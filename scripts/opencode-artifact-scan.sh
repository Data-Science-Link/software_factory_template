#!/usr/bin/env bash
# Fail closed if artifacts or logs contain secrets or forbidden paths. Never prints matched secrets.
set -euo pipefail

fail() {
  echo "artifact-scan: FAIL — $1" >&2
  exit 1
}

scan_one() {
  local path="$1"
  [ -f "$path" ] || return 0

  if command -v gitleaks >/dev/null 2>&1; then
    if ! gitleaks detect --no-git --redact --exit-code 1 --source "$path" >/dev/null 2>&1; then
      fail "gitleaks reported a possible secret in $(basename "$path") (redacted)"
    fi
  fi

  if grep -qE '(ghs_[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{10,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.)' "$path" 2>/dev/null; then
    fail "token-like string in $(basename "$path") (details redacted)"
  fi

  if [ -n "${DEEPINFRA_API_KEY:-}" ] && grep -Fq "$DEEPINFRA_API_KEY" "$path" 2>/dev/null; then
    fail "DEEPINFRA_API_KEY value appears in $(basename "$path")"
  fi
}

forbidden_paths() {
  local patch="$1"
  [ -f "$patch" ] || return 0
  local paths
  paths="$(grep -E '^(\+\+\+|---) [ab]/' "$patch" 2>/dev/null | sed -E 's/^(\+\+\+|---) [ab]\///' | sort -u || true)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      .github/*|.github) fail "patch touches forbidden path: $p" ;;
      scripts/protect-main.sh) fail "patch touches forbidden path: $p" ;;
      .*) fail "patch touches dotfile: $p" ;;
    esac
  done <<<"$paths"
}

if [ "$#" -lt 1 ]; then
  echo "usage: opencode-artifact-scan.sh <files...>" >&2
  exit 2
fi

for f in "$@"; do
  scan_one "$f"
done

for f in "$@"; do
  case "$f" in
    *.patch|*changes.patch|*patch.diff) forbidden_paths "$f" ;;
  esac
done

echo "artifact-scan: passed."
