#!/usr/bin/env bash
# Installs two git hooks. Run once per clone. Safe to run again.
#   pre-commit: runs gitleaks on staged changes and blocks the commit if it
#               finds a secret (or if gitleaks isn't installed).
#   pre-push:   blocks pushes to the default branch (main/master); changes
#               reach main only through a pull request.
# An existing hook that this script didn't write is kept as <hook>.local and
# still runs. See .factory/skills/local-agent-safety.md.
set -euo pipefail

MARKER="# installed-by: scripts/install-hooks.sh"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "install-hooks: run this inside a git clone." >&2
  exit 1
fi

hooks_dir="$(git rev-parse --git-path hooks)"
mkdir -p "$hooks_dir"

# write_hook NAME: reads the hook body from stdin and installs it.
write_hook() {
  local name="$1" hook="$hooks_dir/$1" backup
  if [ -f "$hook" ] && ! grep -qF "$MARKER" "$hook"; then
    backup="$hooks_dir/$name.local"
    if [ -e "$backup" ]; then
      backup="$hooks_dir/$name.backup-$(date +%Y%m%d%H%M%S)"
    fi
    mv "$hook" "$backup"
    echo "install-hooks: moved your existing $name hook to $backup"
  fi
  { echo "#!/usr/bin/env bash"; echo "$MARKER ($name)"; cat; } > "$hook"
  chmod +x "$hook"
  echo "install-hooks: $name hook installed at $hook"
}

write_hook pre-commit <<'HOOK'
# Blocks the commit if gitleaks finds a secret in the staged changes.
set -euo pipefail

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "pre-commit: gitleaks is not installed, so this commit is blocked." >&2
  echo "  Install it, then commit again:" >&2
  echo "  macOS:  brew install gitleaks" >&2
  echo "  Linux:  download the linux_x64 release from https://github.com/gitleaks/gitleaks/releases" >&2
  echo "          and put the gitleaks binary on your PATH" >&2
  exit 1
fi

# gitleaks v8.19+ uses "git --pre-commit --staged"; older versions use "protect --staged".
if gitleaks git --help >/dev/null 2>&1; then
  scan=(gitleaks git --pre-commit --staged --redact --verbose)
else
  scan=(gitleaks protect --staged --redact --verbose)
fi

if ! "${scan[@]}"; then
  echo "" >&2
  echo "pre-commit: gitleaks found a possible secret (shown redacted above). Commit blocked." >&2
  echo "  Remove it from the staged files, then commit again. Keep keys in .env (gitignored)." >&2
  exit 1
fi

# Run the hook that was here before, if any.
local_hook="$(git rev-parse --git-path hooks)/pre-commit.local"
if [ -x "$local_hook" ]; then
  "$local_hook" "$@"
fi
HOOK

write_hook pre-push <<'HOOK'
# Blocks pushes to the default branch (main/master). Open a PR instead.
# Human-only override: FACTORY_ALLOW_MAIN_PUSH=1 git push ...  (agents never use it)
set -euo pipefail

remote="${1:-origin}"
input="$(cat)"

protected=" refs/heads/main refs/heads/master "
default="$(git symbolic-ref --quiet "refs/remotes/$remote/HEAD" 2>/dev/null || true)"
if [ -n "$default" ]; then
  protected="$protected refs/heads/${default#refs/remotes/$remote/} "
fi

if [ "${FACTORY_ALLOW_MAIN_PUSH:-}" != "1" ]; then
  while read -r _local_ref _local_sha remote_ref _remote_sha; do
    [ -n "${remote_ref:-}" ] || continue
    case "$protected" in
      *" $remote_ref "*)
        echo "Pushes to main are blocked. Open a PR instead." >&2
        echo "  (blocked: push to ${remote_ref#refs/heads/} on $remote)" >&2
        exit 1
        ;;
    esac
  done <<<"$input"
fi

# Run the hook that was here before, if any.
local_hook="$(git rev-parse --git-path hooks)/pre-push.local"
if [ -x "$local_hook" ]; then
  printf '%s\n' "$input" | "$local_hook" "$@"
fi
HOOK

if command -v gitleaks >/dev/null 2>&1; then
  echo "install-hooks: found gitleaks $(gitleaks version 2>/dev/null || echo "(version unknown)")."
else
  echo "install-hooks: gitleaks is not installed yet. Commits are blocked until it is:" >&2
  echo "  macOS:  brew install gitleaks" >&2
  echo "  Linux:  download the linux_x64 release from https://github.com/gitleaks/gitleaks/releases" >&2
  echo "          and put the gitleaks binary on your PATH (or: brew install gitleaks)" >&2
fi
