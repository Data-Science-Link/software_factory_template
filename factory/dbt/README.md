# Factory dbt project (dbt-duckdb)

Slice 1 of issue #32: an offline `dbt build` over a DuckDB file, seeded from validated
run records (`factory/runs/*.json`). One seed (`agent_runs`), one staging view
(`stg_agent_runs`), and its tests. Marts and the other seeds come in follow-ups
(slice 2 of #32, then #33 and #34).

## Setup (venv)

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-factory.txt
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

- `profiles.yml` is in-repo with a relative DuckDB path under `target/` (gitignored):
  no warehouse, no credentials, works offline.
- `logs/` and `*.duckdb` are gitignored via `factory/dbt/.gitignore`.
- Marts (#33), the financials page (#34), and the remaining seeds/staging models come
  in follow-ups.
