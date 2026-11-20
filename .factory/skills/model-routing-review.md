# Model routing review (periodic)

Use this after ~20–30 real issues land in `fct_agent_runs` (or when `factory/runs/` on a branch holds committed records). The bar from issue #122: look at the run table, tweak `.factory/models.yaml` only when the data supports it — no auto-router, no default MCP sprawl.

## 1. Offline report from run JSON

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-factory.txt

# Default: markdown on stdout (or: python3 scripts/factory-cli.py routing-report)
python3 scripts/factory-routing-report.py

# Explicit paths and JSON
python3 scripts/factory-routing-report.py \
  --runs-dir factory/runs \
  --models .factory/models.yaml \
  --json

python3 scripts/factory-routing-report.py --markdown > /tmp/routing-report.md
```

The report groups runs by **model**, **phase** (`spec` / `build` / `fix`), **complexity**, and **risk**, and prints run count, mean/median/total cost, mean duration, first-pass success rate, fix-round rate, and mean cache-hit ratio. Slices with fewer than five runs get an explicit **insufficient sample size** note instead of invented tuning advice.

## 2. Same metrics from dbt (`fct_agent_runs`)

When the analytics project is built:

```bash
cd factory/dbt
dbt build --select fct_agent_runs
```

Example ad-hoc query (adjust filters for your review window):

```sql
select
    model_id,
    complexity,
    risk,
    work_type,
    count(*) as runs,
    avg(actual_cost_usd) as mean_cost_usd,
    median(actual_cost_usd) as median_cost_usd,
    sum(actual_cost_usd) as total_cost_usd,
    avg(duration_s) as mean_duration_s,
    avg(case when issue_run_seq = 1 and gate_passed then 1.0 else 0.0 end) as first_pass_rate,
    avg(case when issue_run_seq > 1 then 1.0 else 0.0 end) as fix_round_rate,
    avg(cache_hit_rate) as mean_cache_hit_rate
from fct_agent_runs
group by 1, 2, 3, 4
order by 1, 2, 3, 4;
```

Map `work_type = 'spec'` to phase **spec**; treat `outcome = 'pr_updated'` as phase **fix**; other code/docs/data/review rows as **build** (same rule as `scripts/factory-run-review.py`).

## 3. What to change (human PR only)

1. Read the **Recommendations** section of the report (or your dbt aggregates).
2. Propose **simple** rule tweaks in `.factory/models.yaml` only when a slice has enough runs and a clear signal (e.g. sustained high fix-round rate or low first-pass rate on one model/tier).
3. Paste the relevant table rows or JSON group into the PR body as evidence.
4. Do **not** merge routing changes without owner review.

## 4. Read-only docs lookup check (default-off MCP)

Issue #122: enable Context7 (or similar) **only** if product-repo runs often fail because the model lacks current library versions.

The report's **Docs lookup** block scans **notes** on product-repo `work_type: code` runs for phrases such as “knowledge cutoff” or “library version”. It does **not** call any MCP.

| Signal | Action |
|--------|--------|
| Fewer than 5 product-repo code runs | Keep `opencode.json` `mcp: {}` |
| Zero cutoff hits in notes | Keep `mcp: {}` |
| Repeated cutoff hits | Consider optional read-only docs MCP in a separate PR: `"oauth": false`, default-deny tool permissions, owner approval |

Manual spot-check (optional): open recent `/oc` failure logs or run-review output for version/cutoff language; the scripted check is a cheap first pass, not a substitute for reading failures.

## 5. Regression tests

```bash
bash scripts/test-factory-routing-report.sh
bash scripts/test-run-records.sh
```