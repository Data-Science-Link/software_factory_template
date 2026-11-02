#!/usr/bin/env bash
# Validate run-record fixtures: pass-* must validate; fail-* must fail.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! python3 -c "import jsonschema" 2>/dev/null; then
  python3 -m pip install -q -r requirements-factory.txt
fi

passed=0
failed=0

run_expect_ok() {
  local path=$1
  if python3 scripts/factory-validate-run.py "$path" >/dev/null; then
    echo "PASS  $path (valid)"
    passed=$((passed + 1))
  else
    echo "FAIL  $path (expected valid)"
    failed=$((failed + 1))
  fi
}

run_expect_fail() {
  local path=$1
  local reason=$2
  set +e
  out="$(python3 scripts/factory-validate-run.py "$path" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "PASS  $path (rejected: $reason)"
    echo "       $(echo "$out" | tail -n +1 | head -1)"
    passed=$((passed + 1))
  else
    echo "FAIL  $path (expected rejection: $reason)"
    failed=$((failed + 1))
  fi
}

for f in tests/run-records/pass-*.json tests/run-records/pass-*.md; do
  [ -f "$f" ] || continue
  run_expect_ok "$f"
done

run_expect_fail tests/run-records/fail-cached-gt-in.json "tokens_cached > tokens_in"
run_expect_fail tests/run-records/fail-local-timestamp.json "non-UTC timestamp"
run_expect_fail tests/run-records/fail-cost-mismatch.json "cost mismatch"
run_expect_fail tests/run-records/fail-unknown-field.json "unknown field"

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
