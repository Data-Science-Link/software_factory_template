<!-- factory-spec v1 -->
---
spec_version: 1
issue: 134
title: '#30 part 2: factory-run-end.sh writes the run record + key-spend cross-check'
status: approved
complexity: standard
complexity_reason: one record builder, a thin shell wrapper and one test script; fixed
  inputs, no network, no PR edits, no workflow changes
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
approved_at: '2026-11-07T13:22:00-06:00'
drafted_by: grok-bot
---

## Outcome

`scripts/factory-run-end.sh` writes one schema-valid run record, `factory/runs/<run_id>.json`, for an `/oc` run. Inputs are the run start state, the approved spec, OpenCode session exports (parsed by `scripts/factory-usage.py`) and an optional DeepInfra key-spend snapshot. The cost is computed by script from `.factory/models.yaml` prices and cross-checked against the key spend, so OpenCode's unrecorded title-generation calls can't hide spend. `scripts/test-run-end.sh` proves it offline with the real `tests/factory-usage/` fixtures.

## Context

- Part 2 of 3 of #30 (split approved by Michael on 2026-11-07). Part 1 (#133, PR #138) put `scripts/factory-usage.py` on `main`. Part 3 (#135) rewrites the PR body; #31 posts records and wires the workflow.
- `scripts/factory-usage.py <export.json>...` prints one sorted-key JSON line: `models`, `opencode_cost_usd` (number or `null`), `requests`, `sessions`, `source`, `tokens_cached`, `tokens_in` (includes cache), `tokens_out`, `tokens_reasoning`. It exits 2 for usage errors and 3 for bad or absent usage, with empty stdout.
- `scripts/factory-run-start.py --out "$OC_ARTIFACT_DIR/run-start.json"` writes `cap_usd`, `model` (`deepinfra/<id>`), `model_id`, `predicted_cost_usd`, `prior_spend_usd`, `retry_of`, `route_reason`, `routed_rule` and `run_id` (`gha-<GITHUB_RUN_ID>-<GITHUB_RUN_ATTEMPT>`). Its `prior_spend_usd` sums `actual_cost_usd` over records with the same `issue` and `run_id`, so the records written here are what make the per-issue cap count real builds.
- The record shape is `.factory/schemas/run-record.schema.json` (`additionalProperties: false`, 48 required fields). The example to copy is `tests/run-records/pass-failed-no-pr.json`. `scripts/factory-validate-run.py` checks the schema, `run_id` against the file name, UTC `Z` timestamps, and, when `cost_method` is `usage_x_price_table`, `actual_cost_usd` against `cost_from_usage(tokens_in, tokens_cached, tokens_out, prices)` within $0.0001.
- **Title-generation gap** (`tests/factory-usage/README.md`): OpenCode makes one title request per session that appears in neither export nor stats. On real runs that's real DeepInfra spend. The key-spend delta catches it.
- `scripts/deepinfra-cost.sh spend` prints the key's current spend (needs the Actions-only key and network). This part doesn't call it (see Design); the workflow wiring in #31 calls it before and after the agent step and writes the snapshot file read here.

## Scope

Create only **new** files:

1. `scripts/factory-run-record.py` (Python 3, stdlib plus PyYAML from `requirements-factory.txt`). It builds the record and prints it as `json.dumps(record, indent=2, sort_keys=True)` to stdout.
   - **Inputs**, all from `$OC_ARTIFACT_DIR` plus env:
     - `run-start.json` (optional; see the degrade rules).
     - `spec.md` (required): the `issue`, `complexity`, `risk` and `work_type` values from its YAML front matter (between the two `---` lines after the spec marker line).
     - `usage.json` (optional): the `factory-usage.py` output. The wrapper writes it.
     - `key-spend.json` (optional): `{"start_usd": number, "end_usd": number, "concurrent": bool}`.
     - `gate.json` (optional): an object with the 8 schema gate keys. Each missing key is `"skip"`.
   - **Required env:** `OC_ARTIFACT_DIR`, `GITHUB_REPOSITORY`, `GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT`, `OC_STARTED_AT`, `OC_ENDED_AT`, `OC_BASE_SHA`, `OC_HEAD_SHA`, `OC_OUTCOME` (a schema `outcome` value).
   - **Optional env:**
     - `OC_PR_NUMBER`: `pr`, else `null`.
     - `OC_TRIGGER_URL` and `OC_SPEC_LINK`: each defaults to `https://github.com/<repo>/issues/<issue>`.
     - `GITHUB_ACTOR`: `triggered_by`, default `unknown`.
     - `GITHUB_EVENT_NAME`: `trigger`, default `issue_comment`.
     - `OPENCODE_VERSION`: `harness_version`, default `unknown`.
     - `OC_RUNNER`: default `ubuntu-latest`.
   - **Fixed fields:**
     - `schema_version` 1, `harness` `opencode-github-action`, `provider` `deepinfra`, `escalated_from` `null`.
     - `issues` is `[issue]` and `spec_path` is `factory/specs/issue-<issue>.md`.
     - `workflow_run_url` is `https://github.com/<repo>/actions/runs/<GITHUB_RUN_ID>`.
     - `run_id` is `gha-<GITHUB_RUN_ID>-<GITHUB_RUN_ATTEMPT>`.
     - `duration_s` is `ended - started` and `actions_minutes` is `ceil(duration_s / 60)`.
     - `gate_passed` is `true` only when all 8 gates are `"pass"`.
   - **Start state is trusted** only when `run-start.json` parses and its `run_id` equals the env `run_id`. Then:
     - `model` = `model_id`.
     - `predicted_cost_usd`, `budget_cap_usd` (= `cap_usd`) and the prior spend come from the file.
     - The prices come from the `.factory/models.yaml` `models[]` entry whose `id` is `model_id`, with top-level `price_table_version`.
   - **Otherwise** (missing, unparseable or mismatched): `model` is `unknown`, the three prices and `predicted_cost_usd` are 0, the prior spend is 0, `budget_cap_usd` is `budget.issue_cap_usd` from `models.yaml`, and `notes` says `run start state missing` or `run_id mismatch`.
   - **Usage:** if `usage.json` parses, copy `requests` and the four token fields. Otherwise all five are 0 and `notes` says `usage unavailable`.
   - **Key spend** is *available* when `key-spend.json` parses, both values are non-negative numbers (not bool), `concurrent` is `false`, and `end_usd >= start_usd`. Then `delta = end_usd - start_usd`.
   - **Cost**, using `decimal.Decimal(str(x))` and rounding every USD output to 6 decimals:
     - Usage present and start state trusted: `computed = cost_from_usage(...)` from `scripts/factory-validate-run.py`, loaded with `importlib.util.spec_from_file_location`.
       - Key spend available: `cost_check = match` if `|delta - computed| <= max(0.10 × computed, 0.005)`, else `mismatch`.
       - On a `mismatch` with `delta > computed`: `cost_method = key_spend_delta` and `actual_cost_usd = delta`, with `notes` naming both numbers and "unrecorded calls (OpenCode title generation) or other key use". Otherwise `cost_method = usage_x_price_table` and `actual_cost_usd = computed`.
     - Usage absent or start state untrusted: if key spend is available, `key_spend_delta` with `actual = delta`; else `not_measured` with `actual = 0.0`. `cost_check` is `skipped_unavailable` either way.
     - `key_spend_delta_usd` = `delta` when available, else `null`.
     - `cost_check` = `skipped_concurrent` whenever `concurrent` is `true`, and `skipped_unavailable` whenever key spend is otherwise unavailable.
     - `issue_spend_to_date_usd` = prior spend + `actual_cost_usd`.
   - **Notes:** `notes` = the reasons above joined by `"; "`. When `usage.json` has a number, add `opencode_cost_usd <x>`. Use `ok` when there are none.
   - **Exit codes:** `0` record printed; `2` usage error (a missing required env var, a missing `OC_ARTIFACT_DIR` or `spec.md`, a spec without an integer `issue`, an `OC_OUTCOME` outside the enum, or a timestamp that isn't UTC `Z`), with empty stdout and one `factory-run-record: <reason>` line on stderr.
   - Never print environment values or file contents. Read no env var except those listed.
2. `scripts/factory-run-end.sh` (`set -euo pipefail`): the orchestration.
   - `OC_ENDED_AT` defaults to `date -u +%Y-%m-%dT%H:%M:%SZ`, and `OC_HEAD_SHA` defaults to `git rev-parse HEAD`.
   - Run `python3 scripts/factory-usage.py` on the sorted `"$OC_ARTIFACT_DIR"/usage/*.json` files (skip if there are none). On exit 0, write its stdout to `$OC_ARTIFACT_DIR/usage.json`; on any failure, remove `usage.json` and continue.
   - Run `factory-run-record.py` into a temp file and validate it with `python3 scripts/factory-validate-run.py`. Only then move it to `${FACTORY_RUNS_DIR:-factory/runs}/<run_id>.json` and print that path.
   - Exit with the record builder's code (2), or 1 if validation fails; on failure nothing is written to the runs dir.
3. `scripts/test-run-end.sh`: offline test harness (`set -euo pipefail`, `mktemp -d` with trap cleanup, `PASS`/`FAIL` per case, exactly one count per case, final `Results: <n> passed, <m> failed`, exit 1 on any failure).
   - Each case builds an artifact dir in the temp dir:
     - `spec.md` is a copy of `factory/specs/issue-133.md`.
     - `usage/` holds copies of `tests/factory-usage/opencode-export-session-*.json`.
     - `run-start.json` and `key-spend.json` are small inline JSON.
   - It sets fixed env (`OC_STARTED_AT=2026-11-07T17:00:00Z`, `OC_ENDED_AT=2026-11-07T17:04:10Z`, 40-hex SHAs, `GITHUB_RUN_ID=42400000001`, `GITHUB_RUN_ATTEMPT=1`) and `FACTORY_RUNS_DIR` in the temp dir.
   - It runs `scripts/factory-run-end.sh` and checks record fields with an inline `python3` snippet. No new fixture files.

## Out of scope

- The PR-body rewrite (#135). Posting records to the issue, gate checks and workflow wiring (#31).
- Capturing `opencode export` files in the agent job, and calling `deepinfra-cost.sh` around the agent step (#31 owner wiring; see Manual steps).
- Any edit to existing files: `scripts/*` (including `factory-usage.py`, `factory-validate-run.py`, `deepinfra-cost.sh`, `factory-cost.sh`), `.github/`, `.factory/`, `opencode.json`, `requirements-factory.txt`, `tests/factory-usage/`, `tests/run-records/`.
- Committing any record under `factory/runs/` (tests write only to the temp dir).
- `factory/specs/issue-134.md`: the harness writes it.

## Files

- Create: `scripts/factory-run-end.sh`, `scripts/factory-run-record.py`, `scripts/test-run-end.sh`.
- Read first: `.factory/schemas/run-record.schema.json`, `tests/run-records/pass-failed-no-pr.json`, `scripts/factory-validate-run.py`, `scripts/factory-usage.py`, `tests/factory-usage/README.md`, `factory/specs/issue-133.md`, `scripts/test-factory-usage.sh` (test style).

## Acceptance criteria

- [ ] **Happy path:** both exports, trusted start state (Qwen3-Coder, `prior_spend_usd` 0.1263), key spend 12.000000 → 12.001700. The record validates and is named `gha-42400000001-1.json`, with:
  - `tokens_in` 10000, `tokens_cached` 8000, `tokens_out` 240, `requests` 4.
  - Prices 0.30/0.10/1.00 and `price_table_version` `2026-11-02`.
  - `actual_cost_usd` 0.00164 (hand calculation: 2000×0.30 + 8000×0.10 + 240×1.00 = 1640 µ$).
  - `cost_method` `usage_x_price_table`, `key_spend_delta_usd` 0.0017, `cost_check` `match`, `issue_spend_to_date_usd` 0.12794, `duration_s` 250, `actions_minutes` 5, `issue` 133, `risk` `high`.
- [ ] **Cache-heavy:** session 1 alone gives `actual_cost_usd` 0.00058 (700×0.30 + 2800×0.10 + 90×1.00 = 580 µ$; uncached pricing would be 0.00114).
- [ ] **Title-generation gap:**
  - Key spend 12.000000 → 12.002400 (delta 0.0024, within $0.005): `match`, with `actual_cost_usd` still 0.00164.
  - 12.000000 → 12.020000: `mismatch`, `cost_method` `key_spend_delta`, `actual_cost_usd` 0.02, and `notes` containing `title generation`.
- [ ] **Key spend unavailable:**
  - `concurrent: true` gives `skipped_concurrent`.
  - No `key-spend.json`, or `end_usd < start_usd` (month rollover), gives `skipped_unavailable`.
  - In all three cases `key_spend_delta_usd` is `null` and the cost is 0.00164 via `usage_x_price_table`.
- [ ] **Missing usage** (no `usage/` dir, or an export with an unknown `tokens` key so `factory-usage.py` exits 3):
  - With key spend: `key_spend_delta` and `actual_cost_usd` 0.0017.
  - Without: `not_measured` and 0.0.
  - Tokens and requests are 0 and `cost_check` is `skipped_unavailable`. A cost is never guessed.
- [ ] **Bad start state:** no `run-start.json`, or one whose `run_id` is `gha-1-1`, still writes a valid record with `model` `unknown`, `cost_method` not `usage_x_price_table`, and `notes` naming the reason.
- [ ] **Failed run with no PR:** `OC_OUTCOME=failed` and no `OC_PR_NUMBER` give a valid record with `pr` `null` and `outcome` `failed`.
- [ ] **Usage errors exit 2 and write nothing to the runs dir:** `OC_ARTIFACT_DIR` unset; `spec.md` missing; `OC_OUTCOME=bogus`; `OC_STARTED_AT` without `Z`.
- [ ] **No secrets printed:** with `DEEPINFRA_API_KEY` and `FACTORY_TEST_SECRET` set to a sentinel, the sentinel appears in no stdout, stderr or record of any case. Both new shell scripts use `set -euo pipefail`.

## Verification

```bash
bash scripts/test-run-end.sh
git diff --name-only HEAD~1 | sort
```

Expected: every `test-run-end.sh` line `PASS` and a final `Results: <n> passed, 0 failed`. The changed-file list is only `factory/specs/issue-134.md`, `scripts/factory-run-end.sh`, `scripts/factory-run-record.py` and `scripts/test-run-end.sh`.

## Classification

- Complexity: standard. One record builder and a thin wrapper, with every input fixed and testable offline.
- Risk: high. It writes the numbers the per-issue cap and financials depend on (Michael approves).
- Model: routed by `models.yaml` rule 1 (high risk → Qwen3-Coder); `model_override_reason` is empty.

## Cost forecast

Standard prior on Qwen3-Coder (1.0M in, 80% cached, 50K out) predicts about $0.19, against this issue's $1.00 cap. #133 cost $0.36 in total over one build and three fixes. Expect about 200 lines of Python, 40 of shell and 220 of tests: one worker window, a bit more than #133.

## Manual steps for Michael

- None to merge this PR. Nothing calls `factory-run-end.sh` until the #31 wiring.
- Later (#31, owner wiring, not this PR):
  - In the agent job, export each session with `opencode session list --format json` plus `opencode export <id> --sanitize` into `$OC_ARTIFACT_DIR/usage/`. This edits the existing `scripts/opencode-agent-run.sh` or adds a workflow step.
  - Write `key-spend.json` from `scripts/deepinfra-cost.sh spend` before and after the agent step.
  - Call `factory-run-end.sh` in the publish job.

## Dependencies

#133 (PR #138, `scripts/factory-usage.py`) is on `main` at `1bc1110`. #135 and #31 build on this record.

## Worker prompt

Read `.factory/schemas/run-record.schema.json`, `tests/run-records/pass-failed-no-pr.json`, `scripts/factory-validate-run.py`, `scripts/factory-usage.py`, `tests/factory-usage/README.md`, `factory/specs/issue-133.md` and `scripts/test-factory-usage.sh` first. Then create exactly three files, `scripts/factory-run-record.py`, `scripts/factory-run-end.sh` and `scripts/test-run-end.sh`, following the Scope exactly: the env and file inputs listed, the trusted start-state check on `run_id`, prices from `.factory/models.yaml`, `cost_from_usage` loaded with `importlib`, the key-spend rules and thresholds, the degrade rules, sorted keys, validation before the record is moved into `FACTORY_RUNS_DIR`, exit 2 for usage errors with empty stdout. The tests build every case at runtime in a temp dir from copies of the real fixtures, with exactly one PASS or FAIL per case; don't add fixture files and never write under `factory/runs/`. Start writing after those reads; don't browse other directories. The write tool creates parent directories; never run mkdir, chmod, ls or git commit; use paths relative to the repo root. Never print a key, token or env value. Fill the PR template; tick only what you proved.

## Design / approach

Split responsibility: `factory-run-record.py` is a pure function from fixed inputs to one record, so every rule is unit-testable offline. `factory-run-end.sh` only sequences parse → build → validate → move. The model never computes cost.

The key spend comes in as a snapshot file, not a live call, for three reasons: the record step never holds the DeepInfra key, the tests need no network or mocks, and the existing `deepinfra-cost.sh` stays untouched (#31 calls it around the agent step).

On a large mismatch where the key spent more, the record counts the key delta. The cap is never under-counted because of unrecorded calls such as title generation. A concurrent run makes the delta unattributable, so it is recorded as `skipped_concurrent` and not used.

## Alternatives considered

- `factory-run-end.sh` calls `deepinfra-cost.sh spend` itself: rejected. It puts the key and network into the record step and needs a curl mock in tests; the snapshot file gives the same cross-check.
- Always `usage_x_price_table`, with the key delta only recorded: simpler, but the title-generation gap would under-count toward the cap. Michael's decision (D2 below).
- `opencode stats` as the token source: rejected (rounded; #133).
- Hand-written run-end fixtures: rejected. The cases are built from the real #137 exports and the real #133 spec.

## Risks, rollback and revert trigger

- Risk: the run-start or export shapes change. The `run_id` check and `factory-usage.py`'s strictness degrade to `key_spend_delta`/`not_measured`, which is visible in `notes`, never a guessed number.
- Risk: other uses of the same DeepInfra key inflate the delta. That shows as `mismatch`. `concurrent` covers overlapping factory runs; the key is Actions-only.
- Rollback: revert the merge commit. Nothing calls it until #31.
- Revert trigger: any record whose `actual_cost_usd` differs from a hand calculation from its own tokens and prices (for `usage_x_price_table`), or from `end - start` (for `key_spend_delta`).

## What changes in production on merge

Nothing at runtime. Two new scripts and their tests land; no workflow, existing script or config changes. Records start appearing once #31 wires the step.

## Success metric (baseline, target, how measured)

- Baseline: no run records on `main`. `prior_spend_usd` is $0 for every issue, so the cap ignores real build spend (#133 spent $0.36 unseen).
- Target: every fixture case yields a validator-OK record with the exact cost above, and every bad input degrades without a guessed cost.
- How measured: `bash scripts/test-run-end.sh` (`Results: <n> passed, 0 failed`).

## Test plan detail (broken case shown blocked)

Each case runs `scripts/factory-run-end.sh` against a temp artifact dir and a temp `FACTORY_RUNS_DIR`. It checks the exit code, whether `<run_id>.json` exists, and the listed fields:
- Cost: happy path (0.00164, `match`); cache-heavy (0.00058); title-generation delta within tolerance (`match`); large delta (`mismatch` → `key_spend_delta` 0.02).
- Key spend: concurrent, absent, rollover → `skipped_*`, delta `null`.
- Usage: absent or invalid → `key_spend_delta` 0.0017 or `not_measured` 0.0, zero tokens.
- Start state: absent or mismatched `run_id` → `model` `unknown`, never `usage_x_price_table`.
- Outcome: failed with no PR → `pr` `null`.
- Blocked (exit 2, nothing written): no artifact dir, no spec, bad outcome, non-`Z` timestamp.
- Secrets: the sentinel never appears in any output or record.

## Security and liability review (`liability-gates.md`)

- No network and no key: the key-spend numbers arrive in a file and the DeepInfra key is never read. Only the listed env vars are read, and none are printed.
- It writes one file under `FACTORY_RUNS_DIR`, and only after the validator passes. No PR, issue or workflow edits. No new dependency (PyYAML and jsonschema are already in `requirements-factory.txt`).
- Merge stays behind Michael's gate (high risk). Records feed the cap, so a wrong number matters; the cost rules are exact and tested against hand calculations.

## Milestones / split plan

One PR, about 460 lines across three files. This is milestone 2 of the #30 split (after #133, before #135 and the #31 wiring). If the worker runs out of time, the fallback is to split the degrade and usage-error tests into a follow-up fix run, not to loosen the rules.
