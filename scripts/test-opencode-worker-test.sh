#!/usr/bin/env bash
# Offline security + functional tests for scripts/opencode-worker-test.sh (#107).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
wrapper="$root/scripts/opencode-worker-test.sh"
work="$(mktemp -d)"
chmod o+x "$work"
trap 'sudo -n rm -rf "$work" 2>/dev/null || rm -rf "$work" 2>/dev/null || true' EXIT
passed=0
failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }
FAKE_KEY="fake-deepinfra-key-$RANDOM$RANDOM"

fixture_repo() {
  rm -rf "$work/repo"
  mkdir -p "$work/repo/scripts"
  cp "$wrapper" "$work/repo/scripts/opencode-worker-test.sh"
  cat >"$work/repo/scripts/test-oc-pass.sh" <<'EOS'
#!/usr/bin/env bash
echo pass-ok
EOS
  cat >"$work/repo/scripts/test-oc-fail.sh" <<'EOS'
#!/usr/bin/env bash
echo fail-line
exit 7
EOS
  cat >"$work/repo/scripts/test-oc-env.sh" <<'EOS'
#!/usr/bin/env bash
echo "key=${DEEPINFRA_API_KEY:-unset} gh=${GH_TOKEN:-unset} github=${GITHUB_TOKEN:-unset}"
EOS
  chmod +x "$work/repo/scripts"/test-oc-*.sh
  git -C "$work/repo" init -q
  git -C "$work/repo" -c user.name=t -c user.email=t@t add -A
  git -C "$work/repo" -c user.name=t -c user.email=t@t commit -qm base
  chmod o+rX "$work/repo" "$work/repo/scripts"
}

wrun() { # $1 = target
  env OC_WORKER_TEST_FIXTURE=1 OC_WORKER_TEST_ROOT="$work/repo" OC_WORKER_TEST_SANDBOX=none \
    OC_ARTIFACT_DIR="$work/art" DEEPINFRA_API_KEY="$FAKE_KEY" GH_TOKEN=fake-gh GITHUB_TOKEN=fake-github \
    bash "$work/repo/scripts/opencode-worker-test.sh" "$1"
}

fixture_repo
set +e
out="$(wrun oc-pass 2>&1)"; rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -qx pass-ok <<<"$out"; then ok "valid scripts/test-*.sh target succeeds"
else bad "valid target (rc=$rc)"; echo "$out"; fi

set +e
out="$(wrun oc-fail 2>&1)"; rc=$?
set -e
if [ "$rc" -eq 7 ] && grep -qx fail-line <<<"$out"; then ok "failing test returns its exit code"
else bad "failing test (rc=$rc)"; echo "$out"; fi

reject() { # $1=name $2=expected message substring $3=target
  set +e
  out="$(wrun "$3" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 2 ] && grep -qF -- "$2" <<<"$out"; then ok "$1"
  else bad "$1 (rc=$rc: $out)"; fi
}

reject "path traversal rejected" "rejected unsafe target" '../scripts/test-oc-pass.sh'
reject "shell injection semicolon rejected" "rejected unsafe target" 'oc-pass; id'
reject "shell injection command substitution rejected" "rejected unsafe target" '$(whoami)'
reject "pipe rejected" "rejected unsafe target" 'oc-pass|cat'
reject "non-test script name rejected" "rejected target outside the allowlist" 'factory-merge'
reject "full script path rejected" "rejected unsafe target" 'scripts/factory-merge.sh'

set +e
out="$(env OC_WORKER_TEST_FIXTURE=1 OC_WORKER_TEST_ROOT="$work/repo" OC_ARTIFACT_DIR="$work/art" \
  bash "$work/repo/scripts/opencode-worker-test.sh" oc-pass extra 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -qF 'exactly one argument' <<<"$out"; then ok "extra arguments rejected"
else bad "extra args (rc=$rc: $out)"; fi

set +e
out="$(wrun oc-env 2>&1)"; rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -qx 'key=unset gh=unset github=unset' <<<"$out" && ! grep -qF "$FAKE_KEY" <<<"$out"; then
  ok "secret env vars scrubbed in child (offline none sandbox)"
else bad "env scrub"; echo "$out"; fi

if sudo -n true 2>/dev/null; then
  fixture_repo
  vuser="${OC_VERIFY_USER:-ocverify}"
  probe="$work/repo/scripts/test-oc-proc.sh"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "key=${DEEPINFRA_API_KEY:-unset}"' \
    "for p in \$(pgrep -u $(id -un) 2>/dev/null); do tr '\\0' '\\n' </proc/\$p/environ 2>/dev/null; done 2>/dev/null | grep -c FAKE_PARENT_SECRET || true" \
    >"$probe"
  chmod +x "$probe"
  git -C "$work/repo" add scripts/test-oc-proc.sh
  git -C "$work/repo" -c user.name=t -c user.email=t@t commit -qm probe
  set +e
  out="$(env OC_WORKER_TEST_FIXTURE=1 OC_WORKER_TEST_ROOT="$work/repo" OC_ARTIFACT_DIR="$work/art2" \
    OC_WORKER_TEST_SANDBOX=user FAKE_PARENT_SECRET="$FAKE_KEY" DEEPINFRA_API_KEY="$FAKE_KEY" \
    bash "$work/repo/scripts/opencode-worker-test.sh" oc-proc 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q 'key=unset' <<<"$out" && grep -qE '(^|[[:space:]])0$' <<<"$out" \
    && ! grep -qF "$FAKE_KEY" <<<"$out"; then
    ok "sudo: separate user and empty env hide parent secrets"
  else bad "sudo sandbox"; echo "$out"; id -u "$vuser" 2>/dev/null || true
  fi
else
  echo "SKIP  sudo: separate-user sandbox (no passwordless sudo)"
fi

# pytest allowlist (fixture flag only; skipped when pytest is not installed)
if python3 -c "import pytest" 2>/dev/null; then
  mkdir -p "$work/repo/factory/pytest_pkg"
  printf '[pytest]\ntestpaths = pytest_pkg\n' >"$work/repo/factory/pytest.ini"
  cat >"$work/repo/factory/pytest_pkg/test_harness.py" <<'PY'
def test_ok():
    assert 1 == 1
PY
  git -C "$work/repo" add factory/pytest.ini factory/pytest_pkg/test_harness.py
  git -C "$work/repo" -c user.name=t -c user.email=t@t commit -qm pytest
  set +e
  out="$(env OC_WORKER_TEST_FIXTURE=1 OC_WORKER_TEST_ROOT="$work/repo" OC_WORKER_TEST_SANDBOX=none \
    OC_WORKER_TEST_PYTEST=1 OC_ARTIFACT_DIR="$work/art3" bash "$work/repo/scripts/opencode-worker-test.sh" factory/pytest_pkg 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q . <<<"$out"; then ok "factory/ pytest target runs when configured"
  else bad "pytest target (rc=$rc)"; echo "$out"; fi
else
  echo "SKIP  factory/ pytest (pytest not installed)"
fi

fixture_repo
reject "factory pytest without config rejected" "not configured" 'factory/evil'

if python3 - "$root/opencode.json" <<'PY'
import json, sys
bash = json.load(open(sys.argv[1]))["permission"]["bash"]
if bash.get("*") != "deny":
    sys.exit(1)
if bash.get("bash scripts/opencode-worker-test.sh*") != "allow":
    sys.exit(1)
bad = [k for k, v in bash.items() if v == "allow" and "test-" in k and "opencode-worker-test" not in k]
if bad:
    sys.exit(1)
# git allows stay
for need in ("git status*", "git diff*", "git add*", "git checkout -b*"):
    if bash.get(need) != "allow":
        sys.exit(1)
sys.exit(0)
PY
then ok "opencode.json bash allows only the worker-test wrapper (+ git)"
else bad "opencode.json bash permissions"; fi

echo "worker-test tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]