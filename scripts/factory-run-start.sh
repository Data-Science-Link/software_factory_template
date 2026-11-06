#!/usr/bin/env bash
# #92 run start step for /oc (build) and /oc fix, before OpenCode is installed and before any
# DeepInfra spend. Saves the comments run start reads (read-only GH_TOKEN, this step only; the
# DeepInfra key is not in this step), then runs scripts/factory-run-start.py, which routes the
# model from .factory/models.yaml and checks the per-issue cap. Exit 3 = refused: the job stops
# and the notify job posts the reason from the refused=<code> output.
#
# Env: OC_KIND build|fix, OC_ARTIFACT_DIR, GITHUB_REPOSITORY, GH_TOKEN (read-only; used by gh only,
#   never printed), and OC_ISSUE_NUMBER (build) or OC_PR_NUMBER (fix; the linked issue number and
#   its approved spec come from the fix context step: fix-meta.txt and spec.md).
# Outputs ($GITHUB_OUTPUT, from factory-run-start.py): model, model_id, routed_rule, route_reason,
#   retry_of, predicted_cost_usd, prior_spend_usd, cap_usd, run_id; or refused=<code> on refusal.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${OC_ARTIFACT_DIR:?OC_ARTIFACT_DIR is required}"

repo="${GITHUB_REPOSITORY:-}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "run-start: GITHUB_REPOSITORY must be owner/repo" >&2; exit 2; }

digits() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac; }

kind="${OC_KIND:-}"
case "$kind" in
  build)
    issue="${OC_ISSUE_NUMBER:-}"
    digits "$issue" || { echo "run-start: OC_ISSUE_NUMBER must be digits" >&2; exit 2; }
    targets=("$issue")
    ;;
  fix)
    pr="${OC_PR_NUMBER:-}"
    digits "$pr" || { echo "run-start: OC_PR_NUMBER must be digits" >&2; exit 2; }
    # Linked issue from the fix context step (it guarded the oc/issue-<N>-<run_id> head ref).
    issue="$(sed -n 's/^issue_number=//p' "$OC_ARTIFACT_DIR/fix-meta.txt" 2>/dev/null | head -n 1 || true)"
    digits "$issue" || { echo "run-start: no linked issue number in fix-meta.txt" >&2; exit 2; }
    targets=("$issue" "$pr")
    ;;
  *) echo "run-start: OC_KIND must be build or fix" >&2; exit 2 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# One JSON object per comment (only the fields run start reads), then one array per target.
read -r -d '' to_array <<'PY' || true
import json, sys
rows = [json.loads(line) for line in sys.stdin if line.strip()]
json.dump(rows, sys.stdout)
PY
args=()
for n in "${targets[@]}"; do
  gh api --paginate "repos/${repo}/issues/${n}/comments" \
    --jq '.[] | {user: {login: .user.login}, author_association: .author_association, created_at: .created_at, body: .body}' \
    | python3 -c "$to_array" >"$tmp/comments-$n.json"
  args+=(--comments-json "$tmp/comments-$n.json")
done
unset GH_TOKEN GITHUB_TOKEN

python3 "$here/factory-run-start.py" --kind "$kind" --issue "$issue" \
  --spec "$OC_ARTIFACT_DIR/spec.md" "${args[@]}" --out "$OC_ARTIFACT_DIR/run-start.json"
