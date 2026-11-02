#!/usr/bin/env bash
# Push once using GH_TOKEN via gh's credential helper, without writing git config to disk.
set -euo pipefail

branch="${1:?branch name required}"
: "${GH_TOKEN:?GH_TOKEN is required for push}"

cred_helper="${OPENCODE_GIT_CREDENTIAL_HELPER:-!gh auth git-credential}"

git -c credential.helper= \
  -c "credential.helper=${cred_helper}" \
  push -u origin "$branch"
