<!-- factory-spec v1 -->
---
spec_version: 1
issue: 159
title: 'factory-run-review.py live --pr/--issue misses spec runs and leaves null tokens/tool stats'
status: approved
complexity: standard
complexity_reason: 'touches run selection and artifact/record enrichment across the live and offline paths, plus their fixtures'
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
approved_at: '2026-11-10T21:15:23-06:00'
drafted_by: oc-spec-run
---

## Outcome

`scripts/factory-run-review.py --pr` / `--issue` includes the `opencode-spec` run(s) for the linked issue so the summed cost matches the PR Cost line, and fills tokens (and tool/gap stats where the #31 run record or artifacts carry them) instead of leaving silent `null`s, with the output saying when a field was unavailable.

## Context

Found in the post-merge /oc run review of #154 (closes #136), the first live use of `scripts/factory-run-review.py --pr 154` on main (be0e420). The live `--pr` path listed the build run and the two fix runs (about $0.113 total) but missed the `opencode-spec` runs on #136, so the summed cost fell short of the PR's own `Cost:` line of $0.1996 (about $0.087 missing). Every run came back with `tokens` all `null`, empty `tool_counts`, and `null` for `longest_gap_seconds` and `seconds_per_tool_turn`, even though the PR body carries token counts (351.4K in / 1.4M cached / 35.1K out for the build). This weakens the post-merge review: the stall, slow-turn and spinning checks can only fire on offline fixtures, not on live runs. No spend was wasted and main stayed green. Refs #38, #136.

## Scope

Edit `scripts/factory-run-review.py` so the live `--pr`/`--issue` path:

- Selects the `opencode-spec` run(s) for the linked issue. The fix belongs in `select_oc_runs` / the run-selection logic (factory-run-review.py:397-430): spec runs for the issue, including those with `headBranch` `main` whose `displayTitle` does not carry the PR's build run id, must be matched to the issue (for example by the issue number in `displayTitle`, by a matching `#31` run record on the issue, or by the spec run's own build linkage). Spec runs already selected via the #31 record path must keep working.
- Fills `tokens`, `tool_counts`, `seconds_per_tool_turn` and `longest_gap_seconds` from the #31 run record and/or downloaded artifacts (`run-record.json`, `opencode-export.json`, `run-start.json`, tool-event sources) wherever those sources carry the data, matching what `review_run` / `_tokens_from_run` / `tool_turn_stats` consume. When a value is genuinely unavailable it should be reported as unavailable rather than left as a silent `null` where the issue expects an explanation.

Update the tests and fixtures to match: `scripts/test-factory-run-review.sh` and `tests/factory-run-review/` (the `live/`, `records/` and `fallback/` fixtures and any committed `expected-*.json` / fixture `run-list.json` / `run-record` files the script reads). The live fixture currently asserts spec runs are excluded (test-factory-run-review.sh:56); that must flip to assert the spec run for the linked issue IS selected and its tokens/cost populated.

Do not change the `## Verification` contract or the byte-identical `--input` behavior for fields the issue does not touch; keep the review deterministic (no model calls, no wall clock in output, no secret or env value printed).

## Out of scope

Do not edit any protected spend/security script (see `scripts/opencode-artifact-scan.sh --list-protected`), in particular `scripts/factory-predict-cost.py`, `scripts/factory-usage.py`, or any other script on the protected list; do not edit any existing script other than `scripts/factory-run-review.py` and `scripts/test-factory-run-review.sh`. Do not touch `.github/`, `opencode.json`, any `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, `requirements-factory.txt`, or any other dot-path. Do not add or re-pin a Python package. Do not change the cost/token computation itself in `factory-usage.py`; only the review script's selection and enrichment. Keep the change to one PR of roughly 300 changed lines or less.

## Files

- Edit: `scripts/factory-run-review.py`
- Edit: `scripts/test-factory-run-review.sh`
- Edit: `tests/factory-run-review/live/run-list.json`
- Edit: `tests/factory-run-review/live/pr-head.txt` (only if needed to express the new fixture)
- Edit: `tests/factory-run-review/records/issue-comments.json`
- Edit: `tests/factory-run-review/fallback/run-list.json`
- Edit: `tests/factory-run-review/expected-42282682618.json`
- Edit: `tests/factory-run-review/expected-42290238204.json`
- Edit: `tests/factory-run-review/expected-42297659590.json`

## Acceptance criteria

- [ ] `--pr`/`--issue` (and the offline `--live-dir` path) includes the `opencode-spec` run(s) for the linked issue, and the summed `cost_usd` equals the PR Cost line when all runs are accounted for, or the output states why not.
- [ ] Live runs fill `tokens`, `tool_counts`, `seconds_per_tool_turn` and `longest_gap_seconds` from the #31 run record and/or artifacts wherever those sources have the data; fields that are genuinely missing stay JSON `null` and the rendered (human-readable) output says "unavailable" for them; do not put the string "unavailable" into JSON fields.
- [ ] `bash scripts/test-factory-run-review.sh` passes, including an updated live fixture that proves the spec run for the issue is selected and populated, and a broken case that proves a genuinely token-less run reports unavailable rather than fabricating values.
- [ ] No key, token, or environment value appears in the script's output or stderr (the sentinel test still passes).

## Verification

```bash
bash scripts/test-factory-run-review.sh
```

Expected:
```
PASS  <...all updated checks...>
Results: <N> passed, 0 failed
```
The final line must report 0 failed; all updated checks (spec-run selection for the linked issue, token/tool/gap population from record and artifacts, the unavailable-not-null broken case, and the no-secret-printed sentinel) pass.

## Classification

- complexity: standard — the fix spans run selection plus record/artifact enrichment and their fixtures; not a single-line change.
- risk: normal — it changes the review tool's reported output (which runs are listed and what stats are shown) but is priority-low, only weakens post-merge review, and prints no secrets; not high.
- work_type: code.
- Model routing and reason match the front matter; the harness fills the model fields.

## Cost forecast

Tokens in/cached/out and predicted cost are left for `factory-predict-cost.py` to route; the change is a small, focused edit to one script plus its tests and fixtures, expected to fit well under the $1 cap, so no split is planned.

## Manual steps for Michael

None. No workflow, secret, setting or dependency change is required; this is contained to the review script and its tests/fixtures.

## Dependencies

None blocking. Refs #38 (run-record #31 path) and #136, but neither blocks this change; #136 is already merged.

## Worker prompt

Read issue #159 and `.factory/FACTORY.md` first. Edit `scripts/factory-run-review.py` so the live `--pr`/`--issue` path selects the `opencode-spec` run(s) for the linked issue (the current `select_oc_runs` / `_title_matches_pr` logic at factory-run-review.py:397-430 misses spec runs whose `headBranch` is `main` and whose `displayTitle` does not carry the PR build run id) and so live runs fill `tokens`, `tool_counts`, `seconds_per_tool_turn` and `longest_gap_seconds` from the #31 run record and downloaded artifacts, reporting genuinely missing fields as unavailable rather than silent `null`s. Update `scripts/test-factory-run-review.sh` and the `tests/factory-run-review/` fixtures (including flipping the live fixture that currently asserts spec runs are excluded, and any `expected-*.json`) to prove the new behavior and a broken token-less case. Do not edit any protected spend/security script (including `scripts/factory-predict-cost.py` and `scripts/factory-usage.py`), any existing script other than the two named, or any owner-only file; do not touch `.github/`, `opencode.json`, `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, or `requirements-factory.txt`. Keep the review deterministic and never print a key, token or env value. Fill the PR template; tick only what you proved.

## Design / approach

Keep the review script a pure transform that never guesses. Selection: extend the run-matching so an `opencode-spec` run belongs to the reviewed PR's issue when its `displayTitle` references the issue (`issue #<N>`), when it matches the build linkage, or when a #31 `<!-- factory-run-record -->` comment on the issue already carries that run id; a spec run that matches only one of these still counts exactly once (dedupe by numeric run id, as `fetch_runs` already does via `facts_by_id`). Enrichment: reuse the existing `enrich_from_artifacts` and `facts_from_record` overlay so record `tokens_in/cached/out/reasoning` and artifact-derived token/tool data flow into the facts that `review_run` / `_tokens_from_run` / `tool_turn_stats` read; where none of those sources has a field, leave it `null` and have the rendered output say it was unavailable rather than presenting it as an actual zero or value. Clarification at approval: keep JSON values `null` and print "unavailable" only in rendered output. Keep `--input` byte-identical output for the unaffected fields so the committed `expected-*.json` files stay meaningful.

## Alternatives considered

Not required for standard/normal, but briefly: a fallback that recomputes tokens purely from workflow logs was rejected as too lossy and non-deterministic; instead prefer the authoritative #31 record and artifact sources, which is exactly where the issue says the data already lives. Computing cost differently from `factory-usage.py` was rejected because it must not drift from the canonical implementation.

## Risks, rollback and revert trigger

Risk: over-selecting unrelated spec runs (false positives that inflate the summed cost) or double-counting a run already present via both the record and workflow paths. Mitigations: dedupe by numeric run id, gate spec-run selection on an explicit issue match, and pin behavior with the updated fixtures. Risk: fabricating token/tool values when no source has them; mitigated by reporting unavailable rather than guessing. Rollback is a normal code revert of `factory-run-review.py` and its test/fixture changes. Revert trigger: if the updated fixtures or a live run show an unrelated spec run being counted, a run double-counted, or a fabricated (non-null) token/tool value with no source, revert.

## What changes in production on merge

The post-merge `/oc` run-review output starts listing the `opencode-spec` run(s) for the reviewed issue, so the summed `cost_usd` matches the PR Cost line, and it starts filling tokens/tool/gap stats from the #31 records and artifacts instead of reporting `null`s. The script is invoked in the same place it is today; no workflow, gate, or model-routing behavior changes. Output for genuinely unavailable fields changes from a silent `null` to an explicit unavailable note.

## Success metric (baseline, target, how measured)

Baseline (from #159): a live `--pr` review lists only the build and fix runs, misses the spec run(s) (~$0.087 short of the PR Cost line), and reports all-`null` tokens and empty tool/gap stats even when the PR body shows real token counts. Target: a live `--pr`/`--issue` review on a PR with spec runs lists every `/oc` run for the issue so the summed cost equals the PR Cost line (or says why not), and populates tokens/tool/gap from the record or artifacts where they exist. Measured by the updated `bash scripts/test-factory-run-review.sh` (run by the verification harness) and by the next real post-merge review on main.

## Test plan detail (broken case shown blocked)

Happy path: the updated `live/` fixture carries a spec run for the linked issue in `run-list.json` (e.g. `headBranch` `main`, no build-run id in the title but matching `issue #<N>`); the test asserts that spec run IS selected and that its `tokens`/`cost_usd` are populated from the artifact/record, alongside the existing build and fix runs, and that an unrelated spec/build run stays excluded. Run-record path: `records/issue-comments.json` already selects a spec run and populates model/cost/tokens/gate; extend assertions to tokens non-null. Broken case: a fixture whose run has no token source asserts the field is reported as unavailable (explicit) rather than a silent `null` or a fabricated value, and the no-secret sentinel test still passes. The previous live assertion that spec runs are excluded (test-factory-run-review.sh:56) is removed or flipped so the test cannot pass while the bug is present.

## Security and liability review (`liability-gates.md`)

The script stays read-only (`gh` read calls only), deterministic, and prints no key, token or env value; the sentinel test keeps guarding that. No new dependency is introduced (only `scripts/factory-run-review.py` and its test/fixtures change; cost/token computation stays delegated to `factory-usage.py`). No protected spend/security script, workflow, or owner-only file is touched. Reported values come only from the #31 records and downloaded artifacts; the script never fabricates a number, so a reviewer cannot be misled into thinking a run was cheaper or healthier than it was.

## Milestones / split plan (when near the cap)

Not required — standard/normal and expected to fit comfortably in one PR well under the cap.
