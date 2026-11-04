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
for f in opencode-artifact-scan.sh opencode-git-push-lease.sh opencode-run-facts.sh opencode-build-fix-context.py \
  opencode-build-context.py factory-spec-check.py opencode-text-block.sh; do
  git -C "$trusted" show "HEAD:scripts/$f" >"$PRISTINE_DIR/$f"
done
# #102: the default branch's scripts, from this job's trusted checkout (not the PR head or job A).
git -C "$trusted" ls-tree -r --name-only HEAD -- scripts/ >"$PRISTINE_DIR/base-scripts.txt"
[ -s "$PRISTINE_DIR/base-scripts.txt" ] || { echo "publish-fix: could not list the default branch scripts" >&2; exit 1; }
scan() { bash "$PRISTINE_DIR/opencode-artifact-scan.sh" "$@"; }
scan_patch() { bash "$PRISTINE_DIR/opencode-artifact-scan.sh" --base-scripts "$PRISTINE_DIR/base-scripts.txt" "$@"; }

# Canonical approved spec text into $1. First choice: re-fetch spec comment $spec_id with this
# job's token. If the token may not read issue comments (HTTP 403: the publish job has no
# issues: read), fall back to job A's copy (<artifact>/spec.md), re-validated with the pristine
# checker and matched to the spec_sha256 job A recorded, and say so in the PR (spec_source).
canonical_spec_into() {
  local dest="$1" meta_path="$2" rc=0 want
  python3 "$PRISTINE_DIR/opencode-build-context.py" --print-spec "$spec_id" \
    --repo "${GITHUB_REPOSITORY:-}" --issue "$3" ${OC_SPEC_FIXTURE:+--from-json "$OC_SPEC_FIXTURE"} >"$dest" || rc=$?
  if [ "$rc" -eq 0 ]; then
    spec_source="checked by publish against the comment"
    return 0
  fi
  [ "$rc" -eq 3 ] || return 1
  want="$(sed -n 's/^spec_sha256=//p' "$meta_path" 2>/dev/null | head -n 1)"
  python3 "$PRISTINE_DIR/opencode-build-context.py" --check-spec-file "$OC_ARTIFACT_DIR/spec.md" >"$dest" || return 1
  if [ -z "$want" ] || [ "$(sha256sum <"$dest" | cut -d' ' -f1)" != "$want" ]; then
    echo "publish: job A's spec.md does not match its spec_sha256; refusing" >&2
    return 1
  fi
  spec_source="checked by publish against job A's copy only (this job's token can't read issue comments; give the publish job issues: read)"
  echo "publish: cannot re-fetch spec comment ${spec_id} (HTTP 403); using job A's validated copy" >&2
}

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
evidence="$OC_ARTIFACT_DIR/evidence.md"
scan_patch "$patch" "$OC_ARTIFACT_DIR/summary.md" "$note" "$evidence"
[ -s "$patch" ] || { echo "publish-fix: empty patch" >&2; exit 1; }

# 4. Apply on the PR head and commit.
cd "$OC_PR_DIR"
if [ "$(git rev-parse HEAD)" != "$OC_EXPECTED_HEAD_SHA" ]; then
  echo "publish-fix: PR checkout is not at the expected head; refusing" >&2
  exit 1
fi
git apply --check "$patch"
git apply "$patch"
# The spec file on the branch must be the exact approved comment (#75): re-fetch and re-validate
# it with this job's token (pristine build-context.py); job A's copy only when the token can't
# read issue comments (canonical_spec_into).
spec_id="$(meta spec_comment_id)"
spec_path="factory/specs/issue-${issue}.md"
spec_file_line="not checked (no approved spec comment)"
case "$spec_id" in
  '' | none) ;;
  *[!0-9]*) echo "publish-fix: invalid spec_comment_id in fix-meta.txt" >&2; exit 1 ;;
  *)
    canonical="$PRISTINE_DIR/spec-canonical.md"
    canonical_spec_into "$canonical" "$OC_ARTIFACT_DIR/fix-meta.txt" "$issue" || {
      echo "publish-fix: cannot confirm the approved spec comment ${spec_id}; refusing" >&2; exit 1; }
    if [ -L "$spec_path" ] || ! cmp -s "$canonical" "$spec_path"; then
      echo "publish-fix: ${spec_path} after the patch is not the exact approved spec comment ${spec_id}; refusing" >&2
      exit 1
    fi
    spec_file_line="exact copy of spec comment ${spec_id}, ${spec_source}"
    ;;
esac
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
run_facts="$(OC_RUN_KIND=fix OC_ISSUE_NUMBER="$issue" OC_BRANCH="$branch" bash "$PRISTINE_DIR/opencode-run-facts.sh")"
# Model text and command output: no fences, mentions or HTML comments can escape the blocks.
block() { bash "$PRISTINE_DIR/opencode-text-block.sh" fence "$@"; }
note_block="$(block "$note" 3000 "(the worker did not write a labeled note)")"
evidence_block="$(block "$evidence" 12000 "(no verification output in this run's artifact)")"
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
  echo "Spec file: ${spec_file_line}."
  echo
  echo "### What I changed and why (worker note: model-written, unverified)"
  echo
  echo "$note_block"
  echo
  echo "### Evidence: verification output (run by the harness in a sandbox, not by the model; capped)"
  echo
  echo "$evidence_block"
  echo
  echo "Checks: a push made with the workflow token leaves pr-check and gitleaks waiting for approval (#74). Use **Approve workflows to run** on this PR, or have Grok Bot run \`bash scripts/factory-kick-checks.sh ${OC_PR_NUMBER}\` (close and reopen as the owner), so they run on \`${new_sha:0:12}\` before merge."
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
