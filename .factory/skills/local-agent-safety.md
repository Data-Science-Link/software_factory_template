# Skill: local-agent-safety

**One-time setup for the human owner, before any local agent (Cursor desktop or another harness on your machine) works an issue.** Takes about 10 minutes. A local agent runs terminal commands as you, so these steps limit what a mistake, or a prompt injected into an issue, web page or file it reads, can do.

## 1. Block secrets before they're committed

A pushed secret stays in git history and has to be revoked. The stop has to happen before the commit.

1. Install gitleaks: `brew install gitleaks` (macOS or Linux with Homebrew). On Linux without Homebrew, download the `linux_x64` release from https://github.com/gitleaks/gitleaks/releases and put `gitleaks` on your PATH.
2. In each clone, run once: `scripts/install-hooks.sh`. It adds a pre-commit hook that scans staged changes and blocks the commit if it finds a secret (values are redacted in the output). If you already had a pre-commit hook, it's kept as `pre-commit.local` and still runs. Running the script again is safe.
3. Test it with a fake GitHub token made on the fly (never a real key):
   ```
   printf 'token = "ghp_%s"\n' "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)" > leak-test.txt
   git add leak-test.txt && git commit -m "leak test"    # must be blocked
   git rm --cached -q leak-test.txt && rm leak-test.txt
   ```
   If the commit goes through, stop and fix the hook before running an agent (then `git reset HEAD~1` and delete the file; don't push it).
4. The `secret-scan` workflow runs the same scan on every push and PR as a backstop. It only reports; it can't un-push a secret.

## 2. Log `gh` in with a scoped token

Logged in as your full account, `gh` can do anything you can. Give it only what the factory needs.

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token.
2. Set an expiry (for example 30 or 90 days).
3. **Repository access:** only select repositories, and pick just the factory repos.
4. **Repository permissions:** Contents read/write, Pull requests read/write, Issues read/write, Metadata read-only. Leave everything else at No access, including **Administration** and **Workflows**. Without Workflows the agent can't push changes to `.github/workflows/`; that's intended, so CI changes go through you.
5. Save the token to a temporary file outside the repo. If `gh` is already logged in with your full account, run `gh auth logout` first. Then:
   ```
   gh auth login --with-token < /path/to/token-file
   rm /path/to/token-file
   gh auth status
   ```
6. When the token expires, make a new one the same way.

## 3. Keep command approvals on

- Keep the harness asking before it runs terminal commands. Don't turn on its auto-run or "run everything" setting (the name differs by harness and version; look for the command approval or auto-run setting).
- Fine to approve: `gh issue view`, `gh issue comment`, `gh pr create`, `git push` to a feature branch.
- Always yours to run, never approved for the agent: `gh pr merge`, any `gh repo …`, any `gh api …`, `git push` to `main`, force pushes (`--force`, `-f`), and anything that deletes (branches, files outside the change, repos, releases).
- If unsure, say no and run it yourself.

## 4. Protect `main` where you can

Add a branch protection rule or ruleset on `main` that requires a pull request. On private repos this needs a paid GitHub plan (see `FACTORY.md` → Private repos). If it isn't available, the factory merge gate is the control: only you, or the manager within its authority, merge.

## 5. Keep keys out of the repo

Never put keys or tokens in the repo, issues, PRs or chat. Keep them in your harness settings or a local `.env`, which is gitignored (`.env.example` holds names only, no values).
