#!/usr/bin/env bash
# Offline tests for prompt-cache prefix stability (#120) and factory-cache-report.py.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
py="${FACTORY_PYTHON:-python3}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }

DELIM='=== PER-RUN CONTEXT (not cacheable) ==='

prompt_prefix() { # full prompt -> bytes before delimiter (inclusive newline after delim line)
  local full="$1"
  case "$full" in
    *"$DELIM"*) printf '%s\n' "${full%%$DELIM*}$DELIM" ;;
    *) printf '%s\n' "$full" ;;
  esac
}

build_prompt() { # issue instruction -> stdout
  env -u DEEPINFRA_API_KEY OC_INSTRUCTION="${2:-/oc run}" OC_ISSUE_NUMBER="$1" OC_ARTIFACT_DIR="$work/ctx$1" \
    bash scripts/opencode-agent-run.sh --print-prompt 2>/dev/null
}

mkdir -p "$work/ctx7" "$work/ctx99"
"$py" scripts/opencode-build-context.py --from-json tests/oc-context/approved.json --out-dir "$work/ctx7" >/dev/null
"$py" scripts/opencode-build-context.py --from-json tests/oc-context/approved.json --out-dir "$work/ctx99" >/dev/null

p7="$(build_prompt 7 run)"
p99="$(build_prompt 99 run)"
pref7="$(prompt_prefix "$p7")"
pref99="$(prompt_prefix "$p99")"
if [ "$pref7" = "$pref99" ] && [ -n "$pref7" ]; then
  ok "build worker: prefix byte-stable across issue 7 vs 99"
else
  bad "build worker: prefix byte-stable (len7=$(printf '%s' "$pref7" | wc -c) len99=$(printf '%s' "$pref99" | wc -c))"
fi
if grep -qF "$DELIM" <<<"$p7" && grep -q 'Issue number: #7' <<<"$p7" && ! grep -q 'Issue number: #99' <<<"$p7"; then
  ok "build worker: per-run tail carries issue number after delimiter"
else bad "build worker: per-run tail placement"; fi

s7="$(OC_INSTRUCTION='/oc spec x' OC_ISSUE_NUMBER=7 OC_ARTIFACT_DIR="$work/sp7" bash scripts/opencode-spec-run.sh --print-prompt 2>/dev/null || true)"
s42="$(OC_INSTRUCTION='/oc spec y' OC_ISSUE_NUMBER=42 OC_ARTIFACT_DIR="$work/sp42" bash scripts/opencode-spec-run.sh --print-prompt 2>/dev/null || true)"
if [ "$(prompt_prefix "$s7")" = "$(prompt_prefix "$s42")" ]; then
  ok "spec worker: prefix byte-stable across issue 7 vs 42"
else bad "spec worker: prefix byte-stable"; fi

# factory-cache-report.py
empty_out="$("$py" scripts/factory-cache-report.py --runs-dir factory/runs 2>&1)" || true
if grep -q 'Run records: 0 file(s)' <<<"$empty_out" && grep -q 'n/a' <<<"$empty_out"; then
  ok "cache report: empty factory/runs/ shows n/a overall"
else bad "cache report: empty factory/runs"; printf '%s\n' "$empty_out"; fi

fixture_dir="$work/runs"
mkdir -p "$fixture_dir"
cp tests/run-records/pass-pr-opened.json "$fixture_dir/gha-pass-pr-opened.json"
cp tests/run-records/pass-failed-no-pr.json "$fixture_dir/gha-pass-failed.json"
"$py" - "$fixture_dir/gha-pass-failed.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["tokens_in"] = 0
d["tokens_cached"] = 0
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
report="$("$py" scripts/factory-cache-report.py --runs-dir "$fixture_dir")"
rate="$(grep '^Overall' <<<"$report" | sed -n 's/.*: \([0-9.]*%\).*/\1/p')"
# pass-pr-opened: 350000/412000 = 84.95%
if [ "$rate" = "84.95%" ]; then
  ok "cache report: aggregates tokens_cached / tokens_in"
else bad "cache report: expected 84.95%, got $rate"; printf '%s\n' "$report"; fi

unit="$("$py" - <<'PY'
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location(
    "factory_cache_report", Path("scripts/factory-cache-report.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
f = mod.cache_hit_rate
assert f(0, 0) is None
assert f(100, None) is None
assert f(None, 50) is None
assert abs(f(1000, 800) - 0.8) < 1e-9
print("ok")
PY
)" 2>&1 || unit=fail
if [ "$unit" = ok ]; then ok "cache_hit_rate edge cases"; else bad "cache_hit_rate edge cases: $unit"; fi

echo
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]