#!/usr/bin/env bash
# Offline tests for scripts/factory-prepublic-check.py
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PY=(python3 scripts/factory-prepublic-check.py)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }

# --- minimal fixture repo ---
fixture="$work/fixture"
git init -q "$fixture"
git -C "$fixture" config user.email 'test@test'
git -C "$fixture" config user.name test
printf 'MIT\n' >"$fixture/LICENSE"
printf '# Security\n' >"$fixture/SECURITY.md"
printf 'clean public readme\n' >"$fixture/README.md"
mkdir -p "$fixture/tests" "$fixture/allow"
printf 'leak test@company.com here\n' >"$fixture/README.md"
printf 'token ghp_0123456789012345678901234567890AB\n' >"$fixture/secret.txt"
printf 'private link https://github.com/org/perspectiverse/issues/1\n' >"$fixture/link.md"
printf 'allowed fixture test@company.com\n' >"$fixture/tests/fixture.md"
printf 'also allowed\n' >"$fixture/allow/skip.md"
git -C "$fixture" add -A
git -C "$fixture" commit -q -m base
git -C "$fixture" remote add origin 'https://github.com/org/fixture.git'

set +e
out="$("${PY[@]}" "$fixture" --json 2>"$work/err.txt")"
rc=$?
set -e
[ "$rc" -eq 0 ] || bad "default mode exits 0 with findings (rc=$rc)"

count="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["finding_count"])')"
kinds="$(printf '%s' "$out" | python3 -c 'import json,sys; print(" ".join(sorted({f["kind"] for f in json.load(sys.stdin)["findings"]})))')"

if [ "$count" -ge 3 ] && echo "$kinds" | grep -q private_email && echo "$kinds" | grep -q token_pattern; then
  ok "fixture repo: flags email and token"
else
  bad "fixture repo findings (count=$count kinds=$kinds)"
fi

if printf '%s' "$out" | python3 -c '
import json,sys
fs=json.load(sys.stdin)["findings"]
assert not any(f["path"]=="tests/fixture.md" for f in fs)
'; then
  ok "tests/ allowlist skips fixture emails"
else
  bad "tests/ allowlist"
fi

rm "$fixture/SECURITY.md"
git -C "$fixture" add -A
git -C "$fixture" commit -q -m drop-security

out2="$("${PY[@]}" "$fixture" --json)"
if printf '%s' "$out2" | python3 -c '
import json,sys
fs=json.load(sys.stdin)["findings"]
assert any(f["kind"]=="missing_file" and f["path"]=="SECURITY.md" for f in fs)
'; then
  ok "missing SECURITY.md reported"
else
  bad "missing SECURITY.md"
fi

set +e
"${PY[@]}" "$fixture" --strict --json >/dev/null
rc_strict=$?
set -e
[ "$rc_strict" -eq 1 ] && ok "--strict exits 1 when findings exist" || bad "--strict rc=$rc_strict"

set +e
md="$("${PY[@]}" "$fixture" 2>/dev/null)"
set -e
echo "$md" | grep -q '^# Pre-public hygiene scan' && ok "markdown report heading" || bad "markdown report"

# Live scan of this repo (report mode must exit 0)
set +e
live="$("${PY[@]}" . --json 2>"$work/live.err")"
live_rc=$?
set -e
[ "$live_rc" -eq 0 ] && ok "live repo scan report mode (rc=0)" || bad "live repo scan rc=$live_rc"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]