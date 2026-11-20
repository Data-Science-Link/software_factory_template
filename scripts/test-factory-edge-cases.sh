#!/usr/bin/env bash
# Edge-case regression tests for factory-backlog.py, factory-fix-policy.py,
# factory-run-review.py, and factory-sync-repos.py (Refs #38, #178).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

passed=0
failed=0
note() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }

EDGE=tests/edge-cases
POLICY=(python3 scripts/factory-fix-policy.py)
BACKLOG=(python3 scripts/factory-backlog.py)
REVIEW=(python3 scripts/factory-run-review.py)

# ---- factory-fix-policy.py ----

assert_policy() {
  local name="$1" input="$2" py="$3"
  set +e
  out="$("${POLICY[@]}" --input "$input" 2>"$tmpdir/err-policy.txt")"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    fail "$name (exit $rc)"
    tail -3 "$tmpdir/err-policy.txt" 2>/dev/null || true
    return
  fi
  if ! python3 -c "$py" <<<"$out"; then
    fail "$name"
    printf '%s\n' "$out"
    return
  fi
  note "$name"
}

for spend in 0.149 0.150 0.151; do
  cat >"$tmpdir/spend-$spend.json" <<JSON
{"complexity": "standard", "issue_spend_usd": $spend, "failed_fix_rounds": 0}
JSON
done

assert_policy "fix-policy spend 0.149 within budget, not complex" "$tmpdir/spend-0.149.json" \
  'import json,sys; d=json.load(sys.stdin); assert d["within_budget"] and not d["complex_build"]'

assert_policy "fix-policy spend 0.150 at target (within budget, not complex)" "$tmpdir/spend-0.150.json" \
  'import json,sys; d=json.load(sys.stdin); assert d["within_budget"] and not d["complex_build"]'

assert_policy "fix-policy spend 0.151 above target (complex, over budget)" "$tmpdir/spend-0.151.json" \
  'import json,sys; d=json.load(sys.stdin); assert d["complex_build"] and not d["within_budget"]'

cat >"$tmpdir/rounds-0.json" <<'JSON'
{"complexity": "simple", "issue_spend_usd": 0.05, "failed_fix_rounds": 0, "proposed_fix_round": 1}
JSON
assert_policy "fix-policy simple 0 failed rounds allows round 1" "$tmpdir/rounds-0.json" \
  'import json,sys; d=json.load(sys.stdin); assert d["max_fix_rounds"]==2 and d["recommendation"]=="allow_fix_round"'

cat >"$tmpdir/rounds-1.json" <<'JSON'
{"complexity": "simple", "issue_spend_usd": 0.05, "failed_fix_rounds": 1,
 "verification_failed_after_last_fix": true, "proposed_fix_round": 2}
JSON
assert_policy "fix-policy simple 1 failed round still allows round 2" "$tmpdir/rounds-1.json" \
  'import json,sys; d=json.load(sys.stdin); assert d["recommendation"]=="allow_fix_round" and d["max_fix_rounds"]==2'

cat >"$tmpdir/rounds-2.json" <<'JSON'
{"complexity": "complex", "failed_fix_rounds": 1, "verification_failed_after_last_fix": true, "proposed_fix_round": 2}
JSON
assert_policy "fix-policy complex 1 failed verification stops second round" "$tmpdir/rounds-2.json" \
  'import json,sys; d=json.load(sys.stdin); assert d["recommendation"]=="stop_and_escalate" and d["max_fix_rounds"]==1'

cat >"$tmpdir/unknown-cx.json" <<'JSON'
{"complexity": "mystery-tier", "issue_spend_usd": 0.05, "major_sections": 1}
JSON
assert_policy "fix-policy unknown complexity treated as non-complex" "$tmpdir/unknown-cx.json" \
  'import json,sys; d=json.load(sys.stdin); assert not d["complex_build"] and d["max_fix_rounds"]==2'

printf '{not-json' >"$tmpdir/bad-policy.json"
set +e
"${POLICY[@]}" --input "$tmpdir/bad-policy.json" >/dev/null 2>"$tmpdir/err-bad-policy.txt"
rc=$?
set -e
if [ "$rc" -ne 0 ] && ! grep -q Traceback "$tmpdir/err-bad-policy.txt"; then
  note "fix-policy malformed JSON exits cleanly (no traceback)"
else
  fail "fix-policy malformed JSON (rc=$rc, traceback=$(grep -c Traceback "$tmpdir/err-bad-policy.txt" || echo 0))"
  cat "$tmpdir/err-bad-policy.txt"
fi

# ---- factory-backlog.py ----

empty_fixture="$tmpdir/empty-issues.json"
printf '[]\n' >"$empty_fixture"
out_backlog="$tmpdir/backlog-out.json"
if "${BACKLOG[@]}" --from-json "$empty_fixture" --out "$out_backlog" >/dev/null 2>"$tmpdir/err-backlog.txt"; then
  if python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))==[]' "$out_backlog"; then
    note "backlog empty issues list produces []"
  else
    fail "backlog empty issues list output not []"
  fi
else
  fail "backlog empty issues list (script failed)"
fi

if "${BACKLOG[@]}" --from-json "$EDGE/backlog-edge.json" --out "$out_backlog" >/dev/null; then
  if python3 - "$out_backlog" <<'PY'
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(items) == 2
u = next(i for i in items if i["number"] == 9001)
assert "🔥" in u["title"] and "<script>" in u["title"]
assert u["priority"] == "high"  # duplicate labels: high beats low
assert u["risk"] == "medium"
n = next(i for i in items if i["number"] == 9002)
assert n["priority"] == "none" and n["risk"] == "unlabeled"
PY
  then
    note "backlog unicode titles, duplicate labels, missing labels, null body"
  else
    fail "backlog unicode/labels normalization"
  fi
else
  fail "backlog edge fixture run failed"
fi

printf '{broken' >"$tmpdir/bad-backlog.json"
set +e
"${BACKLOG[@]}" --from-json "$tmpdir/bad-backlog.json" --out "$out_backlog" 2>"$tmpdir/err-bad-backlog.txt"
rc=$?
set -e
if [ "$rc" -ne 0 ] && ! grep -q Traceback "$tmpdir/err-bad-backlog.txt"; then
  note "backlog malformed fixture JSON exits cleanly (no traceback)"
else
  fail "backlog malformed JSON (rc=$rc)"
  cat "$tmpdir/err-bad-backlog.txt"
fi

# ---- factory-run-review.py ----

live_empty="$tmpdir/live-empty"
mkdir -p "$live_empty"
set +e
"${REVIEW[@]}" --live-dir "$live_empty" >"$tmpdir/review-empty.json" 2>"$tmpdir/err-review-empty.txt"
rc=$?
set -e
if [ "$rc" -eq 0 ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("runs")==[]' "$tmpdir/review-empty.json" 2>/dev/null; then
  note "run-review empty live-dir returns runs: []"
else
  fail "run-review empty live-dir"
fi

printf '{broken' >"$tmpdir/bad-run.json"
set +e
"${REVIEW[@]}" --input "$tmpdir/bad-run.json" >"$tmpdir/out-bad-run.txt" 2>"$tmpdir/err-bad-run.txt"
rc=$?
set -e
if [ "$rc" -ne 0 ] && ! grep -q Traceback "$tmpdir/err-bad-run.txt"; then
  note "run-review malformed --input JSON exits cleanly (no traceback)"
else
  fail "run-review malformed --input (rc=$rc)"
  cat "$tmpdir/err-bad-run.txt"
fi

if "${REVIEW[@]}" --input "$EDGE/run-review-minimal.json" >"$tmpdir/review-min.json" 2>"$tmpdir/err-review-min.txt"; then
  if python3 - "$tmpdir/review-min.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["cost_usd"] is None
assert d["run_id"] == 999001
assert "findings" in d
assert isinstance(d["blocked_calls"], list)
PY
  then
    note "run-review minimal input missing cost/verification fields"
  else
    fail "run-review minimal input handling"
  fi
else
  fail "run-review minimal input script failed"
fi

echo '{"broken' >"$live_empty/issue-comments.json"
set +e
"${REVIEW[@]}" --live-dir "$live_empty" >"$tmpdir/review-trunc.json" 2>"$tmpdir/err-review-trunc.txt"
rc=$?
set -e
if [ "$rc" -eq 0 ] && ! grep -q Traceback "$tmpdir/err-review-trunc.txt"; then
  note "run-review truncated issue-comments.json does not traceback"
else
  fail "run-review truncated live-dir JSON"
fi

# ---- factory-sync-repos.py ----

empty_repos="$tmpdir/empty-repos.txt"
printf '# adopters\n' >"$empty_repos"
set +e
python3 scripts/factory-sync-repos.py --repos-file "$empty_repos" --tag v0.2.0 2>"$tmpdir/err-sync-empty.txt"
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -qi 'empty repo list' "$tmpdir/err-sync-empty.txt"; then
  note "sync-repos empty adopters list exits 2"
else
  fail "sync-repos empty adopters (rc=$rc)"
fi

set +e
python3 scripts/factory-sync-repos.py --repos-file "$empty_repos" --tag not-a-semver 2>"$tmpdir/err-sync-tag.txt"
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -qi 'invalid semver' "$tmpdir/err-sync-tag.txt"; then
  note "sync-repos invalid semver tag rejected cleanly"
else
  fail "sync-repos invalid semver (rc=$rc)"
  cat "$tmpdir/err-sync-tag.txt"
fi

if python3 <<'PY'
import importlib.util
import sys
root = __import__("subprocess").check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
path = f"{root}/scripts/factory-sync-repos.py"
spec = importlib.util.spec_from_file_location("sync", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
text = (
    "uses: Data-Science-Link/software_factory_template"
    "/.github/workflows/reusable-pr-check.yml@v0.2.0\n"
    "    with:\n"
    "      factory_ref: v0.2.0\n"
)
new, changed = mod.bump_content(text, "v0.2.0")
assert not changed, (changed, new)
assert new == text
text2 = text.replace("v0.2.0", "v0.1.0")
new2, changed2 = mod.bump_content(text2, "v0.2.0")
assert changed2 and "@v0.2.0" in new2
new3, changed3 = mod.bump_content(new2, "v0.2.0")
assert not changed3 and new3 == new2
PY
then
  note "sync-repos already-up-to-date tag is a no-op bump"
else
  fail "sync-repos up-to-date no-op bump"
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi