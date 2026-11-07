# OpenCode usage fixtures (#30 part 1)

These are **real output from the pinned OpenCode CLI** (`1.19.5`, installed with `scripts/opencode-install.sh`, same checksum as CI). Nothing in this folder was hand-written. Only the token counts are synthetic: they come from a local mock provider, so there is no DeepInfra spend and no key.

How they were captured (2026-11-07, Grok Bot, on the factory box):

1. Start `mock-openai-server.py`: an OpenAI-compatible `/v1/chat/completions` endpoint on 127.0.0.1 that streams fixed `usage` blocks (`prompt_tokens`, `completion_tokens`, `prompt_tokens_details.cached_tokens`). The first request of each session gets a `read` tool call, the next gets a text reply.
2. In a scratch git repo with an empty `HOME`, set `opencode.json` to the same `deepinfra` provider block as the repo's, but with `baseURL` pointing at the mock and a dummy key. Run `opencode run --pure --format default "<prompt>"` twice (two sessions).
3. `opencode stats --models` → `opencode-stats-models.txt` (ANSI escapes stripped, nothing else changed).
4. `opencode export <sessionID> --sanitize` → `opencode-export-session-1.json` and `-2.json`, byte for byte. `--sanitize` already redacts text, titles, paths, tool input and output, and snapshots; there are no usernames, keys or tokens.

## What the format says (read from these files)

- Export JSON: `{"info": {...session...}, "messages": [{"info": {...}, "parts": [...]}]}`.
- Token usage appears at **three levels**, and each repeats the same numbers:
  - session `info.tokens` + `info.cost` = sum over its assistant messages
  - assistant message `info.tokens` + `info.cost` (role `assistant`; `finish` is `tool-calls` or `stop`)
  - `parts[]` with `"type": "step-finish"`: `tokens` + `cost` for that step

  A parser must count **one** level, or it double or triple counts.
- `tokens`: `{"input", "output", "reasoning", "cache": {"read", "write"}}` (messages and steps also have `total`). **`input` excludes cache reads**: the mock sent `prompt_tokens` 1500 with 1200 cached, and OpenCode stored `input: 300, cache.read: 1200`.
- `cost` is OpenCode's own USD price for that model (models.dev prices; here $0.30 in / $0.10 cached / $1.00 out per Mtok, the same as `.factory/models.yaml` for Qwen3-Coder).
- Model: session `info.model.{id, providerID}`; message `info.modelID` / `info.providerID`.
- `opencode stats --models` rounds (`2.0K`, `8.0K`), so it can't give exact token counts. Use export for numbers and stats only as a cross-check.

Expected totals across both sessions (sum of session `info.tokens`):

| | session 1 | session 2 | total |
|---|---|---|---|
| input (uncached) | 700 | 1300 | 2000 |
| cache.read | 2800 | 5200 | 8000 |
| output | 90 | 150 | 240 |
| reasoning | 0 | 0 | 0 |
| assistant messages (requests) | 2 | 2 | 4 |
| cost (USD) | 0.00058 | 0.00106 | 0.00164 |

## Caveat: title-generation calls are not recorded

The mock received **6** requests, but OpenCode recorded only **4** assistant messages. OpenCode also makes one title-generation request per session to the same provider (mock requests 0 and 3: 1000 and 2500 prompt tokens). That usage appears in neither `export` nor `stats`. On a real run it is real DeepInfra spend that OpenCode's numbers miss, which is why the run-end cross-check against key spend (#30 part 2) matters.
