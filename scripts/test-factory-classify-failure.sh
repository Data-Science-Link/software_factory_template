#!/usr/bin/env bash
# Offline tests for scripts/factory-classify-failure.py (#92, #150): every error_class and input edge case.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
cls() { python3 "$root/scripts/factory-classify-failure.py" "$@"; }

ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); cat "$work/last.out" 2>/dev/null || true; }

run_expect() {
  local label="$1" want="$2"
  shift 2
  set +e
  cls "$@" >"$work/last.out" 2>&1
  local rc=$?
  set -e
  local got
  got="$(tr -d '\r' <"$work/last.out" | head -1)"
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
    ok "$label"
  else
    bad "$label (rc=$rc got='$got' want='$want')"
  fi
}

# --- missing, empty, binary logs ---
run_expect "missing log file -> other" "error_class=other" --log "$work/does-not-exist.log"
: >"$work/empty.log"
run_expect "empty log -> other" "error_class=other" --log "$work/empty.log"
# Replacement chars only — must not match tool patterns or raise traceback.
printf '\xff\xfe\x00\xff\xfe\x00\n\n' >"$work/binary.log"
run_expect "binary/non-UTF-8 log decodes without traceback" "error_class=other" --log "$work/binary.log"

# --- tool_or_reasoning_format threshold (3+ matching lines) ---
printf 'ok\nSchemaError(a)\nSchemaError(b)\n' >"$work/two-hits.log"
run_expect "two tool-error lines -> other" "error_class=other" --log "$work/two-hits.log"
printf 'SchemaError\nAI_NoSuchToolError\ninvalid tool call\n' >"$work/three-hits.log"
run_expect "three tool-error lines -> tool_or_reasoning_format" "error_class=tool_or_reasoning_format" --log "$work/three-hits.log"
printf 'schemAerror\nschemAerror\nschemAerror\n' >"$work/case-insensitive.log"
run_expect "case-insensitive patterns count" "error_class=tool_or_reasoning_format" --log "$work/case-insensitive.log"

# --- agent-failure-reason wins over log heuristics ---
mkdir -p "$work/reason-dir"
printf 'SchemaError\nSchemaError\nSchemaError\n' >"$work/reason-dir/opencode.log"
printf 'empty_instruction\n' >"$work/reason-dir/agent-failure-reason.txt"
run_expect "agent reason empty_instruction beats tool log" "error_class=empty_instruction" --log "$work/reason-dir/opencode.log"
printf 'not_a_known_reason\n' >"$work/reason-dir/agent-failure-reason.txt"
run_expect "unknown agent reason ignored -> tool class from log" "error_class=tool_or_reasoning_format" --log "$work/reason-dir/opencode.log"

# --- --github-output ---
: >"$work/out.gh"
run_expect "github-output append" "error_class=other" --log "$work/empty.log" --github-output "$work/out.gh"
if [ "$(cat "$work/out.gh")" = "error_class=other" ]; then
  ok "github-output file content"
else
  bad "github-output file content"
fi

# --- argparse: no unhandled traceback ---
set +e
cls >"$work/last.out" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] && ! grep -q 'Traceback' "$work/last.out"; then
  ok "missing --log: argparse exit without traceback"
else
  bad "missing --log (rc=$rc)"
fi

# --- operational log hints stay other (not expanded classes in classifier) ---
cat >"$work/path-policy.log" <<'LOG'
opencode-artifact-scan: path policy block
protected script edit refused
LOG
run_expect "path-policy log lines -> other" "error_class=other" --log "$work/path-policy.log"
cat >"$work/budget.log" <<'LOG'
factory-run-start: issue budget cap exceeded
Cost cap hit
LOG
run_expect "budget cap log -> other" "error_class=other" --log "$work/budget.log"
cat >"$work/verify.log" <<'LOG'
Verification
Result: FAIL
LOG
run_expect "verification fail log -> other" "error_class=other" --log "$work/verify.log"

echo
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]