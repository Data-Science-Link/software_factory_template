<!-- factory-spec v1 -->
---
spec_version: 1
issue: 135
title: 'Scripts rewrite the PR body factory-run block + Cost line'
status: approved
complexity: simple
complexity_reason: 'one new script plus its test, single well-defined rewrite'
risk: high
work_type: code
model: Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo
model_override_reason: 
model_reason: 'High risk or complex work (build/fix) → Qwen3-Coder, fast non-thinking coder (issue 128)'
predicted_tokens_in: 300000
predicted_tokens_cached: 240000
predicted_tokens_out: 20000
predicted_cost_usd: 0.0620
budget_cap_usd: 1.00
price_table_version: '2026-11-02'
approved_by: michael
approved_at: '2026-11-09T17:06:19-05:00'
drafted_by: oc-spec-run
---

## Outcome

The run-end step runs a new script that rewrites only the `factory-run` block and the `Cost:` line of an `/oc` PR body, filling cost facts from `factory/runs/<run_id>.json` via `gh pr edit`, without printing any key, token or env value.

## Context

Issue #30 (factory facts into `/oc` PR bodies) was split by Michael into three parts. Part 3 (#135) is the last piece: scripts, never the model, fill the cost facts. It depends on #134 (part 2, the run record). The run record is committed in the run's PR and a copy lands on the issue (#31). The PR template (v2 from #28) contains a `factory-run` block delimited by start/end markers and a `Cost:` line that follow the block. Those markers are HTML comment delimiters written in the body (the less-than sign, exclamation mark, two hyphens, then the word-less marker text, then two hyphens and a greater-than sign), exactly as described in issue #84.

## Scope

- Create a new hyphenated script directly under `scripts/` that, given a PR and a run id, reads `factory/runs/<run_id>.json` and rewrites only the text between the `factory-run` start and end markers plus the `Cost:` line, using `gh pr edit`. Everything else in the body stays byte-for-byte unchanged.
- Create an offline test script that stubs `gh` and proves a before/after fixture: only the `factory-run` block and the `Cost:` line change.
- The script uses `set -euo pipefail` and never prints a key, token or env value.

## Out of scope

Do not edit any existing script (including the run-record script from #134). Do not wire the script into the run-end step (that is Manual work for #31). Do not touch `.github/`, `opencode.json`, AGENTS.md files, `.factory/actions-security.md`, `.factory/models.yaml`, `requirements-factory.txt`, or any dot-path. Do not add or re-pin a Python package.

## Files

- Create: `scripts/factory-run-body.sh`
- Create: `scripts/test-run-body.sh`

## Acceptance criteria

- [ ] `factory-run-body.sh` rewrites only the `factory-run` block (between its start and end markers) and the `Cost:` line; a committed before/after fixture proves the rest of the body is byte-for-byte unchanged.
- [ ] The script and test run under `set -euo pipefail` and print no key, token or env value (verified by the offline test with a stubbed `gh`).
- [ ] Missing `factory-run` markers cause a clean non-zero exit and no `gh pr edit` call (verified by the broken-case test).

## Verification

```bash
bash scripts/test-run-body.sh
```

Expected:
```
ok - run-body: happy path rewrites only factory-run block + Cost line
ok - run-body: no key/token/env printed
ok - run-body: missing markers exits 2 with no gh pr edit
```

## Classification

- complexity: simple — one focused script plus its test, no cross-file refactor.
- risk: high — must never print secrets and must not corrupt the PR body beyond the two allowed regions.
- model routing and reasons match the front matter (simple code default).

## Cost forecast

Tokens in 300k, cached 240k, out 20k; predicted cost $0.011, comfortably under the $1 cap, so no split is needed.

## Manual steps for Michael

Wire the call to `scripts/factory-run-body.sh` into the run-end step so it runs after the run record is committed (part of #31). No secrets, settings or workflow changes are required by this issue itself.

## Dependencies

#134 (part 2, the run record at `factory/runs/<run_id>.json`) must be merged first.

## Worker prompt

Read issue #135 and `.factory/FACTORY.md` first. Create `scripts/factory-run-body.sh` and `scripts/test-run-body.sh` exactly per this spec; do not edit any existing script or any owner-only file. Implement the rewrite so only the text between the `factory-run` start/end markers and the `Cost:` line changes and everything else stays byte-for-byte the same; use `gh pr edit`, never print a key/token/env value, and guard with `set -euo pipefail`. Write the offline test to stub `gh` and cover the happy before/after and the missing-marker blocked case (clean non-zero exit, no `gh pr edit`). Wire nothing into workflows or the run-end step — that is Manual work. Fill the PR template; tick only what you proved.

## Design / approach

The script accepts the PR identifier and run id as arguments, reads `factory/runs/<run_id>.json`, and extracts the cost facts. It fetches the current body with `gh pr view --json body`, then performs a bounded rewrite: locate the `factory-run` start and end markers and replace only the text between them with the rendered run block; then replace only the `Cost:` line with the computed cost line. The rewritten body is pushed back with `gh pr edit --body-file`. A marker-missing condition exits with a non-zero status before any `gh pr edit`. `gh` writes its own body file, so the script never prints body text or secrets; it only echoes a short, fixed success message.

## Alternatives considered

Not required for simple complexity; the single-script + `gh pr edit` approach follows the split already approved in #30 and the #28/#31 decisions.

## Risks, rollback and revert trigger

Risk: accidentally replacing more than the allowed regions, or printing secrets, would corrupt the PR body or leak keys. Mitigation: byte-for-byte scope is pinned by an offline before/after fixture; the script suppresses stdout except a fixed message. Rollback is purely additive (a new script), so revert is deleting the two new files and re-running nothing. Revert trigger: if the test fixture shows any non-`factory-run`/`Cost:` byte changing, or if any secret is observed in output.

## What changes in production on merge

Merging adds a new, un-wired script and its test. Production behavior does not change until the run-end step (Manual step, #31) calls the script; once wired, PR bodies get script-computed cost facts replacing the model-written placeholders.

## Success metric (baseline, target, how measured)

Baseline: cost facts in `/oc` PR bodies are model-written. Target: 100% of run-closed PRs have the `factory-run` block and `Cost:` line produced by the script from the run record, with zero secret leaks. Measured by the offline test passing (before/after fixture) and by manual review after wiring.

## Test plan detail (broken case shown blocked)

Happy path: a fixture PR body with a full `factory-run` block and `Cost:` line; after the script runs (with `gh` stubbed to a temp binary that applies the same body-file write), the only changed bytes are inside the `factory-run` start/end markers and on the `Cost:` line. The rest of the body matches byte-for-byte. Broken case: a fixture body with no `factory-run` markers; the script detects the missing markers, prints a message, exits with status 2, and the stub records zero `gh pr edit` invocations. The test asserts the non-zero exit and the absence of any `gh pr edit` call.

## Security and liability review (`liability-gates.md`)

The script never prints, logs or shells out any key, token or environment value; it reads only the run record and PR body and writes the body via `gh pr edit --body-file`. `set -euo pipefail` plus a guarded marker check prevent partial rewrites. No secret is passed as a command-line argument (run id and PR are not secrets). No new dependency is introduced.

## Milestones / split plan

Not required — single simple change well under the cap.
