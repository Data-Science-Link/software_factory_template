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

# Single source of truth for the /oc worker path policy (issue #63). opencode-agent-run.sh
# prints --list-rules into the worker prompt; the scan below enforces the same rules.
# Patterns are bash globs; `*` also matches `/`.
#
# 1. FORBIDDEN_PATTERNS: never created, edited, renamed or deleted.
# 2. Dot-paths (any path component starting with "."): forbidden, except anything under
#    .factory/ (minus the owner-only files in 1) and .gitignore files (add lines only).
# 3. scripts/: new files only, directly in scripts/, hyphenated names. Existing scripts are the
#    guardrails: no edit, delete, rename-out or mode change.
# 4. Symlinks, submodules, binary patches, quoted (special-character) paths and ".." are forbidden.
FORBIDDEN_PATTERNS=(
  '.github' '.github/*'
  'opencode.json'
  'AGENTS.md' '*/AGENTS.md'
  '.factory/actions-security.md'
  '.factory/models.yaml'
  'requirements-factory.txt'
  'scripts'
  '*.tar.gz' '*.tgz' '*.zip' '*.tar' '*.deb' '*.rpm'
  'gitleaks_*'
  '.*' '*/.*'
)
ADD_ONLY_DIR='scripts/'
EDITABLE_DOT_DIR='.factory/'
# Fix runs only (#102): --base-scripts FILE lists the scripts/ paths that exist on the base branch
# (the trusted default-branch checkout, written by the harness, never by the worker). A scripts/
# file NOT in that list was added by the PR being fixed, so a fix patch may edit its content.
# Without the flag (build runs) every existing script stays locked, as before.
BASE_SCRIPTS_FILE=''
in_base_scripts() { # $1 = path; true when it exists on the base branch
  [ -n "$BASE_SCRIPTS_FILE" ] && grep -qxF -- "$1" "$BASE_SCRIPTS_FILE"
}

list_rules() {
  cat <<'RULES'
Path policy (enforced by scripts/opencode-artifact-scan.sh; bash globs, * also matches /).
If your change breaks ANY rule, the scan discards the WHOLE run and all your work.

Always forbidden: never create, edit, rename or delete a path matching:
RULES
  printf -- '- %s\n' "${FORBIDDEN_PATTERNS[@]}"
  cat <<'RULES'
".*" and "*/.*" cover every dot-file and dot-directory at any depth (.cursor/, .env,
factory/x/.env), with two exceptions:
- .factory/: you may edit and add docs under .factory/, except .factory/actions-security.md
  and .factory/models.yaml (owner-only: security policy, model routing and budget caps).
- .gitignore files: you may only ADD lines. Never delete or change an existing line, and
  never delete, rename or chmod a .gitignore.

scripts/: you may add new scripts under scripts/ but not edit existing ones.
- A new file must sit directly in scripts/ (no subdirectories) and have a hyphenated name,
  for example scripts/dbt-seed-check.sh or scripts/factory-report.py. A bare module-style
  name such as scripts/yaml.py or scripts/helpers.sh is rejected (it could shadow imports).
- You may NOT edit, delete, rename, move out or chmod any existing file under scripts/;
  existing scripts are the factory's guardrails. If an existing script needs a change,
  stop and say so in your final message instead.
- New scripts are not run by CI unless a workflow calls them, and workflows are owner-only.

Also forbidden everywhere: symlinks, submodules, binary files, ".." in paths, and file
names with spaces or special characters. Other tooling can go under factory/<area>/
(for example factory/dbt/). If the spec asks for a forbidden change, skip that part and
say so in your final message.

requirements-factory.txt (the pinned factory Python dependencies) is owner-only: never add,
remove or re-pin a package. If the spec needs a new dependency, stop and say so instead.
RULES
  if [ "${1:-}" = fix ]; then
    cat <<'RULES'

Fix runs only: a script under scripts/ that this PR added (it is not on the default branch)
may be EDITED in place (content changes; a mode change only between 100644 and 100755). You
still may not delete or rename it, and every script that exists on the default branch stays
locked: never edit, delete, rename, re-create or chmod it.
RULES
  fi
}

path_has_dot_component() {
  case "/$1" in */.*) return 0 ;; esac
  return 1
}

# Echoes the class of a path: forbidden | gitignore | scripts | ok.
path_class() {
  local p="$1" pat base
  case "$p" in
    '' | /* | ../* | */../* | */.. | .. | ./* | */./* | */. | . | *//*) echo forbidden; return ;;
  esac
  case "$p" in *[[:cntrl:]\\]*) echo forbidden; return ;; esac
  for pat in "${FORBIDDEN_PATTERNS[@]}"; do
    case "$pat" in '.*' | '*/.*') continue ;; esac
    # shellcheck disable=SC2254 # unquoted on purpose: pattern match
    case "$p" in $pat) echo forbidden; return ;; esac
  done
  base="${p##*/}"
  if [ "$base" = .gitignore ]; then
    # A .gitignore inside another dot-dir (other than .factory/) stays forbidden.
    if path_has_dot_component "${p%/*}" && [ "$p" != .gitignore ]; then
      case "$p" in "$EDITABLE_DOT_DIR"*) ;; *) echo forbidden; return ;; esac
    fi
    echo gitignore; return
  fi
  case "$p" in "$EDITABLE_DOT_DIR"*) echo ok; return ;; esac
  if path_has_dot_component "$p"; then echo forbidden; return; fi
  case "$p" in "$ADD_ONLY_DIR"*) echo scripts; return ;; esac
  echo ok
}

# Back-compat helper: true when a path may never appear in a patch at all.
path_is_forbidden() {
  [ "$1" = /dev/null ] && return 1
  [ "$(path_class "$1")" = forbidden ]
}

check_mode() { # $1 = mode string
  case "$1" in
    120000) fail "patch adds a symlink (forbidden)" ;;
    160000) fail "patch adds a submodule (forbidden)" ;;
    100644 | 100755) ;;
    *) fail "patch has an unexpected file mode: $1" ;;
  esac
}

check_new_script_name() { # $1 = path under scripts/
  local rel="${1#"$ADD_ONLY_DIR"}" stem
  case "$rel" in */*) fail "new file under scripts/ must sit directly in scripts/: $1" ;; esac
  stem="${rel%%.*}"
  if [[ "$stem" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    fail "new script needs a hyphenated name (module-style names can shadow imports): $1"
  fi
}

# Per-file state for the patch parser.
sec_open=no
reset_section() {
  sec_open=no sec_sym='' sec_old='' sec_new='' sec_copy_src=''
  sec_is_new=no sec_is_del=no sec_is_rename=no sec_is_copy=no sec_mode_change=no sec_deletes=no
}

start_section() { # $1 = "diff --git ..." line
  reset_section
  sec_open=yes
  local rest="${1#diff --git }" r half
  case "$rest" in '"'*) fail "patch has a quoted path (special characters are forbidden)" ;; esac
  case "$rest" in a/*) ;; *) fail "patch header without a/ b/ prefixes" ;; esac
  r="${rest#a/}"
  if [ $(( (${#r} - 3) % 2 )) -eq 0 ] && [ "${#r}" -ge 5 ]; then
    half=$(( (${#r} - 3) / 2 ))
    if [ "${r:half}" = " b/${r:0:half}" ]; then sec_sym="${r:0:half}"; fi
  fi
}

no_quoted_path() { # $1 = raw path after a prefix (runs in this shell so fail exits)
  case "$1" in '"'*) fail "patch has a quoted path (special characters are forbidden)" ;; esac
}

finish_section() {
  [ "$sec_open" = yes ] || return 0
  local old="$sec_old" new="$sec_new" status p cls
  if [ -z "$old" ] && [ "$sec_is_new" = no ] && [ "$sec_is_copy" = no ]; then old="$sec_sym"; fi
  if [ -z "$new" ] && [ "$sec_is_del" = no ]; then new="$sec_sym"; fi
  if [ "$sec_is_new" = yes ] && [ "$sec_is_del" = yes ]; then fail "patch section is both new and deleted"; fi
  if [ "$sec_is_new" = yes ] || [ "$sec_is_copy" = yes ]; then status=added; old=''
  elif [ "$sec_is_del" = yes ]; then status=deleted; new=''
  elif [ "$sec_is_rename" = yes ]; then status=renamed
  else status=modified
  fi
  case "$status" in
    added) [ -n "$new" ] || fail "cannot read the new path of a patch section" ;;
    deleted) [ -n "$old" ] || fail "cannot read the deleted path of a patch section" ;;
    *) { [ -n "$old" ] && [ -n "$new" ]; } || fail "cannot read the paths of a patch section" ;;
  esac
  if [ "$status" = modified ] && [ "$old" != "$new" ]; then fail "patch section names two different paths without a rename"; fi
  if [ -n "$sec_sym" ] && [ "$status" != renamed ] && [ "$sec_is_copy" = no ] && [ "$sec_sym" != "${new:-$old}" ]; then
    fail "patch header path does not match the file it changes"
  fi

  # Every path the section mentions must be allowed at all.
  for p in "$sec_sym" "$old" "$new" "$sec_copy_src"; do
    [ -n "$p" ] || continue
    if [ "$(path_class "$p")" = forbidden ]; then
      if [ "$status" = renamed ]; then fail "patch renames forbidden path: $p"; fi
      fail "patch touches forbidden path: $p"
    fi
  done

  # Old side: an existing file that is modified, deleted or renamed away.
  if [ -n "$old" ]; then
    cls="$(path_class "$old")"
    if [ "$cls" = scripts ] && [ -n "$BASE_SCRIPTS_FILE" ] && [ "$status" = modified ] && ! in_base_scripts "$old"; then
      : # fix run: content edit of a script the PR added (#102); delete/rename/main scripts fall through
    elif [ "$cls" = scripts ]; then
      case "$status" in
        deleted) fail "patch deletes an existing script (only new files are allowed under scripts/): $old" ;;
        renamed) fail "patch renames an existing script (only new files are allowed under scripts/): $old" ;;
        *) fail "patch modifies an existing script (only new files are allowed under scripts/): $old" ;;
      esac
    fi
    if [ "$cls" = gitignore ]; then
      if [ "$status" != modified ] || [ "$sec_mode_change" = yes ]; then fail "patch deletes, renames or chmods $old (only added lines are allowed)"; fi
      if [ "$sec_deletes" = yes ]; then fail "patch removes or changes lines in $old (only added lines are allowed)"; fi
    fi
  fi
  # New side: an added, copied or renamed-in file.
  if [ -n "$new" ] && [ "$status" != modified ]; then
    cls="$(path_class "$new")"
    if [ "$cls" = scripts ] && in_base_scripts "$new"; then
      fail "patch re-creates a script that exists on the default branch: $new"
    fi
    if [ "$cls" = scripts ]; then check_new_script_name "$new"; fi
    if [ "$cls" = gitignore ] && [ "$status" != added ]; then fail "patch renames or copies onto .gitignore: $new"; fi
  fi
  sec_open=no
}

# Parses a git patch file by file (same structure git apply reads: headers, then hunks with
# line counts), so lines inside a hunk are never mistaken for headers. Fails closed on any
# line it does not understand.
forbidden_paths() {
  local patch="$1"
  [ -f "$patch" ] || return 0
  if grep -qE '^(GIT binary patch|Binary files .* differ$)' "$patch" 2>/dev/null; then
    fail "patch contains a binary file (forbidden)"
  fi
  local line state=pre old_left=0 new_left=0 m p
  reset_section
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$state" = hunk ]; then
      case "$line" in
        ' '* | '') old_left=$((old_left - 1)); new_left=$((new_left - 1)) ;;
        '+'*) new_left=$((new_left - 1)) ;;
        '-'*) old_left=$((old_left - 1)); sec_deletes=yes ;;
        \\*) ;;
        *) fail "malformed hunk in patch" ;;
      esac
      if [ "$old_left" -lt 0 ] || [ "$new_left" -lt 0 ]; then fail "malformed hunk in patch (line counts)"; fi
      if [ "$old_left" -eq 0 ] && [ "$new_left" -eq 0 ]; then state=between; fi
      continue
    fi
    case "$line" in
      'diff --git '*)
        finish_section
        start_section "$line"
        state=header
        continue
        ;;
      '@@ '*)
        [ "$state" = header ] || [ "$state" = between ] || fail "hunk outside a file section"
        if [[ "$line" =~ ^@@\ -[0-9]+(,([0-9]+))?\ \+[0-9]+(,([0-9]+))?\ @@ ]]; then
          old_left="${BASH_REMATCH[2]:-1}"
          new_left="${BASH_REMATCH[4]:-1}"
        else
          fail "malformed hunk header in patch"
        fi
        if [ "$old_left" -eq 0 ] && [ "$new_left" -eq 0 ]; then state=between; else state=hunk; fi
        continue
        ;;
    esac
    case "$state" in
      pre) fail "patch must start with a 'diff --git' header" ;;
      between)
        case "$line" in \\*) continue ;; *) fail "unexpected line after a hunk in patch" ;; esac
        ;;
    esac
    # state = header
    case "$line" in
      '--- /dev/null') sec_is_new=yes ;;
      '--- a/'*) p="${line#--- a/}"; p="${p%$'\t'}"; no_quoted_path "$p"; sec_old="$p" ;;
      '+++ /dev/null') sec_is_del=yes ;;
      '+++ b/'*) p="${line#+++ b/}"; p="${p%$'\t'}"; no_quoted_path "$p"; sec_new="$p" ;;
      'rename from '*) sec_is_rename=yes; p="${line#rename from }"; no_quoted_path "$p"; sec_old="$p" ;;
      'rename to '*) sec_is_rename=yes; p="${line#rename to }"; no_quoted_path "$p"; sec_new="$p" ;;
      'copy from '*) sec_is_copy=yes; p="${line#copy from }"; no_quoted_path "$p"; sec_copy_src="$p" ;;
      'copy to '*) sec_is_copy=yes; p="${line#copy to }"; no_quoted_path "$p"; sec_new="$p" ;;
      'new file mode '*) sec_is_new=yes; check_mode "${line#new file mode }" ;;
      'deleted file mode '*) sec_is_del=yes; check_mode "${line#deleted file mode }" ;;
      'old mode '*) sec_mode_change=yes; check_mode "${line#old mode }" ;;
      'new mode '*) sec_mode_change=yes; check_mode "${line#new mode }" ;;
      'similarity index '* | 'dissimilarity index '*) ;;
      'index '*)
        m="${line##* }"
        case "$m" in index | *..*) ;; *) check_mode "$m" ;; esac
        ;;
      *) fail "unexpected line in patch header" ;;
    esac
  done <"$patch"
  [ "$state" = hunk ] && fail "patch ends inside a hunk"
  finish_section
}

if [ "${1:-}" = "--list-rules" ]; then
  list_rules "${2:-}"
  exit 0
fi

if [ "${1:-}" = "--base-scripts" ]; then
  BASE_SCRIPTS_FILE="${2:-}"
  [ -f "$BASE_SCRIPTS_FILE" ] || { echo "artifact-scan: --base-scripts needs a readable file" >&2; exit 2; }
  shift 2
fi

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
    *.patch|*patch.diff) forbidden_paths "$f" ;;
  esac
done

echo "artifact-scan: passed."
