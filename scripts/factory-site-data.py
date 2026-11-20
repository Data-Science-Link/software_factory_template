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

# Optional CFO marts: exported when present in --source, else derived from fct_agent_runs.
OPTIONAL_DERIVED_MARTS = (
    "mart_spend_by_work_type",
)

# Whitelisted fct_agent_runs columns for the site export.
AGENT_RUNS_COLUMNS = (
    "run_id",
    "issue",
    "pr",
    "harness",
    "provider",
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


def _normalize_work_type(raw):
    if raw is None:
        return "unknown"
    text = str(raw).strip().lower()
    return text if text else "unknown"


def compute_mart_spend_by_work_type(agent_rows):
    """Mirror mart_spend_by_work_type.sql for site export when dbt JSON is absent."""
    groups = {}
    for row in agent_rows:
        if not isinstance(row, dict):
            continue
        wt = _normalize_work_type(row.get("work_type"))
        bucket = groups.setdefault(
            wt,
            {
                "run_count": 0,
                "pass_count": 0,
                "total_actual_cost_usd": 0.0,
                "total_tokens_in": 0,
                "total_tokens_cached": 0,
                "total_tokens_out": 0,
                "total_actions_minutes": 0,
            },
        )
        bucket["run_count"] += 1
        if row.get("gate_passed"):
            bucket["pass_count"] += 1
        bucket["total_actual_cost_usd"] += float(row.get("actual_cost_usd") or 0)
        bucket["total_tokens_in"] += int(row.get("tokens_in") or 0)
        bucket["total_tokens_cached"] += int(row.get("tokens_cached") or 0)
        bucket["total_tokens_out"] += int(row.get("tokens_out") or 0)
        bucket["total_actions_minutes"] += int(row.get("actions_minutes") or 0)

    spend_total = sum(g["total_actual_cost_usd"] for g in groups.values())
    out = []
    for work_type, g in groups.items():
        run_count = g["run_count"]
        pass_rate_pct = (
            round(g["pass_count"] / run_count * 100.0, 6) if run_count else None
        )
        avg_cost_usd = (
            g["total_actual_cost_usd"] / run_count if run_count else None
        )
        if spend_total > 0:
            cost_share_pct = round(
                g["total_actual_cost_usd"] / spend_total * 100.0, 6
            )
        else:
            cost_share_pct = 0.0
        out.append(
            sort_value(
                {
                    "work_type": work_type,
                    "run_count": run_count,
                    "pass_count": g["pass_count"],
                    "pass_rate_pct": pass_rate_pct,
                    "total_actual_cost_usd": g["total_actual_cost_usd"],
                    "avg_cost_usd": avg_cost_usd,
                    "cost_share_pct": cost_share_pct,
                    "total_tokens_in": g["total_tokens_in"],
                    "total_tokens_cached": g["total_tokens_cached"],
                    "total_tokens_out": g["total_tokens_out"],
                    "total_actions_minutes": g["total_actions_minutes"],
                }
            )
        )

    out.sort(
        key=lambda r: (
            -float(r.get("total_actual_cost_usd") or 0),
            -int(r.get("run_count") or 0),
            str(r.get("work_type", "")),
        )
    )
    return out


def _write_mart_payload(out: Path, model: str, rows) -> None:
    payload = {"model": model, "rows": rows}
    with open(out / f"{model}.json", "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
        fh.write("\n")


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
    agent_rows = []
    if agent_src.is_file():
        agent_rows = whitelist_agent_runs(normalize_rows(load_json(agent_src)))
        agent_rows.sort(key=lambda r: json.dumps(r, sort_keys=True))
        _write_mart_payload(out, "fct_agent_runs", agent_rows)

    for model in OPTIONAL_DERIVED_MARTS:
        src = source / f"{model}.json"
        if src.is_file():
            rows = normalize_rows(load_json(src))
        elif model == "mart_spend_by_work_type":
            rows = compute_mart_spend_by_work_type(agent_rows)
        else:
            rows = []
        rows = [sort_value(r) for r in rows]
        rows.sort(key=lambda r: json.dumps(r, sort_keys=True))
        _write_mart_payload(out, model, rows)

    print(f"Exported {len(EXPORTED_MODELS)} marts to {out}")


if __name__ == "__main__":
    main()
