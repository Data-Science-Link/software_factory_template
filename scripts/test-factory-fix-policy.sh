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

# ---- malformed / missing input ----
set +e
"${POLICY[@]}" --input "$tmpdir/does-not-exist.json" >"$tmpdir/out.txt" 2>"$tmpdir/err.txt"
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -q '^ERROR: cannot read --input' "$tmpdir/err.txt"; then
  note "missing --input exits 2 with ERROR"
else
  fail "missing --input error handling"
fi

printf 'not-json' >"$tmpdir/bad.json"
set +e
"${POLICY[@]}" --input "$tmpdir/bad.json" >"$tmpdir/out.txt" 2>"$tmpdir/err.txt"
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -q '^ERROR: --input is not valid JSON' "$tmpdir/err.txt"; then
  note "malformed --input JSON rejected"
else
  fail "malformed --input JSON"
fi

touch "$tmpdir/empty.json"
set +e
"${POLICY[@]}" --input "$tmpdir/empty.json" >"$tmpdir/out.txt" 2>"$tmpdir/err.txt"
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -q '^ERROR: --input is empty' "$tmpdir/err.txt"; then
  note "empty --input rejected"
else
  fail "empty --input"
fi

printf '[]' >"$tmpdir/array.json"
set +e
"${POLICY[@]}" --input "$tmpdir/array.json" >"$tmpdir/out.txt" 2>"$tmpdir/err.txt"
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -q '^ERROR: --input must be a JSON object' "$tmpdir/err.txt"; then
  note "non-object --input rejected"
else
  fail "non-object --input"
fi

set +e
"${POLICY[@]}" --issue-spend-usd -1 >"$tmpdir/out.txt" 2>"$tmpdir/err.txt"
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -q '^ERROR: issue_spend_usd must be non-negative' "$tmpdir/err.txt"; then
  note "negative CLI issue_spend_usd rejected"
else
  fail "negative CLI issue_spend_usd"
fi

cat >"$tmpdir/neg-spend.json" <<'JSON'
{"issue_spend_usd": -0.5}
JSON
set +e
"${POLICY[@]}" --input "$tmpdir/neg-spend.json" >"$tmpdir/out.txt" 2>"$tmpdir/err.txt"
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -q '^ERROR: issue_spend_usd must be non-negative' "$tmpdir/err.txt"; then
  note "negative JSON issue_spend_usd rejected"
else
  fail "negative JSON issue_spend_usd"
fi

printf 'issue_target_usd: not-a-number\n' >"$tmpdir/budget.yml"
cat >"$tmpdir/bad-budget.json" <<JSON
{"budget_path": "$tmpdir/budget.yml"}
JSON
set +e
"${POLICY[@]}" --input "$tmpdir/bad-budget.json" >"$tmpdir/out.txt" 2>"$tmpdir/err.txt"
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q "^ERROR: budget key 'issue_target_usd'" "$tmpdir/err.txt" \
   && ! grep -q '^Traceback' "$tmpdir/err.txt"; then
  note "invalid budget YAML values rejected"
else
  fail "invalid budget YAML values"
  cat "$tmpdir/err.txt" || true
fi

# ---- JSON output sort_keys determinism ----
out1="$("${POLICY[@]}" --input "$tmpdir/simple-allow.json")"
out2="$("${POLICY[@]}" --input "$tmpdir/simple-allow.json")"
if [ "$out1" = "$out2" ] && python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert list(d)==sorted(d)' "$out1" 2>/dev/null; then
  note "JSON output sort_keys deterministic"
else
  fail "JSON output determinism"
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi