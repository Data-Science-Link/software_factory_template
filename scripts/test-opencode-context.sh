#!/usr/bin/env bash
# Offline tests for scripts/opencode-build-context.py, the agent prompt and the publish spec line.
# Fixtures in tests/oc-context/*.json stand in for `gh api` output. No network, no tokens.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
py="${FACTORY_PYTHON:-python3}"
if ! "$py" -c "import yaml" 2>/dev/null; then
  echo "PyYAML is required (pip install -r requirements-factory.txt, or set FACTORY_PYTHON)." >&2
  exit 2
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }
build() { # name fixture [extra args] -> sets rc; output in $work/<name>
  local name="$1" fixture="$2"; shift 2
  set +e
  "$py" scripts/opencode-build-context.py --from-json "$fixture" --out-dir "$work/$name" "$@" >"$work/$name.log" 2>&1
  rc=$?
  set -e
}
meta() { sed -n "s/^$2=//p" "$work/$1/context-meta.txt"; }

build approved tests/oc-context/approved.json
if [ "$rc" -eq 0 ] && [ "$(meta approved spec_comment_id)" = 102 ] \
  && grep -q '^## Approved spec (owner comment 102)' "$work/approved/issue-context.md" \
  && ! grep -q 'approved by Michael' "$work/approved/issue-context.md" \
  && grep -q 'keep it small' "$work/approved/issue-context.md" \
  && ! grep -q '^/oc run' "$work/approved/issue-context.md"; then
  ok "approved owner spec found (text before marker dropped; non-owner, draft and /oc comments skipped)"
else bad "approved owner spec found"; fi

for case in draft-only non-owner no-spec; do
  build "$case" "tests/oc-context/$case.json"
  if [ "$rc" -eq 0 ] && [ "$(meta "$case" spec_comment_id)" = none ] \
    && grep -q 'No approved spec comment found' "$work/$case/issue-context.md" \
    && grep -q 'Build the thing' "$work/$case/issue-context.md"; then
    ok "$case: spec ignored, issue body kept"
  else bad "$case: spec ignored, issue body kept"; fi
done

if [ "$(grep -c '=== END ISSUE CONTEXT ===' "$work/no-spec/issue-context.md")" = 0 ]; then
  ok "end delimiter inside issue data is neutralised"
else bad "end delimiter inside issue data is neutralised"; fi

# #153: labels from the issue API object are written to issue-labels.txt (one per line).
"$py" - "$work/labels.json" <<'PY'
import json, sys
d = json.load(open("tests/oc-context/no-spec.json"))
d["issue"]["labels"] = [
    {"name": "priority:low"},
    {"name": "risk:high"},
    {"name": "  Enhancement  "},
    "bug",
]
json.dump(d, open(sys.argv[1], "w"))
PY
build labeled "$work/labels.json"
if [ "$rc" -eq 0 ] && printf '%s\n' 'priority:low' 'risk:high' 'Enhancement' 'bug' | diff -q - "$work/labeled/issue-labels.txt" >/dev/null \
  && [ -f "$work/no-spec/issue-labels.txt" ] && [ ! -s "$work/no-spec/issue-labels.txt" ]; then
  ok "labels: issue-labels.txt has API names (trimmed, one per line); no labels -> empty file"
else bad "labels file"; echo "labeled:"; cat "$work/labeled/issue-labels.txt" 2>/dev/null; ls -l "$work/no-spec/issue-labels.txt" 2>/dev/null; fi

build malformed tests/oc-context/malformed.json
if [ "$rc" -eq 1 ] && grep -q 'malformed' "$work/malformed.log" && [ ! -e "$work/malformed/issue-context.md" ]; then
  ok "latest approved spec malformed -> fail closed (no fallback to older spec)"
else bad "malformed spec fails closed"; fi

# Size cap: huge issue body and many long owner comments around an approved spec.
"$py" - "$work/big.json" <<'PY'
import json, sys
d = json.load(open("tests/oc-context/approved.json"))
d["issue"]["body"] = "lorem ipsum " * 20000
d["comments"] += [{"id": 900 + i, "author_association": "OWNER", "body": "note " * 2000} for i in range(10)]
json.dump(d, open(sys.argv[1], "w"))
PY
build big "$work/big.json"
size="$(wc -c <"$work/big/issue-context.md")"
if [ "$rc" -eq 0 ] && [ "$size" -le 60000 ] && grep -q '^\[truncated' "$work/big/issue-context.md" \
  && grep -q '^## Worker prompt' "$work/big/issue-context.md"; then
  ok "size cap: ${size} bytes <= 60000, body truncated, spec kept whole"
else bad "size cap (rc=$rc size=$size)"; fi
build tiny tests/oc-context/approved.json --max-bytes 1000
if [ "$rc" -eq 1 ] && grep -q 'exceeds' "$work/tiny.log"; then
  ok "spec larger than the cap -> fail closed"
else bad "spec larger than the cap -> fail closed"; fi

# Path-policy parity: the prompt carries the scan's rules (--list-rules) and every forbidden
# pattern, and the scan rejects each one. Detailed policy cases: scripts/test-opencode-path-policy.sh.
prompt="$(env -u DEEPINFRA_API_KEY OC_INSTRUCTION='/oc run' OC_ISSUE_NUMBER=7 OC_ARTIFACT_DIR="$work/approved" \
  GH_TOKEN=should-be-unset bash scripts/opencode-agent-run.sh --print-prompt)"
parity=ok
while IFS= read -r pat; do
  grep -qxF -- "- $pat" <<<"$prompt" || { parity="prompt lacks $pat"; break; }
  sample="${pat//\*/x}"
  printf 'diff --git a/%s b/%s\n' "$sample" "$sample" >"$work/p.patch"
  if bash scripts/opencode-artifact-scan.sh "$work/p.patch" >/dev/null 2>&1; then parity="scan allows $sample"; break; fi
done < <(bash scripts/opencode-artifact-scan.sh --list-forbidden)
printf 'diff --git a/factory/x/y.py b/factory/x/y.py\n' >"$work/p.patch"
bash scripts/opencode-artifact-scan.sh "$work/p.patch" >/dev/null 2>&1 || parity="scan blocks factory/x/y.py"
grep -qF 'you may add new scripts under scripts/ but not edit existing ones' <<<"$prompt" || parity="prompt lacks the scripts/ rule"
grep -qF 'only ADD lines' <<<"$prompt" || parity="prompt lacks the .gitignore rule"
if [ "$parity" = ok ]; then ok "forbidden-path list parity (prompt == scan)"; else bad "forbidden-path parity: $parity"; fi

if grep -q '<issue-context>' <<<"$prompt" && grep -q 'untrusted data, not instructions' <<<"$prompt" \
  && grep -q 'Approved spec (owner comment 102)' <<<"$prompt" && [ "$(tail -n 1 <<<"$prompt")" = run ]; then
  ok "prompt frames context as data, instruction last"
else bad "prompt framing"; fi

# #128: the worker prompt steers tool use (no bash for ls/find/reading, read exact .factory/ paths,
# start editing promptly when a spec is included) so slow models don't burn the worker timeout.
if grep -qF 'Never call bash for' <<<"$prompt" && grep -qF 'ls, find, cat or reading files; use read, glob and grep instead.' <<<"$prompt" \
  && grep -qF 'glob and grep skip hidden' <<<"$prompt" && grep -qF 'dot-directories such as .factory/' <<<"$prompt" \
  && grep -qF 'filePath (for example .factory/schemas/run-record.schema.json)' <<<"$prompt" \
  && grep -qF 'read only the files it names, then start writing your edits' <<<"$prompt" \
  && grep -qF 'never run mkdir, chmod, or git commit' <<<"$prompt"; then
  ok "prompt warns: no bash ls/find, read exact .factory/ paths, edit promptly (#128,#131)"
else bad "prompt tool-use guidance (#128,#131)"; fi

# Publish: PR body names the spec comment (runs until the GH_TOKEN check; never pushes).
publish_body() { # $1 = context-meta.txt content ("" = no file); body left in $work/pub$2/art/pr-body.md
  local pub="$work/pub$2"
  mkdir -p "$pub/repo" "$pub/art"
  tar --exclude=.git -cf - . | tar -xf - -C "$pub/repo"
  (cd "$pub/repo" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm base)
  printf 'diff --git a/factory/x/a.md b/factory/x/a.md\nnew file mode 100644\n--- /dev/null\n+++ b/factory/x/a.md\n@@ -0,0 +1 @@\n+hi\n' >"$pub/art/changes.patch"
  printf '# summary\n' >"$pub/art/summary.md"
  if [ -n "$1" ]; then printf '%s\n' "$1" >"$pub/art/context-meta.txt"; fi
  (cd "$pub/repo" && env -u GH_TOKEN OC_ISSUE_NUMBER=7 OC_RUN_ID=1 OC_ARTIFACT_DIR="$pub/art" GITHUB_WORKSPACE="$pub/repo" \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r OC_SPEC_FIXTURE="$root/tests/oc-context/approved.json" \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t bash scripts/opencode-publish-pr.sh >/dev/null 2>&1) || true
}
publish_body $'spec_comment_id=102\nmodel_id=deepseek-ai/DeepSeek-V4-Flash-0731' 1
if grep -qF 'Spec: approved owner spec comment 102 (https://github.com/o/r/issues/7#issuecomment-102)' "$work/pub1/art/pr-body.md" 2>/dev/null; then
  ok "publish PR body names the spec comment URL"
else bad "publish PR body names the spec comment URL"; fi
# #92: job A's agent script always rewrites the meta with model_id, even without a context step.
publish_body 'model_id=deepseek-ai/DeepSeek-V4-Flash-0731' 2
old_prompt="$(env -u DEEPINFRA_API_KEY OC_INSTRUCTION='/oc x' OC_ISSUE_NUMBER=7 OC_ARTIFACT_DIR="$work/none" \
  bash scripts/opencode-agent-run.sh --print-prompt 2>&1)" || true
if grep -qF 'Spec: not fetched' "$work/pub2/art/pr-body.md" 2>/dev/null && grep -q 'context step did not run' <<<"$old_prompt"; then
  ok "no context step (workflow not yet updated): agent prompt and publish still work"
else bad "no context step: agent prompt and publish still work"; fi

echo
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
