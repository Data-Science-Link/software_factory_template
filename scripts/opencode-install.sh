#!/usr/bin/env bash
# Install a pinned OpenCode CLI from GitHub releases (checksum verified). No npm @latest.
set -euo pipefail

OPENCODE_VERSION="${OPENCODE_VERSION:-1.19.5}"
OPENCODE_LINUX_X64_SHA512="${OPENCODE_LINUX_X64_SHA512:-5e1b67e903547f045c2d3b2d05da9fc9d9f78a882cee84a73cf634ca1e57443244868f131669c06e23d662cee61b83c944b1b7f34eff300a010a44273afef01c}"
INSTALL_DIR="${OPENCODE_INSTALL_DIR:-${RUNNER_TEMP:-/tmp}/opencode-bin}"

arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) tarball="opencode-linux-x64.tar.gz" ;;
  aarch64|arm64) tarball="opencode-linux-arm64.tar.gz" ;;
  *)
    echo "opencode-install: unsupported architecture: $arch" >&2
    exit 1
    ;;
esac

if [ "$tarball" != "opencode-linux-x64.tar.gz" ]; then
  echo "opencode-install: pin OPENCODE_LINUX_ARM64_SHA512 for $tarball before using on arm runners." >&2
  exit 1
fi

base="https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -sSfL -o "$work/$tarball" "${base}/${tarball}"
printf '%s  %s\n' "$OPENCODE_LINUX_X64_SHA512" "$tarball" | (cd "$work" && sha512sum -c -)

mkdir -p "$INSTALL_DIR"
tar -xzf "$work/$tarball" -C "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/opencode"

"$INSTALL_DIR/opencode" --version | grep -Fq "$OPENCODE_VERSION" || {
  echo "opencode-install: version mismatch after install" >&2
  exit 1
}

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "OPENCODE_BIN=$INSTALL_DIR/opencode" >> "$GITHUB_ENV"
fi
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$INSTALL_DIR" >> "$GITHUB_PATH"
fi
export PATH="$INSTALL_DIR:$PATH"
echo "Installed OpenCode ${OPENCODE_VERSION} at $INSTALL_DIR/opencode"
