#!/usr/bin/env bash
# Job B helper for /oc fix: re-guard the PR, scan the artifact, apply the patch on the PR head,
# push one commit to the SAME branch (lease on the head job A saw), then comment run facts and
# the worker note on the PR. No DeepInfra key. Opens no PR and never merges.
#
# Trusted scripts: pristine HEAD copies from this script's checkout (the default branch). The
# PR head is checked out separately in OC_PR_DIR; nothing from it is executed.
set -euo pipefail

: "${OC_PR_NUMBER:?OC_PR_NUMBER is required}"
: "${OC_RUN_ID:?OC_RUN_ID is required}"
: "${OC_ARTIFACT_DIR:?OC_ARTIFACT_DIR is required}"
: "${OC_PR_DIR:?OC_PR_DIR is required (PR head checkout)}"
: "${OC_EXPECTED_HEAD_SHA:?OC_EXPECTED_HEAD_SHA is required (from job A)}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

case "$OC_PR_NUMBER$OC_RUN_ID" in *[!0-9]*) echo "publish-fix: PR number and run id must be digits" >&2; exit 1 ;; esac
[[ "$OC_EXPECTED_HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "publish-fix: expected head SHA is malformed" >&2; exit 1; }

trusted="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OC_ARTIFACT_DIR="$(cd "$OC_ARTIFACT_DIR" && pwd)"
patch="$OC_ARTIFACT_DIR/changes.patch"
note="$OC_ARTIFACT_DIR/worker-note.md"

PRISTINE_DIR="$(mktemp -d)"
trap 'rm -rf "$PRISTINE_DIR"' EXIT
for f in opencode-artifact-scan.sh opencode-git-push-lease.sh opencode-run-facts.sh opencode-build-fix-context.py; do
  git -C "$trusted" show "HEAD:scripts/$f" >"$PRISTINE_DIR/$f"
done
scan() { bash "$PRISTINE_DIR/opencode-artifact-scan.sh" "$@"; }

# 1. Guard again from the API: open, same repo, oc/issue-<N>-<run_id>, head still where job A saw it.
facts="$(python3 "$PRISTINE_DIR/opencode-build-fix-context.py" --check-pr \
  --repo "$GITHUB_REPOSITORY" --pr "$OC_PR_NUMBER" --expect-head "$OC_EXPECTED_HEAD_SHA" \
  ${OC_PR_FIXTURE:+--from-json "$OC_PR_FIXTURE"})"
fact() { sed -n "s/^$1=//p" <<<"$facts" | head -n 1; }
branch="$(fact head_ref)"; issue="$(fact issue_number)"
[[ "$branch" =~ ^oc/issue-[0-9]+-[0-9]+$ ]] || { echo "publish-fix: guard returned a bad branch" >&2; exit 1; }

# 2. Artifact must describe this same PR and head.
meta() { sed -n "s/^$1=//p" "$OC_ARTIFACT_DIR/fix-meta.txt" 2>/dev/null | head -n 1; }
if [ "$(meta pr_number)" != "$OC_PR_NUMBER" ] || [ "$(meta head_sha)" != "$OC_EXPECTED_HEAD_SHA" ] \
  || [ "$(meta head_ref)" != "$branch" ]; then
  echo "publish-fix: artifact fix-meta.txt does not match this PR/head; refusing" >&2
  exit 1
fi

# 3. Scan (secrets + path policy on the patch, relative to the PR head).
scan "$patch" "$OC_ARTIFACT_DIR/summary.md" "$note"
[ -s "$patch" ] || { echo "publish-fix: empty patch" >&2; exit 1; }

# 4. Apply on the PR head and commit.
cd "$OC_PR_DIR"
if [ "$(git rev-parse HEAD)" != "$OC_EXPECTED_HEAD_SHA" ]; then
  echo "publish-fix: PR checkout is not at the expected head; refusing" >&2
  exit 1
fi
git apply --check "$patch"
git apply "$patch"
git add -A
if git diff --cached --quiet; then
  echo "publish-fix: patch applied but nothing staged" >&2
  exit 1
fi
git commit -q -m "OpenCode fix: PR #${OC_PR_NUMBER} review (run ${OC_RUN_ID})"
new_sha="$(git rev-parse HEAD)"
files="$(git diff --name-only HEAD~1 HEAD)"

# 5. Comment body: script facts + labeled, defanged worker note.
body="$OC_ARTIFACT_DIR/fix-comment.md"
usage_metrics="$OC_ARTIFACT_DIR/usage-metrics.md"
usage_block="$(cat "$usage_metrics" 2>/dev/null || printf '%s\n\n%s' '## Token usage (opencode stats)' '(not available)')"
cost_line="Cost: not measured on DeepInfra (opencode stats unavailable)"
reported="$(sed -n 's/^- OpenCode-reported cost: //p' "$usage_metrics" 2>/dev/null | head -n 1 || true)"
if [[ "$reported" =~ ^\$[0-9] ]]; then cost_line="Cost: ${reported} on DeepInfra (OpenCode stats)"; fi
run_facts="$(OC_ISSUE_NUMBER="$issue" OC_BRANCH="$branch" bash "$PRISTINE_DIR/opencode-run-facts.sh")"
# Model text: no fences, mentions or HTML comments can escape the quoted block.
worker_note="$(head -c 3000 "$note" 2>/dev/null | sed -E 's/```/'"'''"'/g; s/@/(at)/g; s/<!--/<! --/g')"
[ -n "$worker_note" ] || worker_note="(the worker did not write a labeled note)"
repo_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}"

{
  echo "## /oc fix run ${OC_RUN_ID}"
  echo
  echo "Pushed \`${new_sha:0:12}\` to \`${branch}\` on top of \`${OC_EXPECTED_HEAD_SHA:0:12}\` (one commit; this run opened no new PR and merged nothing)."
  echo
  echo "Files in this commit:"
  bt='`'
  while IFS= read -r f; do printf -- '- %s%s%s\n' "$bt" "$f" "$bt"; done <<<"$files"
  echo
  echo "AI disclosure: harness opencode-actions; model deepseek-ai/DeepSeek-V4-Flash-0731"
  echo
  echo "$run_facts"
  echo
  echo "$usage_block"
  echo
  echo "$cost_line"
  echo
  echo "### What I changed and why (worker note: model-written, unverified)"
  echo
  echo '```text'
  echo "$worker_note"
  echo '```'
  echo
  echo "Checks: a push made with the workflow token does not start \`pull_request\` checks (#74). Close and reopen this PR (or push by hand) so pr-check and gitleaks run on \`${new_sha:0:12}\` before merge."
  echo
  echo "Run: ${repo_url}/actions/runs/${OC_RUN_ID}"
} >"$body"
scan "$body"

# 6. Push (lease on the head job A saw), then comment.
if [ -z "${GH_TOKEN:-}" ]; then
  echo "publish-fix: GH_TOKEN is required to push and comment" >&2
  exit 1
fi
bash "$PRISTINE_DIR/opencode-git-push-lease.sh" "$branch" "$OC_EXPECTED_HEAD_SHA"
gh pr comment "$OC_PR_NUMBER" --repo "$GITHUB_REPOSITORY" --body-file "$body"
echo "publish-fix: pushed ${new_sha:0:12} to ${branch} and commented on PR #${OC_PR_NUMBER}"
