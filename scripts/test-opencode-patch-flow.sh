#!/usr/bin/env bash
# Simulate agent capture → artifact scan → publish apply (hello.md only). No OpenCode/DeepInfra.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "== simulate: clone pristine repo =="
git clone -q "$root" "$work/repo"
cd "$work/repo"
git checkout -q cursor/issue-22-opencode-spike-dbd1 2>/dev/null || true

echo "== simulate: agent job installs gitleaks =="
bash scripts/install-gitleaks-ci.sh >/dev/null
status_after_install="$(git status --porcelain)"
if [ -n "$status_after_install" ]; then
  echo "FAIL: git status not clean after gitleaks install:"
  echo "$status_after_install"
  exit 1
fi
echo "OK: git status --porcelain empty after gitleaks install"

echo "== simulate: worker creates hello.md =="
mkdir -p factory/spikes
echo "Hello from OpenCode spike." >factory/spikes/hello.md
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

bash scripts/opencode-artifact-scan.sh \
  "$OC_ARTIFACT_DIR/changes.patch" \
  "$OC_ARTIFACT_DIR/summary.md" \
  "$OC_ARTIFACT_DIR/opencode.log"

files_in_patch="$(grep -E '^diff --git a/' "$OC_ARTIFACT_DIR/changes.patch" | awk '{print $4}' | sed 's|^b/||' | sort -u)"
if [ "$files_in_patch" != "factory/spikes/hello.md" ]; then
  echo "FAIL: patch files expected only factory/spikes/hello.md, got:"
  echo "$files_in_patch"
  exit 1
fi
echo "OK: patch contains only factory/spikes/hello.md"

echo "== simulate: publish job (fresh checkout + apply) =="
publish="$work/publish"
git clone -q "$root" "$publish"
cd "$publish"
git checkout -q cursor/issue-22-opencode-spike-dbd1 2>/dev/null || true
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
if [ "$(git diff-tree --no-commit-id --name-only -r HEAD | sort -u)" != "factory/spikes/hello.md" ]; then
  echo "FAIL: commit file list unexpected"
  git diff-tree --no-commit-id --name-only -r HEAD
  exit 1
fi
echo "OK: publish apply + commit contains only factory/spikes/hello.md"
echo "PASS: full agent-then-publish simulation"
