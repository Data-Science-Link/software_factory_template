#!/usr/bin/env bash
# Test runner for scripts/factory-spec-check.py.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "Installing factory Python deps from requirements-factory.txt"
  python3 -m pip install -q -r requirements-factory.txt
fi

passed=0
failed=0
total=0
fixtures_dir="tests/specs"

for fixture in "$fixtures_dir"/*.md; do
  [ -f "$fixture" ] || continue
  total=$((total + 1))
  name="$(basename "$fixture")"

  set +e
  output="$(python3 scripts/factory-spec-check.py "$fixture" 2>&1)"
  rc=$?
  set -e

  case "$name" in
    pass-*)
      if [ "$rc" -eq 0 ]; then
        echo "PASS  $name"
        passed=$((passed + 1))
      else
        echo "FAIL  $name (expected exit 0, got $rc)"
        echo "$output" | head -5
        failed=$((failed + 1))
      fi
      ;;
    fail-*)
      if [ "$rc" -ne 0 ]; then
        echo "PASS  $name"
        passed=$((passed + 1))
      else
        echo "FAIL  $name (expected non-zero exit, got 0)"
        failed=$((failed + 1))
      fi
      ;;
    *)
      echo "SKIP  $name (unknown prefix)"
      total=$((total - 1))
      ;;
  esac
done

echo ""
echo "Results: $passed passed, $failed failed, $total total"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
