<!-- factory-spec v1 -->
---
spec_version: 1
issue: 136
title: Deterministic post-merge /oc run-review script (factory-run-review.py)
status: approved
complexity: standard
complexity_reason: one analysis script, a fixed finding-code catalog and an offline test with three fixtures; more than a single trivial script
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
approved_at: '2026-11-09T19:28:47-06:00'
drafted_by: oc-spec-run
---

## Outcome

A new read-only script, `scripts/factory-run-review.py`, takes a PR number (or its linked issue), finds that PR's `/oc` workflow runs via `gh`, and emits a deterministic, key-sorted JSON summary plus a short markdown summary of each run — model, routing rule, wall time, timeout, cost (delegating to `scripts/factory-usage.py`), tool-call counts, blocked calls, out-of-spec reads, seconds-per-tool-turn and stalls, scan/evidence results, and a fixed catalog of severity-coded findings — so the same input always produces byte-identical output.

## Context

Issue #136 is a child of #38 (factory harness). Today the /oc review picks come from reading run logs by hand: V4 Pro's ~35s of thinking per tool call, workers running `ls`/`glob` on `.factory/`, blocked `mkdir`/`chmod`/`git commit` calls, reading files beyond the spec's `## Files`, and stalls at 780s. That review needs to be deterministic and cheap, and — key point in the issue — the goal is to make smart models productive inside guardrails, not to route everything to Flash. It depends on #30 part 1 (`scripts/factory-usage.py`, already on `main`), which it calls as a library/helper for per-run cost and token counts.

## Scope

- Create `scripts/factory-run-review.py` (Python 3, stdlib only, plus running `scripts/factory-usage.py` as a subprocess). No model calls; scripted only; `gh` used read-only (`gh pr view`, `gh run view`, `gh run list`, `gh api`).
- Input: a PR number or an issue number (resolves the issue's PR via `gh`). Optionally `--pr <n>` / `--issue <n>` and `--output <path>` (default stdout).
- For each matching `/oc` workflow run it reports: `run_id`, model + routing rule, wall time, timeout hit (`true`/`false`), cost and token counts (from `factory-usage.py`), tool-call counts by tool, denied/blocked calls (by command string), reads outside the spec's `## Files`, seconds per tool turn, long gaps or stalls, and the artifact-scan/harness-evidence result.
- Emit a fixed list of finding codes with severity. `high` = run failed, or wasted more than $0.10, or a guardrail was bypassed. `low` = inefficiency. The code meanings are a committed, stable table.
- Output is key-sorted (`json.dumps(..., indent=2, sort_keys=True)`) plus a short markdown rendering; deterministic for identical input (fixtures prove byte-identical output).
- Create an offline test, `scripts/test-factory-run-review.sh`, backed by sanitized fixtures in a new `tests/factory-run-review/` directory.

## Out of scope

Do not edit any existing file under `scripts/`. Do not touch `.github/`, `opencode.json`, AGENTS.md files, `.factory/actions-security.md`, `.factory/models.yaml`, `requirements-factory.txt`, or any dot-path. Do not add or re-pin a Python package. The Grok Bot post-merge routine (file/update one issue per finding code, `priority:high`/`priority:low` labels, dedupe) is issue #136's "Then" section and is explicitly not this PR — it is listed under Manual steps for Michael. Do not wire the script into any workflow.

## Files

- Create: `scripts/factory-run-review.py`
- Create: `scripts/test-factory-run-review.sh`
- Create: `tests/factory-run-review/run-42282682618.json`
- Create: `tests/factory-run-review/run-42290238204.json`
- Create: `tests/factory-run-review/run-42297659590.json`
- Create: `tests/factory-run-review/expected-42282682618.json`
- Create: `tests/factory-run-review/expected-42290238204.json`
- Create: `tests/factory-run-review/expected-42297659590.json`
- Create: `tests/factory-run-review/README.md`
- Read first: `scripts/factory-usage.py`, `scripts/test-factory-usage.sh`, `tests/factory-usage/README.md`

## Acceptance criteria

- [ ] `factory-run-review.py` accepts a PR or issue number, finds the run(s) read-only with `gh`, and prints a key-sorted JSON summary followed by a short markdown summary.
- [ ] The three fixtures (runs 42282682618 V4 Pro timeout, 42290238204 artifact-scan block, 42297659590 Qwen stall) each produce the byte-identical expected JSON, proven by the test comparing `python3 scripts/factory-run-review.py` output to the committed `expected-*.json` with `cmp`.
- [ ] Finding codes are a fixed catalog with `severity` `high`|`low` per the issue's definitions; `high` for failed / >$0.10 / guardrail bypass, `low` for inefficiency.
- [ ] The script makes no model calls and reads no key, token or env value; the test sets a sentinel in the environment and proves it never appears in output.
- [ ] Cost/token figures are obtained by delegating to `scripts/factory-usage.py`, not recomputed independently.

## Verification

```bash
bash scripts/test-factory-run-review.sh
```

Expected:

```
PASS  run 42282682618 byte-identical
PASS  run 42290238204 byte-identical
PASS  run 42297659590 byte-identical
PASS  no model call, no secret printed
Results: 4 passed, 0 failed
```

## Classification

- Complexity: standard. One analysis script with deterministic parsing, a fixed finding-code catalog, and three offline fixtures, but a single well-defined deliverable — more than a trivial one-liner, short of a cross-file refactor.
- Risk: normal. Read-only, produces only a report, touches no secrets, no production behavior, no financial/cap figures, and is not wired into any workflow. It does not gate merges or spend.
- Model: default for standard code (`deepseek-ai/DeepSeek-V4-Flash-0731`); `model_override_reason` left empty to let routing decide.

## Cost forecast

Standard prior: 300k tokens in (240k cached), 20k out, about $0.011 against a $1.00 cap. Expected size roughly 200 lines of Python, 80 lines of test shell, and three small sanitized fixtures. No split needed.

## Manual steps for Michael

None to merge this PR. The Grok Bot post-merge routine that files/updates one issue per finding code (with `priority:high`/`priority:low` and dedupe) is the "Then" section of #136 and is turned on after #30 part 1 lands; it is configured by the owner, not by this worker.

## Dependencies

#30 part 1 (`scripts/factory-usage.py`) is already on `main` (`1bc1110`). No other blocking issue or PR.

## Worker prompt

Read issue #136 and `.factory/FACTORY.md` first. Create `scripts/factory-run-review.py`, `scripts/test-factory-run-review.sh`, and the `tests/factory-run-review/` fixtures and expected outputs, exactly per this spec. The script is Python 3, stdlib only, no model calls, `gh` read-only; it resolves a PR or issue to its `/oc` runs, delegates tokens/cost to `scripts/factory-usage.py` as a subprocess, and emits key-sorted JSON plus a short markdown summary with the fixed finding-code catalog (severity `high` for failed / >$0.10 / guardrail bypass, `low` for inefficiency). The three fixtures stand in for the real runs named in the issue and must be sanitized, with no secrets; the test proves byte-identical output against the committed `expected-*.json` and that a sentinel env value never appears in output. Do not edit any existing script, `.github/`, or any owner-only file; do not write under `factory/runs/`; do not wire anything into a workflow or into the Grok Bot routine. Create only the new files listed under `## Files`. Fill the PR template; tick only what you proved.

## Design / approach

The script splits cleanly: a pure transform from run facts (workflow run metadata, job logs, `factory-usage.py` output, the spec's `## Files` list) into one JSON object, then two renderers (JSON and a short markdown block). Determinism is guaranteed by `sort_keys=True`, fixed key order, sorted lists, fixed timestamp rounding, and a committed finding-code table — no wall-clock, no random IDs, no model calls. The `gh` calls are read-only (`gh pr view`, `gh run list`, `gh run view --log`, `gh api` for issue links) and are disabled in the test via `GH_TOKEN`-less fixtures: the test feeds the review script its parsed input directly from the fixture files, so byte-identical output is checkable offline with `cmp` against the committed expected files.

Denied/blocked calls and out-of-spec reads are detected by matching the run log against the guardrail command vocabulary (`mkdir`, `chmod`, `git commit`, `ls`/`glob` on `.factory/`, `cat`/`find`, etc.) and against the spec's `## Files` list parsed from the approved spec. Seconds-per-tool-turn is computed from consecutive tool timestamps in the log; a gap over a threshold (e.g. 780s) is a stall finding.

## Alternatives considered

Optional for standard/normal — noted for the record: implementing cost from `factory-usage.py` as an in-process import rather than a subprocess was considered and kept as a subprocess, so it never duplicates or drifts from the canonical `factory-usage.py` logic.

## Risks, rollback and revert trigger

Risk: log format drift or a renamed workflow could make findings noise. Mitigation: the script degrades gracefully (unknown fields become `null`, never guessed) and the fixtures pin current behavior. Risk: reading too much into the log could flag legitimate commands; mitigation: the finding catalog is fixed and conservative, matching only the documented guardrail command set. Rollback: purely additive — revert the merge commit. Revert trigger: any byte change in the three expected outputs after an unrelated log-format change is not silently accepted; the test fails and the finding-catalog table is the only place to update.

## What changes in production on merge

Adds an un-wired reporting script and its offline tests. Nothing runs automatically; no PR body, record, workflow, or financials path changes.

## Success metric (baseline, target, how measured)

Baseline: run review is manual, from hand-read logs, with no reproducible result. Target: the three named real runs each produce a byte-identical, severity-coded summary on every invocation. Measured by `bash scripts/test-factory-run-review.sh` printing `Results: 4 passed, 0 failed`.
