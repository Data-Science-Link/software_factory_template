# Repo security baseline (factory template)

One-time setup per repo: copy the files from this template, merge the `.gitignore` block, add the CI workflows, then run **`scripts/harden-repo.sh`** as the owner (never factory agents). Rollout to other org repos is tracked in issue [#37](https://github.com/Data-Science-Link/software_factory_template/issues/37); this doc is the source of truth for *what* to enable.

## Public vs private (GitHub Free vs paid)

Verify limits on [GitHub’s docs](https://docs.github.com/en/get-started/learning-about-github/githubs-plans) before you assume a row applies to your repo.

| Control | What it blocks | Public repo (Free) | Private repo (Free) | Private + Pro / GHAS (paid options) |
| --- | --- | --- | --- | --- |
| **Dependabot alerts** | Known vulnerable dependencies | Yes ([Dependabot alerts](https://docs.github.com/en/code-security/dependabot/dependabot-alerts/about-dependabot-alerts)) | Yes for supported manifests | Yes |
| **Dependabot security updates** | Auto-PRs for CVE fixes | Yes ([configuring updates](https://docs.github.com/en/code-security/dependabot/dependabot-security-updates/configuring-dependabot-security-updates)) | Yes | Yes |
| **Dependabot version updates** | Drift on Actions / packages | Yes (`.github/dependabot.yml`) | Yes | Yes |
| **Secret scanning** | Committed tokens | Yes ([secret scanning](https://docs.github.com/en/code-security/secret-scanning/introduction/about-secret-scanning)) | **No** on Free ([Advanced Security](https://docs.github.com/en/get-started/learning-about-github/about-github-advanced-security) for private) | With GHAS / Secret Protection |
| **Push protection** | Pushing a secret | Yes on public when enabled | **No** on private Free | With GHAS |
| **Private vulnerability reporting** | Public zero-days | Yes ([private reporting](https://docs.github.com/en/code-security/security-advisories/working-with-repository-security-advisories/configuring-private-vulnerability-reporting-for-a-repository)) | N/A (use private channel) | Public repos |
| **CodeQL default setup** | Code vulnerabilities | Yes ([CodeQL](https://docs.github.com/en/code-security/code-scanning/introduction-to-code-scanning/about-code-scanning)) | Default setup targets public; private often needs GHAS | GHAS Code Security |
| **OSV-Scanner CI** | Known bad deps (report-only) | Optional | Yes (this template’s private fallback) | Optional |
| **Rulesets / branch protection** | Direct push to `main`, bad merges | Yes ([rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)) | **No** on private Free ([branch protection](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches) needs Pro or public) | Yes — use `scripts/protect-main.sh` or `harden-repo.sh` |
| **Pre-commit / CI gitleaks** | Secrets in commits | Yes (local + `secret-scan.yml`) | Yes | Yes |
| **Default `GITHUB_TOKEN` read-only** | Workflow over-permission | Yes ([Workflow permissions](https://docs.github.com/en/actions/security-for-github-actions/security-guides/automatic-token-authentication#permissions-for-the-github_token)) | Yes | Yes |
| **OpenSSF Scorecard** | Supply-chain hygiene signal | Yes (informational workflow) | Optional | Optional |

**Backstop when rulesets do not apply:** `scripts/install-hooks.sh` pre-push hook blocks pushes to `main`; factory merge gate still requires green `pr-check` and `gitleaks`.

## Files in this template

| Artifact | Role |
| --- | --- |
| `.github/dependabot.yml` | Weekly grouped updates for `github-actions` (add pip/npm ecosystems when the repo uses them). |
| `.github/workflows/secret-scan.yml` | CI gitleaks (pinned Actions, least privilege). |
| `.github/workflows/pr-check.yml` | Factory PR body gate. |
| `.github/workflows/workflow-lint.yml` | actionlint + zizmor on workflow changes. |
| `.github/workflows/codeql.yml` | CodeQL for **public** repos. |
| `.github/workflows/osv-scanner.yml` | OSV-Scanner for **private** repos (non-blocking). |
| `.github/workflows/scorecard.yml` | Scorecard for **public** repos (non-blocking). |
| `.github/rulesets/protect-main.json` | Required checks + merge rules (see issue [#46](https://github.com/Data-Science-Link/software_factory_template/issues/46)). |
| `scripts/protect-main.sh` | Owner applies ruleset to **this** clone’s remote. |
| `scripts/harden-repo.sh` | Owner applies settings + ruleset to **any** `owner/repo` (supports `--dry-run`, `--required-checks`). |
| `.github/CODEOWNERS` | Owner review on `.github/`, `scripts/`, `.factory/`, `opencode.json`. |
| `SECURITY.md` | Private reporting path. |
| `.gitignore` block | `.env*`, keys, credentials, downloaded tarballs. |
| `.factory/actions-security.md` | Threat model for OpenCode / Actions spike workflows. |

## Owner checklist (`scripts/harden-repo.sh`)

1. Log in to `gh` with **Administration** on the target repo (agents use a scoped token **without** Administration by design).
2. From a checkout that includes this template:  
   `bash scripts/harden-repo.sh --dry-run OWNER/REPO`  
   Review the pass/fail table.
3. Run without `--dry-run` when satisfied.
4. Per-repo CI check names (when not `pr-check,gitleaks`):  
   `bash scripts/harden-repo.sh --required-checks build,pytest,gitleaks,pr-check ORG/REPO`
5. If gitleaks history scan reports findings, fix or rotate with the owner **privately** — never paste secrets in issues or PRs.

Dependabot PRs are **not** auto-merged; they must pass the same required checks as other factory PRs.

## Workflow hardening rules

- Top-level `permissions: {}` in every workflow; grant only what each job needs.
- Pin third-party Actions to a **full commit SHA** (comment the human tag).
- Repo setting: default `GITHUB_TOKEN` **read** (enabled by `harden-repo.sh`).
- See `.factory/actions-security.md` for OpenCode-specific splits (agent vs publish jobs).

## Paid options (not required)

GitHub Advanced Security (Code Security, Secret Protection) on private repos is optional and paid — note only, not part of the Free baseline.
