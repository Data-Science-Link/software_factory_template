#!/usr/bin/env bash
# Test scoped git push (no persisted credential config). Uses a bare remote + fake credential helper.
set -euo pipefail

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

assert_no_credential_config() {
  local label=$1
  if git config --global --get-regexp '^credential\.' >/dev/null 2>&1; then
    echo "FAIL: global credential config present ($label)" >&2
    git config --global --get-regexp '^credential\.' >&2 || true
    exit 1
  fi
  if git config --local --get-regexp '^credential\.' >/dev/null 2>&1; then
    echo "FAIL: local credential config present ($label)" >&2
    git config --local --get-regexp '^credential\.' >&2 || true
    exit 1
  fi
}

work="$(mktemp -d)"
export HOME="$work/home"
mkdir -p "$HOME"
trap 'rm -rf "$work"' EXIT

bare="$work/remote.git"
git init --bare -q "$bare"

clone="$work/clone"
git clone -q "$bare" "$clone"
cd "$clone"
git config user.email "test@test"
git config user.name "test"
echo base >README.md
git add README.md
git commit -q -m base
git branch -M main
git push -q origin main

git checkout -q -b oc/issue-test-push
mkdir -p factory/spikes
echo hello >factory/spikes/hello.md
git add factory/spikes/hello.md
git commit -q -m worker

helper="$work/fake-git-credential.sh"
cat >"$helper" <<'EOF'
#!/usr/bin/env bash
echo "username=git"
echo "password=fake-token-for-test"
EOF
chmod +x "$helper"

export GH_TOKEN=fake-token-for-test
export OPENCODE_GIT_CREDENTIAL_HELPER="!${helper}"

assert_no_credential_config "before push"
bash "$scripts_dir/opencode-git-push-scoped.sh" oc/issue-test-push
assert_no_credential_config "after push"

cd "$bare"
if ! git show-ref --verify --quiet refs/heads/oc/issue-test-push; then
  echo "FAIL: branch not found on bare remote after push" >&2
  exit 1
fi

echo "OK: scoped push reached bare remote; no credential config before or after"
