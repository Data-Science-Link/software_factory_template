# GitHub Actions + OpenCode + DeepInfra — security

Threat model and controls for the `/oc` spike workflow (`opencode-spike.yml`). **Not legal advice.**

## What we defend against

| Incident | Risk | Mitigation in this spike |
| --- | --- | --- |
| [opencode#11166](https://github.com/anomalyco/opencode/issues/11166) — GitHub Action posted raw env (including `GITHUB_TOKEN`, OIDC tokens, API keys) into PR comments | Credential theft | **Do not use** `anomalyco/opencode/github`. Split jobs: agent never gets write `GITHUB_TOKEN`; publish never gets `DEEPINFRA_API_KEY`. PR body built from scanned templates, not raw env dumps. |
| [GHSA-632h-h47v-g4x4](https://github.com/anomalyco/opencode/security/advisories/GHSA-632h-h47v-g4x4) — RCE via `opencode serve` `/global/upgrade` on npm installs | RCE on runner | **Never** run `opencode serve` or `opencode web`. Install pinned **GitHub release** tarball (≥ 1.18.33; spike pins 1.19.5), not npm `@latest`. |
| MCP OAuth RCE (fixed 1.18.33, no advisory) | RCE on Windows/WSL | Ubuntu runners only; `"mcp": {}`; `opencode run --pure`; no MCP OAuth flow. |
| Malicious npm skills (`opencode-skills-collection`, `agentic-awesome-skills`, Oct 2026) | Supply chain | No npm skill packages; `"skill": "deny"`; no `.opencode/plugins` in repo. |
| Prompt injection via issue text | Unwanted edits / exfil | Scope from owner comment only; patch cannot touch `.github/`, dotfiles, or `scripts/protect-main.sh`; gitleaks + token-pattern scan on patch and logs. |
| Script injection in Actions | Runner compromise | Pass `github.event.comment.body` only through `env:`; never interpolate `${{ github.event.* }}` into `run:` scripts. |

## Controls (checklist)

1. **Trigger:** `issue_comment` + `startsWith('/oc')` + `user.login == 'Data-Science-Link'` + `author_association == 'OWNER'` + issue (not PR).
2. **Top-level `permissions: {}`**; job-scoped least privilege.
3. **Agent job:** `contents: read` only; no `id-token`; checkout `persist-credentials: false`; unset `GITHUB_TOKEN` before OpenCode; only secret `DEEPINFRA_API_KEY`.
4. **Publish job:** `contents: write`, `pull-requests: write` only; no DeepInfra secret.
5. **Artifact gate:** `scripts/opencode-artifact-scan.sh` + gitleaks on patch, summary, and log (fail closed; redacted output only).
6. **OpenCode config:** `webfetch` / `websearch` / `skill` denied; dangerous bash denied; API key via `{env:DEEPINFRA_API_KEY}` only.
7. **Pinned** third-party Actions (full SHA) and pinned OpenCode version with SHA-512.
8. **Optional:** `step-security/harden-runner` in **audit** mode first (egress visibility before block mode).
9. **No merge** step; no push to `main`; concurrency per issue; job timeout.
10. **Bot-opened PRs + `main` ruleset:** PRs from `github-actions[bot]` (publish job) are first-time contributors from GitHub’s workflow perspective. On the protected `main` branch (`pr-check` + gitleaks required, strict), open the PR → **Approve workflows to run** (or org/repo **Actions → General → Fork pull request workflows** / workflow approval settings as configured) so `pr-check` and gitleaks execute on the harness PR before merge.

## If a secret leaks

1. **Rotate immediately:** DeepInfra → delete compromised Actions key → create new key (`sft-actions`) → update repo secret `DEEPINFRA_API_KEY`.
2. **Revoke GitHub exposure:** Delete any comment/PR body/log that contained material; cancel running workflows if needed.
3. **Review:** DeepInfra usage for the key; GitHub audit log for the repo.
4. **Document:** Comment on the issue with what rotated (no secret values).

## References

- Vision: `.factory/VISION.md` §13, §18 (2026-11-02 decisions).
- Workflow: `.github/workflows/opencode-spike.yml` or `.factory/workflows-to-install/opencode-spike.yml`.
