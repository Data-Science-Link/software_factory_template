#!/usr/bin/env bash
# Job B helper: scan artifact again, apply patch, open PR. No DeepInfra key.
set -euo pipefail

: "${OC_ISSUE_NUMBER:?OC_ISSUE_NUMBER is required}"
: "${OC_RUN_ID:?OC_RUN_ID is required}"
: "${OC_ARTIFACT_DIR:?OC_ARTIFACT_DIR is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"

patch="$OC_ARTIFACT_DIR/changes.patch"
summary="$OC_ARTIFACT_DIR/summary.md"

# Pristine copies from base ref — never run repo scripts that the patch might replace.
PRISTINE_DIR="$(mktemp -d)"
trap 'rm -rf "$PRISTINE_DIR"' EXIT
git show HEAD:scripts/opencode-artifact-scan.sh >"$PRISTINE_DIR/opencode-artifact-scan.sh"
git show HEAD:scripts/opencode-git-push-scoped.sh >"$PRISTINE_DIR/opencode-git-push-scoped.sh"
git show HEAD:scripts/pr-check.sh >"$PRISTINE_DIR/pr-check.sh"
chmod +x "$PRISTINE_DIR/opencode-artifact-scan.sh" \
  "$PRISTINE_DIR/opencode-git-push-scoped.sh" \
  "$PRISTINE_DIR/pr-check.sh"

bash "$PRISTINE_DIR/opencode-artifact-scan.sh" "$patch" "$summary"

if [ ! -s "$patch" ]; then
  echo "publish: empty patch" >&2
  exit 1
fi

# Derive changed paths from the patch before applying anything.
git apply --stat "$patch" >"$OC_ARTIFACT_DIR/patch-stat.txt" 2>/dev/null || true
grep -E '^ [^|]+ \|' "$OC_ARTIFACT_DIR/patch-stat.txt" 2>/dev/null | awk '{print $1}' >"$OC_ARTIFACT_DIR/pr-files.txt" || true
if [ ! -s "$OC_ARTIFACT_DIR/pr-files.txt" ]; then
  # Fallback: parse diff headers
  grep -E '^(\+\+\+ b/|--- b/|diff --git a/.+ b/)' "$patch" | sed -E 's/^\+\+\+ b\///; s/^--- b\///; s/^diff --git a\/[^ ]+ b\///' | sort -u | grep -v '^$' >"$OC_ARTIFACT_DIR/pr-files.txt" || true
fi

branch="oc/issue-${OC_ISSUE_NUMBER}-${OC_RUN_ID}"
git checkout -b "$branch"
git apply --check "$patch"
git apply "$patch"
git add -A

if git diff --cached --quiet; then
  echo "publish: patch applied but nothing staged" >&2
  exit 1
fi

git commit -m "OpenCode: issue #${OC_ISSUE_NUMBER} (run ${OC_RUN_ID})"

body_file="$OC_ARTIFACT_DIR/pr-body.md"
usage_metrics="$OC_ARTIFACT_DIR/usage-metrics.md"
usage_block="$(cat "$usage_metrics" 2>/dev/null || echo '## Token usage (opencode stats)'$'\n\n(not available)')"
cost_line="Cost: not measured on DeepInfra (opencode stats unavailable)"
if [ -f "$usage_metrics" ]; then
  reported="$(grep -F 'OpenCode-reported cost:' "$usage_metrics" | sed 's/^- OpenCode-reported cost: //' || true)"
  if [ -n "$reported" ] && [ "$reported" != "not available" ] && [ "$reported" != "not measured" ]; then
    cost_line="Cost: ${reported} on DeepInfra (OpenCode stats; factory metering is issue #30)"
  fi
fi

# Spec comment used by job A (scripts/opencode-build-context.py). Digits only; URL built here.
spec_id="$(sed -n 's/^spec_comment_id=//p' "$OC_ARTIFACT_DIR/context-meta.txt" 2>/dev/null | head -n 1 || true)"
case "$spec_id" in
  '' ) spec_line="Spec: not fetched (no issue context step in this run)"; spec_gate="N/A (no context step)" ;;
  none ) spec_line="Spec: no approved spec comment found; worker used the issue body and the /oc instruction only"; spec_gate="no approved spec found" ;;
  *[!0-9]* ) echo "publish: invalid spec_comment_id in context-meta.txt" >&2; exit 1 ;;
  * ) spec_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/issues/${OC_ISSUE_NUMBER}#issuecomment-${spec_id}"
      spec_line="Spec: approved owner spec comment ${spec_id} (${spec_url}), validated by factory-spec-check.py"; spec_gate="approved spec comment ${spec_id}" ;;
esac

cat >"$body_file" <<EOF
## Summary

OpenCode (DeepInfra \`deepseek-ai/DeepSeek-V4-Flash-0731\`) applied the owner \`/oc\` instruction on issue #${OC_ISSUE_NUMBER}. This PR was opened by GitHub Actions job **publish**; it is not merged automatically.

Closes #${OC_ISSUE_NUMBER}
Refs #38

## Spec

${spec_line}

## Success metric from the original ask

N/A — spike / trivial automation run.

## What changes in production on merge

Only the files in this PR diff. No workflow or secret changes.

## Factory loop

- [x] **1. Intake** — Triggered by owner \`/oc\` on issue #${OC_ISSUE_NUMBER}
- [x] **2. Triage** — spike run; **high** risk (Actions + secret on agent job)
- [x] **3. Spec gate** — ${spec_gate}
- [x] **4. Build** — OpenCode agent job + publish job
- [ ] **5. Review** — Grok Bot / Michael
- [ ] **6. Verify** — Michael checks run logs and this PR for leaks
- [ ] **7. Product gate** — **required** (high risk)
- [ ] **8. Ship + monitor** — Michael merges if satisfied; workers never merge

## Risk class

- [ ] trivial
- [ ] normal
- [x] **high** (Actions harness + DeepInfra secret)

## AI disclosure

AI disclosure: harness opencode-actions; model deepseek-ai/DeepSeek-V4-Flash-0731

## Safety checklist

- [x] No secrets in PR body (artifact scan + gitleaks)
- [x] Did not auto-merge
- [x] No change under \`.github/workflows/\` in this PR
- [x] Evidence below

## Evidence

Workflow run: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${OC_RUN_ID}

${usage_block}

${cost_line}

## Notes for reviewers

Michael: review diff and Actions logs before merge. Rotate \`DEEPINFRA_API_KEY\` if anything looks leaked (see \`.factory/actions-security.md\`).
EOF

git diff --name-only HEAD~1..HEAD >"$OC_ARTIFACT_DIR/pr-files.txt"
if ! bash "$PRISTINE_DIR/pr-check.sh" "$body_file" "$OC_ARTIFACT_DIR/pr-files.txt"; then
  echo "publish: pr-check failed on generated body" >&2
  exit 1
fi

# Push only after scan/apply/commit/pr-check (checkout stays persist-credentials: false).
if [ -z "${GH_TOKEN:-}" ]; then
  echo "publish: GH_TOKEN is required to push and open the PR" >&2
  exit 1
fi
bash "$PRISTINE_DIR/opencode-git-push-scoped.sh" "$branch"

gh pr create \
  --title "OpenCode: issue #${OC_ISSUE_NUMBER} (run ${OC_RUN_ID})" \
  --body-file "$body_file" \
  --base main \
  --head "$branch"

echo "publish: pull request opened for branch $branch"
