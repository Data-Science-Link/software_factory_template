#!/usr/bin/env bash
# Offline tests for scripts/factory-models-check.py (refs #71, #127, #30).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
CHECK=( "$PYTHON" scripts/factory-models-check.py )

if ! "$PYTHON" -c "import yaml" 2>/dev/null; then
  echo "FAIL  PyYAML not installed; run: pip install -r requirements-factory.txt"
  exit 1
fi

passed=0
failed=0
fixtures_dir="tests/models-check"

note() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }

# --- real repo models.yaml passes (warnings allowed; no errors) ---
set +e
out="$(
  "${CHECK[@]}" --models-yaml .factory/models.yaml \
    --routing-md .factory/MODEL_ROUTING.md 2>&1
)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "real .factory/models.yaml (expected exit 0, got $rc)"
  printf '%s\n' "$out" | head -20
else
  note "real .factory/models.yaml -> exit 0"
fi

# --- negative price -> non-zero ---
set +e
out="$(
  "${CHECK[@]}" --models-yaml "$fixtures_dir/negative-price.yaml" \
    --routing-md /dev/null 2>&1
)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "negative-price.yaml (expected non-zero exit)"
elif printf '%s\n' "$out" | grep -qi "negative\|non-negative"; then
  note "negative price -> exit $rc with non-negative error"
else
  fail "negative-price.yaml (exit $rc but missing expected message)"
  printf '%s\n' "$out" | head -10
fi

# --- duplicate model id -> non-zero ---
set +e
out="$(
  "${CHECK[@]}" --models-yaml "$fixtures_dir/duplicate-id.yaml" \
    --routing-md /dev/null 2>&1
)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "duplicate-id.yaml (expected non-zero exit)"
elif printf '%s\n' "$out" | grep -qi "duplicate"; then
  note "duplicate model id -> exit $rc"
else
  fail "duplicate-id.yaml (exit $rc but missing duplicate message)"
  printf '%s\n' "$out" | head -10
fi

# --- dangling routing model reference -> non-zero ---
set +e
out="$(
  "${CHECK[@]}" --models-yaml "$fixtures_dir/dangling-model-ref.yaml" \
    --routing-md /dev/null 2>&1
)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "dangling-model-ref.yaml (expected non-zero exit)"
elif printf '%s\n' "$out" | grep -qi "undefined model"; then
  note "dangling model reference -> exit $rc"
else
  fail "dangling-model-ref.yaml (exit $rc but missing undefined model message)"
  printf '%s\n' "$out" | head -10
fi

# --- --json output parses ---
set +e
json_out="$(
  "${CHECK[@]}" --json \
    --models-yaml "$fixtures_dir/minimal-ok.yaml" \
    --routing-md "$fixtures_dir/routing-md-stub.md" 2>"$fixtures_dir/.json.err"
)"
rc=$?
set -e
rm -f "$fixtures_dir/.json.err"
if [ "$rc" -ne 0 ]; then
  fail "--json minimal-ok.yaml (expected exit 0, got $rc)"
elif printf '%s\n' "$json_out" | "$PYTHON" -c "
import json, sys
d = json.load(sys.stdin)
assert d['status'] in ('ok', 'warn', 'fail')
assert isinstance(d['models_checked'], int) and d['models_checked'] >= 1
assert isinstance(d['errors'], list) and isinstance(d['warnings'], list)
"; then
  note "--json output parses (status, models_checked, errors, warnings)"
else
  fail "--json output did not parse or validate"
  printf '%s\n' "$json_out" | head -5
fi

printf '\nSummary: %s passed, %s failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
exit 0