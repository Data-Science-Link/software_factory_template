#!/usr/bin/env python3
"""Validate factory run records against the JSON Schema and business rules."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path

import jsonschema
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / ".factory/schemas/run-record.schema.json"
UTC_Z = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$")
ISSUE_JSON_FENCE = re.compile(r"```json\s*\n(.*?)```", re.DOTALL | re.IGNORECASE)
COST_TOLERANCE_USD = 0.0001


def load_schema() -> dict:
    with SCHEMA_PATH.open(encoding="utf-8") as f:
        return json.load(f)


def parse_record_text(text: str, source: str) -> dict:
    stripped = text.strip()
    if stripped.startswith("{"):
        return json.loads(stripped)
    match = ISSUE_JSON_FENCE.search(text)
    if not match:
        raise ValueError(f"{source}: no JSON object or ```json fenced block found")
    return json.loads(match.group(1))


def load_record(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    return parse_record_text(text, str(path))


def parse_utc_z(value: str) -> datetime:
    body = value[:-1]
    if "." in body:
        return datetime.strptime(body, "%Y-%m-%dT%H:%M:%S.%f")
    return datetime.strptime(body, "%Y-%m-%dT%H:%M:%S")


def utc_timestamp_ok(value: str) -> bool:
    if not UTC_Z.match(value):
        return False
    try:
        parse_utc_z(value)
    except ValueError:
        return False
    return True


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


def cost_from_tokens(record: dict) -> float:
    return cost_from_usage(
        record["tokens_in"],
        record["tokens_cached"],
        record["tokens_out"],
        record["price_in_per_mtok"],
        record["price_cached_per_mtok"],
        record["price_out_per_mtok"],
    )


def validate_business_rules(record: dict, path: Path | None) -> list[str]:
    errors: list[str] = []
    run_id = record.get("run_id")
    if path is not None and path.suffix == ".json" and run_id:
        under_runs = "factory/runs" in path.as_posix()
        named_like_run = path.name.startswith("gha-") and path.name.endswith(".json")
        if (under_runs or named_like_run) and path.name != f"{run_id}.json":
            errors.append(f"run_id {run_id!r} does not match file name {path.name!r}")

    if record.get("tokens_cached", 0) > record.get("tokens_in", 0):
        errors.append("tokens_cached must be <= tokens_in")

    if record.get("tokens_reasoning", 0) > record.get("tokens_out", 0):
        errors.append("tokens_reasoning must be <= tokens_out")

    for field in ("started_at", "ended_at"):
        ts = record.get(field, "")
        if not utc_timestamp_ok(ts):
            errors.append(f"{field} must be UTC ISO 8601 ending in Z (got {ts!r})")

    if utc_timestamp_ok(record.get("started_at", "")) and utc_timestamp_ok(
        record.get("ended_at", "")
    ):
        if parse_utc_z(record["ended_at"]) < parse_utc_z(record["started_at"]):
            errors.append("ended_at must be >= started_at")

    if record.get("cost_method") == "usage_x_price_table":
        expected = cost_from_tokens(record)
        actual = record.get("actual_cost_usd", 0)
        if abs(expected - actual) > COST_TOLERANCE_USD:
            errors.append(
                "actual_cost_usd must match tokens × record prices within "
                f"${COST_TOLERANCE_USD} when cost_method is usage_x_price_table "
                f"(expected {expected:.6f}, got {actual})"
            )

    for idx, step in enumerate(record.get("steps") or []):
        if step.get("tokens_cached", 0) > step.get("tokens_in", 0):
            errors.append(f"steps[{idx}]: tokens_cached must be <= tokens_in")
        if step.get("tokens_reasoning", 0) > step.get("tokens_out", 0):
            errors.append(f"steps[{idx}]: tokens_reasoning must be <= tokens_out")
        if step.get("cost_method") == "usage_x_price_table":
            expected = cost_from_usage(
                step["tokens_in"],
                step["tokens_cached"],
                step["tokens_out"],
                step["price_in_per_mtok"],
                step["price_cached_per_mtok"],
                step["price_out_per_mtok"],
            )
            actual = step.get("actual_cost_usd", 0)
            if abs(expected - actual) > COST_TOLERANCE_USD:
                errors.append(
                    f"steps[{idx}]: actual_cost_usd must match step tokens × "
                    f"step prices within ${COST_TOLERANCE_USD} "
                    f"(expected {expected:.6f}, got {actual})"
                )

    return errors


def validate_record(record: dict, path: Path | None) -> list[str]:
    schema = load_schema()
    validator = Draft202012Validator(schema)
    errors: list[str] = []
    for err in sorted(validator.iter_errors(record), key=lambda e: list(e.path)):
        loc = ".".join(str(p) for p in err.path) or "(root)"
        errors.append(f"schema: {loc}: {err.message}")
    errors.extend(validate_business_rules(record, path))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths",
        nargs="+",
        type=Path,
        help="Run record .json files or issue comments containing a fenced json block",
    )
    args = parser.parse_args()

    exit_code = 0
    for path in args.paths:
        try:
            record = load_record(path)
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            print(f"ERROR {path}: {exc}", file=sys.stderr)
            exit_code = 1
            continue

        path_for_name = path if path.suffix == ".json" else None
        errors = validate_record(record, path_for_name)
        if errors:
            exit_code = 1
            print(f"INVALID {path}:", file=sys.stderr)
            for msg in errors:
                print(f"  - {msg}", file=sys.stderr)
        else:
            print(f"OK {path}")

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
