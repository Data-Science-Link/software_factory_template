#!/usr/bin/env bash
# #84: post one script-worded failure comment on the issue (/oc) or PR (/oc fix) when a run's
# agent or publish job did not succeed. Runs as a final notify job; wording comes only from this
# script. Idempotent per run attempt: a marker comment trusted only from github-actions[bot].
#
# Env inputs (validated, digits-only where applicable):
#   OC_KIND build|fix, OC_TARGET_NUMBER, OC_RUN_ID, OC_RUN_ATTEMPT (default 1),
#   OC_AGENT_RESULT, OC_PUBLISH_RESULT (success|failure|cancelled|skipped),
#   GITHUB_REPOSITORY, optional GITHUB_SERVER_URL, GH_TOKEN (used only by gh, never printed).
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

server="${GITHUB_SERVER_URL:-https://github.com}"
marker="<!-- factory-run-failed v1 run=${OC_RUN_ID} attempt=${attempt} -->"
if [ "$OC_KIND" = fix ]; then
  second="No commit was pushed to this PR."
else
  second="No PR was opened."
fi
body="$marker
$title in the \`$job\` job (result: \`$result\`). $second
- Run: $server/$repo/actions/runs/${OC_RUN_ID}
- DeepInfra spend may still have happened; the run's usage report is in the job log."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

python3 - "$tmp/body.json" "$body" <<'PY'
import json, sys
json.dump({"body": sys.argv[2]}, open(sys.argv[1], "w"))
PY

# Idempotency: a marker with this run id + attempt already posted by github-actions[bot] -> stop.
comments="$(gh api --paginate "repos/$repo/issues/${OC_TARGET_NUMBER}/comments")"
if python3 - "$comments" "$marker" <<'PY'
import json, sys
text = sys.argv[1]
marker = sys.argv[2]
seen = False
# The output may be several concatenated JSON arrays.
for line in text.splitlines():
    line = line.strip()
    if not line:
        continue
    for c in json.loads(line):
        if (c.get("user") or {}).get("login") == "github-actions[bot]" and marker in (c.get("body") or ""):
            seen = True
            break
sys.exit(0 if seen else 1)
PY
then
  echo "notify-failure: already posted for this run attempt"
  exit 0
fi

gh api --method POST "repos/$repo/issues/${OC_TARGET_NUMBER}/comments" --input "$tmp/body.json"
echo "notify-failure: posted a failure comment (job $job, result $result)"
