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

# Single source of truth for forbidden patch paths (bash glob; `*` also matches `/`).
# opencode-agent-run.sh prints this list into the worker prompt via --list-forbidden.
FORBIDDEN_PATTERNS=(
  '.github' '.github/*'
  'scripts' 'scripts/*'
  'opencode.json'
  '.factory/actions-security.md'
  '*.tar.gz' '*.tgz' '*.zip' '*.tar' '*.deb' '*.rpm'
  'gitleaks_*'
  '.*'
)

path_is_forbidden() {
  local p="$1" pat
  [ "$p" = /dev/null ] && return 1
  for pat in "${FORBIDDEN_PATTERNS[@]}"; do
    # shellcheck disable=SC2254 # unquoted on purpose: pattern match
    case "$p" in $pat) return 0 ;; esac
  done
  return 1
}

forbidden_paths() {
  local patch="$1"
  [ -f "$patch" ] || return 0
  if grep -q '^GIT binary patch' "$patch" 2>/dev/null; then
    fail "patch contains a GIT binary patch (forbidden)"
  fi
  local line p
  while IFS= read -r line; do
    case "$line" in
      "+++ b/"*)
        p="${line#+++ b/}"
        if path_is_forbidden "$p"; then fail "patch touches forbidden path: $p"; fi
        ;;
      "--- b/"*)
        p="${line#--- b/}"
        if path_is_forbidden "$p"; then fail "patch touches forbidden path: $p"; fi
        ;;
      diff\ --git\ a/*\ b/*)
        p="${line##* b/}"
        if path_is_forbidden "$p"; then fail "patch touches forbidden path: $p"; fi
        ;;
      rename\ from\ *)
        p="${line#rename from }"
        if path_is_forbidden "$p"; then fail "patch renames forbidden path: $p"; fi
        ;;
      rename\ to\ *)
        p="${line#rename to }"
        if path_is_forbidden "$p"; then fail "patch renames forbidden path: $p"; fi
        ;;
    esac
  done <"$patch"
}

if [ "${1:-}" = "--list-forbidden" ]; then
  printf '%s\n' "${FORBIDDEN_PATTERNS[@]}"
  exit 0
fi

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
