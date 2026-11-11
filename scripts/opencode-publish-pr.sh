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
git show HEAD:scripts/opencode-run-facts.sh >"$PRISTINE_DIR/opencode-run-facts.sh"
for f in opencode-text-block.sh opencode-build-context.py factory-spec-check.py opencode-stage-spec-files.sh; do
  git show "HEAD:scripts/$f" >"$PRISTINE_DIR/$f"
done
chmod +x "$PRISTINE_DIR/opencode-artifact-scan.sh" \
  "$PRISTINE_DIR/opencode-git-push-scoped.sh" \
  "$PRISTINE_DIR/pr-check.sh"
block() { bash "$PRISTINE_DIR/opencode-text-block.sh" fence "$@"; }

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

note="$OC_ARTIFACT_DIR/worker-note.md"
evidence="$OC_ARTIFACT_DIR/evidence.md"
bash "$PRISTINE_DIR/opencode-artifact-scan.sh" "$patch" "$summary" "$note" "$evidence"

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

# Spec comment used by job A (scripts/opencode-build-context.py). Digits only; URL built here.
spec_id="$(sed -n 's/^spec_comment_id=//p' "$OC_ARTIFACT_DIR/context-meta.txt" 2>/dev/null | head -n 1 || true)"
case "$spec_id" in '' | none | *[!0-9]*) ;; *) spec_id_ok=yes ;; esac
case "$spec_id" in '' | none) ;; *[!0-9]*) echo "publish: invalid spec_comment_id in context-meta.txt" >&2; exit 1 ;; esac
# #92: the model job A ran (meta rewritten by the harness after the worker), re-checked against
# the default branch's models.yaml (pristine HEAD copies) before the PR body names it.
git show HEAD:scripts/factory-check-model.py >"$PRISTINE_DIR/factory-check-model.py"
git show HEAD:.factory/models.yaml >"$PRISTINE_DIR/models.yaml"
model_id="$(sed -n 's/^model_id=//p' "$OC_ARTIFACT_DIR/context-meta.txt" 2>/dev/null | head -n 1 || true)"
python3 "$PRISTINE_DIR/factory-check-model.py" --models "$PRISTINE_DIR/models.yaml" "$model_id" 2>/dev/null \
  || { echo "publish: model_id in context-meta.txt is missing or not a deepinfra model in models.yaml; refusing" >&2; exit 1; }

branch="oc/issue-${OC_ISSUE_NUMBER}-${OC_RUN_ID}"
git checkout -b "$branch"
git apply --check "$patch"
git apply "$patch"

# The committed spec must be the exact approved comment text (#75). Re-fetch that comment with
# this job's token and re-validate it (pristine build-context.py); job A's copy only when the token
# can't read issue comments (canonical_spec_into).
spec_path="factory/specs/issue-${OC_ISSUE_NUMBER}.md"
spec_file_line="not written (no approved spec comment)"
if [ "${spec_id_ok:-no}" = yes ]; then
  canonical="$PRISTINE_DIR/spec-canonical.md"
  canonical_spec_into "$canonical" "$OC_ARTIFACT_DIR/context-meta.txt" "$OC_ISSUE_NUMBER" || {
    echo "publish: cannot confirm the approved spec comment ${spec_id}; refusing" >&2; exit 1; }
  if [ ! -e "$spec_path" ]; then
    mkdir -p "$(dirname "$spec_path")"; cp "$canonical" "$spec_path"
    spec_file_line="written by publish from spec comment ${spec_id} (the patch did not include it); ${spec_source}"
  elif [ -L "$spec_path" ] || ! cmp -s "$canonical" "$spec_path"; then
    echo "publish: ${spec_path} in the patch is not the exact approved spec comment ${spec_id}; refusing" >&2
    exit 1
  else
    spec_file_line="exact copy of spec comment ${spec_id}, ${spec_source}"
  fi
fi
# #101: new scripts/*.sh|*.py that start with "#!" are staged executable (100755), because the
# worker's git-only shell cannot chmod. Reads the index only (never runs or trusts worker files);
# only files ADDED relative to $1, directly under scripts/, that are plain 100644 blobs.
mark_new_scripts_executable() { # $1 = base commit
  local p
  git diff --cached --name-only --diff-filter=A -z "$1" -- 'scripts/' | while IFS= read -r -d '' p; do
    case "$p" in scripts/*/*) continue ;; scripts/*.sh | scripts/*.py) ;; *) continue ;; esac
    [ "$(git ls-files -s -- "$p" | cut -d' ' -f1)" = 100644 ] || continue
    [ "$(git cat-file blob ":$p" 2>/dev/null | head -c 2)" = '#!' ] || continue
    git update-index --chmod=+x -- "$p"
    echo "harness: staged new script $p as executable (#101)"
  done
}
git add -A
# #197: force-stage spec-listed (or already-in-patch) files that git add -A dropped
# because they are gitignored; fail loudly if a listed Create path is missing and
# would have been ignored (dropped from the job A patch).
if [ "${spec_id_ok:-no}" = yes ] && [ -f "${canonical:-}" ]; then
  chmod +x "$PRISTINE_DIR/opencode-stage-spec-files.sh"
  bash "$PRISTINE_DIR/opencode-stage-spec-files.sh" --spec "$canonical" --patch "$patch" --fail-missing-ignored
fi
mark_new_scripts_executable HEAD

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
# Run-record facts (pr-check rule 4) come from env, artifact and the committed spec only.
facts="$(OC_BRANCH="$branch" bash "$PRISTINE_DIR/opencode-run-facts.sh")"

case "$spec_id" in
  '' ) spec_line="Spec: not fetched (no issue context step in this run)"; spec_gate="N/A (no context step)" ;;
  none ) spec_line="Spec: no approved spec comment found; worker used the issue body and the /oc instruction only"; spec_gate="no approved spec found" ;;
  * ) spec_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/issues/${OC_ISSUE_NUMBER}#issuecomment-${spec_id}"
      spec_line="Spec: approved owner spec comment ${spec_id} (${spec_url}), validated by factory-spec-check.py"; spec_gate="approved spec comment ${spec_id}" ;;
esac

# Risk class and Gate line both come from the committed spec's front matter (#76).
risk="$(OC_BRANCH="$branch" bash "$PRISTINE_DIR/opencode-run-facts.sh" --risk)"
box() { if [ "$risk" = "$1" ] || { [ "$1" = high ] && [ "$risk" = unknown ]; }; then echo x; else echo ' '; fi; }
case "$risk" in
  trivial) triage="risk class **trivial** (spec front matter)"; product_gate="N/A trivial: manager may merge after green checks" ;;
  normal | high) triage="risk class **${risk}** (spec front matter)"; product_gate="**required** (${risk} risk)" ;;
  *) triage="risk class unknown (no spec front matter): treated as **high**"; product_gate="**required** (risk unknown, treated as high)" ;;
esac

note_block="$(block "$note" 3000 "(the worker did not write a labeled note)")"
evidence_block="$(block "$evidence" 12000 "(no verification output in this run's artifact)")"

cat >"$body_file" <<EOF
## Summary

OpenCode (DeepInfra \`${model_id}\`, routed by run start) applied the owner \`/oc\` instruction on issue #${OC_ISSUE_NUMBER}. This PR was opened by GitHub Actions job **publish**; it is not merged automatically.

Closes #${OC_ISSUE_NUMBER}
Refs #38

## Spec

${spec_line}

Spec file: ${spec_file_line}.

## Success metric from the original ask

See the approved spec's success metric; this automation run reports evidence only.

## What changes in production on merge

Only the files in this PR diff. No workflow or secret changes.

## Factory loop

- [x] **1. Intake** — Triggered by owner \`/oc\` on issue #${OC_ISSUE_NUMBER}
- [x] **2. Triage** — ${triage}
- [x] **3. Spec gate** — ${spec_gate}
- [x] **4. Build** — OpenCode agent job + publish job
- [ ] **5. Review** — Grok Bot / Michael
- [ ] **6. Verify** — harness verification output in Evidence; required CI must still run on this PR (#74)
- [ ] **7. Product gate** — ${product_gate}
- [ ] **8. Ship + monitor** — merge only per risk class; workers never merge

## Risk class

- [$(box trivial)] trivial
- [$(box normal)] normal
- [$(box high)] **high**

## AI disclosure

AI disclosure: harness opencode-actions; model ${model_id}

## What I changed and why

Worker note (model-written, unverified; capped and defanged by publish):

${note_block}

## Safety checklist

- [x] No secrets in PR body (artifact scan + gitleaks)
- [x] Did not auto-merge
- [x] No change under \`.github/workflows/\` in this PR
- [x] Evidence below

## Evidence

${facts}

Verification output (run by the harness in a sandbox, not by the model; capped):

${evidence_block}

${usage_block}

${cost_line}

## Notes for reviewers

Michael: review diff and Actions logs before merge. Rotate \`DEEPINFRA_API_KEY\` if anything looks leaked (see \`.factory/actions-security.md\`).

Checks: this PR was opened with the workflow token, so pr-check and gitleaks wait for approval (#74). On this PR, use **Approve workflows to run**, or have Grok Bot run \`bash scripts/factory-kick-checks.sh <PR number>\` (close and reopen as the owner).
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
