#!/usr/bin/env bash
# Offline tests for scripts/factory-run-finish.sh (#31): stub gh, real factory-run-end.sh,
# real OpenCode export fixtures (tests/factory-usage/) and a real approved spec.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 -c 'import yaml, jsonschema' 2>/dev/null || { echo "PyYAML and jsonschema are required (pip install -r requirements-factory.txt)" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0; failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }

mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >>"$STUB_DIR/gh.log"
case "$1 $2" in
  "pr list") printf '%s\n' "${STUB_PR:-}" ;;
  "pr view")
    if [[ "$*" == *headRefOid* ]]; then echo cccccccccccccccccccccccccccccccccccccccc; else cat "$STUB_DIR/pr-body.md"; fi ;;
  "pr edit") cp "${@: -1}" "$STUB_DIR/pr-body-edited.md" ;;
  "run list") cat "$STUB_DIR/runs.json" ;;
  "issue view") cat "$STUB_DIR/comments.txt" 2>/dev/null || true ;;
  "issue comment")
    while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$STUB_DIR/posted-$(date +%s%N).md"; shift; done
    echo "https://github.com/Data-Science-Link/software_factory_template/issues/134#issuecomment-999" ;;
  *) echo "stub gh: unexpected: $*" >&2; exit 1 ;;
esac
GH
chmod +x "$work/bin/gh"

SENTINEL="sk-test-sentinel-31-do-not-print"

# case <name> <kind> <agent result> <publish result>; artifact built by the caller in $work/<name>/art.
new_case() {
  d="$work/$1"; mkdir -p "$d/art/usage" "$d/stub"
  cp tests/factory-usage/opencode-export-session-*.json "$d/art/usage/"
  cp factory/specs/issue-133.md "$d/art/spec.md"
  printf '{"base_sha": "%s", "ended_at": "2026-11-09T22:04:10Z", "started_at": "2026-11-09T22:00:00Z"}\n' \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$d/art/run-clock.json"
  cat >"$d/art/run-start.json" <<J
{"run_id": "gha-42400000031-1", "model_id": "Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo", "predicted_cost_usd": 0.19, "prior_spend_usd": 0.1, "cap_usd": 1.0}
J
  echo '{"start_usd": 12.0, "end_usd": 12.0017, "concurrent": false}' >"$d/art/key-spend.json"
  echo '[]' >"$d/stub/runs.json"
  printf '%s\n' '## Evidence' '<!-- factory-run:start -->' 'Run ID: 42400000031' 'Gate: risk high' \
    '<!-- factory-run:end -->' '' 'Cost: $0.09 on DeepInfra (OpenCode stats)' >"$d/stub/pr-body.md"
}
run_finish() { # <name> <kind> <agent> <publish> [extra env...]
  local d="$work/$1" kind="$2" a="$3" p="$4"; shift 4
  set +e
  env PATH="$work/bin:$PATH" STUB_DIR="$d/stub" DEEPINFRA_API_KEY="$SENTINEL" \
    GITHUB_REPOSITORY=Data-Science-Link/software_factory_template GITHUB_RUN_ID=42400000031 GITHUB_RUN_ATTEMPT=1 \
    GITHUB_STEP_SUMMARY="$d/summary.md" OC_KIND="$kind" OC_ISSUE_NUMBER=133 OC_ARTIFACT_DIR="$d/art" \
    OC_AGENT_RESULT="$a" OC_PUBLISH_RESULT="$p" OC_RECORD_OUT="$d/record.json" FACTORY_RUNS_DIR="$d/runs" "$@" \
    bash scripts/factory-run-finish.sh >"$d/out.txt" 2>&1
  rc=$?
  set -e
}
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
posted() { cat "$work/$1"/stub/posted-*.md 2>/dev/null || true; }
nposted() { ls "$work/$1"/stub/posted-*.md 2>/dev/null | wc -l | tr -d ' '; }

# 1. Build run with a PR: record built, posted with the marker, PR body block + Cost rewritten.
new_case c1
run_finish c1 build success success STUB_PR=142
r="$work/c1/record.json"
if [ "$rc" = 0 ] && [ "$(field "$r" outcome)" = pr_opened ] && [ "$(field "$r" pr)" = 142 ] \
  && [ "$(field "$r" actual_cost_usd)" = 0.00164 ] && [ "$(field "$r" cost_check)" = match ] \
  && [ "$(field "$r" budget_cap_usd)" = 1.0 ] && [ "$(field "$r" head_sha)" = cccccccccccccccccccccccccccccccccccccccc ] \
  && [ "$(field "$r" started_at)" = 2026-11-09T22:00:00Z ] && [ "$(field "$r" duration_s)" = 250 ] \
  && [ "$(posted c1 | head -n 1)" = '<!-- factory-run-record -->' ] && posted c1 | grep -qF '"run_id": "gha-42400000031-1"' \
  && grep -qxF 'Cost: $0.00164 on DeepInfra (factory run record; usage_x_price_table); issue total so far $0.10164' "$work/c1/stub/pr-body-edited.md" \
  && grep -qxF 'Run record: https://github.com/Data-Science-Link/software_factory_template/issues/134#issuecomment-999' "$work/c1/stub/pr-body-edited.md" \
  && grep -q 'gh pr list .*--head oc/issue-133-42400000031' "$work/c1/stub/gh.log"; then
  ok "build run: record (pr_opened, PR 142, \$0.00164 match, cap 1.0, PR head sha), posted with marker, PR body rewritten"
else bad "build run (rc=$rc)"; cat "$work/c1/out.txt"; fi

# 2. Run start can read the posted comment back as this issue's spend (#91 prior-spend format).
if posted c1 | python3 -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("rs", "scripts/factory-run-start.py"); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
body = sys.stdin.read(); spend = {}; warned = []
m.load_comments_spend([{"user": {"login": "github-actions[bot]"}, "body": body}], 133, spend, warned)
sys.exit(0 if spend == {"gha-42400000031-1": 0.00164} and not warned else 1)'; then
  ok "posted record is read back by factory-run-start.py as the issue's spend"
else bad "run start cannot read the posted record"; fi

# 3. Another /oc run overlapping this one -> key spend marked concurrent (skipped_concurrent).
new_case c3
echo '[{"databaseId": 1, "workflowName": "opencode-spike", "status": "in_progress", "conclusion": "", "createdAt": "2026-11-09T21:59:00Z", "updatedAt": "2026-11-09T22:01:00Z"},
       {"databaseId": 2, "workflowName": "opencode-fix", "status": "completed", "conclusion": "skipped", "createdAt": "2026-11-09T22:01:00Z", "updatedAt": "2026-11-09T22:01:05Z"}]' >"$work/c3/stub/runs.json"
run_finish c3 build success success STUB_PR=142
if [ "$rc" = 0 ] && [ "$(field "$work/c3/record.json" cost_check)" = skipped_concurrent ]; then
  ok "overlapping /oc run -> cost_check skipped_concurrent (skipped runs ignored)"
else bad "overlap (rc=$rc)"; cat "$work/c3/out.txt"; fi

# 3b. Only a skipped run and a run that ended before this one started -> not concurrent.
new_case c3b
echo '[{"databaseId": 2, "workflowName": "opencode-fix", "status": "completed", "conclusion": "skipped", "createdAt": "2026-11-09T22:01:00Z", "updatedAt": "2026-11-09T22:01:05Z"},
       {"databaseId": 3, "workflowName": "opencode-spec", "status": "completed", "conclusion": "success", "createdAt": "2026-11-09T21:40:00Z", "updatedAt": "2026-11-09T21:50:00Z"}]' >"$work/c3b/stub/runs.json"
run_finish c3b build success success STUB_PR=142
if [ "$rc" = 0 ] && [ "$(field "$work/c3b/record.json" cost_check)" = match ]; then
  ok "no overlapping /oc run -> key spend used (match)"
else bad "no overlap (rc=$rc)"; cat "$work/c3b/out.txt"; fi

# 4. Re-run of the record job: the record is already on the issue -> not posted twice.
new_case c4
printf 'x\n  "run_id": "gha-42400000031-1",\n' >"$work/c4/stub/comments.txt"
run_finish c4 build success success STUB_PR=142
if [ "$rc" = 0 ] && [ "$(nposted c4)" = 0 ] && [ -f "$work/c4/stub/pr-body-edited.md" ]; then
  ok "record already posted for this run attempt -> no second comment (PR body still refreshed)"
else bad "idempotency (rc=$rc, posted $(nposted c4))"; cat "$work/c4/out.txt"; fi

# 5. Worker never started (no run-clock.json) -> exit 0, no gh call.
new_case c5; rm -f "$work/c5/art/run-clock.json"
run_finish c5 build failure skipped
if [ "$rc" = 0 ] && [ ! -s "$work/c5/stub/gh.log" ] && grep -q 'nothing to record' "$work/c5/out.txt"; then
  ok "no metering artifact (refused / early failure) -> nothing recorded, exit 0"
else bad "no artifact (rc=$rc)"; fi

# 6. Failed build: record posted (decision 1: every run), outcome failed, PR body untouched.
new_case c6
run_finish c6 build failure skipped
if [ "$rc" = 0 ] && [ "$(field "$work/c6/record.json" outcome)" = failed ] && [ "$(nposted c6)" = 1 ] \
  && [ ! -f "$work/c6/stub/pr-body-edited.md" ] && ! grep -q 'gh pr ' "$work/c6/stub/gh.log"; then
  ok "failed build: record posted on the issue (outcome failed), no PR lookup or edit"
else bad "failed build (rc=$rc)"; cat "$work/c6/out.txt"; fi

# 7. Spec run: own spec stub (work_type spec, routed risk), outcome no_changes, no PR.
new_case c7
echo '{"run_id": "gha-42400000031-1", "model_id": "deepseek-ai/DeepSeek-V4-Flash-0731", "predicted_cost_usd": 0.0058, "prior_spend_usd": 0, "cap_usd": 1.0, "risk_class": "not_high", "kind": "spec"}' >"$work/c7/art/run-start.json"
run_finish c7 spec success success
r="$work/c7/record.json"
if [ "$rc" = 0 ] && [ "$(field "$r" work_type)" = spec ] && [ "$(field "$r" risk)" = normal ] && [ "$(field "$r" outcome)" = no_changes ] \
  && [ "$(field "$r" model)" = deepseek-ai/DeepSeek-V4-Flash-0731 ] && [ "$(field "$r" pr)" = None ] \
  && [ "$(nposted c7)" = 1 ] && posted c7 | grep -qF '`/oc spec` run' && ! grep -q 'gh pr ' "$work/c7/stub/gh.log"; then
  ok "spec run: work_type spec, risk normal, no_changes, Flash model, posted, no PR calls"
else bad "spec run (rc=$rc)"; cat "$work/c7/out.txt"; fi

# 8. Fix run: issue and PR from fix-meta.txt, outcome pr_updated.
new_case c8
printf 'pr_number=147\nissue_number=133\n' >"$work/c8/art/fix-meta.txt"
run_finish c8 fix success success OC_ISSUE_NUMBER=
if [ "$rc" = 0 ] && [ "$(field "$work/c8/record.json" outcome)" = pr_updated ] && [ "$(field "$work/c8/record.json" pr)" = 147 ] \
  && grep -q 'gh pr edit 147' "$work/c8/stub/gh.log" && ! grep -q 'gh pr list' "$work/c8/stub/gh.log"; then
  ok "fix run: PR and issue from fix-meta.txt, pr_updated, PR 147 body rewritten"
else bad "fix run (rc=$rc)"; cat "$work/c8/out.txt"; fi

# 9. Nothing printed or posted contains the DeepInfra key sentinel.
if ! cat "$work"/c*/out.txt "$work"/c*/summary.md "$work"/c*/stub/posted-*.md "$work"/c*/stub/pr-body-edited.md 2>/dev/null | grep -qF "$SENTINEL"; then
  ok "no key sentinel in output, summaries, posted comments or PR bodies"
else bad "key sentinel leaked"; fi

# --- scripts/opencode-run-meter.sh (agent side) ---
m="$work/meter"; mkdir -p "$m/bin" "$m/repo" "$m/src"
git -C "$m/repo" init -q && git -C "$m/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
cat >"$m/bin/opencode" <<'OC'
#!/usr/bin/env bash
echo "opencode $* (cwd $(pwd))" >>"$METER_LOG"
case "$1 ${2:-}" in
  "session list") echo '[{"id": "ses_good1", "title": "t"}, {"id": "bad id; rm -rf /", "title": "x"}, {"id": "ses_good2"}]' ;;
  "export ses_good1"*) cat tests/factory-usage/opencode-export-session-1.json 2>/dev/null || cat "$FIX1" ;;
  "export ses_good2"*) echo 'not json' ;;
esac
OC
chmod +x "$m/bin/opencode"
printf '#!/usr/bin/env bash\necho "key names: a b" >&2\necho "${FAKE_SPEND:-2.500000}"\n' >"$m/cost.sh"
meter_env=(env PATH="$m/bin:$PATH" METER_LOG="$m/log" FIX1="$PWD/tests/factory-usage/opencode-export-session-1.json" OC_ARTIFACT_DIR="$m/src"
  DEEPINFRA_API_KEY="$SENTINEL" OC_METER_COST_SH="$m/cost.sh" OC_KEY_SPEND_SETTLE_SECONDS=0)
(cd "$m/repo" && "${meter_env[@]}" FACTORY_DEEPINFRA_KEY_NAME=actions bash "$OLDPWD/scripts/opencode-run-meter.sh" start . \
  && "${meter_env[@]}" FACTORY_DEEPINFRA_KEY_NAME=actions FAKE_SPEND=2.5042 bash "$OLDPWD/scripts/opencode-run-meter.sh" end .) >"$m/out.txt" 2>&1
mrc=$?
if [ "$mrc" = 0 ] && [ "$(ls "$m/src-record/usage")" = session-1.json ] && ! grep -q 'bad id' "$m/log" \
  && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d == {"start_usd": 2.5, "end_usd": 2.5042, "concurrent": False} else 1)' "$m/src-record/key-spend.json" \
  && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if set(d) == {"started_at", "ended_at", "base_sha"} and len(d["base_sha"]) == 40 else 1)' "$m/src-record/run-clock.json" \
  && grep -q "session list --format json (cwd $m/repo)" "$m/log" \
  && ! grep -qF "$SENTINEL" "$m/out.txt" && ! grep -q 'key names' "$m/out.txt"; then
  ok "run meter: clock, valid sanitized exports only (bad ids skipped), key-spend.json; no key or key names printed"
else bad "run meter (rc=$mrc)"; cat "$m/out.txt"; fi

# Without the FACTORY_DEEPINFRA_KEY_NAME variable: no key-spend snapshot at all (no API call).
rm -rf "$m/src-record"; : >"$m/cost-called"
printf '#!/usr/bin/env bash\necho called >"%s"\necho 1.0\n' "$m/cost-called" >"$m/cost.sh"
(cd "$m/repo" && "${meter_env[@]}" bash "$OLDPWD/scripts/opencode-run-meter.sh" start . && "${meter_env[@]}" bash "$OLDPWD/scripts/opencode-run-meter.sh" end .) >"$m/out2.txt" 2>&1
if [ ! -f "$m/src-record/key-spend.json" ] && [ ! -s "$m/cost-called" ] && [ -f "$m/src-record/run-clock.json" ]; then
  ok "run meter without FACTORY_DEEPINFRA_KEY_NAME: no key-spend call, clock still written"
else bad "run meter opt-in"; fi

# The meter never fails the run: no OC_ARTIFACT_DIR, bad mode, opencode missing.
if (cd "$m/repo" && env -u OC_ARTIFACT_DIR bash "$OLDPWD/scripts/opencode-run-meter.sh" end . && \
    OC_ARTIFACT_DIR="$m/src" bash "$OLDPWD/scripts/opencode-run-meter.sh" bogus && \
    PATH=/usr/bin:/bin OC_ARTIFACT_DIR="$m/art" OPENCODE_BIN=/nonexistent bash "$OLDPWD/scripts/opencode-run-meter.sh" end .) >/dev/null 2>&1; then
  ok "run meter exits 0 when it can't measure (no artifact dir, bad mode, no opencode)"
else bad "run meter must never fail the run"; fi


# --- scripts/factory-run-pack.sh (agent job, always) ---
p="$work/pack"; mkdir -p "$p/src" "$p/src-record/usage"
echo '{"started_at": "2026-11-09T01:00:00Z", "base_sha": "x"}' >"$p/src-record/run-clock.json"
echo '{"run_id": "gha-1-1"}' >"$p/src/run-start.json"; echo spec >"$p/src/spec.md"; echo 'pr_number=1' >"$p/src/fix-meta.txt"
echo 2.5 >"$p/src-record/key-spend-start.txt"
echo '{"ok": 1}' >"$p/src-record/usage/session-1.json"
echo '{"leak": "ghp_abcdefghijklmnopqrstuvwxyz0123"}' >"$p/src-record/usage/session-2.json"
OC_ARTIFACT_DIR="$p/src" GITHUB_OUTPUT="$p/out" bash scripts/factory-run-pack.sh >"$p/log" 2>&1
if grep -qx ok=yes "$p/out" && [ -f "$p/src-record/usage/session-1.json" ] && [ ! -f "$p/src-record/usage/session-2.json" ] \
  && [ -f "$p/src-record/run-start.json" ] && [ -f "$p/src-record/spec.md" ] && [ -f "$p/src-record/fix-meta.txt" ] \
  && [ ! -f "$p/src-record/key-spend-start.txt" ] && ! grep -q ghp_ "$p/log"; then
  ok "run pack: copies run-start/spec/fix-meta, drops an export with a scan hit, ok=yes"
else bad "run pack"; cat "$p/log"; fi
echo '{"run_id": "ghp_abcdefghijklmnopqrstuvwxyz0123"}' >"$p/src/run-start.json"; : >"$p/out"
OC_ARTIFACT_DIR="$p/src" GITHUB_OUTPUT="$p/out" bash scripts/factory-run-pack.sh >"$p/log" 2>&1; prc=$?
rm -rf "$p/none"; OC_ARTIFACT_DIR="$p/none" GITHUB_OUTPUT="$p/out" bash scripts/factory-run-pack.sh >/dev/null 2>&1; nrc=$?
if [ "$prc" = 0 ] && [ "$nrc" = 0 ] && [ ! -s "$p/out" ] && ! grep -q ghp_ "$p/log"; then
  ok "run pack: scan hit in record files or no clock: exit 0, nothing uploaded"
else bad "run pack fail-closed (rc=$prc/$nrc)"; fi

echo "Results: ${passed} passed, ${failed} failed"
[ "$failed" -eq 0 ]
