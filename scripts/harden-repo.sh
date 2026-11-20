#!/usr/bin/env bash
# OWNER STEP — never run by factory agents. Idempotent repo security setup.
#
# Usage:
#   scripts/harden-repo.sh [--dry-run] [--repo OWNER/REPO] [--required-checks ctx1,ctx2]
#                           [--skip-branch-protection]
#
# If --repo is omitted, uses the current git checkout's GitHub remote (gh repo view).
#
# Applies GitHub settings (Dependabot alerts, automated security fixes, secret scanning
# and push protection where the plan allows, default read-only GITHUB_TOKEN, private
# vulnerability reporting on public repos), applies or updates the protect-main ruleset
# (same JSON as scripts/protect-main.sh), and runs a one-time full-history gitleaks scan
# when run from a matching clone (findings counted, values never printed).
#
# Requires: gh logged in with Administration on the target repo, jq, and gitleaks on
# PATH for the history scan (or a clear skip row).
set -euo pipefail

DRY_RUN=0
REQUIRED_CHECKS="pr-check,gitleaks"
SKIP_BRANCH_PROTECTION=0
REPO=""

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \?//'
  echo "Example: scripts/harden-repo.sh --dry-run --repo Data-Science-Link/software_factory_template"
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage ;;
    -n | --dry-run) DRY_RUN=1; shift ;;
    --repo)
      [ $# -ge 2 ] || usage
      REPO="$2"
      shift 2
      ;;
    --required-checks)
      [ $# -ge 2 ] || usage
      REQUIRED_CHECKS="$2"
      shift 2
      ;;
    --skip-branch-protection)
      SKIP_BRANCH_PROTECTION=1
      shift
      ;;
    -*)
      echo "harden-repo: unknown option $1" >&2
      usage
      ;;
    *)
      [ -z "$REPO" ] || usage
      REPO="$1"
      shift
      ;;
  esac
done

if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi

[ -n "$REPO" ] || {
  echo "harden-repo: could not detect OWNER/REPO; pass --repo or run inside a git checkout" >&2
  exit 2
}
[[ "$REPO" == */* ]] || { echo "harden-repo: expected OWNER/REPO, got $REPO" >&2; exit 2; }

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
declare -a ROWS=()

record() { # name status detail
  ROWS+=("$1|$2|$3")
}

is_plan_limit() { # $1 = gh error text
  grep -qiE "Upgrade to GitHub Pro|make this repository public|Advanced Security" <<<"$1"
}

is_permission_error() { # $1 = gh error text
  grep -qiE "HTTP 403|Resource not accessible|admin access|Administration|permission" <<<"$1"
}

run_gh() { # description api-args...
  local desc="$1"
  shift
  if [ "$DRY_RUN" -eq 1 ]; then
    record "$desc" "dry-run" "would run: gh $*"
    return 0
  fi
  local out
  if out="$(gh "$@" 2>&1)"; then
    record "$desc" "pass" "ok"
    return 0
  fi
  if is_plan_limit "$out"; then
    record "$desc" "skip" "$(head -n1 <<<"$out")"
    return 0
  fi
  if is_permission_error "$out"; then
    record "$desc" "fail" "needs Administration on $REPO"
    return 0
  fi
  record "$desc" "fail" "$(head -n1 <<<"$out")"
  return 0
}

visibility="$(gh repo view "$REPO" --json visibility --jq .visibility 2>/dev/null || echo unknown)"
is_public=0
[ "$visibility" = "PUBLIC" ] && is_public=1

# --- Dependabot alerts ---
run_gh "Dependabot alerts" api --method PUT "repos/$REPO/vulnerability-alerts"

# --- Dependabot security updates ---
run_gh "Dependabot security updates" api --method PUT "repos/$REPO/automated-security-fixes"

# --- Default GITHUB_TOKEN read-only ---
if [ "$DRY_RUN" -eq 1 ]; then
  record "Default workflow token read-only" "dry-run" "would PUT actions/permissions/workflow (read)"
else
  out=""
  if out="$(gh api --method PUT "repos/$REPO/actions/permissions/workflow" \
    -f default_workflow_permissions=read \
    -F can_approve_pull_request_reviews=false 2>&1)"; then
    perm="$(gh api "repos/$REPO/actions/permissions/workflow" --jq .default_workflow_permissions 2>/dev/null || echo unknown)"
    if [ "$perm" = "read" ]; then
      record "Default workflow token read-only" "pass" "read (verified)"
    else
      record "Default workflow token read-only" "fail" "read-back=$perm"
    fi
  elif is_plan_limit "$out"; then
    record "Default workflow token read-only" "skip" "$(head -n1 <<<"$out")"
  elif is_permission_error "$out"; then
    record "Default workflow token read-only" "fail" "needs Administration on $REPO"
  else
    record "Default workflow token read-only" "fail" "$(head -n1 <<<"$out")"
  fi
fi

# --- Secret scanning + push protection (plan-dependent) ---
security_field_status() { # $1 = field name under security_and_analysis
  gh api "repos/$REPO" --jq ".security_and_analysis.\"$1\".status // \"absent\"" 2>/dev/null || echo unknown
}

patch_security() {
  local field="$1"
  local label="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    record "$label" "dry-run" "would PATCH security_and_analysis.$field=enabled"
    return 0
  fi
  local body out st
  body="$(jq -n --arg f "$field" '{security_and_analysis: {($f): {status: "enabled"}}}')"
  if out="$(gh api --method PATCH "repos/$REPO" --input - <<<"$body" 2>&1)"; then
    st="$(security_field_status "$field")"
    if [ "$st" = "enabled" ]; then
      record "$label" "pass" "enabled (verified)"
    else
      record "$label" "fail" "read-back status=$st"
    fi
  elif is_plan_limit "$out"; then
    record "$label" "skip" "paid plan or public repo required"
  elif is_permission_error "$out"; then
    record "$label" "fail" "needs Administration on $REPO"
  else
    record "$label" "fail" "$(head -n1 <<<"$out")"
  fi
}

patch_security secret_scanning "Secret scanning"
patch_security secret_scanning_push_protection "Secret scanning push protection"

if [ "$is_public" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    record "Private vulnerability reporting" "dry-run" "would PUT private-vulnerability-reporting"
  else
    out=""
    if out="$(gh api --method PUT "repos/$REPO/private-vulnerability-reporting" 2>&1)"; then
      st="$(security_field_status private_vulnerability_reporting)"
      if [ "$st" = "enabled" ]; then
        record "Private vulnerability reporting" "pass" "enabled (verified)"
      else
        record "Private vulnerability reporting" "pass" "PUT ok (status=$st)"
      fi
    elif is_plan_limit "$out"; then
      record "Private vulnerability reporting" "skip" "$(head -n1 <<<"$out")"
    elif is_permission_error "$out"; then
      record "Private vulnerability reporting" "fail" "needs Administration on $REPO"
    else
      record "Private vulnerability reporting" "fail" "$(head -n1 <<<"$out")"
    fi
  fi
else
  record "Private vulnerability reporting" "skip" "public repos only"
fi

# --- protect-main ruleset (delegate to scripts/protect-main.sh) ---
invoke_protect_main() {
  local label="Branch protection (ruleset protect-main)"
  local prot="$root/scripts/protect-main.sh"
  [ -x "$prot" ] || prot="$root/scripts/protect-main.sh"

  if [ "$SKIP_BRANCH_PROTECTION" -eq 1 ]; then
    record "$label" "skip" "--skip-branch-protection"
    return 0
  fi

  local trimmed="${REQUIRED_CHECKS// /}"
  if [ -z "$trimmed" ] || [ "$trimmed" = "none" ]; then
    record "$label" "skip" "no required checks configured (avoids blocking PRs forever)"
    return 0
  fi

  local -a pargs=(bash "$prot" --repo "$REPO" --checks "$REQUIRED_CHECKS")
  if [ "$DRY_RUN" -eq 1 ]; then
    pargs+=(--dry-run)
    local out
    out="$("${pargs[@]}" 2>&1)"
  else
    local out rc=0
    set +e
    out="$("${pargs[@]}" 2>&1)"
    rc=$?
    set -e
    if grep -qiE "private on GitHub Free|won't enforce branch rules" <<<"$out"; then
      record "$label" "skip" "private GitHub Free — use pre-push hook"
      return 0
    fi
    if [ "$rc" -ne 0 ]; then
      if is_plan_limit "$out"; then
        record "$label" "skip" "private GitHub Free — use pre-push hook"
        return 0
      fi
      if is_permission_error "$out"; then
        record "$label" "fail" "needs Administration on $REPO"
        return 0
      fi
      record "$label" "fail" "$(head -n1 <<<"$out")"
      return 0
    fi
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    record "$label" "dry-run" "protect-main.sh --dry-run (checks: $REQUIRED_CHECKS)"
    return 0
  fi

  if grep -q 'ruleset created on' <<<"$out"; then
    record "$label" "pass" "created ($(sed -n 's/.*id \([0-9]*\).*/\1/p' <<<"$out" | head -1))"
  elif grep -q 'ruleset updated on' <<<"$out"; then
    record "$label" "pass" "updated ($(sed -n 's/.*id \([0-9]*\).*/\1/p' <<<"$out" | head -1))"
  else
    record "$label" "pass" "$(head -n1 <<<"$out")"
  fi
}

invoke_protect_main

# --- Full-history gitleaks (local clone must match REPO) ---
history_scan() {
  if [ "$DRY_RUN" -eq 1 ]; then
    record "Full-history gitleaks" "dry-run" "would run: gitleaks git --redact --exit-code 1"
    return 0
  fi
  if [ "${HARDEN_SKIP_GITLEAKS:-}" = 1 ]; then
    record "Full-history gitleaks" "skip" "HARDEN_SKIP_GITLEAKS=1"
    return 0
  fi
  if ! command -v gitleaks >/dev/null 2>&1; then
    record "Full-history gitleaks" "skip" "install gitleaks locally (brew or release tarball)"
    return 0
  fi
  local here
  here="$(git -C "$root" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#.*github.com[:/]##' || true)"
  if [ "$here" != "$REPO" ]; then
    record "Full-history gitleaks" "skip" "run from a clone of $REPO (this checkout is ${here:-unknown})"
    return 0
  fi
  local log findings
  if log="$(gitleaks git --redact --verbose --exit-code 1 "$root" 2>&1)"; then
    record "Full-history gitleaks" "pass" "clean"
  else
    findings="$(grep -c '^Finding:' <<<"$log" 2>/dev/null || true)"
    [ -n "$findings" ] || findings="some"
    record "Full-history gitleaks" "fail" "$findings finding(s) — tell owner privately; values not printed"
    echo "harden-repo: gitleaks reported leak(s). Details redacted; contact the owner out of band." >&2
  fi
}

history_scan

echo ""
echo "harden-repo summary for $REPO (visibility=$visibility, dry_run=$DRY_RUN)"
printf "%-42s %-8s %s\n" "Control" "Status" "Detail"
printf "%-42s %-8s %s\n" "-------" "------" "------"
local_row=""
for local_row in "${ROWS[@]}"; do
  IFS='|' read -r name status detail <<<"$local_row"
  printf "%-42s %-8s %s\n" "$name" "$status" "$detail"
done

echo ""
echo "Docs: .factory/repo-security-baseline.md"
echo "Ruleset reference: scripts/protect-main.sh + .github/rulesets/protect-main.json"