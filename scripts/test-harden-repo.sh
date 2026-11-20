#!/usr/bin/env bash
# Offline tests for scripts/harden-repo.sh: stubbed gh, public/private, dry-run, API errors.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); cat "$work/out" 2>/dev/null; }

mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_LOG:?}"
api_line() { printf '%s\n' "$*"; }

if [ "$1" = repo ] && [ "$2" = view ]; then
  if [ -n "${FAKE_REPO_VIEW_FAIL:-}" ]; then
    echo "gh: could not resolve repository" >&2
    exit 1
  fi
  if [[ "$*" == *"nameWithOwner"* ]]; then
  api_line "${FAKE_REPO:-org/case-repo}"
    exit 0
  fi
  if [[ "$*" == *visibility* ]]; then
    api_line "${FAKE_VISIBILITY:-PUBLIC}"
    exit 0
  fi
  exit 0
fi

if [ "$1" = api ]; then
  if [ -n "${FAKE_API_FAIL:-}" ]; then
    echo "gh: Resource not accessible by integration (HTTP 403)" >&2
    exit 1
  fi
  if [ -n "${FAKE_PLAN_BLOCK:-}" ]; then
    case "$*" in
      *rulesets*)
        echo "Upgrade to GitHub Pro or make this repository public" >&2
        exit 1
        ;;
      *secret_scanning*|*repos/*PATCH*)
        echo "GitHub Advanced Security is not enabled" >&2
        exit 1
        ;;
    esac
  fi
  case "$*" in
    *"actions/permissions/workflow"*)
      if [[ "$*" == *"--method PUT"* ]]; then
        exit 0
      fi
      api_line "${FAKE_WORKFLOW_PERM:-read}"
      exit 0
      ;;
    *"repos/"*"/rulesets"*)
      if [[ "$*" == *"--jq"* ]] && [[ "$*" != *"--method"* ]]; then
        api_line "${FAKE_RULESET_ID:-}"
        exit 0
      fi
      if [[ "$*" == *"--method POST"* ]] || [[ "$*" == *"--method PUT"* ]]; then
        api_line "99"
        exit 0
      fi
      ;;
    *"repos/"*)
      if [[ "$*" == *"--jq"* ]] && [[ "$*" == *"security_and_analysis"* || "$*" == *"secret_scanning"* || "$*" == *"private_vulnerability_reporting"* ]]; then
        api_line "${FAKE_SECURITY_STATUS:-enabled}"
        exit 0
      fi
      if [[ "$*" == *"--method PATCH"* ]]; then
        exit 0
      fi
      ;;
  esac
  exit 0
fi

echo "fake gh: unexpected $*" >&2
exit 1
GH
chmod +x "$work/bin/gh"

run_harden() { # label expect-substring ...
  local label="$1" expect="$2"
  shift 2
  : >"$work/log"
  set +e
  PATH="$work/bin:$PATH" FAKE_LOG="$work/log" HARDEN_SKIP_GITLEAKS=1 \
    bash "$root/scripts/harden-repo.sh" "$@" >"$work/out" 2>&1
  local rc=$?
  set -e
  if grep -qF "$expect" "$work/out"; then
  if [ "$rc" -eq 0 ]; then ok "$label"; else bad "$label (rc=$rc, wanted 0)"; fi
  else
    bad "$label (missing: $expect)"
  fi
}

export FAKE_REPO=test-org/public-template FAKE_VISIBILITY=PUBLIC
run_harden "public repo --dry-run" "Private vulnerability reporting" --dry-run --repo test-org/public-template
grep -q 'dry-run.*private-vulnerability-reporting' "$work/out" || bad "public dry-run includes private reporting"
grep -q 'Secret scanning.*dry-run' "$work/out" && ok "public dry-run secret scanning row" || bad "public dry-run secret scanning row"

export FAKE_VISIBILITY=PRIVATE FAKE_PLAN_BLOCK=1 FAKE_SECURITY_STATUS=absent
unset FAKE_RULESET_ID
run_harden "private repo ruleset plan skip" "private GitHub Free" --repo test-org/private-free
grep -q 'Private vulnerability reporting.*skip.*public repos only' "$work/out" \
  && ok "private skips private vulnerability reporting" \
  || bad "private skips private vulnerability reporting"

export FAKE_VISIBILITY=PUBLIC FAKE_PLAN_BLOCK=
run_harden "auto-detect repo from gh" "harden-repo summary for $FAKE_REPO" --dry-run

export FAKE_VISIBILITY=PUBLIC FAKE_API_FAIL=1
run_harden "API permission failure" "needs Administration" --repo test-org/no-admin
grep -q 'Dependabot alerts.*fail' "$work/out" && ok "dependabot fail on 403" || bad "dependabot fail on 403"

export FAKE_API_FAIL= FAKE_VISIBILITY=PUBLIC FAKE_RULESET_ID=42
run_harden "public apply (fake gh)" "updated id 99" --repo other/unrelated-clone
grep -q 'Full-history gitleaks.*skip' "$work/out" && ok "gitleaks skipped for non-matching clone" || bad "gitleaks skip"

export FAKE_REPO_VIEW_FAIL=1
set +e
PATH="$work/bin:$PATH" FAKE_LOG="$work/log" bash "$root/scripts/harden-repo.sh" --dry-run >"$work/out" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q 'could not detect OWNER/REPO' "$work/out"; then
  ok "missing repo detection refused"
else
  bad "missing repo detection (rc=$rc)"
fi

echo
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]