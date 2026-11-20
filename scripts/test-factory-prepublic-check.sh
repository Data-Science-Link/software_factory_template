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

mk_repo() {
  local dest="$1"
  git init -q "$dest"
  git -C "$dest" config user.email 'test@test'
  git -C "$dest" config user.name test
  printf 'MIT\n' >"$dest/LICENSE"
  printf '# Security\n' >"$dest/SECURITY.md"
  git -C "$dest" remote add origin 'https://github.com/org/fixture.git'
}

commit_all() {
  local dest="$1" msg="$2"
  git -C "$dest" add -A
  git -C "$dest" commit -q -m "$msg"
}

# --- clean fixture repo (zero findings) ---
clean="$work/clean"
mk_repo "$clean"
printf 'public readme only\n' >"$clean/README.md"
commit_all "$clean" init

set +e
clean_out="$("${PY[@]}" "$clean" --strict --json 2>"$work/clean.err")"
clean_rc=$?
set -e
if [ "$clean_rc" -eq 0 ]; then
  ok "clean fixture: --strict exit 0"
else
  bad "clean fixture: --strict rc=$clean_rc"
fi

clean_count="$(printf '%s' "$clean_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["finding_count"])')"
[ "$clean_count" -eq 0 ] && ok "clean fixture: 0 findings" || bad "clean fixture finding_count=$clean_count"

# --- dirty fixture (email, token, private link) ---
fixture="$work/fixture"
mk_repo "$fixture"
printf 'leak test@company.com here\n' >"$fixture/README.md"
# Token built at runtime so this script never contains a literal ghp_ secret for gitleaks.
tok="$(
  python3 - <<'PY'
prefix = "ghp_"
body = "0123456789012345678901234567890AB"
print(prefix + body)
PY
)"
printf 'token %s\n' "$tok" >"$fixture/secret.txt"
printf 'private link https://github.com/org/perspectiverse/issues/1\n' >"$fixture/link.md"
printf 'path /Users/alice/secret/project\n' >"$fixture/home.txt"
printf '%s\n' '-----BEGIN RSA PRIVATE KEY-----' >"$fixture/key.pem"
mkdir -p "$fixture/tests" "$fixture/allow"
printf 'allowed fixture test@company.com\n' >"$fixture/tests/fixture.md"
printf 'also allowed\n' >"$fixture/allow/skip.md"
commit_all "$fixture" base

set +e
out="$("${PY[@]}" "$fixture" --json 2>"$work/err.txt")"
rc=$?
set -e
[ "$rc" -eq 0 ] || bad "default mode exits 0 with findings (rc=$rc)"

count="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["finding_count"])')"
kinds="$(printf '%s' "$out" | python3 -c 'import json,sys; print(" ".join(sorted({f["kind"] for f in json.load(sys.stdin)["findings"]})))')"

if [ "$count" -ge 5 ] \
  && echo "$kinds" | grep -q private_email \
  && echo "$kinds" | grep -q token_pattern \
  && echo "$kinds" | grep -q home_path \
  && echo "$kinds" | grep -q private_key; then
  ok "fixture repo: flags email, token, home path, and private key"
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

if printf '%s' "$out" | python3 -c '
import json,sys
fs=json.load(sys.stdin)["findings"]
assert any(f["kind"]=="home_path" and "alice" in f["detail"] for f in fs)
'; then
  ok "synthetic /Users/alice path caught"
else
  bad "/Users/alice path"
fi

# --- email: example vs real-domain style ---
email_fix="$work/email"
mk_repo "$email_fix"
printf 'ok you@example.com\nbad alice@realcorp.example\n' >"$email_fix/NOTE.md"
commit_all "$email_fix" email

email_out="$("${PY[@]}" "$email_fix" --json)"
if printf '%s' "$email_out" | python3 -c '
import json,sys
fs=json.load(sys.stdin)["findings"]
emails=[f for f in fs if f["kind"]=="private_email"]
assert len(emails)==1
assert "realcorp.example" in emails[0]["detail"]
'; then
  ok "non-example email caught; example.com allowed"
else
  bad "email example vs realcorp.example"
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

# --- JSON schema: summary fields and per-rule counts ---
if printf '%s' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
for key in ("finding_count","files_scanned","allowlisted_count","findings_by_kind"):
    assert key in p, key
assert p["finding_count"] == len(p["findings"])
assert sum(p["findings_by_kind"].values()) == p["finding_count"]
'; then
  ok "JSON summary keys and findings_by_kind"
else
  bad "JSON summary shape"
fi

set +e
json_a="$("${PY[@]}" "$clean" --json 2>/dev/null)"
json_b="$("${PY[@]}" "$clean" --json 2>/dev/null)"
set -e
[ "$json_a" = "$json_b" ] && ok "JSON output deterministic" || bad "JSON not deterministic"

# Live scan of this repo (report mode must exit 0, zero findings — no self-match false positives)
set +e
live="$("${PY[@]}" . --json 2>"$work/live.err")"
live_rc=$?
set -e
[ "$live_rc" -eq 0 ] && ok "live repo scan report mode (rc=0)" || bad "live repo scan rc=$live_rc"

live_count="$(printf '%s' "$live" | python3 -c 'import json,sys; print(json.load(sys.stdin)["finding_count"])')"
if [ "$live_count" -eq 0 ]; then
  ok "live repo scan: zero findings (no self-match on scanner literals)"
else
  bad "live repo scan finding_count=$live_count (expected 0)"
  printf '%s' "$live" | python3 -c 'import json,sys; [print(f) for f in json.load(sys.stdin)["findings"]]' >&2 || true
fi

set +e
live_strict="$("${PY[@]}" . --strict --json 2>"$work/live_strict.err")"
live_strict_rc=$?
set -e
[ "$live_strict_rc" -eq 0 ] && ok "live repo --strict with zero findings" || bad "live repo --strict rc=$live_strict_rc"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]