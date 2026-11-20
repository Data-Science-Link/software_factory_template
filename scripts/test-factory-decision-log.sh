#!/usr/bin/env bash
# Offline tests for scripts/factory-decision-log.py
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
LOG=scripts/factory-decision-log.py
passed=0
failed=0

ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# ---- 1: check passes on the real repo log ----
set +e
out="$("$PYTHON" "$LOG" check --file .factory/DECISIONS.md 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && echo "$out" | grep -q 'check: ok'; then
  ok "check passes on .factory/DECISIONS.md"
else
  bad "check on .factory/DECISIONS.md (rc=$rc)"
  echo "$out" | head -20
fi

# ---- 2: list --json on the real repo log ----
if "$PYTHON" "$LOG" list --file .factory/DECISIONS.md --json >"$tmpdir/real-list.json" 2>/dev/null; then
  if "$PYTHON" - "$tmpdir/real-list.json" <<'PY'
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(items, list) and len(items) >= 1
for row in items:
    assert "number" in row and "title" in row and "date" in row
PY
  then
    ok "list --json parses .factory/DECISIONS.md"
  else
    bad "list --json shape on .factory/DECISIONS.md"
  fi
else
  bad "list --json on .factory/DECISIONS.md"
fi

# ---- 3: duplicate id fixture fails check ----
set +e
"$PYTHON" "$LOG" check --file tests/decision-log/duplicate-id.md >/dev/null 2>"$tmpdir/dup.err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -qi 'duplicate decision id' "$tmpdir/dup.err"; then
  ok "duplicate id fixture fails check"
else
  bad "duplicate id fixture (rc=$rc)"
  cat "$tmpdir/dup.err"
fi

# ---- 4: next-id increments ----
want="$("$PYTHON" "$LOG" list --file tests/decision-log/small-log.md --json | "$PYTHON" -c 'import json,sys; print(len(json.load(sys.stdin))+1)')"
got="$("$PYTHON" "$LOG" next-id --file tests/decision-log/small-log.md)"
if [ "$want" = "$got" ]; then
  ok "next-id increments (want=$want got=$got)"
else
  bad "next-id (want=$want got=$got)"
fi

# ---- 5: add dry-run leaves file unchanged ----
cp tests/decision-log/small-log.md "$tmpdir/small.md"
before="$(sha256sum "$tmpdir/small.md" | awk '{print $1}')"
"$PYTHON" "$LOG" add --file "$tmpdir/small.md" \
  --title "Gamma" --decision "Gamma choice." --why "Because gamma." \
  --date 2026-03-03 --status accepted >"$tmpdir/add-dry.txt"
after="$(sha256sum "$tmpdir/small.md" | awk '{print $1}')"
if [ "$before" = "$after" ] && grep -q '### 2026-03-03 — Gamma' "$tmpdir/add-dry.txt"; then
  ok "add dry-run leaves file unchanged"
else
  bad "add dry-run"
fi

# ---- 6: add --write appends and updated file passes check ----
"$PYTHON" "$LOG" add --file "$tmpdir/small.md" --write \
  --title "Gamma" --decision "Gamma choice." --why "Because gamma." \
  --date 2026-03-03 --status accepted >/dev/null
if "$PYTHON" "$LOG" check --file "$tmpdir/small.md" 2>&1 | grep -q 'check: ok'; then
  ok "add --write passes check on updated file"
else
  bad "add --write check on updated file"
  "$PYTHON" "$LOG" check --file "$tmpdir/small.md" || true
fi

# ---- 7: non-UTF-8 file fails without traceback ----
printf '\xff\xfe' >"$tmpdir/bad-encoding.md"
set +e
"$PYTHON" "$LOG" check --file "$tmpdir/bad-encoding.md" 2>"$tmpdir/utf8.err" >/dev/null
rc=$?
set -e
if [ "$rc" -ne 0 ] && ! grep -q Traceback "$tmpdir/utf8.err" \
  && grep -qi 'not valid UTF-8' "$tmpdir/utf8.err"; then
  ok "non-UTF-8 decision log fails cleanly"
else
  bad "non-UTF-8 decision log (rc=$rc)"
  cat "$tmpdir/utf8.err"
fi

# ---- 8: check --json uses sort_keys (stable key order) ----
"$PYTHON" "$LOG" check --file tests/decision-log/small-log.md --json >"$tmpdir/check.json"
if "$PYTHON" - "$tmpdir/check.json" <<'PY'
import json, sys
text = open(sys.argv[1], encoding="utf-8").read()
obj = json.loads(text)
# sort_keys=True places "errors" before "total"
assert text.index('"errors"') < text.index('"total"')
assert "valid" in obj
PY
then
  ok "check --json sort_keys ordering"
else
  bad "check --json sort_keys"
fi

# ---- 9: list --json sort_keys and missing file ----
"$PYTHON" "$LOG" list --file "$tmpdir/missing-log.md" --json >"$tmpdir/missing-list.json" 2>/dev/null
if [ "$(cat "$tmpdir/missing-list.json")" = "[]" ]; then
  ok "list on missing file returns []"
else
  bad "list on missing file"
fi

# ---- 10: malformed date in fixture fails check ----
cat >"$tmpdir/bad-date.md" <<'EOF'
## Log

### 2099-99-99 — Bad date
- **Decision:** Something.
- **Why:** Because.
EOF
set +e
"$PYTHON" "$LOG" check --file "$tmpdir/bad-date.md" 2>"$tmpdir/bdate.err" >/dev/null
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -qi 'malformed date' "$tmpdir/bdate.err"; then
  ok "malformed decision date fails check"
else
  bad "malformed decision date (rc=$rc)"
  cat "$tmpdir/bdate.err"
fi

echo
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]