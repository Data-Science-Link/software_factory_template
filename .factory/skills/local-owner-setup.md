# Skill: local-owner-setup

**One-time checklist for the human owner, on each computer that runs local open-weights issues (desktop Cursor + DeepInfra).** About 10 minutes. The owner does these steps, never an agent. Do `local-agent-safety.md` too; this list points to it where they overlap.

## 1. gh CLI

1. Install `gh` (https://cli.github.com).
2. Log in with a fine-grained token: only the factory repos; Contents, Issues and Pull requests read/write; Metadata read; no Workflows, no Administration. Steps: `local-agent-safety.md` part 2.
3. Run `gh auth setup-git` so `git push` uses the same login.
4. Check: `gh auth status`.

## 2. Hooks

1. Install gitleaks (`brew install gitleaks`, or the release binary on your PATH).
2. In each clone, run `scripts/install-hooks.sh` (pre-commit secret scan, pre-push block on `main`). Test it as in `local-agent-safety.md` part 1.

## 3. DeepInfra key for the cost script

Cursor's settings key isn't visible to terminal commands, so the cost script needs its own copy.

1. Add to `~/.zshrc` (placeholders; use your own values):
   ```
   export DEEPINFRA_API_KEY=<your DeepInfra key>
   export FACTORY_DEEPINFRA_KEY_NAME=<the key's name on DeepInfra's API keys page>
   ```
2. Restart Cursor so its terminals pick them up.
3. Check without printing the key: `[ -n "${DEEPINFRA_API_KEY:-}" ] && echo set || echo "not set"`.

Trade-off: the key sits in a plain-text file in your home folder, and any local command can read it. Stronger option: keep it in the macOS Keychain and load it in `~/.zshrc` with `security find-generic-password -w -s <service name>`.

Never `cat ~/.zshrc` while an agent is running, and never paste the key into chat, an issue or a PR.

## 4. Spending limit on the key

In the DeepInfra dashboard, set a spending limit on the factory key. It caps the worst case if the key leaks and backs up the $1 per-issue cap.

## 5. Antivirus / endpoint protection

Keep it on (for example Bitdefender). If it blocks normal dev tools, add narrow exceptions only: the repo folder and the tools the loop uses (`git`, `gh`, `gitleaks`, the shell Cursor runs). Don't turn protection off.

## 6. Cursor command approvals

1. Allowlist only the commands in `local-open-weights-run.md` → Command allowlist. Never allow `gh pr merge`, any push to `main`, or `--no-verify`.
2. **Sandbox and Keychain:** Cursor's agent sandbox can't read the macOS Keychain, so `gh` says the token is invalid inside the agent even when `gh auth status` works in your terminal. Approve `gh` and `git push origin issue-*` (and `bash scripts/factory-cost.sh`, which calls `gh`) to run outside the sandbox one command at a time, or allowlist only those. Don't turn the sandbox off or auto-approve everything, and don't put the GitHub token in `~/.zshrc` (it covers all repos).

## Done when

`gh auth status` works, a fake-secret commit is blocked, the key check prints `set`, the key has a spending limit, and `do issue N` on a small issue runs without asking for anything outside the allowlist.
