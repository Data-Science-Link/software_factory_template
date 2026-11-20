#!/usr/bin/env bash
# Run every offline scripts/test-*.sh (except this file) and print a pass/fail table.
# New test scripts are picked up automatically once CI calls: bash scripts/test-all.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
missing_deps=0
for mod in yaml jsonschema; do
  if ! "$PYTHON" -c "import $mod" 2>/dev/null; then
    echo "NOTE: Python module $mod missing; some tests may fail or exit early." >&2
    echo "      Install: python3 -m pip install -r requirements-factory.txt" >&2
    missing_deps=1
  fi
done
if [ "$missing_deps" -eq 1 ] && [ -f requirements-factory.txt ]; then
  if "$PYTHON" -m pip install -q -r requirements-factory.txt 2>/dev/null; then
  echo "Installed requirements-factory.txt for this test run." >&2
  fi
fi

mapfile -t tests < <(find scripts -maxdepth 1 -name 'test-*.sh' -type f ! -name 'test-all.sh' | sort)

passed=0
failed=0
skipped=0
declare -a rows=()

for t in "${tests[@]}"; do
  name="$(basename "$t")"
  log="$(mktemp)"
  set +e
  bash "$t" >"$log" 2>&1
  rc=$?
  set -e
  status="PASS"
  if [ "$rc" -eq 0 ]; then
    passed=$((passed + 1))
  elif [ "$rc" -eq 2 ]; then
    status="SKIP"
    skipped=$((skipped + 1))
  else
    status="FAIL"
    failed=$((failed + 1))
  fi
  summary="$(grep -E 'Results: [0-9]+ passed' "$log" | tail -1 || true)"
  [ -z "$summary" ] && summary="$(tail -1 "$log" | head -c 80)"
  rows+=("$status	$name	$rc	$summary")
  rm -f "$log"
done

printf '\n%-6s %-40s %4s  %s\n' "STATUS" "SCRIPT" "RC" "SUMMARY"
printf '%s\n' "------ ---------------------------------------- ----  -------"
for row in "${rows[@]}"; do
  IFS=$'\t' read -r st nm rc sum <<<"$row"
  printf '%-6s %-40s %4s  %s\n' "$st" "$nm" "$rc" "$sum"
done

total="${#tests[@]}"
echo ""
echo "Test-all: $passed passed, $failed failed, $skipped skipped (exit 2), $total scripts"
if [ "$failed" -gt 0 ]; then
  exit 1
fi