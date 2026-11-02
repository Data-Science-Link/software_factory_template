<!-- factory-spec v1 -->
---
spec_version: 1
issue: 32
title: 'dbt-duckdb skeleton, slice 1: agent_runs seed from run records, stg_agent_runs,
  tests'
status: approved
complexity: standard
complexity_reason: new dbt-duckdb project plus a seed script across ~9 small files
  (~260 changed lines); no existing code changes beyond requirements-factory.txt
risk: normal
work_type: code
model: deepseek-ai/DeepSeek-V4-Flash-0731
model_reason: "Default for all other factory worker runs → V4 Flash"
predicted_tokens_in: 1000000
predicted_tokens_cached: 800000
predicted_tokens_out: 50000
predicted_cost_usd: 0.033
budget_cap_usd: 1.0
price_table_version: '2026-11-02'
approved_by: michael
approved_at: "2026-11-02T11:03:00-06:00"
drafted_by: grok-bot
---

## Outcome
`dbt build` runs green, offline, on a local DuckDB file, over an `agent_runs` seed that `factory/dbt/runs_to_seeds.py` builds deterministically from validated run records, with one staging model (`stg_agent_runs`) and its tests, including a cost-recompute test that fails on a wrong record.

## Context
- Issue #32 (part of epic #38, order 11 of 16). Vision `.factory/VISION.md` §11 (cost pipeline) and §18 decisions 1 and 5.
- Michael: "Costs must be tracked through a dbt pipeline to build a solid dataset… DBT pipeline should have seed CSVs or JSONs of each agent's run that it adds to master datasets to clean."
- Run record schema and validator from #25 / PR #50: `.factory/schemas/run-record.schema.json`, `scripts/factory-validate-run.py`, fixtures in `tests/run-records/`. `factory/runs/` holds only its README on `main` (its README says: don't commit example records there), so sample data comes from `tests/run-records/pass-*.json` and is written to a test-only seed folder.
- This is **slice 1** of #32, cut to fit one cheap run (~300 changed lines). The rest of #32 is listed in Out of scope and in the split plan.

## Scope
1. `requirements-factory.txt`: add exact pins `dbt-core==1.11.16`, `dbt-duckdb==1.11.1`, `duckdb==1.5.6` (keep the existing `PyYAML` and `jsonschema` pins). This set resolves cleanly with `jsonschema==4.23.0` on Python 3.13 (`pip check`: no broken requirements).
2. `factory/dbt/runs_to_seeds.py` (stdlib + the existing validator only, no network):
   - Args: `--runs GLOB` (default `factory/runs/*.json`), `--out DIR` (default `factory/dbt/seeds`).
   - Load each file and validate it by importing `load_record` and `validate_record` from `scripts/factory-validate-run.py` (via `importlib`, the file has a dash). If **any** record is invalid, print `INVALID <path>:` plus each error on stderr, write nothing, exit 1.
   - Write `<out>/agent_runs.csv`: header + one row per run, sorted by (`started_at`, `run_id`), `csv.writer(..., lineterminator="\n")`, UTF-8. `None` → empty cell; booleans → `true`/`false`; other values as Python `str()` of the JSON value. Columns, in this exact order:
     `run_id, repo, issue, pr, trigger, triggered_by, harness, provider, model, escalated_from, complexity, risk, work_type, price_table_version, price_in_per_mtok, price_cached_per_mtok, price_out_per_mtok, requests, tokens_in, tokens_cached, tokens_out, tokens_reasoning, predicted_cost_usd, actual_cost_usd, cost_method, key_spend_delta_usd, cost_check, budget_cap_usd, issue_spend_to_date_usd, started_at, ended_at, duration_s, actions_minutes, runner, outcome, gate_passed`
   - Print `wrote <out>/agent_runs.csv (<n> runs)` and exit 0. Zero matching files is valid (header-only CSV).
3. `factory/dbt/dbt_project.yml`: `name: factory`, `profile: factory`, `config-version: 2`, `seed-paths: ["{{ env_var('FACTORY_SEEDS_DIR', 'seeds') }}"]`, `model-paths: ["models"]`, `test-paths: ["tests"]`, and `seeds: factory: agent_runs: +column_types:` for **every** column (varchar for text and the two timestamps, integer for `issue`/`pr`, bigint for counts/tokens/durations, double for prices and USD, boolean for `gate_passed`) so a header-only seed still builds.
4. `factory/dbt/profiles.yml`, exactly:
   ```yaml
   factory:
     target: local
     outputs:
       local:
         type: duckdb
         path: target/factory.duckdb
         threads: 1
   ```
5. `factory/dbt/models/staging/stg_agent_runs.sql`: from `ref('agent_runs')`, dedupe on `run_id` (`row_number() over (partition by run_id order by ended_at desc)`, keep 1), `lower(trim(model)) as model_id`, `cast(cast(started_at as timestamptz) at time zone 'UTC' as timestamp) as started_at_utc` (same for `ended_at_utc`), all other seed columns passed through.
6. `factory/dbt/models/staging/schema.yml` (dbt 1.11 syntax: `data_tests:`, `accepted_values` with `arguments: {values: [...]}`) — exactly these 8 generic tests on `stg_agent_runs`: `unique` + `not_null` on `run_id`; `accepted_values` on `complexity` (simple, standard, complex), `risk` (trivial, normal, high), `work_type` (code, docs, spec, review, data), `cost_method` (provider_reported, usage_x_price_table, key_spend_delta, not_measured), `outcome` (pr_opened, pr_updated, no_changes, failed, cap_exceeded, gate_failed, cancelled); `not_null` on `actual_cost_usd`.
7. Two singular tests in `factory/dbt/tests/`:
   - `assert_actual_cost_non_negative.sql`: rows where `actual_cost_usd < 0`.
   - `assert_cost_recomputes.sql`: rows where `cost_method = 'usage_x_price_table'` and `abs(actual_cost_usd - ((tokens_in - tokens_cached) * price_in_per_mtok + tokens_cached * price_cached_per_mtok + tokens_out * price_out_per_mtok) / 1e6) > 0.0001`. (Only that method: `not_measured` records legitimately have `actual_cost_usd = 0` with non-zero tokens, e.g. `pass-failed-no-pr.json`.)
8. Seeds committed: `tests/dbt/seeds/agent_runs.csv` (built from `tests/run-records/pass-*.json`, 4 runs) and `factory/dbt/seeds/agent_runs.csv` (built from today's empty `factory/runs/`, header only).
9. `factory/dbt/README.md` (short): what this is, the venv install, the env var to disable dbt anonymous usage stats, the regenerate-seeds and `dbt build` commands for sample and real data, the `FACTORY_SEEDS_DIR` switch, and that marts/other seeds come in follow-ups.
10. Create `factory/dbt/.gitignore` (do NOT edit the root `.gitignore`; the publish scan rejects root dotfiles) containing `logs/` and `*.duckdb` (`target/` is already ignored; confirm with `git check-ignore`).

## Out of scope
- Seeds `agent_run_gates.csv`, `model_prices.csv` (from `.factory/models.yaml`), hand-kept `fixed_costs.csv` and `budget.csv`, and staging models `stg_run_gates`, `stg_model_prices`, `stg_fixed_costs`, `stg_budget` → follow-up slice 2 of #32.
- Flattening optional `steps[]` (#41) into the seed → follow-up.
- Marts (#33), the financials page (#34), `factory-collect-runs.sh` issue-comment copies (#34).
- Anything under `.github/workflows/` (the factory token can't push workflow files). CI wiring of `dbt build` is a follow-up for Michael to paste by hand.
- dbt packages (`packages.yml`, `dbt_utils`): no `dbt deps`, no network at build time.
- Any change to `factory/runs/` (no example records there), the run-record schema, the validator, `models.yaml`, or existing scripts/tests.
- Any credentials, warehouse, MotherDuck, or absolute paths.

## Files
- **Create:** `factory/dbt/runs_to_seeds.py`, `factory/dbt/dbt_project.yml`, `factory/dbt/profiles.yml`, `factory/dbt/README.md`, `factory/dbt/models/staging/stg_agent_runs.sql`, `factory/dbt/models/staging/schema.yml`, `factory/dbt/tests/assert_actual_cost_non_negative.sql`, `factory/dbt/tests/assert_cost_recomputes.sql`, `factory/dbt/seeds/agent_runs.csv` (generated), `tests/dbt/seeds/agent_runs.csv` (generated), `factory/specs/issue-32.md` (this spec).
- **Change:** `requirements-factory.txt` only. **Create** also `factory/dbt/.gitignore`. Never edit the root `.gitignore` or any other root dotfile.
- **Read first:** `.factory/VISION.md` §8 and §11, `factory/runs/README.md`, `scripts/factory-validate-run.py`, `tests/run-records/pass-*.json`.

## Acceptance criteria
- [ ] `pip install -r requirements-factory.txt` in a fresh venv succeeds and `pip check` prints `No broken requirements found.`
- [ ] Seed script on the fixtures prints `wrote tests/dbt/seeds/agent_runs.csv (4 runs)`; a second run leaves the file byte-identical (same sha256, `git diff --exit-code` clean).
- [ ] Seed script on `tests/run-records/fail-cost-mismatch.json` prints `INVALID …` and exits 1 without writing.
- [ ] Seed script with defaults prints `wrote factory/dbt/seeds/agent_runs.csv (0 runs)` and the file is header only (1 line).
- [ ] `dbt build` on the sample seeds ends with `Done. PASS=12 WARN=0 ERROR=0 SKIP=0 NO-OP=0 TOTAL=12` (1 seed, 1 view, 10 tests).
- [ ] `dbt build` on the real (header-only) seed also ends with `PASS=12 … ERROR=0`.
- [ ] Broken case: with one row's `actual_cost_usd` changed to `0.5`, `dbt build` shows `FAIL 1 assert_cost_recomputes`, ends `PASS=11 WARN=0 ERROR=1`, exit code 1.
- [ ] `git check-ignore` lists both `factory/dbt/target/factory.duckdb` and `factory/dbt/logs/dbt.log`; no `.duckdb` file is committed.
- [ ] No credentials, host or warehouse settings under `factory/dbt/`; no file under `.github/workflows/` changed.
- [ ] `bash scripts/test-run-records.sh` and `bash scripts/test-spec-check.sh` still pass.
- [ ] PR diff is under ~300 changed lines.

## Verification
Run from the repo root in a fresh venv; paste the outputs in the PR Evidence section. Everything after the `pip install` runs offline.
```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-factory.txt && pip check        # No broken requirements found.
export DBT_SEND_ANONYMOUS_USAGE_STATS=false

python factory/dbt/runs_to_seeds.py --runs 'tests/run-records/pass-*.json' --out tests/dbt/seeds
#   wrote tests/dbt/seeds/agent_runs.csv (4 runs)
sha256sum tests/dbt/seeds/agent_runs.csv
python factory/dbt/runs_to_seeds.py --runs 'tests/run-records/pass-*.json' --out tests/dbt/seeds
sha256sum tests/dbt/seeds/agent_runs.csv                     # same hash as above
git diff --exit-code -- tests/dbt/seeds                      # exit 0 once committed

python factory/dbt/runs_to_seeds.py --runs tests/run-records/fail-cost-mismatch.json --out /tmp/never; echo "exit=$?"
#   INVALID tests/run-records/fail-cost-mismatch.json: ... (expected 0.012246, got 0.99)   exit=1
python factory/dbt/runs_to_seeds.py && wc -l factory/dbt/seeds/agent_runs.csv
#   wrote factory/dbt/seeds/agent_runs.csv (0 runs)   1 factory/dbt/seeds/agent_runs.csv

cd factory/dbt
FACTORY_SEEDS_DIR=../../tests/dbt/seeds dbt build --profiles-dir .
#   Done. PASS=12 WARN=0 ERROR=0 SKIP=0 NO-OP=0 TOTAL=12
dbt build --profiles-dir .
#   Done. PASS=12 WARN=0 ERROR=0 SKIP=0 NO-OP=0 TOTAL=12

mkdir -p /tmp/broken
sed '2s/,0.012246,usage_x_price_table/,0.5,usage_x_price_table/' ../../tests/dbt/seeds/agent_runs.csv > /tmp/broken/agent_runs.csv
FACTORY_SEEDS_DIR=/tmp/broken dbt build --profiles-dir .; echo "exit=$?"
#   ... FAIL 1 assert_cost_recomputes ...   Done. PASS=11 WARN=0 ERROR=1 ...   exit=1
cd ../..

git check-ignore factory/dbt/target/factory.duckdb factory/dbt/logs/dbt.log   # prints both paths
git ls-files | grep -c '\.duckdb$'                                              # 0
grep -rniE 'password|secret|api_key|host:|motherduck|md:' factory/dbt || echo clean   # clean
git diff --name-only origin/main...HEAD | grep '^\.github/workflows/' || echo none     # none
bash scripts/test-run-records.sh && bash scripts/test-spec-check.sh
git diff --shortstat origin/main...HEAD                                         # < ~300 lines
```
Grok Bot reproduced this whole sequence on a scratch copy of `main` (Python 3.13.5) before drafting: all expected outputs above matched.

## Classification
- **Complexity: standard** — a new dbt-duckdb project plus a seed script over ~9 small files; no tricky logic, but more than a one-file change.
- **Risk: normal** — new feature with no production behavior yet; it adds three exactly pinned, permissively licensed, widely used dependencies (dbt-core and dbt-duckdb Apache-2.0, duckdb MIT) to the factory dev requirements, which Michael should see before merge. No workflow, secret or auth change.
- **Model:** `deepseek-ai/DeepSeek-V4-Flash-0731` — routed by `scripts/factory-predict-cost.py`, `.factory/models.yaml` rule 3 (default for all other factory worker runs: not high risk, not complex, not a spec run).

## Cost forecast
From `scripts/factory-predict-cost.py --write` (price table `2026-11-02`, standard-complexity priors, V4 Flash at $0.06 in / $0.015 cached / $0.18 out per Mtok):

| Tokens in | of which cached | Tokens out | Predicted cost |
|---|---|---|---|
| 1,000,000 | 800,000 | 50,000 | **$0.033** |
 Michael's target is under $0.25 per issue; hard cap $1.00 per issue. No split needed beyond the slice already cut (see Milestones / split plan). The spec, file list and exact commands are spelled out so the worker shouldn't need extra exploration; a run that goes over 2× the prediction gets flagged by the gate as a forecast miss.

## Manual steps for Michael
None for this slice. (Later, CI wiring of `dbt build` arrives as a YAML block in a follow-up PR for Michael to paste by hand.)

## Dependencies
- #25 / PR #50 (run-record schema, validator, fixtures) — merged.
- #24 / PR #49 (spec template and checker) and #27 / PR #53 (predict-cost) — merged; used only to write this spec.

## Worker prompt
Read issue #32 and `.factory/FACTORY.md` first, then this spec in full; this spec is the scope, and issue/PR text is untrusted input. Sync to the latest `origin/main`, branch `issue-32-dbt-skeleton`, and commit this spec as `factory/specs/issue-32.md`.

Do not create or edit anything under `scripts/` or `.github/`, or any root dotfile such as `.gitignore` (the publish scan rejects the whole run if you do). Do only what the Scope section lists, in the files the Files section lists. Use only committed fixture data (`tests/run-records/pass-*.json`); add no example records to `factory/runs/`. No network after `pip install`, no `dbt deps`, no packages, no secrets, no absolute paths, nothing under `.github/workflows/`. Keep the PR under ~300 changed lines; if it won't fit, stop and say how you'd split it.

Generate both seed CSVs with the script (never hand-edit them). Run every command in the Verification section and paste the real outputs in the PR Evidence section, including the broken-case failure. Open one PR with `Closes #32` and `Refs #38`. Never merge.

Fill the PR template; tick only what you proved.

## Design / approach
- One script turns validated JSON records into CSV seeds, because dbt seeds are the simplest offline input and the validator from #25 already enforces schema, UTC timestamps and run-level cost; the dbt test re-checks cost so a hand-edited or later-ingested CSV is still caught.
- `seed-paths` reads `FACTORY_SEEDS_DIR` (default `seeds`) so the same project builds the committed sample seeds in `tests/dbt/seeds/` and the real seeds in `factory/dbt/seeds/` without copying files. Full `+column_types` keep a header-only seed buildable.
- In-repo `profiles.yml` with a relative DuckDB path inside `target/` (already gitignored): no warehouse, no credentials, works on any laptop or runner.
- Staging is a view; dedupe by `run_id` keeping the latest `ended_at`, so an issue-comment copy and a PR copy of the same run (decision 1) don't double count later.

## Alternatives considered
- Read the JSON directly in DuckDB (`read_json_auto`) instead of seeds: fewer files, but the issue and vision ask for committed seeds, and it would skip the Python validator. Rejected for this slice.
- Copy fixtures into `factory/runs/`: rejected; `factory/runs/README.md` forbids example records on `main`, and they'd pollute real financials.
- `dbt_utils` for range tests: needs `dbt deps` (network). Replaced by two singular tests.

## Risks, rollback and revert trigger
- **Risk:** dependency weight/conflicts in `requirements-factory.txt` (dbt pulls ~40 transitive packages). Mitigated by exact pins and `pip check` in Evidence. Follow-up option: split into `requirements-dbt.txt` if the factory run job shouldn't install dbt.
- **Risk:** the env-var seed path is unusual; documented in the README and covered by both `dbt build` runs.
- **Rollback:** revert the merge commit; nothing else reads these files yet.
- **Revert trigger:** `bash scripts/test-run-records.sh` or `bash scripts/test-spec-check.sh` fails on `main` after merge, or a fresh-venv `pip install -r requirements-factory.txt` fails.

## What changes in production on merge
Nothing runs automatically: no workflow change. `requirements-factory.txt` gains three pins, so anyone (or a future job) installing factory deps also gets dbt. The `factory/dbt/` project and seed script become available for #33 (marts) and #34 (financials).

## Success metric (baseline, target, how measured)
- **Baseline:** no dataset; run cost exists only per JSON record.
- **Target:** `dbt build` green on the 4 sample records (PASS=12, ERROR=0), and the cost-recompute test catches a wrong cost (ERROR=1, exit 1). Seeds byte-identical across runs.
- **How measured:** the Verification commands, rerunnable by anyone from the repo.

## Test plan detail (broken case shown blocked)
Two broken cases: (1) the seed script rejects `tests/run-records/fail-cost-mismatch.json` (exit 1, nothing written); (2) a CSV with one `actual_cost_usd` changed to `0.5` makes `assert_cost_recomputes` fail (`FAIL 1`, exit 1). Healthy cases: sample seeds and header-only real seed both give PASS=12.

## Security and liability review (`liability-gates.md`)
N/A beyond the notes above — no secrets, auth, workflows or licenses changed. New dependencies are exactly pinned and permissively licensed (Apache-2.0 / MIT); Michael approves them with the PR (normal risk).

## Milestones / split plan (when near the cap)
- **Slice 1 (this spec):** scaffold, `agent_runs` seed, `stg_agent_runs`, tests.
- **Slice 2 (follow-up issue):** `agent_run_gates.csv` and `model_prices.csv` from the script; hand-kept `fixed_costs.csv` (Cursor plan ~$20/month) and `budget.csv` (`deepinfra_budget_usd = 10`, decision 5); `stg_run_gates`, `stg_model_prices`, `stg_fixed_costs`, `stg_budget` with tests; normalize model IDs against `stg_model_prices`.
- **Slice 3 (follow-up):** `steps[]` flattening (#41) and a `scripts/test-dbt.sh` wrapper; CI wiring of `dbt build` as a hand-pasted workflow block.
