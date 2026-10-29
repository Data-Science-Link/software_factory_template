# Skill: local-open-weights-run

**If you are a local agent running this issue, use the Local open-weights model from the issue's handoff block. Cloud agents never use this file.**

Use when cloud agents can't run (e.g. Cursor usage is used up) and the human works an issue in **desktop Cursor** (or another local harness) on a **Local open-weights** model with their own OpenAI-compatible provider key. Default provider: DeepInfra (`MODEL_ROUTING.md` → Local open-weights harness).

**Model:** default `Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo` (a non-thinking coder model). Other models in `MODEL_ROUTING.md` are marked *Needs test*; use one only after a short local test with thinking off passes. Keep the handoff prompt first and unchanged, don't switch models, rules or tools mid-run, and start a new chat at about 60-70% of context (`MODEL_ROUTING.md` → Caching and context).

## One-time setup (human)

1. Create a provider API key (DeepInfra: account dashboard → API keys).
2. In desktop Cursor, open **Cursor Settings → Models**, add the key as the OpenAI API key, turn on the OpenAI base-URL override with `https://api.deepinfra.com/v1/openai`, and add each model ID from `MODEL_ROUTING.md` as a custom model (name must match the ID exactly). Source: https://cursor.com/help/models-and-usage/api-keys (checked 2026-10-27); menu names change, so follow Cursor's current docs if they differ.
3. While the override is on, Cursor's own OpenAI-family models also route to that URL; turn it off to go back to Cursor models.
4. The key stays in local Cursor settings or env only. Never commit, paste or log it.

## Per issue

1. Open the repo in desktop Cursor and pick the model the issue's **handoff block** names on its `Local open-weights` line.
2. Tell the agent: `do issue #N` (or paste the handoff prompt).
3. The agent syncs to latest default branch, branches, follows `factory-loop.md`, and opens a PR that references the issue. AI disclosure in the PR names the harness (`local Cursor + <provider>`) and model ID.
4. Review, CI and human gates are unchanged.
