#!/usr/bin/env python3
"""Export dbt mart tables from the local DuckDB database to JSON row files.

Writes one JSON file per mart under --out (a list of row objects per file), matching
the shape of tests/site-data/sample-marts/*.json. That directory is the input to
scripts/factory-site-data.py in live site builds.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

# Keep in sync with scripts/factory-site-data.py EXPORTED_MODELS + fct_agent_runs.
TABLES = (
    "rpt_run_rate",
    "agg_spend_weekly",
    "agg_spend_monthly",
    "agg_spend_by_issue",
    "agg_spend_by_model",
    "fct_forecast_vs_actual",
    "rpt_issue_target_compliance",
    "fct_agent_runs",
)


def json_value(value):
    if value is None:
        return None
    if isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        return value
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    return str(value)


def row_to_dict(columns, row):
    return {col: json_value(val) for col, val in zip(columns, row)}


def export_table(con, table: str, out_dir: Path) -> int:
    try:
        rel = con.sql(f"select * from {table}")
    except Exception as exc:  # noqa: BLE001 — surface duckdb errors to stderr
        sys.stderr.write(f"ERROR: failed to read mart {table}: {exc}\n")
        raise SystemExit(1) from exc
    columns = [d[0] for d in rel.description]
    rows = [row_to_dict(columns, row) for row in rel.fetchall()]
    out_path = out_dir / f"{table}.json"
    with out_path.open("w", encoding="utf-8") as fh:
        json.dump(rows, fh, indent=2, sort_keys=True)
        fh.write("\n")
    return len(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--db",
        default="factory/dbt/target/factory.duckdb",
        help="Path to the DuckDB database file produced by dbt build.",
    )
    parser.add_argument(
        "--out",
        default="site-data/dbt-marts",
        help="Directory for per-mart JSON row files.",
    )
    args = parser.parse_args()

    db_path = Path(args.db)
    if not db_path.is_file():
        sys.stderr.write(f"ERROR: DuckDB database not found: {db_path}\n")
        sys.stderr.write("(run dbt build in factory/dbt before exporting marts)\n")
        return 1

    try:
        import duckdb
    except ImportError:
        sys.stderr.write("ERROR: duckdb is not installed; pip install -r factory/dbt/requirements-dbt.txt\n")
        return 1

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    con = duckdb.connect(str(db_path), read_only=True)
    try:
        total = 0
        for table in TABLES:
            count = export_table(con, table, out_dir)
            dest = out_dir / f"{table}.json"
            print(f"exported {table}: {count} rows -> {dest}")
            total += count
    finally:
        con.close()

    print(f"Exported {len(TABLES)} marts ({total} rows) to {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())