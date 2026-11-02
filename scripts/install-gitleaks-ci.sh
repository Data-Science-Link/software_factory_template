#!/usr/bin/env bash
# Install pinned gitleaks for CI (same pins as .github/workflows/secret-scan.yml).
set -euo pipefail

GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.30.1}"
GITLEAKS_SHA256="${GITLEAKS_SHA256:-551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb}"

file="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
curl -sSfL -o "$file" "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${file}"
echo "${GITLEAKS_SHA256}  ${file}" | sha256sum -c -
tar -xzf "$file" gitleaks
sudo mv gitleaks /usr/local/bin/gitleaks
gitleaks version
