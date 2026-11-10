#!/bin/bash
# Rewrite only the factory-run block and Cost: line in a PR body from a run record.
set -euo pipefail

# Check arguments
if [ $# -ne 2 ]; then
  echo "Usage: $0 <pr_number> <run_id>" >&2
  exit 2
fi

pr_number="$1"
run_id="$2"

# Define paths using FACTORY_RUNS_DIR with default
FACTORY_RUNS_DIR="${FACTORY_RUNS_DIR:-factory/runs}"
run_record_path="$FACTORY_RUNS_DIR/$run_id.json"
temp_body_file=$(mktemp)

# Cleanup function
cleanup() {
  rm -f "$temp_body_file"
}
trap cleanup EXIT

# Check if run record exists
if [ ! -f "$run_record_path" ]; then
  echo "factory-run-body: run record not found: $run_record_path" >&2
  exit 2
fi

# Fetch current PR body
if ! gh pr view "$pr_number" --json body -q '.body' > "$temp_body_file"; then
  echo "factory-run-body: failed to fetch PR body" >&2
  exit 2
fi

# Check for factory-run markers using the correct markers from opencode-run-facts.sh
start_marker='<!-- factory-run:start -->'
end_marker='<!-- factory-run:end -->'

if ! grep -q "$start_marker" "$temp_body_file" || ! grep -q "$end_marker" "$temp_body_file"; then
  echo "factory-run-body: missing factory-run markers in PR body" >&2
  exit 2
fi

# Extract cost facts from run record using the schema from tests/run-records/pass-failed-no-pr.json
actual_cost_usd=$(jq -r '.actual_cost_usd' "$run_record_path")
cost_method=$(jq -r '.cost_method' "$run_record_path")

# Format the cost line to match the existing publish Cost: style
cost_line="Cost: \$${actual_cost_usd} on DeepInfra (factory run record; ${cost_method})"

# Generate the new factory-run block content
# We'll construct this based on the PR template structure
run_block_content=$(cat <<EOF
Run ID: $run_id
Workflow run: $(jq -r '.workflow_run_url' "$run_record_path")
Model: $(jq -r '.model' "$run_record_path")
Tokens in / cached / out: $(jq -r '.tokens_in' "$run_record_path") / $(jq -r '.tokens_cached' "$run_record_path") / $(jq -r '.tokens_out' "$run_record_path")
Predicted cost: \$$(jq -r '.predicted_cost_usd' "$run_record_path")
Actual cost: \$${actual_cost_usd}
Cost method: ${cost_method}
Key spend check: $(jq -r '.cost_check' "$run_record_path")
Actions minutes: $(jq -r '.actions_minutes' "$run_record_path")
Gate: $(jq -r 'if .gate and (.gate | type) == "object" then "passed: \(.gate | to_entries[] | select(.value == \"pass\") | .key) failed: \(.gate | to_entries[] | select(.value == \"fail\") | .key)" else (.gate | tostring) end' "$run_record_path")
Run record: $run_record_path
EOF
)

# Create a temporary file for the new body
new_body_file=$(mktemp)
trap 'rm -f "$temp_body_file" "$new_body_file"' EXIT

# Process the body line by line to replace only the factory-run block and Cost line
{
  in_run_block=false
  cost_line_found=false
  
  while IFS= read -r line; do
    # Check if we're entering the run block
    if [[ "$line" == "$start_marker" ]]; then
      echo "$line"
      in_run_block=true
      # Output the new run block content
      echo "$run_block_content"
      continue
    fi
    
    # Check if we're exiting the run block
    if [[ "$line" == "$end_marker" ]]; then
      in_run_block=false
      echo "$line"
      continue
    fi
    
    # Skip lines within the old run block
    if [[ "$in_run_block" == true ]]; then
      continue
    fi
    
    # Check if this is the Cost line and replace it
    if [[ "$line" == "Cost: "* ]]; then
      echo "$cost_line"
      cost_line_found=true
      continue
    fi
    
    # Output all other lines as-is
    echo "$line"
  done < "$temp_body_file"
  
  # If we never found the cost line, add it at the end
  if [[ "$cost_line_found" == false ]]; then
    echo "$cost_line"
  fi
} > "$new_body_file"

# Update the PR body
if ! gh pr edit "$pr_number" --body-file "$new_body_file"; then
  echo "factory-run-body: failed to update PR body" >&2
  exit 2
fi

echo "factory-run-body: successfully updated PR body with run facts"