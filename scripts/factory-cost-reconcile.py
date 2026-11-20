#!/usr/bin/env python3
"""Offline deterministic cost reconciliation and run-record drift auditor.

Loads model prices from .factory/models.yaml (stdlib YAML subset parser), walks run
JSON files under factory/runs/, recomputes usage × price_table, and classifies each
run as MATCH, DRIFT, UNPRICED_MODEL, or NO_TOKEN_USAGE.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RUNS = ROOT / "factory" / "runs"
DEFAULT_MODELS = ROOT / ".factory" / "models.yaml"
ALTERNATE_MODELS = ROOT / "factory" / "models.yaml"

PRICE_KEYS = ("price_in_per_mtok", "price_cached_per_mtok", "price_out_per_mtok")
TOKEN_KEYS = ("tokens_in", "tokens_out")


def die(msg: str, code: int = 2) -> None:
    print(f"cost-reconcile: {msg}", file=sys.stderr)
    sys.exit(code)


def resolve_default_models() -> Path:
    if DEFAULT_MODELS.is_file():
        return DEFAULT_MODELS
    if ALTERNATE_MODELS.is_file():
        return ALTERNATE_MODELS
    die(f"models file not found: {DEFAULT_MODELS} or {ALTERNATE_MODELS}")


def _strip_yaml_scalar(raw: str) -> str:
    value = raw.strip()
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1]
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1]
    return value


def load_price_table(path: Path) -> dict[str, dict[str, float]]:
    """Parse model id and per-mtok prices from models.yaml without PyYAML."""
    if not path.is_file():
        die(f"models file not found: {path}")

    text = path.read_text(encoding="utf-8")
    prices: dict[str, dict[str, float]] = {}
    in_models = False
    current_id: str | None = None
    current: dict[str, float] = {}

    def flush() -> None:
        nonlocal current_id, current
        if current_id and all(k in current for k in PRICE_KEYS):
            prices[current_id] = dict(current)
        current_id = None
        current = {}

    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("models:"):
            in_models = True
            continue
        if not in_models:
            continue
        if not line.startswith(" ") and not line.startswith("\t"):
            flush()
            break
        if line.startswith("  - "):
            flush()
            rest = line[4:].strip()
            if rest.startswith("id:"):
                current_id = _strip_yaml_scalar(rest.split(":", 1)[1])
            continue
        if current_id is None:
            continue
        stripped = line.strip()
        for key in PRICE_KEYS:
            if stripped.startswith(f"{key}:"):
                try:
                    current[key] = float(_strip_yaml_scalar(stripped.split(":", 1)[1]))
                except ValueError as exc:
                    die(f"{path}: bad {key} for {current_id!r}: {exc}")
                break

    flush()
    if not prices:
        die(f"{path}: no models with price fields found")
    return prices


def cost_from_usage(
    tokens_in: int,
    tokens_cached: int,
    tokens_out: int,
    price_in_per_mtok: float,
    price_cached_per_mtok: float,
    price_out_per_mtok: float,
) -> float:
    return (
        (tokens_in - tokens_cached) * price_in_per_mtok / 1_000_000
        + tokens_cached * price_cached_per_mtok / 1_000_000
        + tokens_out * price_out_per_mtok / 1_000_000
    )


def has_token_usage(record: dict[str, Any]) -> bool:
    for key in TOKEN_KEYS:
        if key not in record or record[key] is None:
            return False
    return True


def actual_cost_usd(record: dict[str, Any]) -> float | None:
    if "actual_cost_usd" in record and record["actual_cost_usd"] is not None:
        return float(record["actual_cost_usd"])
    if "cost_usd" in record and record["cost_usd"] is not None:
        return float(record["cost_usd"])
    return None


def classify_run(
    record: dict[str, Any],
    price_table: dict[str, dict[str, float]],
    tolerance: float,
) -> dict[str, Any]:
    run_id = record.get("run_id") or record.get("_source_file", "unknown")
    if not has_token_usage(record):
        return {
            "run_id": run_id,
            "status": "NO_TOKEN_USAGE",
            "model": record.get("model"),
            "actual_cost_usd": actual_cost_usd(record),
            "expected_cost_usd": None,
            "delta_usd": None,
        }

    model = record.get("model")
    if not isinstance(model, str) or not model.strip():
        return {
            "run_id": run_id,
            "status": "UNPRICED_MODEL",
            "model": model,
            "actual_cost_usd": actual_cost_usd(record),
            "expected_cost_usd": None,
            "delta_usd": None,
        }

    row = price_table.get(model.strip())
    if row is None:
        return {
            "run_id": run_id,
            "status": "UNPRICED_MODEL",
            "model": model,
            "actual_cost_usd": actual_cost_usd(record),
            "expected_cost_usd": None,
            "delta_usd": None,
        }

    tokens_in = int(record["tokens_in"])
    tokens_cached = int(record.get("tokens_cached") or 0)
    tokens_out = int(record["tokens_out"])
    expected = cost_from_usage(
        tokens_in,
        tokens_cached,
        tokens_out,
        row["price_in_per_mtok"],
        row["price_cached_per_mtok"],
        row["price_out_per_mtok"],
    )
    actual = actual_cost_usd(record)
    if actual is None:
        actual = 0.0
    delta = actual - expected
    status = "MATCH" if abs(delta) <= tolerance else "DRIFT"
    return {
        "run_id": run_id,
        "status": status,
        "model": model,
        "actual_cost_usd": actual,
        "expected_cost_usd": expected,
        "delta_usd": delta,
    }


def load_run_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        die(f"{path}: invalid JSON: {exc}")
    if not isinstance(data, dict):
        die(f"{path}: run record must be a JSON object")
    data["_source_file"] = path.name
    return data


def iter_run_files(runs_dir: Path) -> list[Path]:
    if not runs_dir.is_dir():
        die(f"runs directory not found: {runs_dir}")
    return sorted(p for p in runs_dir.glob("*.json") if p.is_file())


def build_report(
    runs_dir: Path,
    price_table: dict[str, dict[str, float]],
    tolerance: float,
) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    for path in iter_run_files(runs_dir):
        record = load_run_json(path)
        if not record.get("run_id"):
            record["run_id"] = path.stem
        results.append(classify_run(record, price_table, tolerance))

    counts = {s: 0 for s in ("MATCH", "DRIFT", "UNPRICED_MODEL", "NO_TOKEN_USAGE")}
    total_logged = 0.0
    total_recomputed = 0.0
    max_drift = 0.0
    for row in results:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
        if row["actual_cost_usd"] is not None:
            total_logged += float(row["actual_cost_usd"])
        if row["expected_cost_usd"] is not None:
            total_recomputed += float(row["expected_cost_usd"])
        if row["status"] == "DRIFT" and row["delta_usd"] is not None:
            max_drift = max(max_drift, abs(float(row["delta_usd"])))

    summary = {
        "runs_dir": str(runs_dir),
        "total_runs": len(results),
        "matched": counts["MATCH"],
        "drifted": counts["DRIFT"],
        "unpriced": counts["UNPRICED_MODEL"],
        "no_token_usage": counts["NO_TOKEN_USAGE"],
        "max_drift_usd": max_drift,
        "total_logged_usd": total_logged,
        "total_recomputed_usd": total_recomputed,
        "tolerance_usd": tolerance,
    }
    return {"summary": summary, "runs": results}


def print_table(report: dict[str, Any]) -> None:
    s = report["summary"]
    print("Factory cost reconciliation")
    print(f"  runs_dir              {s['runs_dir']}")
    print(f"  total_runs            {s['total_runs']}")
    print(f"  matched               {s['matched']}")
    print(f"  drifted               {s['drifted']}")
    print(f"  unpriced_model        {s['unpriced']}")
    print(f"  no_token_usage        {s['no_token_usage']}")
    print(f"  max_drift_usd         {s['max_drift_usd']:.6f}")
    print(f"  total_logged_usd      {s['total_logged_usd']:.6f}")
    print(f"  total_recomputed_usd  {s['total_recomputed_usd']:.6f}")
    print(f"  tolerance_usd         {s['tolerance_usd']:.6f}")

    if report["runs"]:
        print("")
        print(f"{'run_id':<28} {'status':<18} {'delta_usd':>12}  model")
        print("-" * 72)
        for row in report["runs"]:
            delta = ""
            if row["delta_usd"] is not None:
                delta = f"{row['delta_usd']:+.6f}"
            model = row.get("model") or ""
            print(f"{str(row['run_id']):<28} {row['status']:<18} {delta:>12}  {model}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--runs-dir", type=Path, default=DEFAULT_RUNS)
    ap.add_argument(
        "--models-yaml",
        type=Path,
        default=None,
        help="Model price table (default: .factory/models.yaml or factory/models.yaml)",
    )
    ap.add_argument("--tolerance-usd", type=float, default=0.0005)
    ap.add_argument("--json", action="store_true", dest="as_json")
    ap.add_argument(
        "--strict",
        action="store_true",
        help="Exit non-zero when any run is classified DRIFT",
    )
    args = ap.parse_args()

    models_path = args.models_yaml or resolve_default_models()
    price_table = load_price_table(models_path)
    report = build_report(args.runs_dir.resolve(), price_table, args.tolerance_usd)

    if args.as_json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print_table(report)

    if args.strict and report["summary"]["drifted"] > 0:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()