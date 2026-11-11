#!/usr/bin/env bash
# After `git add -A`, force-stage exact paths from the approved spec's ## Files
# that exist in the worktree but were left unstaged because a gitignore rule
# matches them (#197). Non-spec ignored files stay unstaged.
#
# If a listed path exists and still cannot be staged, or (with
# --fail-missing-ignored) a listed Create path is missing and would be ignored
# (dropped from the patch), exit 1 naming the file and the matching rule.
set -euo pipefail

usage() {
  echo "usage: opencode-stage-spec-files.sh --spec FILE [--patch FILE] [--fail-missing-ignored]" >&2
  exit 2
}

spec=''
patch=''
fail_missing_ignored=no
while [ $# -gt 0 ]; do
  case "$1" in
    --spec) spec="${2:-}"; shift 2 ;;
    --patch) patch="${2:-}"; shift 2 ;;
    --fail-missing-ignored) fail_missing_ignored=yes; shift ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done

if [ -z "$spec" ] || [ ! -f "$spec" ]; then
  echo "opencode-stage-spec-files: --spec FILE is required and must exist" >&2
  exit 2
fi
if [ -n "$patch" ] && [ ! -f "$patch" ]; then
  echo "opencode-stage-spec-files: --patch FILE must exist: $patch" >&2
  exit 2
fi
git rev-parse --is-inside-work-tree >/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scan="${OC_STAGE_SCAN:-$here/opencode-artifact-scan.sh}"

# Print "intent<TAB>path" for exact ## Files paths (same rules as
# scripts/factory-spec-check.py files_section_paths).
list_spec_files() {
  python3 - "$1" <<'PY'
import re, sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
body = text
stripped = text.lstrip()
if stripped.startswith("---"):
    parts = stripped.split("---", 2)
    if len(parts) >= 3:
        body = parts[2]
m = re.search(r"^##[ \t]+Files[ \t]*\n(.*?)(?=^##[ \t]|\Z)", body, re.M | re.S)
if not m:
    sys.exit(0)
PATH_IN_BACKTICKS = re.compile(r"`([^`]+)`")

def files_line_intent(line: str) -> str:
    low = line.lower()
    if re.search(r"\b(read\b|read-first)", low) and not re.search(r"\b(create|add|new)\b", low):
        return "read"
    if re.search(r"\b(create|add|new)\b", low):
        return "create"
    if re.search(r"\b(edit|change|modify|update)\b", low):
        return "modify"
    return "read"

for line in m.group(1).splitlines():
    found = PATH_IN_BACKTICKS.findall(line)
    if not found:
        continue
    intent = files_line_intent(line)
    for raw in found:
        p = raw.strip()
        if not p or "*" in p or "?" in p or "..." in p:
            continue
        print(f"{intent}\t{p}")
PY
}

# Paths added in a git patch (b/ side), one per line.
list_patch_paths() {
  [ -n "$1" ] || return 0
  python3 - "$1" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
seen = set()
for m in re.finditer(r"^diff --git a/.+ b/(.+)$", text, re.M):
    p = m.group(1).strip()
    if p and p not in seen:
        seen.add(p)
        print(p)
PY
}

safe_path() { # $1 = path; 0 if a relative repo path we will even consider
  local p="$1"
  case "$p" in
    '' | /* | -* | *..*) return 1 ;;
  esac
  case "$p" in *$'\n'* | *$'\t'*) return 1 ;; esac
  return 0
}

# Matching ignore rule as "source:line:pattern", or empty if not ignored.
ignore_rule() { # $1 = path; $2 = --no-index or empty
  local p="$1" flags="${2:-}" out
  # shellcheck disable=SC2086
  out="$(git check-ignore -v $flags -- "$p" 2>/dev/null || true)"
  [ -n "$out" ] || return 0
  printf '%s\n' "${out%%$'\t'*}"
}

is_tracked() {
  git ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

is_staged() {
  git diff --cached --name-only -- "$1" | grep -qxF -- "$1"
}

fail_named() { # $1 = path, $2 = rule, $3 = message suffix
  echo "opencode-stage-spec-files: spec-listed file $1 is ignored by $2$3" >&2
  exit 1
}

stage_ignored() { # $1 = path
  local p="$1" rule
  if [ -L "$p" ]; then
    rule="$(ignore_rule "$p" --no-index)"
    echo "opencode-stage-spec-files: spec-listed file $p is a symlink (ignored by ${rule:-unknown rule}); refusing to force-add" >&2
    exit 1
  fi
  [ -f "$p" ] || return 0
  is_tracked "$p" && return 0
  rule="$(ignore_rule "$p")"
  [ -n "$rule" ] || return 0
  if [ -x "$scan" ]; then
    if ! bash "$scan" --check-spec-path create "$p" >/dev/null 2>&1; then
      echo "opencode-stage-spec-files: spec-listed file $p is ignored by $rule and is not a path the scan would allow; refusing to force-add" >&2
      exit 1
    fi
  fi
  git add -f -- "$p" || fail_named "$p" "$rule" " and git add -f failed"
  if ! is_staged "$p"; then
    fail_named "$p" "$rule" " and could not be staged"
  fi
  echo "harness: staged ignored spec-listed file $p (ignored by $rule) (#197)"
}

# 1. Force-add listed paths that exist, are untracked, and are ignored.
while IFS=$'\t' read -r intent path; do
  [ -n "${path:-}" ] || continue
  if ! safe_path "$path"; then
    echo "opencode-stage-spec-files: refusing unsafe ## Files path: $path" >&2
    exit 1
  fi
  if [ -e "$path" ] || [ -L "$path" ]; then
    stage_ignored "$path"
    continue
  fi
  # Missing Create path that a gitignore rule would drop: fail only when asked
  # (publish, after the patch was applied). Job A leaves this to verification.
  if [ "$fail_missing_ignored" = yes ] && [ "$intent" = create ]; then
    rule="$(ignore_rule "$path" --no-index)"
    if [ -n "$rule" ]; then
      fail_named "$path" "$rule" "; it is missing from the worktree and was likely dropped from the patch"
    fi
  fi
done < <(list_spec_files "$spec")

# 2. Also force-add any untracked ignored file that is already in the patch, in
# case the ## Files wording was not parsed. Never force-add a path only because
# it is ignored.
if [ -n "$patch" ]; then
  while IFS= read -r path; do
    [ -n "${path:-}" ] || continue
    safe_path "$path" || continue
    [ -f "$path" ] || continue
    is_tracked "$path" && continue
    [ -n "$(ignore_rule "$path")" ] || continue
    stage_ignored "$path"
  done < <(list_patch_paths "$patch")
fi
