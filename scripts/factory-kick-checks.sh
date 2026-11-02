#!/usr/bin/env bash
# Manager helper (#74): make pr-check and gitleaks run on a bot PR opened or pushed by an /oc run.
#
#   bash scripts/factory-kick-checks.sh <PR number> [--dry-run] [--force]
#
# Why: the publish jobs open PRs and push with the workflow GITHUB_TOKEN. GitHub then creates the
# pull_request runs in an approval-required state (they show as failed runs with no jobs once the
# PR is closed), and a workflow_dispatch run would not count: checks from workflow_dispatch are
# not evaluated for pull requests or required status checks. A close + reopen by the owner's
# account is a normal `reopened` event, so both required checks run on the PR head.
# Run it from the owner's own gh login (Grok Bot's manager session), never from a workflow.
#
# Refuses anything but an open same-repo PR whose head branch is oc/issue-<N>-<run_id>. Skips
# the kick when both required checks are already reported on the head commit (--force kicks
# anyway). Uses only `gh pr view`, `gh pr checks`, `gh pr close` and `gh pr reopen`.
set -euo pipefail

pr="${1:-}"; shift || true
dry=no force=no
for a in "$@"; do
  case "$a" in --dry-run) dry=yes ;; --force) force=yes ;; *) echo "kick-checks: unknown argument $a" >&2; exit 2 ;; esac
done
case "$pr" in '' | *[!0-9]*) echo "usage: factory-kick-checks.sh <PR number> [--dry-run] [--force]" >&2; exit 2 ;; esac
REQUIRED=(pr-check gitleaks)

info="$(gh pr view "$pr" --json state,isCrossRepository,headRefName,headRefOid \
  --jq '[.state, (.isCrossRepository|tostring), .headRefName, .headRefOid] | @tsv')"
IFS=$'\t' read -r state cross ref sha <<<"$info"
[ "$state" = OPEN ] || { echo "kick-checks: PR #$pr is $state, not open; refusing" >&2; exit 1; }
[ "$cross" = false ] || { echo "kick-checks: PR #$pr comes from a fork; refusing" >&2; exit 1; }
[[ "$ref" =~ ^oc/issue-[0-9]+-[0-9]+$ ]] || { echo "kick-checks: PR #$pr head '$ref' is not an /oc branch; refusing" >&2; exit 1; }
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "kick-checks: cannot read the head SHA of PR #$pr" >&2; exit 1; }

# `gh pr checks` exits non-zero while checks are pending or failing; only its output matters here.
names="$(gh pr checks "$pr" --json name --jq '.[].name' 2>/dev/null || true)"
missing=()
for c in "${REQUIRED[@]}"; do grep -qxF "$c" <<<"$names" || missing+=("$c"); done
if [ "${#missing[@]}" -eq 0 ] && [ "$force" = no ]; then
  echo "kick-checks: PR #$pr already has ${REQUIRED[*]} on ${sha:0:12}; nothing to do (--force to kick anyway)"
  exit 0
fi
echo "kick-checks: PR #$pr ($ref @ ${sha:0:12}) is missing: ${missing[*]:-none}"
if [ "$dry" = yes ]; then echo "kick-checks: dry run; would close and reopen PR #$pr"; exit 0; fi
gh pr close "$pr" >/dev/null
gh pr reopen "$pr" >/dev/null
echo "kick-checks: closed and reopened PR #$pr; now run: gh pr checks $pr --watch"
