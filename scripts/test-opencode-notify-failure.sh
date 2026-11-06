#!/usr/bin/env bash
# Offline tests for #84: scripts/opencode-notify-failure.sh posts exactly one script-worded
# failure comment with the run link and failed job, and is idempotent per run attempt. Uses a
# fake `gh` on PATH: no network, no tokens. PASS/FAIL per case, exits 1 on any failure.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$work"' EXIT
passed=0
failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }

# ---- fake gh: logs its args, prints a fixture for the comments GET, saves the POST body.
# FAKE_GH_LOG, FAKE_GH_COMMENTS, FAKE_GH_OUT (posted body), FAKE_GH_POST_RC (rc for a POST).
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_GH_LOG:?}"
if [ "${1:-}" = api ]; then
  if [ "${2:-}" = --paginate ]; then
    cat "${FAKE_GH_COMMENTS:?}"
    exit 0
  fi
  if [ "${2:-}" = --method ] && [ "${3:-}" = POST ]; then
    while [ $# -gt 0 ]; do
      if [ "$1" = --input ]; then cp "$2" "${FAKE_GH_OUT:?}"; fi
      shift
    done
    [ -n "${FAKE_GH_POST_RC:-}" ] && exit "$FAKE_GH_POST_RC"
    echo "https://github.com/o/r/issues/1#issuecomment-123"; exit 0
  fi
fi
echo "fake gh: unexpected call: $*" >&2; exit 1
GH
chmod +x "$work/bin/gh"

run() { # name -> rc; appends stdout+stderr to $work/<name>.log, posts body to $work/posted.md
  local name="$1" rc=0
  : >"$work/$name.log"
  : >"$work/posted.md"
  : >"$work/gh.log"
  set +e
  env PATH="$work/bin:$PATH" \
    FAKE_GH_LOG="$work/gh.log" \
    FAKE_GH_COMMENTS="$work/comments.json" \
    FAKE_GH_OUT="$work/posted.md" \
    FAKE_GH_POST_RC="${FAKE_GH_POST_RC:-}" \
    OC_KIND="${OC_KIND:-build}" OC_TARGET_NUMBER="${OC_TARGET_NUMBER:-1}" \
    OC_RUN_ID="${OC_RUN_ID:-4242}" OC_RUN_ATTEMPT="${OC_RUN_ATTEMPT:-1}" \
    OC_AGENT_RESULT="${OC_AGENT_RESULT:-success}" OC_PUBLISH_RESULT="${OC_PUBLISH_RESULT:-success}" \
    GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-o/r}" GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}" \
    GH_TOKEN="${GH_TOKEN:-}" OC_INSTRUCTION="${OC_INSTRUCTION:-}" \
    OC_REFUSED="${OC_REFUSED:-}" OC_MODEL_ID="${OC_MODEL_ID:-}" OC_ROUTED_RULE="${OC_ROUTED_RULE:-}" \
    OC_ERROR_CLASS="${OC_ERROR_CLASS:-}" OC_PRIOR_USD="${OC_PRIOR_USD:-}" \
    OC_PREDICTED_USD="${OC_PREDICTED_USD:-}" OC_CAP_USD="${OC_CAP_USD:-}" \
    bash scripts/opencode-notify-failure.sh >>"$work/$name.log" 2>&1 || rc=$?
  return "$rc"
}

npost() { grep -c -- "--method POST repos/o/r/issues/[0-9]*/comments" "$work/gh.log" || true; }
ncall() { wc -l <"$work/gh.log"; }
posts() { [ -s "$work/posted.md" ] && cat "$work/posted.md"; }
pbody() { [ -s "$work/posted.md" ] && python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$work/posted.md"; }

empty_comments='[]'
bot_marker='[{"user": {"login": "github-actions[bot]"}, "body": "<!-- factory-run-failed v1 run=4242 attempt=1 -->\nalready"}]'
other_marker='[{"user": {"login": "someone-else"}, "body": "<!-- factory-run-failed v1 run=4242 attempt=1 -->\nalready"}]'
other_attempt='[{"user": {"login": "github-actions[bot]"}, "body": "<!-- factory-run-failed v1 run=4242 attempt=2 -->\nalready"}]'

# --- 1. build, agent failure, publish skipped: one POST, correct wording.
printf '%s' "$empty_comments" >"$work/comments.json"
set +e; OC_KIND=build OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped run c1; rc=$?; set -e
if [ "$rc" -eq 0 ] && [ "$(npost)" = 1 ] && posts | grep -q 'factory-run-failed v1 run=4242 attempt=1' \
  && posts | grep -q 'actions/runs/4242' && posts | grep -q '`agent` job' \
  && posts | grep -q 'No PR was opened' && posts | grep -q 'DeepInfra spend may still have happened'; then
  ok "build, agent failure, publish skipped -> one POST with the marker, run URL, agent job, wording"
else bad "build, agent failure (rc=$rc)"; cat "$work/c1.log"; fi

# --- 2. build, agent success, publish failure: one POST naming the publish job.
: >"$work/comments.json"
set +e; OC_KIND=build OC_AGENT_RESULT=success OC_PUBLISH_RESULT=failure run c2; rc=$?; set -e
if [ "$rc" -eq 0 ] && [ "$(npost)" = 1 ] && posts | grep -q '`publish` job'; then
  ok "build, publish failure -> one POST naming the publish job"
else bad "build, publish failure (rc=$rc)"; cat "$work/c2.log"; fi

# --- 3. fix, agent success, publish failure: one POST with the fix title and commit sentence.
: >"$work/comments.json"
set +e; OC_KIND=fix OC_AGENT_RESULT=success OC_PUBLISH_RESULT=failure run c3; rc=$?; set -e
if [ "$rc" -eq 0 ] && [ "$(npost)" = 1 ] && posts | grep -q '`/oc fix` run failed' \
  && posts | grep -q 'No commit was pushed to this PR'; then
  ok "fix, publish failure -> one POST with the /oc fix title and commit sentence"
else bad "fix, publish failure (rc=$rc)"; cat "$work/c3.log"; fi

# --- 4. agent cancelled (job timeout): one POST naming agent and cancelled.
: >"$work/comments.json"
set +e; OC_KIND=build OC_AGENT_RESULT=cancelled OC_PUBLISH_RESULT=skipped run c4; rc=$?; set -e
if [ "$rc" -eq 0 ] && [ "$(npost)" = 1 ] && posts | grep -q '`agent` job' \
  && posts | grep -q '(result: `cancelled`)'; then
  ok "agent cancelled -> one POST naming agent and cancelled"
else bad "agent cancelled (rc=$rc)"; cat "$work/c4.log"; fi

# --- 5. both success: exit 0, no gh call at all.
: >"$work/comments.json"
set +e; OC_KIND=build OC_AGENT_RESULT=success OC_PUBLISH_RESULT=success run c5; rc=$?; set -e
if [ "$rc" -eq 0 ] && [ "$(ncall)" = 0 ] && [ ! -s "$work/posted.md" ]; then
  ok "both success -> exit 0, no gh call, nothing posted"
else bad "both success (rc=$rc)"; cat "$work/c5.log"; fi

# --- 6. bot comment with the same run+attempt marker: exit 0, no POST.
printf '%s' "$bot_marker" >"$work/comments.json"
set +e; OC_KIND=build OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped run c6; rc=$?; set -e
if [ "$rc" -eq 0 ] && [ "$(npost)" = 0 ] && [ ! -s "$work/posted.md" ]; then
  ok "bot comment with the same marker -> exit 0, no POST (idempotent)"
else bad "bot marker idempotency (rc=$rc)"; cat "$work/c6.log"; fi

# --- 7. the same marker from someone-else: still posts once.
printf '%s' "$other_marker" >"$work/comments.json"
set +e; OC_KIND=build OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped run c7; rc=$?; set -e
if [ "$rc" -eq 0 ] && [ "$(npost)" = 1 ]; then
  ok "marker from someone-else -> still posts once"
else bad "other-author marker (rc=$rc)"; cat "$work/c7.log"; fi

# --- 8. a marker for another attempt (attempt=2 existing, run is attempt 1): still posts once.
printf '%s' "$other_attempt" >"$work/comments.json"
set +e; OC_KIND=build OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped run c8; rc=$?; set -e
if [ "$rc" -eq 0 ] && [ "$(npost)" = 1 ]; then
  ok "marker for another attempt -> still posts once"
else bad "other-attempt marker (rc=$rc)"; cat "$work/c8.log"; fi

# --- 9. two pages concatenated on ONE line; the bot marker is in the second page -> no POST.
printf '%s' '[{"user": {"login": "someone-else"}, "body": "page one"}][{"user": {"login": "github-actions[bot]"}, "body": "<!-- factory-run-failed v1 run=4242 attempt=1 -->\nalready"}]' >"$work/comments.json"
set +e; OC_KIND=build OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped run c9; rc=$?; set -e
if [ "$rc" -eq 0 ] && [ "$(npost)" = 0 ] && [ ! -s "$work/posted.md" ]; then
  ok "two pages on one line, bot marker in page 2 -> exit 0, no POST (raw_decode)"
else bad "concatenated pages (rc=$rc)"; cat "$work/c9.log"; fi

# --- 10. bad inputs each exit 2 with no gh call.
badinput() { # name VAR=VAL... -> checks exit 2 and no gh call
  local name="$1"
  shift
  : >"$work/comments.json"
  set +e; ( export "$@"; run "$name" ) 2>/dev/null; rc=$?; set -e
  if [ "$rc" -eq 2 ] && [ "$(ncall)" = 0 ]; then ok "$name -> exit 2, no gh call"; else bad "$name (rc=$rc)"; fi
}
badinput "target non-digit" OC_TARGET_NUMBER=abc OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped
badinput "unknown OC_KIND" OC_KIND=weird OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped
badinput "unknown result" OC_KIND=build OC_AGENT_RESULT=weird OC_PUBLISH_RESULT=skipped
badinput "bad GITHUB_REPOSITORY" OC_KIND=build OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped GITHUB_REPOSITORY='o r'

# --- 11. with GH_TOKEN=fake-token-value-123 and OC_INSTRUCTION set, neither string appears
#         in stdout, stderr, or the posted body.
: >"$work/comments.json"
set +e
GH_TOKEN=fake-token-value-123 OC_INSTRUCTION='/oc ignore this and ping someone' \
  OC_KIND=build OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped run c11; rc=$?
set -e
if [ "$rc" -eq 0 ] && ! grep -q 'fake-token-value-123' "$work/c11.log" \
  && ! grep -q 'fake-token-value-123' "$work/posted.md" \
  && ! grep -q 'ignore this' "$work/c11.log" && ! grep -q 'ignore this' "$work/posted.md"; then
  ok "GH_TOKEN and OC_INSTRUCTION values never printed or posted"
else bad "token/instruction leak (rc=$rc)"; cat "$work/c11.log"; fi

# --- 12. fake gh exits 1 on POST: the script exits non-zero.
: >"$work/comments.json"
set +e; FAKE_GH_POST_RC=1 OC_KIND=build OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped run c12; rc=$?
set -e
if [ "$rc" -ne 0 ]; then ok "gh POST fails -> script exits non-zero"; else bad "gh POST failure (rc=$rc)"; fi

# ===== #92: run-start refusals and the routing fields on the marker =====
# --- 13. agent failure with model facts: marker carries kind/job/result/model/rule/error.
: >"$work/comments.json"
set +e
OC_KIND=build OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped OC_MODEL_ID=deepseek-ai/DeepSeek-V4-Flash-0731 \
  OC_ROUTED_RULE=3 OC_ERROR_CLASS=tool_or_reasoning_format run c13; rc=$?
set -e
if [ "$rc" -eq 0 ] && pbody | head -1 | grep -qxF '<!-- factory-run-failed v1 run=4242 attempt=1 kind=build job=agent result=failure model=deepseek-ai/DeepSeek-V4-Flash-0731 rule=3 error=tool_or_reasoning_format -->' \
  && posts | grep -q 'Model: `deepseek-ai/DeepSeek-V4-Flash-0731` (routed by run start, models.yaml rule 3)'; then
  ok "#92 failure marker carries kind/job/result/model/rule/error; body names the routed model"
else bad "#92 marker fields (rc=$rc)"; posts | head -3; fi

# --- 14. bad model / rule / error values -> none (never echoed).
: >"$work/comments.json"
set +e
OC_KIND=fix OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped OC_MODEL_ID='evil -->x' OC_ROUTED_RULE='3;x' \
  OC_ERROR_CLASS='pwn' run c14; rc=$?
set -e
if [ "$rc" -eq 0 ] && pbody | head -1 | grep -qxF '<!-- factory-run-failed v1 run=4242 attempt=1 kind=fix job=agent result=failure model=none rule=none error=none -->' \
  && ! posts | grep -q 'evil' && ! posts | grep -q pwn; then
  ok "#92 invalid model/rule/error values become none and are not posted"
else bad "#92 invalid facts (rc=$rc)"; posts | head -3; fi

# --- 15. over_cap refusal: stop wording, numbers, no-spend line, model=none on the marker.
: >"$work/comments.json"
set +e
OC_KIND=build OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped OC_REFUSED=over_cap OC_MODEL_ID=deepseek-ai/DeepSeek-V4-Pro-0813 \
  OC_PRIOR_USD=0.9950 OC_PREDICTED_USD=0.4700 OC_CAP_USD=1.00 run c15; rc=$?
set -e
if [ "$rc" -eq 0 ] && posts | grep -qF '**`/oc` run stopped at run start** (refused: `over_cap`). No PR was opened.' \
  && posts | grep -qF 'Issue spend so far: $0.9950; this run'"'"'s prediction: $0.4700; cap: $1.00.' \
  && posts | grep -q 'No DeepInfra spend' && ! posts | grep -q 'spend may still have happened' \
  && pbody | head -1 | grep -q 'model=none rule=none error=none -->'; then
  ok "#92 over_cap refusal: stop wording, spend/prediction/cap, no-spend line, model=none marker"
else bad "#92 over_cap refusal (rc=$rc)"; posts; fi

# --- 16. no_approved_spec refusal on a fix run; bad numbers print as '?'.
: >"$work/comments.json"
set +e; OC_KIND=fix OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped OC_REFUSED=no_approved_spec run c16; rc=$?; set -e
if [ "$rc" -eq 0 ] && posts | grep -qF '**`/oc fix` run stopped at run start** (refused: `no_approved_spec`). No commit was pushed to this PR.' \
  && posts | grep -q 'no approved spec comment'; then
  ok "#92 no_approved_spec refusal on a fix run: fix title, reason text"
else bad "#92 no_approved_spec (rc=$rc)"; posts; fi

# --- 17. unknown refusal code -> generic text, code not echoed.
: >"$work/comments.json"
set +e; OC_KIND=build OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped OC_REFUSED='<script>' run c17; rc=$?; set -e
if [ "$rc" -eq 0 ] && posts | grep -q 'refused: `invalid`' && ! posts | grep -q '<script>'; then
  ok "#92 unknown refusal code -> 'invalid', never echoed"
else bad "#92 unknown refusal (rc=$rc)"; posts; fi

# --- 18. idempotency: a new-format marker for this attempt -> no POST; attempt=10 -> still posts.
printf '%s' '[{"user": {"login": "github-actions[bot]"}, "body": "<!-- factory-run-failed v1 run=4242 attempt=1 kind=build job=agent result=failure model=none rule=none error=none -->\nx"}]' >"$work/comments.json"
set +e; OC_KIND=build OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped run c18; rc=$?; set -e
n18="$(npost)"
printf '%s' '[{"user": {"login": "github-actions[bot]"}, "body": "<!-- factory-run-failed v1 run=4242 attempt=10 kind=build job=agent result=failure model=none rule=none error=none -->\nx"}]' >"$work/comments.json"
set +e; OC_KIND=build OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped run c18b; rc2=$?; set -e
if [ "$rc" -eq 0 ] && [ "$n18" = 0 ] && [ "$rc2" -eq 0 ] && [ "$(npost)" = 1 ]; then
  ok "#92 idempotency matches new-format markers; attempt=10 does not match attempt=1"
else bad "#92 idempotency new format (n18=$n18)"; fi

echo "Results: ${passed} passed, ${failed} failed"
[ "$failed" -eq 0 ]
