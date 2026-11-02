#!/usr/bin/env python3
"""Route a DeepInfra model and predict run cost from a factory spec + models.yaml.

Reads only the spec file and .factory/models.yaml (or --models). No network.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODELS = ROOT / ".factory" / "models.yaml"

SPECIAL_MODELS = frozenset({"use_different_model_than_builder"})


def strip_test_directive(text: str) -> str:
    lines = text.splitlines(keepends=True)
    while lines and lines[0].startswith("# predict-expect:"):
        lines.pop(0)
    return "".join(lines)


def split_front_matter(text: str) -> tuple[dict[str, Any] | None, str]:
    body_start = text.lstrip("\ufeff").lstrip()
    if not body_start.startswith("---"):
        return None, text
    parts = body_start.split("---", 2)
    if len(parts) < 3:
        return None, text
    try:
        data = yaml.safe_load(parts[1])
    except yaml.YAMLError as exc:
        raise SystemExit(f"invalid spec front matter YAML: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit("spec front matter must be a YAML mapping")
    return data, parts[2]


def _match_when(when: dict, ctx: dict) -> bool:
    if not when:
        return True
    if "any" in when:
        return any(_match_when(branch, ctx) for branch in when["any"])
    for key, expected in when.items():
        if key == "predicted_cost_usd_gt":
            pred = ctx.get("predicted_cost_usd")
            if pred is None or not (pred > expected):
                return False
        elif ctx.get(key) != expected:
            return False
    return True


def select_route(routing_rules: list[dict], ctx: dict) -> tuple[dict | None, str | None]:
    for rule in routing_rules:
        if _match_when(rule.get("when") or {}, ctx):
            return rule, rule.get("description") or f"routing rule {rule.get('rule')}"
    return None, None


def model_prices(models: list[dict], model_id: str) -> dict[str, Any]:
    for row in models:
        if row.get("id") == model_id:
            return row
    raise SystemExit(f"unknown model id {model_id!r} (not in models.yaml)")


def predict_tokens(priors: dict, complexity: str) -> tuple[int, int, int]:
    if complexity not in priors:
        raise SystemExit(f"unknown complexity {complexity!r} (not in token_priors)")
    block = priors[complexity]
    tokens_in = int(block["tokens_in"])
    frac = float(block["tokens_cached_fraction"])
    tokens_cached = int(tokens_in * frac)
    tokens_out = int(block["tokens_out"])
    return tokens_in, tokens_cached, tokens_out


def predict_cost_usd(
    tokens_in: int,
    tokens_cached: int,
    tokens_out: int,
    price_in: float,
    price_cached: float,
    price_out: float,
) -> float:
    uncached = tokens_in - tokens_cached
    cost = (
        (uncached / 1_000_000) * price_in
        + (tokens_cached / 1_000_000) * price_cached
        + (tokens_out / 1_000_000) * price_out
    )
    return round(cost, 4)


def routing_context(fm: dict[str, Any]) -> dict[str, Any]:
    ctx: dict[str, Any] = {}
    for key in (
        "complexity",
        "risk",
        "work_type",
        "retry",
        "escalated_from",
        "error_class",
        "prior_model_family",
        "tier_requested",
    ):
        if key in fm and fm[key] is not None:
            ctx[key] = fm[key]
    return ctx


def is_empty_model(value: Any) -> bool:
    if value is None:
        return True
    if isinstance(value, str) and not value.strip():
        return True
    return False


def dump_front_matter(fm: dict[str, Any]) -> str:
    return yaml.safe_dump(fm, sort_keys=False, default_flow_style=False).rstrip()


def write_spec(path: Path, fm: dict[str, Any], body: str) -> None:
    if body and not body.startswith("\n"):
        body = "\n" + body
    new_text = f"---\n{dump_front_matter(fm)}\n---{body}"
    path.write_text(new_text, encoding="utf-8")


def apply_checks(checks: list[dict], ctx: dict) -> list[str]:
    actions: list[str] = []
    for check in checks:
        if _match_when(check.get("when") or {}, ctx):
            action = check.get("action")
            if action:
                actions.append(action)
    return actions


def compute(
    spec_path: Path,
    models_path: Path,
    *,
    write: bool,
    as_json: bool,
) -> dict[str, Any]:
    raw = strip_test_directive(spec_path.read_text(encoding="utf-8"))
    fm, body = split_front_matter(raw)
    if fm is None:
        raise SystemExit(f"{spec_path}: missing YAML front matter")

    data = yaml.safe_load(models_path.read_text(encoding="utf-8"))
    routing_rules = data["routing_rules"]
    checks_block = data["checks"]
    priors = data["token_priors"]
    budget = data["budget"]
    price_table_version = data["price_table_version"]
    models_list = data["models"]

    complexity = fm.get("complexity")
    if not complexity:
        raise SystemExit("spec front matter missing complexity")

    ctx = routing_context(fm)
    model_id = fm.get("model")
    model_reason = fm.get("model_reason")
    selected_via_rule: int | None = None

    if is_empty_model(model_id):
        rule, reason = select_route(routing_rules, ctx)
        if rule is None:
            raise SystemExit("no routing rule matched; cannot select a model")
        model_id = rule.get("model")
        model_reason = reason
        selected_via_rule = rule.get("rule")
        if model_id in SPECIAL_MODELS:
            raise SystemExit(
                f"routing rule {selected_via_rule} requires a human/model choice "
                f"({model_id!r}); cannot predict cost automatically"
            )
    else:
        model_id = str(model_id).strip()
        if model_id in SPECIAL_MODELS:
            raise SystemExit(f"spec model {model_id!r} is not a concrete DeepInfra model id")

    price_row = model_prices(models_list, model_id)
    tokens_in, tokens_cached, tokens_out = predict_tokens(priors, str(complexity))
    predicted_cost = predict_cost_usd(
        tokens_in,
        tokens_cached,
        tokens_out,
        float(price_row["price_in_per_mtok"]),
        float(price_row["price_cached_per_mtok"]),
        float(price_row["price_out_per_mtok"]),
    )

    check_ctx = dict(ctx)
    check_ctx["predicted_cost_usd"] = predicted_cost
    check_actions = apply_checks(checks_block, check_ctx)

    issue_cap = float(budget["issue_cap_usd"])
    issue_target = float(budget["issue_target_usd"])

    result: dict[str, Any] = {
        "spec_path": str(spec_path),
        "models_path": str(models_path),
        "complexity": complexity,
        "risk": fm.get("risk"),
        "work_type": fm.get("work_type"),
        "model": model_id,
        "model_reason": model_reason,
        "selected_via_rule": selected_via_rule,
        "predicted_tokens_in": tokens_in,
        "predicted_tokens_cached": tokens_cached,
        "predicted_tokens_out": tokens_out,
        "predicted_cost_usd": predicted_cost,
        "price_table_version": price_table_version,
        "price_in_per_mtok": price_row["price_in_per_mtok"],
        "price_cached_per_mtok": price_row["price_cached_per_mtok"],
        "price_out_per_mtok": price_row["price_out_per_mtok"],
        "provider": price_row.get("provider", "deepinfra"),
        "budget_cap_usd": issue_cap,
        "issue_target_usd": issue_target,
        "check_actions": check_actions,
    }

    if "reject_unless_owner_approved" in check_actions:
        owner_ok = fm.get("owner_approved_priority") is True or fm.get(
            "priority_tier_owner_approved"
        ) is True
        if not owner_ok:
            raise SystemExit(
                "Priority DeepInfra tier requested but owner approval is not recorded "
                "(set owner_approved_priority: true in the spec after Michael asks)"
            )

    if "do_not_run_split_issue" in check_actions:
        print(
            f"predicted cost ${predicted_cost:.4f} exceeds issue cap ${issue_cap:.2f}; "
            "split this issue",
            file=sys.stderr,
        )
        raise SystemExit(2)

    if predicted_cost > issue_target:
        print(
            f"warning: predicted cost ${predicted_cost:.4f} is above target "
            f"${issue_target:.2f} (cap ${issue_cap:.2f})",
            file=sys.stderr,
        )

    if write:
        fm["model"] = model_id
        fm["model_reason"] = model_reason
        fm["predicted_tokens_in"] = tokens_in
        fm["predicted_tokens_cached"] = tokens_cached
        fm["predicted_tokens_out"] = tokens_out
        fm["predicted_cost_usd"] = predicted_cost
        fm["budget_cap_usd"] = issue_cap
        fm["price_table_version"] = price_table_version
        write_spec(spec_path, fm, body)

    if as_json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(f"model: {model_id}")
        print(f"model_reason: {model_reason}")
        if selected_via_rule is not None:
            print(f"selected_via_rule: {selected_via_rule}")
        print(f"predicted_tokens_in: {tokens_in}")
        print(f"predicted_tokens_cached: {tokens_cached}")
        print(f"predicted_tokens_out: {tokens_out}")
        print(f"predicted_cost_usd: {predicted_cost:.4f}")
        print(f"price_table_version: {price_table_version}")

    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "spec",
        type=Path,
        help="Spec markdown file (factory/specs/issue-N.md or test fixture)",
    )
    parser.add_argument(
        "--models",
        type=Path,
        default=DEFAULT_MODELS,
        help="Path to models.yaml (default: .factory/models.yaml)",
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help="Update spec front matter in place (body unchanged)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print result as JSON on stdout",
    )
    args = parser.parse_args()

    if not args.spec.is_file():
        raise SystemExit(f"spec not found: {args.spec}")
    if not args.models.is_file():
        raise SystemExit(f"models file not found: {args.models}")

    compute(args.spec, args.models, write=args.write, as_json=args.json)


if __name__ == "__main__":
    main()
