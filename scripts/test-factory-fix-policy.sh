#!/usr/bin/env bash
# Offline tests for scripts/factory-fix-policy.py (#233).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

passed=0
failed=0

note() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }

POLICY=(python3 scripts/factory-fix-policy.py)

assert_json() {
  local name="$1"
  local input="$2"
  local py_check="$3"
  set +e
  out="$("${POLICY[@]}" --input "$input" 2>"$tmpdir/err.txt")"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    fail "$name (exit $rc)"
    return
  fi
  if ! python3 -c "$py_check" <<<"$out"; then
    fail "$name"
    printf '%s\n' "$out"
    return
  fi
  note "$name"
}

cat >"$tmpdir/simple-allow.json" <<'JSON'
{
  "complexity": "simple",
  "major_sections": 1,
  "issue_spend_usd": 0.08,
  "failed_fix_rounds": 0,
  "verification_failed_after_last_fix": false,
  "proposed_fix_round": 1
}
JSON
assert_json "simple within budget allows fix round 1" "$tmpdir/simple-allow.json" \
  'import json,sys; d=json.load(sys.stdin); assert d["recommendation"]=="allow_fix_round" and d["max_fix_rounds"]==2 and d["complex_build"] is False'

cat >"$tmpdir/complex-first-fail.json" <<'JSON'
{
  "complexity": "complex",
  "major_sections": 6,
  "issue_spend_usd": 0.55,
  "failed_fix_rounds": 1,
  "verification_failed_after_last_fix": true,
  "proposed_fix_round": 2
}
JSON
assert_json "complex first fix still fails verification -> stop second round" "$tmpdir/complex-first-fail.json" \
  'import json,sys; d=json.load(sys.stdin); assert d["recommendation"]=="stop_and_escalate" and d["max_fix_rounds"]==1 and d["complex_build"] is True'

cat >"$tmpdir/complex-first-allow.json" <<'JSON'
{
  "complexity": "complex",
  "issue_spend_usd": 0.2,
  "failed_fix_rounds": 0,
  "verification_failed_after_last_fix": false,
  "proposed_fix_round": 1
}
JSON
assert_json "complex build allows first fix round" "$tmpdir/complex-first-allow.json" \
  'import json,sys; d=json.load(sys.stdin); assert d["recommendation"]=="allow_fix_round" and d["max_fix_rounds"]==1'

cat >"$tmpdir/spend-trigger.json" <<'JSON'
{
  "complexity": "standard",
  "major_sections": 1,
  "issue_spend_usd": 0.2,
  "failed_fix_rounds": 0,
  "proposed_fix_round": 1
}
JSON
assert_json "spend above target counts as complex (one fix cap)" "$tmpdir/spend-trigger.json" \
  'import json,sys; d=json.load(sys.stdin); assert d["complex_build"] is True and d["max_fix_rounds"]==1'

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi