#!/usr/bin/env bash
# Installs a git pre-commit hook that runs gitleaks on staged changes and
# blocks the commit if it finds a secret. Run once per clone. Safe to run again.
# See .factory/skills/local-agent-safety.md.
set -euo pipefail

MARKER="# installed-by: scripts/install-hooks.sh (gitleaks pre-commit)"

install_help() {
  echo "  macOS:  brew install gitleaks" >&2
  echo "  Linux:  download the linux_x64 release from https://github.com/gitleaks/gitleaks/releases" >&2
  echo "          and put the gitleaks binary on your PATH (or: brew install gitleaks)" >&2
}

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "install-hooks: run this inside a git clone." >&2
  exit 1
fi

hooks_dir="$(git rev-parse --git-path hooks)"
hook="$hooks_dir/pre-commit"
mkdir -p "$hooks_dir"

# Keep any existing hook that we didn't write; ours runs it after the scan.
if [ -f "$hook" ] && ! grep -qF "$MARKER" "$hook"; then
  backup="$hooks_dir/pre-commit.local"
  if [ -e "$backup" ]; then
    backup="$hooks_dir/pre-commit.backup-$(date +%Y%m%d%H%M%S)"
  fi
  mv "$hook" "$backup"
  echo "install-hooks: moved your existing pre-commit hook to $backup"
fi

cat > "$hook" <<HOOK
#!/usr/bin/env bash
$MARKER
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

if ! "\${scan[@]}"; then
  echo "" >&2
  echo "pre-commit: gitleaks found a possible secret (shown redacted above). Commit blocked." >&2
  echo "  Remove it from the staged files, then commit again. Keep keys in .env (gitignored)." >&2
  exit 1
fi

# Run the hook that was here before, if any.
local_hook="\$(git rev-parse --git-path hooks)/pre-commit.local"
if [ -x "\$local_hook" ]; then
  "\$local_hook" "\$@"
fi
HOOK
chmod +x "$hook"
echo "install-hooks: gitleaks pre-commit hook installed at $hook"

if command -v gitleaks >/dev/null 2>&1; then
  echo "install-hooks: found gitleaks $(gitleaks version 2>/dev/null || echo "(version unknown)")."
else
  echo "install-hooks: gitleaks is not installed yet. Commits are blocked until it is:" >&2
  install_help
fi
