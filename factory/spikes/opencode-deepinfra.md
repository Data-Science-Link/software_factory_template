# Spike: OpenCode + DeepInfra on GitHub Actions

Part of [#38](https://github.com/Data-Science-Link/software_factory_template/issues/38). Parent issue: [#22](https://github.com/Data-Science-Link/software_factory_template/issues/22).

## Design (phase 1)

- **Harness:** OpenCode CLI `opencode run` (pinned release tarball, `--pure`, no `opencode serve` / web / official GitHub Action).
- **Model:** `deepinfra/deepseek-ai/DeepSeek-V4-Flash-0731` via `opencode.json` and `DEEPINFRA_API_KEY`.
- **Jobs:** `agent` (read-only GitHub token, DeepInfra key) → artifact scan → `publish` (write token, no DeepInfra key) → PR.
- **Trigger:** Owner-only `/oc…` comment on an **issue** (not a PR thread).

## Test plan (phase 2 — Michael)

| Step | What | Pass? |
| --- | --- | --- |
| 1 | Merge phase 1 PR; install workflow if staged under `.factory/workflows-to-install/` | |
| 2 | Add `DEEPINFRA_API_KEY` + Actions settings (see PR **Michael: what to do next**) | |
| 3 | Open trivial test issue; comment `/oc …` from `Data-Science-Link` | |
| 4 | Actions run green; PR opened by `github-actions[bot]` | |
| 5 | No secrets in logs, PR, or comments | |
| 6 | DeepInfra spend for run under ~$0.05 | |

## Results (fill after first real run)

| Field | Value |
| --- | --- |
| Date (UTC) | |
| Workflow run URL | |
| Target issue | |
| PR opened | |
| Actions billable minutes | |
| Wall time (approx) | |
| Tokens in | |
| Tokens cached | |
| Tokens out | |
| Usage source (command / file) | |
| Sample usage JSON (redacted) | |
| Cost (tokens × price table) | |
| Key spend delta (Actions key) | |
| DeepSeek V4 Flash tool calls OK? | |
| `pr-check` / `secret-scan` on harness PR? | |
| **Go / no-go** | |

## Security notes

See `.factory/actions-security.md`. OpenCode **≥ 1.18.33**; no MCP; no npm skill packages; no `anomalyco/opencode/github` action (env leak [#11166](https://github.com/anomalyco/opencode/issues/11166)).
