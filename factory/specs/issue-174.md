<!-- factory-spec v1 -->
---
spec_version: 1
issue: 174
title: 'Site Financials tab (CFO view): budget vs spend, per-issue target/cap, prediction accuracy'
status: approved
complexity: complex
complexity_reason: 'six interlocking sections (headline cards, inline SVG budget charts, per-issue economics, per-model/per-work-type spend, prediction accuracy, data freshness) plus budget math across week and month boundaries, many edge cases and byte-identical deterministic output'
risk: normal
work_type: code
model: Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo
model_override_reason: 
model_reason: 'High risk or complex work (build/fix) → Qwen3-Coder, fast non-thinking coder (issue 128)'
predicted_tokens_in: 800000
predicted_tokens_cached: 560000
predicted_tokens_out: 50000
predicted_cost_usd: 0.1780
budget_cap_usd: 1.00
price_table_version: '2026-11-02'
approved_by: michael
approved_at: '2026-11-11T16:29:00-06:00'
drafted_by: oc-spec-run
over_target_approved_by: michael
---

## Outcome

A CFO-style Financials tab answers four questions in one screen: what the factory cost this week and this month, whether that is under Michael's budgets, which issues and models drove it, and how good the predictions are. It renders from `site-data/marts/*.json` (from #170) only, offline, with no JS and no chart library, and every number is asserted against the fixture values.

## Context

Part of #169. This is the build-5 complex test of escalation routing before #156. The merged #171 site generator (`scripts/factory-site.py`, `factory/site/base.html`, `factory/site/style.css`, `scripts/factory-site-build.sh --sample`) already produces the four-tab skeleton and a Financials placeholder; the merged #170 marts and export (`factory/budget.yml`, the budget-vs-spend marts, `scripts/factory-site-data.py`, the committed fixtures under `tests/site-data/sample-marts/`) provide the seven marts plus the whitelisted `fct_agent_runs` subset that this tab reads. Budget numbers for the headline cards come from `factory/budget.yml` (owner-only, read-only here; do not edit it). The issue asks for a complex build with risk normal: it is website/pages work and touches no secrets, auth, workflows or spend enforcement.

## Scope

Replace the Financials placeholder in `scripts/factory-site.py` with a full tab that reads `site-data/marts/*.json` and renders six sections, each with a footnote naming its source mart:

1. **Headline cards** (`rpt_run_rate`): this week's spend vs the weekly budget (% used), month-to-date vs the monthly budget (% used), projected month-end, fixed costs, total month-to-date, Actions minutes vs quota, with a warn colour at `warn_pct` read from `factory/budget.yml`.
2. **Budget vs spend** (`agg_spend_weekly`, `agg_spend_monthly`): an inline SVG bar chart of the last 12 ISO weeks with a weekly budget line, and the last 6 months with a monthly budget line, each with a table fallback. The charts come from a small helper (`factory/site/charts.py` or inside the script) with no JS and no chart library.
3. **Per-issue economics** (`agg_spend_by_issue`, `rpt_issue_target_compliance`): the top 15 issues by spend with a run count, under $0.15 target ✓/✗, under $1 cap ✓/✗ and headroom; a compliance summary of % of issues under target and the count over cap (should be 0).
4. **By model and by work type** (`agg_spend_by_model`, `fct_agent_runs`): spend, runs and average cost per run for spec, build and fix, by model, showing whether escalation (Pro, Qwen3-Coder) is used and what it costs.
5. **Prediction accuracy** (`fct_forecast_vs_actual`): predicted vs actual per issue and per complexity tier, the median and worst absolute error, and a "recalibrate priors" flag when the median error is above 100%.
6. **Data freshness** (`fct_agent_runs`): latest run time in UTC and America/Chicago, the number of records, and the number of records skipped as invalid.

Create an offline test script and edge-case marts fixtures. Keep the charts and all math deterministic (stable sorts, pinned clock via `--now` / `SOURCE_DATE_EPOCH`) so two runs are byte-identical.

## Out of scope

Do not edit `factory/budget.yml` (owner-only budgets; read it but never write it). Do not edit any existing script, in particular `scripts/factory-site.py` is the one existing script this build edits (the worker may edit its content; it is not on the protected list) — but do not touch any protected spend/security script in `bash scripts/opencode-artifact-scan.sh --list-protected` (`scripts/factory-site-data.py`, `scripts/factory-site-build.sh`, `scripts/factory-collect-runs.py`, `scripts/factory-predict-cost.py`, etc.). Do not touch `.github/`, `opencode.json`, any `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, or `requirements-factory.txt`. Do not add, remove or re-pin a Python package (PyYAML and jsonschema come from the pinned `requirements-factory.txt`); the charts use stdlib only. Do not implement the Backlog or dbt tabs (those are #172 and #173). Do not publish the site or add a deploy workflow (that is #56). The generated `site/` and `site-data/` are gitignored and never committed; do not commit generated JSON. Do not change `.gitignore` unless you only add lines. Keep the work to one PR of roughly 300 changed lines or less; if it cannot fit, stop and propose a split.

## Files

- Create: `scripts/test-factory-site-financials.sh`
- Create: `factory/site/charts.py`
- Create: `tests/site/fixtures/marts/over-budget/agg_spend_weekly.json`
- Create: `tests/site/fixtures/marts/over-budget/agg_spend_monthly.json`
- Create: `tests/site/fixtures/marts/over-budget/agg_spend_by_issue.json`
- Create: `tests/site/fixtures/marts/over-budget/agg_spend_by_model.json`
- Create: `tests/site/fixtures/marts/over-budget/rpt_issue_target_compliance.json`
- Create: `tests/site/fixtures/marts/over-budget/fct_forecast_vs_actual.json`
- Create: `tests/site/fixtures/marts/over-budget/rpt_run_rate.json`
- Create: `tests/site/fixtures/marts/over-budget/fct_agent_runs.json`
- Create: `tests/site/fixtures/marts/zero-budget/agg_spend_weekly.json`
- Create: `tests/site/fixtures/marts/zero-budget/agg_spend_monthly.json`
- Create: `tests/site/fixtures/marts/zero-budget/rpt_run_rate.json`
- Create: `tests/site/fixtures/marts/zero-budget/fct_agent_runs.json`
- Create: `tests/site/fixtures/marts/partial-week/agg_spend_weekly.json`
- Create: `tests/site/fixtures/marts/partial-week/agg_spend_monthly.json`
- Create: `tests/site/fixtures/marts/partial-week/rpt_run_rate.json`
- Create: `tests/site/fixtures/marts/partial-week/fct_agent_runs.json`
- Create: `tests/site/fixtures/marts/null-prediction/agg_spend_by_issue.json`
- Create: `tests/site/fixtures/marts/null-prediction/fct_forecast_vs_actual.json`
- Create: `tests/site/fixtures/marts/null-prediction/fct_agent_runs.json`
- Create: `tests/site/fixtures/marts/no-runs/rpt_run_rate.json`
- Create: `tests/site/fixtures/marts/no-runs/agg_spend_weekly.json`
- Create: `tests/site/fixtures/marts/no-runs/agg_spend_monthly.json`
- Create: `tests/site/fixtures/marts/no-runs/fct_agent_runs.json`
- Edit: `scripts/factory-site.py`
- Edit: `factory/site/style.css`
- Edit: `factory/site/README.md`

## Acceptance criteria

- [ ] On the sample fixture marts (`tests/site-data/sample-marts/`), every headline number (this week's spend vs the weekly budget, MTD vs the monthly budget, projected month-end, fixed costs, total MTD, Actions minutes vs quota, warn colour) equals the corresponding fixture value, asserted by the test.
- [ ] The SVG charts render as valid inline SVG, and the bar count equals the number of weeks (last 12) and months (last 6) in the fixture, with a budget line; each chart has a table fallback.
- [ ] Every section has a footnote naming its source mart.
- [ ] Output is byte-identical across two runs with a pinned clock.
- [ ] Each edge case (no runs, one run, spend exactly at budget, over budget, zero budget with no divide-by-zero, partial current week, month boundary, null `predicted_cost_usd`) has a fixture, and the page renders for every one.
- [ ] Negative values are asserted impossible (the renderer asserts and fails loudly).
- [ ] `bash scripts/test-factory-site-financials.sh` passes, covering the headline numbers, SVG bar counts and validity, footnotes, determinism, the edge-case fixtures, and the no-JS / no-remote-CSS link checks.
- [ ] Screenshots of the Financials tab (normal and over-budget fixture) are in the PR Evidence section.

## Verification

```bash
bash scripts/test-factory-site-financials.sh
```

Expected:
```
PASS  headline cards equal the fixture values with warn colour
PASS  weekly SVG chart has 12 bars with a budget line and a table fallback
PASS  monthly SVG chart has 6 bars with a budget line and a table fallback
PASS  every section has a footnote naming its source mart
PASS  second render is byte-identical with pinned build time
PASS  no-runs fixture renders with zero spend and no divide-by-zero
PASS  one-run fixture renders
PASS  at-budget fixture renders without warn
PASS  over-budget fixture renders with warn colour and a bar past the line
PASS  zero-budget fixture shows no-budget-set and no divide-by-zero
PASS  partial-week and month-boundary fixtures render
PASS  null-prediction rows are excluded from accuracy and counted
PASS  negative spend is rejected loudly
PASS  site HTML has no script src or remote CSS, and only GitHub or dbt-docs http(s) links
Results: 14 passed, 0 failed
```
The final line must report `Results: 14 passed, 0 failed`. The test script must not run a live `dbt build` or `dbt run` (dbt crashes in the `/oc` sandbox on Python 3.14, #148), must not invoke `scripts/factory-collect-runs.py`, and must make no network calls; it renders `scripts/factory-site.py` directly against the committed sample marts under `tests/site-data/sample-marts/` and the new edge-case fixtures under `tests/site/fixtures/marts/`, feeding a temp data dir of `<model>.json` files in the exported `{"model": ..., "rows": [...]}` format, and a pinned `--now` (and `SOURCE_DATE_EPOCH`) for determinism. Every headline number is asserted against the fixture value by string or computed comparison, and each SVG is parsed as XML to prove it is valid and to count bars. The no-JS / no-remote-CSS / GitHub-or-dbt-docs-only link check inspects the generated `site/*.html`. No checked command is piped into `head`, `tail` or `grep -q` without `set -o pipefail` (the harness already enables `pipefail`); full output is printed.

## Classification

- complexity: complex — six interlocking sections, inline SVG chart generation, budget math across week and month boundaries, many edge cases and byte-identical deterministic output; more than a single or small change. The issue and the escalation-route test require `complex` so the build routes to Qwen3-Coder-480B (rule 1).
- risk: normal — website/pages work per FACTORY.md merge authority; UI evidence (screenshots) is required and a human product gate applies. Not high: it adds no secrets, auth, licenses or workflows, touches no protected or owner-only paths, and does not enforce spend.
- work_type: code.
- Model routing and reason match the front matter; the harness fills the model fields.

## Cost forecast

Tokens in/cached/out and predicted cost are left for `factory-predict-cost.py` to route. This is the complex build the issue sized at about $0.18 on the complex token prior, with recent actuals about 2× prediction so expect roughly $0.20–$0.40 — above the $0.15 target, well under the $1 cap. If the build prediction exceeds about $0.50, split into (a) headline cards + per-issue economics + by-model/by-work-type + data freshness, and (b) the SVG charts + prediction accuracy, as two PRs; otherwise one PR.

## Manual steps for Michael

None. `factory/budget.yml` is read (for `warn_pct` and the budget values) but never written by the worker. Live `dbt build` in the full (non-`--sample`) build path is not run by the harness (dbt crashes in the `/oc` sandbox on Python 3.14, #148) and is not part of this issue's acceptance; the test renders from the committed fixtures offline. Screenshots of the tab (normal and over-budget fixture) must be placed in the PR Evidence section by the worker before the human product gate.

## Dependencies

None blocking. Builds on the merged #171 (site skeleton) and #170 (marts and export); both are on main, so the marts fixtures under `tests/site-data/sample-marts/` and the exported `site-data/marts/*.json` format already exist. Do not treat them as missing. The Backlog and dbt tabs (#172, #173) are separate and not built here.

## Worker prompt

Read issue #174 and `.factory/FACTORY.md` first. In `scripts/factory-site.py`, replace the Financials placeholder with a full CFO-style tab that reads only `site-data/marts/*.json` and renders six sections, each with a footnote naming its source mart: (1) headline cards (`rpt_run_rate`) with this week's spend vs the weekly budget and MTD vs the monthly budget (% used), projected month-end, fixed costs, total MTD and Actions minutes vs quota, with a warn colour at `warn_pct` read from `factory/budget.yml`; (2) inline SVG bar charts (`agg_spend_weekly`, `agg_spend_monthly`) of the last 12 ISO weeks and last 6 months with a budget line and a table fallback, via a small helper `factory/site/charts.py` (or inside the script) with no JS and no chart library; (3) per-issue economics (`agg_spend_by_issue`, `rpt_issue_target_compliance`) for the top 15 issues by spend with run count, under-target ✓/✗, under-cap ✓/✗ and headroom, plus a compliance summary (% under target, count over cap, should be 0); (4) by-model and by-work-type spend, runs and average cost per run for spec, build and fix (`agg_spend_by_model`, `fct_agent_runs`); (5) prediction accuracy (`fct_forecast_vs_actual`) per issue and per complexity tier with median and worst absolute error and a "recalibrate priors" flag when the median error is above 100%; (6) data freshness (`fct_agent_runs`) with the latest run time in UTC and America/Chicago, the record count, and the count skipped as invalid. Handle the bad inputs and edge cases in the issue: no runs, one run, spend exactly at budget, over budget (bar past the line, card red), a zero budget (show "no budget set", no divide-by-zero), a partial current week, a month boundary, `predicted_cost_usd` null (excluded from accuracy and counted), and very large and very small values (chart scaling). Negative values must be impossible: assert and fail loudly. Use stdlib + the pinned PyYAML only; add no dependency. Read `factory/budget.yml` but never edit it. Make the output deterministic (stable sorts, pinned clock via `--now` / `SOURCE_DATE_EPOCH`) so two runs are byte-identical. Create `scripts/test-factory-site-financials.sh` that renders `scripts/factory-site.py` against the committed sample marts under `tests/site-data/sample-marts/` and the new edge-case fixtures under `tests/site/fixtures/marts/` (feeding a temp data dir of `<model>.json` files in the exported `{"model": ..., "rows": [...]}` format, never running live dbt, never invoking `scripts/factory-collect-runs.py`, and making no network calls), asserting every headline number equals its fixture value, that each SVG is valid XML with the right bar count, that every section has a footnote, that the output is byte-identical across two pinned runs, that each edge-case fixture renders, that null-prediction rows are excluded from accuracy and counted, that negative spend is rejected loudly, and that `site/*.html` has no `<script src=`, no remote CSS and only GitHub or dbt-docs `http(s)` links. Update `factory/site/style.css` for the cards, warn colour, charts and footnotes, and `factory/site/README.md` to describe the Financials tab and its marts. Put screenshots of the tab (normal and over-budget fixture) in the PR Evidence section. Keep the work to one PR of roughly 300 changed lines or less; if it cannot fit, stop and propose the split in the issue. Fill the PR template; tick only what you proved.

## Design / approach

Extend the existing single-file renderer rather than adding a framework: `scripts/factory-site.py` gains a `financials_html(data_dir)` implementation (it already reads `site-data/marts/*.json`) plus small pure functions for the six sections, all stdlib. `factory/site/charts.py` holds the SVG generation: given weekly or monthly spend rows and a budget, it computes bar heights and a budget line in a fixed viewBox, normalising large and small values and clamping a zero budget to a "no budget set" label, and returns an SVG string plus the same data as a table fallback. Budget numbers for the headline cards (`warn_pct`, weekly/monthly budget) come from reading `factory/budget.yml` with the pinned PyYAML (read-only). Every number is derived from the fixture rows with a stable sort and a pinned clock (`--now` / `SOURCE_DATE_EPOCH`) so output is byte-identical. Negative values are asserted at the top of each aggregation and raise loudly rather than render. Prediction accuracy excludes rows with a null `predicted_cost_usd` and counts them separately. All text is passed through `html.escape`.

## Alternatives considered

Required because complexity is complex. A JavaScript charting library (Chart.js, D3) was rejected because the issue explicitly wants no JS and no chart library, and it would add a dependency beyond the pinned `requirements-factory.txt`; inline SVG is rendered server-side and stays phone-readable and offline. A separate `scripts/factory-site.py` sub-command or a new top-level script was rejected in favour of extending the existing renderer, which already owns the Financials tab plug-in contract and the tab nav. Pre-computing the charts or numbers in `scripts/factory-site-data.py` was rejected because #170's export already owns the marts and this tab should render what the marts expose. Splitting the tab into two issues up front was rejected because the issue sizes it as one complex build; the split is only the fallback if the cost prediction nears the cap.

## Risks, rollback and revert trigger

Required because complexity is complex. Risk: a divide-by-zero when a budget is zero or missing; mitigated by a "no budget set" path and guarded division, asserted by the zero-budget fixture. Risk: non-deterministic output (dict ordering, wall clock) breaks the byte-identical check; mitigated by stable sorts and a pinned clock, asserted by the determinism test. Risk: a negative or invalid value renders instead of failing; mitigated by loud asserts on every aggregation, asserted by the negative-value test. Risk: an unescaped value (a model id, issue number or fixture cell containing HTML) is injected; mitigated by `html.escape` on all text, asserted by the no-script/no-remote-CSS check. Risk: a chart is malformed SVG or has the wrong bar count; mitigated by parsing each SVG as XML and counting bars in the test. Rollback is a normal code revert of the new files and the small edits to `scripts/factory-site.py`, `factory/site/style.css` and `factory/site/README.md`; no other existing file is edited. Revert trigger: if a headline number on the sample marts does not equal its fixture value, or a fixture fails to render, or two builds with the same pinned time are not byte-identical, revert.

## What changes in production on merge

The Financials tab of the generated site goes from a "not available yet" placeholder to a full CFO view rendered from the #170 marts. The site is not yet published (that is #56), so production behavior is otherwise unchanged: no workflow, spend, gate or model-routing behavior changes, and nothing here enforces spend. The generated `site/` and `site-data/` remain gitignored and uncommitted. `scripts/factory-site.py` is the only existing file edited, alongside `factory/site/style.css` and `factory/site/README.md`, plus the new chart helper, test script and fixtures.

## Success metric (baseline, target, how measured)

Required because complexity is complex. Baseline: the Financials tab shows the placeholder; there are no headline cards, charts, per-issue economics, prediction accuracy or data freshness. Target: the tab renders all six sections from the marts with every headline number equal to its fixture value, valid inline SVG charts with a budget line and a table fallback and the correct bar count, a footnote naming the source mart in every section, byte-identical output across two pinned runs, and clean rendering of every edge-case fixture with negative values rejected loudly. Measured by `bash scripts/test-factory-site-financials.sh` run by the verification harness, plus the normal and over-budget screenshots in the PR Evidence section.

## Test plan detail (broken case shown blocked)

Required because complexity is complex. Happy path: rendering the sample marts under `tests/site-data/sample-marts/` yields every headline number matching its fixture value, valid SVG with 12 weekly and 6 monthly bars plus budget lines and table fallbacks, a footnote per section, and byte-identical output across two pinned runs. Broken cases shown blocked: a zero-budget fixture renders "no budget set" with no divide-by-zero (the renderer does not crash and prints no NaN); a negative spend value causes a loud assert (non-zero exit) rather than rendering; a null `predicted_cost_usd` row is excluded from the accuracy statistics and reported in a skip count; a no-runs fixture renders zero spend with no division; an over-budget fixture shows a warn colour and a bar past the budget line; a partial current week and a month boundary render with correct week/month grouping. These are proven by the edge-case fixtures under `tests/site/fixtures/marts/`, each rendered and checked by the test. Determinism: two renders with the same pinned build time are byte-identical. The test never runs a live `dbt build`/`dbt run` and never invokes `scripts/factory-collect-runs.py`.

## Security and liability review (`liability-gates.md`)

Required because complexity is complex. No secrets, keys, tokens or environment values are read or printed; `html.escape` is applied to all text rendered from the marts so no injected HTML or script can reach the page. `factory/budget.yml` is read only, never written or echoed. No protected spend/security script, workflow, or owner-only file is touched; no dependency is added or re-pinned. Generated `site/` and `site-data/` output is gitignored and never committed. Reporting-only change: nothing here enforces or changes spend, so no cost or liability claim is introduced. Screenshots in the PR Evidence section satisfy the UI-evidence requirement for the normal-risk product gate.

## Milestones / split plan (when near the cap)

Required because complexity is complex. Expected to fit in one PR around the issue's ~300-line estimate and well under the $1 cap. If the build prediction approaches about $0.50 (or the changed lines approach ~300), split into two PRs: (a) headline cards + per-issue economics + by-model/by-work-type + data freshness, and (b) the SVG charts + prediction accuracy. No split is planned unless the prediction warrants it.
