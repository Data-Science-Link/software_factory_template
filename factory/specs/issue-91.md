<!-- factory-spec v1 -->
---
spec_version: 1
issue: 91
title: 'Run start A: factory-run-start.py routes the model and checks the issue cap (script only)'
status: approved
complexity: standard
complexity_reason: one new Python script with routing, trust and cap rules, plus an offline test and fixtures
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
approved_at: '2026-11-02T21:54:27-06:00'
drafted_by: grok-bot
---

## Outcome
`scripts/factory-run-start.py` decides, before any DeepInfra spend and without network access, which model a run uses (from `.factory/models.yaml` through the existing router) and whether the issue still has budget under the $1 cap, and `scripts/test-run-start.sh` proves every rule offline.

## Context
- Split from #29 (part of epic #38). Michael wants the model to be fully prescriptive: routing picks it before the run, the workflow forces exactly that model, and the worker can never choose it. Today `scripts/opencode-agent-run.sh` hard-codes V4 Flash and nothing checks prior spend.
- This issue is the script only. Wiring it into the workflows and the agent scripts is #92 (high risk, owner-only paths). Until #92 lands this script runs only in tests.
- The router already exists: `scripts/factory-predict-cost.py --json <spec>` prints `model`, `routed_rule`, `selected_via_rule`, `predicted_cost_usd`, `check_actions`, `budget_cap_usd`, `model_override` and more. A spec's own `model` is kept only when `model_override_reason` is non-empty. Reuse it as a subprocess; don't copy its logic.
- Run records: `.factory/schemas/run-record.schema.json` (`run_id`, `issue`, `actual_cost_usd`). Committed copies live at `factory/runs/<run_id>.json`. Issue copies are comments whose first line is the `factory-run-record` marker, followed by a fenced json block (see `tests/run-records/pass-from-issue-comment.md`), trusted only from user login `github-actions[bot]` (vision §18 decision 1).

## Scope
1. Create `scripts/factory-run-start.py` (Python 3 standard library plus PyYAML, which is already in `requirements-factory.txt`; no network; never prints environment values). CLI:
   `factory-run-start.py --spec SPEC --issue N [--comments-json FILE] [--runs-dir DIR] [--models FILE] [--github-output FILE] [--out FILE]`
   Defaults: `--runs-dir factory/runs`, `--models .factory/models.yaml`, and `--github-output` from `$GITHUB_OUTPUT` when set. `--comments-json` is a JSON array of issue comments shaped like the GitHub REST API (`user.login`, `body`). A missing file means no comments.
2. Exit codes: 0 ok; 2 bad input (non-digit issue, unreadable spec, invalid JSON); 3 refused. On a refusal, print one line `run-start: refused: <reason>` to stderr and write nothing to `--github-output` or `--out`.
3. Spec checks (refuse with 3): front matter `status` must be `approved`, `issue` must equal `--issue`, and `scripts/factory-spec-check.py SPEC` must pass. The spec may start with the `factory-spec v1` marker line (the router already skips it).
4. Model: run `python3 scripts/factory-predict-cost.py --models MODELS --json SPEC` (path relative to this script's directory). Take `model` and `selected_via_rule`. Refuse unless the model is the `id` of an entry in models.yaml `models:` with `provider: deepinfra`, and it matches `^[A-Za-z0-9._/-]+$`. Refuse if `check_actions` is not empty (rule 6 over the cap, rule 8 priority tier).
5. Prior spend for this issue: sum `actual_cost_usd` over (a) every `RUNS_DIR/*.json` whose `issue` equals N, and (b) every comment in `--comments-json` by `github-actions[bot]` whose first line is the `factory-run-record` marker and whose fenced json block has `issue` equal to N. Count each `run_id` once, preferring the committed file. Ignore records from any other author and records that fail to parse, and print a warning line for each skipped record (no record content). Cap = models.yaml `budget.issue_cap_usd`. Refuse if `prior + predicted_cost_usd > cap`, so a prior total that is already at or over the cap is always refused.
6. Output on success, to `--github-output` (append) and stdout, in this order:
   `model=deepinfra/<id>`, `model_id=<id>`, `routed_rule=<n>`, `predicted_cost_usd=<4 decimals>`, `prior_spend_usd=<4 decimals>`, `cap_usd=<2 decimals>`, `run_id=gha-<GITHUB_RUN_ID>-<GITHUB_RUN_ATTEMPT>` (`gha-local-1` when those are unset). With `--out`, also write the same keys as a sorted-key JSON object. No timestamps anywhere, so the same inputs give byte-identical output.
7. Create `scripts/test-run-start.sh` (offline, `set -euo pipefail`, `mktemp -d` work dir, prints `PASS`/`FAIL` per case and `Results: <n> passed, <m> failed`, exits 1 on any failure) and fixtures under `tests/run-start/`. Cases:
   - approved simple normal spec, no prior runs: exit 0; `model=deepinfra/deepseek-ai/DeepSeek-V4-Flash-0731`, `routed_rule=3`, `prior_spend_usd=0.0000`
   - approved high-risk spec: `model=deepinfra/deepseek-ai/DeepSeek-V4-Pro-0813`, `routed_rule=1`
   - spec with `model: Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo` and an empty `model_override_reason`: re-routed to Flash (the spec cannot pick the model)
   - draft spec: exit 3, nothing written to the output file
   - spec for issue 7 run with `--issue 8`: exit 3
   - prior spend from a runs-dir file (0.40) plus a trusted comment record (0.30, another run_id): `prior_spend_usd=0.7000`, exit 0
   - the same comment record posted by `someone-else`: ignored
   - the same run_id in a runs-dir file and a trusted comment: counted once
   - prior 0.995 plus the predicted cost: exit 3 with `run-start: refused:` on stderr
   - a models fixture whose `token_priors` make the prediction exceed $1: exit 3 (rule 6)
   - two runs with identical inputs give byte-identical stdout; `GITHUB_RUN_ID=11 GITHUB_RUN_ATTEMPT=2` gives `run_id=gha-11-2`
   - with `DEEPINFRA_API_KEY=fake-key-run-start-123` set, that string appears in no output or file

## Out of scope
- Any edit to `.github/`, `.factory/models.yaml`, `requirements-factory.txt` or any existing script (including `opencode-agent-run.sh`, which keeps forcing Flash until #92).
- Fetching comments from GitHub (#92 adds a read-only workflow step for that), run end and records (#30), the gate (#31), spec-run costs from `/oc spec` draft comments (later).
- `factory/specs/issue-91.md`: the harness writes it; don't create or edit it.

## Files
- Create: `scripts/factory-run-start.py`, `scripts/test-run-start.sh`, `tests/run-start/` fixtures (specs, runs-dir JSON files, comments JSON, a models fixture)
- Read first: `scripts/factory-predict-cost.py`, `scripts/factory-spec-check.py`, `.factory/models.yaml`, `.factory/schemas/run-record.schema.json`, `tests/run-records/pass-from-issue-comment.md`, `tests/specs/pass-simple.md`, `scripts/test-predict-cost.sh` (test style)

## Acceptance criteria
- [ ] `scripts/factory-run-start.py` implements Scope 1 to 6; refusals exit 3 and write no outputs
- [ ] The model always comes from the router and must be a deepinfra model in models.yaml; a spec's `model` without an override reason is ignored (test output)
- [ ] Prior spend counts only `github-actions[bot]` comment records and committed run files for this issue, deduplicated by run_id (test output)
- [ ] Over-cap runs are refused before any spend (test output)
- [ ] Outputs are byte-stable and contain no environment values (test output)
- [ ] `bash scripts/test-run-start.sh` passes every case in Scope 7

## Verification
```bash
python3 -m pip install -q -r requirements-factory.txt
bash scripts/test-run-start.sh
bash scripts/test-predict-cost.sh | tail -n 1
git diff --name-only HEAD~1 | sort
```
Expected: every test-run-start line `PASS` and a final `Results: <n> passed, 0 failed`; test-predict-cost still reports 0 failed; changed files are `factory/specs/issue-91.md`, `scripts/factory-run-start.py`, `scripts/test-run-start.sh` and files under `tests/run-start/` only.

## Classification
- Complexity: standard (one script with several rules, plus fixtures).
- Risk: normal. Merging changes nothing at runtime. The spend-path wiring is #92 (high, Michael).
- Model: `deepseek-ai/DeepSeek-V4-Flash-0731` (models.yaml rule 3).

## Cost forecast
Standard prior: 1M in (800K cached), 50K out on V4 Flash, predicted about $0.033. Cap $1.00.

## Manual steps for Michael
None for this issue. #92 holds the workflow paste and the agent-script change. Proposed files are at `/workspace/phase2-wf/29/` on Grok Bot's box.

## Dependencies
None to build. #92 depends on this.

## Worker prompt
Read issue #91 and `.factory/FACTORY.md` first. Then read `scripts/factory-predict-cost.py`, `scripts/factory-spec-check.py`, `.factory/models.yaml`, `.factory/schemas/run-record.schema.json`, `tests/run-records/pass-from-issue-comment.md` and `scripts/test-predict-cost.sh`. Create `scripts/factory-run-start.py`, `scripts/test-run-start.sh` and fixtures under `tests/run-start/`, following Scope 1 to 7 of this spec exactly: call the existing router as a subprocess rather than copying it, trust comment records only from `github-actions[bot]`, deduplicate by run_id, refuse with exit 3 and no outputs, and keep outputs free of timestamps and environment values. Cover every test case listed in Scope 7. Don't edit any existing file, `.github/`, `.factory/models.yaml` or `requirements-factory.txt`. Keep the change under about 300 lines plus fixtures. Fill the PR template; tick only what you proved

## Design / approach
A thin decision script that takes everything as files (spec, comments JSON, runs dir, models.yaml), so it is deterministic and fully testable offline. The workflow (#92) does the fetching with a read-only token. Routing stays in one place (`factory-predict-cost.py`), so the router and run start can't drift. The budget check uses recorded actual costs (committed and trusted issue copies) plus this run's prediction, the conservative reading of the $1 per-issue cap.

## Risks, rollback and revert trigger
- Risk: wrong refusals once wired (a false over-cap) or a missed record (under-counting). Fixtures cover both trust and dedupe. Until #92 lands, the script has no runtime effect.
- Rollback: revert the merge commit.
- Revert trigger (number-checkable, after #92): a run refused while the issue's summed `actual_cost_usd` plus prediction is under the cap, or a run allowed when it is over.

## What changes in production on merge
Nothing at runtime. A new script and its tests land; `/oc` still forces V4 Flash until #92.

## Success metric (baseline, target, how measured)
- Baseline: the model is hard-coded in `opencode-agent-run.sh`, and no pre-run cap check exists.
- Target: after #92, 100% of `/oc` runs record `model` and `routed_rule` from this script before spend, and 0 runs start on an issue whose recorded spend plus prediction is above $1.
- How measured: `bash scripts/test-run-start.sh` now; after #92, the run-start step output in each run's log and the run record's `model` field.
