#!/usr/bin/env bash
# dbt regression: budget math, CFO/work-type reconciliation, and data-quality singular tests.
# Runs dbt build on fixture, example, and live seed directories when dbt is installed.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
DBT_DIR="factory/dbt"
BUDGET_MATH_SEEDS="tests/dbt/budget-math-week-seeds"
FIXTURE_SEEDS="tests/dbt/seeds"
PINNED_AS_OF="2026-11-20"

passed=0
failed=0

pass() {
  echo "PASS  $1"
  passed=$((passed + 1))
}

fail() {
  echo "FAIL  $1"
  failed=$((failed + 1))
}

if ! command -v dbt >/dev/null 2>&1 || ! "$PYTHON" -c "import dbt" >/dev/null 2>&1; then
  echo "SKIP  dbt build (dbt not installed)"
  echo "Results: 0 passed, 0 failed (dbt skipped)"
  exit 0
fi

export DBT_SEND_ANONYMOUS_USAGE_STATS=false
vars="$("$PYTHON" scripts/factory-budget-vars.py | "$PYTHON" -c "import json,sys; v=json.load(sys.stdin); v['as_of_date']='$PINNED_AS_OF'; print(json.dumps(v))")"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

run_dbt_build() {
  local seeds_path="$1"
  local label="$2"
  local log="$tmpdir/dbt-${label}.log"
  local factory_seeds_dir="$seeds_path"
  if [[ "$seeds_path" != /* ]]; then
    factory_seeds_dir="../../$seeds_path"
  fi
  if ! (
    cd "$DBT_DIR"
    FACTORY_SEEDS_DIR="$factory_seeds_dir" dbt build --profiles-dir . --vars "$vars"
  ) >"$log" 2>&1; then
    cat "$log"
    fail "dbt build on $label seeds"
    return 1
  fi
  if ! grep -qE 'ERROR=0|Completed successfully' "$log"; then
    cat "$log"
    fail "dbt build on $label seeds (no clean completion)"
    return 1
  fi
  if grep -qE 'FAIL [0-9]+|ERROR [1-9]' "$log"; then
    cat "$log"
    fail "dbt build on $label seeds (test failures)"
    return 1
  fi
  tail -3 "$log"
  pass "dbt build on $label seeds (models + tests)"
}

# ---- 1. Weekly/monthly budget math float edge case ----
log="$(mktemp)"
if (
  cd "$DBT_DIR"
  FACTORY_SEEDS_DIR="../../$BUDGET_MATH_SEEDS" dbt build --profiles-dir . --vars "$vars"
) >"$log" 2>&1; then
  if ! grep -q 'FAIL.*assert_.*budget_math' "$log" && grep -qE 'ERROR=0|Completed successfully' "$log"; then
    tail -1 "$log"
    pass "dbt budget math tests on float-edge seed week"
  else
    cat "$log"
    fail "budget math dbt tests did not all pass"
  fi
else
  cat "$log"
  fail "dbt build on budget-math-week seeds"
fi
rm -f "$log"

# ---- 2. Committed fixture seeds (tests/dbt/seeds) ----
run_dbt_build "$FIXTURE_SEEDS" "fixture" || true

# ---- 3. examples/sample-runs (temp output; does not touch tracked seeds) ----
sample_seeds="$tmpdir/sample-seeds"
mkdir -p "$sample_seeds"
if "$PYTHON" factory/dbt/runs_to_seeds.py --runs 'examples/sample-runs/*.json' --out "$sample_seeds"; then
  run_dbt_build "$sample_seeds" "sample-runs" || true
else
  fail "runs_to_seeds on examples/sample-runs"
fi

# ---- 4. factory/runs (live records; may be header-only on main) ----
live_seeds="$tmpdir/live-seeds"
mkdir -p "$live_seeds"
if "$PYTHON" factory/dbt/runs_to_seeds.py --runs 'factory/runs/*.json' --out "$live_seeds"; then
  run_dbt_build "$live_seeds" "factory-runs" || true
else
  fail "runs_to_seeds on factory/runs"
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi