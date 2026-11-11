<!-- factory-spec v1 -->
---
spec_version: 1
issue: 166
title: 'factory-run-review.py: read real tool_counts/blocked_calls from session JSON and real OpenCode log lines'
status: approved
complexity: standard
complexity_reason: 'touches the tool-event parser, blocked-call detector, session-JSON artifact reader and the render suffix fix, plus their fixtures'
risk: normal
work_type: code
model: deepseek-ai/DeepSeek-V4-Flash-0731
model_override_reason: 
model_reason: 'Default for all other factory worker runs → V4 Flash'
predicted_tokens_in: 1000000
predicted_tokens_cached: 800000
predicted_tokens_out: 50000
predicted_cost_usd: 0.0330
budget_cap_usd: 1.00
price_table_version: '2026-11-02'
approved_by: grok-bot
approved_at: '2026-11-11T09:52:09-06:00'
drafted_by: oc-spec-run
---

## Outcome

On live `/oc` run reviews, `scripts/factory-run-review.py` reports real `tool_counts` (and per-turn timing where timestamps exist) and the real permission-denied calls in `blocked_calls`, by reading the structured `usage/session-*.json` exports from the run-record artifact and matching the real OpenCode log line format, with the rendered output saying `unavailable` (no stray suffix) when a value is genuinely absent.

## Context

Found in the post-merge run review of #165 (closes #159), part of Epic #38. After #159 merged, `scripts/factory-run-review.py --pr 165` picks up the spec run and fills tokens, but tool stats and guardrail signals are still empty on real runs: `tool_counts: {}`, `seconds_per_tool_turn: null`, `longest_gap_seconds: null` for build run 42951547485 even though its `oc-record-42951547485` artifact has `usage/session-1.json` with structured tool parts (31 read, 8 edit, 8 write, 4 bash, 3 glob, 3 grep), and `blocked_calls: []` even though the run's `opencode.log` has a permission denial (`✗ ls -la tests/factory-run-review/...` followed by `The user has specified a rule which prevents you from using this specific tool call`).

Root cause (in `scripts/factory-run-review.py`): `parse_tool_events()` (factory-run-review.py:489-503) only matches lines containing `<tool> tool call`, which real OpenCode logs never print (they use `→ Read <path>`, `✱ Glob ...`, `✗ <cmd> failed`, with ANSI codes). `detect_blocked_calls()` (factory-run-review.py:506-526) keys on `denied/blocked/guardrail`, which the real denial text does not contain. Neither path reads the structured `usage/session-*.json` files that `scripts/opencode-run-meter.sh` writes into the record artifact (opencode-run-meter.sh:83, `usage/session-<n>.json`). The fixtures use the synthetic log format, so tests pass while live runs read as "nothing happened". Also cosmetic: `render_markdown` (factory-run-review.py:296-300) prints `longest gap: unavailables` because the `s` suffix is appended after `unavailable`.

## Scope

Edit `scripts/factory-run-review.py` so live (and `--live-dir` offline) run reviews:

- Populate `tool_counts`, `seconds_per_tool_turn` and `longest_gap_seconds` from the structured `usage/session-*.json` exports in the run-record artifact when present, using the same `{tool, ts, input}` tool-event shape `tool_turn_stats` (factory-run-review.py:136-153) already consumes. The session export (`info.messages[].parts[]` with `type: "tool"`) is the same shape the `opencode-export.json` fixture documents; derive one event per tool part with the timestamp from `state.time.start` (milliseconds), falling back to the message `info.time.created` when a tool part has no start time. Where no timestamp exists, keep the event but leave the gap contributions absent so per-turn timing stays `null` rather than fabricated.
- Fall back to the real OpenCode log line format when no session JSON is present: match `→ Read <path>`, `✱ Glob ...`, `✗ <cmd>` (failed tool calls), and similar lines, stripping ANSI escape codes first, so `parse_tool_events` no longer requires the synthetic `<tool> tool call` spelling.
- Detect the real permission-denial text (`The user has specified a rule which prevents you from using this specific tool call`) as a blocked call, and capture the denied command from the surrounding log lines (for example the `✗ <cmd>` line), keeping the existing denied/blocked/guardrail vocabulary as a fallback so older fixtures still work.
- Fix the rendered-output suffix bug so a null `longest_gap_seconds` renders as `unavailable` with no stray `s` (e.g. `longest gap: unavailable`, not `unavailables`).

Update the tests and fixtures: `scripts/test-factory-run-review.sh` and the `tests/factory-run-review/` fixtures (add a fixture built from a real, redacted OpenCode log line set and session JSON covering the denied `ls` and the non-empty tool counts). Keep the `--input` expected output byte-identical for the fields the issue does not touch, and keep the review deterministic (no model calls, no wall clock, no secret/env value printed).

## Out of scope

Do not edit any protected spend/security script (see `scripts/opencode-artifact-scan.sh --list-protected`), in particular `scripts/factory-usage.py`, `scripts/opencode-run-meter.sh`, or any other script on the protected list; do not edit any existing script other than `scripts/factory-run-review.py` and `scripts/test-factory-run-review.sh`. Do not touch `.github/`, `opencode.json`, any `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, `requirements-factory.txt`, or any other dot-path. Do not add or re-pin a Python package. Do not change how the session exports are written (that is `opencode-run-meter.sh`'s job); the review script only reads them. Do not change the cost/token computation itself in `factory-usage.py`; only the review script's tool/blocked parsing and rendering. Keep the change to one PR of roughly 300 changed lines or less.

## Files

- Edit: `scripts/factory-run-review.py`
- Edit: `scripts/test-factory-run-review.sh`
- Edit: `tests/factory-run-review/README.md` (document the new real-log/session fixture)
- Create: `tests/factory-run-review/reallog/live/run-list.json`
- Create: `tests/factory-run-review/reallog/live/artifacts/42951547485/usage/session-1.json`
- Create: `tests/factory-run-review/reallog/live/artifacts/42951547485/log.txt`

## Acceptance criteria

- [ ] A live-style fixture whose artifact carries `usage/session-1.json` with structured tool parts reports non-empty `tool_counts` (matching the session JSON's per-tool counts) and non-null `seconds_per_tool_turn` / `longest_gap_seconds` where the part timestamps support them; a run with no usable timestamps keeps those fields JSON `null`.
- [ ] A fixture whose `opencode.log` contains the real permission-denial text (`The user has specified a rule which prevents you from using this specific tool call`) and a preceding `✗ <cmd>` line reports that command in `blocked_calls`.
- [ ] A fixture using the real OpenCode log line format (`→ Read`, `✱ Glob`, `✗ ... failed`, with ANSI codes) populates `tool_counts` via the log fallback when no session JSON is present.
- [ ] The rendered output says `unavailable` for a null `longest_gap_seconds` with no stray `s` suffix (never `unavailables`); JSON fields stay `null` (the string "unavailable" appears only in rendered output, not in JSON).
- [ ] `bash scripts/test-factory-run-review.sh` passes, including the new real-log/session fixture and a broken case proving a run with no tool data reports unavailable rather than fabricating counts.
- [ ] No key, token, or environment value appears in the script's output or stderr (the sentinel test still passes).

## Verification

```bash
bash scripts/test-factory-run-review.sh
```

Expected:
```
PASS  <...all updated checks, including the real-log/session tool-count and blocked-call cases and the unavailable-suffix check...>
Results: <N> passed, 0 failed
```
The final line must report 0 failed; all updated checks (session-JSON tool counts, real-log fallback, real permission-denial blocked call, the unavailable-not-fabricated broken case, and the no-secret-printed sentinel) pass.

## Classification

- complexity: standard — the fix spans the tool-event parser, the blocked-call detector, a new session-JSON artifact reader and the render suffix fix, plus their fixtures; not a single-line change.
- risk: normal — it changes the review tool's reported output (tool counts, per-turn timing, blocked calls) and is review tooling only (no gates, no spend, no workflow), so not high.
- work_type: code.
- Model routing and reason match the front matter; the harness fills the model fields.

## Cost forecast

Tokens in/cached/out and predicted cost are left for `factory-predict-cost.py` to route; the change is a small, focused edit to one script plus its tests and fixtures, expected to fit well under the $1 cap, so no split is planned.

## Manual steps for Michael

None. No workflow, secret, setting or dependency change is required; this is contained to the review script and its tests/fixtures.

## Dependencies

None blocking. Refs #38 (Epic) and #159/#165 (the earlier work this issue follows up), but neither blocks this change; #165 is already merged.

## Worker prompt

Read issue #166 and `.factory/FACTORY.md` first. Edit `scripts/factory-run-review.py` so live (and `--live-dir`) run reviews populate `tool_counts`, `seconds_per_tool_turn` and `longest_gap_seconds` from the structured `usage/session-*.json` exports in the run-record artifact when present (derive one `{tool, ts, input}` event per `type: "tool"` part using `state.time.start`, the same shape `tool_turn_stats` consumes), fall back to the real OpenCode log line format (`→ Read <path>`, `✱ Glob ...`, `✗ <cmd> failed`, ANSI codes stripped) when no session JSON is present, detect the real permission-denial text `The user has specified a rule which prevents you from using this specific tool call` as a blocked call (capturing the denied command from the surrounding log, keeping the existing denied/blocked/guardrail vocabulary as a fallback), and fix the rendered `longest gap: unavailables` suffix bug so a null renders as `unavailable` with no stray `s`. Update `scripts/test-factory-run-review.sh` and the `tests/factory-run-review/` fixtures (add a fixture built from a real, redacted OpenCode log line set and session JSON with no keys, tokens, env values or private paths covering the denied `ls` and the non-empty tool counts) to prove the new behavior and a broken case that reports unavailable rather than fabricating values. Keep the `--input` expected output byte-identical for the fields the issue does not touch, keep the review deterministic, and never print a key, token or env value. Do not edit any protected spend/security script (including `scripts/factory-usage.py` and `scripts/opencode-run-meter.sh`), any existing script other than the two named, or any owner-only file; do not touch `.github/`, `opencode.json`, `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, or `requirements-factory.txt`. Fill the PR template; tick only what you proved.

## Design / approach

Keep the review script a pure transform that never guesses. Make the tool-event source a small pipeline: first read the record artifact's `usage/session-*.json` exports (the authoritative, structured source the run meter already writes), flatten `info.messages[].parts[]` tool parts into `{tool, ts, input}` events with `ts` from `state.time.start` (ms); when no session JSON exists, fall back to parsing the real OpenCode log lines (`→ Read <path>`, `✱ Glob ...`, `✗ <cmd> failed`) after stripping ANSI escapes, preserving the existing synthetic `<tool> tool call` matcher so older fixtures keep passing. Feed the merged events through the existing `tool_turn_stats` and `out_of_spec_reads` unchanged. `detect_blocked_calls` gains the real denial marker as a primary trigger and keeps the old vocabulary as a fallback, then extracts the denied command from a nearby `✗`/`→` line or the line itself; return the command string (never a secret or env value). Fix the render line so the `s` unit is appended only to a real number. Wire the new session-JSON reader into `parse_artifacts` so it populates `tool_events`/`blocked_calls` on the live path (and via `enrich_from_artifacts` / `fetch_runs_live_dir`). Keep `--input` byte-identical for the fields the issue does not touch.

## Alternatives considered

Not required for standard/normal, but briefly: recomputing tool counts purely by grepping workflow logs was rejected as lossy and non-deterministic; instead prefer the structured `usage/session-*.json` exports (the exact source the issue points to) with the real-log-line format as a fallback. Changing the run meter to write a different shape was rejected because `scripts/opencode-run-meter.sh` is a protected spend/security script; the review script reads what the meter already produces.

## Risks, rollback and revert trigger

Risk: the new log parser or session reader double-counts tool events (for example a run that has both a session JSON and a log fallback both firing) or misattributes a blocked command to the wrong line. Mitigations: prefer the session JSON when present and only fall back to the log when the session has no events; dedupe by tool + timestamp where sensible; pin behavior with fixtures. Risk: the real denial text could change in a future OpenCode release, silently returning to empty `blocked_calls`; mitigated by keeping the old vocabulary as a fallback and by a fixture that would fail loudly if detection regresses. Risk: introducing a fabricated count or timing when no source has it; mitigated by reporting unavailable rather than guessing. Rollback is a normal code revert of `factory-run-review.py` and its test/fixture changes. Revert trigger: if the updated fixtures or a live run show tool counts or blocked calls that do not match the session JSON/log, a run double-counted, or a fabricated (non-null) value with no source, revert.

## What changes in production on merge

The post-merge `/oc` run-review output stops silently reporting empty `tool_counts` and empty `blocked_calls` on live runs and instead shows the real per-tool counts, per-turn timing (where timestamps exist) and the denied calls, so the review's wheel-spinning, out-of-spec-read and guardrail near-miss signals actually fire. The rendered output for a genuinely missing value changes from `unavailables` to `unavailable`. The script is invoked in the same place it is today; no workflow, gate, cost, or model-routing behavior changes. No secrets or env values are printed.

## Success metric (baseline, target, how measured)

Baseline (from #165's run 42951547485): a live `--pr` review reports `tool_counts: {}`, `seconds_per_tool_turn: null`, `longest_gap_seconds: null`, and `blocked_calls: []` even though the record artifact's `usage/session-1.json` has 31 read / 8 edit / 8 write / 4 bash / 3 glob / 3 grep tool parts and the `opencode.log` contains a permission denial. Target: a live (or `--live-dir`) review on a run with a session JSON reports those tool counts and per-turn timing, and the denied `ls` appears in `blocked_calls`; the rendered output says `unavailable` with no stray suffix when a value is missing. Measured by the updated `bash scripts/test-factory-run-review.sh` (run by the verification harness) and by the next real post-merge review on main.

## Test plan detail (broken case shown blocked)

Happy path: a new fixture built from a real, redacted OpenCode log line set and session JSON (no keys, tokens, env values or private paths) drives the `--live-dir` path; the test asserts non-empty `tool_counts` matching the session JSON's per-tool counts and non-null `seconds_per_tool_turn` / `longest_gap_seconds` where timestamps exist, and that the denied `ls` shows up in `blocked_calls`. Log-fallback case: a fixture with only a real-format `log.txt` (`→ Read`, `✱ Glob`, `✗ ... failed`, with ANSI codes) and no session JSON still populates `tool_counts`. Broken case: a fixture whose run has no usable tool data asserts the field is reported as unavailable (rendered, no stray suffix) and stays JSON `null` rather than a fabricated value; the no-secret sentinel test still passes; the existing byte-identical `--input` expected-*.json for unaffected fields still passes (the test cannot pass while the synthetic-only parser bug is present).

## Security and liability review (`liability-gates.md`)

The script stays read-only (`gh` read calls only), deterministic, and prints no key, token or env value; the sentinel test keeps guarding that. The new fixture is explicitly sanitized (no secrets, keys, tokens, env values or private paths), matching the existing fixture policy in `tests/factory-run-review/README.md`. No new dependency is introduced (only `scripts/factory-run-review.py` and its test/fixtures change; cost/token computation stays delegated to `factory-usage.py`). No protected spend/security script, workflow, or owner-only file is touched. Reported values come only from the session JSON, run records and downloaded logs; the script never fabricates a number, so a reviewer cannot be misled into thinking a run was healthier than it was.

## Milestones / split plan (when near the cap)

Not required — standard/normal and expected to fit comfortably in one PR well under the cap.
