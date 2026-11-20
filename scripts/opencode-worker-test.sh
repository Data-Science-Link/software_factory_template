#!/usr/bin/env bash
# Sandboxed test entry point for /oc workers (#107). OpenCode allows only this bash command
# besides git; it never runs in the worker's own uid/environment (see scripts/opencode-verify.sh).
#
#   bash scripts/opencode-worker-test.sh <target>
#
# <target> is either:
#   - the short name N naming an existing scripts/test-N.sh (^[a-z0-9][a-z0-9-]*$), or
#   - a pytest path under factory/ (^[a-z0-9][a-z0-9_./-]+$ with a factory/ prefix) when pytest
#     is configured (factory/pytest.ini, or OC_WORKER_TEST_PYTEST=1 for offline harness tests).
set -euo pipefail

die() { echo "worker-test: $*" >&2; exit 2; }

[ $# -eq 1 ] || die "usage: bash scripts/opencode-worker-test.sh <name-or-factory-pytest-path> (exactly one argument)"

target="$1"
if [[ "$target" == *$'\n'* ]] || [[ "$target" == *$'\r'* ]]; then
  die "rejected unsafe target (control characters)"
fi
if [[ "$target" == *".."* ]] || [[ "$target" == *";"* ]] || [[ "$target" == *"|"* ]] \
  || [[ "$target" == *"&"* ]] || [[ "$target" == *'$'* ]] || [[ "$target" == *'`'* ]] \
  || [[ "$target" == *"("* ]] || [[ "$target" == *")"* ]] || [[ "$target" == *" "* ]] \
  || [[ "$target" == -* ]] || [[ "$target" == scripts/* ]] || [[ "$target" == bash* ]]; then
  die "rejected unsafe target: $target"
fi

if [ "${GITHUB_ACTIONS:-}" = true ] && [ "${OC_WORKER_TEST_FIXTURE:-}" = 1 ]; then
  die "fixture mode is not allowed under GitHub Actions"
fi

if [ -n "${OC_WORKER_TEST_FIXTURE:-}" ] && [ "${OC_WORKER_TEST_FIXTURE:-}" = 1 ]; then
  root="${OC_WORKER_TEST_ROOT:-}"
  [ -n "$root" ] && [ -d "$root/.git" ] || die "OC_WORKER_TEST_ROOT must be a git checkout in fixture mode"
else
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
fi
cd "$root"

run_kind='' run_path=''
if [[ "$target" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  candidate="scripts/test-${target}.sh"
  if [ -f "$candidate" ]; then
    run_kind=script
    run_path="$candidate"
  fi
elif [[ "$target" =~ ^factory/[a-z0-9][a-z0-9_./-]*$ ]]; then
  pytest_ok=
  if [ -f factory/pytest.ini ] || [ -f factory/conftest.py ]; then pytest_ok=1; fi
  if [ "${OC_WORKER_TEST_PYTEST:-}" = 1 ]; then pytest_ok=1; fi
  [ -n "$pytest_ok" ] || die "pytest under factory/ is not configured (no factory/pytest.ini)"
  [ -e "$target" ] || die "pytest target does not exist: $target"
  run_kind=pytest
  run_path="$target"
fi
[ -n "$run_kind" ] || die "rejected target outside the allowlist: $target"

timeout_s="${OC_WORKER_TEST_TIMEOUT:-120}"
case "$timeout_s" in '' | *[!0-9]*) die "invalid OC_WORKER_TEST_TIMEOUT"; esac
out_max="${OC_WORKER_TEST_OUTPUT_MAX:-200000}"
case "$out_max" in '' | *[!0-9]*) out_max=200000 ;; esac
max_runs="${OC_WORKER_TEST_MAX_RUNS:-20}"
case "$max_runs" in '' | *[!0-9]*) max_runs=20 ;; esac

count_base="${OC_ARTIFACT_DIR:-${RUNNER_TEMP:-/tmp}}"
mkdir -p "$count_base" 2>/dev/null || true
count_file="$count_base/oc-worker-test.count"
runs=0
if [ -f "$count_file" ]; then
  read -r runs <"$count_file" || runs=0
  case "$runs" in '' | *[!0-9]*) runs=0 ;; esac
fi
if [ "$runs" -ge "$max_runs" ]; then
  die "run limit exceeded (${max_runs} per job; advisory worker tests only)"
fi
echo $((runs + 1)) >"$count_file"

mode="${OC_WORKER_TEST_SANDBOX:-user}"
vuser="${OC_VERIFY_USER:-ocverify}"
[[ "$vuser" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "bad OC_VERIFY_USER"
case "$mode" in
  user) ;;
  none)
    if [ "${GITHUB_ACTIONS:-}" = true ]; then die "OC_WORKER_TEST_SANDBOX=none is for offline tests only"; fi
    ;;
  *) die "OC_WORKER_TEST_SANDBOX must be user or none" ;;
esac

w="$(mktemp -d "${OC_WORKER_TEST_TMPDIR:-/tmp}/oc-worker-test.XXXXXX")"
log="$(mktemp "${RUNNER_TEMP:-/tmp}/oc-worker-test-log.XXXXXX")"
cleanup() {
  if [ "$mode" = user ]; then
    sudo -n pkill -KILL -u "$vuser" 2>/dev/null || true
    sudo -n rm -rf "$w" 2>/dev/null || true
  else
    rm -rf "$w"
  fi
  rm -f "$log"
}
trap cleanup EXIT
mkdir -p "$w/home"

clean_env=(env -i "PATH=/usr/local/bin:/usr/bin:/bin" "HOME=$w/home" "LANG=C.UTF-8" "TERM=dumb" "CI=true")
if [ "$run_kind" = script ]; then
  inner=(bash -c 'cd "$1" && exec bash "$2"' worker "$root" "$run_path")
else
  inner=(bash -c 'cd "$1" && exec python3 -m pytest -q "$2"' worker "$root" "$run_path")
fi
run_cmd=(bash -c 'exec timeout -k 10 "$1" "${@:2}"' timeout-wrap "$timeout_s" "${inner[@]}")

if [ "$mode" = user ]; then
  id -u "$vuser" >/dev/null 2>&1 || sudo -n useradd --system --no-create-home --shell /bin/bash "$vuser"
  sudo -n chown -R "$vuser:" "$w"
  if ! sudo -n -u "$vuser" -- test -x "$root" -a -e "$root/$run_path" 2>/dev/null; then
    sudo -n chmod -R a+rX "$root" 2>/dev/null \
      || die "the sandbox user ${vuser} cannot traverse ${root} (checkout permissions)"
  fi
  sudo -n -u "$vuser" -- test -x "$root" -a -e "$root/$run_path" \
    || die "the sandbox user ${vuser} cannot read ${run_path} under ${root}"
  runner=(sudo -n -u "$vuser" -- "${clean_env[@]}" "${run_cmd[@]}")
else
  runner=("${clean_env[@]}" "${run_cmd[@]}")
fi

set +e
"${runner[@]}" </dev/null >"$log" 2>&1
rc=$?
set -e

if [ "$(wc -c <"$log" | tr -d ' ')" -gt "$out_max" ]; then
  {
    head -c "$((out_max / 2))" "$log"
    printf '\n... worker-test: output truncated (%s byte cap) ...\n' "$out_max"
    tail -c "$((out_max / 2))" "$log"
  } | cat
else
  cat "$log"
fi

case "$rc" in
  124 | 137) die "timed out after ${timeout_s}s" ;;
esac
exit "$rc"