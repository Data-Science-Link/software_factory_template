#!/usr/bin/env bash
# Print the factory-run fact lines for an /oc publish PR body (PR template v2, pr-check rule 4).
# Script only: every value comes from the run env, the artifact, or the committed spec. No model text.
#
# Env:
#   OC_ISSUE_NUMBER, OC_RUN_ID   required
#   OC_ARTIFACT_DIR              dir with usage-metrics.md (optional file)
#   OC_SPEC_FILE                 spec path, default factory/specs/issue-<N>.md (read from the
#                                working tree, i.e. after the patch is applied)
#   GITHUB_SERVER_URL, GITHUB_REPOSITORY, OC_BRANCH   for links (optional)
# Missing facts are printed as "not available" so pr-check fails loudly instead of guessing.
set -euo pipefail

: "${OC_ISSUE_NUMBER:?OC_ISSUE_NUMBER is required}"
: "${OC_RUN_ID:?OC_RUN_ID is required}"
metrics="${OC_ARTIFACT_DIR:-.}/usage-metrics.md"
spec="${OC_SPEC_FILE:-factory/specs/issue-${OC_ISSUE_NUMBER}.md}"
repo_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}"

metric() { if [ -f "$metrics" ]; then sed -n "s/^- $1: //p" "$metrics" | head -1; fi; }
# Top-level key from the spec's YAML front matter (first --- ... --- block).
front() {
  [ -f "$spec" ] || return 0
  awk -v k="$1" '/^---[[:space:]]*$/ { n++; next } n == 1 && index($0, k ":") == 1 {
    v = substr($0, length(k) + 2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); gsub(/^["\x27]|["\x27]$/, "", v); print v; exit }' "$spec"
}

t_in="$(metric 'Input tokens')"; t_cached="$(metric 'Cache read')"; t_out="$(metric 'Output tokens')"
reported="$(metric 'OpenCode-reported cost')"
predicted="$(front predicted_cost_usd)"
risk="$(front risk)"

if [ -n "$t_in" ] && [ -n "$t_out" ]; then
  tokens="${t_in} / ${t_cached:-0} / ${t_out} (opencode stats --models, as printed; in excludes cache reads)"
else
  tokens="not available"
fi
if [[ "$reported" =~ ^\$[0-9] ]]; then
  actual="${reported}"; method="provider_reported (OpenCode stats)"
else
  # Run-record convention for unmetered runs: actual_cost_usd = 0 with cost_method not_measured.
  actual="\$0 (not measured)"; method="not_measured"
fi
if [[ "$predicted" =~ ^[0-9.]+$ ]]; then predicted="\$${predicted} (spec front matter)"; else predicted="not available (no spec front matter)"; fi
case "$risk" in
  trivial) gate="risk trivial: manager may merge after green checks and a passing gate" ;;
  normal|high) gate="risk ${risk}: owner product gate required (Michael approves before merge)" ;;
  *) gate="risk unknown (no spec): treat as high, owner product gate required" ;;
esac

echo "<!-- factory-run:start -->"
echo "Run ID: ${OC_RUN_ID}"
echo "Workflow run: ${repo_url}/actions/runs/${OC_RUN_ID}"
echo "Tokens in / cached / out: ${tokens}"
echo "Predicted cost: ${predicted}"
echo "Actual cost: ${actual}"
echo "Cost method: ${method}"
echo "Gate: ${gate}"
if [ -f "$spec" ]; then
  if [ -n "${OC_BRANCH:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    echo "Spec: [${spec}](${repo_url}/blob/${OC_BRANCH}/${spec})"
  else
    echo "Spec: ${spec}"
  fi
else
  echo "Spec: none (this run did not add factory/specs/issue-<N>.md)"
fi
echo "<!-- factory-run:end -->"
