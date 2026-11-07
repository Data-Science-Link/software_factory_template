#!/usr/bin/env bash
# Test harness for scripts/factory-run-end.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

passed=0
failed=0

note() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }

# run_case <name> <expected_rc> <expected_record_check> <setup_func>
run_case() {
  local name="$1"
  local want_rc="$2"
  local expected_record_check="$3"
  local setup_func="$4"
  
  # Create a clean artifact directory for each test
  local artifact_dir="$tmpdir/artifact-$passed"
  mkdir -p "$artifact_dir"
  
  # Setup the test case
  "$setup_func" "$artifact_dir"
  
  # Run the script
  set +e
  local out rc
  out=$(FACTORY_RUNS_DIR="$tmpdir/runs" \
    OC_ARTIFACT_DIR="$artifact_dir" \
    GITHUB_REPOSITORY="Data-Science-Link/software_factory_template" \
    GITHUB_RUN_ID="42400000001" \
    GITHUB_RUN_ATTEMPT="1" \
    OC_STARTED_AT="2026-11-07T17:00:00Z" \
    OC_ENDED_AT="2026-11-07T17:04:10Z" \
    OC_BASE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    OC_HEAD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    OC_OUTCOME="pr_opened" \
    scripts/factory-run-end.sh 2>"$tmpdir/stderr.txt")
  rc=$?
  set -e
  
  # Check exit code
  if [ "$rc" -ne "$want_rc" ]; then
    fail "$name (expected exit $want_rc, got $rc)"
    return
  fi
  
  # Check record if expected
  if [ "$expected_record_check" = "exists" ]; then
    local run_id="gha-42400000001-1"
    local record_path="$tmpdir/runs/$run_id.json"
    
    if [ ! -f "$record_path" ]; then
      fail "$name (expected record file to exist)"
      return
    fi
    
    # Check record contents with jq
    if ! "$expected_record_check" "$record_path"; then
      fail "$name (record content check failed)"
      return
    fi
  elif [ "$expected_record_check" = "not_exists" ]; then
    local run_id="gha-42400000001-1"
    local record_path="$tmpdir/runs/$run_id.json"
    
    if [ -f "$record_path" ]; then
      fail "$name (expected record file to not exist)"
      return
    fi
  fi
  
  note "$name"
}

# Setup functions for different test cases

setup_happy_path() {
  local artifact_dir="$1"
  
  # Copy spec
  cp factory/specs/issue-133.md "$artifact_dir/spec.md"
  
  # Create usage directory and copy fixtures
  mkdir -p "$artifact_dir/usage"
  cp tests/factory-usage/opencode-export-session-*.json "$artifact_dir/usage/"
  
  # Create run-start.json
  cat > "$artifact_dir/run-start.json" <<EOF
{
  "run_id": "gha-42400000001-1",
  "model": "deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "model_id": "Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "predicted_cost_usd": 0.19,
  "prior_spend_usd": 0.1263,
  "cap_usd": 1.0
}
EOF
  
  # Create key-spend.json
  cat > "$artifact_dir/key-spend.json" <<EOF
{
  "start_usd": 12.0,
  "end_usd": 12.0017,
  "concurrent": false
}
EOF
}

check_happy_path() {
  local record_path="$1"
  
  # Check specific fields
  local actual_cost
  actual_cost=$(jq -r '.actual_cost_usd' "$record_path")
  
  if [ "$actual_cost" != "0.00164" ]; then
    echo "Expected actual_cost_usd=0.00164, got $actual_cost" >&2
    return 1
  fi
  
  local cost_method
  cost_method=$(jq -r '.cost_method' "$record_path")
  
  if [ "$cost_method" != "usage_x_price_table" ]; then
    echo "Expected cost_method=usage_x_price_table, got $cost_method" >&2
    return 1
  fi
  
  local key_spend_delta
  key_spend_delta=$(jq -r '.key_spend_delta_usd' "$record_path")
  
  if [ "$key_spend_delta" != "0.0017" ]; then
    echo "Expected key_spend_delta_usd=0.0017, got $key_spend_delta" >&2
    return 1
  fi
  
  local cost_check
  cost_check=$(jq -r '.cost_check' "$record_path")
  
  if [ "$cost_check" != "match" ]; then
    echo "Expected cost_check=match, got $cost_check" >&2
    return 1
  fi
  
  local tokens_in
  tokens_in=$(jq -r '.tokens_in' "$record_path")
  
  if [ "$tokens_in" != "10000" ]; then
    echo "Expected tokens_in=10000, got $tokens_in" >&2
    return 1
  fi
  
  local tokens_cached
  tokens_cached=$(jq -r '.tokens_cached' "$record_path")
  
  if [ "$tokens_cached" != "8000" ]; then
    echo "Expected tokens_cached=8000, got $tokens_cached" >&2
    return 1
  fi
  
  local tokens_out
  tokens_out=$(jq -r '.tokens_out' "$record_path")
  
  if [ "$tokens_out" != "240" ]; then
    echo "Expected tokens_out=240, got $tokens_out" >&2
    return 1
  fi
  
  local requests
  requests=$(jq -r '.requests' "$record_path")
  
  if [ "$requests" != "4" ]; then
    echo "Expected requests=4, got $requests" >&2
    return 1
  fi
  
  return 0
}

setup_cache_heavy() {
  local artifact_dir="$1"
  
  # Copy spec
  cp factory/specs/issue-133.md "$artifact_dir/spec.md"
  
  # Create usage directory and copy only session 1
  mkdir -p "$artifact_dir/usage"
  cp tests/factory-usage/opencode-export-session-1.json "$artifact_dir/usage/"
  
  # Create run-start.json
  cat > "$artifact_dir/run-start.json" <<EOF
{
  "run_id": "gha-42400000001-1",
  "model": "deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "model_id": "Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "predicted_cost_usd": 0.19,
  "prior_spend_usd": 0.1263,
  "cap_usd": 1.0
}
EOF
  
  # Create key-spend.json
  cat > "$artifact_dir/key-spend.json" <<EOF
{
  "start_usd": 12.0,
  "end_usd": 12.00058,
  "concurrent": false
}
EOF
}

check_cache_heavy() {
  local record_path="$1"
  
  # Check specific fields
  local actual_cost
  actual_cost=$(jq -r '.actual_cost_usd' "$record_path")
  
  if [ "$actual_cost" != "0.00058" ]; then
    echo "Expected actual_cost_usd=0.00058, got $actual_cost" >&2
    return 1
  fi
  
  return 0
}

setup_title_generation_gap_match() {
  local artifact_dir="$1"
  
  # Copy spec
  cp factory/specs/issue-133.md "$artifact_dir/spec.md"
  
  # Create usage directory and copy fixtures
  mkdir -p "$artifact_dir/usage"
  cp tests/factory-usage/opencode-export-session-*.json "$artifact_dir/usage/"
  
  # Create run-start.json
  cat > "$artifact_dir/run-start.json" <<EOF
{
  "run_id": "gha-42400000001-1",
  "model": "deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "model_id": "Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "predicted_cost_usd": 0.19,
  "prior_spend_usd": 0.1263,
  "cap_usd": 1.0
}
EOF
  
  # Create key-spend.json with delta within tolerance
  cat > "$artifact_dir/key-spend.json" <<EOF
{
  "start_usd": 12.0,
  "end_usd": 12.0024,
  "concurrent": false
}
EOF
}

check_title_generation_gap_match() {
  local record_path="$1"
  
  # Check specific fields
  local cost_check
  cost_check=$(jq -r '.cost_check' "$record_path")
  
  if [ "$cost_check" != "match" ]; then
    echo "Expected cost_check=match, got $cost_check" >&2
    return 1
  fi
  
  local actual_cost
  actual_cost=$(jq -r '.actual_cost_usd' "$record_path")
  
  if [ "$actual_cost" != "0.00164" ]; then
    echo "Expected actual_cost_usd=0.00164, got $actual_cost" >&2
    return 1
  fi
  
  return 0
}

setup_title_generation_gap_mismatch() {
  local artifact_dir="$1"
  
  # Copy spec
  cp factory/specs/issue-133.md "$artifact_dir/spec.md"
  
  # Create usage directory and copy fixtures
  mkdir -p "$artifact_dir/usage"
  cp tests/factory-usage/opencode-export-session-*.json "$artifact_dir/usage/"
  
  # Create run-start.json
  cat > "$artifact_dir/run-start.json" <<EOF
{
  "run_id": "gha-42400000001-1",
  "model": "deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "model_id": "Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "predicted_cost_usd": 0.19,
  "prior_spend_usd": 0.1263,
  "cap_usd": 1.0
}
EOF
  
  # Create key-spend.json with large delta
  cat > "$artifact_dir/key-spend.json" <<EOF
{
  "start_usd": 12.0,
  "end_usd": 12.02,
  "concurrent": false
}
EOF
}

check_title_generation_gap_mismatch() {
  local record_path="$1"
  
  # Check specific fields
  local cost_check
  cost_check=$(jq -r '.cost_check' "$record_path")
  
  if [ "$cost_check" != "mismatch" ]; then
    echo "Expected cost_check=mismatch, got $cost_check" >&2
    return 1
  fi
  
  local cost_method
  cost_method=$(jq -r '.cost_method' "$record_path")
  
  if [ "$cost_method" != "key_spend_delta" ]; then
    echo "Expected cost_method=key_spend_delta, got $cost_method" >&2
    return 1
  fi
  
  local actual_cost
  actual_cost=$(jq -r '.actual_cost_usd' "$record_path")
  
  if [ "$actual_cost" != "0.02" ]; then
    echo "Expected actual_cost_usd=0.02, got $actual_cost" >&2
    return 1
  fi
  
  local notes
  notes=$(jq -r '.notes' "$record_path")
  
  if [[ ! "$notes" =~ "unrecorded calls" ]]; then
    echo "Expected notes to contain 'unrecorded calls', got $notes" >&2
    return 1
  fi
  
  return 0
}

setup_key_spend_concurrent() {
  local artifact_dir="$1"
  
  # Copy spec
  cp factory/specs/issue-133.md "$artifact_dir/spec.md"
  
  # Create usage directory and copy fixtures
  mkdir -p "$artifact_dir/usage"
  cp tests/factory-usage/opencode-export-session-*.json "$artifact_dir/usage/"
  
  # Create run-start.json
  cat > "$artifact_dir/run-start.json" <<EOF
{
  "run_id": "gha-42400000001-1",
  "model": "deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "model_id": "Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "predicted_cost_usd": 0.19,
  "prior_spend_usd": 0.1263,
  "cap_usd": 1.0
}
EOF
  
  # Create key-spend.json with concurrent=true
  cat > "$artifact_dir/key-spend.json" <<EOF
{
  "start_usd": 12.0,
  "end_usd": 12.0017,
  "concurrent": true
}
EOF
}

check_key_spend_concurrent() {
  local record_path="$1"
  
  # Check specific fields
  local cost_check
  cost_check=$(jq -r '.cost_check' "$record_path")
  
  if [ "$cost_check" != "skipped_concurrent" ]; then
    echo "Expected cost_check=skipped_concurrent, got $cost_check" >&2
    return 1
  fi
  
  local key_spend_delta
  key_spend_delta=$(jq -r '.key_spend_delta_usd' "$record_path")
  
  if [ "$key_spend_delta" != "null" ]; then
    echo "Expected key_spend_delta_usd=null, got $key_spend_delta" >&2
    return 1
  fi
  
  return 0
}

setup_key_spend_absent() {
  local artifact_dir="$1"
  
  # Copy spec
  cp factory/specs/issue-133.md "$artifact_dir/spec.md"
  
  # Create usage directory and copy fixtures
  mkdir -p "$artifact_dir/usage"
  cp tests/factory-usage/opencode-export-session-*.json "$artifact_dir/usage/"
  
  # Create run-start.json
  cat > "$artifact_dir/run-start.json" <<EOF
{
  "run_id": "gha-42400000001-1",
  "model": "deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "model_id": "Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "predicted_cost_usd": 0.19,
  "prior_spend_usd": 0.1263,
  "cap_usd": 1.0
}
EOF
  
  # No key-spend.json
}

check_key_spend_absent() {
  local record_path="$1"
  
  # Check specific fields
  local cost_check
  cost_check=$(jq -r '.cost_check' "$record_path")
  
  if [ "$cost_check" != "skipped_unavailable" ]; then
    echo "Expected cost_check=skipped_unavailable, got $cost_check" >&2
    return 1
  fi
  
  local key_spend_delta
  key_spend_delta=$(jq -r '.key_spend_delta_usd' "$record_path")
  
  if [ "$key_spend_delta" != "null" ]; then
    echo "Expected key_spend_delta_usd=null, got $key_spend_delta" >&2
    return 1
  fi
  
  return 0
}

setup_missing_usage_with_key_spend() {
  local artifact_dir="$1"
  
  # Copy spec
  cp factory/specs/issue-133.md "$artifact_dir/spec.md"
  
  # No usage directory
  
  # Create run-start.json
  cat > "$artifact_dir/run-start.json" <<EOF
{
  "run_id": "gha-42400000001-1",
  "model": "deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "model_id": "Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "predicted_cost_usd": 0.19,
  "prior_spend_usd": 0.1263,
  "cap_usd": 1.0
}
EOF
  
  # Create key-spend.json
  cat > "$artifact_dir/key-spend.json" <<EOF
{
  "start_usd": 12.0,
  "end_usd": 12.0017,
  "concurrent": false
}
EOF
}

check_missing_usage_with_key_spend() {
  local record_path="$1"
  
  # Check specific fields
  local cost_method
  cost_method=$(jq -r '.cost_method' "$record_path")
  
  if [ "$cost_method" != "key_spend_delta" ]; then
    echo "Expected cost_method=key_spend_delta, got $cost_method" >&2
    return 1
  fi
  
  local actual_cost
  actual_cost=$(jq -r '.actual_cost_usd' "$record_path")
  
  if [ "$actual_cost" != "0.0017" ]; then
    echo "Expected actual_cost_usd=0.0017, got $actual_cost" >&2
    return 1
  fi
  
  local tokens_in
  tokens_in=$(jq -r '.tokens_in' "$record_path")
  
  if [ "$tokens_in" != "0" ]; then
    echo "Expected tokens_in=0, got $tokens_in" >&2
    return 1
  fi
  
  return 0
}

setup_missing_usage_without_key_spend() {
  local artifact_dir="$1"
  
  # Copy spec
  cp factory/specs/issue-133.md "$artifact_dir/spec.md"
  
  # No usage directory
  
  # Create run-start.json
  cat > "$artifact_dir/run-start.json" <<EOF
{
  "run_id": "gha-42400000001-1",
  "model": "deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "model_id": "Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "predicted_cost_usd": 0.19,
  "prior_spend_usd": 0.1263,
  "cap_usd": 1.0
}
EOF
  
  # No key-spend.json
}

check_missing_usage_without_key_spend() {
  local record_path="$1"
  
  # Check specific fields
  local cost_method
  cost_method=$(jq -r '.cost_method' "$record_path")
  
  if [ "$cost_method" != "not_measured" ]; then
    echo "Expected cost_method=not_measured, got $cost_method" >&2
    return 1
  fi
  
  local actual_cost
  actual_cost=$(jq -r '.actual_cost_usd' "$record_path")
  
  if [ "$actual_cost" != "0" ]; then
    echo "Expected actual_cost_usd=0, got $actual_cost" >&2
    return 1
  fi
  
  local tokens_in
  tokens_in=$(jq -r '.tokens_in' "$record_path")
  
  if [ "$tokens_in" != "0" ]; then
    echo "Expected tokens_in=0, got $tokens_in" >&2
    return 1
  fi
  
  return 0
}

setup_no_run_start() {
  local artifact_dir="$1"
  
  # Copy spec
  cp factory/specs/issue-133.md "$artifact_dir/spec.md"
  
  # Create usage directory and copy fixtures
  mkdir -p "$artifact_dir/usage"
  cp tests/factory-usage/opencode-export-session-*.json "$artifact_dir/usage/"
  
  # No run-start.json
  
  # Create key-spend.json
  cat > "$artifact_dir/key-spend.json" <<EOF
{
  "start_usd": 12.0,
  "end_usd": 12.0017,
  "concurrent": false
}
EOF
}

check_no_run_start() {
  local record_path="$1"
  
  # Check specific fields
  local model
  model=$(jq -r '.model' "$record_path")
  
  if [ "$model" != "unknown" ]; then
    echo "Expected model=unknown, got $model" >&2
    return 1
  fi
  
  local cost_method
  cost_method=$(jq -r '.cost_method' "$record_path")
  
  if [ "$cost_method" = "usage_x_price_table" ]; then
    echo "Expected cost_method!=usage_x_price_table, got $cost_method" >&2
    return 1
  fi
  
  local notes
  notes=$(jq -r '.notes' "$record_path")
  
  if [[ ! "$notes" =~ "run start state missing" ]]; then
    echo "Expected notes to contain 'run start state missing', got $notes" >&2
    return 1
  fi
  
  return 0
}

setup_run_start_mismatch() {
  local artifact_dir="$1"
  
  # Copy spec
  cp factory/specs/issue-133.md "$artifact_dir/spec.md"
  
  # Create usage directory and copy fixtures
  mkdir -p "$artifact_dir/usage"
  cp tests/factory-usage/opencode-export-session-*.json "$artifact_dir/usage/"
  
  # Create run-start.json with mismatched run_id
  cat > "$artifact_dir/run-start.json" <<EOF
{
  "run_id": "gha-1-1",
  "model": "deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "model_id": "Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "predicted_cost_usd": 0.19,
  "prior_spend_usd": 0.1263,
  "cap_usd": 1.0
}
EOF
  
  # Create key-spend.json
  cat > "$artifact_dir/key-spend.json" <<EOF
{
  "start_usd": 12.0,
  "end_usd": 12.0017,
  "concurrent": false
}
EOF
}

check_run_start_mismatch() {
  local record_path="$1"
  
  # Check specific fields
  local model
  model=$(jq -r '.model' "$record_path")
  
  if [ "$model" != "unknown" ]; then
    echo "Expected model=unknown, got $model" >&2
    return 1
  fi
  
  local cost_method
  cost_method=$(jq -r '.cost_method' "$record_path")
  
  if [ "$cost_method" = "usage_x_price_table" ]; then
    echo "Expected cost_method!=usage_x_price_table, got $cost_method" >&2
    return 1
  fi
  
  local notes
  notes=$(jq -r '.notes' "$record_path")
  
  if [[ ! "$notes" =~ "run_id mismatch" ]]; then
    echo "Expected notes to contain 'run_id mismatch', got $notes" >&2
    return 1
  fi
  
  return 0
}

setup_failed_no_pr() {
  local artifact_dir="$1"
  
  # Copy spec
  cp factory/specs/issue-133.md "$artifact_dir/spec.md"
  
  # Create usage directory and copy fixtures
  mkdir -p "$artifact_dir/usage"
  cp tests/factory-usage/opencode-export-session-*.json "$artifact_dir/usage/"
  
  # Create run-start.json
  cat > "$artifact_dir/run-start.json" <<EOF
{
  "run_id": "gha-42400000001-1",
  "model": "deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "model_id": "Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "predicted_cost_usd": 0.19,
  "prior_spend_usd": 0.1263,
  "cap_usd": 1.0
}
EOF
  
  # Create key-spend.json
  cat > "$artifact_dir/key-spend.json" <<EOF
{
  "start_usd": 12.0,
  "end_usd": 12.0017,
  "concurrent": false
}
EOF
}

check_failed_no_pr() {
  local record_path="$1"
  
  # Check specific fields - this will be checked with a custom OC_OUTCOME
  return 0
}

setup_bad_outcome() {
  local artifact_dir="$1"
  
  # Copy spec
  cp factory/specs/issue-133.md "$artifact_dir/spec.md"
  
  # No other files needed for this test
}

setup_no_artifact_dir() {
  # This test will be run differently since it's testing a usage error
  return 0
}

check_no_artifact_dir() {
  # This test will be run differently since it's testing a usage error
  return 0
}

setup_no_spec() {
  local artifact_dir="$1"
  
  # Don't create spec.md
  
  # No other files needed for this test
}

setup_bad_started_at() {
  local artifact_dir="$1"
  
  # Copy spec
  cp factory/specs/issue-133.md "$artifact_dir/spec.md"
  
  # No other files needed for this test
}

setup_secrets_test() {
  local artifact_dir="$1"
  
  # Copy spec
  cp factory/specs/issue-133.md "$artifact_dir/spec.md"
  
  # Create usage directory and copy fixtures
  mkdir -p "$artifact_dir/usage"
  cp tests/factory-usage/opencode-export-session-*.json "$artifact_dir/usage/"
  
  # Create run-start.json
  cat > "$artifact_dir/run-start.json" <<EOF
{
  "run_id": "gha-42400000001-1",
  "model": "deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "model_id": "Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo",
  "predicted_cost_usd": 0.19,
  "prior_spend_usd": 0.1263,
  "cap_usd": 1.0
}
EOF
  
  # Create key-spend.json
  cat > "$artifact_dir/key-spend.json" <<EOF
{
  "start_usd": 12.0,
  "end_usd": 12.0017,
  "concurrent": false
}
EOF
}

# Run test cases
run_case "Happy path" 0 check_happy_path setup_happy_path
run_case "Cache-heavy" 0 check_cache_heavy setup_cache_heavy
run_case "Title-generation gap: match" 0 check_title_generation_gap_match setup_title_generation_gap_match
run_case "Title-generation gap: mismatch" 0 check_title_generation_gap_mismatch setup_title_generation_gap_mismatch
run_case "Key spend concurrent" 0 check_key_spend_concurrent setup_key_spend_concurrent
run_case "Key spend absent" 0 check_key_spend_absent setup_key_spend_absent
run_case "Missing usage with key spend" 0 check_missing_usage_with_key_spend setup_missing_usage_with_key_spend
run_case "Missing usage without key spend" 0 check_missing_usage_without_key_spend setup_missing_usage_without_key_spend
run_case "No run-start.json" 0 check_no_run_start setup_no_run_start
run_case "Run-start.json run_id mismatch" 0 check_run_start_mismatch setup_run_start_mismatch

# Special case for failed run with no PR
# Create a clean artifact directory for this test
artifact_dir="$tmpdir/artifact-special"
mkdir -p "$artifact_dir"
setup_failed_no_pr "$artifact_dir"

set +e
out=$(FACTORY_RUNS_DIR="$tmpdir/runs" \
  OC_ARTIFACT_DIR="$artifact_dir" \
  GITHUB_REPOSITORY="Data-Science-Link/software_factory_template" \
  GITHUB_RUN_ID="42400000001" \
  GITHUB_RUN_ATTEMPT="1" \
  OC_STARTED_AT="2026-11-07T17:00:00Z" \
  OC_ENDED_AT="2026-11-07T17:04:10Z" \
  OC_BASE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  OC_HEAD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  OC_OUTCOME="failed" \
  OC_PR_NUMBER="" \
  scripts/factory-run-end.sh 2>"$tmpdir/stderr-special.txt")
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  fail "Failed run with no PR (expected exit 0, got $rc)"
else
  # Check the record
  run_id="gha-42400000001-1"
  record_path="$tmpdir/runs/$run_id.json"
  
  if [ ! -f "$record_path" ]; then
    fail "Failed run with no PR (expected record file to exist)"
  else
    # Check pr field is null
    pr=$(jq -r '.pr' "$record_path")
    outcome=$(jq -r '.outcome' "$record_path")
    
    if [ "$pr" != "null" ] || [ "$outcome" != "failed" ]; then
      fail "Failed run with no PR (expected pr=null and outcome=failed)"
    else
      note "Failed run with no PR"
    fi
  fi
fi

# Test usage errors
# No artifact dir
set +e
out=$(FACTORY_RUNS_DIR="$tmpdir/runs" \
  GITHUB_REPOSITORY="Data-Science-Link/software_factory_template" \
  GITHUB_RUN_ID="42400000001" \
  GITHUB_RUN_ATTEMPT="1" \
  OC_STARTED_AT="2026-11-07T17:00:00Z" \
  OC_ENDED_AT="2026-11-07T17:04:10Z" \
  OC_BASE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  OC_HEAD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  OC_OUTCOME="pr_opened" \
  scripts/factory-run-end.sh 2>"$tmpdir/stderr-no-artifact.txt")
rc=$?
set -e

if [ "$rc" -ne 2 ]; then
  fail "No OC_ARTIFACT_DIR (expected exit 2, got $rc)"
else
  note "No OC_ARTIFACT_DIR"
fi

# Bad OC_OUTCOME
set +e
out=$(FACTORY_RUNS_DIR="$tmpdir/runs" \
  OC_ARTIFACT_DIR="/nonexistent" \
  GITHUB_REPOSITORY="Data-Science-Link/software_factory_template" \
  GITHUB_RUN_ID="42400000001" \
  GITHUB_RUN_ATTEMPT="1" \
  OC_STARTED_AT="2026-11-07T17:00:00Z" \
  OC_ENDED_AT="2026-11-07T17:04:10Z" \
  OC_BASE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  OC_HEAD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  OC_OUTCOME="bogus" \
  scripts/factory-run-end.sh 2>"$tmpdir/stderr-bad-outcome.txt")
rc=$?
set -e

if [ "$rc" -ne 2 ]; then
  fail "Bad OC_OUTCOME (expected exit 2, got $rc)"
else
  note "Bad OC_OUTCOME"
fi

# No spec.md
artifact_dir="$tmpdir/artifact-no-spec"
mkdir -p "$artifact_dir"
setup_no_spec "$artifact_dir"

set +e
out=$(FACTORY_RUNS_DIR="$tmpdir/runs" \
  OC_ARTIFACT_DIR="$artifact_dir" \
  GITHUB_REPOSITORY="Data-Science-Link/software_factory_template" \
  GITHUB_RUN_ID="42400000001" \
  GITHUB_RUN_ATTEMPT="1" \
  OC_STARTED_AT="2026-11-07T17:00:00Z" \
  OC_ENDED_AT="2026-11-07T17:04:10Z" \
  OC_BASE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  OC_HEAD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  OC_OUTCOME="pr_opened" \
  scripts/factory-run-end.sh 2>"$tmpdir/stderr-no-spec.txt")
rc=$?
set -e

if [ "$rc" -ne 2 ]; then
  fail "No spec.md (expected exit 2, got $rc)"
else
  note "No spec.md"
fi

# Bad OC_STARTED_AT
set +e
out=$(FACTORY_RUNS_DIR="$tmpdir/runs" \
  OC_ARTIFACT_DIR="$artifact_dir" \
  GITHUB_REPOSITORY="Data-Science-Link/software_factory_template" \
  GITHUB_RUN_ID="42400000001" \
  GITHUB_RUN_ATTEMPT="1" \
  OC_STARTED_AT="2026-11-07T17:00:00" \
  OC_ENDED_AT="2026-11-07T17:04:10Z" \
  OC_BASE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  OC_HEAD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  OC_OUTCOME="pr_opened" \
  scripts/factory-run-end.sh 2>"$tmpdir/stderr-bad-started-at.txt")
rc=$?
set -e

if [ "$rc" -ne 2 ]; then
  fail "Bad OC_STARTED_AT (expected exit 2, got $rc)"
else
  note "Bad OC_STARTED_AT"
fi

# Secrets test
artifact_dir="$tmpdir/artifact-secrets"
mkdir -p "$artifact_dir"
setup_secrets_test "$artifact_dir"

secret="sentinel-secret-value-12345"
FACTORY_TEST_SECRET="$secret" result_secret=$(
  FACTORY_RUNS_DIR="$tmpdir/runs" \
  OC_ARTIFACT_DIR="$artifact_dir" \
  GITHUB_REPOSITORY="Data-Science-Link/software_factory_template" \
  GITHUB_RUN_ID="42400000001" \
  GITHUB_RUN_ATTEMPT="1" \
  OC_STARTED_AT="2026-11-07T17:00:00Z" \
  OC_ENDED_AT="2026-11-07T17:04:10Z" \
  OC_BASE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  OC_HEAD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  OC_OUTCOME="pr_opened" \
  scripts/factory-run-end.sh 2>"$tmpdir/stderr-secret.txt"
)
rc=$?

if [ "$rc" -ne 0 ]; then
  fail "Secrets test (script failed)"
else
  # Check that secret doesn't appear in output or record
  if echo "$result_secret" | grep -q "$secret" || grep -q "$secret" "$tmpdir/stderr-secret.txt" || grep -q "$secret" "$tmpdir/runs/gha-42400000001-1.json"; then
    fail "Secrets test (secret appeared in output or record)"
  else
    note "No key or token printed: sentinel env value never appears in output"
  fi
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi