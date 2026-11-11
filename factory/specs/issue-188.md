<!-- factory-spec v1 -->
---
spec_version: 1
issue: 188
title: 'factory-run-review.py: stop blocked_calls false positives from echoed OC_INSTRUCTION and harden-runner denied_endpoints'
status: approved
complexity: standard
complexity_reason: 'touches the blocked-call detector, the session-JSON/log source selection and the fixtures, plus a regression fixture, but stays within one script and its test'
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
approved_at: '2026-11-11T11:32:22-06:00'
drafted_by: oc-spec-run
---

## Outcome

On live `/oc` run reviews, `scripts/factory-run-review.py` `detect_blocked_calls()` reports a `blocked_call` finding only when the denial comes from the agent's own tool output (a session JSON tool-part error, or an OpenCode tool-result log line in the agent step), never from the echoed `OC_INSTRUCTION:` env line or the StepSecurity harden-runner `denied_endpoints` config line, so run 43052631438 reports 0 blocked calls (not 13) and real denials such as run 42951547485 are still detected.

## Context

Found in the post-merge review of PR #175 (closes #166), run on main at 9af9191. After #166 merged, the tool-count and timing parsing works on live runs, but `detect_blocked_calls()` now flags a `blocked_call` finding on every `/oc` run that ran a model, and all of them are false positives: run 43052631438 reported 13 (0 real denials), run 43055644910 reported 14 (0), run 43065273291 reported 1 (0).

Root cause (in `scripts/factory-run-review.py:647-670`): `detect_blocked_calls()` treats a log line as denied when it contains the real permission-denial text OR any of the bare substrings `denied`, `blocked`, `guardrail` (`factory-run-review.py:661-663`). On the live path the log is the full workflow log, so that fallback matches two non-agent lines on every run: (1) the echoed `OC_INSTRUCTION:` env line GitHub prints on every step, which fires whenever the owner instruction mentions those words or quotes the denial text, and (2) the StepSecurity harden-runner config line `"denied_endpoints":""` printed by the `Pre Harden runner (audit egress)` step, which fires even on a clean run with no matching instruction (run 43065273291). `blocked_calls` is the guardrail signal the post-merge review relies on, so if it always fires real denials are lost in the noise.

## Scope

Edit `scripts/factory-run-review.py` so live (and `--live-dir` offline) run reviews count a blocked call only from the agent's own tool output:

- Drop the bare `denied` / `blocked` / `guardrail` substring fallback when matching the full workflow log on the live path. Only a line that is the real OpenCode permission-denial text (`The user has specified a rule which prevents you from using this specific tool call`) in an agent tool-result line, or a session JSON tool-part error, counts as a blocked call. Do not match `OC_INSTRUCTION:` / env echo lines or harden-runner config JSON (for example the `denied_endpoints` line).
- Keep the denied-command capture from the surrounding `✗` / `→` / `✱` log lines so a real denial still reports its command, as #166 established.
- Keep the existing real denial in run 42951547485 still detected (the `✗ ls -la ... failed` + denial text case).

Update the tests and fixtures: `scripts/test-factory-run-review.sh` and the `tests/factory-run-review/` fixtures. Add a regression fixture built from the real false-positive lines: a GitHub step instruction text (the `OC_INSTRUCTION:` env echo) and a harden-runner config line with `denied_endpoints`. That fixture must produce `blocked_calls: []`. Keep the existing real-denial fixture (run 42951547485) still detecting its denied `ls`, and keep the review deterministic (no model calls, no wall clock, no secret/env value printed).

## Out of scope

Do not edit any protected spend/security script (see `scripts/opencode-artifact-scan.sh --list-protected`); do not edit any existing script other than `scripts/factory-run-review.py` and `scripts/test-factory-run-review.sh`. Do not touch `.github/`, `opencode.json`, any `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, or `requirements-factory.txt`, or any other dot-path. Do not add or re-pin a Python package. Do not edit files that the parallel #34 and #170 specs will touch: `scripts/factory-collect-runs.py`, `site-data/`, `factory/budget.yml`, `factory/dbt`, or `scripts/factory-site-data.py`. Do not change how the session exports or the run meter write logs; the review script only reads them. Do not change the cost/token computation in `factory-usage.py`. Keep the change to one PR of roughly 300 changed lines or less.

## Files

- Edit: `scripts/factory-run-review.py`
- Edit: `scripts/test-factory-run-review.sh`
- Edit: `tests/factory-run-review/README.md` (document the new false-positive regression fixture)
- Create: `tests/factory-run-review/falsepos/live/run-list.json`
- Create: `tests/factory-run-review/falsepos/live/pr-head.txt`
- Create: `tests/factory-run-review/falsepos/live/artifacts/43052631438/log.txt`

## Acceptance criteria

- [ ] A live-style regression fixture whose log contains the echoed `OC_INSTRUCTION:` env line (an instruction that quotes the denial text / uses the words `denied` / `blocked` / `guardrail`) and a harden-runner `denied_endpoints` config line reports `blocked_calls: []` and no `blocked_call` finding.
- [ ] The existing real-denial fixture (run 42951547485) still reports its denied `ls` in `blocked_calls`.
- [ ] The bare `denied` / `blocked` / `guardrail` substring fallback no longer fires on arbitrary workflow-log lines (env echo, harden-runner config, or any non-agent line).
- [ ] `bash scripts/test-factory-run-review.sh` passes, including the new false-positive regression fixture and the still-detected real-denial case.
- [ ] No key, token, or environment value appears in the script's output or stderr (the sentinel test still passes).

## Verification

```bash
bash scripts/test-factory-run-review.sh
```

Expected:
```
PASS  <...all existing checks plus the false-positive regression fixture: echoed OC_INSTRUCTION + harden-runner denied_endpoints produce blocked_calls: [], while the real denial in run 42951547485 is still detected...>
Results: <N> passed, 0 failed
```
The final line must report 0 failed; the new false-positive regression fixture reports `blocked_calls: []`, the real-denial fixture still detects its denied `ls`, and the no-secret-printed sentinel still passes.

## Classification

- complexity: standard — the fix spans the blocked-call detector and the source selection (session JSON vs full-workflow log), plus a new regression fixture and test updates; not a single-line change.
- risk: normal — it changes the review tool's reported output (the `blocked_calls` list and its `blocked_call` finding) and is review tooling only (no gates, no spend, no workflow), so not high.
- work_type: code.
- Model routing and reason match the front matter; the harness fills the model fields.

## Cost forecast

Tokens in/cached/out and predicted cost are left for `factory-predict-cost.py` to route; the change is a small, focused edit to one script plus its test and fixtures, expected to fit well under the $1 cap, so no split is planned.

## Manual steps for Michael

None. No workflow, secret, setting or dependency change is required; this is contained to the review script and its tests/fixtures.

## Dependencies

None blocking. Refs #38 (Epic), #166, #175 (the earlier work this issue follows up), but neither blocks this change; #175 is already merged. The parallel #34 and #170 specs touch different files and do not block this change.

## Worker prompt

Read issue #188 and `.factory/FACTORY.md` first. Edit `scripts/factory-run-review.py` so live (and `--live-dir`) run reviews count a blocked call only from the agent's own tool output: drop the bare `denied` / `blocked` / `guardrail` substring fallback that currently fires on the full workflow log, and instead trigger only on the real OpenCode permission-denial text `The user has specified a rule which prevents you from using this specific tool call` in an agent tool-result line (or a session JSON tool-part error), so the echoed `OC_INSTRUCTION:` env line and the StepSecurity harden-runner `denied_endpoints` config line never produce a `blocked_call` finding; keep the denied-command capture from the surrounding `✗` / `→` / `✱` log lines and keep the existing real denial in run 42951547485 (the `✗ ls ... failed` case) still detected. Update `scripts/test-factory-run-review.sh` and the `tests/factory-run-review/` fixtures: add a regression fixture under `tests/factory-run-review/falsepos/live/` built from the real false-positive lines (an `OC_INSTRUCTION:` env echo that quotes the denial text / uses `denied` / `blocked` / `guardrail`, and a harden-runner `denied_endpoints` line) that must produce `blocked_calls: []`, while the existing real-denial fixture still detects its denied `ls`. Keep the review deterministic, keep `--input` expected output byte-identical for the fields the issue does not touch, and never print a key, token or env value. Do not edit any protected spend/security script (including `scripts/factory-usage.py` and `scripts/opencode-run-meter.sh`), any existing script other than the two named, or any owner-only file; do not touch `.github/`, `opencode.json`, `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, `requirements-factory.txt`, or the files the parallel #34 and #170 specs will touch (`scripts/factory-collect-runs.py`, `site-data/`, `factory/budget.yml`, `factory/dbt`, `scripts/factory-site-data.py`). Fill the PR template; tick only what you proved.

## Design / approach

Keep the review script a pure transform that never guesses. Make `detect_blocked_calls()` distinguish the agent's own tool output from the surrounding workflow noise. The real denial marker is the OpenCode permission-denial text; count a blocked call only when that text appears on an agent tool-result line (a `✗` / `→` / `✱` line, after stripping the `assistant ` role prefix and ANSI codes) or in a session JSON tool-part error. Remove the bare `denied` / `blocked` / `guardrail` substring match from the whole-log fallback, so an `OC_INSTRUCTION:` env echo (which GitHub prints on every step) and the harden-runner `denied_endpoints` config JSON line cannot fire. Preserve the `_denied_command()` capture so a real denial still reports its command from the surrounding log. Add the regression fixture under `tests/factory-run-review/falsepos/live/` (mirroring the `reallog/live/` layout) whose `log.txt` contains the echoed instruction and the harden-runner line and no agent denial, asserting `blocked_calls: []`; keep the existing `reallog` fixture asserting the real denial is still detected.

## Alternatives considered

Not required for standard/normal, but briefly: keeping the bare `denied` / `blocked` / `guardrail` substring fallback but excluding `OC_INSTRUCTION:` and `denied_endpoints` lines by string filter was considered and rejected as brittle (the env echo can appear without a literal `OC_INSTRUCTION:` prefix, and the denial text can appear in any echoed variable); anchoring detection to the agent's own tool-result lines / session tool-part errors is the robust fix and matches how the real denial is actually emitted. Recomputing denials from `usage/session-*.json` tool-part errors only was considered; the log-line source is kept for runs that have no session JSON.

## Risks, rollback and revert trigger

Risk: dropping the substring fallback could stop detecting a real denial whose only signal was a `denied` / `blocked` / `guardrail` word on a live line. Mitigation: real denials in OpenCode always carry the permission-denial text, which is retained as the primary trigger, and the existing run 42951547485 fixture fails loudly if detection regresses. Risk: over-filtering could skip an agent denial that appears on a line the tool-result matcher does not recognize. Mitigation: keep the role-prefix and ANSI handling from #166 and pin behavior with fixtures. Rollback is a normal code revert of `factory-run-review.py` and its test/fixture changes. Revert trigger: if a live run or the updated fixtures show a real denied call no longer reported in `blocked_calls`, or a false positive reappears from an env echo / harden-runner line, revert.

## What changes in production on merge

The post-merge `/oc` run-review output stops flagging a `blocked_call` finding on every run that echoes an instruction or a harden-runner line. A clean run (for example run 43065273291) that previously reported 1 blocked call now reports 0; run 43052631438 drops from 13 to 0 false positives; real denials (run 42951547485) are still reported. The script is invoked in the same place it is today; no workflow, gate, cost, or model-routing behavior changes. No secrets or env values are printed.

## Success metric (baseline, target, how measured)

Baseline (from PR #175): live `/oc` runs report spurious `blocked_call` findings on every model run — run 43052631438 reported 13 with 0 real denials, run 43055644910 reported 14 with 0, run 43065273291 reported 1 with 0. Target: a live (or `--live-dir`) review of the false-positive fixture reports `blocked_calls: []` and no `blocked_call` finding, while the existing real denial in run 42951547485 is still detected. Measured by the updated `bash scripts/test-factory-run-review.sh` (run by the verification harness) and by the next real post-merge review on main, which should report 0 blocked calls on runs with no real denial.

## Test plan detail (broken case shown blocked)

Happy path: a new regression fixture under `tests/factory-run-review/falsepos/live/` built from the real false-positive lines — a GitHub step instruction text (the `OC_INSTRUCTION:` env echo that quotes the denial text / uses `denied` / `blocked` / `guardrail`) and a StepSecurity harden-runner config line with `"denied_endpoints":""` — with no real agent denial. `--live-dir falsepos/live` must report `blocked_calls: []` and no `blocked_call` finding. Control case (must still detect): the existing `reallog/live` fixture (run 42951547485) whose `log.txt` has the real permission-denial text after a `✗ Bash: ls -la ... failed` line must still report that `ls` in `blocked_calls`. Broken case shown blocked: if the substring fallback were still active, the false-positive fixture would report a non-empty `blocked_calls`, and the test asserts it is `[]`; the no-secret sentinel test still passes, and the existing byte-identical `--input` expected-*.json for unaffected fields still passes.

## Security and liability review (`liability-gates.md`)

The script stays read-only (`gh` read calls only), deterministic, and prints no key, token or env value; the sentinel test keeps guarding that. The new regression fixture is explicitly sanitized (no secrets, keys, tokens, env values or private paths), matching the existing fixture policy in `tests/factory-run-review/README.md`. No new dependency is introduced (only `scripts/factory-run-review.py` and its test/fixtures change; cost/token computation stays delegated to `factory-usage.py`). No protected spend/security script, workflow, or owner-only file is touched, and no file that the parallel #34 and #170 specs will touch. Reported denials come only from the agent's own tool output, so the reviewer is not misled into thinking a run attempted a denied command when it did not.

## Milestones / split plan (when near the cap)

Not required — standard/normal and expected to fit comfortably in one PR well under the cap.
