#!/usr/bin/env python3
"""Compare .factory/models.yaml DeepInfra prices to a catalog and propose updates (issue #71).

Proposal-only: never writes models.yaml. Use --catalog for offline runs or --fetch for the
public DeepInfra OpenAI-compatible models list. Exits 0 when nothing meaningful changed;
exits 2 when a proposal should be opened; exits 1 on usage or catalog errors.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODELS = ROOT / ".factory" / "models.yaml"
DEEPINFRA_MODELS_URL = "https://api.deepinfra.com/v1/openai/models"
PRICE_DELTA_FRACTION = 0.15
PRICE_KEYS = ("price_in_per_mtok", "price_cached_per_mtok", "price_out_per_mtok")
CODING_ID_HINTS = ("coder", "code", "instruct")


@dataclass
class PriceRow:
    price_in_per_mtok: float
    price_cached_per_mtok: float
    price_out_per_mtok: float


@dataclass
class CatalogEntry:
    id: str
    prices: PriceRow
    promo: bool = False
    promo_long_lived: bool = False
    coding_candidate: bool = False
    quality_tier: str = "unknown"
    notes: str = ""


@dataclass
class ProposalItem:
    kind: str
    model_id: str
    rationale: str
    fields: list[dict[str, Any]] = field(default_factory=list)
    extra: dict[str, Any] = field(default_factory=dict)


def err(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)


def load_models_yaml(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if not path.is_file():
        raise ValueError(f"models file not found: {path}")
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise ValueError(f"cannot read {path}: {exc}") from exc
    try:
        data = yaml.safe_load(raw)
    except yaml.YAMLError as exc:
        raise ValueError(f"{path}: YAML parse error: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError(f"{path}: root must be a mapping")
    rows = data.get("models", [])
    if not isinstance(rows, list):
        raise ValueError(f"{path}: models must be a list")
    configured = [
        r for r in rows if isinstance(r, dict) and r.get("provider") == "deepinfra" and r.get("id")
    ]
    return data, configured


def _as_float(value: Any, label: str) -> float:
    if value is None:
        raise ValueError(f"missing {label}")
    try:
        out = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"invalid {label}: {value!r}") from exc
    if not math.isfinite(out):
        raise ValueError(f"non-finite {label}")
    return out


def price_row_from_mapping(m: dict[str, Any]) -> PriceRow:
    return PriceRow(
        price_in_per_mtok=_as_float(m.get("price_in_per_mtok"), "price_in_per_mtok"),
        price_cached_per_mtok=_as_float(m.get("price_cached_per_mtok"), "price_cached_per_mtok"),
        price_out_per_mtok=_as_float(m.get("price_out_per_mtok"), "price_out_per_mtok"),
    )


def relative_delta(current: float, candidate: float) -> float | None:
    if current <= 0:
        return None
    return abs(candidate - current) / current


def meaningful_price_change(current: PriceRow, candidate: PriceRow) -> list[dict[str, Any]]:
    changes: list[dict[str, Any]] = []
    for key in PRICE_KEYS:
        cur = getattr(current, key)
        cand = getattr(candidate, key)
        delta = relative_delta(cur, cand)
        if delta is None:
            continue
        if delta > PRICE_DELTA_FRACTION and cur != cand:
            changes.append(
                {
                    "field": key,
                    "current": cur,
                    "candidate": cand,
                    "delta_fraction": round(delta, 4),
                    "direction": "decrease" if cand < cur else "increase",
                }
            )
    return changes


def estimated_standard_cost(prices: PriceRow, priors: dict[str, Any]) -> float:
    tokens_in = int(priors.get("tokens_in", 0))
    frac = float(priors.get("tokens_cached_fraction", 0))
    tokens_out = int(priors.get("tokens_out", 0))
    tokens_cached = int(tokens_in * frac)
    return (
        (tokens_in - tokens_cached) * prices.price_in_per_mtok / 1_000_000
        + tokens_cached * prices.price_cached_per_mtok / 1_000_000
        + tokens_out * prices.price_out_per_mtok / 1_000_000
    )


def parse_fixture_catalog(raw: dict[str, Any]) -> dict[str, CatalogEntry]:
    models = raw.get("models")
    if models is None:
        raise ValueError("catalog missing 'models' list")
    if not isinstance(models, list):
        raise ValueError("catalog 'models' must be a list")
    out: dict[str, CatalogEntry] = {}
    for row in models:
        if not isinstance(row, dict) or not row.get("id"):
            continue
        model_id = str(row["id"])
        out[model_id] = CatalogEntry(
            id=model_id,
            prices=price_row_from_mapping(row),
            promo=bool(row.get("promo", False)),
            promo_long_lived=bool(row.get("promo_long_lived", False)),
            coding_candidate=bool(row.get("coding_candidate", False)),
            quality_tier=str(row.get("quality_tier", "unknown")),
            notes=str(row.get("notes", "")),
        )
    candidates = raw.get("candidates", [])
    if isinstance(candidates, list):
        for row in candidates:
            if not isinstance(row, dict) or not row.get("id"):
                continue
            model_id = str(row["id"])
            out[model_id] = CatalogEntry(
                id=model_id,
                prices=price_row_from_mapping(row),
                promo=bool(row.get("promo", False)),
                promo_long_lived=bool(row.get("promo_long_lived", False)),
                coding_candidate=True,
                quality_tier=str(row.get("quality_tier", "comparable")),
                notes=str(row.get("notes", "")),
            )
    return out


def catalog_from_deepinfra(payload: dict[str, Any]) -> dict[str, CatalogEntry]:
    data = payload.get("data")
    if not isinstance(data, list):
        raise ValueError("DeepInfra models response missing data[]")
    out: dict[str, CatalogEntry] = {}
    for row in data:
        if not isinstance(row, dict):
            continue
        model_id = row.get("id")
        if not model_id:
            continue
        meta = row.get("metadata") if isinstance(row.get("metadata"), dict) else {}
        pricing = meta.get("pricing") if isinstance(meta.get("pricing"), dict) else {}
        if not pricing:
            continue
        try:
            prices = PriceRow(
                price_in_per_mtok=_as_float(pricing.get("input_tokens"), "input_tokens"),
                price_cached_per_mtok=_as_float(
                    pricing.get("cache_read_tokens", pricing.get("input_tokens")),
                    "cache_read_tokens",
                ),
                price_out_per_mtok=_as_float(pricing.get("output_tokens"), "output_tokens"),
            )
        except ValueError:
            continue
        discount = meta.get("discount")
        promo = discount is not None
        long_lived = bool(meta.get("promo_long_lived"))
        mid = str(model_id).lower()
        coding = any(h in mid for h in CODING_ID_HINTS) or "coder" in str(meta.get("description", "")).lower()
        out[str(model_id)] = CatalogEntry(
            id=str(model_id),
            prices=prices,
            promo=promo,
            promo_long_lived=long_lived,
            coding_candidate=coding,
            quality_tier="unknown",
        )
    return out


def load_catalog_path(path: Path) -> dict[str, CatalogEntry]:
    if not path.is_file():
        raise ValueError(f"catalog file not found: {path}")
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise ValueError(f"cannot read catalog {path}: {exc}") from exc
    try:
        raw = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"catalog is not valid JSON: {exc}") from exc
    if not isinstance(raw, dict):
        raise ValueError("catalog root must be a JSON object")
    return parse_fixture_catalog(raw)


def fetch_catalog() -> dict[str, CatalogEntry]:
    req = urllib.request.Request(
        DEEPINFRA_MODELS_URL,
        headers={"Accept": "application/json", "User-Agent": "factory-model-scout/1"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = json.load(resp)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise ValueError(f"could not fetch DeepInfra models: {exc}") from exc
    return catalog_from_deepinfra(payload)


def ignore_promo_entry(entry: CatalogEntry) -> bool:
    return entry.promo and not entry.promo_long_lived


def configured_price_row(row: dict[str, Any]) -> PriceRow:
    model_id = str(row.get("id") or "?")
    try:
        return price_row_from_mapping(row)
    except ValueError as exc:
        raise ValueError(f"configured model {model_id}: {exc}") from exc


def build_proposals(
    configured: list[dict[str, Any]],
    catalog: dict[str, CatalogEntry],
    priors: dict[str, Any],
) -> list[ProposalItem]:
    proposals: list[ProposalItem] = []
    configured_ids = {str(r["id"]) for r in configured}

    for row in configured:
        model_id = str(row["id"])
        entry = catalog.get(model_id)
        if entry is None:
            continue
        if ignore_promo_entry(entry):
            continue
        current = configured_price_row(row)
        field_changes = meaningful_price_change(current, entry.prices)
        if not field_changes:
            continue
        parts = [
            f"{c['field']} {c['direction']} {c['delta_fraction'] * 100:.1f}%"
            for c in field_changes
        ]
        proposals.append(
            ProposalItem(
                kind="price_update",
                model_id=model_id,
                rationale="Catalog price differs by more than "
                f"{int(PRICE_DELTA_FRACTION * 100)}%: " + "; ".join(parts),
                fields=field_changes,
            )
        )

    standard = priors.get("standard")
    if isinstance(standard, dict):
        baseline_rows = [
            r
            for r in configured
            if str(r.get("status")) in ("default", "complex_builder", "escalation")
        ]
        baseline_costs = [
            (str(r["id"]), estimated_standard_cost(configured_price_row(r), standard)) for r in baseline_rows
        ]
        best_id, best_cost = min(baseline_costs, key=lambda t: t[1]) if baseline_costs else ("", float("inf"))

        for model_id, entry in catalog.items():
            if model_id in configured_ids:
                continue
            if ignore_promo_entry(entry):
                continue
            if not entry.coding_candidate:
                continue
            tier = entry.quality_tier.lower()
            if tier not in ("comparable", "higher", "high"):
                continue
            cand_cost = estimated_standard_cost(entry.prices, standard)
            if best_cost <= 0:
                continue
            saving = (best_cost - cand_cost) / best_cost
            if saving <= PRICE_DELTA_FRACTION:
                continue
            proposals.append(
                ProposalItem(
                    kind="better_value_candidate",
                    model_id=model_id,
                    rationale=(
                        f"Standard-run prior cost ~${cand_cost:.4f} vs best configured "
                        f"{best_id} ~${best_cost:.4f} ({saving * 100:.1f}% lower)."
                    ),
                    extra={
                        "baseline_model": best_id,
                        "baseline_cost_usd": round(best_cost, 4),
                        "candidate_cost_usd": round(cand_cost, 4),
                        "quality_tier": entry.quality_tier,
                        "notes": entry.notes,
                    },
                )
            )

    return proposals


def render_markdown(proposals: list[ProposalItem], models_path: Path, checked_at: str) -> str:
    lines = [
        "## Weekly model scouting proposal",
        "",
        f"Source of truth today: `{models_path.relative_to(ROOT)}` (read-only; owner updates by hand).",
        f"Catalog checked: {checked_at}.",
        "",
        "This is a **proposal only** — no automatic changes to `models.yaml`.",
        "",
    ]
    for item in proposals:
        lines.append(f"### {item.model_id}")
        lines.append("")
        lines.append(f"- **Kind:** {item.kind}")
        lines.append(f"- **Rationale:** {item.rationale}")
        if item.fields:
            lines.append("")
            lines.append("| Field | Current ($/Mtok) | Catalog ($/Mtok) | Delta |")
            lines.append("| --- | ---: | ---: | ---: |")
            for f in item.fields:
                lines.append(
                    f"| `{f['field']}` | {f['current']:.6g} | {f['candidate']:.6g} | "
                    f"{f['delta_fraction'] * 100:.1f}% {f['direction']} |"
                )
        if item.extra:
            lines.append("")
            for key, val in item.extra.items():
                lines.append(f"- **{key}:** {val}")
        lines.append("")
    lines.append("---")
    lines.append("_Generated by `scripts/factory-model-scout.py` (issue #71)._")
    return "\n".join(lines).rstrip() + "\n"


def emit_json(proposals: list[ProposalItem], status: str, models_path: Path, checked_at: str) -> str:
    body = {
        "status": status,
        "checked_at": checked_at,
        "models_yaml": str(models_path),
        "items": [
            {
                "kind": p.kind,
                "model_id": p.model_id,
                "rationale": p.rationale,
                "fields": p.fields,
                **({"extra": p.extra} if p.extra else {}),
            }
            for p in proposals
        ],
    }
    return json.dumps(body, indent=2, sort_keys=True) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--models", type=Path, default=DEFAULT_MODELS)
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--catalog", type=Path, help="Offline catalog JSON (deterministic tests)")
    src.add_argument("--fetch", action="store_true", help="Load catalog from DeepInfra public models API")
    ap.add_argument(
        "--format",
        choices=("markdown", "json"),
        default="markdown",
        help="Proposal output format (default: markdown)",
    )
    ap.add_argument(
        "--checked-at",
        default=date.today().isoformat(),
        help="Date stamp for the proposal (default: today UTC calendar date)",
    )
    args = ap.parse_args()

    if not args.catalog and not args.fetch:
        err("provide --catalog <file> or --fetch")
        return 1

    try:
        _data, configured = load_models_yaml(args.models)
    except ValueError as exc:
        err(f"cannot read models.yaml: {exc}")
        return 1

    if not configured:
        err("no deepinfra models configured in models.yaml")
        return 1

    priors = _data.get("token_priors") if isinstance(_data.get("token_priors"), dict) else {}

    try:
        if args.fetch:
            catalog = fetch_catalog()
        else:
            assert args.catalog is not None
            catalog = load_catalog_path(args.catalog)
    except ValueError as exc:
        err(str(exc))
        return 1

    if not catalog:
        if args.format == "json":
            sys.stdout.write(emit_json([], "no_change", args.models, args.checked_at))
        else:
            print("model-scout: empty catalog — no meaningful changes", file=sys.stderr)
        return 0

    proposals = build_proposals(configured, catalog, priors)
    if not proposals:
        if args.format == "json":
            sys.stdout.write(emit_json([], "no_change", args.models, args.checked_at))
        else:
            print("model-scout: no meaningful changes", file=sys.stderr)
        return 0

    payload = emit_json(proposals, "proposal", args.models, args.checked_at)
    if args.format == "json":
        sys.stdout.write(payload)
    else:
        sys.stdout.write(render_markdown(proposals, args.models, args.checked_at))
    return 2


if __name__ == "__main__":
    sys.exit(main())