#!/usr/bin/env bash
# Test runner for scripts/factory-predict-cost.py
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "FAIL  PyYAML not installed; run: pip install -r requirements-factory.txt"
  exit 1
fi

PY=(python3 scripts/factory-predict-cost.py)
MODELS_DEFAULT=".factory/models.yaml"
MODELS_OVER="tests/predict/models-over-cap.yaml"
passed=0
failed=0

run_pass() {
  local fixture="$1"
  local models="${2:-$MODELS_DEFAULT}"
  local name
  name="$(basename "$fixture")"
  local expect_line
  expect_line="$(grep '^# predict-expect:' "$fixture" | head -1 || true)"

  set +e
  output="$("${PY[@]}" "$fixture" --models "$models" 2>&1)"
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    echo "FAIL  $name (expected exit 0, got $rc)"
    echo "$output" | head -5
    failed=$((failed + 1))
    return
  fi

  if [ -z "$expect_line" ]; then
    echo "FAIL  $name (missing # predict-expect directive)"
    failed=$((failed + 1))
    return
  fi

  local want_model want_cost want_rule
  want_model="$(echo "$expect_line" | sed -n 's/.*model=\([^ ]*\).*/\1/p')"
  want_cost="$(echo "$expect_line" | sed -n 's/.*cost=\([^ ]*\).*/\1/p')"
  want_rule="$(echo "$expect_line" | sed -n 's/.*rule=\([^ ]*\).*/\1/p')"

  if ! echo "$output" | grep -q "model: $want_model"; then
    echo "FAIL  $name (model mismatch, want $want_model)"
    echo "$output" | head -5
    failed=$((failed + 1))
    return
  fi
  if ! echo "$output" | grep -q "predicted_cost_usd: $want_cost"; then
    echo "FAIL  $name (cost mismatch, want $want_cost)"
    echo "$output" | grep predicted_cost || true
    failed=$((failed + 1))
    return
  fi
  if [ -n "$want_rule" ] && ! echo "$output" | grep -q "selected_via_rule: $want_rule"; then
    echo "FAIL  $name (rule mismatch, want $want_rule)"
    echo "$output" | grep selected_via_rule || true
    failed=$((failed + 1))
    return
  fi

  echo "PASS  $name"
  passed=$((passed + 1))
}

run_fail() {
  local fixture="$1"
  local models="${2:-$MODELS_DEFAULT}"
  local want_exit="${3:-1}"
  local want_reason="${4:-}"
  local name
  name="$(basename "$fixture")"

  set +e
  output="$("${PY[@]}" "$fixture" --models "$models" 2>&1)"
  rc=$?
  set -e

  if [ "$rc" -ne "$want_exit" ]; then
    echo "FAIL  $name (expected exit $want_exit, got $rc)"
    echo "$output" | head -5
    failed=$((failed + 1))
    return
  fi

  case "$want_reason" in
    split)
      if ! echo "$output" | grep -qi "split this issue"; then
        echo "FAIL  $name (expected split message)"
        echo "$output" | head -3
        failed=$((failed + 1))
        return
      fi
      ;;
    priority)
      if ! echo "$output" | grep -qi "Priority DeepInfra tier"; then
        echo "FAIL  $name (expected priority tier rejection)"
        echo "$output" | head -3
        failed=$((failed + 1))
        return
      fi
      ;;
  esac

  echo "PASS  $name"
  passed=$((passed + 1))
}

run_pass tests/predict/pass-simple-flash.md
run_pass tests/predict/pass-complex-pro.md
run_pass tests/predict/pass-high-risk-pro.md
run_pass tests/predict/pass-work-type-spec.md
run_fail tests/predict/fail-over-cap.md "$MODELS_OVER" 2 split
run_fail tests/predict/fail-priority-tier.md "$MODELS_DEFAULT" 1 priority

# --write idempotence: copy fixture to temp, write twice, no diff on second run
tmp="$(mktemp)"
cp tests/predict/pass-write-idempotent.md "$tmp"
"${PY[@]}" "$tmp" --write >/dev/null
first_hash="$(sha256sum "$tmp" | awk '{print $1}')"
"${PY[@]}" "$tmp" --write >/dev/null
second_hash="$(sha256sum "$tmp" | awk '{print $1}')"
rm -f "$tmp"

if [ "$first_hash" = "$second_hash" ]; then
  echo "PASS  pass-write-idempotent (--write idempotent)"
  passed=$((passed + 1))
else
  echo "FAIL  pass-write-idempotent (--write changed file on second run)"
  failed=$((failed + 1))
fi

echo "---"
echo "predict-cost tests: $passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
