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
  if grep -qiE "Upgrade to GitHub Pro|make this repository public|Advanced Security|422|403" <<<"$out"; then
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
  record "Default workflow token read-only" "dry-run" "would PATCH repos/$REPO default_workflow_permissions=read"
else
  if gh api --method PATCH "repos/$REPO" \
    -f default_workflow_permissions=read \
    -F can_admins_bypass=false >/dev/null 2>&1; then
    record "Default workflow token read-only" "pass" "read"
  else
    record "Default workflow token read-only" "fail" "PATCH repos/$REPO refused"
  fi
fi

# --- Secret scanning + push protection (plan-dependent) ---
patch_security() {
  local field="$1"
  local label="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    record "$label" "dry-run" "would enable via security_and_analysis"
    return 0
  fi
  local body
  body="$(jq -n --arg f "$field" '{security_and_analysis: {($f): {status: "enabled"}}}')"
  if gh api --method PATCH "repos/$REPO" --input - <<<"$body" >/dev/null 2>&1; then
    record "$label" "pass" "enabled"
  else
    record "$label" "skip" "not available on this plan or visibility"
  fi
}

patch_security secret_scanning "Secret scanning"
patch_security secret_scanning_push_protection "Secret scanning push protection"

if [ "$is_public" -eq 1 ]; then
  patch_security private_vulnerability_reporting "Private vulnerability reporting"
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
    if grep -qiE "Upgrade to GitHub Pro|make this repository public" <<<"$existing"; then
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
    if grep -qiE "Upgrade to GitHub Pro|make this repository public" <<<"$out"; then
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
  here="$(git -C "$root" remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/](.+)(\.git)?$#\1#' || true)"
  if [ "$here" != "$REPO" ]; then
    record "Full-history gitleaks" "skip" "run from a clone of $REPO (this checkout is ${here:-unknown})"
    return 0
  fi
  local log findings
  if log="$(gitleaks git --redact --verbose --exit-code 1 "$root" 2>&1)"; then
    record "Full-history gitleaks" "pass" "clean"
  else
    findings="$(grep -c '^Finding:' <<<"$log" 2>/dev/null || echo "some")"
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
