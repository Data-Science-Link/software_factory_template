#!/usr/bin/env python3
"""Route a DeepInfra model and predict run cost from a factory spec + models.yaml.

Reads only the spec file and .factory/models.yaml (or --models). No network.

The model is always routed from models.yaml. A spec's `model` is kept only as an owner
override, i.e. when `model_override_reason` is non-empty; otherwise it is replaced by the
routed model (and overwritten with --write). Checks and the cost cap apply either way.
The split guard uses budget.issue_cap_usd; checks rule 6 is the fallback when it is absent.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import date, datetime
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODELS = ROOT / ".factory" / "models.yaml"

SPECIAL_MODELS = frozenset({"use_different_model_than_builder"})


SPEC_MARKER = "<!-- factory-spec v1 -->"


def split_marker(text: str) -> tuple[str, str]:
    """(prefix, rest): prefix is everything up to and including the spec marker line (empty when
    there is no marker), so a spec comment body or text before the marker works (#60)."""
    idx = text.find(SPEC_MARKER)
    if idx == -1:
        return "", text
    end = text.find("\n", idx)
    end = len(text) if end == -1 else end + 1
    return text[:end], text[end:]


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


# Fields --write owns. Every other byte of the file is left unchanged (#60).
OWNED_WRITE_FIELDS = (
    "model",
    "model_reason",
    "predicted_tokens_in",
    "predicted_tokens_cached",
    "predicted_tokens_out",
    "predicted_cost_usd",
    "budget_cap_usd",
    "price_table_version",
)

_NEEDS_QUOTES = re.compile(
    r"^(?:"
    r"null|true|false|yes|no|on|off|~|"
    r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"
    r")$",
    re.I,
)


def _line_core(line: str) -> str:
    return line.lstrip("\ufeff").rstrip("\r\n")


def _line_ending(line: str) -> str:
    if line.endswith("\r\n"):
        return "\r\n"
    if line.endswith("\n"):
        return "\n"
    return "\n"


def _is_field_line(line: str, key: str) -> bool:
    return bool(re.match(rf"^{re.escape(key)}:(\s|$)", _line_core(line)))


def _is_continuation(line: str) -> bool:
    core = line.rstrip("\r\n")
    return bool(core) and core[0] in " \t"


def _quote_if_needed(text: str) -> str:
    """Single-quote a YAML scalar only when leaving it bare would change the value."""
    if text == "":
        return ""
    needs = (
        text[0] in " \t'\"&*!%@`|>{}[]?,:"
        or text[-1] in " \t"
        or (text[0] == "-" and (len(text) == 1 or text[1] in " \t"))
        or "#" in text
        or ": " in text
        or text.endswith(":")
        or "\n" in text
        or bool(_NEEDS_QUOTES.fullmatch(text))
    )
    if needs:
        return "'" + text.replace("'", "''") + "'"
    return text


def format_owned_value(key: str, value: Any) -> str:
    if value is None:
        return "null"
    if key == "predicted_cost_usd":
        return f"{float(value):.4f}"
    if key == "budget_cap_usd":
        return f"{float(value):.2f}"
    if key in (
        "predicted_tokens_in",
        "predicted_tokens_cached",
        "predicted_tokens_out",
    ):
        return str(int(value))
    if key == "price_table_version":
        # Unquoted so a version like 2026-11-02 stays a bare date, matching the template.
        return _version_str(value)
    return _quote_if_needed(str(value))


def _parse_rhs(rhs: str) -> Any:
    try:
        loaded = yaml.safe_load("v: " + rhs)
    except yaml.YAMLError:
        return rhs.strip()
    if isinstance(loaded, dict) and "v" in loaded:
        return loaded["v"]
    return loaded


def _version_str(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, datetime):
        return value.date().isoformat()
    if isinstance(value, date):
        return value.isoformat()
    return str(value).strip()


def _values_match(key: str, existing: Any, new: Any) -> bool:
    if key == "price_table_version":
        return _version_str(existing) == _version_str(new) and _version_str(new) != ""
    if key in ("predicted_cost_usd", "budget_cap_usd"):
        if existing is None or new is None:
            return existing is None and new is None
        try:
            return float(existing) == float(new)
        except (TypeError, ValueError):
            return False
    if key in (
        "predicted_tokens_in",
        "predicted_tokens_cached",
        "predicted_tokens_out",
    ):
        try:
            return int(existing) == int(new)
        except (TypeError, ValueError):
            return False
    exist_s = "" if existing is None else str(existing)
    new_s = "" if new is None else str(new)
    return exist_s == new_s


def _front_matter_bounds(lines: list[str]) -> tuple[int, int]:
    """Indexes of the opening and closing --- lines, searching after a spec marker if present."""
    search_from = 0
    for i, line in enumerate(lines):
        if SPEC_MARKER in line:
            search_from = i + 1
            break
    start = None
    for i in range(search_from, len(lines)):
        if _line_core(lines[i]).strip() == "---":
            if start is None:
                start = i
            else:
                return start, i
    raise SystemExit("cannot --write: missing YAML front matter delimiters")


def patch_owned_fields(text: str, updates: dict[str, Any]) -> str:
    """Rewrite only owned front-matter field lines; leave every other byte unchanged."""
    updates = {k: updates[k] for k in OWNED_WRITE_FIELDS if k in updates}
    lines = text.splitlines(keepends=True)
    if not lines:
        raise SystemExit("cannot --write: empty file")
    start, end = _front_matter_bounds(lines)
    seen: set[str] = set()
    out: list[str] = []
    out.extend(lines[: start + 1])
    i = start + 1
    while i < end:
        line = lines[i]
        matched: str | None = None
        for key in updates:
            if _is_field_line(line, key):
                matched = key
                break
        if matched is None:
            out.append(line)
            i += 1
            continue
        j = i + 1
        while j < end and _is_continuation(lines[j]):
            j += 1
        if matched in seen:
            i = j
            continue
        seen.add(matched)
        rhs = _line_core(line).split(":", 1)[1]
        if j > i + 1:
            rhs += "".join(lines[i + 1 : j])
        existing = _parse_rhs(rhs)
        new_val = updates[matched]
        if _values_match(matched, existing, new_val):
            out.extend(lines[i:j])
        else:
            nl = _line_ending(line)
            out.append(f"{matched}: {format_owned_value(matched, new_val)}{nl}")
        i = j
    missing = [k for k in OWNED_WRITE_FIELDS if k in updates and k not in seen]
    if missing:
        nl = _line_ending(lines[end]) if end < len(lines) else "\n"
        for key in missing:
            out.append(f"{key}: {format_owned_value(key, updates[key])}{nl}")
    out.extend(lines[end:])
    return "".join(out)


def write_spec(path: Path, updates: dict[str, Any], original: str | None = None) -> None:
    text = path.read_text(encoding="utf-8") if original is None else original
    path.write_text(patch_owned_fields(text, updates), encoding="utf-8")


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
    _marker_prefix, raw = split_marker(raw)
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
    rule, route_reason = select_route(routing_rules, ctx)
    if rule is None:
        raise SystemExit("no routing rule matched; cannot select a model")
    routed_model = rule.get("model")
    routed_rule = rule.get("rule")

    spec_model = fm.get("model")
    override_reason = fm.get("model_override_reason")
    is_override = (
        not is_empty_model(spec_model)
        and isinstance(override_reason, str)
        and bool(override_reason.strip())
    )
    selected_via_rule: int | None = None

    if is_override:
        model_id = str(spec_model).strip()
        model_reason = f"owner override: {override_reason.strip()}"
        if model_id in SPECIAL_MODELS:
            raise SystemExit(f"spec model {model_id!r} is not a concrete DeepInfra model id")
        if model_id != routed_model:
            print(
                f"warning: spec model {model_id} differs from routed model {routed_model} "
                f"(rule {routed_rule}); kept as owner override",
                file=sys.stderr,
            )
    else:
        model_id = routed_model
        model_reason = route_reason
        selected_via_rule = routed_rule
        if model_id in SPECIAL_MODELS:
            raise SystemExit(
                f"routing rule {selected_via_rule} requires a human/model choice "
                f"({model_id!r}); cannot predict cost automatically"
            )

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

    cap_raw = budget.get("issue_cap_usd")
    issue_cap: float | None = float(cap_raw) if cap_raw is not None else None
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
        "model_override": is_override,
        "routed_model": routed_model,
        "routed_rule": routed_rule,
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

    # Split guard: budget.issue_cap_usd is the source of truth; checks rule 6 only as fallback.
    if issue_cap is not None:
        if predicted_cost > issue_cap:
            print(
                f"predicted cost ${predicted_cost:.4f} exceeds issue cap ${issue_cap:.2f} "
                "(budget.issue_cap_usd); split this issue",
                file=sys.stderr,
            )
            raise SystemExit(2)
    elif "do_not_run_split_issue" in check_actions:
        print(
            f"predicted cost ${predicted_cost:.4f} exceeds the checks rule 6 cap "
            "(budget.issue_cap_usd not set); split this issue",
            file=sys.stderr,
        )
        raise SystemExit(2)

    if predicted_cost > issue_target:
        cap_note = f"${issue_cap:.2f}" if issue_cap is not None else "checks rule 6"
        print(
            f"warning: predicted cost ${predicted_cost:.4f} is above target "
            f"${issue_target:.2f} (cap {cap_note})",
            file=sys.stderr,
        )

    if write:
        write_spec(
            spec_path,
            {
                "model": model_id,
                "model_reason": model_reason,
                "predicted_tokens_in": tokens_in,
                "predicted_tokens_cached": tokens_cached,
                "predicted_tokens_out": tokens_out,
                "predicted_cost_usd": predicted_cost,
                "budget_cap_usd": issue_cap,
                "price_table_version": price_table_version,
            },
        )

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
        help="Update owned front-matter fields in place (targeted line edits; every other byte unchanged)",
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
