#!/usr/bin/env python3
"""Offline schema, routing reference, and price-sanity check for .factory/models.yaml.

Reads models.yaml and optionally .factory/MODEL_ROUTING.md. No network.
Refs #71, #127, #30.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODELS = ROOT / ".factory" / "models.yaml"
DEFAULT_ROUTING_MD = ROOT / ".factory" / "MODEL_ROUTING.md"

REQUIRED_SECTIONS = (
    "models",
    "routing_rules",
    "checks",
    "token_priors",
    "budget",
)

PRICE_KEYS = ("price_in_per_mtok", "price_cached_per_mtok", "price_out_per_mtok")
MAX_PRICE_PER_MTOK = 200.0

SPECIAL_MODELS = frozenset({"use_different_model_than_builder"})

MODEL_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$")
BACKTICK_RE = re.compile(r"`([^`]+)`")


class CheckResult:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.models_checked = 0

    def error(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)

    @property
    def status(self) -> str:
        if self.errors:
            return "fail"
        if self.warnings:
            return "warn"
        return "ok"


def load_yaml(path: Path) -> dict[str, Any]:
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise SystemExit(f"models-check: cannot read {path}: {exc}") from exc
    except yaml.YAMLError as exc:
        raise SystemExit(f"models-check: invalid YAML in {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit(f"models-check: {path}: root must be a mapping")
    return data


def is_model_id(value: Any) -> bool:
    return isinstance(value, str) and bool(MODEL_ID_RE.match(value))


def as_nonneg_float(value: Any, label: str) -> float | None:
    if value is None:
        return None
    try:
        out = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(out):
        return None
    return out


def collect_model_refs(obj: Any, refs: set[str]) -> None:
    if isinstance(obj, dict):
        for key, val in obj.items():
            if key == "model" and isinstance(val, str):
                refs.add(val)
            elif key == "escalated_from" and is_model_id(val):
                refs.add(val)
            elif key in ("selected_model",) and is_model_id(val):
                refs.add(val)
            elif key == "model" and isinstance(val, str) and is_model_id(val):
                refs.add(val)
            else:
                collect_model_refs(val, refs)
    elif isinstance(obj, list):
        for item in obj:
            collect_model_refs(item, refs)


def collect_price_source_models(data: dict[str, Any], refs: set[str]) -> None:
    for row in data.get("price_sources") or []:
        if isinstance(row, dict):
            mid = row.get("model")
            if is_model_id(mid):
                refs.add(str(mid))


def models_cataloged_in_md(registry_ids: set[str], md_text: str, result: CheckResult) -> None:
    if not md_text.strip():
        return
    mentioned: set[str] = set()
    for match in BACKTICK_RE.finditer(md_text):
        token = match.group(1).strip()
        if is_model_id(token):
            mentioned.add(token)
    for mid in sorted(registry_ids):
        if mid not in mentioned:
            result.warn(
                f"model {mid!r} is in models.yaml but not backticked in MODEL_ROUTING.md"
            )


def validate_models_yaml(data: dict[str, Any], result: CheckResult) -> set[str]:
    for key in REQUIRED_SECTIONS:
        if key not in data:
            result.error(f"missing required top-level section {key!r}")
        elif key == "models":
            if not isinstance(data[key], list) or len(data[key]) == 0:
                result.error("models registry must be a non-empty list")
        elif not data[key]:
            result.error(f"required section {key!r} is empty")

    rows = data.get("models")
    if not isinstance(rows, list):
        return set()

    ids: list[str] = []
    registry: set[str] = set()
    for i, row in enumerate(rows):
        if not isinstance(row, dict):
            result.error(f"models[{i}] must be a mapping")
            continue
        mid = row.get("id")
        if not mid:
            result.error(f"models[{i}] missing id")
            continue
        mid_s = str(mid)
        ids.append(mid_s)
        registry.add(mid_s)

    seen: set[str] = set()
    for mid in ids:
        if mid in seen:
            result.error(f"duplicate model id {mid!r}")
        seen.add(mid)

    result.models_checked = len(registry)

    for i, row in enumerate(rows):
        if not isinstance(row, dict) or not row.get("id"):
            continue
        mid = str(row["id"])
        has_price = any(k in row for k in PRICE_KEYS)
        if not has_price:
            continue
        for pk in PRICE_KEYS:
            if pk not in row:
                result.error(f"model {mid!r}: missing {pk}")
                continue
            val = as_nonneg_float(row[pk], pk)
            if val is None:
                result.error(f"model {mid!r}: {pk} is not a finite number")
            elif val < 0:
                result.error(f"model {mid!r}: {pk} must be non-negative (got {row[pk]!r})")
            elif val > MAX_PRICE_PER_MTOK:
                result.warn(
                    f"model {mid!r}: {pk}={val} exceeds ${MAX_PRICE_PER_MTOK}/1M "
                    "(possible typo)"
                )

    refs: set[str] = set()
    collect_model_refs(data.get("routing_rules"), refs)
    collect_model_refs(data.get("routing_worked_examples"), refs)
    collect_price_source_models(data, refs)

    for ref in sorted(refs):
        if ref in SPECIAL_MODELS:
            continue
        if not is_model_id(ref):
            result.warn(f"routing references non-model token {ref!r}")
            continue
        if ref not in registry:
            result.error(f"routing references undefined model id {ref!r}")

    return registry


def validate_routing_md(registry: set[str], path: Path | None, result: CheckResult) -> None:
    if path is None or not path.is_file():
        return
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        result.warn(f"cannot read {path}: {exc}")
        return
    models_cataloged_in_md(registry, text, result)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "--models-yaml",
        type=Path,
        default=DEFAULT_MODELS,
        help="Path to models.yaml (default: .factory/models.yaml)",
    )
    ap.add_argument(
        "--routing-md",
        type=Path,
        default=DEFAULT_ROUTING_MD,
        help="Path to MODEL_ROUTING.md for cross-check (default: .factory/MODEL_ROUTING.md)",
    )
    ap.add_argument("--json", action="store_true", help="Emit JSON result on stdout")
    ap.add_argument(
        "--strict",
        action="store_true",
        help="Treat warnings as errors (non-zero exit)",
    )
    args = ap.parse_args()

    data = load_yaml(args.models_yaml)
    result = CheckResult()
    registry = validate_models_yaml(data, result)

    routing_path = args.routing_md
    if routing_path == DEFAULT_ROUTING_MD and not routing_path.is_file():
        routing_path = None
    validate_routing_md(registry, routing_path, result)

    payload = {
        "status": result.status,
        "models_checked": result.models_checked,
        "errors": result.errors,
        "warnings": result.warnings,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        if result.status == "ok":
            print(
                f"OK  {args.models_yaml} ({result.models_checked} model(s), "
                "no errors or warnings)"
            )
        else:
            print(f"models-check: {args.models_yaml} ({result.models_checked} model(s))")
            for msg in result.errors:
                print(f"ERROR  {msg}", file=sys.stderr)
            for msg in result.warnings:
                print(f"WARN   {msg}", file=sys.stderr)

    if result.errors:
        return 1
    if args.strict and result.warnings:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())