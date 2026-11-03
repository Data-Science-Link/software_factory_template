# GitHub Actions + OpenCode + DeepInfra — security

Threat model and controls for the `/oc` spike workflow (`opencode-spike.yml`). **Not legal advice.**

## What we defend against

| Incident | Risk | Mitigation in this spike |
| --- | --- | --- |
| [opencode#11166](https://github.com/anomalyco/opencode/issues/11166) — GitHub Action posted raw env (including `GITHUB_TOKEN`, OIDC tokens, API keys) into PR comments | Credential theft | **Do not use** `anomalyco/opencode/github`. Split jobs: agent never gets write `GITHUB_TOKEN`; publish never gets `DEEPINFRA_API_KEY`. PR body built from scanned templates, not raw env dumps. |
| [GHSA-632h-h47v-g4x4](https://github.com/anomalyco/opencode/security/advisories/GHSA-632h-h47v-g4x4) — RCE via `opencode serve` `/global/upgrade` on npm installs | RCE on runner | **Never** run `opencode serve` or `opencode web`. Install pinned **GitHub release** tarball (≥ 1.18.33; spike pins 1.19.5), not npm `@latest`. |
| MCP OAuth RCE (fixed 1.18.33, no advisory) | RCE on Windows/WSL | Ubuntu runners only; `"mcp": {}`; `opencode run --pure`; no MCP OAuth flow. |
| Malicious npm skills (`opencode-skills-collection`, `agentic-awesome-skills`, Oct 2026) | Supply chain | No npm skill packages; `"skill": "deny"`; no `.opencode/plugins` in repo. |
| Prompt injection via issue text | Unwanted edits / exfil | Scope from owner comment only; patch cannot touch `.github/`, `opencode.json`, `requirements-factory.txt` (pinned dependencies are owner-only, so a run can't add or re-pin a package), owner-only `.factory/` files, other dot-paths, or any existing script (new scripts only; `--list-rules` in `scripts/opencode-artifact-scan.sh`); gitleaks + token-pattern scan on patch and logs. |
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
10. **Bot-opened PRs + `main` ruleset (#74):** a PR opened or pushed with `GITHUB_TOKEN` gets its `pull_request` runs (pr-check, gitleaks) in an approval-required state. On the PR, **Approve workflows to run**, or Grok Bot runs `scripts/factory-kick-checks.sh <PR>` (owner's gh login: close + reopen, only for open same-repo `oc/issue-<N>-<run_id>` PRs missing a required check). No PAT or GitHub App secret is added for this. `workflow_dispatch` / `repository_dispatch` / `workflow_run` are not used: GitHub does not evaluate checks from those events for pull requests or rulesets, and `workflow_run` runs on the default branch's commit.
11. **Spec file (#75):** the harness writes `factory/specs/issue-<N>.md` from the validated approved comment (hash-checked before and after the model runs, worker edits overwritten); publish re-fetches the comment with its own token, re-validates it with the pristine `opencode-build-context.py --print-spec`, and refuses a patch whose spec file differs. The publish jobs need `issues: read` for that re-fetch; until it is pasted, a 403 makes publish fall back to job A's `spec.md` (pristine checker + the `spec_sha256` job A recorded), labeled `checked by publish against job A's copy only` in the PR. Any other fetch error refuses. `factory-spec-check.py` rejects `\"` in front matter.
12. **Verification (#76, #80):** the worker shell stays git-only for build and fix runs (bash `*` deny in `opencode.json`), because any interpreter (python, dbt's `env_var()`, DuckDB) could read `DEEPINFRA_API_KEY` from the agent's environment. Instead `scripts/opencode-verify.sh` runs the spec's `## Verification` `bash` block after the model exits: scratch copy of the base commit plus the patch (scanned first), separate unprivileged user `ocverify` (via the runner's sudo) with `env -i`, so neither the key nor `/proc/<pid>/environ` of the runner's processes is readable; `timeout`, and a time budget so the job limit is never hit. The output is scanned (gitleaks, token patterns, the key value) before upload and again in publish, then pasted fenced and capped. **Residual risk:** the network is not blocked during verification (the spec's `pip install` needs it), so code from the patch could reach the internet with the repository contents; harden-runner stays in audit mode.
13. **PR body text from the model or from commands** is pasted only inside a fenced `text` block (``` → ''', `@` → `(at)`, `<!--` defanged, capped) by `scripts/opencode-text-block.sh`, and `pr-check` ignores fenced blocks.

## `/oc fix` on an existing PR (issue #55)

Proposed workflow `.github/workflows/opencode-fix.yml` (owner pastes it; workers can't edit `.github/`). Same two-job split and controls as above, plus:

1. **Trigger:** `issue_comment` on a **pull request**, `startsWith('/oc fix')`, same login + `OWNER` check. `opencode-spike.yml` ignores PR comments, so the two never both fire.
2. **PR guard** (`scripts/opencode-build-fix-context.py --check-pr`, run in both jobs): PR open, head repo = base repo and not a fork, head branch exactly `oc/issue-<N>-<run_id>`, base = default branch, head SHA well-formed. Job B passes the SHA job A used and refuses if it moved.
3. **Trusted code:** both jobs run scripts and `opencode.json` from the default-branch checkout; the PR head is a second checkout in `pr/` and none of its scripts run. Job A refuses if the PR head has a different `opencode.json` or a `.opencode/` dir (project config overrides the trusted one), or if the worker changed `.git/config` (a planted filter or hook would run on `git add`).
4. **Context:** only comments and reviews by the repo owner login with `author_association: OWNER`, posted after the head commit, each capped and the whole section capped, inside the untrusted-data block. Bot, collaborator and look-alike logins are dropped.
5. **Push:** `scripts/opencode-git-push-lease.sh` pushes `HEAD:refs/heads/<branch>` only, with `--force-with-lease=refs/heads/<branch>:<job A SHA>`, and only when HEAD is exactly one commit on that SHA. No plain force, no other ref, credentials via `gh auth git-credential` without writing git config.
6. **PR comment:** built from script facts (`opencode-run-facts.sh`, usage metrics); the worker note is capped, put in a text block with fences, `@` mentions and HTML comments defanged, and scanned with the rest of the body before posting.
7. **Checks:** a `GITHUB_TOKEN` push leaves pr-check and gitleaks waiting for approval (#74, control 10). Approve them on the PR or run `scripts/factory-kick-checks.sh <PR>` before merge so they run on the new head.
8. **Same worker shell and verification as build runs (#80):** `opencode.json` is shared (and the PR head may not bring its own), so the fix worker's shell is git-only like the build worker's; the harness runs the spec's Verification on the PR head plus the fix patch and pastes it into the PR comment. The comment's cost line says `Predicted cost: not predicted (fix run)`.

## If a secret leaks

1. **Rotate immediately:** DeepInfra → delete compromised Actions key → create new key (`sft-actions`) → update repo secret `DEEPINFRA_API_KEY`.
2. **Revoke GitHub exposure:** Delete any comment/PR body/log that contained material; cancel running workflows if needed.
3. **Review:** DeepInfra usage for the key; GitHub audit log for the repo.
4. **Document:** Comment on the issue with what rotated (no secret values).

## References

- Vision: `.factory/VISION.md` §13, §18 (2026-11-02 decisions).
- Workflow: `.github/workflows/opencode-spike.yml` or `.factory/workflows-to-install/opencode-spike.yml`.
