# Skill: local-open-weights-run

**If you are a local agent running this issue, use the Local open-weights model from the issue's handoff block. Cloud agents never use this file.**

Use when cloud agents can't run (e.g. Cursor usage is used up) and the human works an issue in **desktop Cursor** (or another local harness) on a **Local open-weights** model with their own OpenAI-compatible provider key. Default provider: DeepInfra (`MODEL_ROUTING.md` → Local open-weights harness).

**Model:** default `Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo` (a non-thinking coder model). Other models in `MODEL_ROUTING.md` are marked *Needs test*; use one only after a short local test with thinking off passes. Keep the handoff prompt first and unchanged, don't switch models, rules or tools mid-run, and start a new chat at about 60-70% of context (`MODEL_ROUTING.md` → Caching and context).

## One-time setup (human)

**Required first:** do the one-time setup in `local-agent-safety.md` (secret-scan hook, scoped `gh` token, command approvals). Don't start a local run until it's done.

1. Create a provider API key (DeepInfra: account dashboard → API keys).
2. In desktop Cursor, open **Cursor Settings → Models**, add the key as the OpenAI API key, turn on the OpenAI base-URL override with `https://api.deepinfra.com/v1/openai`, and add each model ID from `MODEL_ROUTING.md` as a custom model (name must match the ID exactly). Source: https://cursor.com/help/models-and-usage/api-keys (checked 2026-10-27); menu names change, so follow Cursor's current docs if they differ.
3. While the override is on, Cursor's own OpenAI-family models also route to that URL; turn it off to go back to Cursor models.
4. The key stays in local Cursor settings or env only. Never commit, paste or log it.
5. **(One-time, per computer)** Add `export DEEPINFRA_API_KEY=<DeepInfra key>` to `~/.zshrc` (or your shell's rc file), then restart Cursor or start a new terminal. The key name (visible on DeepInfra's API keys page) is the one to pass as the argument to `deepinfra-cost.sh`. Verify with: `[ -n "$DEEPINFRA_API_KEY" ] && echo "key is set" || echo "key is not set"`.

## Per issue

1. Open the repo in desktop Cursor and pick the model the issue's **handoff block** names on its `Local open-weights` line.
2. Tell the agent: `do issue #N` (or paste the handoff prompt).
3. The agent syncs to latest default branch, branches, follows `factory-loop.md`, and opens a PR that references the issue. The PR body has `AI disclosure: harness local Cursor + <provider>; model <model ID>`, a `Cost:` line (e.g. `Cost: $0.04 on DeepInfra`), and a `Caching:` line (e.g. `Caching: no - no cached_input tokens reported`); the PR check fails without them.
4. Review, CI and human gates are unchanged. The reviewing bot posts a `Factory review` comment on the PR (`review-local-pr.md`).
5. **Fixes:** when the owner says "address the review on PR #N", the agent runs `gh pr view N --comments`, fixes each numbered item in the latest `Factory review`, pushes to the same branch, and replies on the PR with what changed, item by item.
6. **Budget:** target under $0.10 per issue (complex may scale up), hard cap $1 (`MODEL_ROUTING.md` → Per-issue budget). After the run, check spend on the provider's usage page (e.g. DeepInfra's) and note it on the issue. If spend nears $1, stop and comment on the issue instead of continuing.
7. **Cost check:** After the PR is open (before asking for review), run `bash scripts/deepinfra-cost.sh end "<key-name>"` from the repo root. Paste its output lines (`Cost:` and `Caching:`) into the PR body's `Cost:` and `Caching:` fields. The `start` should have been run just before the agent began working (step 0 of the work-for-agent list).
