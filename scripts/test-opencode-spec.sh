#!/usr/bin/env bash
# Offline tests for /oc spec (#78): model choice and cost guard, the read-only worker run with a
# fake `opencode`, draft extraction and checks, the publish step with a fake `gh`, the approval
# helper, and the build workflow's refusal of "/oc spec". No network, no tokens.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
py="${FACTORY_PYTHON:-python3}"
if ! "$py" -c "import yaml" 2>/dev/null; then
  echo "PyYAML is required (pip install -r requirements-factory.txt, or set FACTORY_PYTHON)." >&2
  exit 2
fi
work="$(mktemp -d)"
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL="$work/gitconfig"; : >"$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@t
unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY GH_TOKEN GITHUB_TOKEN GITHUB_ACTIONS || true
passed=0
failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }
draft() { "$py" scripts/opencode-spec-draft.py "$@"; }

# --- model and cost guard from models.yaml
if [ "$(draft model)" = deepseek-ai/DeepSeek-V4-Pro-0813 ] && draft preflight | grep -q '^predicted_spec_run_usd=0\.0[0-9]*$'; then
  ok "model: no issue context -> V4 Pro from models.yaml rule 2 (fail safe); predicted spec run under \$0.10"
else bad "model / preflight"; fi
printf '# Issue #64\n\ndbt hygiene: disable anonymous stats.\n' >"$work/ctx-normal.md"
printf '# Issue #134\n\n## Budget\n- Risk: **high**, complexity: **standard**\n' >"$work/ctx-high.md"
pf_normal="$(draft preflight --context "$work/ctx-normal.md" --guidance="keep it small")"
if grep -qx 'model=deepseek-ai/DeepSeek-V4-Flash-0731' <<<"$pf_normal" && grep -qx 'risk_class=not_high' <<<"$pf_normal" \
  && [ "$(draft model --context "$work/ctx-high.md")" = deepseek-ai/DeepSeek-V4-Pro-0813 ] \
  && [ "$(draft model --context "$work/ctx-normal.md" --guidance="risk: high")" = deepseek-ai/DeepSeek-V4-Pro-0813 ] \
  && [ "$(draft model --context "$work/ctx-normal.md" --guidance="-x high-risk change")" = deepseek-ai/DeepSeek-V4-Pro-0813 ]; then
  ok "model: issue without high risk -> V4 Flash rule 9; 'Risk: high' in the issue or guidance -> V4 Pro rule 2"
else bad "model: risk-based spec routing"; echo "$pf_normal"; fi
"$py" - "$work/models-big.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(".factory/models.yaml"))
d["token_priors"]["spec"] = {"tokens_in": 2000000, "tokens_cached_fraction": 0.1, "tokens_out": 100000}
yaml.safe_dump(d, open(sys.argv[1], "w"), sort_keys=False)
PY
if ! draft --models "$work/models-big.yaml" preflight >/dev/null 2>&1; then ok "preflight: predicted spec run above the \$1 cap refused"
else bad "preflight over cap"; fi

# --- a scratch repo: the worker runs here (fake opencode prints a canned final message)
repo="$work/repo"
mkdir -p "$repo"
git ls-files -co --exclude-standard | tar -T - -cf - | tar -xf - -C "$repo"
(cd "$repo" && git init -q && git add -A && git commit -qm base)
mkdir -p "$work/bin"
cat >"$work/bin/opencode" <<'OC'
#!/usr/bin/env bash
# Fake OpenCode: prints $FAKE_OC_OUT as the session output; may touch the tree.
[ "${1:-}" = run ] || exit 0
printf 'some tool chatter\n'
cat "$FAKE_OC_OUT"
if [ -n "${FAKE_OC_TOUCH:-}" ]; then echo x >"$FAKE_OC_TOUCH"; fi
if [ -n "${FAKE_OC_CFG:-}" ]; then printf '%s' "${OPENCODE_CONFIG_CONTENT:-}" >"$FAKE_OC_CFG"; fi
OC
chmod +x "$work/bin/opencode"
mkstats() { # cost -> stats file
  sed "s/\\\$0.0028/\\\$$1/" tests/opencode-capture-usage/stats-normal.txt | sed 's/V4-Flash-0731/V4-Pro-0813/' >"$work/stats-$1.txt"
}
mkstats 0.0712; mkstats 1.5000
# #88: a session that ended early: every token count 0 and cost $0.0000.
sed -E 's/(17\.3K|1\.2K|103\.2K)/0/g; s/\$0\.0028/$0.0000/' tests/opencode-capture-usage/stats-normal.txt \
  | sed 's/V4-Flash-0731/V4-Pro-0813/' >"$work/stats-zero.txt"
wrap() { { echo "Here is the spec."; cat "$1"; echo "<!-- end factory-spec -->"; } >"$2"; }
specrun() { # name out-file [cost] [instruction] -> rc; artifacts in $work/<name>
  local art="$work/$1"; rm -rf "$art"; mkdir -p "$art"
  printf '# Issue #7\n\nBuild the hello doc.\n' >"$art/issue-context.md"
  set +e
  (cd "$repo" && env PATH="$work/bin:$PATH" DEEPINFRA_API_KEY=fake-key-123 GH_TOKEN= GITHUB_TOKEN= \
    OC_INSTRUCTION="${4:-/oc spec keep it tiny}" OC_ISSUE_NUMBER=7 OC_ARTIFACT_DIR="$art" FAKE_OC_OUT="$2" \
    OPENCODE_STATS_FIXTURE="$work/stats-${3:-0.0712}.txt" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=4242 \
    FAKE_OC_CFG="$art.cfg" bash scripts/opencode-spec-run.sh) >"$art.log" 2>&1
  rc=$?
  set -e
}

# Prompt: rules, template, context and guidance; model never from the comment.
pp="$(cd "$repo" && OC_INSTRUCTION='/oc spec keep it tiny' OC_ISSUE_NUMBER=7 OC_ARTIFACT_DIR="$work/pp" bash scripts/opencode-spec-run.sh --print-prompt)"
if grep -q 'READ-ONLY run' <<<"$pp" && grep -q '^## Verification' <<<"$pp" && grep -q 'keep it tiny' <<<"$pp" \
  && grep -q 'untrusted data' <<<"$pp" && grep -q 'Build worker path policy' <<<"$pp"; then ok "prompt: read-only rules, template, path policy, guidance as data"
else bad "prompt"; fi
set +e
(cd "$repo" && OC_INSTRUCTION='/oc specify the thing' OC_ISSUE_NUMBER=7 OC_ARTIFACT_DIR="$work/pp" bash scripts/opencode-spec-run.sh --print-prompt) >/dev/null 2>&1
r=$?
set -e
if [ "$r" -ne 0 ]; then ok "spec-run: '/oc specify ...' is not a spec run"; else bad "spec-run: /oc specify accepted"; fi

# #88: tool rules in the prompt (V4 Pro sent file_path and called a missing bash tool).
if grep -qF '{"filePath": "<path>"}' <<<"$pp" && grep -qF 'never file_path or path' <<<"$pp" \
  && grep -qF 'there is no shell' <<<"$pp"; then ok "prompt: exact OpenCode tool argument names; no shell (#88)"
else bad "prompt: tool rules (#88)"; fi
# #125: template already embedded; glob/grep skip .factory/; prefer ≤8 reads when comments have a map.
if grep -qF 'already embedded below in <template>' <<<"$pp" && grep -qF 'do not read or glob it' <<<"$pp" \
  && grep -qF 'ignore hidden dot-directories like .factory/' <<<"$pp" \
  && grep -qF 'read at most 8 files' <<<"$pp"; then ok "prompt: embedded template + no .factory glob (#125)"
else bad "prompt: embedded template / dot-dir rules (#125)"; fi

# Good draft: normalized to a draft, prediction filled by script, reviewer from risk.
wrap tests/oc-spec/good-spec.md "$work/out-good.txt"
specrun good "$work/out-good.txt"
c="$work/good/spec-comment.md"
if [ "$rc" -eq 0 ] && [ "$(head -n 1 "$c")" = '<!-- factory-spec-draft v1 -->' ] && grep -qx 'status: draft' "$c" \
  && grep -qx 'approved_by: null' "$c" && grep -qx 'approved_at: null' "$c" && grep -qx 'drafted_by: oc-spec-run' "$c" \
  && grep -qx 'model_override_reason: ' "$c" && grep -qx 'model: deepseek-ai/DeepSeek-V4-Flash-0731' "$c" \
  && grep -qx 'predicted_cost_usd: 0.0330' "$c" && ! grep -q 'worker guess' "$c"; then
  ok "build: approved/override fields reset to a draft; model + prediction filled by factory-predict-cost.py"
else bad "build: normalized draft (rc=$rc)"; cat "$work/good.log"; head -40 "$c" 2>/dev/null; fi
if grep -q '^- Review: Grok Bot (risk normal)' "$c" && grep -q '^- Approval: Grok Bot may approve (risk normal; approved_by: grok-bot)' "$c" \
  && grep -q 'Spec run: deepseek-ai/DeepSeek-V4-Flash-0731 (models.yaml rule 9' "$c" && grep -q 'cost \$0.0712 (OpenCode-reported)' "$c" \
  && grep -q 'actions/runs/4242' "$c" && grep -qx 'reviewer=Grok' "$work/good/spec-meta.txt" && grep -qx 'worktree=unchanged' "$work/good/spec-meta.txt"; then
  ok "build: review/approval lines, spec-run model + cost + run link"
else bad "build: header lines"; head -12 "$c"; cat "$work/good/spec-meta.txt"; fi
if python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["permission"]; sys.exit(0 if p["bash"]=={"*":"deny"} and p["doom_loop"]=="deny" and p["edit"]=="deny" else 1)' "$work/good.cfg"; then
  ok "spec-run config: bash kept as an all-deny map, doom_loop denied, edit denied (#88)"
else bad "spec-run config (#88)"; cat "$work/good.cfg" 2>/dev/null || true; fi
specrun zero "$work/out-good.txt" zero
if grep -q 'cost not measured' "$work/zero/spec-comment.md" && grep -q 'OpenCode stats empty' "$work/zero/spec-comment.md" \
  && ! grep -q '\$0\.0000' "$work/zero/spec-comment.md"; then ok "build: empty OpenCode stats say 'not measured', never \$0.0000 (#88)"
else bad "build: zero stats (#88)"; grep -n 'Spec run' "$work/zero/spec-comment.md" || true; fi
if draft check-comment "$c" --issue 7 >/dev/null 2>&1; then ok "check-comment: the draft passes the publish re-check"
else bad "check-comment on the good draft"; draft check-comment "$c" --issue 7 || true; fi
if ! draft check-comment "$c" --issue 8 >/dev/null 2>&1; then ok "check-comment: draft for another issue refused"; else bad "check-comment issue mismatch"; fi
# The context step must never take the bot's draft as the approved spec (non-owner, status draft).
"$py" - "$c" "$work/ctx.json" <<'PY'
import json, sys
body = open(sys.argv[1]).read()
json.dump({"issue": {"number": 7, "title": "t", "body": "b", "html_url": "u"},
           "comments": [{"id": 900, "author_association": "NONE", "user": {"login": "github-actions[bot]"},
                         "created_at": "2026-11-02T12:00:00Z", "body": body},
                        {"id": 901, "author_association": "OWNER", "user": {"login": "Data-Science-Link"},
                         "created_at": "2026-11-02T12:01:00Z", "body": body}]}, open(sys.argv[2], "w"))
PY
"$py" scripts/opencode-build-context.py --from-json "$work/ctx.json" --issue 7 --out-dir "$work/ctxout" >/dev/null 2>&1 || true
if grep -qx 'spec_comment_id=none' "$work/ctxout/context-meta.txt"; then ok "context step ignores the draft (bot author; status draft even from the owner)"
else bad "context step picked up a draft"; cat "$work/ctxout/context-meta.txt"; fi

# High risk: review goes to Michael.
sed 's/^risk: normal$/risk: high/' tests/oc-spec/good-spec.md >"$work/high.md"
printf '\n## Alternatives considered\nx\n\n## Test plan detail (broken case shown blocked)\nx\n\n## Security and liability review\nx\n\n## Milestones / split plan\nx\n' >>"$work/high.md"
wrap "$work/high.md" "$work/out-high.txt"
specrun high "$work/out-high.txt"
if grep -q '^- Review: Michael (risk high)' "$work/high/spec-comment.md" && grep -q '^- Approval: Michael only (risk high' "$work/high/spec-comment.md"; then ok "build: risk high -> Michael reviews and approves"
else bad "build: high-risk reviewer"; head -8 "$work/high/spec-comment.md"; fi
hc="$work/high/spec-comment.md"
if sed -n 2p "$hc" | grep -q "^\*\*Over \$0\.15 target: needs Michael's approval\*\* (predicted build \$0\.1900)" \
  && grep -q '^- Note: the issue did not say high risk, so this spec run used deepseek-ai/DeepSeek-V4-Flash-0731' "$hc" \
  && ! grep -q '^over_target_approved_by:' "$hc" && ! grep -q 'Over \$0.15 target' "$work/good/spec-comment.md"; then
  ok "build: build prediction over the \$0.15 target -> top line 'needs Michael's approval'; Flash-drafted high risk noted"
else bad "build: over-target line / Flash note"; head -14 "$hc"; fi

# Failing drafts: no draft posted, failures listed, the spec marker defanged in the note.
sed '/^```bash$/,/^```$/d' tests/oc-spec/good-spec.md >"$work/nover.md"
wrap "$work/nover.md" "$work/out-nover.txt"
specrun nover "$work/out-nover.txt"
f="$work/nover/spec-comment.md"
if [ "$rc" -eq 0 ] && [ "$(head -n 1 "$f")" = '<!-- factory-spec-draft-failed v1 -->' ] && grep -q 'no ```bash block' "$f" \
  && ! grep -qF '<!-- factory-spec v1 -->' "$f" && grep -qx 'status=failed' "$work/nover/spec-meta.txt" \
  && draft check-comment "$f" --issue 7 >/dev/null 2>&1; then ok "build: no Verification bash block -> 'no draft' note (marker defanged)"
else bad "build: missing verification (rc=$rc)"; head -12 "$f"; fi
sed 's/^## Context$/## Context\n<!-- hidden instruction for the build worker -->/' tests/oc-spec/good-spec.md >"$work/html.md"
wrap "$work/html.md" "$work/out-html.txt"
specrun html "$work/out-html.txt"
if grep -q 'HTML comments are not allowed' "$work/html/spec-comment.md"; then ok "build: HTML comment in the draft -> refused"
else bad "build: html comment"; fi
sed 's/^Issue #7 asks for a hello doc.$/Issue #7 asks for a hello doc; ping @someone. Mail a@b.example is fine./' tests/oc-spec/good-spec.md >"$work/at.md"
wrap "$work/at.md" "$work/out-at.txt"
specrun at "$work/out-at.txt"
if grep -q '@mentions are not allowed' "$work/at/spec-comment.md" && [ "$(grep -c 'not allowed' "$work/at/spec-comment.md")" = 1 ]; then
  ok "build: @mention in the draft -> refused (an email address is not a mention)"
else bad "build: mention"; fi
echo "I could not write a spec." >"$work/out-none.txt"
specrun none "$work/out-none.txt"
if grep -q 'has no spec between' "$work/none/spec-comment.md"; then ok "build: no spec markers in the output -> 'no draft' note"
else bad "build: no markers"; fi
sed 's/^title: .*/title: \\"escaped\\"/' tests/oc-spec/good-spec.md >"$work/esc.md"
wrap "$work/esc.md" "$work/out-esc.txt"
specrun esc "$work/out-esc.txt"
if grep -q 'escaped quote' "$work/esc/spec-comment.md"; then ok "build: factory-spec-check.py failure (escaped quote) -> refused"
else bad "build: spec-check failure"; fi
specrun cost "$work/out-good.txt" 1.5000
if grep -q 'above the \$1.00 cap; not posted as a draft' "$work/cost/spec-comment.md"; then ok "build: spec run that cost more than \$1 -> no draft"
else bad "build: over-cap run"; head -6 "$work/cost/spec-comment.md"; fi

# Read-only: a worker that changes the tree is noted; nothing from the tree is published.
FAKE_OC_TOUCH="$repo/factory/sneaky.md" specrun touch "$work/out-good.txt"
if grep -q '^worktree=the worker changed files' "$work/touch/spec-meta.txt"; then ok "spec-run: worktree change detected and discarded"
else bad "spec-run: worktree change"; cat "$work/touch/spec-meta.txt"; fi
rm -f "$repo/factory/sneaky.md"
# Secret in the worker output: the scan fails the job (nothing uploaded, nothing posted).
{ cat "$work/out-good.txt"; echo "leak ghp_abcdefghijklmnopqrstuvwxyz0123456789"; } >"$work/out-leak.txt"
specrun leak "$work/out-leak.txt"
if [ "$rc" -ne 0 ] && grep -q 'artifact-scan: FAIL' "$work/leak.log"; then ok "spec-run: token in the output -> scan fails the job"
else bad "spec-run: secret scan (rc=$rc)"; tail -3 "$work/leak.log"; fi

# --- publish-spec with a fake gh (records the posted body)
cat >"$work/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = "issue comment" ]; then
  while [ $# -gt 0 ]; do if [ "$1" = --body-file ]; then cp "$2" "$FAKE_GH_OUT"; fi; shift; done
  echo "https://github.com/o/r/issues/7#issuecomment-555"; exit 0
fi
if [ "$1 $2" = "issue view" ]; then cat "$FAKE_GH_VIEW"; exit 0; fi
echo "fake gh: unexpected call: $*" >&2; exit 1
GH
chmod +x "$work/bin/gh"
publish() { # art result -> rc; posted body in $work/posted.md
  rm -f "$work/posted.md"
  set +e
  (cd "$repo" && env PATH="$work/bin:$PATH" FAKE_GH_OUT="$work/posted.md" OC_ISSUE_NUMBER=7 OC_RUN_ID=4242 \
    OC_ARTIFACT_DIR="$1" OC_AGENT_RESULT="$2" GITHUB_REPOSITORY=o/r bash scripts/opencode-publish-spec.sh) >"$1.pub.log" 2>&1
  rc=$?
  set -e
}
publish "$work/good" success
if [ "$rc" -eq 0 ] && cmp -s "$work/posted.md" "$work/good/spec-comment.md"; then ok "publish: posts the checked draft as is"
else bad "publish: good draft (rc=$rc)"; cat "$work/good.pub.log"; fi
publish "$work/none" success
if [ "$rc" -eq 0 ] && grep -q 'no draft posted' "$work/posted.md"; then ok "publish: posts the 'no draft' note"; else bad "publish: no-draft note"; fi
publish "$work/missing" failure
if [ "$rc" -eq 0 ] && grep -q 'ended with result `failure`' "$work/posted.md" && grep -q 'actions/runs/4242' "$work/posted.md"; then
  ok "publish: agent job failed -> failure note with the run link (never silent)"
else bad "publish: failure note"; cat "$work/missing.pub.log"; fi
cp -R "$work/good" "$work/tamper"; sed -i 's/^status: draft$/status: approved/' "$work/tamper/spec-comment.md"
publish "$work/tamper" success
if [ "$rc" -ne 0 ] && [ ! -e "$work/posted.md" ]; then ok "publish: artifact edited to 'approved' -> refused, nothing posted"
else bad "publish: tampered draft (rc=$rc)"; fi

# --- approval: the existing convention (owner posts the approved copy), via the helper
spec_only="$work/good/spec-draft.md"
if draft approve "$spec_only" --approved-by grok-bot --issue 7 | grep -qx 'approved_by: grok-bot'; then
  ok "approve: Grok Bot may approve a standard/normal spec"; else bad "approve: grok-bot on normal"; fi
sed 's/^risk: normal$/risk: high/' "$spec_only" >"$work/high-spec.md"
printf '\n## Alternatives considered\nx\n\n## Test plan detail (broken case shown blocked)\nx\n\n## Security and liability review\nx\n\n## Milestones / split plan\nx\n' >>"$work/high-spec.md"
set +e
hout="$(draft approve "$work/high-spec.md" --approved-by grok-bot 2>&1)"; hr=$?
set -e
if [ "$hr" -ne 0 ] && grep -q 'only Michael approves high-risk specs' <<<"$hout" \
  && draft approve "$work/high-spec.md" --approved-by michael | grep -qx 'approved_by: michael'; then
  ok "approve: high risk -> grok-bot refused, michael accepted"
else bad "approve: high-risk rule"; echo "$hout"; fi
set +e
ot_plain="$(draft approve "$work/high-spec.md" --approved-by michael 2>"$work/ot.err")"
ot_bot="$(draft approve "$work/high-spec.md" --approved-by grok-bot --over-target-ok 2>&1)"; ot_bot_rc=$?
set -e
ot_ok="$(draft approve "$work/high-spec.md" --approved-by michael --over-target-ok)"
if ! grep -q '^over_target_approved_by:' <<<"$ot_plain" && grep -q "Over \$0.15 target: needs Michael's approval" "$work/ot.err" \
  && grep -qx 'over_target_approved_by: michael' <<<"$ot_ok" && [ "$ot_bot_rc" -ne 0 ] \
  && ! draft approve "$spec_only" --approved-by michael --over-target-ok | grep -q '^over_target_approved_by:' \
  && printf '%s\n' "$ot_ok" >"$work/ot-ok.md" && "$py" scripts/factory-spec-check.py "$work/ot-ok.md" >/dev/null; then
  ok "approve: over target -> warning without --over-target-ok; flag sets over_target_approved_by: michael (Michael only; not set under target)"
else bad "approve: over-target flag"; cat "$work/ot.err"; echo "$ot_bot"; fi
if ! draft approve "$spec_only" --approved-by someone-else >/dev/null 2>&1; then ok "approve: unknown approver refused"
else bad "approve: unknown approver"; fi
draft approve "$spec_only" --approved-by michael --at '2026-11-02T19:00:00-06:00' --issue 7 >"$work/approved.md"
if grep -qx 'status: approved' "$work/approved.md" && grep -qx 'approved_by: michael' "$work/approved.md" \
  && grep -qx "approved_at: '2026-11-02T19:00:00-06:00'" "$work/approved.md" && grep -qx 'drafted_by: oc-spec-run' "$work/approved.md" \
  && "$py" scripts/factory-spec-check.py "$work/approved.md" >/dev/null; then ok "approve: approved copy with approved_by/at, passes the spec check"
else bad "approve: michael"; head -25 "$work/approved.md"; fi
"$py" - "$work/approved.md" "$work/ctx2.json" <<'PY'
import json, sys
json.dump({"issue": {"number": 7, "title": "t", "body": "b", "html_url": "u"},
           "comments": [{"id": 902, "author_association": "OWNER", "user": {"login": "Data-Science-Link"},
                         "created_at": "2026-11-02T12:02:00Z", "body": open(sys.argv[1]).read()}]}, open(sys.argv[2], "w"))
PY
"$py" scripts/opencode-build-context.py --from-json "$work/ctx2.json" --issue 7 --out-dir "$work/ctxout2" >/dev/null
if grep -qx 'spec_comment_id=902' "$work/ctxout2/context-meta.txt" && cmp -s "$work/ctxout2/spec.md" "$work/approved.md"; then
  ok "approve: /oc's context step takes the posted copy, byte for byte"
else bad "approve: context step on the approved copy"; fi
sed -e 's/^complexity: standard$/complexity: simple/' -e 's/^risk: normal$/risk: trivial/' "$spec_only" >"$work/simple.md"
if draft approve "$work/simple.md" --approved-by grok-bot | grep -qx 'model: deepseek-ai/DeepSeek-V4-Flash-0731'; then
  ok "approve: Grok Bot approves simple + trivial; prediction re-filled after the edit"
else bad "approve: simple+trivial"; fi

# factory-approve-spec.py: finds the draft by URL, refuses non-drafts, posts the approved copy.
"$py" - "$work/good/spec-comment.md" "$work/view.json" <<'PY'
import json, sys
body = open(sys.argv[1]).read()
json.dump({"comments": [
  {"author": {"login": "github-actions"}, "authorAssociation": "NONE", "body": body,
   "url": "https://github.com/o/r/issues/7#issuecomment-900"},
  {"author": {"login": "someone"}, "authorAssociation": "NONE", "body": body,
   "url": "https://github.com/o/r/issues/7#issuecomment-901"}]}, open(sys.argv[2], "w"))
PY
helper() { rm -f "$work/posted.md"; set +e
  env PATH="$work/bin:$PATH" FAKE_GH_OUT="$work/posted.md" FAKE_GH_VIEW="$work/view.json" "$py" scripts/factory-approve-spec.py "$@" >"$work/helper.log" 2>&1
  rc=$?; set -e; }
helper 7 'https://github.com/o/r/issues/7#issuecomment-900' --approved-by grok-bot
if [ "$rc" -eq 0 ] && grep -qx 'status: approved' "$work/posted.md" && grep -qx 'approved_by: grok-bot' "$work/posted.md" && [ "$(head -n 1 "$work/posted.md")" = '<!-- factory-spec v1 -->' ]; then
  ok "approve helper: posts the approved copy (marker on line 1)"
else bad "approve helper: post (rc=$rc)"; cat "$work/helper.log"; fi
helper 7 'https://github.com/o/r/issues/7#issuecomment-901' --approved-by michael
if [ "$rc" -ne 0 ] && [ ! -e "$work/posted.md" ]; then ok "approve helper: a copy posted by someone else is refused"; else bad "approve helper: non-bot author"; fi
helper 7 900 --approved-by michael --dry-run
if [ "$rc" -eq 0 ] && [ ! -e "$work/posted.md" ] && grep -qx 'status: approved' "$work/helper.log"; then ok "approve helper: --dry-run posts nothing"
else bad "approve helper: dry run"; fi

# --- the build workflow's agent refuses "/oc spec" (both workflows trigger on "/oc" comments)
set +e
out="$(cd "$repo" && OC_INSTRUCTION='/oc spec' OC_ISSUE_NUMBER=7 OC_ARTIFACT_DIR="$work/ar" bash scripts/opencode-agent-run.sh --print-prompt 2>&1)"
r=$?
set -e
if [ "$r" -ne 0 ] && grep -q 'handled by the opencode-spec workflow' <<<"$out"; then ok "agent-run: '/oc spec' starts no build worker"
else bad "agent-run: /oc spec guard"; fi

echo "Results: ${passed} passed, ${failed} failed"
[ "$failed" -eq 0 ]
