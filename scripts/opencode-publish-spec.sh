#!/usr/bin/env bash
# Job B of /oc spec (#78): post job A's draft spec comment (or a "no draft" note) on the issue.
# Token: issues: write only (plus contents: read for the checkout). No repo write, no PR.
# Never trusts job A: scans the comment again and re-checks it with pristine copies of the scripts
# from this checkout. If job A failed or left no artifact, posts a short failure note with the run
# link instead, so a failed run never goes silent.
#
# Env: OC_ISSUE_NUMBER, OC_RUN_ID, OC_ARTIFACT_DIR, GITHUB_REPOSITORY, GH_TOKEN (gh), and
#      OC_AGENT_RESULT (needs.agent.result: success | failure | cancelled).
set -euo pipefail

: "${OC_ISSUE_NUMBER:?OC_ISSUE_NUMBER is required}"
: "${OC_RUN_ID:?OC_RUN_ID is required}"
: "${OC_ARTIFACT_DIR:?OC_ARTIFACT_DIR is required}"
case "$OC_ISSUE_NUMBER" in '' | *[!0-9]*) echo "publish-spec: issue number must be digits" >&2; exit 2 ;; esac
case "$OC_RUN_ID" in '' | *[!0-9]*) echo "publish-spec: run id must be digits" >&2; exit 2 ;; esac
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${OC_RUN_ID}"

PRISTINE_DIR="$(mktemp -d)"
trap 'rm -rf "$PRISTINE_DIR"' EXIT
# Same layout as the repo (scripts/ + .factory/models.yaml), so the helper finds models.yaml.
P="$PRISTINE_DIR/scripts"
mkdir -p "$P" "$PRISTINE_DIR/.factory"
for f in opencode-artifact-scan.sh opencode-spec-draft.py factory-spec-check.py factory-predict-cost.py opencode-text-block.sh; do
  git show "HEAD:scripts/$f" >"$P/$f"
done
git show HEAD:.factory/models.yaml >"$PRISTINE_DIR/.factory/models.yaml"

post() { gh issue comment "$OC_ISSUE_NUMBER" --repo "${GITHUB_REPOSITORY:?}" --body-file "$1"; }

comment="$OC_ARTIFACT_DIR/spec-comment.md"
if [ "${OC_AGENT_RESULT:-}" != success ] || [ ! -s "$comment" ]; then
  note="$PRISTINE_DIR/failed.md"
  {
    echo "<!-- factory-spec-draft-failed v1 -->"
    echo "**\`/oc spec\`: no draft posted.** The spec worker job ended with result \`${OC_AGENT_RESULT:-unknown}\` before a draft was ready."
    echo ""
    echo "- Run: ${run_url} (the job log and summary say why; DeepInfra spend may still have happened)"
  } >"$note"
  post "$note"
  echo "publish-spec: posted a failure note (agent result ${OC_AGENT_RESULT:-unknown})"
  exit 0
fi

bash "$P/opencode-artifact-scan.sh" "$comment"
python3 "$P/opencode-spec-draft.py" check-comment "$comment" --issue "$OC_ISSUE_NUMBER"
post "$comment"
echo "publish-spec: posted $(head -n 1 "$comment")"
