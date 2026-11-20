#!/usr/bin/env bash
# Issue #150: refuse bare /oc (no instruction) at run start and classify agent refusal clearly.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "FAIL  PyYAML not installed"
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
STD="tests/run-start/spec-approved-simple-normal.md"
PY=(python3 scripts/factory-run-start.py)

passed=0
failed=0
ok() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }

# --- run start refuses before routing (no spec read required for empty instruction). ---
for body in '/oc' '/oc   ' $'/oc\t'; do
  : >"$tmpdir/gh.txt"
  set +e
  env OC_INSTRUCTION="$body" "${PY[@]}" --kind build --spec "$STD" --issue 91 \
    --runs-dir "$tmpdir/none" --github-output "$tmpdir/gh.txt" >/dev/null 2>"$tmpdir/err.txt"
  rc=$?
  set -e
  if [ "$rc" -eq 3 ] && grep -qx "refused=empty_instruction" "$tmpdir/gh.txt" \
    && ! grep -q '^model' "$tmpdir/gh.txt" \
    && grep -q 'empty instruction after /oc' "$tmpdir/err.txt"; then
    ok "run-start: OC_INSTRUCTION=$(printf %q "$body") -> refused=empty_instruction"
  else
    bad "run-start empty body $(printf %q "$body") (rc=$rc)"
  fi
done

# --- normal /oc instructions still route. ---
for body in '/oc run' '/oc implement the spec' '/oc fix docs'; do
  set +e
  out="$(env OC_INSTRUCTION="$body" "${PY[@]}" --kind build --spec "$STD" --issue 91 --runs-dir "$tmpdir/none2")"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q '^model=deepinfra/' <<<"$out"; then
    ok "run-start: OC_INSTRUCTION=$(printf %q "$body") still routes"
  else
    bad "run-start non-empty $(printf %q "$body") (rc=$rc)"
  fi
done

# --- /oc spec is not stripped as empty (workflow does not trigger build on it; agent guard unchanged). ---
repo="$(git rev-parse --show-toplevel)"
set +e
out="$(cd "$repo" && mkdir -p "$tmpdir/spec-art" && OC_INSTRUCTION='/oc spec' OC_ISSUE_NUMBER=7 OC_ARTIFACT_DIR="$tmpdir/spec-art" \
  bash scripts/opencode-agent-run.sh --print-prompt 2>&1)"
r=$?
set -e
if [ "$r" -ne 0 ] && grep -q 'opencode-spec workflow' <<<"$out"; then
  ok "agent-run: '/oc spec' still refused as spec workflow (not empty_instruction)"
else
  bad "agent-run /oc spec guard (r=$r)"
fi

# --- agent-run: bare /oc writes reason file; classify -> empty_instruction. ---
art="$tmpdir/art-build"
mkdir -p "$art"
touch "$art/issue-context.md"
printf 'spec_comment_id=none\n' >"$art/context-meta.txt"
set +e
(cd "$(git rev-parse --show-toplevel)" && OC_INSTRUCTION='/oc' OC_ISSUE_NUMBER=7 OC_ARTIFACT_DIR="$art" \
  bash scripts/opencode-agent-run.sh --print-prompt) >/dev/null 2>"$tmpdir/agent.err"
r=$?
set -e
if [ "$r" -ne 0 ] && [ "$(cat "$art/agent-failure-reason.txt")" = empty_instruction ] \
  && [ "$(python3 scripts/factory-classify-failure.py --log "$tmpdir/missing.log")" = "error_class=other" ]; then
  : # missing log alone is other
fi
touch "$art/opencode.log"
printf 'empty_instruction\n' >"$art/agent-failure-reason.txt"
if [ "$(python3 scripts/factory-classify-failure.py --log "$art/opencode.log")" = "error_class=empty_instruction" ]; then
  ok "classify-failure: agent-failure-reason.txt -> empty_instruction"
else
  bad "classify-failure with reason file"
fi

if [ "$r" -ne 0 ] && grep -q 'empty instruction after /oc' "$tmpdir/agent.err"; then
  ok "agent-run: bare /oc refused with reason file"
else
  bad "agent-run bare /oc (r=$r)"
fi

# --- notify: refused empty_instruction at run start (no DeepInfra spend line). ---
mkdir -p "$tmpdir/nbin"
cat >"$tmpdir/nbin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$2" = --paginate ]; then echo '[]'; exit 0; fi
while [ $# -gt 0 ]; do [ "$1" = --input ] && cp "$2" "${FAKE_POST:?}"; shift; done
GH
chmod +x "$tmpdir/nbin/gh"
env PATH="$tmpdir/nbin:$PATH" FAKE_POST="$tmpdir/post.json" GH_TOKEN=x GITHUB_REPOSITORY=o/r \
  OC_KIND=build OC_TARGET_NUMBER=91 OC_RUN_ID=150 OC_RUN_ATTEMPT=1 \
  OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped OC_REFUSED=empty_instruction \
  bash scripts/opencode-notify-failure.sh >/dev/null 2>&1
if grep -qF '(refused: `empty_instruction`)' "$tmpdir/post.json" \
  && grep -q 'No DeepInfra spend' "$tmpdir/post.json" \
  && ! grep -q 'spend may still have happened' "$tmpdir/post.json" \
  && grep -q 'implement the approved spec' "$tmpdir/post.json"; then
  ok "notify: empty_instruction refusal is clear and claims no DeepInfra spend"
else
  bad "notify refusal empty_instruction"
  cat "$tmpdir/post.json"
fi

# --- notify: agent path with error_class empty_instruction. ---
env PATH="$tmpdir/nbin:$PATH" FAKE_POST="$tmpdir/post2.json" GH_TOKEN=x GITHUB_REPOSITORY=o/r \
  OC_KIND=build OC_TARGET_NUMBER=91 OC_RUN_ID=151 OC_RUN_ATTEMPT=1 \
  OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped \
  OC_ERROR_CLASS=empty_instruction OC_MODEL_ID=deepseek-ai/DeepSeek-V4-Flash-0731 OC_ROUTED_RULE=3 \
  bash scripts/opencode-notify-failure.sh >/dev/null 2>&1
if grep -q 'failure class: `empty_instruction`' "$tmpdir/post2.json" \
  && grep -q 'No DeepInfra spend' "$tmpdir/post2.json" \
  && ! grep -q 'spend may still have happened' "$tmpdir/post2.json"; then
  ok "notify: empty_instruction error class names the reason and no-spend"
else
  bad "notify error_class empty_instruction"
  cat "$tmpdir/post2.json"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]