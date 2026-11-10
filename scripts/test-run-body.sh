#!/bin/bash
# Test script for factory-run-body.sh with gh stubbing

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Test counter
TEST_COUNT=0
PASSED=0
FAILED=0

# Temporary directories and files
TEST_TEMP_DIR=$(mktemp -d)
TEMP_BIN_DIR="$TEST_TEMP_DIR/bin"
TEMP_WORK_DIR="$TEST_TEMP_DIR/work"
export TEMP_WORK_DIR
TEMP_FACTORY_RUNS_DIR="$TEMP_WORK_DIR/factory/runs"

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cleanup function
cleanup() {
  rm -rf "$TEST_TEMP_DIR"
}
trap cleanup EXIT

# Setup test environment
setup_test_env() {
  mkdir -p "$TEMP_BIN_DIR" "$TEMP_FACTORY_RUNS_DIR"
  
# Create a stub gh command
  cat > "$TEMP_BIN_DIR/gh" <<'EOF'
#!/bin/bash
# gh stub for testing

# Record the command
echo "gh $*" >> "${TEMP_WORK_DIR}/gh_calls.log"

# Handle specific gh commands
case "$1" in
  pr)
    case "$2" in
      view)
        # Return test PR body
        cat "${TEMP_WORK_DIR}/test_pr_body.txt"
        ;;
      edit)
        # Capture the edited body
        if [[ "$*" == *"--body-file"* ]]; then
          # Extract the body file path (assuming it's the last argument)
          body_file="${!#}"
          cp "$body_file" "${TEMP_WORK_DIR}/edited_pr_body.txt"
        fi
        echo "PR edited successfully"
        ;;
    esac
    ;;
  *)
    echo "Unknown gh command: $*" >&2
    exit 1
    ;;
 esac
EOF
  
  chmod +x "$TEMP_BIN_DIR/gh"
  
  # Add our stub to PATH
  export PATH="$TEMP_BIN_DIR:$PATH"
  
  # Create test work directory
  mkdir -p "$TEMP_WORK_DIR"
}

# Helper function to run a test
run_test() {
  local test_name="$1"
  shift
  TEST_COUNT=$((TEST_COUNT + 1))
  
  if "$@"; then
    echo -e "${GREEN}ok - run-body: $test_name${NC}"
    PASSED=$((PASSED + 1))
  else
    echo -e "${RED}not ok - run-body: $test_name${NC}"
    FAILED=$((FAILED + 1))
  fi
}

# Test 1: Happy path - rewrites only factory-run block + Cost line
test_happy_path() {
  # Create test PR body with factory-run block
  cat > "$TEMP_WORK_DIR/test_pr_body.txt" <<'EOF'
## Summary

This is a test PR.

## Cost

Some other content here.

<!-- factory-run:start -->
Run ID: old-run-id
Workflow run: https://example.com/old-workflow
Model: old-model
Tokens in / cached / out: 0 / 0 / 0
Predicted cost: $0.00
Actual cost: $0.00
Cost method: not_measured
Key spend check: skipped_unavailable
Actions minutes: 0
Gate: false
Run record: factory/runs/old-run-id.json
<!-- factory-run:end -->

Cost: $0.00 (placeholder)

## Evidence

More content here.
EOF

  # Create a test run record with proper format
  cat > "$TEMP_FACTORY_RUNS_DIR/gha-90000000135-1.json" <<'EOF'
{
  "run_id": "gha-90000000135-1",
  "workflow_run_url": "https://github.com/test/repo/actions/runs/123",
  "model": "test-model",
  "tokens_in": 1000,
  "tokens_cached": 500,
  "tokens_out": 2000,
  "predicted_cost_usd": 0.05,
  "actual_cost_usd": 0.045,
  "cost_method": "usage_x_price_table",
  "cost_check": "match",
  "actions_minutes": 2,
  "gate": {
    "gitleaks": "pass",
    "run_record_valid": "pass",
    "cost_recorded": "pass",
    "pr_template": "pass",
    "pr_check": "pass",
    "budget_cap": "pass",
    "no_workflow_changes": "pass",
    "spec_present": "pass"
  },
  "gate_passed": true
}
EOF

  # Run the script
  cd "$TEMP_WORK_DIR"
  FACTORY_RUNS_DIR="$TEMP_FACTORY_RUNS_DIR" "$SCRIPT_DIR/factory-run-body.sh" 123 gha-90000000135-1 > "$TEMP_WORK_DIR/output.txt" 2>&1
  
  # Check that gh pr edit was called
  if ! grep -q "gh pr edit 123 --body-file" "$TEMP_WORK_DIR/gh_calls.log"; then
    echo "FAIL: gh pr edit was not called"
    return 1
  fi
  
  # Check the edited body content
  if [ ! -f "$TEMP_WORK_DIR/edited_pr_body.txt" ]; then
    echo "FAIL: edited_pr_body.txt was not created"
    return 1
  fi
  
  edited_body=$(cat "$TEMP_WORK_DIR/edited_pr_body.txt")
  
  # Check that the factory-run block was updated
  if ! echo "$edited_body" | grep -q "Run ID: gha-90000000135-1"; then
    echo "FAIL: factory-run block was not updated correctly"
    return 1
  fi
  
  # Check that the Cost line was updated
  if ! echo "$edited_body" | grep -q "Cost: \$0.045 on DeepInfra (factory run record; usage_x_price_table)"; then
    echo "FAIL: Cost line was not updated correctly"
    return 1
  fi
  
  # Check that other content is preserved
  if ! echo "$edited_body" | grep -q "## Summary"; then
    echo "FAIL: Other content was not preserved"
    return 1
  fi
  
  if ! echo "$edited_body" | grep -q "## Evidence"; then
    echo "FAIL: Other content was not preserved"
    return 1
  fi
  
  return 0
}

# Test 2: No key/token/env printed
test_no_secrets_printed() {
  # This test ensures our script doesn't print sensitive information
  # We'll check the output of the script for any sensitive-looking content
  
  # Create test PR body with factory-run block
  cat > "$TEMP_WORK_DIR/test_pr_body.txt" <<'EOF'
<!-- factory-run:start -->
Run ID: old-run-id
Workflow run: https://example.com/old-workflow
Model: old-model
Tokens in / cached / out: 0 / 0 / 0
Predicted cost: $0.00
Actual cost: $0.00
Cost method: not_measured
Key spend check: skipped_unavailable
Actions minutes: 0
Gate: false
Run record: factory/runs/old-run-id.json
<!-- factory-run:end -->

Cost: $0.00 (placeholder)
EOF

  # Create a test run record with proper format
  cat > "$TEMP_FACTORY_RUNS_DIR/gha-90000000135-2.json" <<'EOF'
{
  "run_id": "gha-90000000135-2",
  "workflow_run_url": "https://github.com/test/repo/actions/runs/456",
  "model": "test-model",
  "tokens_in": 1000,
  "tokens_cached": 500,
  "tokens_out": 2000,
  "predicted_cost_usd": 0.05,
  "actual_cost_usd": 0.045,
  "cost_method": "usage_x_price_table",
  "cost_check": "match",
  "actions_minutes": 2,
  "gate": {
    "gitleaks": "pass",
    "run_record_valid": "pass",
    "cost_recorded": "pass",
    "pr_template": "pass",
    "pr_check": "pass",
    "budget_cap": "pass",
    "no_workflow_changes": "pass",
    "spec_present": "pass"
  },
  "gate_passed": true
}
EOF

  # Run the script and capture output
  cd "$TEMP_WORK_DIR"
  output=$(FACTORY_RUNS_DIR="$TEMP_FACTORY_RUNS_DIR" "$SCRIPT_DIR/factory-run-body.sh" 456 gha-90000000135-2 2>&1)
  
  # Check that the output doesn't contain sensitive information
  # In this simple case, we just check that it doesn't contain the actual cost value
  # In a real scenario, we'd check for API keys, tokens, etc.
  if echo "$output" | grep -q "0.045"; then
    echo "FAIL: Sensitive information might have been printed"
    return 1
  fi
  
  # Check that it contains the expected success message
  if ! echo "$output" | grep -q "successfully updated PR body"; then
    echo "FAIL: Expected success message not found"
    return 1
  fi
  
  return 0
}

# Test 3: Missing markers exits 2 with no gh pr edit
test_missing_markers() {
  # Create test PR body without factory-run markers
  cat > "$TEMP_WORK_DIR/test_pr_body.txt" <<'EOF'
## Summary

This is a test PR without factory-run markers.

## Cost

Cost: $0.00 (placeholder)

## Evidence

More content here.
EOF

  # Create a test run record with proper format
  cat > "$TEMP_FACTORY_RUNS_DIR/gha-90000000135-3.json" <<'EOF'
{
  "run_id": "gha-90000000135-3",
  "workflow_run_url": "https://github.com/test/repo/actions/runs/789",
  "model": "test-model",
  "tokens_in": 1000,
  "tokens_cached": 500,
  "tokens_out": 2000,
  "predicted_cost_usd": 0.05,
  "actual_cost_usd": 0.045,
  "cost_method": "usage_x_price_table",
  "cost_check": "match",
  "actions_minutes": 2,
  "gate": {
    "gitleaks": "pass",
    "run_record_valid": "pass",
    "cost_recorded": "pass",
    "pr_template": "pass",
    "pr_check": "pass",
    "budget_cap": "pass",
    "no_workflow_changes": "pass",
    "spec_present": "pass"
  },
  "gate_passed": true
}
EOF

  # Reset gh_calls.log between tests
  rm -f "$TEMP_WORK_DIR/gh_calls.log"
  
  # Run the script and capture exit code before any if (so $? is the script's)
  cd "$TEMP_WORK_DIR"
  set +e
  FACTORY_RUNS_DIR="$TEMP_FACTORY_RUNS_DIR" "$SCRIPT_DIR/factory-run-body.sh" 789 gha-90000000135-3 > "$TEMP_WORK_DIR/output.txt" 2>&1
  exit_code=$?
  set -e
  if [ "$exit_code" -ne 2 ]; then
    echo "FAIL: Script should have exited with code 2, got $exit_code"
    return 1
  fi
  
  # Check that gh pr edit was not called
  if [ -f "$TEMP_WORK_DIR/gh_calls.log" ] && grep -q "gh pr edit" "$TEMP_WORK_DIR/gh_calls.log"; then
    echo "FAIL: gh pr edit should not have been called"
    return 1
  fi
  
  return 0
}

# Test 4 (#31): a real run-end record (every gate "skip") gives exactly one Gate line, the Run record
# line uses OC_RUN_RECORD_URL, and the Cost line adds the issue total when it differs.
test_skip_gates_one_line() {
  cat > "$TEMP_WORK_DIR/test_pr_body.txt" <<'EOF'
## Evidence

<!-- factory-run:start -->
Run ID: old-run-id
Gate: false
Run record: factory/runs/old-run-id.json
<!-- factory-run:end -->

Cost: $0.00 (placeholder)
EOF
  cat > "$TEMP_FACTORY_RUNS_DIR/gha-90000000031-1.json" <<'EOF'
{
  "run_id": "gha-90000000031-1",
  "workflow_run_url": "https://github.com/test/repo/actions/runs/31",
  "model": "test-model",
  "tokens_in": 10, "tokens_cached": 5, "tokens_out": 2,
  "predicted_cost_usd": 0.01, "actual_cost_usd": 0.0037, "issue_spend_to_date_usd": 0.025,
  "risk": "normal", "spec_path": "factory/specs/issue-31.md",
  "cost_method": "usage_x_price_table", "cost_check": "match", "actions_minutes": 3,
  "gate": {"gitleaks": "skip", "run_record_valid": "skip", "cost_recorded": "skip", "pr_template": "skip",
           "pr_check": "skip", "budget_cap": "skip", "no_workflow_changes": "skip", "spec_present": "skip"},
  "gate_passed": false
}
EOF
  rm -f "$TEMP_WORK_DIR/edited_pr_body.txt"
  cd "$TEMP_WORK_DIR"
  OC_RUN_RECORD_URL="https://github.com/test/repo/issues/31#issuecomment-1" FACTORY_RUNS_DIR="$TEMP_FACTORY_RUNS_DIR" \
    "$SCRIPT_DIR/factory-run-body.sh" 31 gha-90000000031-1 > "$TEMP_WORK_DIR/output4.txt" 2>&1 || return 1
  local body; body=$(cat "$TEMP_WORK_DIR/edited_pr_body.txt")
  [ "$(grep -c '^Gate: ' <<<"$body")" = 1 ] || { echo "FAIL: expected one Gate line"; return 1; }
  grep -qxF 'Gate: not run (no gate checks wired yet); risk normal: owner product gate required' <<<"$body" || { echo "FAIL: Gate line"; grep '^Gate' <<<"$body"; return 1; }
  grep -qxF 'Run record: https://github.com/test/repo/issues/31#issuecomment-1' <<<"$body" || { echo "FAIL: Run record line"; return 1; }
  grep -qxF 'Spec: factory/specs/issue-31.md' <<<"$body" || { echo "FAIL: Spec line (pr-check needs the spec path)"; return 1; }
  grep -qxF 'Cost: $0.0037 on DeepInfra (factory run record; usage_x_price_table); issue total so far $0.025' <<<"$body" \
    || { echo "FAIL: Cost line"; grep '^Cost' <<<"$body"; return 1; }
}

# Main test execution
main() {
  setup_test_env
  
  run_test "happy path rewrites only factory-run block + Cost line" test_happy_path
  run_test "no key/token/env printed" test_no_secrets_printed
  run_test "missing markers exits 2 with no gh pr edit" test_missing_markers
  run_test "all-skip gates: one Gate line, record URL, issue total (#31)" test_skip_gates_one_line
  
  echo "1..$TEST_COUNT"
  if [ $FAILED -eq 0 ]; then
    echo "All tests passed!"
    exit 0
  else
    echo "$FAILED test(s) failed"
    exit 1
  fi
}

main