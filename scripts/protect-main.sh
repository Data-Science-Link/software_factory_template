#!/usr/bin/env bash
# OWNER STEP, not an agent step. Run once per repo, logged in to gh with an
# account that has admin rights on the repo (the agent's scoped token has no
# Administration permission, by design).
#
# Applies .github/rulesets/protect-main.json as a repository ruleset: the
# default branch can't be deleted or force-pushed, changes reach it only
# through a pull request (merge commits only, 0 approvals needed so a solo
# owner can merge their own PRs), and the gitleaks secret-scan check must
# pass on a branch that is up to date with main. No one can bypass it.
# (integration_id 15368 in the JSON is the GitHub Actions app, so only an
# Actions run can satisfy the check.)
#
# Creates the ruleset, or updates it if one named protect-main exists.
# Safe to run again. See .factory/skills/local-agent-safety.md.
set -euo pipefail

NAME="protect-main"
root="$(git rev-parse --show-toplevel)"
json="$root/.github/rulesets/protect-main.json"
[ -f "$json" ] || { echo "protect-main: missing $json" >&2; exit 1; }

repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"

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

if ! existing="$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$NAME\") | .id" 2>&1)"; then
  check "$existing"
  echo "protect-main: couldn't list rulesets on $repo:" >&2
  echo "$existing" >&2
  exit 1
fi

if [ -n "$existing" ]; then
  method=PUT; path="repos/$repo/rulesets/$existing"; verb="updated"
else
  method=POST; path="repos/$repo/rulesets"; verb="created"
fi

if ! out="$(gh api --method "$method" "$path" --input "$json" --jq '.id' 2>&1)"; then
  check "$out"
  echo "protect-main: GitHub refused the ruleset on $repo:" >&2
  echo "$out" >&2
  exit 1
fi

echo "protect-main: ruleset $verb on $repo (id $out)."
echo "Check it at https://github.com/$repo/settings/rules"
