#!/usr/bin/env bash
# #84: post one script-worded failure comment on the issue (/oc) or PR (/oc fix) when a run's
# agent or publish job did not succeed. Runs as a final notify job; wording comes only from this
# script. Idempotent per run attempt: a marker comment trusted only from github-actions[bot].
#
# Env inputs (validated, digits-only where applicable):
#   OC_KIND build|fix, OC_TARGET_NUMBER, OC_RUN_ID, OC_RUN_ATTEMPT (default 1),
#   OC_AGENT_RESULT, OC_PUBLISH_RESULT (success|failure|cancelled|skipped),
#   GITHUB_REPOSITORY, optional GITHUB_SERVER_URL, GH_TOKEN (used only by gh, never printed).
# Optional (#92, from the agent job's run-start and classify steps; each validated, else "none"):
#   OC_REFUSED      run-start refusal code (scripts/factory-run-start.py): the run never started
#   OC_MODEL_ID     the routed model, OC_ROUTED_RULE its models.yaml rule
#   OC_ERROR_CLASS  tool_or_reasoning_format|other (scripts/factory-classify-failure.py)
#   OC_PRIOR_USD, OC_PREDICTED_USD, OC_CAP_USD  numbers for an over_cap refusal
# The marker line carries kind/job/result/model/rule/error so the next run start can route the
# retry (rule 4) or the fallback (rule 5) without trusting anything the worker wrote.
set -euo pipefail

case "${OC_KIND:-}" in
  build) title='**`/oc` run failed**'; ;;
  fix)   title='**`/oc fix` run failed**'; ;;
  *) echo "notify-failure: OC_KIND must be build or fix (got '${OC_KIND:-}')" >&2; exit 2 ;;
esac

case "${OC_TARGET_NUMBER:-}" in '' | *[!0-9]*)
  echo "notify-failure: OC_TARGET_NUMBER must be digits" >&2; exit 2 ;; esac
case "${OC_RUN_ID:-}" in '' | *[!0-9]*)
  echo "notify-failure: OC_RUN_ID must be digits" >&2; exit 2 ;; esac
attempt="${OC_RUN_ATTEMPT:-1}"
case "$attempt" in '' | *[!0-9]*)
  echo "notify-failure: OC_RUN_ATTEMPT must be digits" >&2; exit 2 ;; esac

repo="${GITHUB_REPOSITORY:-}"
owner="${repo%%/*}"
name="${repo#*/}"
case "$owner" in '' | *[!A-Za-z0-9_.-]* | */*) owner=bad ;; esac
case "$name" in '' | *[!A-Za-z0-9_.-]* | */*) name=bad ;; esac
if [ "$owner" = bad ] || [ "$name" = bad ] || [ "$repo" != "$owner/$name" ]; then
  echo "notify-failure: GITHUB_REPOSITORY must be owner/repo" >&2; exit 2
fi

for v in OC_AGENT_RESULT OC_PUBLISH_RESULT; do
  case "${!v:-}" in
    success|failure|cancelled|skipped) ;;
    *) echo "notify-failure: $v must be success|failure|cancelled|skipped (got '${!v:-}')" >&2; exit 2 ;;
  esac
done

# Failed job: agent unless it succeeded; otherwise publish unless it succeeded.
if [ "$OC_AGENT_RESULT" = success ] && [ "$OC_PUBLISH_RESULT" = success ]; then
  echo "notify-failure: run succeeded; nothing to post"
  exit 0
fi
if [ "$OC_AGENT_RESULT" != success ]; then
  job=agent; result="$OC_AGENT_RESULT"
else
  job=publish; result="$OC_PUBLISH_RESULT"
fi

# #92 optional facts: anything that fails validation becomes "none" (never echoed back).
model="${OC_MODEL_ID:-}"
[[ "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || model=none
rule="${OC_ROUTED_RULE:-}"
case "$rule" in '' | *[!0-9]*) rule=none ;; esac
error="${OC_ERROR_CLASS:-}"
case "$error" in tool_or_reasoning_format | other) ;; *) error=none ;; esac
refused="${OC_REFUSED:-}"
case "$refused" in
  '') refused=none ;;
  no_approved_spec) why="This issue has no approved spec comment. Post one (\`/oc spec\`, then approve it with scripts/factory-approve-spec.py) and run \`/oc\` again." ;;
  spec_not_approved) why="The spec found is not \`status: approved\`." ;;
  spec_issue_mismatch) why="The approved spec names a different issue." ;;
  spec_check_failed) why="The approved spec fails scripts/factory-spec-check.py." ;;
  router_failed) why="The model router (scripts/factory-predict-cost.py) could not route this spec." ;;
  router_guard) why="A models.yaml guard fired (rule 6: predicted cost over the cap, or rule 8: priority tier). Split the issue." ;;
  model_not_allowed) why="The routed model is not a DeepInfra model listed in .factory/models.yaml." ;;
  cap_unset) why="\`budget.issue_cap_usd\` is not set in .factory/models.yaml." ;;
  over_target_unapproved) why="This run's predicted cost is over \`budget.issue_target_usd\` and the approved spec lacks \`over_target_approved_by: michael\`. Michael re-approves with scripts/factory-approve-spec.py ... --approved-by michael --over-target-ok (or split the issue)." ;;
  over_cap) why="Prior spend on this issue plus this run's predicted cost is over the per-issue cap. Split the issue or raise the cap in .factory/models.yaml." ;;
  *) refused=invalid; why="Run start refused the run (unrecognized reason code)." ;;
esac
num() { [[ "${1:-}" =~ ^[0-9]{1,6}\.[0-9]{1,6}$ ]] && printf '%s' "$1" || printf '?'; }

server="${GITHUB_SERVER_URL:-https://github.com}"
marker_key="<!-- factory-run-failed v1 run=${OC_RUN_ID} attempt=${attempt}"
if [ "$refused" != none ]; then model=none; rule=none; error=none; fi
marker="$marker_key kind=${OC_KIND} job=${job} result=${result} model=${model} rule=${rule} error=${error} -->"
if [ "$OC_KIND" = fix ]; then
  second="No commit was pushed to this PR."
else
  second="No PR was opened."
fi
if [ "$refused" != none ]; then
  stop_title="${title% failed\*\*} stopped at run start**"
  body="$marker
$stop_title (refused: \`$refused\`). $second
- Why: $why"
  if [ "$refused" = over_cap ]; then
    body="$body
- Issue spend so far: \$$(num "${OC_PRIOR_USD:-}"); this run's prediction: \$$(num "${OC_PREDICTED_USD:-}"); cap: \$$(num "${OC_CAP_USD:-}")."
  fi
  body="$body
- No DeepInfra spend: run start stops the job before OpenCode is installed or the key is used.
- Run: $server/$repo/actions/runs/${OC_RUN_ID}"
else
  body="$marker
$title in the \`$job\` job (result: \`$result\`). $second
- Run: $server/$repo/actions/runs/${OC_RUN_ID}"
  if [ "$model" != none ]; then
    body="$body
- Model: \`$model\` (routed by run start, models.yaml rule $rule); failure class: \`$error\`."
  fi
  body="$body
- DeepInfra spend may still have happened; the run's usage report is in the job log."
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

python3 - "$tmp/body.json" "$body" <<'PY'
import json, sys
json.dump({"body": sys.argv[2]}, open(sys.argv[1], "w"))
PY

# Idempotency: a marker with this run id + attempt already posted by github-actions[bot] -> stop.
# Pipe the (possibly multi-page, possibly several concatenated JSON arrays on one line) output
# into python3 on stdin; a large payload never becomes a command-line argument. The Python
# program lives in a shell variable (read -r -d '' from a heredoc) so the heredoc does NOT
# replace stdin: the gh output is still what Python reads on stdin.
read -r -d '' dup_py <<'PY' || true
import json, sys
# Match the run+attempt key followed by a space, so old (v1, no fields) and new markers both count
# and attempt=1 never matches attempt=10.
marker = sys.argv[1] + " "
decoder = json.JSONDecoder()
seen = False
buf = sys.stdin.read()
i = 0
n = len(buf)
while i < n:
    while i < n and buf[i] in " \t\r\n":
        i += 1
    if i >= n:
        break
    obj, j = decoder.raw_decode(buf, i)
    i = j
    for c in obj:
        if (c.get("user") or {}).get("login") == "github-actions[bot]" and marker in (c.get("body") or ""):
            seen = True
            break
    if seen:
        break
sys.exit(0 if seen else 1)
PY
if gh api --paginate "repos/$repo/issues/${OC_TARGET_NUMBER}/comments" | python3 -c "$dup_py" "$marker_key"
then
  echo "notify-failure: already posted for this run attempt"
  exit 0
fi

gh api --method POST "repos/$repo/issues/${OC_TARGET_NUMBER}/comments" --input "$tmp/body.json"
echo "notify-failure: posted a failure comment (job $job, result $result, refused $refused)"
