#!/usr/bin/env bash
# Push HEAD onto an existing branch, only if the remote branch is still at the expected SHA and
# HEAD is exactly one commit on top of it. Uses GH_TOKEN via gh's credential helper without
# writing git config to disk (same as opencode-git-push-scoped.sh). Never a plain force push:
# --force-with-lease pins the expected remote value, so a moved head is refused by the server.
set -euo pipefail

branch="${1:?branch name required}"
expected="${2:?expected remote head SHA required}"
: "${GH_TOKEN:?GH_TOKEN is required for push}"

[[ "$expected" =~ ^[0-9a-f]{40}$ ]] || { echo "push-lease: expected SHA is malformed" >&2; exit 1; }
git check-ref-format --branch "$branch" >/dev/null 2>&1 || { echo "push-lease: bad branch name" >&2; exit 1; }
parent="$(git rev-parse --verify --quiet HEAD^ || true)"
if [ "$parent" != "$expected" ]; then
  echo "push-lease: HEAD is not a single commit on top of ${expected:0:12}; refusing" >&2
  exit 1
fi

cred_helper="${OPENCODE_GIT_CREDENTIAL_HELPER:-!gh auth git-credential}"

git -c credential.helper= \
  -c "credential.helper=${cred_helper}" \
  push --force-with-lease="refs/heads/${branch}:${expected}" \
  origin "HEAD:refs/heads/${branch}"
