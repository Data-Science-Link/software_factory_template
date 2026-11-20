#!/usr/bin/env bash
# OWNER STEP, not an agent step. Run once per repo, logged in to gh with an
# account that has admin rights on the repo (the agent's scoped token has no
# Administration permission, by design).
#
# Applies .github/rulesets/protect-main.json as a repository ruleset: the
# default branch can't be deleted or force-pushed, changes reach it only
# through a pull request (merge commits only, 0 approvals needed so a solo
# owner can merge their own PRs), and the gitleaks and pr-check checks must
# pass on a branch that is up to date with main. No one can bypass it.
# (integration_id 15368 in the JSON is the GitHub Actions app, so only an
# Actions run can satisfy the check.)
#
# Creates the ruleset, or updates it if one named protect-main exists.
# Safe to run again. See .factory/skills/local-agent-safety.md.
#
# Usage:
#   scripts/protect-main.sh
#   scripts/protect-main.sh --dry-run
#   scripts/protect-main.sh --verify [--checks ctx1,ctx2]
#   scripts/protect-main.sh --checks build,pytest,gitleaks --repo OWNER/REPO
set -euo pipefail

NAME="protect-main"
root="$(git rev-parse --show-toplevel)"
json="$root/.github/rulesets/protect-main.json"
[ -f "$json" ] || { echo "protect-main: missing $json" >&2; exit 1; }

DRY_RUN=0
VERIFY=0
SKIP=0
CHECKS=""
REPO=""

usage() {
  sed -n '17,21p' "$0" | sed 's/^# \?//'
  echo "Options:"
  echo "  --dry-run          Print ruleset JSON payload only (no gh api calls)"
  echo "  --verify           Read live ruleset; exit 0 if compliant, 1 if not"
  echo "  --checks CSV       Override required status check contexts (default: JSON file)"
  echo "  --repo OWNER/REPO  Target repo (default: gh repo view for this checkout)"
  echo "  --skip             No-op (for callers that lack CI checks yet)"
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage ;;
    -n | --dry-run) DRY_RUN=1; shift ;;
    --verify) VERIFY=1; shift ;;
    --skip) SKIP=1; shift ;;
    --checks)
      [ $# -ge 2 ] || usage
      CHECKS="$2"
      shift 2
      ;;
    --repo)
      [ $# -ge 2 ] || usage
      REPO="$2"
      shift 2
      ;;
    -*)
      echo "protect-main: unknown option $1" >&2
      usage
      ;;
    *)
      echo "protect-main: unexpected argument $1" >&2
      usage
      ;;
  esac
done

plan_blocked() {
  echo "This repo is private on GitHub Free, so GitHub won't enforce branch rules."
  echo "Options: GitHub Pro, or make the repo public."
  echo "Until then the local pre-push hook and the factory merge gate are the controls."
  exit 0
}

check() { # $1 = gh api output; exits on the plan 403, returns 1 on other errors
  if grep -qiE "Upgrade to GitHub Pro|make this repository public" <<<"$1"; then
    plan_blocked
  fi
}

resolve_repo() {
  if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
  fi
  [[ "$REPO" == */* ]] || { echo "protect-main: expected OWNER/REPO, got $REPO" >&2; exit 2; }
}

checks_json_from_csv() { # $1 = csv
  local csv="$1"
  IFS=',' read -ra parts <<<"$csv"
  local p
  for p in "${parts[@]}"; do
    p="${p// /}"
    [ -n "$p" ] || continue
    printf '{"context":"%s","integration_id":15368}\n' "$p"
  done | jq -s .
}

expected_check_contexts() { # prints sorted context names, one per line
  if [ -n "$CHECKS" ]; then
    IFS=',' read -ra parts <<<"$CHECKS"
    local p
    for p in "${parts[@]}"; do
      p="${p// /}"
      [ -n "$p" ] || continue
      printf '%s\n' "$p"
    done | sort -u
  else
    jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' "$json" | sort -u
  fi
}

build_payload() {
  if [ -n "$CHECKS" ]; then
    local checks_json
    checks_json="$(checks_json_from_csv "$CHECKS")"
    jq --argjson checks "$checks_json" '
      (.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) = $checks
    ' "$json"
  else
    cat "$json"
  fi
}

if [ "$SKIP" -eq 1 ]; then
  echo "protect-main: skipped (--skip)" >&2
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  resolve_repo 2>/dev/null || REPO="${REPO:-OWNER/REPO (not resolved; pass --repo)}"
  echo "protect-main: dry-run payload for $REPO (no GitHub API calls)" >&2
  build_payload
  exit 0
fi

resolve_repo

verify_ruleset() {
  local rs raw fail=0
  if ! raw="$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$NAME\")" 2>&1)"; then
    check "$raw"
    echo "protect-main verify: could not list rulesets on $REPO" >&2
    echo "$raw" >&2
    return 1
  fi
  if [ -z "$raw" ] || [ "$raw" = "null" ]; then
    echo "protect-main verify: FAIL — no ruleset named $NAME on $REPO" >&2
    return 1
  fi
  local rsid
  rsid="$(jq -r '.id' <<<"$raw")"
  if ! rs="$(gh api "repos/$REPO/rulesets/$rsid" 2>&1)"; then
    check "$rs"
    echo "protect-main verify: could not read ruleset $rsid" >&2
    echo "$rs" >&2
    return 1
  fi

  local bypass
  bypass="$(jq -r '.bypass_actors | length' <<<"$rs")"
  if [ "$bypass" != "0" ]; then
    echo "protect-main verify: FAIL — bypass_actors not empty ($bypass)" >&2
    fail=1
  else
    echo "protect-main verify: OK — no bypass actors"
  fi

  if jq -e '.rules[] | select(.type == "deletion")' <<<"$rs" >/dev/null; then
    echo "protect-main verify: OK — deletion rule present"
  else
    echo "protect-main verify: FAIL — missing deletion rule" >&2
    fail=1
  fi

  if jq -e '.rules[] | select(.type == "non_fast_forward")' <<<"$rs" >/dev/null; then
    echo "protect-main verify: OK — non_fast_forward (no force push) rule present"
  else
    echo "protect-main verify: FAIL — missing non_fast_forward rule" >&2
    fail=1
  fi

  if jq -e '.rules[] | select(.type == "pull_request")' <<<"$rs" >/dev/null; then
    echo "protect-main verify: OK — pull_request required"
  else
    echo "protect-main verify: FAIL — missing pull_request rule" >&2
    fail=1
  fi

  local strict
  strict="$(jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy // false' <<<"$rs")"
  if [ "$strict" = "true" ]; then
    echo "protect-main verify: OK — strict required status checks"
  else
    echo "protect-main verify: FAIL — strict_required_status_checks_policy is not true" >&2
    fail=1
  fi

  local live_sorted expected_sorted
  live_sorted="$(jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' <<<"$rs" | sort -u)"
  expected_sorted="$(expected_check_contexts)"
  if [ "$live_sorted" = "$expected_sorted" ]; then
    echo "protect-main verify: OK — required checks: $(tr '\n' ',' <<<"$live_sorted" | sed 's/,$//')"
  else
    echo "protect-main verify: FAIL — checks mismatch" >&2
    echo "  expected: $(tr '\n' ',' <<<"$expected_sorted")" >&2
    echo "  live:     $(tr '\n' ',' <<<"$live_sorted")" >&2
    fail=1
  fi

  if [ "$fail" -eq 0 ]; then
    echo "protect-main verify: PASS on $REPO (ruleset id $rsid)"
    return 0
  fi
  echo "protect-main verify: FAIL on $REPO (ruleset id $rsid)" >&2
  return 1
}

if [ "$VERIFY" -eq 1 ]; then
  if verify_ruleset; then
    exit 0
  fi
  exit 1
fi

if ! existing="$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$NAME\") | .id" 2>&1)"; then
  check "$existing"
  echo "protect-main: couldn't list rulesets on $REPO:" >&2
  echo "$existing" >&2
  exit 1
fi

if [ -n "$existing" ]; then
  method=PUT
  path="repos/$REPO/rulesets/$existing"
  verb="updated"
else
  method=POST
  path="repos/$REPO/rulesets"
  verb="created"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if [ -n "$CHECKS" ]; then
  build_payload >"$tmp"
  input="$tmp"
else
  input="$json"
fi

if ! out="$(gh api --method "$method" "$path" --input "$input" --jq '.id' 2>&1)"; then
  check "$out"
  echo "protect-main: GitHub refused the ruleset on $REPO:" >&2
  echo "$out" >&2
  exit 1
fi

echo "protect-main: ruleset $verb on $REPO (id $out)."
echo "Check it at https://github.com/$REPO/settings/rules"