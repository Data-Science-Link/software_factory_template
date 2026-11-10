#!/usr/bin/env bash
# Offline tests for #92: the agent scripts (opencode-agent-run.sh, opencode-agent-fix.sh) run
# exactly the model run start routed. OC_MODEL is required, must be a deepinfra model listed in
# .factory/models.yaml, and is passed to OpenCode unchanged (a fake `opencode` records --model).
# Refusals happen before OpenCode starts. No network, no real key. PASS/FAIL per case.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
py="${FACTORY_PYTHON:-python3}"
"$py" -c 'import yaml' 2>/dev/null || { echo "PyYAML is required (pip install -r requirements-factory.txt)" >&2; exit 2; }
work="$(mktemp -d)"
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL="$work/gitconfig"; : >"$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@t
unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY GH_TOKEN GITHUB_TOKEN GITHUB_ACTIONS OC_MODEL || true
passed=0; failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }
FAKE_KEY=fake-deepinfra-key-model-test
PRO=deepseek-ai/DeepSeek-V4-Pro-0813
QWEN=Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo

# Fake worker: records every argument after --model, then makes one change.
mkdir -p "$work/bin"
cat >"$work/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
case "$1" in stats | session | export) exit 0 ;; esac  # #31: the run meter calls session/export
prev=''
for a in "$@"; do [ "$prev" = --model ] && echo "$a" >>"$FAKE_MODEL_LOG"; prev="$a"; done
mkdir -p factory/x && echo hello >factory/x/model-test.md
printf '## What I changed and why\n- added a file\n'
FAKE
chmod +x "$work/bin/opencode"

# --- build: a repo copy with an approved-spec context (as in test-opencode-verify.sh)
repo="$work/repo"
mkdir -p "$repo"
git ls-files -co --exclude-standard | tar -T - -cf - | tar -xf - -C "$repo"
(cd "$repo" && git init -q && git add -A && git commit -qm base)
"$py" scripts/opencode-build-context.py --from-json tests/oc-context/approved.json --out-dir "$work/ctx" >/dev/null

agent_run() { # name [VAR=VAL...] -> rc; artifacts in $work/<name>
  local name="$1"; shift
  local art="$work/$name"
  rm -rf "$art"; mkdir -p "$art"; cp "$work/ctx/"* "$art/"
  : >"$work/$name.models"
  (cd "$repo" && git reset -q --hard && git clean -qfd)
  local rc=0
  (cd "$repo" && env PATH="$work/bin:$PATH" FAKE_MODEL_LOG="$work/$name.models" OC_INSTRUCTION='/oc run' \
    OC_ISSUE_NUMBER=7 OC_ARTIFACT_DIR="$art" DEEPINFRA_API_KEY="$FAKE_KEY" OC_VERIFY_SANDBOX=none "$@" \
    bash scripts/opencode-agent-run.sh) >"$work/$name.log" 2>&1 || rc=$?
  return "$rc"
}

rc=0; agent_run b1 OC_MODEL="$PRO" || rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$work/b1.models")" = "deepinfra/$PRO" ] \
  && grep -qx "model_id=$PRO" "$work/b1/context-meta.txt"; then
  ok "agent-run: routed model passed to opencode unchanged (--model deepinfra/$PRO); meta records model_id"
else bad "agent-run: routed model pass-through (rc=$rc, models=$(cat "$work/b1.models"))"; tail -5 "$work/b1.log"; fi

rc=0; agent_run b2 OC_MODEL="$QWEN" || rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$work/b2.models")" = "deepinfra/$QWEN" ]; then
  ok "agent-run: fallback model (Qwen3-Coder) passed unchanged"
else bad "agent-run: Qwen pass-through (rc=$rc)"; fi

rc=0; agent_run b3 || rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$work/b3.models" ] && grep -q 'OC_MODEL is required' "$work/b3.log"; then
  ok "agent-run: missing OC_MODEL refused before opencode starts"
else bad "agent-run: missing OC_MODEL (rc=$rc)"; fi

for m in openai/gpt-5 "deepinfra/$PRO" 'deepseek-ai/DeepSeek-V4-Pro-0813 --agent x' ''; do
  rc=0; agent_run b4 OC_MODEL="$m" || rc=$?
  if [ "$rc" -ne 0 ] && [ ! -s "$work/b4.models" ] && ! grep -qF "$FAKE_KEY" "$work/b4.log"; then
    ok "agent-run: OC_MODEL='$m' refused before opencode starts"
  else bad "agent-run: OC_MODEL='$m' (rc=$rc)"; fi
done

# The worker's checkout cannot widen the allow-list: models.yaml is read before the worker runs,
# and a models.yaml edit in the patch only lands through review. Here the repo copy lists only
# Flash, so Pro is refused even though the real models.yaml has it.
"$py" - "$repo/.factory/models.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]
d = yaml.safe_load(open(p))
d["models"] = [m for m in d["models"] if m["id"].endswith("Flash-0731")]
yaml.safe_dump(d, open(p, "w"), sort_keys=False)
PY
(cd "$repo" && git commit -qam "flash only")
rc=0; agent_run b5 OC_MODEL="$PRO" || rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$work/b5.models" ] && grep -q 'OC_MODEL is not a deepinfra model' "$work/b5.log"; then
  ok "agent-run: a model not in this checkout's models.yaml is refused"
else bad "agent-run: models.yaml allow-list (rc=$rc)"; fi
(cd "$repo" && git reset -q --hard HEAD~1)

# --- fix: PR head checkout + fix context, as in test-opencode-verify.sh
prdir="$work/prhead"
mkdir -p "$prdir"
git ls-files -co --exclude-standard | tar -T - -cf - | tar -xf - -C "$prdir"
(cd "$prdir" && git init -q && git add -A && git commit -qm head)
head_real="$(git -C "$prdir" rev-parse HEAD)"
"$py" - tests/oc-context/approved.json "$work/fixpr.json" "$head_real" <<'PY'
import json, sys
src, out, sha = sys.argv[1:]
d = json.load(open(src))
repo = {"full_name": "Data-Science-Link/software_factory_template", "fork": False, "default_branch": "main"}
fx = {"pr": {"number": 80, "state": "open", "title": "t", "head": {"ref": "oc/issue-7-555", "sha": sha, "repo": repo},
             "base": {"ref": "main", "repo": repo}},
      "head_commit_date": "2026-11-02T19:00:00Z", "files": [], "reviews": [], "review_comments": [],
      "pr_comments": [], "issue": d["issue"], "issue_comments": d["comments"]}
json.dump(fx, open(out, "w"))
PY
"$py" scripts/opencode-build-fix-context.py --repo Data-Science-Link/software_factory_template \
  --from-json "$work/fixpr.json" --out-dir "$work/fctx" >/dev/null

agent_fix() { # name [VAR=VAL...] -> rc
  local name="$1"; shift
  local art="$work/$name"
  rm -rf "$art"; mkdir -p "$art"; cp "$work/fctx/"* "$art/"
  : >"$work/$name.models"
  (cd "$prdir" && git reset -q --hard && git clean -qfd)
  local rc=0
  env PATH="$work/bin:$PATH" FAKE_MODEL_LOG="$work/$name.models" OC_INSTRUCTION='/oc fix add a file' \
    OC_ARTIFACT_DIR="$art" OC_PR_DIR="$prdir" DEEPINFRA_API_KEY="$FAKE_KEY" OC_VERIFY_SANDBOX=none "$@" \
    bash scripts/opencode-agent-fix.sh >"$work/$name.log" 2>&1 || rc=$?
  return "$rc"
}

rc=0; agent_fix f1 OC_MODEL="$PRO" || rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$work/f1.models")" = "deepinfra/$PRO" ] && grep -qx "model_id=$PRO" "$work/f1/fix-meta.txt"; then
  ok "agent-fix: routed model passed to opencode unchanged; fix-meta records model_id"
else bad "agent-fix: routed model pass-through (rc=$rc)"; tail -5 "$work/f1.log"; fi

rc=0; agent_fix f2 || rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$work/f2.models" ] && grep -q 'OC_MODEL is required' "$work/f2.log"; then
  ok "agent-fix: missing OC_MODEL refused before opencode starts"
else bad "agent-fix: missing OC_MODEL (rc=$rc)"; fi

rc=0; agent_fix f3 OC_MODEL=openai/gpt-5 || rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$work/f3.models" ] && grep -q 'OC_MODEL is not a deepinfra model' "$work/f3.log"; then
  ok "agent-fix: unknown OC_MODEL refused before opencode starts"
else bad "agent-fix: unknown OC_MODEL (rc=$rc)"; fi

# The PR head's models.yaml is never the allow-list: a PR head that lists only Flash does not
# block Pro, and one that adds a model cannot allow it (the trusted checkout's file decides).
"$py" - "$prdir/.factory/models.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]
d = yaml.safe_load(open(p))
d["models"].append({"id": "evil/model", "provider": "deepinfra", "price_in_per_mtok": 0,
                    "price_cached_per_mtok": 0, "price_out_per_mtok": 0})
yaml.safe_dump(d, open(p, "w"), sort_keys=False)
PY
(cd "$prdir" && git commit -qam "pr head adds a model")
"$py" - "$work/fctx/fix-meta.txt" "$(git -C "$prdir" rev-parse HEAD)" <<'PY'
import re, sys
p, sha = sys.argv[1:]
t = open(p).read()
open(p, "w").write(re.sub(r"^head_sha=.*$", f"head_sha={sha}", t, flags=re.M))
PY
rc=0; agent_fix f4 OC_MODEL=evil/model || rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$work/f4.models" ] && grep -q 'OC_MODEL is not a deepinfra model' "$work/f4.log"; then
  ok "agent-fix: a model added only on the PR head's models.yaml is refused"
else bad "agent-fix: PR head models.yaml (rc=$rc)"; fi

if grep -rqF "$FAKE_KEY" "$work"/b1 "$work"/f1 2>/dev/null; then bad "no key in any artifact"; else ok "no key in any artifact"; fi

echo "Results: ${passed} passed, ${failed} failed"
[ "$failed" -eq 0 ]
