#!/usr/bin/env bash
# Offline tests for scripts/opencode-stage-spec-files.sh (#197): a spec-listed
# new file matching .gitignore is force-staged (or publish fails naming the
# file and rule); non-spec ignored files stay excluded.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
helper="$root/scripts/opencode-stage-spec-files.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL="$work/gitconfig"; : >"$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_NOSYSTEM=1
git config --global user.name t
git config --global user.email t@t

passed=0
failed=0
ok() { echo "OK    $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }

# A throwaway repo with *.log ignored, plus a committed tracked log (negation
# is not needed: a tracked file is not dropped by gitignore).
new_repo() {
  local dir="$1"
  rm -rf "$dir"
  git init -q "$dir"
  printf '*.log\nnoise/\n' >"$dir/.gitignore"
  mkdir -p "$dir/tests/stage-spec" "$dir/factory/specs"
  echo tracked >"$dir/tests/stage-spec/already-tracked.log"
  echo base >"$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" add -f -- tests/stage-spec/already-tracked.log
  git -C "$dir" commit -q -m base
}

# Minimal spec whose ## Files lists the given create/read paths in backticks.
write_spec() { # $1 = dest; remaining lines are Files bullets
  local dest="$1"
  shift
  {
    printf '%s\n' '<!-- factory-spec v1 -->' '---' 'title: test' '---' '' '## Outcome' 'x' '' '## Files'
    printf '%s\n' "$@"
    printf '%s\n' '' '## Out of scope' 'y'
  } >"$dest"
}

# Confirm the four protected callers invoke the helper, so a later edit cannot
# silently drop the hook.
for s in opencode-agent-run.sh opencode-agent-fix.sh opencode-publish-pr.sh opencode-publish-fix.sh; do
  if grep -qF 'opencode-stage-spec-files.sh' "$root/scripts/$s"; then
    ok "caller $s invokes the helper"
  else
    bad "caller $s invokes the helper"
  fi
done

echo "== listed ignored file is force-staged; sibling ignored file is not =="
repo="$work/r1"
new_repo "$repo"
cd "$repo"
echo fixture >tests/stage-spec/opencode.log
echo leftover >tests/stage-spec/noise.log
mkdir -p noise
echo build >noise/out.log
write_spec factory/specs/issue-197.md \
  '- Create: `tests/stage-spec/opencode.log`'
git add -A
# git add -A must have dropped the .log files (the bug).
if git diff --cached --name-only | grep -q 'opencode.log'; then
  bad "precondition: git add -A left opencode.log unstaged"
else
  ok "precondition: git add -A drops the gitignored .log files"
fi
if bash "$helper" --spec factory/specs/issue-197.md >"$work/r1.out" 2>"$work/r1.err"; then
  if git diff --cached --name-only | grep -qxF 'tests/stage-spec/opencode.log' \
    && ! git diff --cached --name-only | grep -q 'noise.log' \
    && ! git diff --cached --name-only | grep -q 'noise/out.log' \
    && grep -q 'staged ignored spec-listed file tests/stage-spec/opencode.log' "$work/r1.out" \
    && grep -q '\.gitignore:' "$work/r1.out"; then
    ok "force-stages only the spec-listed ignored file and names the rule"
  else
    bad "force-stages only the spec-listed ignored file and names the rule"
    git diff --cached --name-only; cat "$work/r1.out" "$work/r1.err"
  fi
else
  bad "helper exits 0 when the listed file exists and can be force-added (rc=$?)"
  cat "$work/r1.out" "$work/r1.err"
fi

echo "== missing Create path that would be ignored fails loudly when asked =="
repo="$work/r2"
new_repo "$repo"
cd "$repo"
write_spec factory/specs/issue-197.md \
  '- Create: `tests/stage-spec/opencode.log`'
git add -A
set +e
bash "$helper" --spec factory/specs/issue-197.md --fail-missing-ignored >"$work/r2.out" 2>"$work/r2.err"
rc=$?
set -e
if [ "$rc" -eq 1 ] \
  && grep -q 'spec-listed file tests/stage-spec/opencode.log is ignored by' "$work/r2.err" \
  && grep -q 'dropped from the patch' "$work/r2.err" \
  && grep -q '\.gitignore:' "$work/r2.err"; then
  ok "missing ignored Create path: fails naming the file and rule"
else
  bad "missing ignored Create path: fails naming the file and rule (rc=$rc)"
  cat "$work/r2.out" "$work/r2.err"
fi

echo "== missing Create path that is not ignored does not fail =="
repo="$work/r3"
new_repo "$repo"
cd "$repo"
write_spec factory/specs/issue-197.md \
  '- Create: `tests/stage-spec/readme.md`'
git add -A
if bash "$helper" --spec factory/specs/issue-197.md --fail-missing-ignored; then
  ok "missing non-ignored Create path is left to verification"
else
  bad "missing non-ignored Create path is left to verification"
fi

echo "== already-tracked ignored path is a no-op =="
repo="$work/r4"
new_repo "$repo"
cd "$repo"
echo changed >>tests/stage-spec/already-tracked.log
write_spec factory/specs/issue-197.md \
  '- Change: `tests/stage-spec/already-tracked.log`'
git add -A
if git diff --cached --name-only | grep -qxF 'tests/stage-spec/already-tracked.log' \
  && bash "$helper" --spec factory/specs/issue-197.md; then
  ok "tracked file matching an ignore pattern stays a normal staged change"
else
  bad "tracked file matching an ignore pattern stays a normal staged change"
fi

echo "== symlink at a listed ignored path is refused =="
repo="$work/r5"
new_repo "$repo"
cd "$repo"
echo target >tests/stage-spec/target.log
ln -s target.log tests/stage-spec/opencode.log
write_spec factory/specs/issue-197.md \
  '- Create: `tests/stage-spec/opencode.log`'
git add -A
set +e
bash "$helper" --spec factory/specs/issue-197.md >"$work/r5.out" 2>"$work/r5.err"
rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'is a symlink' "$work/r5.err" \
  && ! git diff --cached --name-only | grep -q 'opencode.log'; then
  ok "refuses to force-add a symlink"
else
  bad "refuses to force-add a symlink (rc=$rc)"
  cat "$work/r5.out" "$work/r5.err"
fi

echo "== --patch force-adds an ignored file present in the patch =="
repo="$work/r6"
new_repo "$repo"
cd "$repo"
echo fixture >tests/stage-spec/from-patch.log
# A spec that does not list the log (parser miss / unusual wording).
write_spec factory/specs/issue-197.md \
  '- Create: `README.md`'
# Build a patch that includes the ignored log (as job A would after force-add).
git add -A
git add -f -- tests/stage-spec/from-patch.log
git diff --cached --binary >"$work/from-patch.patch"
git reset -q
git add -A
# Worktree still has the file; git add -A left it unstaged.
if bash "$helper" --spec factory/specs/issue-197.md --patch "$work/from-patch.patch" >"$work/r6.out" 2>"$work/r6.err" \
  && git diff --cached --name-only | grep -qxF 'tests/stage-spec/from-patch.log'; then
  ok "--patch force-adds an ignored file that is in the patch"
else
  bad "--patch force-adds an ignored file that is in the patch"
  git diff --cached --name-only; cat "$work/r6.out" "$work/r6.err"
fi

echo "== unsafe path is refused =="
repo="$work/r7"
new_repo "$repo"
cd "$repo"
write_spec factory/specs/issue-197.md \
  '- Create: `../outside.log`'
set +e
bash "$helper" --spec factory/specs/issue-197.md >"$work/r7.out" 2>"$work/r7.err"
rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'refusing unsafe' "$work/r7.err"; then
  ok "refuses a ## Files path with .."
else
  bad "refuses a ## Files path with .. (rc=$rc)"
  cat "$work/r7.out" "$work/r7.err"
fi

echo
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
