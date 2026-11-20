#!/usr/bin/env bash
# Regression for #232: weekly/monthly budget_used_pct must match round(spend/budget*100, 6)
# even when IEEE-754 float noise appears in summed spend_usd.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
DBT_DIR="factory/dbt"
SEEDS_DIR="tests/dbt/budget-math-week-seeds"

if ! command -v dbt >/dev/null 2>&1 || ! "$PYTHON" -c "import dbt" >/dev/null 2>&1; then
  echo "SKIP  dbt build (dbt not installed)"
  echo "Results: 0 passed, 0 failed (dbt skipped)"
  exit 0
fi

export DBT_SEND_ANONYMOUS_USAGE_STATS=false
vars="$("$PYTHON" scripts/factory-budget-vars.py | "$PYTHON" -c 'import json,sys; v=json.load(sys.stdin); v["as_of_date"]="2026-11-20"; print(json.dumps(v))')"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

(
  cd "$DBT_DIR"
  FACTORY_SEEDS_DIR="../../$SEEDS_DIR" dbt build --profiles-dir . --vars "$vars"
) >"$log" 2>&1 || {
  cat "$log"
  echo "FAIL  dbt build on budget-math-week seeds"
  exit 1
}

if ! grep -q 'FAIL.*assert_.*budget_math' "$log" && grep -q 'ERROR=0' "$log"; then
  tail -1 "$log"
  echo "PASS  dbt budget math tests on float-edge seed week"
  echo "Results: 1 passed, 0 failed"
else
  cat "$log"
  echo "FAIL  budget math dbt tests did not all pass"
  exit 1
fi