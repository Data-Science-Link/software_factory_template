<!-- factory-spec v1 -->
---
spec_version: 1
issue: 193
title: 'factory-run-review.py: derive live blocked_calls from session-export tool-part errors and the opencode.log artifact, and surface artifact unavailability'
status: approved
complexity: standard
complexity_reason: 'touches the blocked-call source selection (session-export tool-part errors and the opencode.log artifact), the parse/overlay plumbing in parse_artifacts, enrich_from_artifacts and fetch_runs_live_dir, an artifacts-unavailable marker, and the test/fixtures, but stays within one worker-editable script and its test'
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
approved_by: michael
approved_at: '2026-11-11T12:06:58-06:00'
drafted_by: oc-spec-run
---

## Outcome

Live `/oc` run reviews report real permission denials in `blocked_calls` (derived from the downloaded session export's errored tool parts with the permission-denial text, falling back to the `opencode.log` artifact), so build run 43069209256 lists the blocked `find` command, while the #188 false positives stay gone; and when the run's artifact directory is missing or the artifact download fails, the review says so explicitly instead of silently returning empty `tool_counts` / evidence / routing.

## Context

Issue #193, found in the post-merge review of PR #190 (#188), build run 43069209256. That run had one real OpenCode permission denial (the worker's `find .../tests/factory-run-review -type f | sort` bash call was blocked by the deny rule; the guardrail held and the worker fell back to glob), but `python3 scripts/factory-run-review.py --pr 190` reports `blocked_calls: []`, so the review never surfaces it.

Root cause (verified in `scripts/factory-run-review.py`): in live mode `detect_blocked_calls()` only runs on the `gh run view --log` text (`base_run_facts` at line 1023 and `enrich_from_artifacts` at line 1124). That workflow log does not contain the agent's tool output at all (no tool lines, no denial text), so it can never match a real denial. The denial is present in artifacts the script already downloads: `oc-record-<id>/usage/session-1.json` (a `type: "tool"` part with `state.status: "error"` and the "prevents you from using this specific tool call" error) and `oc-artifacts-<id>/opencode.log` (running `detect_blocked_calls()` on that file already returns the `find` denial correctly). `parse_artifacts()` (line 921) reads session exports only for `tool_events` via `events_from_session()` (line 535), which extracts `{tool, ts, input}` and never inspects `state.status` or the error text, and it never derives `blocked_calls` from the session exports or from `opencode.log`; `enrich_from_artifacts()` (line 1115) also never copies a `blocked_calls` value from parsed artifacts into the run facts.

The offline `--live-dir` path is `fetch_runs_live_dir()` (line 1236), not `enrich_from_artifacts()`. It already runs `detect_blocked_calls()` on `artifacts/<run_id>/log.txt` via `base_run_facts()`, and it overlays any non-`None` `parse_artifacts()` value, including an empty `blocked_calls: []`, which would wipe a log-derived denial such as the `reallog/live` denied `ls`. Both overlay sites need the same empty-list guard.

So after #166 and #188, live `tool_counts` work but live `blocked_calls` is structurally always empty: #188 removed the false positives, and this is the matching false negative. Minor, same area: a transient artifact-download failure currently degrades silently (empty `tool_counts`, evidence, routing rule); it deserves a loud "artifacts unavailable" marker.

## Scope

Edit `scripts/factory-run-review.py` (worker-editable, not on the protected list) so live and `--live-dir` reviews derive `blocked_calls` from the agent's own tool output in the downloaded artifacts, and surface artifact unavailability:

- In `parse_artifacts()`, derive `blocked_calls` from the structured session exports (`usage/session-<n>.json`): a `type: "tool"` part whose `state.status` is an error (for example `"error"`/`"failed"`) and whose error/output contains the real OpenCode permission-denial text (`The user has specified a rule which prevents you from using this specific tool call`) counts as a blocked call, with the command string taken from the part's `state.input` (`input.command` for bash, else the `_tool_input_str()` value). Dedupe by command string.
- Also read the `opencode.log` artifact in each artifact root (the layout `oc-artifacts-<id>/opencode.log` / `oc-fix-artifacts-<id>/opencode.log`) and run `detect_blocked_calls()` on that file as a fallback, so a run with a real-format log and no session export still reports its denial. Merge and dedupe with the session-derived list.
- In `enrich_from_artifacts()` and in `fetch_runs_live_dir()`, overlay a parsed `blocked_calls` value onto the run facts only when the parsed list is non-empty (the same empty-list guard already used for `tool_events`). An empty parsed list must not overwrite a `blocked_calls` value already taken from `log.txt` or a run record. This preserves the `reallog/live` denied `ls`, which today comes from that fixture's `log.txt`, not from its session export.
- Keep the existing #188 false-positive logic intact: the echoed `OC_INSTRUCTION:` env line and the StepSecurity harden-runner `denied_endpoints` config line must still produce no blocked call (the `detect_blocked_calls()` agent-tool-line anchor and the session status/error-text check are the only triggers).
- Emit an explicit "artifacts unavailable" status instead of silent empties. Set an `artifacts_unavailable: true` field, rendered as an "artifacts unavailable" line in the markdown and present in the JSON, when either (1) `download_run_artifacts()` fails on the live path, or (2) the run's artifact directory is missing (live or `--live-dir`, including when `tests/.../artifacts/<run_id>` does not exist). Do not treat an artifact directory that exists but simply has no token or tool data as artifacts-unavailable. Add the new field only when it is true, following the existing optional-key pattern used for `gate`/`gate_passed`, so the three `expected-*.json` fixtures stay byte-identical.
- The existing `tokenless` fixture has no `artifacts/` directory, so under this definition the marker must fire there too. Update the tokenless test in `scripts/test-factory-run-review.sh` so it still passes: keep the current assertions (tokens JSON-null, timing rendered "unavailable", no stray "unavailables" suffix, no fabricated token counts) and also assert that the artifacts-unavailable marker is present in the JSON and the markdown.
- Keep `--input` expected output byte-identical for the fields the issue does not touch.

Update the tests and fixtures: `scripts/test-factory-run-review.sh` and `tests/factory-run-review/`. Name every new fixture with an exact repo-relative path under `tests/factory-run-review/` (no placeholders). Keep the review deterministic (no model calls, no wall clock, no secret/env value printed).

Denied-session fixture (`denied/live`, run 43069209256): `usage/session-1.json` has one errored bash tool part carrying the permission-denial text and the `find .../tests/factory-run-review -type f | sort` command. Its `log.txt` must be a workflow-style `gh run view --log` transcript with no permission-denial text and no agent tool-result line (`✗` / `→` / `✱`) that `detect_blocked_calls()` could treat as a denial. Today's code, which only scans `log.txt` in `--live-dir`, must report `blocked_calls: []` on this fixture; only session-export parsing can make the `find` appear. That is the point of the fixture.

opencode.log fallback fixture (`denied-log/live`, synthetic session-less run 43069209257): no `usage/session-*.json`. The blocked `find` command appears only in `artifacts/43069209257/oc-artifacts-43069209257/opencode.log`. Its `log.txt` is also a workflow-style log with no denial text, so only the `opencode.log` fallback can pass the assertion.

Negative-session fixtures (`denied-neg/live`): two runs whose `log.txt` files are workflow-style logs with no denial text. Run 43069209301 has `usage/session-1.json` with a bash tool part whose `state.status` is not an error (for example `"completed"`), even if the part text mentions a command. Run 43069209302 has `usage/session-1.json` with a bash tool part whose `state.status` is an error but whose error/output does not contain the permission-denial text. Both must report `blocked_calls: []` and no `blocked_call` finding.

Artifacts-unavailable fixture (`unavailable/live`): `run-list.json` and `pr-head.txt` only; no `artifacts/` directory. The review must emit the artifacts-unavailable marker rather than silent empties.

The `note()` / `PASS` strings in `scripts/test-factory-run-review.sh` must match the Verification expected transcript exactly, including the updated tokenless wording.

## Out of scope

Do not edit any protected spend/security script (see `scripts/opencode-artifact-scan.sh --list-protected`); do not edit any existing script other than `scripts/factory-run-review.py` and `scripts/test-factory-run-review.sh`. Do not touch `.github/`, `opencode.json`, any `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, `requirements-factory.txt`, or any other dot-path. Do not add or re-pin a Python package. Do not change how the run meter or session exports write logs; the review script only reads them. Do not change the cost/token computation in `scripts/factory-usage.py` or the run meter. Do not change the #188 false-positive behavior (echoed `OC_INSTRUCTION:` and harden-runner `denied_endpoints` must still produce `blocked_calls: []`). Keep the change to one PR of roughly 300 changed lines or less.

## Files

- Edit: `scripts/factory-run-review.py`
- Edit: `scripts/test-factory-run-review.sh`
- Edit: `tests/factory-run-review/README.md`
- Create: `tests/factory-run-review/denied/live/run-list.json`
- Create: `tests/factory-run-review/denied/live/pr-head.txt`
- Create: `tests/factory-run-review/denied/live/artifacts/43069209256/usage/session-1.json`
- Create: `tests/factory-run-review/denied/live/artifacts/43069209256/log.txt`
- Create: `tests/factory-run-review/denied-log/live/run-list.json`
- Create: `tests/factory-run-review/denied-log/live/pr-head.txt`
- Create: `tests/factory-run-review/denied-log/live/artifacts/43069209257/log.txt`
- Create: `tests/factory-run-review/denied-log/live/artifacts/43069209257/oc-artifacts-43069209257/opencode.log`
- Create: `tests/factory-run-review/denied-neg/live/run-list.json`
- Create: `tests/factory-run-review/denied-neg/live/pr-head.txt`
- Create: `tests/factory-run-review/denied-neg/live/artifacts/43069209301/usage/session-1.json`
- Create: `tests/factory-run-review/denied-neg/live/artifacts/43069209301/log.txt`
- Create: `tests/factory-run-review/denied-neg/live/artifacts/43069209302/usage/session-1.json`
- Create: `tests/factory-run-review/denied-neg/live/artifacts/43069209302/log.txt`
- Create: `tests/factory-run-review/unavailable/live/run-list.json`
- Create: `tests/factory-run-review/unavailable/live/pr-head.txt`

## Acceptance criteria

- [ ] Live/`--live-dir` review of `denied/live` (run 43069209256) reports the blocked `find` command in `blocked_calls` and a `blocked_call` finding. That fixture's `log.txt` is a workflow-style log with no denial text, so `detect_blocked_calls()` on `log.txt` alone returns `[]`; only session-export parsing can satisfy this criterion.
- [ ] Live/`--live-dir` review of `denied-log/live` (session-less run 43069209257) reports the blocked `find` command in `blocked_calls` from `artifacts/43069209257/oc-artifacts-43069209257/opencode.log`. That fixture has no `usage/session-*.json`, and its `log.txt` has no denial text.
- [ ] No regression on #188: the `falsepos/live` fixture (echoed `OC_INSTRUCTION:` line and harden-runner `denied_endpoints` line, no real denial) still reports `blocked_calls: []` and no `blocked_call` finding, and the `reallog/live` fixture (real denied `ls` from that fixture's `log.txt`) still detects its denial.
- [ ] `fetch_runs_live_dir()` and `enrich_from_artifacts()` both apply the empty-list guard when overlaying parsed `blocked_calls`: a parsed empty list does not overwrite a log-derived or record-derived value (this is what keeps `reallog/live` green).
- [ ] `denied-neg/live` run 43069209301 (session tool part with non-error `state.status`) and run 43069209302 (session tool part with an error that lacks the permission-denial text) both report `blocked_calls: []` and no `blocked_call` finding. Their `log.txt` files have no denial text.
- [ ] `enrich_from_artifacts()` overlays a parsed non-empty `blocked_calls` value onto the run facts (not just `tool_events`).
- [ ] The artifacts-unavailable marker (`artifacts_unavailable: true` in the JSON and an "artifacts unavailable" line in the markdown) is set when `download_run_artifacts()` fails or the run's artifact directory is missing, and is not set merely because an existing artifact directory has no token or tool data.
- [ ] `unavailable/live` (no `artifacts/` directory) emits the artifacts-unavailable marker instead of silent empties.
- [ ] The existing tokenless test still passes: tokens stay JSON-null, timing still renders as "unavailable", there is no stray "unavailables" suffix, and the artifacts-unavailable marker is now also present (tokenless has no `artifacts/` directory).
- [ ] `bash scripts/test-factory-run-review.sh` passes and prints the Verification expected transcript exactly, including `Results: 14 passed, 0 failed`, the still-passing byte-identical `--input` expected-*.json checks, and the no-secret sentinel.
- [ ] No key, token, or environment value appears in the script's output or stderr.

## Verification

```bash
bash scripts/test-factory-run-review.sh
```

Expected:

```
PASS  run 42282682618 byte-identical
PASS  run 42290238204 byte-identical
PASS  run 42297659590 byte-identical
PASS  live-path parser (spec run selected, tokens/cost populated from artifacts)
PASS  run-record parser (model/cost/gate/tokens from comment)
PASS  fallback parser (nested artifacts, usage-metrics, displayTitle)
PASS  token-less broken case (no tool data, tokens/gap null, rendered unavailable, artifacts-unavailable marker present, no stray suffix)
PASS  real-log/session parser (session tool counts + timing, denied ls, log fallback)
PASS  false-positive regression (echoed OC_INSTRUCTION + harden-runner denied_endpoints produce blocked_calls: [])
PASS  denied session fixture (run 43069209256 lists the blocked find command in blocked_calls; log.txt has no denial)
PASS  opencode.log fallback (session-less run 43069209257 lists the blocked find command from oc-artifacts-43069209257/opencode.log)
PASS  artifacts-unavailable marker (unavailable/live, missing artifact dir, emits artifacts unavailable)
PASS  negative session parts (run 43069209301 non-error status and run 43069209302 error without denial text both produce blocked_calls: [])
PASS  no model call, no secret printed

Results: 14 passed, 0 failed
```

The `note()` strings in `scripts/test-factory-run-review.sh` must match those PASS lines exactly. The final line must be `Results: 14 passed, 0 failed`.

## Classification

- complexity: standard — the fix spans the blocked-call source selection (session-export tool-part errors and the `opencode.log` artifact), the parse/overlay plumbing in `parse_artifacts`, `enrich_from_artifacts` and `fetch_runs_live_dir`, an artifacts-unavailable marker, and new fixtures/test updates; not a single-line change.
- risk: normal — it changes the review tool's reported output (the live `blocked_calls` list, its `blocked_call` finding, and the new artifacts marker) and is review tooling only (no gates, no spend, no workflow), so not high.
- work_type: code.
- Model routing and reason match the front matter; the harness fills the model fields.

## Cost forecast

Tokens in/cached/out and predicted cost are left for `factory-predict-cost.py` to route; the change is a small, focused edit to one script plus its test and fixtures, expected to fit well under the $1 cap, so no split is planned.

## Manual steps for Michael

None. No workflow, secret, setting or dependency change is required; this is contained to the review script and its tests/fixtures. The live verification of `blocked_calls` on run 43069209256 happens on the next real post-merge review after merge.

## Dependencies

None blocking. Refs #38 (Epic), #166, #188 (the earlier work this issue follows up, already merged), and #190 (the PR whose run exposed the miss, already merged); none block this change.

## Worker prompt

Read issue #193 and `.factory/FACTORY.md` first. Edit `scripts/factory-run-review.py` so live (and `--live-dir`) run reviews derive `blocked_calls` from the agent's own tool output in the downloaded artifacts instead of only the `gh run view --log` text: (1) in `parse_artifacts()`, derive blocked calls from the structured session exports (`usage/session-<n>.json`) — a `type: "tool"` part whose `state.status` is an error (for example `"error"`/`"failed"`) and whose error/output contains the real OpenCode permission-denial text `The user has specified a rule which prevents you from using this specific tool call` counts as a blocked call, with the command string from the part's `state.input` (`input.command` for bash, else the existing `_tool_input_str()` value), deduped by command string; (2) read the `opencode.log` artifact in each artifact root (`oc-artifacts-<id>/opencode.log` / `oc-fix-artifacts-<id>/opencode.log`) and run `detect_blocked_calls()` on it as a fallback, merging and deduping with the session-derived list; (3) in both `enrich_from_artifacts()` and `fetch_runs_live_dir()`, overlay the parsed `blocked_calls` value onto the run facts only when that list is non-empty (the same empty-list guard already used for `tool_events`), so a parsed `[]` cannot wipe a log-derived denial and the `reallog/live` denied `ls` stays reported. Keep the #188 false-positive logic intact: the echoed `OC_INSTRUCTION:` env line and the StepSecurity harden-runner `denied_endpoints` config line must still produce `blocked_calls: []`, and only the agent-tool-line anchor and the session status/error-text check trigger a blocked call. Emit an explicit artifacts-unavailable status: set `artifacts_unavailable: true` (JSON) and render an "artifacts unavailable" line in the markdown when `download_run_artifacts()` fails or the run's artifact directory is missing; do not set it merely because an existing artifact directory has no token or tool data. Add the new field only when it is true (follow the existing optional-key pattern for `gate`/`gate_passed`) so the `--input` expected-*.json files stay byte-identical for unaffected fields. Update `scripts/test-factory-run-review.sh` and the `tests/factory-run-review/` fixtures using the exact paths in ## Files: add `denied/live` for run 43069209256 whose session export has the errored bash `find` denial and whose `log.txt` is a workflow-style log with no denial text (so only session-export parsing can pass); add `denied-log/live` for session-less run 43069209257 whose blocked `find` lives only in `artifacts/43069209257/oc-artifacts-43069209257/opencode.log` (its `log.txt` also has no denial, and there is no session export); add `denied-neg/live` with run 43069209301 (non-error `state.status`) and run 43069209302 (error without the permission-denial text), both asserting `blocked_calls: []`; add `unavailable/live` (`run-list.json` and `pr-head.txt` only, no `artifacts/` directory) asserting the artifacts-unavailable marker; keep `falsepos/live` asserting `blocked_calls: []` and `reallog/live` still detecting its denied `ls`; and update the existing tokenless test so it still passes (tokens JSON-null, timing rendered unavailable, no stray "unavailables" suffix) and also asserts the artifacts-unavailable marker, because tokenless has no `artifacts/` directory. The `note()` / PASS strings must match the ## Verification expected transcript exactly, and the final line must be `Results: 14 passed, 0 failed`. Keep the review deterministic and never print a key, token or env value. Do not edit any protected spend/security script (including `scripts/factory-usage.py` and `scripts/opencode-run-meter.sh`), any existing script other than the two named, or any owner-only file; do not touch `.github/`, `opencode.json`, `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, or `requirements-factory.txt`. Fill the PR template; tick only what you proved. Quote any YAML front-matter value that contains a colon in single quotes.

## Design / approach

Keep the review script a pure transform that never guesses. `blocked_calls` for a live run must come from the agent's own tool output in the downloaded artifacts. The authoritative source is the structured session export (`usage/session-<n>.json`): `events_from_session()` already walks `info.messages[].parts[]` for `type: "tool"` parts; extend it (or add a sibling pass in `parse_artifacts()`) to also look at `state.status` and the part's error/output text, and emit a blocked-call entry when the status is an error and the text matches `PERMISSION_DENIED_RE`, using the part's `state.input` command (bash `input.command`) as the reported command string — the same dedupe-and-sort shape the current `blocked_calls` uses. Fall back to the `opencode.log` artifact (the layout `oc-artifacts-<id>/opencode.log`) by running the existing `detect_blocked_calls()` on that file, which already returns the `find` denial correctly, and merge/dedupe. In both `enrich_from_artifacts()` and `fetch_runs_live_dir()`, copy `blocked_calls` from parsed artifacts only when the parsed list is non-empty, mirroring the `tool_events` handling, so an empty parse cannot overwrite a `log.txt`-derived or record-derived value (this is what keeps `reallog/live` reporting its denied `ls`). The #188 false-positive guarantees hold because the session trigger requires an errored tool part with the exact denial text, and the log fallback reuses `detect_blocked_calls()` which is already anchored to agent tool-result lines. The `denied/live` and `denied-log/live` `log.txt` files are deliberately workflow-style logs with no denial, so a test cannot go green from the existing `log.txt` scan. For artifact unavailability, set `artifacts_unavailable: true` when `download_run_artifacts()` fails or the run's artifact directory is missing (the `--live-dir` equivalent of a failed download), and emit that marker in the JSON and markdown, added only when true so `--input` fixtures stay byte-identical. The existing tokenless fixture has no `artifacts/` directory, so it gets the marker too; its test is updated to assert the marker while keeping its token and timing checks.

## Alternatives considered

Not required for standard/normal, but briefly: keeping the `gh run view --log` text as the primary source and just widening the denial vocabulary was considered and rejected — that log has no agent tool output, so no match can ever be found; reading the downloaded artifacts is the only source that actually carries the denial. Deriving `blocked_calls` only from the `opencode.log` artifact and not the session export was considered; the session export is kept as the authoritative source because it is the same structured source already used for `tool_events`, with the log kept as a fallback for runs that have no session export. Adding the artifacts-unavailable marker unconditionally to the review output was rejected because it would change the byte-identical `--input` expected files; it is added only when true, following the existing optional-key pattern. Leaving the tokenless fixture unchanged was rejected because that fixture has no `artifacts/` directory and would otherwise fail once the marker is implemented; its test is updated to expect the marker.

## Risks, rollback and revert trigger

Risk: deriving blocked calls from session tool-part errors could over-count if a non-denial error text happens to include the permission-denial phrase; mitigated by requiring both `state.status` error AND the exact `PERMISSION_DENIED_RE` text, and by the `denied-neg/live` fixtures (non-error status, and error without denial text, must stay `blocked_calls: []`) plus the #188 false-positive fixture. Risk: putting the denial in `denied/live`'s `log.txt` would let today's `fetch_runs_live_dir()` path pass without reading the session export; mitigated by requiring that `log.txt` to be a workflow-style log with no denial. Risk: overlaying a parsed `blocked_calls: []` in `fetch_runs_live_dir()` would wipe the `reallog/live` denied `ls`; mitigated by requiring the same empty-list guard in `fetch_runs_live_dir()` and `enrich_from_artifacts()`, and by keeping the `reallog/live` assertion. Risk: adding a new review-output field could perturb the byte-identical `--input` checks; mitigated by adding it only when true and running the existing expected-file tests. Rollback is a normal code revert of `factory-run-review.py` and its test/fixture changes. Revert trigger: if a live run or the updated fixtures show a real denied call still not reported in `blocked_calls`, or a false positive reappears from an env echo / harden-runner line, or the `--input` expected-file check breaks, revert.

## What changes in production on merge

The post-merge `/oc` run-review output stops reporting `blocked_calls: []` for runs that actually had a denial: build run 43069209256 now lists its blocked `find` command (and its `blocked_call` finding), sourced from the downloaded session export (falling back to `opencode.log`). Runs with no real denial keep `blocked_calls: []`, and runs whose artifact download fails or whose artifact directory is missing now emit an explicit "artifacts unavailable" marker instead of silently empty `tool_counts` / evidence / routing. The script is invoked in the same place it is today; no workflow, gate, cost, or model-routing behavior changes. No secrets or env values are printed.

## Success metric (baseline, target, how measured)

Baseline (from issue #193 / PR #190): a real denial in build run 43069209256 goes unreported — `python3 scripts/factory-run-review.py --pr 190` reports `blocked_calls: []` for a run with one actual blocked `find` call, because live detection only scans `gh run view --log` text which carries no agent tool output. Target: a live/`--live-dir` review of run 43069209256 reports the blocked `find` command in `blocked_calls` and a `blocked_call` finding, a session-less review of run 43069209257 reports the same `find` from `opencode.log`, and an artifacts-unavailable run (missing artifact directory or failed download) reports the explicit marker rather than silent empties. Measured by the updated `bash scripts/test-factory-run-review.sh` (run by the verification harness; expected final line `Results: 14 passed, 0 failed`) and by the next real post-merge review on main, which should surface a real denial when one occurred and say "artifacts unavailable" when it could not get the artifacts.

## Test plan detail (broken case shown blocked)

Happy path: `tests/factory-run-review/denied/live` for run 43069209256 has a `usage/session-1.json` with one `type: "tool"` bash part whose `state.status` is `"error"`, whose error text contains `The user has specified a rule which prevents you from using this specific tool call`, and whose `state.input.command` is the `find .../tests/factory-run-review -type f | sort` string, plus a workflow-style `log.txt` with no denial text; `--live-dir denied/live` must report that `find` command in `blocked_calls` and a `blocked_call` finding, which today's `log.txt`-only scan cannot do. Fallback path: `tests/factory-run-review/denied-log/live` for session-less run 43069209257 has no session export; the `find` denial lives only in `artifacts/43069209257/oc-artifacts-43069209257/opencode.log`, and `log.txt` has no denial; `--live-dir denied-log/live` must report that `find`. Control cases (must still hold): `falsepos/live` reports `blocked_calls: []` and no `blocked_call` finding (echoed `OC_INSTRUCTION:` + harden-runner `denied_endpoints`), and `reallog/live` still detects its denied `ls` from that fixture's `log.txt` because `fetch_runs_live_dir()` does not let a parsed empty `blocked_calls` overwrite it. Broken case shown blocked: `denied-neg/live` run 43069209301 (non-error `state.status`) and run 43069209302 (error text without the permission-denial phrase) must produce `blocked_calls: []`, so a naive status-only or text-only trigger would fail. Artifacts-unavailable: `unavailable/live` has no `artifacts/` directory and must emit the explicit marker, so a silently-empty implementation would fail; the existing tokenless test is updated to expect that same marker (it also has no `artifacts/` directory) while still asserting tokens/timing stay unavailable and there is no stray suffix. The no-secret sentinel test still passes, and the existing byte-identical `--input` expected-*.json for unaffected fields still passes.

## Security and liability review (`liability-gates.md`)

The script stays read-only (`gh` read calls only), deterministic, and prints no key, token or env value; the sentinel test keeps guarding that. The new fixtures are explicitly sanitized (no secrets, keys, tokens, env values or private paths), matching the existing fixture policy in `tests/factory-run-review/README.md`. No new dependency is introduced (only `scripts/factory-run-review.py` and its test/fixtures change; cost/token computation stays delegated to `scripts/factory-usage.py`). No protected spend/security script, workflow, or owner-only file is touched. Reported denials come only from the agent's own tool output (an errored session tool part with the exact denial text, or an agent-tool-line `opencode.log` match), so the reviewer is not misled into thinking a run attempted a denied command when it did not, and a real denial is no longer hidden.

## Milestones / split plan (when near the cap)

Not required — standard/normal and expected to fit comfortably in one PR well under the cap.
