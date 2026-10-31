# Skill: local-open-weights-run

**If you are a local agent running this issue, use the Local open-weights model from the issue's handoff block. Cloud agents never use this file.**

Use when cloud agents can't run (e.g. Cursor usage is used up) and the human works an issue in **desktop Cursor** (or another local harness) on a **Local open-weights** model with their own OpenAI-compatible provider key. Default provider: DeepInfra (`MODEL_ROUTING.md` → Local open-weights harness).

**Model:** default `Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo` (a non-thinking coder model). Other models in `MODEL_ROUTING.md` are marked *Needs test*; use one only after a short local test with thinking off passes. Keep the handoff prompt first and unchanged, don't switch models, rules or tools mid-run, and start a new chat at about 60-70% of context (`MODEL_ROUTING.md` → Caching and context).

## One-time setup (human)

**Required first:** do the owner checklist in `local-owner-setup.md` (gh, hooks, DeepInfra key, antivirus, command allowlist) and the safety setup in `local-agent-safety.md`. Don't start a local run until both are done.

1. Create a provider API key (DeepInfra: account dashboard → API keys).
2. In desktop Cursor, open **Cursor Settings → Models**, add the key as the OpenAI API key, turn on the OpenAI base-URL override with `https://api.deepinfra.com/v1/openai`, and add each model ID from `MODEL_ROUTING.md` as a custom model (name must match the ID exactly). Source: https://cursor.com/help/models-and-usage/api-keys (checked 2026-10-27); menu names change, so follow Cursor's current docs if they differ.
3. While the override is on, Cursor's own OpenAI-family models also route to that URL; turn it off to go back to Cursor models.
4. The key stays in local Cursor settings or env only. Never commit, paste or log it.
5. **(One-time, per computer)** Put `DEEPINFRA_API_KEY` and `FACTORY_DEEPINFRA_KEY_NAME` in `~/.zshrc` (`local-owner-setup.md` step 3), then restart Cursor. The cost script reads both, so the agent never needs the key or its name.

## Per issue

1. Open the repo in desktop Cursor, in Agent mode, and pick the model the issue's **handoff block** names on its `Local open-weights` line.
2. Type `do issue N`. The always-on rule `.cursor/rules/factory.mdc` tells the agent the rest.
3. The agent runs `bash scripts/factory-cost.sh start N` first. It posts the key's current spend on issue N as a hidden marker comment; there's no local state file.
4. The agent syncs to the latest default branch, branches `issue-N-<slug>`, follows `factory-loop.md`, and opens a PR with `Closes #N`, `AI disclosure: harness local Cursor + <provider>; model <model ID>`, and the template filled in.
5. After the PR is open, the agent runs `bash scripts/factory-cost.sh end N` and puts its `Cost:` line (for example `Cost: $0.0700 on DeepInfra`) and `Caching:` line in the PR body. The PR check fails without a `Cost:` amount. The script can't see cached tokens, so read the cache share off the provider's usage page if you want it on the PR.
6. **Automatic review:** when the PR opens and on each push, the Builder bot (the Factory Manager in project repos) posts a `Factory review (Builder)` comment following `review-local-pr.md`. This is a bot routine, not repo code. You don't relay anything.
7. **Fixes:** say `address the review on PR N`. The agent runs `gh pr view N --comments`, fixes each numbered item in the latest `Factory review`, pushes to the same branch, and replies on the PR item by item. The push triggers the next review round.
8. CI and human gates are unchanged: you give the product gate and merge.
9. **Budget:** target under $0.10 per issue (complex may scale up), hard cap $1 (`MODEL_ROUTING.md` → Per-issue budget). If spend nears $1, stop and comment on the issue instead of continuing.

## Command allowlist (Cursor)

Allowlist only these command prefixes in Cursor's agent settings, so a run doesn't stop for each one:

- `gh issue view`, `gh issue comment`
- `gh pr view`, `gh pr create`, `gh pr comment`, `gh pr edit`
- `git status`, `git diff`, `git log`
- `git checkout -b issue-`, `git add`, `git commit`, `git push origin issue-`
- `bash scripts/factory-cost.sh`, `bash scripts/pr-check.sh` (exact scripts only, never `bash scripts/` as a whole: the agent could write a new script and run it unasked)

Never allow: `curl`, `gh pr merge`, `gh api`, bare `git push`, `--no-verify`, `env`, `printenv`. Leave everything else on ask.

**gh runs outside the sandbox.** Cursor runs agent commands in a sandbox that can't read the macOS Keychain, so `gh` reports the token as invalid inside the agent even when `gh auth status` works in your terminal. Approve `gh` commands, `git push origin issue-*` and `bash scripts/factory-cost.sh` (it calls `gh`) to run outside the sandbox one command at a time, or allowlist only those. Don't turn the sandbox off or auto-approve everything, and don't put the GitHub token in `~/.zshrc` (it covers all repos).
