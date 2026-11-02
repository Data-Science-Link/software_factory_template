#!/usr/bin/env bash
# Test runner for scripts/pr-check.sh.
# Runs each fixture under tests/pr-check/ through pr-check.sh and checks
# that pass-* fixtures exit 0 and fail-* fixtures exit non-zero.
# For fail-* fixtures, a sibling .expect file must contain a substring of the FAIL line.
# Bash only, no new dependencies.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

passed=0
failed=0
total=0
fixtures_dir="tests/pr-check"

for fixture in "$fixtures_dir"/*.md; do
  [ -f "$fixture" ] || continue
  total=$((total + 1))
  name="$(basename "$fixture")"

  # Run pr-check.sh with just the fixture file (no files argument)
  set +e
  output="$(bash scripts/pr-check.sh "$fixture" 2>&1)"
  rc=$?
  set -e

  case "$name" in
    pass-*)
      if [ "$rc" -eq 0 ]; then
        echo "PASS  $name"
        passed=$((passed + 1))
      else
        echo "FAIL  $name (expected exit 0, got $rc)"
        echo "       $output" | head -3
        failed=$((failed + 1))
      fi
      ;;
    fail-*)
      expect_file="${fixture%.md}.expect"
      if [ "$rc" -ne 0 ]; then
        if [ ! -f "$expect_file" ]; then
          echo "FAIL  $name (missing $expect_file)"
          failed=$((failed + 1))
        elif ! grep -Fq "$(tr -d '\n' < "$expect_file")" <<<"$output" && ! grep -Fq "$(cat "$expect_file")" <<<"$output"; then
          echo "FAIL  $name (output missing expected FAIL substring from $(basename "$expect_file"))"
          echo "       expected contains: $(head -1 "$expect_file")"
          echo "       got: $(grep '^FAIL:' <<<"$output" | head -1)"
          failed=$((failed + 1))
        else
          echo "PASS  $name"
          passed=$((passed + 1))
        fi
      else
        echo "FAIL  $name (expected non-zero exit, got 0)"
        echo "       $output" | head -1
        failed=$((failed + 1))
      fi
      ;;
    *)
      echo "SKIP  $name (unknown prefix, not pass-* or fail-*)"
      total=$((total - 1))
      ;;
  esac
done

echo ""
echo "Results: $passed passed, $failed failed, $total total"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
