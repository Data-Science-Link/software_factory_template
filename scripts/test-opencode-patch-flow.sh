#!/usr/bin/env bash
# Simulate agent capture → artifact scan → publish apply (hello.md only).
# Does NOT run opencode-publish-pr.sh or git push — see scripts/test-opencode-publish-push.sh.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL="$work/gitconfig"; : >"$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@t

echo "== test: opencode usage capture parser =="
bash "$root/scripts/test-opencode-capture-usage.sh"

echo "== simulate: clone pristine repo (main) =="
git clone -q "$root" "$work/repo"
cd "$work/repo"
git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null || true

echo "== simulate: agent job installs gitleaks =="
bash scripts/install-gitleaks-ci.sh >/dev/null
status_after_install="$(git status --porcelain)"
if [ -n "$status_after_install" ]; then
  echo "FAIL: git status not clean after gitleaks install:"
  echo "$status_after_install"
  exit 1
fi
echo "OK: git status --porcelain empty after gitleaks install"

echo "== simulate: worker creates spike sim file =="
mkdir -p factory/spikes
sim_file=factory/spikes/opencode-sim-test.md
echo "Hello from OpenCode spike sim." >"$sim_file"
export OC_ARTIFACT_DIR="$work/artifacts"
export OC_ISSUE_NUMBER=99999
mkdir -p "$OC_ARTIFACT_DIR"
rm -f gitleaks_*.tar.gz 2>/dev/null || true
git add -A -- . \
  ":(exclude)*.tar.gz" \
  ":(exclude)*.tgz" \
  ":(exclude)*.zip" \
  ":(exclude)gitleaks_*"
git diff --cached --binary >"$OC_ARTIFACT_DIR/changes.patch"
printf '# summary\n' >"$OC_ARTIFACT_DIR/summary.md"
printf 'log\n' >"$OC_ARTIFACT_DIR/opencode.log"
cat >"$OC_ARTIFACT_DIR/usage-metrics.md" <<'USAGE'
## Token usage (opencode stats)

- Model: deepinfra/deepseek-ai/DeepSeek-V4-Flash-0731
- Input tokens: 1
- Output tokens: 1
- Cache read: 0
- OpenCode-reported cost: not measured
- Source: `opencode stats --models`
USAGE

bash scripts/opencode-artifact-scan.sh \
  "$OC_ARTIFACT_DIR/changes.patch" \
  "$OC_ARTIFACT_DIR/summary.md" \
  "$OC_ARTIFACT_DIR/usage-metrics.md" \
  "$OC_ARTIFACT_DIR/opencode.log"

files_in_patch="$(grep -E '^diff --git a/' "$OC_ARTIFACT_DIR/changes.patch" | awk '{print $4}' | sed 's|^b/||' | sort -u)"
if [ "$files_in_patch" != "$sim_file" ]; then
  echo "FAIL: patch files expected only $sim_file, got:"
  echo "$files_in_patch"
  exit 1
fi
echo "OK: patch contains only $sim_file"

echo "== simulate: publish apply + commit only (no push, not opencode-publish-pr.sh) =="
publish="$work/publish"
git clone -q "$root" "$publish"
cd "$publish"
git checkout -q main 2>/dev/null || true
bash scripts/install-gitleaks-ci.sh >/dev/null
if [ -n "$(git status --porcelain)" ]; then
  echo "FAIL: publish checkout dirty after gitleaks install"
  exit 1
fi
git checkout -q -b oc/issue-99999-sim
git apply --check "$OC_ARTIFACT_DIR/changes.patch"
git apply "$OC_ARTIFACT_DIR/changes.patch"
git add -A
git commit -q -m "sim"
if [ "$(git diff-tree --no-commit-id --name-only -r HEAD | sort -u)" != "$sim_file" ]; then
  echo "FAIL: commit file list unexpected"
  git diff-tree --no-commit-id --name-only -r HEAD
  exit 1
fi
echo "OK: publish apply + commit contains only $sim_file"
echo "NOTE: push path not covered here — run scripts/test-opencode-publish-push.sh"
echo "PASS: agent + publish-apply simulation"
