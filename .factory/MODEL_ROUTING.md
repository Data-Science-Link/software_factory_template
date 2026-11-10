# Model routing

## Factory runs (GitHub Actions + DeepInfra)

GitHub Actions workers (OpenCode + DeepInfra) pick models from **`.factory/models.yaml`**. That file is the **source of truth** for:

- Dated DeepInfra **standard-tier** prices (input, cached input, output per million tokens), with source URLs and `checked_at` dates
- **Token priors** per complexity (`simple`, `standard`, `complex`) for cost prediction
- Ordered **routing rules** for model selection (first match wins) plus a **checks** block (rules 6 and 8) applied after a model is picked (see `.factory/VISION.md` §10)
- **Budget** caps (`deepinfra_monthly_limit_usd`, per-issue cap and target, Actions minutes warning)

**Default worker model:** `deepseek-ai/DeepSeek-V4-Flash-0731` for most runs. **Architect:** `deepseek-ai/DeepSeek-V4-Pro-0813` for `/oc spec` runs on **high-risk** issues (rule 2, listed before rule 1), plus one retry after Flash fails on standard work (rule 4). `/oc spec` on any other issue uses V4 Flash (rule 9, a trial from #64; Michael, 2026-11-07). The spec run counts as high risk only from a structured signal (#153): the issue has the `risk:high` label, or the guidance starts with `risk: high` (`/oc spec risk: high ...`); prose such as "high-risk" or "risk high" in the issue or comment never routes. No issue context or label list fails closed to V4 Pro. **Complex builder:** `Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo` for high-risk or complex `/oc` builds and `/oc fix` runs (rule 1, #128). It is a fast non-thinking coder (about 2–4 s per tool turn vs about 35 s on V4 Pro), and the spec already holds the hard thinking. It is also the **fallback** when DeepSeek hits tool-call or reasoning-format errors (rule 5).

Scripts read `models.yaml` directly; do not duplicate prices in this file.

**How a run gets its model (run start, #91/#92).** `/oc` and `/oc fix` never let the worker pick. Before OpenCode is installed, the workflow's run start step (`scripts/factory-run-start.sh` → `scripts/factory-run-start.py`) routes the model and checks the cap, and the agent step passes that exact id to OpenCode as a fixed `--model` (`OC_MODEL`; the agent scripts refuse a missing id or one not listed here). The DeepInfra key is only in the agent step.

- **Inputs:** the approved spec (for `/oc fix`, the linked issue's spec), so risk and complexity pick rules 1–3 (rules 2 and 9 only match `work_type: spec`, which build specs don't use). A run with no approved spec is refused.
- **Retry and fallback:** read from the #84 failure comments (`github-actions[bot]` only) posted since the owner's previous trigger of the same kind. If the worker step failed on DeepSeek with a tool-call or reasoning-format error (`scripts/factory-classify-failure.py` on the log), the next run uses Qwen3-Coder (rule 5). If it failed on Flash on standard work, the next run uses Pro once (rule 4). If that Pro retry fails too, routing goes back to the spec's own rule. Retry keys in a spec are ignored; an owner who wants a model sets `model` + `model_override_reason`.
- **Cap:** prior spend on the issue (run records) plus the predicted cost must stay under `budget.issue_cap_usd`. A refusal stops the job and the notify job posts the reason, with "no DeepInfra spend".
- `/oc spec` keeps its own preflight in `scripts/opencode-spec-run.sh` (rule 2 V4 Pro for high risk, else rule 9 V4 Flash; predicted cost under the cap).
- **Over-target gate:** when the spec's own build prediction is above `budget.issue_target_usd` ($0.15), run start refuses (`over_target_unapproved`) unless the approved spec has `over_target_approved_by: michael`, whatever the risk. Michael sets it with `factory-approve-spec.py ... --approved-by michael --over-target-ok`. The draft comment's first line says `Over $0.15 target: needs Michael's approval`. Harness retries and fallbacks (rules 4 and 5) don't need a second approval.

**Spend rules (unchanged):** never enable on-demand spend (Cursor or elsewhere). Workers and the manager stay within the issue cap ($1 hard, $0.15 target, above which Michael approves explicitly) and the Actions-only DeepInfra key limit ($10/month per `.factory/DECISIONS.md`).

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
