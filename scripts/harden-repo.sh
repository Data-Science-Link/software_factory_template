#!/usr/bin/env bash
# OWNER STEP — never run by factory agents. Idempotent repo security setup.
#
# Usage:
#   scripts/harden-repo.sh [--dry-run] [--required-checks ctx1,ctx2] OWNER/REPO
#
# Applies GitHub settings (Dependabot alerts, secret scanning where the plan
# allows, default read-only GITHUB_TOKEN, private vulnerability reporting on
# public repos), reuses .github/rulesets/protect-main.json (same as
# scripts/protect-main.sh) with optional per-repo required check names, and
# runs a one-time full-history gitleaks scan (findings counted, never printed).
#
# Requires: gh logged in with Administration on the target repo, jq, and
# gitleaks on PATH for the history scan (or skip with a clear fail row).
set -euo pipefail

DRY_RUN=0
REQUIRED_CHECKS="pr-check,gitleaks"
REPO=""

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \?//'
  echo "Example: scripts/harden-repo.sh --dry-run Data-Science-Link/software_factory_template"
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage ;;
    -n | --dry-run) DRY_RUN=1; shift ;;
    --required-checks)
      [ $# -ge 2 ] || usage
      REQUIRED_CHECKS="$2"
      shift 2
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

[ -n "$REPO" ] || usage
[[ "$REPO" == */* ]] || { echo "harden-repo: expected OWNER/REPO, got $REPO" >&2; exit 2; }

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RULESET_JSON="$root/.github/rulesets/protect-main.json"
[ -f "$RULESET_JSON" ] || { echo "harden-repo: missing $RULESET_JSON" >&2; exit 1; }

declare -a ROWS=()

record() { # name status detail
  ROWS+=("$1|$2|$3")
}

is_plan_limit() { # $1 = gh error text
  grep -qiE "Upgrade to GitHub Pro|make this repository public|Advanced Security" <<<"$1"
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
  record "$desc" "fail" "$(head -n1 <<<"$out")"
  return 1
}

visibility="$(gh repo view "$REPO" --json visibility --jq .visibility 2>/dev/null || echo unknown)"
is_public=0
[ "$visibility" = "PUBLIC" ] && is_public=1

# --- Dependabot alerts ---
run_gh "Dependabot alerts" api --method PUT "repos/$REPO/vulnerability-alerts" || true

# --- Dependabot security updates ---
run_gh "Dependabot security updates" api --method PUT "repos/$REPO/automated-security-fixes" || true

# --- Default GITHUB_TOKEN read-only ---
if [ "$DRY_RUN" -eq 1 ]; then
  record "Default workflow token read-only" "dry-run" "would run: gh api --method PUT repos/$REPO/actions/permissions/workflow -f default_workflow_permissions=read"
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
    record "$label" "dry-run" "would PATCH security_and_analysis.$field=enabled, then read back"
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
    record "$label" "skip" "$(head -n1 <<<"$out")"
  else
    record "$label" "fail" "$(head -n1 <<<"$out")"
  fi
}

patch_security secret_scanning "Secret scanning"
patch_security secret_scanning_push_protection "Secret scanning push protection"

if [ "$is_public" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    record "Private vulnerability reporting" "dry-run" "would run: gh api --method PUT repos/$REPO/private-vulnerability-reporting"
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
    else
      record "Private vulnerability reporting" "fail" "$(head -n1 <<<"$out")"
    fi
  fi
else
  record "Private vulnerability reporting" "skip" "public repos only"
fi

# --- protect-main ruleset (reuse JSON, customize checks) ---
build_ruleset() {
  local checks_csv="$1"
  local checks_json
  checks_json="$(
    IFS=',' read -ra parts <<<"$checks_csv"
    local p
    for p in "${parts[@]}"; do
      p="${p// /}"
      [ -n "$p" ] || continue
      printf '{"context":"%s","integration_id":15368}\n' "$p"
    done | jq -s .
  )"
  jq --argjson checks "$checks_json" '
    (.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) = $checks
  ' "$RULESET_JSON"
}

apply_ruleset() {
  local name="protect-main"
  if [ "$DRY_RUN" -eq 1 ]; then
    record "Ruleset protect-main (checks: $REQUIRED_CHECKS)" "dry-run" "would POST/PUT rulesets API"
    return 0
  fi
  local existing plan_out
  if ! existing="$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$name\") | .id" 2>&1)"; then
    if is_plan_limit "$existing"; then
      record "Ruleset protect-main" "skip" "private GitHub Free — use pre-push hook"
      return 0
    fi
    record "Ruleset protect-main" "fail" "$(head -n1 <<<"$existing")"
    return 0
  fi
  local tmp method path verb out
  tmp="$(mktemp)"
  build_ruleset "$REQUIRED_CHECKS" >"$tmp"
  if [ -n "$existing" ]; then
    method=PUT
    path="repos/$REPO/rulesets/$existing"
    verb="updated"
  else
    method=POST
    path="repos/$REPO/rulesets"
    verb="created"
  fi
  if out="$(gh api --method "$method" "$path" --input "$tmp" --jq .id 2>&1)"; then
    record "Ruleset protect-main (checks: $REQUIRED_CHECKS)" "pass" "$verb id $out"
  else
    if is_plan_limit "$out"; then
      record "Ruleset protect-main" "skip" "private GitHub Free — use pre-push hook"
    else
      record "Ruleset protect-main" "fail" "$(head -n1 <<<"$out")"
    fi
  fi
  rm -f "$tmp"
}

apply_ruleset

# --- Full-history gitleaks (local clone must exist; run from current checkout when REPO matches) ---
history_scan() {
  if [ "$DRY_RUN" -eq 1 ]; then
    record "Full-history gitleaks" "dry-run" "would run: gitleaks git --redact --exit-code 1"
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
