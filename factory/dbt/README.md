# Factory dbt project (dbt-duckdb)

Slice 1 of issue #32: an offline `dbt build` over a DuckDB file, seeded from validated
run records (`factory/runs/*.json`). One seed (`agent_runs`), one staging view
(`stg_agent_runs`), and its tests. Marts and the other seeds come in follow-ups
(slice 2 of #32, then #34).

## Setup (venv)

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r factory/dbt/requirements-dbt.txt
export DBT_SEND_ANONYMOUS_USAGE_STATS=false   # disable dbt anonymous usage stats
```

## Regenerate the seeds

Sample seeds from committed fixtures (`tests/run-records/pass-*.json`):

```bash
python factory/dbt/runs_to_seeds.py --runs 'tests/run-records/pass-*.json' --out tests/dbt/seeds
```

Real seeds from today's run records (defaults; `factory/runs/` is empty on `main`, so
this writes a header-only CSV):

```bash
python factory/dbt/runs_to_seeds.py
```

## Build

`seed-paths` reads `FACTORY_SEEDS_DIR` (default `seeds`, i.e. `factory/dbt/seeds`).
Point it at the sample seeds or run on the real seeds:

```bash
cd factory/dbt
FACTORY_SEEDS_DIR=../../tests/dbt/seeds dbt build --profiles-dir .   # sample seeds
dbt build --profiles-dir .                                           # real seeds
```

## Notes

- dbt is pinned only in `factory/dbt/requirements-dbt.txt` (issue #64); `requirements-factory.txt`
  no longer installs it, so run jobs that never invoke dbt don't. A dbt CI job (or any dbt
  user) installs `-r factory/dbt/requirements-dbt.txt`. Run dbt on Python 3.13 or older:
  dbt 1.11 crashes on 3.14 (#148).
- `profiles.yml` is in-repo with a relative DuckDB path under `target/` (gitignored):
  no warehouse, no credentials, works offline.
- `logs/` and `*.duckdb` are gitignored via `factory/dbt/.gitignore`.

## Marts (#33)

Six mart tables under `models/marts/`: `fct_agent_runs` (one row per run with cost
variance, cache hit rate and first-time gate pass), `agg_spend_daily`, `agg_spend_by_issue`,
`agg_spend_by_model`, `fct_forecast_vs_actual` (per issue and per complexity) and
`rpt_run_rate` (month-to-date spend, trailing 7/30-day spend per day, projected month-end,
budget and Actions minutes usage). They read `stg_agent_runs` through `fct_agent_runs`.

The budget numbers (per-issue cap, monthly DeepInfra budget, fixed costs, Actions minutes
quota, warn threshold) are `vars` in `dbt_project.yml`, not seeds, so they're easy to
override and to swap for `stg_budget` / `stg_fixed_costs` when those land. `rpt_run_rate`
defaults to today (UTC) and can be pinned for repeatable builds:

```bash
FACTORY_SEEDS_DIR=../../tests/dbt/seeds dbt build --profiles-dir . \
  --vars '{as_of_date: "2026-11-02"}'
```

The financials page (#34) and the remaining seeds/staging models come in follow-ups.

## Budget file (#170)

`factory/budget.yml` is the single committed source of budget numbers. Michael's starting
values (2026-11-11): $10/month, $2.50/week, per-issue target $0.15, per-issue cap $1.00,
fixed costs $20/month, 2000 Actions minutes/month and an 80% warn threshold.

`scripts/factory-budget-vars.py` reads and validates that file (all keys present, positive,
weekly ≤ monthly) and prints a JSON object of dbt vars for `dbt build --vars`, mapping
`monthly_usd` onto the existing `deepinfra_monthly_budget_usd` var and emitting the new
`weekly_budget_usd` and `issue_target_usd`:

```bash
cd factory/dbt
FACTORY_SEEDS_DIR=../../tests/dbt/seeds dbt build --profiles-dir . \
  --vars "$(python ../../scripts/factory-budget-vars.py)"
```

## Weekly / monthly spend and issue compliance marts (#170)

Three marts were added for the site:

- `agg_spend_weekly` — spend, runs, issues, weekly budget, percent used and an over-budget
  flag by ISO week (UTC) across the reporting window; weeks with no runs show 0 spend.
- `agg_spend_monthly` — the same fields by calendar month (UTC).
- `rpt_issue_target_compliance` — per issue: total spend, under-target and under-cap flags
  and run count, plus one summary row.

`factory/dbt/tests/assert_weekly_budget_math.sql` guards that each weekly row's
`budget_used_pct` matches spend ÷ budget. Build with `as_of_date` pinned for repeatable
output.

## Site-data export (#170)

`scripts/factory-site-data.py` exports the marts the site needs to
`site-data/marts/<model>.json`, deterministically sorted: `rpt_run_rate`, `agg_spend_weekly`,
`agg_spend_monthly`, `agg_spend_by_issue`, `agg_spend_by_model`, `fct_forecast_vs_actual`
and `rpt_issue_target_compliance`, plus a whitelisted column subset of `fct_agent_runs`.
`site-data/` is gitignored; the site generator consumes the JSON without needing dbt or
DuckDB. `scripts/test-factory-site-data.sh` covers budget-vars validation and export
determinism using the committed fixtures under `tests/site-data/sample-marts/`.
