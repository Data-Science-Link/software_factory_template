#!/usr/bin/env python3
"""Read factory/budget.yml, validate it, and print dbt vars as a JSON object.

The printed object is meant to be passed to `dbt build --vars`. Keys are dbt var
names mapped from the budget-file keys, mapping `monthly_usd` onto the existing
`deepinfra_monthly_budget_usd` var so nothing else must change, and emitting the
new `weekly_budget_usd` and `issue_target_usd`.
"""
import argparse
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write("ERROR: PyYAML is required (pip install -r requirements-factory.txt)\n")
    sys.exit(1)

REQUIRED_KEYS = (
    "monthly_usd",
    "weekly_usd",
    "issue_target_usd",
    "issue_cap_usd",
    "fixed_costs_monthly_usd",
    "actions_minutes_month",
    "warn_pct",
)

# Map budget-file keys onto dbt var names. Existing vars keep their names.
VAR_MAP = {
    "monthly_usd": "deepinfra_monthly_budget_usd",
    "weekly_usd": "weekly_budget_usd",
    "issue_target_usd": "issue_target_usd",
    "issue_cap_usd": "issue_cap_usd",
    "fixed_costs_monthly_usd": "fixed_costs_monthly_usd",
    "actions_minutes_month": "actions_minutes_month",
    "warn_pct": "warn_pct",
}


def load_budget(path: Path) -> dict:
    if not path.is_file():
        sys.stderr.write(f"ERROR: budget file not found: {path}\n")
        sys.exit(1)
    with open(path, encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    if not isinstance(data, dict):
        sys.stderr.write(f"ERROR: budget file must contain a mapping, got {type(data).__name__}\n")
        sys.exit(1)
    return data


def validate(data: dict) -> None:
    missing = [k for k in REQUIRED_KEYS if k not in data]
    if missing:
        sys.stderr.write(
            "ERROR: budget file is missing required key(s): " + ", ".join(missing) + "\n"
        )
        sys.exit(1)

    for key in REQUIRED_KEYS:
        value = data[key]
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            sys.stderr.write(
                f"ERROR: budget key '{key}' must be a number, got {value!r}\n"
            )
            sys.exit(1)
        if value <= 0:
            sys.stderr.write(
                f"ERROR: budget key '{key}' must be positive, got {value}\n"
            )
            sys.exit(1)

    if data["weekly_usd"] > data["monthly_usd"]:
        sys.stderr.write(
            "ERROR: weekly budget (weekly_usd) cannot exceed the monthly budget "
            f"(monthly_usd): {data['weekly_usd']} > {data['monthly_usd']}\n"
        )
        sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--budget",
        default=str(Path(__file__).resolve().parent.parent / "factory" / "budget.yml"),
        help="Path to the budget YAML file (default: factory/budget.yml).",
    )
    args = parser.parse_args()

    path = Path(args.budget)
    data = load_budget(path)
    validate(data)
    vars_out = {VAR_MAP[key]: data[key] for key in REQUIRED_KEYS}
    json.dump(vars_out, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
