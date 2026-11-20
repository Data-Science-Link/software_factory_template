#!/usr/bin/env bash
# Offline fixtures for scripts/factory-check-docs.py
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
fixtures="${root}/tests/factory-check-docs"
passed=0
failed=0

ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); echo "$2" | head -20; }

if [ ! -d "$fixtures" ]; then
  echo "missing fixtures dir: $fixtures" >&2
  exit 1
fi

run_case() {
  local name="$1"
  local dir="$2"
  local expect_rc="$3"
  local extra_args=("${@:4}")

  set +e
  out="$(python3 "${root}/scripts/factory-check-docs.py" --repo-dir "$dir" --strict "${extra_args[@]}" 2>&1)"
  rc=$?
  set -e

  if [ "$rc" -ne "$expect_rc" ]; then
    bad "$name" "expected exit $expect_rc, got $rc\n$out"
    return
  fi
  ok "$name"
}

# --- clean fixture ---
clean="${fixtures}/pass-clean"
run_case "clean --strict exit 0" "$clean" 0

# --- broken file link ---
broken_file="${fixtures}/fail-broken-file"
run_case "broken file link --strict exit 1" "$broken_file" 1
broken_file_out="$(python3 "${root}/scripts/factory-check-docs.py" --repo-dir "$broken_file" --strict 2>&1 || true)"
if [[ "$broken_file_out" == *"does not exist"* ]]; then
  ok "broken file link reports missing target"
else
  bad "broken file link reports missing target" "output missing 'does not exist'"
fi

# --- broken anchor ---
broken_anchor="${fixtures}/fail-broken-anchor"
run_case "broken anchor --strict exit 1" "$broken_anchor" 1
broken_anchor_out="$(python3 "${root}/scripts/factory-check-docs.py" --repo-dir "$broken_anchor" --strict 2>&1 || true)"
if [[ "$broken_anchor_out" == *"heading anchor"* ]]; then
  ok "broken anchor mentioned in report"
else
  bad "broken anchor mentioned in report" "no anchor error in output"
fi

# --- placeholder script refs ---
placeholder="${fixtures}/pass-script-placeholders"
run_case "script placeholders not flagged" "$placeholder" 0
warn_out="$(python3 "${root}/scripts/factory-check-docs.py" --repo-dir "$placeholder" 2>&1 || true)"
if [[ "$warn_out" == *"referenced script"* ]] || [[ "$warn_out" == *"missing_script"* ]]; then
  bad "wildcard script placeholders" "unexpected missing_script warning"
else
  ok "wildcard script placeholders"
fi

# --- JSON schema ---
json_out="$(python3 "${root}/scripts/factory-check-docs.py" --repo-dir "$clean" --json)"
if echo "$json_out" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for key in ('repo_dir', 'files_scanned', 'links_checked', 'findings', 'summary'):
    assert key in data, key
assert 'broken_links' in data['summary']
"; then
  ok "--json schema"
else
  bad "--json schema" "$json_out"
fi

echo ""
echo "factory-check-docs tests: ${passed} passed, ${failed} failed"
[ "$failed" -eq 0 ]