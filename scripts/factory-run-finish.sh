#!/usr/bin/env bash
# Record job for every /oc spec, build and fix run (#31). Runs on a fresh default-branch checkout
# (never the worker's patch), after the agent and publish jobs, even when they failed:
#   1. builds factory/runs/<run_id>.json with scripts/factory-run-end.sh from the agent job's
#      metering artifact (run-clock.json, run-start.json, spec.md, usage/*.json, key-spend.json);
#   2. marks key spend "concurrent" when another /oc run overlapped this one (same DeepInfra key);
#   3. posts the record on the issue under <!-- factory-run-record --> (run start reads these for
#      the issue's prior spend), once per run attempt;
#   4. on a build or fix PR, rewrites the PR body's factory-run block and Cost: line
#      (scripts/factory-run-body.sh).
# Needs GH_TOKEN with issues: write, pull-requests: write, actions: read. No DeepInfra key.
# Env: OC_KIND (build|fix|spec), OC_ARTIFACT_DIR (the downloaded metering artifact), OC_ISSUE_NUMBER
# (build/spec; fix reads fix-meta.txt), OC_AGENT_RESULT, OC_PUBLISH_RESULT, optional OC_REFUSED,
# OC_TRIGGER_URL, plus the GitHub-provided GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT.
# Exit: 0 recorded (or nothing to record), 1 a step failed (the workflow run shows red).
set -euo pipefail

say() { echo "run-finish: $*" >&2; }
: "${OC_KIND:?OC_KIND is required}"
: "${GITHUB_REPOSITORY:?}" "${GITHUB_RUN_ID:?}" "${GITHUB_RUN_ATTEMPT:?}"
art="${OC_ARTIFACT_DIR:-}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
run_id="gha-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
repo_url="https://github.com/${GITHUB_REPOSITORY}"

case "$OC_KIND" in build) kind_label="/oc" ;; fix) kind_label="/oc fix" ;; spec) kind_label="/oc spec" ;; *) say "OC_KIND must be build, fix or spec"; exit 1 ;; esac
if [ -z "$art" ] || [ ! -f "$art/run-clock.json" ]; then
  say "no metering artifact (the worker never started: refused or failed early); nothing to record"
  echo "Run record: none (the worker never started, so no DeepInfra spend to record)" >>"$summary"
  exit 0
fi

json_get() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2" 2>/dev/null || true; }
meta() { sed -n "s/^$1=//p" "$art/fix-meta.txt" 2>/dev/null | head -n 1; }

issue="${OC_ISSUE_NUMBER:-}"
pr=""
if [ "$OC_KIND" = fix ]; then issue="$(meta issue_number)"; pr="$(meta pr_number)"; fi
[[ "$issue" =~ ^[0-9]+$ ]] || { say "no issue number"; exit 1; }
[ -z "$pr" ] || [[ "$pr" =~ ^[0-9]+$ ]] || { say "bad PR number"; exit 1; }

# Work on a copy so the downloaded artifact stays as uploaded.
rec="$(mktemp -d)"
trap 'rm -rf "$rec"' EXIT
for f in run-clock.json run-start.json spec.md key-spend.json; do
  [ -f "$art/$f" ] && cp "$art/$f" "$rec/$f"
done
[ -d "$art/usage" ] && cp -r "$art/usage" "$rec/usage"

started="$(json_get "$rec/run-clock.json" started_at)"
ended="$(json_get "$rec/run-clock.json" ended_at)"
base="$(json_get "$rec/run-clock.json" base_sha)"
[ -n "$ended" ] || ended="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
[[ "$base" =~ ^[0-9a-f]{40}$ ]] || base="$(git rev-parse HEAD)"

# A spec run has no approved build spec: describe the spec run itself (work_type spec, the risk
# class it was routed by; complexity is not judged for spec runs and is recorded as standard).
if [ "$OC_KIND" = spec ]; then
  risk="$(json_get "$rec/run-start.json" risk_class)"
  case "$risk" in high) ;; *) risk=normal ;; esac
  printf '%s\n' '<!-- factory-spec v1 -->' '---' "issue: ${issue}" 'complexity: standard' \
    "risk: ${risk}" 'work_type: spec' '---' "/oc spec run for issue #${issue}" >"$rec/spec.md"
fi
[ -f "$rec/spec.md" ] || { say "no spec.md in the artifact; cannot build a record"; exit 1; }

# Outcome from the job results.
agent="${OC_AGENT_RESULT:-failure}"; publish="${OC_PUBLISH_RESULT:-skipped}"
if [ "${OC_REFUSED:-}" = over_cap ]; then outcome=cap_exceeded
elif [ "$agent" = cancelled ] || [ "$publish" = cancelled ]; then outcome=cancelled
elif [ "$agent" != success ] || [ "$publish" != success ]; then outcome=failed
else
  case "$OC_KIND" in build) outcome=pr_opened ;; fix) outcome=pr_updated ;; spec) outcome=no_changes ;; esac
fi

# The build PR (branch oc/issue-<N>-<run id>, opened by publish) and its head commit.
if [ "$OC_KIND" = build ] && [ "$outcome" = pr_opened ]; then
  pr="$(gh pr list --repo "$GITHUB_REPOSITORY" --state all --head "oc/issue-${issue}-${GITHUB_RUN_ID}" \
    --json number -q '.[0].number // empty' 2>/dev/null || true)"
  [[ "$pr" =~ ^[0-9]+$ ]] || pr=""
fi
head="$base"
if [ -n "$pr" ]; then
  h="$(gh pr view "$pr" --repo "$GITHUB_REPOSITORY" --json headRefOid -q .headRefOid 2>/dev/null || true)"
  [[ "$h" =~ ^[0-9a-f]{40}$ ]] && head="$h"
fi

# Key spend is per key, not per run: another /oc run in the same window makes the delta unusable.
if [ -f "$rec/key-spend.json" ]; then
  overlap="$(gh run list --repo "$GITHUB_REPOSITORY" --limit 50 \
    --json databaseId,workflowName,status,conclusion,createdAt,updatedAt 2>/dev/null \
    | python3 -c '
import json, sys
me, start, end = int(sys.argv[1]), sys.argv[2], sys.argv[3]
try:
    runs = json.load(sys.stdin)
except Exception:
    print("unknown"); sys.exit()
n = 0
for r in runs:
    if r.get("databaseId") == me or r.get("workflowName") not in ("opencode-spike", "opencode-fix", "opencode-spec"):
        continue
    if r.get("conclusion") == "skipped":
        continue
    if (r.get("createdAt") or "") <= end and (r.get("status") != "completed" or (r.get("updatedAt") or "") >= start):
        n += 1
print(n)
' "$GITHUB_RUN_ID" "$started" "$ended" 2>/dev/null || echo unknown)"
  if [ "$overlap" != 0 ]; then
    python3 - "$rec/key-spend.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["concurrent"] = True
json.dump(d, open(sys.argv[1], "w"), sort_keys=True)
PY
    say "other /oc runs overlapped this one (${overlap}); key spend marked concurrent"
  fi
fi

runs_dir="${FACTORY_RUNS_DIR:-$rec/runs}"
opencode_version="$(sed -n 's/^OPENCODE_VERSION="\${OPENCODE_VERSION:-\([0-9.]*\)}"$/\1/p' scripts/opencode-install.sh | head -n 1)"
record_path="$(OC_ARTIFACT_DIR="$rec" FACTORY_RUNS_DIR="$runs_dir" OC_STARTED_AT="$started" OC_ENDED_AT="$ended" \
  OC_BASE_SHA="$base" OC_HEAD_SHA="$head" OC_OUTCOME="$outcome" OC_PR_NUMBER="$pr" \
  OC_TRIGGER_URL="${OC_TRIGGER_URL:-}" OPENCODE_VERSION="${opencode_version:-unknown}" \
  bash scripts/factory-run-end.sh)" || { say "factory-run-end.sh failed; no record"; exit 1; }
bash scripts/opencode-artifact-scan.sh "$record_path" >/dev/null || { say "record failed the artifact scan; not posted"; exit 1; }
[ -z "${OC_RECORD_OUT:-}" ] || { mkdir -p "$(dirname "$OC_RECORD_OUT")" && cp "$record_path" "$OC_RECORD_OUT"; }

fact() { json_get "$record_path" "$1"; }
actual="$(fact actual_cost_usd)"; method="$(fact cost_method)"; total="$(fact issue_spend_to_date_usd)"
check="$(fact cost_check)"; model="$(fact model)"

# Post once per run attempt (a re-run of only this job must not double-count the issue's spend).
if gh issue view "$issue" --repo "$GITHUB_REPOSITORY" --json comments \
  -q '.comments[] | select(.author.login == "github-actions") | .body' 2>/dev/null \
  | grep -qF "\"run_id\": \"${run_id}\""; then
  say "record for ${run_id} already on issue #${issue}; not posting again"
  comment_url=""
else
  body="$(mktemp)"
  {
    echo '<!-- factory-run-record -->'
    echo "**Run record** for \`${kind_label}\` run [${run_id}](${repo_url}/actions/runs/${GITHUB_RUN_ID}) (${outcome}): \$${actual} (${method}; key spend check ${check}), model \`${model}\`, issue total so far \$${total}."
    echo
    echo '```json'
    cat "$record_path"
    echo
    echo '```'
  } >"$body"
  comment_url="$(gh issue comment "$issue" --repo "$GITHUB_REPOSITORY" --body-file "$body" | tail -n 1)" \
    || { say "could not post the record on issue #${issue}"; exit 1; }
  rm -f "$body"
fi

if [ -n "$pr" ] && [ "$OC_KIND" != spec ] && [ "$outcome" != failed ] && [ "$outcome" != cancelled ]; then
  OC_RUN_RECORD_URL="${comment_url:-${repo_url}/issues/${issue}}" FACTORY_RUNS_DIR="$runs_dir" \
    bash scripts/factory-run-body.sh "$pr" "$run_id" || { say "could not update PR #${pr} body"; exit 1; }
fi

{
  echo "### Run record (${run_id})"
  echo "- Outcome: ${outcome}; model \`${model}\`"
  echo "- Cost: \$${actual} (${method}; key spend check ${check}); issue #${issue} total so far \$${total}"
  [ -z "$comment_url" ] || echo "- Posted: ${comment_url}"
  [ -z "$pr" ] || echo "- PR: #${pr}"
} >>"$summary"
echo "run-finish: recorded ${run_id} (${outcome}, \$${actual}, ${method})"
