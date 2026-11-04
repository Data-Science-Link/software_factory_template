#!/usr/bin/env bash
# Run the approved spec's Verification commands after the worker finishes and save the output as
# evidence for the PR body (#76, #80). Script only: the model never runs these commands and never
# writes the evidence. The worker's own shell stays git-only (opencode.json).
#
#   opencode-verify.sh --spec <spec.md> --base <checkout> --patch <changes.patch> --out <evidence.md>
#                      [--timeout <seconds>]
#
# Commands: the first ```bash (or ```sh) block under "## Verification" in the spec, i.e. the
# owner-approved text written by scripts/opencode-build-context.py, never anything from the worker.
# Tree: a scratch copy of <base>'s HEAD commit (git archive, so nothing untracked comes along) with
# the patch applied and committed on top; HEAD~1 is the base. There is no origin remote.
# Sandbox (OC_VERIFY_SANDBOX, default "user"): a separate unprivileged user (OC_VERIFY_USER,
# default ocverify) with an EMPTY environment, so no token or API key is in reach, not even via
# /proc of the parent processes (other uid). "none" runs as the current user with an empty
# environment and is refused under GitHub Actions (tests only). Network is not blocked.
# Always exits 0 once the evidence file is written; the evidence carries PASS/FAIL and every
# command that exited non-zero (#100), not just the last command's status.
set -euo pipefail

spec='' base='' patch='' out='' timeout_s="${OC_VERIFY_TIMEOUT:-300}"
while [ $# -gt 0 ]; do
  case "$1" in
    --spec) spec="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    --patch) patch="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --timeout) timeout_s="$2"; shift 2 ;;
    *) echo "verify: unknown argument $1" >&2; exit 2 ;;
  esac
done
if [ -z "$base" ] || [ -z "$out" ]; then echo "verify: need --base and --out" >&2; exit 2; fi
case "$timeout_s" in '' | *[!0-9-]*) timeout_s=300 ;; esac
mode="${OC_VERIFY_SANDBOX:-user}"
vuser="${OC_VERIFY_USER:-ocverify}"
[[ "$vuser" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "verify: bad OC_VERIFY_USER" >&2; exit 2; }
case "$mode" in
  user) ;;
  none) if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "verify: OC_VERIFY_SANDBOX=none is for offline tests only" >&2; exit 2; fi ;;
  *) echo "verify: OC_VERIFY_SANDBOX must be user or none" >&2; exit 2 ;;
esac

not_run() { printf 'Verification run by the harness: not run (%s).\n' "$1" >"$out"; echo "verify: not run ($1)"; exit 0; }

if [ -z "$spec" ] || [ ! -s "$spec" ]; then not_run "no approved spec in this run"; fi
block="$(awk '
  /^## Verification[[:space:]]*$/ { inv = 1; next }
  inv && /^## / { exit }
  inv && !open && /^```(bash|sh)[[:space:]]*$/ { open = 1; next }
  open && /^```[[:space:]]*$/ { exit }
  open { print }' "$spec")"
grep -q '[^[:space:]]' <<<"$block" || not_run 'the spec'"'"'s "## Verification" section has no bash block'
[ "$timeout_s" -ge "${OC_VERIFY_MIN_TIMEOUT:-30}" ] || not_run "not enough time left in the job"

block_sha="$(printf '%s\n' "$block" | sha256sum | cut -c1-12)"
base_sha="$(git -C "$base" rev-parse HEAD)"
# Scratch copy under /tmp, never RUNNER_TEMP: that sits in /home/runner (mode 750), which the
# sandbox user can't traverse (live run 41553660354: "cd: ...: Permission denied").
w="$(mktemp -d "${OC_VERIFY_TMPDIR:-/tmp}/oc-verify.XXXXXX")"
log="$(mktemp "${RUNNER_TEMP:-/tmp}/oc-verify-log.XXXXXX")"
cleanup() {
  if [ "$mode" = user ]; then sudo -n pkill -KILL -u "$vuser" 2>/dev/null || true; sudo -n rm -rf "$w"; else rm -rf "$w"; fi
  rm -f "$log"
}
trap cleanup EXIT
mkdir -p "$w/repo" "$w/home"
git -C "$base" archive --format=tar HEAD | tar -xf - -C "$w/repo"
g() { git -C "$w/repo" -c core.hooksPath=/dev/null -c user.name=oc-verify -c user.email=oc-verify@invalid "$@"; }
g init -q
g add -A
g commit -q -m "base ${base_sha:0:12}"
if [ -n "$patch" ] && [ -s "$patch" ]; then
  g apply --index "$patch" 2>/dev/null || not_run "the patch does not apply to ${base_sha:0:12}"
  g commit -q -m "this run's patch"
fi
# #100: judge EVERY command, not just the last one. The wrapper keeps the block in one shell (cd and
# variables carry over) and runs all of it, but an ERR trap records each command that exits
# non-zero (line, status, command) in status.txt; pipefail makes a failing stage of a pipeline
# count. Commands tested by if/while/&&/|| are not failures (normal bash ERR rules).
# Line 1 of verify.sh is this quiet preamble (stderr, so its xtrace, goes nowhere); the block
# starts on line 2, hence LINENO-1. xtrace is turned on at the end of the preamble.
{
  # shellcheck disable=SC2016 # expanded by the sandboxed bash, on purpose
  printf '%s\n' '{ __oc_status="$1"; __oc_err() { printf "line %s: exit %s: %s\n" "$(($2 - 1))" "$1" "$3" >>"$__oc_status"; }; set -E -o pipefail; trap '"'"'{ __oc_err "$?" "$LINENO" "$BASH_COMMAND"; } 2>/dev/null'"'"' ERR; set -x; } 2>/dev/null'
  printf '%s\n' "$block"
} >"$w/verify.sh"
: >"$w/status.txt"

clean_env=(env -i "PATH=/usr/local/bin:/usr/bin:/bin" "HOME=$w/home" "LANG=C.UTF-8" "TERM=dumb" "CI=true")
# shellcheck disable=SC2016 # $1..$3 are expanded by the inner bash, on purpose
run_cmd=(bash -c 'cd "$1" && exec timeout -k 10 "$2" bash "$3" "$4"' verify "$w/repo" "$timeout_s" "$w/verify.sh" "$w/status.txt")
if [ "$mode" = user ]; then
  id -u "$vuser" >/dev/null 2>&1 || sudo -n useradd --system --no-create-home --shell /bin/bash "$vuser"
  sudo -n chown -R "$vuser:" "$w"
  sudo -n -u "$vuser" -- test -x "$w/repo" -a -w "$w/home" \
    || not_run "the sandbox user ${vuser} cannot reach the scratch copy under $(dirname "$w")"
  runner=(sudo -n -u "$vuser" -- "${clean_env[@]}" "${run_cmd[@]}")
  sandbox="separate unprivileged user ${vuser}, empty environment (no tokens or keys)"
else
  runner=("${clean_env[@]}" "${run_cmd[@]}")
  sandbox="current user, empty environment (offline test mode)"
fi

start=$SECONDS
set +e
"${runner[@]}" </dev/null >"$log" 2>&1
rc=$?
set -e
dur=$((SECONDS - start))
failed_cmds="$(head -c 4000 "$w/status.txt" 2>/dev/null || true)"
nfail="$(grep -c . <<<"$failed_cmds" || true)"
case "$rc" in
  124 | 137) status="FAIL: timed out after ${timeout_s}s" ;;
  *)
    if [ "$nfail" -gt 0 ]; then status="FAIL: ${nfail} command(s) exited non-zero (block exit ${rc})"
    elif [ "$rc" -ne 0 ]; then status="FAIL: block exited ${rc}"
    else status="PASS: every command exited 0"
    fi
    ;;
esac

{
  echo "Verification run by the harness (scripts/opencode-verify.sh), not by the model."
  echo "Commands: the bash block under \"## Verification\" in the approved spec (sha256 ${block_sha})."
  echo "Tree: ${base_sha:0:12} plus this run's patch, committed in a scratch copy (HEAD~1 is the base; no origin remote)."
  echo "Sandbox: ${sandbox}; network not blocked; ${timeout_s}s limit."
  echo "Result: ${status}; ${dur}s. Each \"+ \" line is a command as run; read the outputs below it."
  echo "Per-command status: every command ran; any that exited non-zero is listed here (line in the block, exit code, command)."
  if [ "$nfail" -gt 0 ]; then printf '%s\n' "$failed_cmds" | sed 's/^/  FAILED /'; else echo "  (none failed)"; fi
  echo "--- output ---"
  cat "$log"
} >"$out"
echo "verify: ${status} (${dur}s); evidence in $(basename "$out")"
