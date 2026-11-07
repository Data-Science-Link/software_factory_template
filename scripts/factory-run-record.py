#!/usr/bin/env python3
"""Build a factory run record from inputs and price data."""

import argparse
import decimal
import importlib.util
import json
import os
import sys
from datetime import datetime
from pathlib import Path

import yaml

# Set precision for decimal operations
decimal.getcontext().prec = 10


def parse_utc_z(value):
    """Parse a UTC timestamp ending in Z."""
    body = value[:-1]
    if "." in body:
        return datetime.strptime(body, "%Y-%m-%dT%H:%M:%S.%f")
    return datetime.strptime(body, "%Y-%m-%dT%H:%M:%S")


def utc_timestamp_ok(value):
    """Check if a timestamp is a valid UTC Z timestamp."""
    if not value.endswith("Z"):
        return False
    try:
        parse_utc_z(value)
        return True
    except ValueError:
        return False


def load_cost_function():
    """Load the cost_from_usage function from factory-validate-run.py."""
    spec = importlib.util.spec_from_file_location(
        "factory_validate_run", "scripts/factory-validate-run.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.cost_from_usage


def load_models_config(models_path):
    """Load the models configuration from YAML."""
    with open(models_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def find_model_prices(model_id, models_config):
    """Find the prices for a specific model."""
    for model in models_config.get("models", []):
        if model.get("id") == model_id:
            return {
                "price_in_per_mtok": model["price_in_per_mtok"],
                "price_cached_per_mtok": model["price_cached_per_mtok"],
                "price_out_per_mtok": model["price_out_per_mtok"],
            }
    return None


def compute_cost_from_usage(
    tokens_in,
    tokens_cached,
    tokens_out,
    price_in_per_mtok,
    price_cached_per_mtok,
    price_out_per_mtok,
):
    """Compute cost from usage and prices."""
    cost_func = load_cost_function()
    return cost_func(
        tokens_in,
        tokens_cached,
        tokens_out,
        price_in_per_mtok,
        price_cached_per_mtok,
        price_out_per_mtok,
    )


def main():
    """Main function to build the run record."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--artifact-dir",
        required=True,
        help="OC_ARTIFACT_DIR containing run-start.json, spec.md, usage.json, key-spend.json, gate.json",
    )
    args = parser.parse_args()

    artifact_dir = Path(args.artifact_dir)
    if not artifact_dir.is_dir():
        print("factory-run-record: OC_ARTIFACT_DIR is not a directory", file=sys.stderr)
        return 2

    # Load required environment variables
    required_env_vars = [
        "OC_ARTIFACT_DIR",
        "GITHUB_REPOSITORY",
        "GITHUB_RUN_ID",
        "GITHUB_RUN_ATTEMPT",
        "OC_STARTED_AT",
        "OC_ENDED_AT",
        "OC_BASE_SHA",
        "OC_HEAD_SHA",
        "OC_OUTCOME",
    ]

    for var in required_env_vars:
        if not os.environ.get(var):
            print(f"factory-run-record: missing required env var {var}", file=sys.stderr)
            return 2

    # Optional environment variables with defaults
    oc_pr_number = os.environ.get("OC_PR_NUMBER")
    oc_trigger_url = os.environ.get("OC_TRIGGER_URL")
    oc_spec_link = os.environ.get("OC_SPEC_LINK")
    github_actor = os.environ.get("GITHUB_ACTOR", "unknown")
    github_event_name = os.environ.get("GITHUB_EVENT_NAME", "issue_comment")
    opencode_version = os.environ.get("OPENCODE_VERSION", "unknown")
    oc_runner = os.environ.get("OC_RUNNER", "ubuntu-latest")

    # Validate timestamps
    if not utc_timestamp_ok(os.environ["OC_STARTED_AT"]):
        print("factory-run-record: OC_STARTED_AT must be UTC ISO 8601 ending in Z", file=sys.stderr)
        return 2

    if not utc_timestamp_ok(os.environ["OC_ENDED_AT"]):
        print("factory-run-record: OC_ENDED_AT must be UTC ISO 8601 ending in Z", file=sys.stderr)
        return 2

    # Parse timestamps
    started_at = parse_utc_z(os.environ["OC_STARTED_AT"])
    ended_at = parse_utc_z(os.environ["OC_ENDED_AT"])
    duration_s = int((ended_at - started_at).total_seconds())
    actions_minutes = (duration_s + 59) // 60  # Ceiling division

    # Validate OC_OUTCOME
    valid_outcomes = [
        "pr_opened",
        "pr_updated",
        "no_changes",
        "failed",
        "cap_exceeded",
        "gate_failed",
        "cancelled",
    ]
    if os.environ["OC_OUTCOME"] not in valid_outcomes:
        print(f"factory-run-record: OC_OUTCOME must be one of {valid_outcomes}", file=sys.stderr)
        return 2

    # Validate SHAs
    if len(os.environ["OC_BASE_SHA"]) != 40 or not all(
        c in "0123456789abcdef" for c in os.environ["OC_BASE_SHA"]
    ):
        print("factory-run-record: OC_BASE_SHA must be a 40-character hex SHA", file=sys.stderr)
        return 2

    if len(os.environ["OC_HEAD_SHA"]) != 40 or not all(
        c in "0123456789abcdef" for c in os.environ["OC_HEAD_SHA"]
    ):
        print("factory-run-record: OC_HEAD_SHA must be a 40-character hex SHA", file=sys.stderr)
        return 2

    # Initialize fixed fields
    run_id = f"gha-{os.environ['GITHUB_RUN_ID']}-{os.environ['GITHUB_RUN_ATTEMPT']}"
    repo = os.environ["GITHUB_REPOSITORY"]
    workflow_run_url = f"https://github.com/{repo}/actions/runs/{os.environ['GITHUB_RUN_ID']}"

    # Initialize defaults for degraded modes
    model = "unknown"
    predicted_cost_usd = 0.0
    budget_cap_usd = 0.0
    prior_spend_usd = 0.0
    price_in_per_mtok = 0.0
    price_cached_per_mtok = 0.0
    price_out_per_mtok = 0.0
    price_table_version = "unknown"
    requests = 0
    tokens_in = 0
    tokens_cached = 0
    tokens_out = 0
    tokens_reasoning = 0
    usage_notes = ""

    # Load start state if available
    start_state_trusted = False
    start_state = {}
    start_path = artifact_dir / "run-start.json"
    if start_path.exists():
        try:
            with open(start_path, "r", encoding="utf-8") as f:
                start_state = json.load(f)
            if not isinstance(start_state, dict):
                start_state = {}
        except (OSError, json.JSONDecodeError):
            start_state = {}

        # Check if start state is trusted
        if start_state.get("run_id") == run_id:
            start_state_trusted = True
            model = start_state.get("model_id", "unknown")
            predicted_cost_usd = start_state.get("predicted_cost_usd", 0.0)
            budget_cap_usd = start_state.get("budget.cap_usd", 0.0)
            prior_spend_usd = start_state.get("prior_spend_usd", 0.0)
        else:
            usage_notes += "run_id mismatch; "

    # Load spec if available
    spec_path = artifact_dir / "spec.md"
    if not spec_path.exists():
        print("factory-run-record: spec.md not found in OC_ARTIFACT_DIR", file=sys.stderr)
        return 2

    try:
        with open(spec_path, "r", encoding="utf-8") as f:
            spec_content = f.read()
    except OSError:
        print("factory-run-record: failed to read spec.md", file=sys.stderr)
        return 2

    # Parse spec front matter
    spec_lines = spec_content.split("\n")
    if not spec_lines or spec_lines[0] != "<!-- factory-spec v1 -->":
        print("factory-run-record: spec.md missing factory-spec header", file=sys.stderr)
        return 2

    # Find the YAML front matter
    yaml_start = -1
    yaml_end = -1
    for i, line in enumerate(spec_lines[1:], 1):
        if line.strip() == "---":
            if yaml_start == -1:
                yaml_start = i + 1
            else:
                yaml_end = i
                break

    if yaml_start == -1 or yaml_end == -1:
        print("factory-run-record: spec.md missing YAML front matter", file=sys.stderr)
        return 2

    try:
        spec_data = yaml.safe_load("\n".join(spec_lines[yaml_start:yaml_end]))
    except yaml.YAMLError:
        print("factory-run-record: spec.md has invalid YAML front matter", file=sys.stderr)
        return 2

    if not isinstance(spec_data, dict):
        print("factory-run-record: spec.md YAML front matter is not a dict", file=sys.stderr)
        return 2

    # Validate required spec fields
    required_spec_fields = ["issue", "complexity", "risk", "work_type"]
    for field in required_spec_fields:
        if field not in spec_data:
            print(f"factory-run-record: spec.md missing required field {field}", file=sys.stderr)
            return 2

    # Validate spec fields
    if not isinstance(spec_data["issue"], int) or spec_data["issue"] < 1:
        print("factory-run-record: spec.md issue must be a positive integer", file=sys.stderr)
        return 2

    valid_complexities = ["simple", "standard", "complex"]
    if spec_data["complexity"] not in valid_complexities:
        print(
            f"factory-run-record: spec.md complexity must be one of {valid_complexities}",
            file=sys.stderr,
        )
        return 2

    valid_risks = ["trivial", "normal", "high"]
    if spec_data["risk"] not in valid_risks:
        print(
            f"factory-run-record: spec.md risk must be one of {valid_risks}",
            file=sys.stderr,
        )
        return 2

    valid_work_types = ["code", "docs", "spec", "review", "data"]
    if spec_data["work_type"] not in valid_work_types:
        print(
            f"factory-run-record: spec.md work_type must be one of {valid_work_types}",
            file=sys.stderr,
        )
        return 2

    issue = spec_data["issue"]
    complexity = spec_data["complexity"]
    risk = spec_data["risk"]
    work_type = spec_data["work_type"]

    # Load usage if available
    usage_path = artifact_dir / "usage.json"
    usage_data = None  # Initialize to None for proper handling of missing/invalid usage
    if usage_path.exists():
        try:
            with open(usage_path, "r", encoding="utf-8") as f:
                usage_data = json.load(f)
            if not isinstance(usage_data, dict):
                usage_data = None
        except (OSError, json.JSONDecodeError):
            usage_data = None

        if usage_data:
            requests = usage_data.get("requests", 0)
            tokens_in = usage_data.get("tokens_in", 0)
            tokens_cached = usage_data.get("tokens_cached", 0)
            tokens_out = usage_data.get("tokens_out", 0)
            tokens_reasoning = usage_data.get("tokens_reasoning", 0)
            opencode_cost = usage_data.get("opencode_cost_usd")
            if opencode_cost is not None:
                usage_notes += f"opencode_cost_usd {opencode_cost}; "

    # Load key spend if available
    key_spend_available = False
    key_spend_delta_usd = None
    key_spend_data = {}
    key_spend_path = artifact_dir / "key-spend.json"
    if key_spend_path.exists():
        try:
            with open(key_spend_path, "r", encoding="utf-8") as f:
                key_spend_data = json.load(f)
            if not isinstance(key_spend_data, dict):
                key_spend_data = {}
        except (OSError, json.JSONDecodeError):
            key_spend_data = {}

        # Validate key spend data - reject bool values for start_usd/end_usd
        start_usd = key_spend_data.get("start_usd")
        end_usd = key_spend_data.get("end_usd")
        concurrent = key_spend_data.get("concurrent")

        # Check that start_usd and end_usd are numbers (int or float) but not bool
        if (
            isinstance(start_usd, (int, float)) and not isinstance(start_usd, bool)
            and isinstance(end_usd, (int, float)) and not isinstance(end_usd, bool)
            and isinstance(concurrent, bool)
            and start_usd >= 0
            and end_usd >= 0
        ):
            if concurrent:
                key_spend_available = False
            elif end_usd >= start_usd:
                key_spend_available = True
                key_spend_delta_usd = float(
                    decimal.Decimal(str(end_usd - start_usd)).quantize(
                        decimal.Decimal("0.000001")
                    )
                )
            # else: key_spend_available remains False

    # Load gate data if available
    gate_path = artifact_dir / "gate.json"
    gate_data = {}
    if gate_path.exists():
        try:
            with open(gate_path, "r", encoding="utf-8") as f:
                gate_data = json.load(f)
            if not isinstance(gate_data, dict):
                gate_data = {}
        except (OSError, json.JSONDecodeError):
            gate_data = {}

    # Initialize gate fields with defaults
    gate_defaults = {
        "gitleaks": "skip",
        "run_record_valid": "skip",
        "cost_recorded": "skip",
        "pr_template": "skip",
        "pr_check": "skip",
        "budget_cap": "skip",
        "no_workflow_changes": "skip",
        "spec_present": "skip",
    }

    # Override with actual gate data
    gate = gate_defaults.copy()
    gate.update({k: v for k, v in gate_data.items() if k in gate_defaults})

    gate_passed = all(v == "pass" for v in gate.values())

    # Determine model prices if start state is trusted
    if start_state_trusted and model != "unknown":
        models_config = load_models_config(".factory/models.yaml")
        price_table_version = models_config.get("price_table_version", "unknown")
        model_prices = find_model_prices(model, models_config)
        if model_prices:
            price_in_per_mtok = model_prices["price_in_per_mtok"]
            price_cached_per_mtok = model_prices["price_cached_per_mtok"]
            price_out_per_mtok = model_prices["price_out_per_mtok"]

    # Compute cost and determine cost method
    actual_cost_usd = 0.0
    cost_method = "not_measured"
    cost_check = "skipped_unavailable"
    cost_notes = ""

    if start_state_trusted and usage_data:
        # Compute cost from usage and prices
        computed_cost = compute_cost_from_usage(
            tokens_in,
            tokens_cached,
            tokens_out,
            price_in_per_mtok,
            price_cached_per_mtok,
            price_out_per_mtok,
        )

        if key_spend_available and key_spend_delta_usd is not None:
            # Compare computed cost with key spend delta
            delta = key_spend_delta_usd
            computed_decimal = decimal.Decimal(str(computed_cost))
            delta_decimal = decimal.Decimal(str(delta))
            diff = abs(computed_decimal - delta_decimal)
            threshold = max(
                decimal.Decimal("0.10") * computed_decimal, decimal.Decimal("0.005")
            )

            if diff <= threshold:
                cost_check = "match"
                cost_method = "usage_x_price_table"
                actual_cost_usd = float(
                    computed_decimal.quantize(decimal.Decimal("0.000001"))
                )
            else:
                if delta > computed_cost:
                    cost_check = "mismatch"
                    cost_method = "key_spend_delta"
                    actual_cost_usd = delta
                    cost_notes = (
                        f"key_spend_delta_usd {delta}; computed {computed_cost}; "
                        "unrecorded calls (OpenCode title generation) or other key use"
                    )
                else:
                    cost_check = "mismatch"
                    cost_method = "usage_x_price_table"
                    actual_cost_usd = float(
                        computed_decimal.quantize(decimal.Decimal("0.000001"))
                    )
        else:
            # No key spend available
            cost_method = "usage_x_price_table"
            actual_cost_usd = float(
                decimal.Decimal(str(computed_cost)).quantize(decimal.Decimal("0.000001"))
            )
            cost_check = "skipped_unavailable"
    else:
        # Start state not trusted or no usage data
        if key_spend_available and key_spend_delta_usd is not None:
            cost_method = "key_spend_delta"
            actual_cost_usd = key_spend_delta_usd
            cost_check = "skipped_unavailable"
        else:
            cost_method = "not_measured"
            actual_cost_usd = 0.0
            cost_check = "skipped_unavailable"

    # Handle concurrent key spend
    if key_spend_data.get("concurrent") is True:
        cost_check = "skipped_concurrent"
        key_spend_delta_usd = None

    # Calculate issue spend to date
    issue_spend_to_date_usd = float(
        decimal.Decimal(str(prior_spend_usd + actual_cost_usd)).quantize(
            decimal.Decimal("0.000001")
        )
    )

    # Build notes
    notes_parts = []
    if usage_notes:
        notes_parts.append(usage_notes.rstrip("; "))
    if cost_notes:
        notes_parts.append(cost_notes)
    if not start_state_trusted and start_state:
        notes_parts.append("run start state missing or run_id mismatch")
    if not notes_parts:
        notes_parts.append("ok")

    notes = "; ".join(notes_parts)

    # Determine trigger URL and spec link
    repo_url = f"https://github.com/{repo}"
    trigger_url = oc_trigger_url or f"{repo_url}/issues/{issue}"
    spec_link = oc_spec_link or f"{repo_url}/issues/{issue}"

    # Build the record
    record = {
        "schema_version": 1,
        "run_id": run_id,
        "repo": repo,
        "issue": issue,
        "issues": [issue],
        "pr": int(oc_pr_number) if oc_pr_number and oc_pr_number.isdigit() else None,
        "spec_path": f"factory/specs/issue-{issue}.md",
        "spec_link": spec_link,
        "trigger": github_event_name,
        "triggered_by": github_actor,
        "trigger_url": trigger_url,
        "workflow_run_url": workflow_run_url,
        "harness": "opencode-github-action",
        "harness_version": opencode_version,
        "provider": "deepinfra",
        "model": model,
        "escalated_from": None,
        "complexity": complexity,
        "risk": risk,
        "work_type": work_type,
        "price_table_version": price_table_version,
        "price_in_per_mtok": price_in_per_mtok,
        "price_cached_per_mtok": price_cached_per_mtok,
        "price_out_per_mtok": price_out_per_mtok,
        "requests": requests,
        "tokens_in": tokens_in,
        "tokens_cached": tokens_cached,
        "tokens_out": tokens_out,
        "tokens_reasoning": tokens_reasoning,
        "predicted_cost_usd": predicted_cost_usd,
        "actual_cost_usd": actual_cost_usd,
        "cost_method": cost_method,
        "key_spend_delta_usd": key_spend_delta_usd,
        "cost_check": cost_check,
        "budget_cap_usd": budget_cap_usd,
        "issue_spend_to_date_usd": issue_spend_to_date_usd,
        "started_at": os.environ["OC_STARTED_AT"],
        "ended_at": os.environ["OC_ENDED_AT"],
        "duration_s": duration_s,
        "actions_minutes": actions_minutes,
        "runner": oc_runner,
        "base_sha": os.environ["OC_BASE_SHA"],
        "head_sha": os.environ["OC_HEAD_SHA"],
        "outcome": os.environ["OC_OUTCOME"],
        "gate": gate,
        "gate_passed": gate_passed,
        "notes": notes,
    }

    # Print the record as sorted JSON
    print(json.dumps(record, indent=2, sort_keys=True))


if __name__ == "__main__":
    exit_code = main()
    sys.exit(exit_code)