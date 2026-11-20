#!/usr/bin/env bash
# Offline tests for scripts/factory-issue-triage.py (tests/factory-triage/fixtures).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
TRIAGE="scripts/factory-issue-triage.py"
FIXTURE="tests/factory-triage/backlog.json"
REPO_DIR="tests/factory-triage/repo-dir"

passed=0
failed=0

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

run_pass() {
  echo "PASS  $1"
  passed=$((passed + 1))
}

run_fail() {
  echo "FAIL  $1"
  failed=$((failed + 1))
}

# ---- test 1: unlabeled issues + suggested gh commands ----
md="$tmpdir/triage.md"
if "$PYTHON" "$TRIAGE" --issues-json "$FIXTURE" --repo example/factory \
  --repo-dir "$REPO_DIR" >"$md"; then
  if grep -q "#102" "$md" \
     && grep -q "#103" "$md" \
     && grep -q 'gh issue edit 102 --repo example/factory --add-label priority:low,risk:normal' "$md" \
     && grep -q 'gh issue edit 103 --repo example/factory --add-label risk:normal' "$md"; then
    run_pass "unlabeled issue detection and suggested gh issue edit commands"
  else
    run_fail "unlabeled issue detection or gh commands missing"
    grep -n "102\|103\|gh issue" "$md" || true
  fi
else
  run_fail "factory-issue-triage.py failed on main fixture"
fi

# ---- test 2: already-implemented script detection ----
if grep -q "existing-helper.sh" "$md" && grep -q "#106" "$md"; then
  run_pass "flags open issues whose scripts/* target already exists on disk"
else
  run_fail "possibly-implemented detection missing #106 / existing-helper.sh"
fi

# ---- test 3: Recommendation / Why; skips owner-action and epic ----
if grep -q "^\\*\\*Recommendation:\\*\\*" "$md" \
   && grep -q "^\\*\\*Why:\\*\\*" "$md" \
   && grep -q "#104" "$md" \
   && ! grep -q "Work issue #101" "$md" \
   && ! grep -q "Work issue #100" "$md"; then
  run_pass "priority/risk ranking emits Recommendation and Why (skips owner-action and epic)"
else
  run_fail "Recommendation block wrong or included owner-action/epic"
  grep -n "Recommendation\|Why\|#10" "$md" || true
fi

# ---- test 4: empty backlog exits 0 ----
if "$PYTHON" "$TRIAGE" --issues-json tests/factory-triage/empty.json --repo-dir . \
  >"$tmpdir/empty.md"; then
  if grep -q "Open issues: **0**" "$tmpdir/empty.md" \
     && grep -q "No ready issue to recommend" "$tmpdir/empty.md"; then
    run_pass "empty backlog handled cleanly (exit 0)"
  else
    run_fail "empty backlog output unexpected"
    cat "$tmpdir/empty.md" || true
  fi
else
  run_fail "factory-issue-triage.py failed on empty fixture"
fi

# ---- test 5: --json output parses ----
json_out="$tmpdir/triage.json"
if "$PYTHON" "$TRIAGE" --issues-json "$FIXTURE" --repo-dir "$REPO_DIR" --json \
  >"$json_out" \
  && "$PYTHON" - "$json_out" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
for key in (
    "open_count",
    "label_hygiene",
    "possibly_implemented",
    "candidates",
    "recommendation",
    "epics",
):
    if key not in data:
        raise SystemExit("missing key %r" % key)
if data["recommendation"]["number"] != 104:
    raise SystemExit("expected recommendation #104, got %r" % data["recommendation"])
if not data["label_hygiene"]["suggested_commands"]:
    raise SystemExit("expected hygiene commands")
PY
then
  run_pass "--json output parses and matches expectations"
else
  run_fail "--json output did not parse or validate"
fi

# ---- test 6: missing issues JSON exits non-zero with ERROR (no traceback) ----
set +e
err="$tmpdir/missing.err"
"$PYTHON" "$TRIAGE" --issues-json "$tmpdir/does-not-exist.json" --repo-dir . >"$tmpdir/missing.out" 2>"$err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q '^ERROR: cannot read issues JSON' "$err" \
   && ! grep -q '^Traceback' "$err"; then
  run_pass "missing --issues-json writes ERROR to stderr and exits non-zero"
else
  run_fail "missing --issues-json error handling"
  cat "$err" || true
fi

# ---- test 7: malformed issues JSON ----
printf 'not json' >"$tmpdir/bad.json"
set +e
"$PYTHON" "$TRIAGE" --issues-json "$tmpdir/bad.json" --repo-dir . >"$tmpdir/bad.out" 2>"$tmpdir/bad.err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q '^ERROR: issues JSON is not valid JSON' "$tmpdir/bad.err" \
   && ! grep -q '^Traceback' "$tmpdir/bad.err"; then
  run_pass "malformed issues JSON rejected cleanly"
else
  run_fail "malformed issues JSON handling"
  cat "$tmpdir/bad.err" || true
fi

# ---- test 8: object (not array) issues JSON ----
printf '{}' >"$tmpdir/object.json"
set +e
"$PYTHON" "$TRIAGE" --issues-json "$tmpdir/object.json" --repo-dir . 2>"$tmpdir/obj.err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q '^ERROR: issues JSON must be an array' "$tmpdir/obj.err"; then
  run_pass "non-array issues JSON rejected"
else
  run_fail "non-array issues JSON handling"
fi

# ---- test 9: --json output is key-sorted and deterministic ----
"$PYTHON" "$TRIAGE" --issues-json "$FIXTURE" --repo-dir "$REPO_DIR" --json \
  >"$tmpdir/json-a.json"
"$PYTHON" "$TRIAGE" --issues-json "$FIXTURE" --repo-dir "$REPO_DIR" --json \
  >"$tmpdir/json-b.json"
if cmp -s "$tmpdir/json-a.json" "$tmpdir/json-b.json" \
   && "$PYTHON" -c 'import json; d=json.load(open("'"$tmpdir/json-a.json"'")); assert list(d)==sorted(d)' 2>/dev/null; then
  run_pass "--json output sort_keys deterministic"
else
  run_fail "--json determinism or sort_keys"
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi