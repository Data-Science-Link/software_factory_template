# Factory monthly review (`scripts/factory-monthly-review.py`)

Repo-agnostic, **stdlib-only** 30-day health packet for adopting teams. Aggregates run records under `factory/runs/` (or any `--runs-dir`), reads budget caps from `factory/budget.yml` with fallback to `.factory/models.yaml`, and prints a single Markdown review or sorted JSON. No pip packages, no network.

## Ritual (about 15 minutes)

1. **Collect runs** — ensure recent factory runs are present under `factory/runs/` (or use `scripts/factory-collect-runs.py` in CI).
2. **Generate the packet** — default 30-day window, pinned end date for reproducible review notes:

   ```bash
   python3 scripts/factory-monthly-review.py --as-of YYYY-MM-DD
   ```

3. **Read action prompts** — each bullet is tagged **Keep**, **Tune**, or **Investigate**. Tune items usually map to `.factory/models.yaml` routing; Investigate items belong in `.factory/DECISIONS.md` as owner decisions.
4. **Log decisions** — append accepted changes to [`.factory/DECISIONS.md`](../.factory/DECISIONS.md) (date, decision, rationale). Update model caps or routing in [`.factory/models.yaml`](../.factory/models.yaml) when Tune prompts say so.
5. **Archive** — optionally save output with `--out reviews/monthly-YYYY-MM-DD.md` for audit.

## Quick commands

```bash
# Default: last 30 days, budget from factory/budget.yml
python3 scripts/factory-monthly-review.py

# Golden examples (no private data)
python3 scripts/factory-monthly-review.py \
  --runs-dir examples/sample-runs \
  --as-of 2026-11-20

# Machine-readable report for CI or dashboards
python3 scripts/factory-monthly-review.py --json --out /tmp/monthly-review.json

# Custom window length
python3 scripts/factory-monthly-review.py --days 7 --as-of 2026-11-20
```

## What it measures

| Section | Metrics |
|---|---|
| Volume & reliability | Total runs, unique issues, pass rate, merged rate, fix-round rate |
| Spend & budget | Window spend, calendar-month % of monthly cap, average cost per issue, issues over `issue_target_usd` |
| Work type | `code` vs `review` runs, spend, and share % |
| Model efficiency | Per-model runs, spend, cache hit (`tokens_cached / tokens_in`), pass rate |
| Failures | Breakdown by `error_class` (when present) and `outcome` |
| Action prompts | Rule-based Keep / Tune / Investigate findings |

Malformed JSON files are skipped (`skipped_files` in JSON output); the command never raises on bad files.

## Related tooling

- [`scripts/factory-cost-digest.py`](../scripts/factory-cost-digest.py) — weekly CFO digest (PyYAML required)
- [`scripts/factory-routing-report.py`](../scripts/factory-routing-report.py) — routing slice report
- [`docs/COST_DIGEST.md`](COST_DIGEST.md) — weekly vs monthly cadence notes

## Tests

```bash
bash scripts/test-factory-monthly-review.sh
```