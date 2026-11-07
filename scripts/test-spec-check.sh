#!/usr/bin/env bash
# Test runner for scripts/factory-spec-check.py.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "PyYAML is required. Install factory deps in a venv, then re-run:" >&2
  echo "  python3 -m venv .venv && .venv/bin/pip install -r requirements-factory.txt && .venv/bin/python scripts/factory-spec-check.py ..." >&2
  echo "Or: pip install --user -r requirements-factory.txt  (if your Python allows it)" >&2
  exit 2
fi

read_expect() {
  local fixture="$1"
  head -n 1 "$fixture" | sed -n 's/^# spec-check-expect: //p'
}

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
      if [ "$rc" -eq 0 ] && printf '%s\n' "$output" | grep -q "^OK $fixture\$"; then
        echo "PASS  $name"
        passed=$((passed + 1))
      else
        echo "FAIL  $name (expected exit 0, got $rc)"
        echo "$output" | head -5
        failed=$((failed + 1))
      fi
      ;;
    fail-*)
      expect="$(read_expect "$fixture")"
      if [ -z "$expect" ]; then
        echo "FAIL  $name (missing first-line '# spec-check-expect: ...')"
        failed=$((failed + 1))
        continue
      fi
      if [ "$rc" -eq 0 ]; then
        echo "FAIL  $name (expected non-zero exit, got 0)"
        failed=$((failed + 1))
      elif printf '%s\n' "$output" | grep -Fq "$expect"; then
        echo "PASS  $name"
        passed=$((passed + 1))
      else
        echo "FAIL  $name (expected message containing: $expect)"
        echo "$output" | head -5
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
