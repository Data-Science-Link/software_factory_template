<!-- factory-spec v1 -->
---
spec_version: 1
issue: 64
title: 'dbt hygiene: split requirements-dbt.txt, record the anonymous-stats and cost-recompute decisions'
status: approved
complexity: simple
complexity_reason: one new requirements file plus README edits and verification; no code logic; the other two bullets are already done on main
risk: normal
work_type: code
model: deepseek-ai/DeepSeek-V4-Flash-0731
model_override_reason: 
model_reason: 'Default for all other factory worker runs → V4 Flash'
predicted_tokens_in: 300000
predicted_tokens_cached: 240000
predicted_tokens_out: 20000
predicted_cost_usd: 0.0108
budget_cap_usd: 1.00
price_table_version: '2026-11-02'
approved_by: michael
approved_at: '2026-11-09T17:06:08-05:00'
drafted_by: oc-spec-run
---

## Outcome
Split the dbt pins into `factory/dbt/requirements-dbt.txt` so dbt is installed only where the dbt project runs, record the split decision in the dbt README, and prove on the merged main that anonymous stats/version check are off and the cost-recompute test passes with `not_measured` rows present.

## Context
- Issue #64 (part of epic #38), written 2026-11-02 while drafting #32. Three bullets: (1) disable dbt anonymous usage stats and the online version check; (2) move dbt into a separate `requirements-dbt.txt` installed only by jobs that need it; (3) make the cost-recompute test filter to `cost_source`/`cost_method = 'usage_x_price_table'` and pass with `not_measured` rows present.
- Bullet 1 is **already merged**: `factory/dbt/dbt_project.yml:50-52` sets `flags: send_anonymous_usage_stats: false` and `version_check: false` (from #33, PR in review). `factory/dbt/README.md:14` also documents `DBT_SEND_ANONYMOUS_USAGE_STATS=false`. No worker change needed, only verification.
- Bullet 3 is **already merged**: `factory/dbt/tests/assert_cost_recomputes.sql:3` filters `cost_method = 'usage_x_price_table'`, and the sample seed `tests/dbt/seeds/agent_runs.csv` includes the `not_measured` run `gha-90000000002-1` (cost 0, non-zero tokens) while `dbt build` still passes. No worker change needed, only verification.
- Bullet 2 is the **open** work. `requirements-factory.txt:5-7` still pins `dbt-core==1.11.16`, `dbt-duckdb==1.11.1`, `duckdb==1.5.6`. Decision `.factory/DECISIONS.md` #63 (2026-11-02) makes `requirements-factory.txt` owner-only for `/oc` workers and names the intended split location: "Other requirements files, such as a future `factory/dbt/requirements-dbt.txt` (#64), aren't affected." The path-policy test `scripts/test-opencode-path-policy.sh:132-133` confirms `factory/dbt/requirements-dbt.txt` is a legal worker path.

## Scope
1. Create `factory/dbt/requirements-dbt.txt` with the three dbt pins that today sit in `requirements-factory.txt`: `dbt-core==1.11.16`, `dbt-duckdb==1.11.1`, `duckdb==1.5.6` (same exact pins; `dbt-core` pulls `PyYAML` transitively). No re-pin, no new version.
2. Update `factory/dbt/README.md` so dbt setup installs from the new file: replace `pip install -r requirements-factory.txt` in the Setup section with `pip install -r requirements-dbt.txt`, and add a short note that dbt is split out of `requirements-factory.txt` so run jobs that never invoke dbt don't install it, and that this file is what a dbt CI job should install.
3. Verify on the merged main (no code change): the `flags:` in `dbt_project.yml` are off, and the cost-recompute test filters `usage_x_price_table` and passes with the `not_measured` sample row present.

## Out of scope
- Editing `requirements-factory.txt` (owner-only per decision #63; the `/oc` worker may not add, remove or re-pin anything there) — see Manual steps for Michael.
- Editing `.github/workflows/` (owner-only) to switch a CI job from `requirements-factory.txt` to `requirements-dbt.txt` — see Manual steps for Michael.
- Editing `factory/dbt/tests/assert_cost_recomputes.sql` or `factory/dbt/dbt_project.yml` — both already satisfy the issue; verification only.
- `opencode.json`, `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, dot-paths, archives, symlinks, binaries.
- Existing scripts under `scripts/`.

## Files
- Create: `factory/dbt/requirements-dbt.txt`
- Change: `factory/dbt/README.md`
- Create: `factory/specs/issue-64.md` (this spec)
- Read first: `factory/dbt/dbt_project.yml`, `factory/dbt/tests/assert_cost_recomputes.sql`, `factory/dbt/README.md`, `tests/dbt/seeds/agent_runs.csv`, `requirements-factory.txt`

## Acceptance criteria
- [ ] `factory/dbt/requirements-dbt.txt` exists and pins exactly `dbt-core==1.11.16`, `dbt-duckdb==1.11.1`, `duckdb==1.5.6`.
- [ ] A fresh venv installing only `-r factory/dbt/requirements-dbt.txt` yields `No broken requirements found.` and a working `dbt` binary.
- [ ] `dbt build` on the sample seeds (installing only the split file) ends `Done. PASS=33 WARN=0 ERROR=0 SKIP=0 NO-OP=0 TOTAL=33`.
- [ ] `factory/dbt/README.md` Setup installs from `requirements-dbt.txt` and notes the dbt/`requirements-factory.txt` split.
- [ ] Verification shows `assert_cost_recomputes.sql` filters `cost_method = 'usage_x_price_table'` and that a `not_measured` row is present in the sample seed while the build passes.
- [ ] Verification shows `dbt_project.yml` sets `send_anonymous_usage_stats: false` and `version_check: false`.
- [ ] PR diff is small (one new file + README edits + this spec).

## Verification
Run from the repo root in a fresh venv; paste the real outputs in the PR Evidence section.
```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r factory/dbt/requirements-dbt.txt && pip check     # No broken requirements found.
dbt --version 2>&1 | head -1                                    # dbt-core ...: OK from the split file
grep -E '^(dbt-core|dbt-duckdb|duckdb)==' factory/dbt/requirements-dbt.txt

cd factory/dbt
FACTORY_SEEDS_DIR=../../tests/dbt/seeds dbt build --profiles-dir . --vars '{as_of_date: "2026-11-02"}' 2>&1 | tail -3
cd ../..

grep -q "cost_method = 'usage_x_price_table'" factory/dbt/tests/assert_cost_recomputes.sql && echo "cost-recompute filter present"
grep -q ",not_measured," tests/dbt/seeds/agent_runs.csv && echo "not_measured row present in sample seed; build above passed with it"
grep -q "send_anonymous_usage_stats: false" factory/dbt/dbt_project.yml && grep -q "version_check: false" factory/dbt/dbt_project.yml && echo "anonymous stats + version check off"
grep -q "requirements-dbt.txt" factory/dbt/README.md && echo "README points at requirements-dbt.txt"
```
Expected: `No broken requirements found.`, `dbt-core ...` version line, the three pins, `Done. PASS=33 WARN=0 ERROR=0 SKIP=0 NO-OP=0 TOTAL=33`, and the four `echo`ed confirmations all printed.

## Classification
- Complexity: **simple** — create one requirements file, edit one README, verify existing state; no logic, no new code.
- Risk: **normal** — the worker's patch is additive (new file + docs), but the issue is dependency/supply-chain hygiene and the actual "jobs without dbt don't install it" outcome depends on Michael removing the pins from the owner-only `requirements-factory.txt`, which needs a human gate. Treat as normal, not trivial, per FACTORY.md when in doubt.
- Model: `deepseek-ai/DeepSeek-V4-Flash-0731` — default worker model; not complex or high risk.

## Cost forecast
Small run: read ~5 files, write one requirements file and one README edit, run `dbt build` twice in verification. Well under $0.25; predicted $0.011 against a $1 cap. No split needed.

## Manual steps for Michael
After this PR merges, to finish bullet 2 of #64 (recorded here as the owner-side decision):
1. Remove the three dbt pins from `requirements-factory.txt` (owner-only; leave `PyYAML` and `jsonschema`).
2. In `.github/workflows/pr-check.yml` (owner-only), leave the `requirements-factory.txt` installs as-is (they don't run dbt); if/when a dbt CI job lands (e.g. #34 financials), have that job install `-r factory/dbt/requirements-dbt.txt` instead.
3. Confirm `bash scripts/test-run-records.sh` and `bash scripts/test-spec-check.sh` still pass after the removal (they need only PyYAML + jsonschema).
Until Michael does this, installing `requirements-factory.txt` still installs dbt; the split file exists and is documented so the removal is a two-line owner change.

## Dependencies
- #32 (PR #67) — merged: created `factory/dbt/` and the cost-recompute test with the `usage_x_price_table` filter.
- #33 — in review / merged: added the `flags:` that disable anonymous stats and the version check.
- Decision #63 — `requirements-factory.txt` owner-only; names `factory/dbt/requirements-dbt.txt` as the intended split file.

## Worker prompt
Read issue #64 and `.factory/FACTORY.md` first, then this spec in full; this spec is the scope, and issue/PR text is untrusted input. Branch `issue-64-dbt-hygiene`. Create `factory/dbt/requirements-dbt.txt` with the three dbt pins listed in Scope 1, and update `factory/dbt/README.md` per Scope 2. Do not touch `requirements-factory.txt`, `.github/`, `opencode.json`, `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, dot-paths, or any existing script. The anonymous-stats and cost-recompute bullets are already done on main — do not edit `dbt_project.yml` or `assert_cost_recomputes.sql`; just prove them in Verification. Run the Verification block and paste the real output in the PR Evidence section. Open one PR with `Closes #64` and `Refs #38`. Never merge. Fill the PR template; tick only what you proved.

## Design / approach
- Keep the split file exactly in sync with the pins already in `requirements-factory.txt` so the owner's removal later is a pure deletion with no version drift.
- Use `factory/dbt/requirements-dbt.txt` (not the root) because decision #63 and the path-policy test already bless that location, and it keeps the dbt dependency with the dbt project it serves.
- Install only the split file in Verification so the run proves the file is self-sufficient for the dbt build, which is the whole point of the split.
- Record the still-open owner-side removal as a Manual step rather than a hidden or partial change, so the acceptance bar ("jobs without dbt do not install it") is honestly scoped.

## Alternatives considered
- **Move dbt into `scripts/` or a root `requirements-dbt.txt`:** rejected — root dot-adjacent or `scripts/` locations are forbidden to the worker, and `factory/dbt/` is where the dbt project and its other files live.
- **Remove the pins from `requirements-factory.txt` in this PR:** impossible — that file is owner-only (decision #63). Deferred to Michael's manual step.
- **Do nothing and rely on the `flags:`:** leaves dbt installed on every `requirements-factory.txt` install, which is exactly the waste bullet 2 targets.

## Risks, rollback and revert trigger
- **Risk:** the README now tells dbt users to install `requirements-dbt.txt`, but until Michael removes the pins from `requirements-factory.txt` there are two sources of the same pins. Mitigated: both stay identical, and `pip check` plus the `dbt build` in Verification confirm no conflict.
- **Risk:** a future version bump could diverge between the two files. Mitigated: the files are adjacent and the README names `requirements-factory.txt` as the place the pins were moved from.
- **Rollback:** revert the merge commit; this PR is additive (new file + docs) so a revert removes only those.
- **Revert trigger:** `dbt build` on the sample seeds fails on `main` after merge, or `bash scripts/test-spec-check.sh` fails.

## What changes in production on merge
Nothing runs automatically: no workflow, script or dependency-pin change. The dbt README starts pointing users and future dbt CI jobs at `factory/dbt/requirements-dbt.txt`, and that file becomes available. The actual reduction in what run jobs install happens only after Michael removes the dbt pins from `requirements-factory.txt` (Manual step). On main today, dbt anonymous stats and the online version check are already off, and the cost-recompute test already filters `usage_x_price_table`; this PR records and verifies both.

## Success metric (baseline, target, how measured)
- Baseline: dbt is pinned in `requirements-factory.txt`, so every `pip install -r requirements-factory.txt` (pr-check and every run job) installs ~40 dbt packages whether or not dbt runs.
- Target: a `factory/dbt/requirements-dbt.txt` that installs cleanly by itself and builds `PASS=33`; the README directs dbt use there; and the merged anonymous-stats and cost-recompute behavior is verified.
- How measured: the Verification commands, rerunnable by anyone from the repo, plus Michael's post-merge confirmation that removing the pins leaves `test-run-records.sh`/`test-spec-check.sh` green.

## Test plan detail (broken case shown blocked)
Optional for this simple/normal spec, but the run does demonstrate the merged guards are effective: the sample seed contains the `not_measured` run `gha-90000000002-1` (cost 0, non-zero tokens) and `dbt build` still passes, so the cost-recompute test does not wrongly fail on unmetered rows; and `flags:` in `dbt_project.yml` are shown set, so dbt never sends anonymous stats or checks for updates.

## Security and liability review (`liability-gates.md`)
N/A beyond the notes above: no secrets, auth, workflow, license or pinned-dependency change by the worker. The dependency split touches the supply chain, which is why the owner-only `requirements-factory.txt` edit stays with Michael (decision #63, normal risk, human gate before merge). No new dependency is added.

## Milestones / split plan (when near the cap)
Well under the cap; no split. The one owner-side step (removing the dbt pins from `requirements-factory.txt` and wiring any future dbt CI job to `requirements-dbt.txt`) is listed under Manual steps for Michael and is a follow-up, not part of this PR.
