# Repo security baseline (factory template)

One-time setup per repo: copy the config from this template, then run **`scripts/harden-repo.sh`** as the **owner** (never factory agents). Rollout to other org repos is tracked in issue [#37](https://github.com/Data-Science-Link/software_factory_template/issues/37); this doc is the source of truth for *what* to enable.

**Related docs:** [`SECURITY.md`](../SECURITY.md) (private reporting path), [`.factory/actions-security.md`](actions-security.md) (OpenCode / Actions threat model), [`scripts/protect-main.sh`](../scripts/protect-main.sh) (ruleset-only owner step).

## Checklist (owner, once per repo)

1. Copy template artifacts (`.github/`, `scripts/`, `.factory/`, hooks) into the repo.
2. Log in to `gh` with **Administration** on the target repo (agents use a scoped token **without** Administration by design — see [`.factory/skills/local-agent-safety.md`](skills/local-agent-safety.md)).
3. From a checkout that includes this template:
   ```bash
   bash scripts/harden-repo.sh --dry-run
   # or: bash scripts/harden-repo.sh --dry-run --repo OWNER/REPO
   ```
   Review the pass / skip / fail table.
4. Run without `--dry-run` when satisfied.
5. If other required checks apply (not `pr-check,gitleaks`):
   ```bash
   bash scripts/harden-repo.sh --required-checks build,pytest,gitleaks,pr-check --repo ORG/REPO
   ```
   Repos with **no CI checks yet** must not enable required checks (every PR would stay red). Use `--required-checks none` or `--skip-branch-protection` on `harden-repo.sh` until CI exists; `protect-main.sh` accepts `--skip` for the ruleset-only path.
6. If the full-history gitleaks row reports findings, fix or rotate with the owner **privately** — never paste secrets in issues or PRs.
7. Run `scripts/protect-main.sh` if you only need the ruleset step on **this** clone's remote (same JSON as `harden-repo.sh`):
   ```bash
   bash scripts/protect-main.sh --dry-run                    # print payload (no gh api)
   bash scripts/protect-main.sh --checks pr-check,gitleaks  # override check contexts
   bash scripts/protect-main.sh --verify --repo ORG/REPO  # read-back: strict checks, PR rule, no bypass
   ```

Dependabot PRs are **not** auto-merged; they must pass the same required checks as other factory PRs ([`.factory/actions-security.md`](actions-security.md) §Dependabot).

## Public vs private (GitHub Free vs paid)

Verify limits on [GitHub's plans](https://docs.github.com/en/get-started/learning-about-github/githubs-plans) before you assume a row applies to your repo.

| Control | What it protects against | Public repo (Free) | Private repo (Free) | Private + Pro / GHAS (paid) |
| --- | --- | --- | --- | --- |
| **Dependabot alerts** | Known vulnerable dependencies | Yes ([about Dependabot alerts](https://docs.github.com/en/code-security/dependabot/dependabot-alerts/about-dependabot-alerts)) | Yes for supported manifests | Yes |
| **Dependabot security updates** | Unpatched CVEs in deps | Yes ([configuring security updates](https://docs.github.com/en/code-security/dependabot/dependabot-security-updates/configuring-dependabot-security-updates)) | Yes | Yes |
| **Dependabot version updates** | Stale Actions / package pins | Yes (`.github/dependabot.yml` in template) | Yes | Yes |
| **Secret scanning** | Committed tokens in git | Yes ([about secret scanning](https://docs.github.com/en/code-security/secret-scanning/introduction/about-secret-scanning)) | **No** on Free ([Advanced Security](https://docs.github.com/en/get-started/learning-about-github/about-github-advanced-security) for private) | GHAS / Secret Protection |
| **Push protection** | Pushing a live secret | Yes when enabled (public) | **No** on private Free | GHAS |
| **Private vulnerability reporting** | Public disclosure of 0-days | Yes ([configure private reporting](https://docs.github.com/en/code-security/security-advisories/working-with-repository-security-advisories/configuring-private-vulnerability-reporting-for-a-repository)) | N/A (use private channel in `SECURITY.md`) | Public repos |
| **CodeQL** | Code-level vulnerabilities | Default setup on public ([about CodeQL](https://docs.github.com/en/code-security/code-scanning/introduction-to-code-scanning/about-code-scanning)) | Usually needs GHAS on private | GHAS Code Security |
| **CI gitleaks** (`secret-scan.yml`) | Secrets in new commits/PRs | Yes | Yes | Yes |
| **Local gitleaks hook** | Secrets before commit | Yes (`scripts/install-hooks.sh`) | Yes | Yes |
| **Full-history gitleaks** (`harden-repo.sh`) | Secrets in old commits | Owner scan in script | Same | Same |
| **SHA-pinned Actions** | Supply-chain tag moves | Required in factory workflows | Same | Same |
| **Default `GITHUB_TOKEN` read-only** | Over-privileged workflows | Yes ([token permissions](https://docs.github.com/en/actions/security-for-github-actions/security-guides/automatic-token-authentication#permissions-for-the-github_token)) | Yes | Yes |
| **Rulesets / branch protection** | Direct push to `main`, bad merges | Yes ([about rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)) | **Not enforced** on private Free ([protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)) | Pro or public |
| **CODEOWNERS** | Unreviewed changes to harness paths | File in template (separate #44 PR) | Same | Same |
| **OpenSSF Scorecard** | Supply-chain hygiene signal | Optional workflow (separate #44 PR) | Optional | Optional |

**Backstop when rulesets do not apply:** `scripts/install-hooks.sh` pre-push hook blocks pushes to `main`; the factory merge gate still requires green `pr-check` and `gitleaks` on PRs.

## Files in this template (reference)

| Artifact | Role |
| --- | --- |
| `.github/dependabot.yml` | Weekly grouped `github-actions` updates (`cooldown.default-days` only for that ecosystem). |
| `.github/workflows/secret-scan.yml` | CI gitleaks (pinned Actions, least privilege). |
| `.github/workflows/pr-check.yml` | Factory PR body gate. |
| `.github/rulesets/protect-main.json` | Required checks + merge rules. |
| `scripts/protect-main.sh` | Owner applies ruleset (`--dry-run`, `--verify`, `--checks`, `--repo`, `--skip`). |
| `scripts/harden-repo.sh` | Owner applies settings + ruleset to **any** `owner/repo` (`--dry-run`, `--repo`, `--required-checks`, `--skip-branch-protection`). |
| `SECURITY.md` | Private vulnerability contact path. |
| `.factory/actions-security.md` | Threat model for OpenCode / Actions workflows. |

Additional #44 items (workflow-lint, CodeQL, OSV-Scanner, Scorecard, `CODEOWNERS`, `.gitignore` block) may land in companion PRs; this doc and `harden-repo.sh` are safe to adopt first.

## Workflow hardening rules

- Top-level `permissions: {}` in every workflow; grant only what each job needs.
- Pin third-party Actions to a **full commit SHA** (comment the human tag).
- Repo setting: default `GITHUB_TOKEN` **read** (enabled by `harden-repo.sh`).
- See `.factory/actions-security.md` for OpenCode-specific splits (agent vs publish jobs).

## Paid options (not required)

GitHub Advanced Security (Code Security, Secret Protection) on private repos is optional and paid — note only, not part of the Free baseline.