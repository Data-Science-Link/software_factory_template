#!/usr/bin/env bash
# Offline tests for #75/#76/#80: the harness writes the spec file, runs the spec's Verification
# commands in a sandbox (scripts/opencode-verify.sh), and publish pastes the worker note and the
# evidence as fenced, defanged blocks. Runs the REAL sequence with a fake `opencode` binary:
# build-context -> agent-run (worker tampers with the spec) -> publish-pr (body + pr-check), and
# build-fix-context -> agent-fix -> verification on the PR head. No network, no tokens.
# The separate-user sandbox case runs only where `sudo -n` works (skipped otherwise).
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
FAKE_KEY="fake-deepinfra-key-$RANDOM$RANDOM"

# --- fixtures: approved spec with a bash Verification block (and a CRLF copy of the comment)
"$py" - "$work" <<'PY'
import json, sys
w = sys.argv[1]
d = json.load(open("tests/oc-context/approved.json"))
for c in d["comments"]:
    if c["id"] == 102:
        c["body"] = c["body"].replace(
            "## Verification\nx\n",
            "## Verification\nRun from the repo root.\n```bash\ncat factory/x/hello.md\n"
            "echo \"key=${DEEPINFRA_API_KEY:-unset} gh=${GH_TOKEN:-unset}\"\n"
            "git diff --name-only HEAD~1\n```\n")
json.dump(d, open(f"{w}/spec-fixture.json", "w"))
for c in d["comments"]:
    if c["id"] == 102:
        c["body"] = c["body"].replace("\n", "\r\n")
json.dump(d, open(f"{w}/spec-fixture-crlf.json", "w"))
PY

# --- build-context: spec.md is the exact comment text from the marker on; --print-spec agrees
"$py" scripts/opencode-build-context.py --from-json "$work/spec-fixture.json" --out-dir "$work/ctx" >/dev/null
"$py" scripts/opencode-build-context.py --from-json "$work/spec-fixture-crlf.json" --out-dir "$work/ctx-crlf" >/dev/null
"$py" scripts/opencode-build-context.py --from-json "$work/spec-fixture.json" --print-spec 102 >"$work/printed.md"
sha="$(sed -n 's/^spec_sha256=//p' "$work/ctx/context-meta.txt")"
if [ "$(head -n 1 "$work/ctx/spec.md")" = '<!-- factory-spec v1 -->' ] && ! grep -q 'approved by Michael' "$work/ctx/spec.md" \
  && cmp -s "$work/ctx/spec.md" "$work/printed.md" && cmp -s "$work/ctx/spec.md" "$work/ctx-crlf/spec.md" \
  && [ "$(sha256sum <"$work/ctx/spec.md" | cut -d' ' -f1)" = "$sha" ] \
  && python3 scripts/factory-spec-check.py "$work/ctx/spec.md"; then
  ok "build-context: spec.md exact (marker on, CRLF normalised), sha in meta, --print-spec identical, spec-check passes"
else bad "build-context: spec.md exact copy"; fi
set +e
"$py" scripts/opencode-build-context.py --from-json "$work/spec-fixture.json" --print-spec 103 >/dev/null 2>&1; r1=$?
"$py" scripts/opencode-build-context.py --from-json "$work/spec-fixture.json" --print-spec 101 >/dev/null 2>&1; r2=$?
set -e
if [ "$r1" -ne 0 ] && [ "$r2" -ne 0 ]; then ok "--print-spec refuses a non-owner spec and a non-spec owner comment"
else bad "--print-spec refusals ($r1 $r2)"; fi

# --- text-block: fence can't be closed or used to ping; long text is cut in the middle
printf 'line1\n```\n@michael <!-- x -->\n' >"$work/t.txt"
out="$(bash scripts/opencode-text-block.sh fence "$work/t.txt" 1000 none)"
if [ "$(grep -c '^```' <<<"$out")" = 2 ] && grep -q '(at)michael' <<<"$out" && ! grep -q '<!--' <<<"$out" \
  && [ "$(head -n 1 <<<"$out")" = '```text' ] && [ "$(tail -n 1 <<<"$out")" = '```' ]; then
  ok "text-block fence: one block, inner fence/mention/comment defanged"
else bad "text-block fence"; echo "$out"; fi
seq 1 5000 >"$work/big.txt"
out="$(bash scripts/opencode-text-block.sh fence "$work/big.txt" 2000 none)"
if [ "$(printf '%s' "$out" | wc -c)" -lt 2200 ] && grep -q 'bytes cut' <<<"$out" && grep -qx 5000 <<<"$out" && grep -qx 1 <<<"$out"; then
  ok "text-block fence: capped with head and tail kept"
else bad "text-block cap"; fi
out="$(bash scripts/opencode-text-block.sh fence "$work/missing" 100 "(nothing here)")"
if grep -qx '(nothing here)' <<<"$out"; then ok "text-block fence: missing file -> empty message"; else bad "text-block empty"; fi

# --- verify: unit cases
mkrepo() { rm -rf "$1"; git init -q "$1"; mkdir -p "$1/factory/x"; echo base >"$1/factory/x/base.md"; git -C "$1" add -A; git -C "$1" commit -qm base; }
mkrepo "$work/vb"
(cd "$work/vb" && echo hello >factory/x/hello.md && git add -N factory/x/hello.md && git diff >"$work/v.patch" && git rm -q --cached factory/x/hello.md && rm factory/x/hello.md)
vrun() { # name spec [extra env...]
  local name="$1" spec="$2"; shift 2
  env "$@" DEEPINFRA_API_KEY="$FAKE_KEY" GH_TOKEN=fake-gh OC_VERIFY_SANDBOX=none \
    bash scripts/opencode-verify.sh --spec "$spec" --base "$work/vb" --patch "$work/v.patch" --out "$work/$name.md" --timeout 60 >"$work/$name.log" 2>&1
}
vrun v1 "$work/ctx/spec.md"
if grep -q '^+ cat factory/x/hello.md' "$work/v1.md" && grep -qx hello "$work/v1.md" && grep -qx 'key=unset gh=unset' "$work/v1.md" \
  && grep -qx 'factory/x/hello.md' "$work/v1.md" && grep -q 'not by the model' "$work/v1.md" && grep -q 'PASS: every command exited 0' "$work/v1.md" && grep -q '(none failed)' "$work/v1.md" \
  && ! grep -qF "$FAKE_KEY" "$work/v1.md"; then
  ok "verify: runs the spec block on base + patch, empty environment (key and token unset)"
else bad "verify: basic run"; cat "$work/v1.md"; fi
# #100: a failing command in the middle is a FAIL even if the last command exits 0.
# shellcheck disable=SC2016 # backticks are literal markdown
mkspec() { printf '## Verification\n```bash\n%s\n```\n' "$1" >"$work/$2"; }
mkspec $'false\necho after' mid.md; vrun v100a "$work/mid.md"
if grep -q 'FAIL: 1 command(s) exited non-zero' "$work/v100a.md" && grep -q 'FAILED line 1: exit 1: false' "$work/v100a.md" && grep -qx after "$work/v100a.md"; then
  ok "verify: middle command fails, last passes -> FAIL, the failing command listed, later commands still ran"
else bad "verify: middle failure"; cat "$work/v100a.md"; fi
mkspec $'ls no-such-file\ntrue\nsh -c "exit 3"\necho done' two.md; vrun v100b "$work/two.md"
if grep -q 'FAIL: 2 command(s)' "$work/v100b.md" && grep -q 'FAILED line 1: exit 2: ls no-such-file' "$work/v100b.md" && grep -q 'FAILED line 3: exit 3' "$work/v100b.md"; then
  ok "verify: every failing command reported with its line and exit code"
else bad "verify: two failures"; cat "$work/v100b.md"; fi
mkspec $'false | cat\necho ok' pipe.md; vrun v100c "$work/pipe.md"
if grep -q 'FAIL: 1 command' "$work/v100c.md"; then ok "verify: a failing pipeline stage counts (pipefail)"; else bad "verify: pipefail"; cat "$work/v100c.md"; fi
mkspec $'if false; then echo no; fi\ntest -f nope || echo fallback\ncd factory/x\nls base.md' cond.md; vrun v100d "$work/cond.md"
if grep -q 'PASS: every command exited 0' "$work/v100d.md" && grep -qx base.md "$work/v100d.md"; then
  ok "verify: tested conditions are not failures; cd carries over between commands"
else bad "verify: conditions"; cat "$work/v100d.md"; fi
mkspec $'f() { false; echo in-f; }\nf\nexit 0' func.md; vrun v100e "$work/func.md"
if grep -q 'FAIL: 1 command' "$work/v100e.md"; then ok "verify: failure inside a function counts; exit 0 cannot hide it"; else bad "verify: function/exit 0"; cat "$work/v100e.md"; fi
mkspec $'echo x\nexit 4' ex.md; vrun v100f "$work/ex.md"
if grep -q 'FAIL: block exited 4' "$work/v100f.md"; then ok "verify: explicit non-zero exit is a FAIL"; else bad "verify: exit 4"; cat "$work/v100f.md"; fi
printf '## Verification\nNo commands.\n## Classification\n' >"$work/nob.md"
vrun v2 "$work/nob.md"
if grep -q 'not run (the spec' "$work/v2.md"; then ok "verify: no bash block -> 'not run' evidence"; else bad "verify: no block"; fi
vrun v3 ""
if grep -q 'not run (no approved spec' "$work/v3.md"; then ok "verify: no spec -> 'not run' evidence"; else bad "verify: no spec"; fi
# shellcheck disable=SC2016 # literal spec text
printf '## Verification\n```bash\necho before\nsleep 20\necho after\n```\n' >"$work/slow.md"
env DEEPINFRA_API_KEY=x OC_VERIFY_SANDBOX=none OC_VERIFY_MIN_TIMEOUT=1 bash scripts/opencode-verify.sh \
  --spec "$work/slow.md" --base "$work/vb" --out "$work/v4.md" --timeout 2 >/dev/null 2>&1
if grep -q 'timed out after 2s' "$work/v4.md" && grep -qx before "$work/v4.md" && ! grep -qx after "$work/v4.md"; then
  ok "verify: timeout stops the commands and says so"
else bad "verify: timeout"; cat "$work/v4.md"; fi
printf 'diff --git a/nope.md b/nope.md\n--- a/nope.md\n+++ b/nope.md\n@@ -1 +1 @@\n-a\n+b\n' >"$work/bad.patch"
env OC_VERIFY_SANDBOX=none bash scripts/opencode-verify.sh --spec "$work/ctx/spec.md" --base "$work/vb" --patch "$work/bad.patch" \
  --out "$work/v5.md" --timeout 60 >/dev/null 2>&1
if grep -q 'patch does not apply' "$work/v5.md"; then ok "verify: patch that does not apply -> 'not run'"; else bad "verify: bad patch"; fi
set +e
env GITHUB_ACTIONS=true OC_VERIFY_SANDBOX=none bash scripts/opencode-verify.sh --spec "$work/ctx/spec.md" --base "$work/vb" --out "$work/v6.md" >/dev/null 2>&1
r=$?
set -e
if [ "$r" -ne 0 ] && [ ! -e "$work/v6.md" ]; then ok "verify: sandbox=none refused under GitHub Actions"; else bad "verify: none refused in Actions"; fi
if sudo -n true 2>/dev/null; then
  # shellcheck disable=SC2016 # literal spec text
  printf '## Verification\n```bash\nwhoami\nfor p in $(pgrep -u %s); do tr "\\0" "\\n" </proc/$p/environ 2>/dev/null; done | grep -c FAKE_PARENT_SECRET || true\n```\n' "$(id -un)" >"$work/proc.md"
  # RUNNER_TEMP in a directory the sandbox user can't traverse, like /home/runner/work/_temp on
  # GitHub runners (live run 41553660354); the scratch copy must not go there.
  mkdir -p "$work/runner-home/_temp"; chmod 700 "$work/runner-home"
  RUNNER_TEMP="$work/runner-home/_temp" FAKE_PARENT_SECRET="$FAKE_KEY" bash scripts/opencode-verify.sh --spec "$work/proc.md" --base "$work/vb" --out "$work/v7.md" --timeout 60 >/dev/null 2>&1
  if grep -qx ocverify "$work/v7.md" && grep -qx 0 "$work/v7.md" && ! grep -qF "$FAKE_KEY" "$work/v7.md"; then
    ok "verify (sudo): separate user, parent processes' environment unreadable, RUNNER_TEMP not traversable"
  else bad "verify (sudo): sandbox user"; cat "$work/v7.md"; fi
  # #108: per-command status must be read back from the sandbox user's scratch copy.
  # shellcheck disable=SC2016 # literal markdown backticks
  printf '## Verification\n```bash\nfalse\necho after\n```\n' >"$work/mid-sudo.md"
  bash scripts/opencode-verify.sh --spec "$work/mid-sudo.md" --base "$work/vb" --out "$work/v108.md" --timeout 60 >/dev/null 2>&1
  if grep -q 'FAIL: 1 command(s) exited non-zero' "$work/v108.md" && grep -q 'FAILED line 1: exit 1: false' "$work/v108.md"; then
    ok "verify (sudo): a failing command in the sandbox user's run is reported FAIL (#108)"
  else bad "verify (sudo): status readback"; cat "$work/v108.md"; fi
  # shellcheck disable=SC2016 # literal markdown backticks
  printf '## Verification\n```bash\necho ok\n```\n' >"$work/ok-sudo.md"
  bash scripts/opencode-verify.sh --spec "$work/ok-sudo.md" --base "$work/vb" --out "$work/v108b.md" --timeout 60 >/dev/null 2>&1
  if grep -q 'PASS: every command exited 0' "$work/v108b.md"; then ok "verify (sudo): clean block still PASS"; else bad "verify (sudo): clean PASS"; cat "$work/v108b.md"; fi
else
  echo "SKIP  verify (sudo): separate-user sandbox (no passwordless sudo here)"
fi

# --- real sequence: agent-run with a fake opencode that tampers with the spec and writes a note
repo="$work/repo"
mkdir -p "$repo"
git ls-files -co --exclude-standard | tar -T - -cf - | tar -xf - -C "$repo"
(cd "$repo" && git init -q && git add -A && git commit -qm base)
mkdir -p "$work/bin"
cat >"$work/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
# Fake worker: edits the spec (must be undone), adds a file, ends with a labeled note.
if [ "$1" = stats ]; then cat "$FAKE_STATS"; exit 0; fi
[ -f factory/specs/issue-7.md ] || { echo "spec file not pre-written"; exit 1; }
sed -i 's/^title: .*/title: \\"tampered\\"/' factory/specs/issue-7.md
echo '## Recent owner comments (0)' >>factory/specs/issue-7.md
mkdir -p factory/x && echo hello >factory/x/hello.md
printf 'working...\n## What I changed and why\n- Added factory/x/hello.md @someone\n- ```oops\n'
FAKE
chmod +x "$work/bin/opencode"
art="$work/art"
mkdir -p "$art"
cp "$work/ctx/"* "$art/"
set +e
(cd "$repo" && PATH="$work/bin:$PATH" FAKE_STATS="$root/tests/opencode-capture-usage/stats-normal.txt" \
  OC_INSTRUCTION='/oc run' OC_ISSUE_NUMBER=7 OC_ARTIFACT_DIR="$art" DEEPINFRA_API_KEY="$FAKE_KEY" \
  GH_TOKEN=should-be-unset OC_VERIFY_SANDBOX=none bash scripts/opencode-agent-run.sh) >"$work/agent.log" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then ok "agent-run (fake opencode): completed"; else bad "agent-run (fake opencode) rc=$rc"; cat "$work/agent.log"; fi
spec_in_patch="$(cd "$work" && rm -rf chk && git init -q chk && cd chk && git apply "$art/changes.patch" && cat factory/specs/issue-7.md)" || true
if [ "$spec_in_patch" = "$(cat "$work/ctx/spec.md")" ] && grep -q 'restored the exact approved copy' "$art/summary.md" \
  && grep -q '^+++ b/factory/x/hello.md' "$art/changes.patch"; then
  ok "agent-run: worker's spec edits overwritten; patch carries the exact approved spec + the work"
else bad "agent-run: spec restore"; grep -A3 'Spec file' "$art/summary.md" || true; fi
if grep -q 'Added factory/x/hello.md' "$art/worker-note.md" && grep -qx 'hello' "$art/evidence.md" \
  && grep -qx 'key=unset gh=unset' "$art/evidence.md" && ! grep -rqF "$FAKE_KEY" "$art"; then
  ok "agent-run: note extracted; evidence from the harness run, no key in any artifact"
else bad "agent-run: note/evidence"; cat "$art/evidence.md" 2>/dev/null || true; fi
prompt="$(cd "$repo" && env -u DEEPINFRA_API_KEY OC_INSTRUCTION='/oc run' OC_ISSUE_NUMBER=7 OC_ARTIFACT_DIR="$art" bash scripts/opencode-agent-run.sh --print-prompt)"
if grep -q 'Do not create, edit, copy or delete that file' <<<"$prompt" && grep -q 'harness runs them itself' <<<"$prompt" \
  && grep -q '"## What I changed and why"' <<<"$prompt"; then ok "agent-run prompt: spec is harness-owned; verification by harness; labeled note asked"
else bad "agent-run prompt"; fi

# Worker that only touches the spec: nothing to publish.
cat >"$work/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = stats ]; then exit 0; fi
echo 'x' >>factory/specs/issue-7.md
FAKE
art2="$work/art2"; mkdir -p "$art2"; cp "$work/ctx/"* "$art2/"
(cd "$repo" && git reset -q --hard && git clean -qfd)
set +e
(cd "$repo" && PATH="$work/bin:$PATH" OC_INSTRUCTION='/oc run' OC_ISSUE_NUMBER=7 OC_ARTIFACT_DIR="$art2" \
  DEEPINFRA_API_KEY="$FAKE_KEY" OC_VERIFY_SANDBOX=none bash scripts/opencode-agent-run.sh) >"$work/agent2.log" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q 'no changes produced' "$work/agent2.log"; then ok "agent-run: spec-only patch counts as no changes"
else bad "agent-run: spec-only patch (rc=$rc)"; fi

# Worker that hangs (#89): stopped at the time limit; log and patch are still written.
cat >"$work/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = stats ]; then exit 0; fi
mkdir -p factory/x && echo partial >factory/x/partial.md
echo "worker started"
exec sleep 300
FAKE
art3="$work/art3"; mkdir -p "$art3"; cp "$work/ctx/"* "$art3/"
(cd "$repo" && git reset -q --hard && git clean -qfd)
set +e
t0=$SECONDS
(cd "$repo" && PATH="$work/bin:$PATH" OC_INSTRUCTION='/oc run' OC_ISSUE_NUMBER=7 OC_ARTIFACT_DIR="$art3" \
  DEEPINFRA_API_KEY="$FAKE_KEY" OC_VERIFY_SANDBOX=none OC_WORKER_TIMEOUT=2 bash scripts/opencode-agent-run.sh) >"$work/agent3.log" 2>&1
rc=$?
set -e
if [ $((SECONDS - t0)) -lt 60 ] && grep -q 'worker stopped at the 2s limit' "$work/agent3.log" \
  && grep -q 'worker started' "$art3/opencode.log" && grep -q '^+++ b/factory/x/partial.md' "$art3/changes.patch"; then
  ok "agent-run: hung worker stopped at its time limit; log and partial patch kept (rc=$rc)"
else bad "agent-run: hung worker (rc=$rc)"; tail -5 "$work/agent3.log"; fi

# #101: new scripts with a shebang are staged 100755 in the patch; others stay 100644.
cat >"$work/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = stats ]; then exit 0; fi
printf '#!/usr/bin/env bash\necho tool\n' >scripts/new-tool-check.sh
printf '#!/usr/bin/env python3\nprint(1)\n' >scripts/new-tool-report.py
printf 'echo sourced only\n' >scripts/new-tool-lib.sh
mkdir -p factory/x && printf '#!/bin/sh\n' >factory/x/not-a-script.sh
FAKE
art101a="$work/art101a"; mkdir -p "$art101a"; cp "$work/ctx/"* "$art101a/"
(cd "$repo" && git reset -q --hard && git clean -qfd)
set +e
(cd "$repo" && PATH="$work/bin:$PATH" OC_INSTRUCTION='/oc run' OC_ISSUE_NUMBER=7 OC_ARTIFACT_DIR="$art101a" \
  DEEPINFRA_API_KEY="$FAKE_KEY" OC_VERIFY_SANDBOX=none bash scripts/opencode-agent-run.sh) >"$work/agent101.log" 2>&1
rc=$?
set -e
modes="$(cd "$work" && rm -rf chk101 && git init -q chk101 && cd chk101 && git apply --index "$art101a/changes.patch" && git ls-files -s scripts factory/x)" || true
if [ "$rc" -eq 0 ] && grep -q '^100755 .*scripts/new-tool-check.sh$' <<<"$modes" && grep -q '^100755 .*scripts/new-tool-report.py$' <<<"$modes" \
  && grep -q '^100644 .*scripts/new-tool-lib.sh$' <<<"$modes" && grep -q '^100644 .*factory/x/not-a-script.sh$' <<<"$modes"; then
  ok "agent-run: new scripts/ files with a shebang are 100755 in the patch; no-shebang and non-scripts/ stay 100644 (#101)"
else bad "agent-run: new script modes (rc=$rc)"; echo "$modes"; tail -5 "$work/agent101.log"; fi

# --- publish-pr on that artifact: exact spec checked against the comment; body sections
pub="$work/pub"
mkdir -p "$pub"
git ls-files -co --exclude-standard | tar -T - -cf - | tar -xf - -C "$pub"
(cd "$pub" && git init -q && git add -A && git commit -qm base)
base_branch="$(git -C "$pub" branch --show-current)"
publish() { # artifact-dir -> rc; body in <dir>/pr-body.md
  set +e
  git -C "$pub" checkout -qf "$base_branch"; git -C "$pub" clean -fdq; git -C "$pub" branch -D oc/issue-7-555 >/dev/null 2>&1
  (cd "$pub" && \
    env -u GH_TOKEN OC_ISSUE_NUMBER=7 OC_RUN_ID=555 OC_ARTIFACT_DIR="$1" GITHUB_WORKSPACE="$pub" \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r OC_SPEC_FIXTURE="$work/spec-fixture.json" \
    bash scripts/opencode-publish-pr.sh) >"$1.publish.log" 2>&1
  rc=$?
  set -e
}
publish "$art"
# #101 belt: an older artifact whose patch adds a shebang script as 100644 is committed as 100755.
art101b="$work/art101b"; rm -rf "$art101b"; cp -r "$art" "$art101b"
printf 'diff --git a/scripts/late-tool-check.sh b/scripts/late-tool-check.sh\nnew file mode 100644\n--- /dev/null\n+++ b/scripts/late-tool-check.sh\n@@ -0,0 +1,2 @@\n+#!/usr/bin/env bash\n+echo late\n' >>"$art101b/changes.patch"
publish "$art101b"
if [ "$(git -C "$pub" ls-files -s scripts/late-tool-check.sh | cut -d' ' -f1)" = 100755 ] && grep -q 'staged new script scripts/late-tool-check.sh as executable' "$art101b.publish.log"; then
  ok "publish: new shebang script from a 100644 patch is committed executable (#101)"
else bad "publish: #101 belt"; tail -8 "$art101b.publish.log"; fi
publish "$art"
body="$art/pr-body.md"
if grep -q 'GH_TOKEN is required' "$art.publish.log" && grep -q 'PR check: passed' "$art.publish.log"; then
  ok "publish: body passes pr-check; stops only at the push step"
else bad "publish: pr-check / stop point"; tail -20 "$art.publish.log"; fi
if grep -qx -- '- \[x\] trivial' "$body" && grep -qx -- '- \[ \] \*\*high\*\*' "$body" && grep -qx -- '- \[ \] normal' "$body" \
  && grep -q '^Gate: risk trivial' "$body" && grep -q 'risk class \*\*trivial\*\* (spec front matter)' "$body"; then
  ok "publish: Risk class box and Gate line both from the spec front matter"
else bad "publish: risk box / gate"; grep -n 'trivial\|high\|Gate' "$body" || true; fi
note_sec="$(sed -n '/^## What I changed and why/,/^## Safety checklist/p' "$body")"
if grep -q 'model-written, unverified' <<<"$note_sec" && grep -q 'Added factory/x/hello.md (at)someone' <<<"$note_sec" \
  && [ "$(grep -c '^```' <<<"$note_sec")" = 2 ]; then ok "publish: worker note under 'What I changed and why', labeled, fenced, defanged"
else bad "publish: note section"; echo "$note_sec"; fi
ev_sec="$(sed -n '/^## Evidence/,/^## Notes for reviewers/p' "$body")"
if grep -q 'not by the model' <<<"$ev_sec" && grep -qx 'key=unset gh=unset' <<<"$ev_sec" && grep -q '^Run ID: 555' <<<"$ev_sec" \
  && [ "$(grep -c '^```' <<<"$ev_sec")" = 2 ] && grep -q 'exact copy of spec comment 102, checked by publish' "$body" \
  && grep -q 'Approve workflows to run' "$body"; then
  ok "publish: Evidence has run facts + fenced harness output; spec file checked; #74 note"
else bad "publish: evidence section"; echo "$ev_sec"; fi

# Tampered artifact: the patch's spec file differs from the comment -> publish refuses.
art3="$work/art3"; cp -R "$art" "$art3"
sed -i 's/^+title: Simple fixture$/+title: Tampered/' "$art3/changes.patch"
publish "$art3"
if [ "$rc" -ne 0 ] && grep -q 'not the exact approved spec comment 102' "$art3.publish.log"; then
  ok "publish: patch with an edited spec file refused"
else bad "publish: tampered spec refused (rc=$rc)"; tail -5 "$art3.publish.log"; fi

# Live mode where the publish token can't read issue comments (live run 41553660354: the publish
# job has no issues: read, so `gh api .../issues/comments/<id>` returns HTTP 403).
mkdir -p "$work/fakegh"
cat >"$work/fakegh/gh" <<'GH'
#!/usr/bin/env bash
case "${FAKE_GH_MODE:-403}" in
  403) echo "gh: Resource not accessible by integration (HTTP 403)" >&2 ;;
  *) echo "gh: Not Found (HTTP 404)" >&2 ;;
esac
exit 1
GH
chmod +x "$work/fakegh/gh"
publish_live() { # artifact-dir mode -> rc
  set +e
  git -C "$pub" checkout -qf "$base_branch"; git -C "$pub" clean -fdq; git -C "$pub" branch -D oc/issue-7-555 >/dev/null 2>&1
  (cd "$pub" && \
    env -u GH_TOKEN -u OC_SPEC_FIXTURE PATH="$work/fakegh:$PATH" FAKE_GH_MODE="$2" OC_ISSUE_NUMBER=7 OC_RUN_ID=555 \
    OC_ARTIFACT_DIR="$1" GITHUB_WORKSPACE="$pub" GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r \
    bash scripts/opencode-publish-pr.sh) >"$1.publish.log" 2>&1
  rc=$?
  set -e
}
art4="$work/art4"; cp -R "$art" "$art4"; rm -f "$art4/pr-body.md"
publish_live "$art4" 403
if grep -q 'GH_TOKEN is required' "$art4.publish.log" && grep -q "checked by publish against job A's copy only" "$art4/pr-body.md"; then
  ok "publish: HTTP 403 on the spec comment -> job A's validated copy, labeled in the PR"
else bad "publish: 403 fallback (rc=$rc)"; tail -8 "$art4.publish.log"; fi
art5="$work/art5"; cp -R "$art" "$art5"
sed -i 's/^title: .*/title: Tampered copy/' "$art5/spec.md"
publish_live "$art5" 403
if [ "$rc" -ne 0 ] && grep -q 'cannot confirm the approved spec comment 102' "$art5.publish.log"; then
  ok "publish: 403 fallback refuses a job A spec copy that doesn't match its sha256"
else bad "publish: 403 fallback with tampered copy (rc=$rc)"; tail -5 "$art5.publish.log"; fi
art6="$work/art6"; cp -R "$art" "$art6"
publish_live "$art6" 404
if [ "$rc" -ne 0 ] && grep -q 'cannot fetch spec comment 102' "$art6.publish.log"; then
  ok "publish: spec comment gone (HTTP 404) -> refused, no fallback"
else bad "publish: 404 refused (rc=$rc)"; tail -5 "$art6.publish.log"; fi

# --- fix flow: agent-fix restores the spec on the PR head and verifies the fixed branch
prdir="$work/prhead"
mkdir -p "$prdir"
git ls-files -co --exclude-standard | tar -T - -cf - | tar -xf - -C "$prdir"
mkdir -p "$prdir/factory/specs" "$prdir/factory/x"
sed 's/^approved_at: .*/approved_at: \\"2026-11-02T12:00:00Z\\"/' "$work/ctx/spec.md" >"$prdir/factory/specs/issue-7.md"
echo hello >"$prdir/factory/x/hello.md"
(cd "$prdir" && git init -q && git add -A && git commit -qm head)
head_real="$(git -C "$prdir" rev-parse HEAD)"
"$py" - "$work/spec-fixture.json" "$work/fixpr.json" "$head_real" <<'PY'
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
fart="$work/fart"
"$py" scripts/opencode-build-fix-context.py --repo Data-Science-Link/software_factory_template --from-json "$work/fixpr.json" --out-dir "$fart" >/dev/null
cat >"$work/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = stats ]; then exit 0; fi
echo "fixed" >>factory/x/hello.md
printf '## What I changed and why\n- appended fixed\n'
FAKE
set +e
(PATH="$work/bin:$PATH" OC_INSTRUCTION='/oc fix append fixed' OC_ARTIFACT_DIR="$fart" OC_PR_DIR="$prdir" \
  DEEPINFRA_API_KEY="$FAKE_KEY" OC_VERIFY_SANDBOX=none bash scripts/opencode-agent-fix.sh) >"$work/fix.log" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q '^+++ b/factory/specs/issue-7.md' "$fart/changes.patch" && grep -q 'restored the exact approved copy' "$fart/summary.md" \
  && grep -qx 'fixed' "$fart/evidence.md" && grep -qx 'key=unset gh=unset' "$fart/evidence.md" \
  && grep -qx 'spec_sha256=[0-9a-f]\{64\}' "$fart/fix-meta.txt"; then
  ok "agent-fix: escaped-quote spec on the branch restored; verification ran on PR head + fix"
else bad "agent-fix (rc=$rc)"; tail -20 "$work/fix.log"; fi
prompt="$(OC_INSTRUCTION='/oc fix x' OC_ARTIFACT_DIR="$fart" OC_PR_DIR="$prdir" bash scripts/opencode-agent-fix.sh --print-prompt)"
if grep -q 'rewrites it from the approved comment' <<<"$prompt" && grep -q 'harness runs them itself on the fixed branch' <<<"$prompt"; then
  ok "agent-fix prompt: spec is harness-owned; verification by harness"
else bad "agent-fix prompt"; fi

# run-facts: fix runs are not predicted; --risk mirrors the front matter
mkdir -p "$work/rf/factory/specs"
printf -- '---\nrisk: normal\npredicted_cost_usd: 0.033\n---\n' >"$work/rf/factory/specs/issue-9.md"
f1="$(cd "$work/rf" && OC_ISSUE_NUMBER=9 OC_RUN_ID=1 OC_RUN_KIND=fix bash "$root/scripts/opencode-run-facts.sh")"
r1="$(cd "$work/rf" && OC_ISSUE_NUMBER=9 OC_RUN_ID=1 bash "$root/scripts/opencode-run-facts.sh" --risk)"
r2="$(cd "$work/rf" && OC_ISSUE_NUMBER=8 OC_RUN_ID=1 bash "$root/scripts/opencode-run-facts.sh" --risk)"
if grep -q '^Predicted cost: not predicted (fix run' <<<"$f1" && ! grep -q '0.033' <<<"$f1" && [ "$r1" = normal ] && [ "$r2" = unknown ]; then
  ok "run-facts: fix run says 'not predicted (fix run)'; --risk = front matter or unknown"
else bad "run-facts fix/risk"; echo "$f1 / $r1 / $r2"; fi

echo
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
