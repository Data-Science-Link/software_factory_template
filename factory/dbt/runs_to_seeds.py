#!/usr/bin/env python3
"""Build deterministic dbt seeds (agent_runs.csv) from validated run records.

stdlib + the existing validator in scripts/factory-validate-run.py only, no network.
"""
from __future__ import annotations

import argparse
import csv
import importlib.util
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
VALIDATOR_PATH = REPO_ROOT / "scripts" / "factory-validate-run.py"

COLUMNS = [
    "run_id",
    "repo",
    "issue",
    "pr",
    "trigger",
    "triggered_by",
    "harness",
    "provider",
    "model",
    "escalated_from",
    "complexity",
    "risk",
    "work_type",
    "price_table_version",
    "price_in_per_mtok",
    "price_cached_per_mtok",
    "price_out_per_mtok",
    "requests",
    "tokens_in",
    "tokens_cached",
    "tokens_out",
    "tokens_reasoning",
    "predicted_cost_usd",
    "actual_cost_usd",
    "cost_method",
    "key_spend_delta_usd",
    "cost_check",
    "budget_cap_usd",
    "issue_spend_to_date_usd",
    "started_at",
    "ended_at",
    "duration_s",
    "actions_minutes",
    "runner",
    "outcome",
    "gate_passed",
]


def load_validator():
    spec = importlib.util.spec_from_file_location("factory_validate_run", VALIDATOR_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.load_record, module.validate_record


def csv_value(value):
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", default="factory/runs/*.json")
    parser.add_argument("--out", default="factory/dbt/seeds")
    args = parser.parse_args()

    load_record, validate_record = load_validator()

    pattern = Path(args.runs)
    if "*" in args.runs:
        files = sorted(pattern.parent.glob(pattern.name))
    else:
        files = [pattern]

    records = []
    for path in files:
        if not path.is_file():
            continue
        try:
            record = load_record(path)
        except (OSError, ValueError) as exc:
            print(f"INVALID {path}: {exc}", file=sys.stderr)
            return 1
        errors = validate_record(record, path)
        if errors:
            print(f"INVALID {path}:", file=sys.stderr)
            for msg in errors:
                print(f"  - {msg}", file=sys.stderr)
            return 1
        records.append(record)

    records.sort(key=lambda r: (r.get("started_at", ""), r.get("run_id", "")))

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "agent_runs.csv"
    with out_path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f, lineterminator="\n")
        writer.writerow(COLUMNS)
        for record in records:
            writer.writerow([csv_value(record.get(col)) for col in COLUMNS])

    print(f"wrote {out_path} ({len(records)} runs)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
