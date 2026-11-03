#!/usr/bin/env bash
# Offline test for scripts/factory-kick-checks.sh (#74) with a fake gh: refuses non-/oc, fork and
# closed PRs; skips when both required checks exist; otherwise closes and reopens. No network.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'GH'
#!/usr/bin/env bash
# Fake gh: answers from FAKE_* env, logs every call.
echo "$*" >>"$FAKE_LOG"
case "$1 $2" in
  "pr view") printf '%s\t%s\t%s\t%s\n' "$FAKE_STATE" "$FAKE_CROSS" "$FAKE_REF" "$FAKE_SHA" ;;
  "pr checks") printf '%s' "$FAKE_CHECKS"; exit 8 ;;
  "pr close" | "pr reopen") ;;
  *) echo "fake gh: unexpected $*" >&2; exit 1 ;;
esac
GH
chmod +x "$work/bin/gh"
SHA=0123456789abcdef0123456789abcdef01234567
kick() { # label want(ok|fail) expect-close(yes|no) [args...] ; FAKE_* from caller
  local label="$1" want="$2" close="$3"; shift 3
  : >"$work/log"
  set +e
  PATH="$work/bin:$PATH" FAKE_LOG="$work/log" bash "$root/scripts/factory-kick-checks.sh" "$@" >"$work/out" 2>&1
  local rc=$?
  set -e
  local closed=no
  if grep -q '^pr close' "$work/log" && grep -q '^pr reopen' "$work/log"; then closed=yes; fi
  if { [ "$want" = ok ] && [ "$rc" -eq 0 ]; } || { [ "$want" = fail ] && [ "$rc" -ne 0 ]; }; then
    if [ "$closed" = "$close" ]; then ok "$label"; else bad "$label (close/reopen=$closed)"; fi
  else bad "$label (rc=$rc)"; cat "$work/out"; fi
}
export FAKE_STATE=OPEN FAKE_CROSS=false FAKE_REF=oc/issue-33-41512830533 FAKE_SHA=$SHA
FAKE_CHECKS=$'run-records\n' kick "bot PR missing pr-check and gitleaks: closed and reopened" ok yes 72
FAKE_CHECKS=$'pr-check\ngitleaks\nrun-records\n' kick "both required checks present: no kick" ok no 72
FAKE_CHECKS=$'pr-check\ngitleaks\n' kick "--force kicks anyway" ok yes 72 --force
FAKE_CHECKS='' kick "--dry-run never closes" ok no 72 --dry-run
FAKE_CHECKS='' FAKE_REF=feature/x kick "non-/oc branch refused" fail no 72
FAKE_CHECKS='' FAKE_CROSS=true kick "fork PR refused" fail no 72
FAKE_CHECKS='' FAKE_STATE=MERGED kick "merged PR refused" fail no 72
FAKE_CHECKS='' kick "non-numeric PR refused" fail no 72x
echo
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
