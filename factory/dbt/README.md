# Factory dbt project (dbt-duckdb)

Offline `dbt build` over a DuckDB file under `target/`, seeded from validated run records
(`factory/runs/*.json` or fixtures). Budget numbers come from `factory/budget.yml` via
`scripts/factory-budget-vars.py`.

## Setup (venv)

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r factory/dbt/requirements-dbt.txt
export DBT_SEND_ANONYMOUS_USAGE_STATS=false
```

Use Python 3.13 or older: dbt 1.11 is not compatible with Python 3.14 (#148).

## Regenerate seeds

Committed fixtures (`tests/run-records/pass-*.json` → `tests/dbt/seeds`):

```bash
python factory/dbt/runs_to_seeds.py --runs 'tests/run-records/pass-*.json' --out tests/dbt/seeds
```

Example adopter runs (synthetic, under `examples/sample-runs/`):

```bash
python factory/dbt/runs_to_seeds.py --runs 'examples/sample-runs/*.json' --out /tmp/sample-dbt-seeds
```

Live run records (default `factory/runs/`; may be empty on `main`):

```bash
python factory/dbt/runs_to_seeds.py
```

`seed-paths` reads `FACTORY_SEEDS_DIR` (default `seeds` inside this directory).

## Build

```bash
cd factory/dbt
FACTORY_SEEDS_DIR=../../tests/dbt/seeds dbt build --profiles-dir . \
  --vars "$(python ../../scripts/factory-budget-vars.py | python -c 'import json,sys; v=json.load(sys.stdin); v["as_of_date"]="2026-11-20"; print(json.dumps(v))')"
```

Pin `as_of_date` for reproducible CFO windows and run-rate output.

## Model inventory

| Layer | Model | Role |
|-------|--------|------|
| seed | `agent_runs` | Validated runs CSV |
| staging | `stg_agent_runs` | Deduped runs, normalized `model_id`, UTC timestamps |
| mart | `fct_agent_runs` | One row per run with variance, cache rate, gate flags |
| mart | `agg_spend_daily` | Spend and tokens by UTC day |
| mart | `agg_spend_by_issue` | Spend and cap headroom per issue |
| mart | `agg_spend_by_model` | Spend and gate rate per model |
| mart | `agg_spend_weekly` | ISO week spend vs weekly budget |
| mart | `agg_spend_monthly` | Calendar month spend vs monthly budget |
| mart | `fct_forecast_vs_actual` | Forecast error by issue and complexity |
| mart | `rpt_run_rate` | Month-to-date run rate and projections |
| mart | `rpt_issue_target_compliance` | Per-issue target/cap compliance + summary row |
| mart | `mart_model_efficiency` | Gate and cost efficiency by model × harness × provider |
| mart | `mart_monthly_cfo` | Three-month CFO rollup (spend, budget %, pass rate) |
| mart | `mart_spend_by_work_type` | Spend share by normalized work type |

Schema metadata: `models/staging/schema.yml`, `models/marts/schema.yml`, `models/marts/schema_cfo.yml`.

## Singular tests (`tests/`)

| Test | Checks |
|------|--------|
| `assert_actual_cost_non_negative` | No negative `actual_cost_usd` in facts |
| `assert_no_negative_run_costs` | Staging/fact costs stay non-negative |
| `assert_cost_recomputes` | Price table × tokens matches measured cost |
| `assert_token_counts_non_negative` | Token counts ≥ 0; cached ≤ input when present |
| `assert_issue_spend_within_cap` | Issue spend within configured cap |
| `assert_weekly_budget_math` / `assert_monthly_budget_math` | `budget_used_pct` matches spend ÷ budget |
| `assert_deepinfra_budget_under_warn` | MTD spend under warn threshold when applicable |
| `assert_actions_minutes_under_warn` | Actions minutes under warn threshold |
| `assert_forecast_error_within_100pct` | Forecast error bounds |
| `assert_forecast_grain_unique` | One row per `(grain, grain_key)` in forecast mart |
| `assert_model_efficiency_bounds` | Efficiency rates and costs in valid ranges; `run_count > 0` |
| `assert_model_efficiency_counts_match_runs` | Efficiency mart run totals match `fct_agent_runs` |
| `assert_cfo_monthly_matches_runs` | `mart_monthly_cfo` spend reconciles to facts (±0.0001 USD) |
| `assert_work_type_spend_matches_runs` | Work-type mart totals match facts |

Generic `unique` / `not_null` / `accepted_values` tests are declared in the schema YAML files.

## Verification (repo root)

```bash
bash scripts/test-dbt-budget-math.sh
```

When dbt is installed, that script runs `dbt build` on the budget-math week fixture, `tests/dbt/seeds`,
`examples/sample-runs` (via a temp seed dir), and `factory/runs` (temp dir; may be header-only).

## Site export

`scripts/factory-site-data.py` exports whitelisted mart columns to `site-data/marts/*.json` after a build.
`profiles.yml` uses a relative DuckDB path under `target/` (gitignored); no warehouse credentials.

## Budget file (#170)

`factory/budget.yml` is the committed budget source. Starting template values (2026-11-11):
$10/month variable, $2.50/week, $0.15 issue target, $1.00 issue cap, $20/month fixed costs,
2000 Actions minutes/month, 80% warn threshold.

```bash
cd factory/dbt
FACTORY_SEEDS_DIR=../../tests/dbt/seeds dbt build --profiles-dir . \
  --vars "$(python ../../scripts/factory-budget-vars.py)"
```