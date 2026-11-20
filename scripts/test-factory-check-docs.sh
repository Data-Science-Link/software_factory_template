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

# --- live docs: missing script refs still warn ---
live_warn_dir="$(mktemp -d)"
trap 'rm -rf "$live_warn_dir"' EXIT
printf '%s\n' '# Live doc' '`scripts/no-such-factory-script.sh`' >"$live_warn_dir/bad-live.md"
live_warn_json="$(python3 "${root}/scripts/factory-check-docs.py" --repo-dir "$live_warn_dir" --json 2>&1)"
if echo "$live_warn_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
w = data.get('summary', {}).get('warnings', 0)
assert w >= 1, w
assert any(f.get('kind') == 'missing_script' for f in data.get('findings', []))
"; then
  ok "live docs warn on missing script refs"
else
  bad "live docs warn on missing script refs" "$live_warn_json"
fi

# --- historical specs: default skips orphan script warnings ---
hist_json="$(python3 "${root}/scripts/factory-check-docs.py" --repo-dir "$root" --json 2>&1)"
if echo "$hist_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
spec_hits = [f for f in data.get('findings', []) if (f.get('file') or '').startswith('factory/specs/')]
assert not spec_hits, spec_hits
"; then
  ok "historical factory/specs skipped for orphan script warnings"
else
  bad "historical factory/specs skipped for orphan script warnings" "$hist_json"
fi

# --- historical specs: opt-in via --include-historical-specs ---
hist_opt_json="$(python3 "${root}/scripts/factory-check-docs.py" --repo-dir "$root" --include-historical-specs --json 2>&1)"
if echo "$hist_opt_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
spec_hits = [f for f in data.get('findings', []) if (f.get('file') or '').startswith('factory/specs/')]
assert spec_hits, 'expected warnings from factory/specs'
"; then
  ok "--include-historical-specs warns on archived specs"
else
  bad "--include-historical-specs warns on archived specs" "$hist_opt_json"
fi

# --- live template repo: --strict clean (0 errors, 0 warnings) ---
set +e
strict_out="$(python3 "${root}/scripts/factory-check-docs.py" --repo-dir "$root" --strict 2>&1)"
strict_rc=$?
set -e
strict_json="$(python3 "${root}/scripts/factory-check-docs.py" --repo-dir "$root" --json)"
if [ "$strict_rc" -ne 0 ]; then
  bad "live repo --strict exit 0" "exit $strict_rc\n$strict_out"
elif echo "$strict_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
s = data.get('summary', {})
assert s.get('errors', 1) == 0, s
assert s.get('warnings', 1) == 0, s
assert data.get('findings', []) == [], data.get('findings')
"; then
  ok "live repo --strict zero errors and warnings"
else
  bad "live repo --strict zero errors and warnings" "$strict_json"
fi

echo ""
echo "factory-check-docs tests: ${passed} passed, ${failed} failed"
[ "$failed" -eq 0 ]