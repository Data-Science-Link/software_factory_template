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
| 1 | Merge phase 1 PR; install workflow if staged under `.factory/workflows-to-install/` | x |
| 2 | Add `DEEPINFRA_API_KEY` + Actions settings (see PR **Michael: what to do next**) | x |
| 3 | Open trivial test issue; comment `/oc …` from `Data-Science-Link` | x |
| 4 | Actions run green; PR opened by `github-actions[bot]` | x |
| 5 | No secrets in logs, PR, or comments | x |
| 6 | DeepInfra spend for run under ~$0.05 | x |

## Results (fill after first real run)

### Run A — publish push fix validation (failed publish)

| Field | Value |
| --- | --- |
| Date (UTC) | 2026-11-02 |
| Workflow run URL | https://github.com/Data-Science-Link/software_factory_template/actions/runs/41405259087 |
| Target issue | #42 |
| PR opened | (none — publish failed at `git push`; fixed in PR #43) |
| Actions billable minutes | not measured (GitHub UI / billing export not captured in this spike) |
| Wall time (approx) | agent ~49s (07:16:48–07:17:37 UTC); publish failed ~7s |
| Tokens in | 17.7K |
| Tokens cached | 106.5K cache read |
| Tokens out | 1.2K |
| Usage source (command / file) | `opencode stats --models` in agent artifact `summary.md` |
| Sample usage JSON (redacted) | N/A — stats TUI only on runner |
| Cost (tokens × price table) | **$0.0029** (OpenCode-reported model row) |
| Key spend delta (Actions key) | not measured |
| DeepSeek V4 Flash tool calls OK? | yes (read/bash/glob/grep/write in stats) |
| `pr-check` / `secret-scan` on harness PR? | N/A (no PR) |
| **Go / no-go** | no-go for ship until publish push fixed |

### Run B — end-to-end success (harness PR #45)

| Field | Value |
| --- | --- |
| Date (UTC) | 2026-11-02 |
| Workflow run URL | https://github.com/Data-Science-Link/software_factory_template/actions/runs/41406322310 |
| Target issue | #42 |
| PR opened | #45 (merged e269539; closed #42) |
| Actions billable minutes | not measured |
| Wall time (approx) | agent ~41s; publish ~12s (run timestamps) |
| Tokens in | 17.3K |
| Tokens cached | 103.2K cache read |
| Tokens out | 1.2K |
| Usage source (command / file) | `opencode stats --models` in artifact `summary.md` |
| Sample usage JSON (redacted) | N/A |
| Cost (tokens × price table) | **$0.0028** (OpenCode-reported model row) |
| Key spend delta (Actions key) | not measured |
| DeepSeek V4 Flash tool calls OK? | yes |
| `pr-check` / `secret-scan` on harness PR? | required on `main` ruleset; bot PR needed **Approve workflows to run** before CI (see `.factory/actions-security.md`) |
| **Go / no-go** | **go** for `/oc` spike harness on trivial issues; factory cost metering remains #30 |

### `reasoning_content` / API errors

Runs A and B: no `reasoning_content` (or similar) errors in agent `opencode.log` artifacts; OpenCode completed tool calls without reported API shape failures.

### Still open on #22 (not closed by PR #52)

These Phase 2 report rows remain **not measured** or owner-only; track on #22 until filled:

- **Actions billable minutes** — not captured from GitHub billing/export for either run (wall times recorded only).
- **Sample usage JSON (redacted)** — harness used `opencode stats --models` TUI only; no `opencode export … --sanitize` JSON attached yet.
- **Cost vs key spend cross-check** — OpenCode-reported $0.0029 / $0.0028 not reconciled to DeepInfra dashboard spend for the Actions key on the same UTC window.
- **$10/month limit on Actions key** — owner must confirm limit is set on the Actions-only DeepInfra key (no key name or value in repo).

### Spike conclusion

Two-job split, pinned CLI, artifact scan, and scoped publish push work on a real `/oc` run. Token totals and OpenCode cost are available from `opencode stats --models` on the agent runner; harness PR bodies and Actions summaries must use parsed markdown (not raw TUI). Usage parsing and report gaps are addressed in PR #52; **Refs #22** until the rows above are closed.

## Security notes

See `.factory/actions-security.md`. OpenCode **≥ 1.18.33**; no MCP; no npm skill packages; no `anomalyco/opencode/github` action (env leak [#11166](https://github.com/anomalyco/opencode/issues/11166)).
