# spec-check-new-scripts: scripts/factory-usage.py scripts/test-factory-usage.sh
<!-- factory-spec v1 -->
---
spec_version: 1
issue: 133
title: '#30 part 1: factory-usage.py parser + tests on a real OpenCode usage fixture'
status: approved
complexity: standard
complexity_reason: one new parser and one new test script over real fixtures; strict
  validation rules but no orchestration, network or PR edits
risk: high
work_type: code
model: Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo
model_override_reason: 
model_reason: 'High risk or complex work (build/fix) → Qwen3-Coder, fast non-thinking coder (issue 128)'
predicted_tokens_in: 1000000
predicted_tokens_cached: 800000
predicted_tokens_out: 50000
predicted_cost_usd: 0.1900
budget_cap_usd: 1.00
price_table_version: '2026-11-02'
approved_by: michael
approved_at: '2026-11-07T10:42:00-06:00'
drafted_by: grok-bot
---

## Outcome

`scripts/factory-usage.py` turns one or more `opencode export <sessionID> --sanitize` JSON files into a single key-sorted JSON object of run totals (tokens, cached tokens, requests, OpenCode's cost). It counts each request exactly once and fails loudly on missing or unknown usage fields. `scripts/test-factory-usage.sh` proves this against the real OpenCode 1.19.5 fixtures in `tests/factory-usage/`.

## Context

- Part 1 of 3 of #30 (split approved by Michael on 2026-11-07). #134 (run record) and #135 (PR body) consume this output.
- PR #132 failed because the worker guessed OpenCode's format: it double counted, reported a partial cost as the total, skipped cached tokens and scanned every `*.json`. This spec pins the format to real files.
- **Real format**, from `tests/factory-usage/README.md` (OpenCode 1.19.5 output; token counts come from a local mock provider):
  - An export is `{"info": {...session...}, "messages": [{"info": {...}, "parts": [...]}]}`.
  - Usage repeats at three levels: session `info.tokens`/`info.cost`, each assistant message's `info.tokens`/`info.cost` (`info.role == "assistant"`), and each `parts[]` entry with `"type": "step-finish"`.
  - `tokens` is `{"input", "output", "reasoning", "cache": {"read", "write"}}`, and messages and steps also carry `total`.
  - `input` **excludes** cache reads.
  - `cost` is OpenCode's own price (models.dev), not a DeepInfra-reported figure.
- `opencode stats --models` rounds (`2.0K`), so it is not a source for exact numbers.
- Run record fields (`.factory/schemas/run-record.schema.json`): `tokens_in` includes cached tokens. `scripts/factory-validate-run.py` `cost_from_usage` charges `(tokens_in - tokens_cached)` at the input price, `tokens_cached` at the cached price, and `tokens_out` at the output price.
- Depends on PR #137 (the fixtures) being merged to `main` before the `/oc` run.

## Scope

Create only **new** files:

1. `scripts/factory-usage.py` (Python 3 standard library only, `#!/usr/bin/env python3`):
   - **Input:** explicit export file paths as positional arguments. If none are given, read `$OPENCODE_USAGE_FIXTURE` as a `:`-separated list of file paths (test override, like `OPENCODE_STATS_FIXTURE`). Never glob or scan a directory.
   - **Count one level only:** sum each assistant message's `info.tokens` (`info.role == "assistant"`). `requests` = the number of those messages, and `sessions` = the number of files.
   - **Cross-check:** per file, the message sums must equal that session's `info.tokens` (`input`, `output`, `reasoning`, `cache.read`, `cache.write`). A mismatch is an error. Ignore `step-finish` parts for counting.
   - **Mapping:**
     - `tokens_in` = `input + cache.read + cache.write`
     - `tokens_cached` = `cache.read`
     - `tokens_out` = `output`
     - `tokens_reasoning` = `reasoning`
   - **Cost:** `opencode_cost_usd` = the sum of every counted message's `info.cost`, computed with `decimal.Decimal(str(x))` and rounded to 6 decimals. If **any** counted message lacks a numeric `cost`, output `null`; never a partial sum.
   - **Models:** `models` = the sorted unique list of `"<providerID>/<modelID>"` from the counted messages.
   - **Strictness:** a `tokens` object (or its `cache`) with a missing or unknown key, a non-integer or negative token value, an assistant message without `tokens`, a file that isn't valid export JSON (missing `info`/`messages`), a duplicate session `info.id` across files, or zero counted messages in total are all errors. Unknown fields **outside** `tokens` are ignored.
   - **Output:** exactly one line on stdout, `json.dumps(obj, sort_keys=True)` plus a newline, with keys `models`, `opencode_cost_usd`, `requests`, `sessions`, `source` (`"opencode-export"`), `tokens_cached`, `tokens_in`, `tokens_out`, `tokens_reasoning`.
   - **Exit codes:** `0` OK; `2` usage error (no inputs, or a path that doesn't exist); `3` invalid or absent usage. On any non-zero exit stdout is **empty**, and one `factory-usage: <reason>` line goes to stderr naming the file but never its contents.
   - Never read or print environment variables other than `OPENCODE_USAGE_FIXTURE`. Never print file contents.
2. `scripts/test-factory-usage.sh`: offline test harness (`set -euo pipefail`, `mktemp -d` with a trap cleanup). It prints `PASS`/`FAIL` per case and a final `Results: <n> passed, <m> failed`, and exits 1 on any failure. Variants are made **at runtime** by copying the real fixtures into the temp dir and changing one field with a small inline `python3` snippet. No new hand-written fixture files.

## Out of scope

- Run records, key-spend cross-check, `factory-run-end.sh` (#134); PR-body rewrite (#135); workflow wiring (#31).
- Recovering the title-generation calls that OpenCode does not record (see the README caveat); #134's key-spend cross-check covers that gap.
- Any edit to existing files, including the fixtures and README in `tests/factory-usage/`, `.github/`, `opencode.json`, `.factory/`, and `requirements-factory.txt`.
- `factory/specs/issue-133.md`: the harness writes it.

## Files

- Create: `scripts/factory-usage.py`, `scripts/test-factory-usage.sh`.
- Read first: `tests/factory-usage/README.md`, `tests/factory-usage/opencode-export-session-1.json`, `tests/factory-usage/opencode-export-session-2.json`, `scripts/factory-validate-run.py` (`cost_from_usage`), `.factory/schemas/run-record.schema.json`, `scripts/test-run-start.sh` (test style).

## Acceptance criteria

- [ ] Both real fixtures (in either argument order) print exactly `{"models": ["deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo"], "opencode_cost_usd": 0.00164, "requests": 4, "sessions": 2, "source": "opencode-export", "tokens_cached": 8000, "tokens_in": 10000, "tokens_out": 240, "tokens_reasoning": 0}`.
- [ ] Session 1 alone gives `tokens_in` 3500, `tokens_cached` 2800, `tokens_out` 90, `requests` 2, `opencode_cost_usd` 0.00058.
- [ ] Multi-session fixture sums all sessions (tokens and requests); passing the same file twice exits 3 (duplicate session), so nothing is counted twice.
- [ ] Cached tokens are read: `cost_from_usage(10000, 8000, 240, 0.30, 0.10, 1.00)`, imported from `scripts/factory-validate-run.py` via `importlib`, equals 0.00164 within 1e-9, which matches OpenCode's own cost.
- [ ] One assistant message with its `cost` removed → `opencode_cost_usd` is `null` and the tokens are unchanged (never a partial cost).
- [ ] Bad inputs each exit 3 with empty stdout: unparseable JSON; the `opencode-stats-models.txt` text file; an unknown key added to a message's `tokens`; `cache.read` removed; an assistant message with no `tokens`; a session `info.tokens.input` that doesn't match its messages; an export with no assistant messages.
- [ ] No arguments and no `OPENCODE_USAGE_FIXTURE` → exit 2; a missing path → exit 2; the `OPENCODE_USAGE_FIXTURE` override gives the same output as positional arguments.
- [ ] No key or token printed: with a sentinel env var set (for example `FACTORY_TEST_SECRET=sentinel-value`), the sentinel appears in neither stdout nor stderr of any case.

## Verification

```bash
bash scripts/test-factory-usage.sh
python3 scripts/factory-usage.py tests/factory-usage/opencode-export-session-1.json tests/factory-usage/opencode-export-session-2.json
git diff --name-only HEAD~1 | sort
```

Expected: every `test-factory-usage.sh` line `PASS` and a final `Results: <n> passed, 0 failed`; the second command prints the exact JSON line in the first acceptance criterion; the changed-file list is only `factory/specs/issue-133.md`, `scripts/factory-usage.py`, `scripts/test-factory-usage.sh`.

## Classification

- Complexity: standard. One parser and one test script, but with exact rules and a broad bad-input matrix.
- Risk: high. Spend accounting is a financial correctness surface (Michael approves).
- Model: routed by `models.yaml` rule 1 (high risk → Qwen3-Coder); `model_override_reason` is empty.

## Cost forecast

Standard prior on Qwen3-Coder (1.0M in, 80% cached, 50K out) predicts about $0.19, against a $1.00 cap for this issue. The last two #30 runs cost $0.17–0.26. Small enough for one worker window: about 150 lines of Python plus about 120 lines of tests.

## Manual steps for Michael

- Merge PR #137 (fixtures) before posting `/oc` on #133.
- None for workflows: nothing calls `factory-usage.py` until #134 and #31.

## Dependencies

PR #137 (fixtures) must be on `main`. Then #134 and #135 build on this output.

## Worker prompt

Read `tests/factory-usage/README.md` first, then the two export fixtures, `scripts/factory-validate-run.py` and `scripts/test-run-start.sh`. Then create exactly two files, `scripts/factory-usage.py` and `scripts/test-factory-usage.sh`, following the Scope exactly: count only assistant-message `info.tokens`, cross-check each session total, `tokens_in = input + cache.read + cache.write`, `null` cost unless every counted message has one, strict `tokens` keys, no directory scanning, sorted-key one-line JSON, exit 2 for usage errors and 3 for bad usage with empty stdout. Build every bad-input case at runtime from copies of the real fixtures in a temp dir; don't add fixture files. Start writing after those reads; don't browse other directories. The write tool creates parent directories; never run mkdir, chmod or git commit. Never print a key, token or env value. Fill the PR template; tick only what you proved.

## Design / approach

A small standard-library parser with one rule per failure from PR #132. It reads only the files it is given, counts one level of OpenCode's repeated usage data (assistant messages) and checks it against the session totals, so a format change or a double count shows up as an error, not a wrong number. Cost handling is all-or-nothing (`null` unless every message is priced). `Decimal` and sorted keys make the output byte-stable for tests and for #134. Tests build every edge case from the two real fixtures at runtime, so no hand-invented format enters the repo.

## Alternatives considered

- `opencode stats --models` as the source: rejected. It rounds (`2.0K`) and printed nothing in spike PR #45.
- Reading `opencode.db` (SQLite) directly: rejected for now. It's an internal storage schema; `export --sanitize` is OpenCode's supported, redacted interface.
- Summing `step-finish` parts or session totals instead of messages: either is valid on its own. Messages give `requests` directly, and the session total stays a cross-check.
- Lenient parsing (skip bad files): rejected. A silent skip under-reports spend; #134 decides what to do with exit 3.

## Risks, rollback and revert trigger

- Risk: a newer OpenCode version changes the `tokens` shape. The strict key check makes that exit 3 (visible), not a wrong total. Re-capture fixtures when `OPENCODE_VERSION` changes.
- Risk: OpenCode doesn't record title-generation calls, so export totals slightly under-count real DeepInfra spend. That's documented, and the #134 key-spend cross-check covers it.
- Rollback: revert the merge commit. Nothing calls the parser until #134 and #31.
- Revert trigger: any real run's export where `factory-usage.py` output differs from the session `info.tokens` totals, or `opencode_cost_usd` differs from the sum of message costs.

## What changes in production on merge

Nothing at runtime. A new parser and its tests land; no workflow, existing script or config changes.

## Success metric (baseline, target, how measured)

- Baseline: no parser on `main`; PR #132's guessed parser double counted (20/4 tokens instead of 10/2).
- Target: exact totals on the real fixtures, and every bad-input case blocked with exit 3 and empty stdout.
- How measured: `bash scripts/test-factory-usage.sh` (`Results: <n> passed, 0 failed`) plus the exact JSON line in Verification.

## Test plan detail (broken case shown blocked)

Each case runs `scripts/factory-usage.py` on copies in a `mktemp -d` dir and checks the exit code, the exact stdout (or that stdout is empty) and a stderr substring:
- Happy: both sessions (both orders) → the exact JSON line; session 1 alone → 3500/2800/90/2/0.00058; the env override matches positional arguments.
- Cost: one message's `cost` removed → `opencode_cost_usd: null`, tokens unchanged; `cost_from_usage` from the validator equals 0.00164.
- Blocked (exit 3, empty stdout): duplicate file; unparseable JSON; the stats text file; an unknown `tokens` key; missing `cache.read`; an assistant message without `tokens`; a session total that doesn't match its messages; no assistant messages; a negative token value.
- Usage (exit 2): no inputs; a missing path.
- Secrets: a sentinel env value never appears in any output.

## Security and liability review (`liability-gates.md`)

- Reads only the files named. No network, no env reads except `OPENCODE_USAGE_FIXTURE`, never prints file contents, and stderr names the file only. The fixtures are already `--sanitize` output and gitleaks-clean (PR #137).
- No new dependency (stdlib only). No workflow or owner-only path changes. Merge stays behind Michael's gate (high risk).

## Milestones / split plan

One PR, about 150 lines of parser plus about 120 lines of tests. This is milestone 1 of the #30 split (then #134, then #135). If it grows past about 300 lines, split the bad-input test matrix into a follow-up.

