# Model routing

## Factory runs (GitHub Actions + DeepInfra)

GitHub Actions workers (OpenCode + DeepInfra) pick models from **`.factory/models.yaml`**. That file is the **source of truth** for:

- Dated DeepInfra **standard-tier** prices (input, cached input, output per million tokens), with source URLs and `checked_at` dates
- **Token priors** per complexity (`simple`, `standard`, `complex`) for cost prediction
- Ordered **routing rules** (first match wins; see `.factory/VISION.md` §10)
- **Budget** caps (`deepinfra_monthly_limit_usd`, per-issue cap and target, Actions minutes warning)

**Default worker model:** `deepseek-ai/DeepSeek-V4-Flash-0731` for most runs. **Escalation:** `deepseek-ai/DeepSeek-V4-Pro-0813` for high risk, complex work, `/oc spec` runs, and one retry after Flash fails on standard work. **Fallback:** `Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo` when DeepSeek hits tool-call or reasoning-format errors.

Scripts such as `scripts/factory-predict-cost.py` and the routing helper (#27) read `models.yaml` directly; do not duplicate prices in this file.

**Spend rules (unchanged):** never enable on-demand spend (Cursor or elsewhere). Workers and the manager stay within the issue cap ($1 hard, $0.10 target) and the Actions-only DeepInfra key limit ($10/month per `.factory/DECISIONS.md`).

---

## Cursor cloud agents (Grok Bot manager + backup workers)

How the factory manager picks a model for each **Cursor cloud agent** it launches. The goal is the cheapest model that can do the job well, with escalation only when needed. Each repo may tune this table; keep the structure.

Defaults below assume **Cursor Pro+** (as of 2026-10). Cursor has two monthly pools:
- **Cursor Models** (Grok 4.7 / 4.6 / 4.5, Composer 2.5): much larger included allowance; use first.
- **Other Models** (third-party: Claude, GPT, Gemini, …): small allowance at API prices; exceptions only.

Prices per million tokens (input / output): Composer 2.5 $0.50 / $2.50 · Grok 4.7 $2 / $6 · Claude Opus 5.5 $4 / $20 · GPT-5.6 Sol $4 / $20. Check https://cursor.com/docs/models when updating.

## Routing table

| Work | Model (pin it) | Pool |
|---|---|---|
| **Simple**: docs, typos, issue filing, rebases, Dependabot, playbook syncs | `composer-2.5` | Cursor |
| **Standard**: features, bug fixes, UI | `composer-2.5`; escalate to `grok-4.7` (effort medium) after one failed attempt | Cursor |
| **Complex**: workflows, algorithms (clustering, ML), data stores, security, multi-file refactors, tech specs | `grok-4.7` (effort high) | Cursor |
| **Writing**: product specs, roadmap, methodology / user-facing copy | `grok-4.7` (effort medium) | Cursor |
| **Agent review** | A different model than the builder (e.g. Grok reviews Composer work) | Cursor |
| **Stuck after two Cursor-model attempts**, or a second opinion on high-risk work | `claude-opus-5-5` or `gpt-5.6-sol` | Other — only if the pool has room or a human approves |

## Cost rules

0. **Rate complexity first.** Every issue gets a triage line on the issue and in the PR body (`Complexity: simple|standard|complex — reason; Risk: …; Model: …`) before any launch. Complexity words are separate from risk class (trivial/normal/high), which sets the merge gate. When in doubt between standard and complex, pick complex (`grok-4.7`): a failed cheap attempt costs more than the difference.
1. **Always pin the model** on every launch. Don't leave it on Auto — Auto can route to a third-party model and draw from Other Models.
2. **No Fast mode, no long-context (500k / 1M) variants** unless a human asks; both roughly double the price.
3. Escalate one step at a time, and say why on the issue.
4. Record the model used and the cloud agent run ID(s) in the PR body (AI disclosure). The run IDs let dev cost be matched to each PR later. A cloud agent's token may not be able to comment; if so, the manager posts that agent's reviews and reports.

5. **Outside coding agents** (outside the default harness) need the owner's explicit cost yes; then add their row here and an entry in DECISIONS before first use. They run the same loop and gates.

## When limits are hit

- **Other Models used up** → keep working on Cursor Models only. Don't ask; don't enable on-demand.
- **Cursor Models used up** → finish nothing new. Tell the human and ask: enable on-demand spending, or wait for the monthly reset.
- **Never turn on on-demand spending yourself.**

## Human's editor default

Recommended Cursor default model: `composer-2.5` (cheapest, Cursor pool, and the fallback for any unpinned launch). Switch to Grok 4.7 by hand for hard work.

## Local open-weights harness (retired as default, optional)

**Status:** Retired as the default worker path (see `.factory/VISION.md` §14–15). Actions + DeepInfra (`/oc run`) is the standard. This section remains for optional desktop Cursor runs when needed.

The human runs desktop Cursor locally with their own key for an OpenAI-compatible provider and picks the model the issue's handoff block names (see `skills/local-open-weights-run.md`). Default filled-in provider: **DeepInfra** (base URL `https://api.deepinfra.com/v1/openai`). Same loop, review and human gates as cloud runs; only the harness and model change.

**Cloud vs local:** cloud agents ignore the Local open-weights line in an issue's handoff block and use the model they were launched with. Local agents (Cursor desktop or another harness on the human's machine using an open-weights provider such as DeepInfra) use the Local open-weights model the handoff block names and follow `skills/local-open-weights-run.md`.

**Default model:** `Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo` for every tier and all agentic runs (approved by the human, 2026-10-27). The other rows are kept but each needs a test first.

| Use | DeepInfra model ID (pin it) | Price / 1M tokens (in / out) | Status |
|---|---|---|---|
| **Default — every tier (S / M / L), all agentic runs** | `Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo` | $0.30 / $1.00 | **Default** |
| **S** — simple | `deepseek-ai/DeepSeek-V4-Flash` | $0.09 / $0.18 | Needs test¹ |
| **M** — standard writing | `moonshotai/Kimi-K2.6` | $0.75 / $3.50 | Needs test¹ |
| **L** — complex, high-risk code, specs, user-facing / high-stakes writing | `deepseek-ai/DeepSeek-V4-Pro` | $1.30 / $2.60 | Needs test¹ |

¹ **Needs test:** known Cursor custom-key bug - reasoning_content not returned after tool calls, thinking-mode DeepSeek V4/Kimi fail with 400 (Cursor staff, Jul 2026: https://forum.cursor.com/t/the-deepseek-v4-pro-api-cannot-be-used-normally/159042). Use only after a short local test with thinking off passes.

Checked 2026-10-27 on https://deepinfra.com/models (model pages) and https://api.deepinfra.com/v1/openai/models. Re-check IDs and prices before relying on them; providers retire models.

**Caching and context.** DeepInfra prefix caching is automatic (https://docs.deepinfra.com/chat/prompt-caching), so keep the shared prefix stable: put the handoff prompt first and keep it stable, with no timestamps; don't switch models, rules or tools mid-run; keep issues small; start a new chat at about 60-70% of the context window; verify caching with `usage.prompt_tokens_details.cached_tokens` in the API response and the DeepInfra usage page.

- **Strongest tier for high stakes.** Specs, user-facing or high-stakes writing and high-risk work use the **L** row once it has passed the local test; until then they run on the default model and keep the full review and human gates.
- **Per-issue budget** (owner, 2026-10-28): each issue aims for under $0.10 of provider spend; complex (L) issues may go higher but never above a hard cap of $1 per issue. Split any issue likely to need more. When spend gets close to $1, the local agent or human stops and comments on the issue with the spend so far.
- Pin the model ID exactly as listed; no long-context or priority tiers unless a human asks.
- The API key lives only in the human's local Cursor settings or environment — **never** in the repo, an issue, or a PR.
