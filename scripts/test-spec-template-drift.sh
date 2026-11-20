#!/usr/bin/env bash
# Test runner for scripts/spec-template-drift-check.py.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "FAIL  PyYAML not installed; run: pip install -r requirements-factory.txt"
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

passed=0
failed=0

# Healthy case: the real template and models.yaml agree.
set +e
ok_output="$(python3 scripts/spec-template-drift-check.py 2>&1)"
ok_rc=$?
set -e
if [ "$ok_rc" -eq 0 ] && printf '%s\n' "$ok_output" | grep -q '^price_table_version OK: '; then
  echo "PASS  spec-template-drift (template matches models.yaml)"
  passed=$((passed + 1))
else
  echo "FAIL  spec-template-drift (expected exit 0 and price_table_version OK, got exit $ok_rc)"
  echo "$ok_output" | head -5
  failed=$((failed + 1))
fi

# Broken case: a template copy with a mismatched price_table_version is blocked.
broken="$tmpdir/spec.md"
cp .factory/templates/spec.md "$broken"
sed 's/^price_table_version: .*/price_table_version: 1900-01-01/' "$broken" >"$broken.tmp" && mv "$broken.tmp" "$broken"
set +e
bad_output="$("$PWD/scripts/spec-template-drift-check.py" --template "$broken" 2>&1)"
bad_rc=$?
set -e
if [ "$bad_rc" -ne 0 ] && printf '%s\n' "$bad_output" | grep -q 'drift:'; then
  echo "PASS  spec-template-drift (mismatched copy blocked)"
  passed=$((passed + 1))
else
  echo "FAIL  spec-template-drift (expected non-zero exit on mismatch, got exit $bad_rc)"
  echo "$bad_output" | head -5
  failed=$((failed + 1))
fi

# Regression: the real template must pass offline spec lint (#161).
set +e
lint_out="$(python3 scripts/factory-spec-lint.py .factory/templates/spec.md 2>&1)"
lint_rc=$?
set -e
if [ "$lint_rc" -eq 0 ] && printf '%s\n' "$lint_out" | grep -q '^OK '; then
  echo "PASS  spec-template-drift (template passes factory-spec-lint)"
  passed=$((passed + 1))
else
  echo "FAIL  spec-template-drift (template must pass factory-spec-lint, got exit $lint_rc)"
  echo "$lint_out" | head -5
  failed=$((failed + 1))
fi

echo "---"
echo "spec-template-drift tests: $passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
