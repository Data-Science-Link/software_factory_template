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

- dbt is split out of `requirements-factory.txt` into `factory/dbt/requirements-dbt.txt`
  (issue #64) so run jobs that never invoke dbt don't install it. A dbt CI job (or any
  dbt user) should install `-r factory/dbt/requirements-dbt.txt`, not
  `requirements-factory.txt`.
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
