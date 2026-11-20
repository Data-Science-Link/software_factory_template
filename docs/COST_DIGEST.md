# Factory cost digest (`scripts/factory-cost-digest.py`)

Offline CFO-style spend and quality summary from factory run JSON under `factory/runs/` (or collected copies). No network, no dbt — stdlib plus PyYAML reading budget caps from `.factory/models.yaml`.

## Quick commands

```bash
pip install -r requirements-factory.txt   # once, in a venv

# Weekly check-in (last 7 days, Chicago calendar week/month burn)
python3 scripts/factory-cost-digest.py --days 7

# Default monthly-style window (30 days)
python3 scripts/factory-cost-digest.py

# Machine-readable output for dashboards or CI
python3 scripts/factory-cost-digest.py --json --days 30

# Pin reporting date for reproducible review packets (#110)
python3 scripts/factory-cost-digest.py --as-of 2026-11-20 --days 30 --tz America/Chicago
```

## What it reports

1. **Headline scorecard** — runs in the window, total spend, weekly and monthly burn vs budget caps from `models.yaml` (`deepinfra_monthly_limit_usd`, derived weekly = monthly÷4 unless `weekly_usd` is set), average cost per issue vs `issue_target_usd`, pass rate, and overall cache hit rate.
2. **Top issues by spend** — flags issues over target, over cap, or approaching `issue_cap_usd`.
3. **Breakdowns** — by model, harness, and provider (runs, spend, average per run, cache hit when token fields exist).
4. **Review readiness** — month-over-month cost trend, failure/overrun counts, and concrete next-step bullets for the [1-month factory review](https://github.com/Data-Science-Link/software_factory_template/issues/110).

## Weekly vs monthly review (#110)

| Cadence | Suggested flags | Focus |
|---|---|---|
| Weekly | `--days 7` | Weekly burn % used, failures in the last week, issues over target |
| Monthly (review #110) | `--days 30` plus `--as-of <review-date>` | Full scorecard, top issues, routing/caching recommendations |

Run records must use UTC `...Z` timestamps on `started_at`. Calendar week and month boundaries use `--tz` (default `America/Chicago`).

## Tests

```bash
bash scripts/test-factory-cost-digest.sh
```

Fixtures live under `tests/factory-cost-digest/` with deterministic expected math for spend, budget percentages, cache rate, and overrun flags.

## Related tooling

- `scripts/factory-cache-report.py` — cache hit rates only
- `scripts/factory-routing-report.py` — model routing quality slices
- `scripts/factory-budget-vars.py` — committed `factory/budget.yml` for dbt/site marts (digest reads caps from `models.yaml` by default)