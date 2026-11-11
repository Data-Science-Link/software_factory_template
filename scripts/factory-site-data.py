#!/usr/bin/env python3
"""Export the marts the site needs to site-data/marts/<model>.json, deterministically.

Reads one JSON file per exported model from a source directory (a dbt output
directory, or the committed fixtures under tests/site-data/sample-marts/ when dbt
is skipped) and writes them to the output directory sorted deterministically, so
two runs produce byte-identical output. Also exports a whitelisted column subset
of fct_agent_runs so no internal or sensitive columns reach the site.
"""
import argparse
import json
import sys
from pathlib import Path

# Marts exported to their own JSON file, in a stable order.
EXPORTED_MODELS = (
    "rpt_run_rate",
    "agg_spend_weekly",
    "agg_spend_monthly",
    "agg_spend_by_issue",
    "agg_spend_by_model",
    "fct_forecast_vs_actual",
    "rpt_issue_target_compliance",
)

# Whitelisted fct_agent_runs columns for the site export.
AGENT_RUNS_COLUMNS = (
    "run_id",
    "issue",
    "pr",
    "model_id",
    "complexity",
    "risk",
    "work_type",
    "outcome",
    "gate_passed",
    "started_at_utc",
    "run_date",
    "requests",
    "tokens_in",
    "tokens_cached",
    "tokens_out",
    "tokens_reasoning",
    "predicted_cost_usd",
    "actual_cost_usd",
    "cost_variance_usd",
    "cache_hit_rate",
    "duration_s",
    "actions_minutes",
)


def load_json(path: Path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def sort_value(obj):
    """Return a sort key that is stable for arbitrary JSON values."""
    if isinstance(obj, list):
        return [sort_value(x) for x in obj]
    if isinstance(obj, dict):
        return {k: sort_value(v) for k, v in sorted(obj.items())}
    return obj


def normalize_rows(data):
    """Return a deterministic list of dict rows from JSON data."""
    if isinstance(data, list):
        rows = data
    elif isinstance(data, dict) and "rows" in data:
        rows = data["rows"]
    elif isinstance(data, dict):
        rows = [data]
    else:
        return []
    return [sort_value(r) for r in rows]


def whitelist_agent_runs(rows):
    out = []
    for row in rows:
        out.append({k: sort_value(row.get(k)) for k in AGENT_RUNS_COLUMNS if k in row})
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source",
        default="tests/site-data/sample-marts",
        help="Directory containing one JSON file per exported model.",
    )
    parser.add_argument(
        "--out",
        default="site-data/marts",
        help="Output directory for the exported JSON files.",
    )
    args = parser.parse_args()

    source = Path(args.source)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    for model in EXPORTED_MODELS:
        src = source / f"{model}.json"
        if not src.is_file():
            sys.stderr.write(f"ERROR: missing model file for export: {src}\n")
            sys.exit(1)
        rows = normalize_rows(load_json(src))
        rows.sort(key=lambda r: json.dumps(r, sort_keys=True))
        payload = {"model": model, "rows": rows}
        with open(out / f"{model}.json", "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
            fh.write("\n")

    agent_src = source / "fct_agent_runs.json"
    if agent_src.is_file():
        agent_rows = whitelist_agent_runs(normalize_rows(load_json(agent_src)))
        agent_rows.sort(key=lambda r: json.dumps(r, sort_keys=True))
        payload = {"model": "fct_agent_runs", "rows": agent_rows}
        with open(out / "fct_agent_runs.json", "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
            fh.write("\n")

    print(f"Exported {len(EXPORTED_MODELS)} marts to {out}")


if __name__ == "__main__":
    main()
