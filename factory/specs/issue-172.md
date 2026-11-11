<!-- factory-spec v1 -->
---
spec_version: 1
issue: 172
title: 'Site Backlog tab: open issues by priority, risk, status and epic progress'
status: approved
complexity: simple
complexity_reason: 'one new data script plus a tab renderer upgrade and a build-stage addition, all offline-testable from a committed fixture'
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
approved_at: '2026-11-11T16:03:36-06:00'
drafted_by: oc-spec-run
---

## Outcome

The Backlog tab (`site/backlog.html`) shows the factory's open work at a glance: summary counts, a priority × risk table, an epic list with done/total, and a sorted issue table linking to each issue, always showing titles, generated offline from a committed fixture by `scripts/factory-backlog.py` and rendered by the upgraded `scripts/factory-site.py`.

## Context

Part of #169 (the factory site). #171 merged the site skeleton and the tab plug-in contract: `scripts/factory-site.py` already reads `site-data/backlog.json` in `backlog_html()` and renders a plain title list, and `scripts/factory-site-build.sh --sample` already builds offline. This issue replaces that placeholder list with a full Backlog tab and adds the data producer. A standing site decision (epic #169, Michael 2026-11-11: "Backlog: always show titles") requires titles on every open issue, with no `--titles on|off` switch. This repo is now public and the factory-site workflow from #206 is already on main, so those titles will be published on the public Pages Backlog tab after the next deploy. (A private checkout of this template still stays artifact-only and does not publish Pages.) The tab renders deterministically and HTML-escapes all titles. Risk is normal (pages/website work per FACTORY.md merge authority); complexity is simple per the issue classification.

## Scope

Create `scripts/factory-backlog.py --out FILE [--from-json FILE]`:
- Live mode (no `--from-json`) runs `gh issue list --state open --limit 500 --json number,title,labels,createdAt,updatedAt,url,subIssuesSummary`, using `GITHUB_TOKEN`/`GH_TOKEN` only in the deploy job; it is never called by `/oc` agents or the verification harness. `subIssuesSummary` is required in the `--json` field list so live mode can return epic progress (`gh issue list` will not include it unless requested). If `gh` is missing or unauthenticated, print a clear error and exit non-zero (live mode only).
- `--from-json FILE` reads a fixture for tests and offline builds; no `gh` call, no network.
- Exclude pull requests (items with a `is_pull_request` field or `pull_request` key) from the API result.
- Normalize labels into fields: `priority` = `high`/`low`/`none` from `priority:*` labels (two `priority:*` labels → take the higher: `high` over `low`); `risk` = the `risk:*` label, else `"unlabeled"`; `status` = `epic` when `epic` is present, else `owner-action` when `owner-action` is present, else `factory:selected` when `factory:selected` is present, else `"open"` (precedence if more than one of those labels is present: epic > owner-action > factory:selected > open).
- Always include `title` for every issue (no `--titles` switch).
- Epic progress: for `epic`-labeled issues, include `done`/`total` from `subIssuesSummary` (the `gh --json` field name; a fixture may also use the API spelling `sub_issues_summary`). If the field is absent, omit `done`/`total` or treat them as zero.
- Write the JSON array of normalized issues to `--out`.

Edit `scripts/factory-site.py` `backlog_html()` to render the full Backlog tab from `site-data/backlog.json`:
- summary cards (open count, high priority, owner-action, selected);
- a count table of issues by priority × risk;
- an epic list with done/total progress;
- an issue table sorted by priority (high first, then low, then none), then most recently updated descending, each row linking to the issue `url`.
- Titles always shown and HTML-escaped. Deterministic output (stable sort). Missing or unreadable `backlog.json` → keep the "This tab is not available yet" placeholder rather than crash. An empty list (`[]`, zero open issues) is valid data: render the full Backlog tab with zero counts and empty tables, not the placeholder.

Edit `scripts/factory-site-build.sh` to add the backlog stage before render:
- live: run `scripts/factory-backlog.py --out site-data/backlog.json`;
- `--sample`: run `scripts/factory-backlog.py --from-json tests/site/fixtures/issues.json --out site-data/backlog.json` (offline, no `gh`, no network).

Create the fixture `tests/site/fixtures/issues.json` (the GitHub API-shaped issues list for the test) and `scripts/test-factory-backlog.sh`. Also cover zero open issues, either with a second fixture (`tests/site/fixtures/issues-empty.json` as `[]`) or an in-test empty input: the producer writes `[]` and the tab renders zeros, not the placeholder.

Edit `factory/site/README.md` to describe the Backlog tab and the offline fixture build. The worker may also edit `factory/site/style.css` if the summary cards or tables need styles that the existing stylesheet does not provide; no new CSS file, no remote assets.

## Out of scope

Do not edit any protected spend/security script (see `bash scripts/opencode-artifact-scan.sh --list-protected`). Do not touch `.github/`, `opencode.json`, any `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, `requirements-factory.txt`, or any other dot-path. Do not call `gh` or make any network call inside tests or the verification harness; live `gh issue list` runs only in the deploy job, never in the `/oc` sandbox. Do not add, remove or re-pin a Python package (stdlib + PyYAML only). Generated `site/` and `site-data/` output stays gitignored and is never committed; do not edit `.gitignore` unless you only add lines. Do not build the Financials or dbt tabs (those are #174 and #173). Do not publish the site or add a deploy workflow (#56). Keep the work to one PR of roughly 300 changed lines or less.

## Files

- Create: `scripts/factory-backlog.py`
- Create: `scripts/test-factory-backlog.sh`
- Create: `tests/site/fixtures/issues.json`
- Create: `tests/site/fixtures/issues-empty.json` (optional if the empty-list case is inlined in the test)
- Edit: `scripts/factory-site.py`
- Edit: `scripts/factory-site-build.sh`
- Edit: `factory/site/README.md`
- Edit: `factory/site/style.css` (only if needed for the summary cards or tables)

## Acceptance criteria

- [ ] `scripts/factory-backlog.py --from-json tests/site/fixtures/issues.json --out <tmp>/backlog.json` produces JSON whose priority and risk counts match a hand count written in the test.
- [ ] The output always includes `title` for every issue; there is no `--titles` switch.
- [ ] The Backlog tab renders deterministically and every issue title is HTML-escaped (a title with `<script>` or `&` renders escaped, no raw tag).
- [ ] `bash scripts/factory-site-build.sh --sample` adds the backlog stage and produces `site/backlog.html` with the summary cards, priority × risk table, epic list with done/total, and the sorted issue table with links, all offline.
- [ ] A title with HTML or emoji renders escaped; an issue with two `priority:*` labels takes the higher one; a pull request in the fixture is excluded; an issue with no labels normalizes to `priority: none`, `risk: unlabeled`, `status: open`.
- [ ] Zero open issues (`[]`) produce empty JSON and a rendered Backlog tab with zero counts, not the "not available yet" placeholder.
- [ ] `bash scripts/test-factory-backlog.sh` passes, covering JSON counts, title presence, escaping, PR exclusion, normalization, the zero-open-issues case, determinism, and the rendered table.
- [ ] A screenshot of the Backlog tab is in the PR Evidence section.

## Verification

```bash
bash scripts/test-factory-backlog.sh
```

Expected:
```
PASS  backlog JSON counts by priority and risk match the hand count
PASS  every issue output includes a title (no --titles switch)
PASS  pull requests are excluded from the fixture result
PASS  an issue with no labels normalizes to priority none / risk unlabeled / status open
PASS  two priority: labels take the higher one
PASS  a title with HTML is html.escape-d in the rendered table (no raw <script>)
PASS  the Backlog tab renders summary cards, priority x risk table, epic list and sorted issue table with links
PASS  the render is deterministic with a pinned build time
PASS  an empty issues list renders the Backlog tab with zero counts, not the placeholder

Results: 9 passed, 0 failed
```
The final line must report `Results: 9 passed, 0 failed`. The test script runs entirely offline: it feeds `scripts/factory-backlog.py --from-json tests/site/fixtures/issues.json` and renders via `scripts/factory-site.py` (with `--now` pinned and the site fixtures already present under `tests/site/fixtures/`), and never invokes `gh`, `scripts/factory-collect-runs.py`, or any network. No checked command is piped into `head`, `tail` or `grep -q` without `set -o pipefail`; prefer printing full output.

## Classification

- complexity: simple — one new data script (a pure transform of a fixture) plus an upgrade of the existing `backlog_html()` renderer and a build-stage addition, all offline-tested from one committed fixture; no large refactor and no new dependency.
- risk: normal — pages/website work per FACTORY.md merge authority; UI evidence (screenshots) is required and a human product gate applies. Not high, because it adds no secrets, auth, licenses or workflows and touches no protected or owner-only path.
- work_type: code.
- Model routing and reason match the front matter; the harness fills the model fields.

## Cost forecast

Tokens in/cached/out and predicted cost are left for `factory-predict-cost.py` to route. The change is a small new data script, a focused renderer upgrade, a build-stage line and one fixture + test script, expected to land around the issue's estimate of $0.04–$0.08 and well under the $1 cap; no split is planned.

## Manual steps for Michael

None required to ship the tab. The factory-site workflow (#206, already on main) already runs `bash scripts/factory-site-build.sh` with `GH_TOKEN` and `issues: read`, so adding the live backlog stage to that script wires `gh issue list` into the next deploy. The repo is public; titles will appear on the public Pages Backlog tab per Michael's 2026-11-11 decision. This PR must not edit `.github/` (owner-only). Optional later owner paste, not this PR: add `scripts/factory-backlog.py` to the path filter in `.github/workflows/factory-site.yml` so backlog-script-only changes also trigger a rebuild; this PR still triggers deploy because it edits `scripts/factory-site*`.

## Dependencies

None blocking. Depends on #171 (site skeleton, already merged), which established `scripts/factory-site.py`, `scripts/factory-site-build.sh --sample`, `factory/site/base.html` and the `tests/site/fixtures/` renderer fixtures. Part of #169 (epic). The Financials and dbt tabs are separate sub-issues (#174, #173) and are not touched.

## Worker prompt

Read issue #172 and `.factory/FACTORY.md` first. Create `scripts/factory-backlog.py --out FILE [--from-json FILE]` that produces the normalized open-backlog JSON. In live mode (no `--from-json`) it runs `gh issue list --state open --limit 500 --json number,title,labels,createdAt,updatedAt,url,subIssuesSummary` and prints a clear error if `gh` is missing or unauthenticated; it is never called by `/oc` agents or the harness. `--from-json FILE` reads a fixture for tests and offline builds with no `gh` and no network. Exclude pull requests from the API result. Normalize labels into `priority` (`high`/`low`/`none` from `priority:*`; two such labels take the higher), `risk` (`risk:*`, else `"unlabeled"`) and `status` with precedence epic > owner-action > factory:selected > open. Always include `title` for every issue (no `--titles` switch). For `epic`-labeled issues include `done`/`total` from `subIssuesSummary` (or `sub_issues_summary` in a fixture) when present. Write the JSON array to `--out`. Upgrade `backlog_html()` in `scripts/factory-site.py` to render from `site-data/backlog.json`: summary cards (open, high priority, owner-action, selected), a priority × risk count table, an epic list with done/total, and an issue table sorted by priority then most recently updated, each row linking to the issue `url`, with all titles shown and HTML-escaped, output deterministic. Missing or unreadable `backlog.json` keeps the "not available yet" placeholder; an empty list `[]` renders the full tab with zero counts, not the placeholder. Add the backlog stage to `scripts/factory-site-build.sh`: live runs `scripts/factory-backlog.py --out site-data/backlog.json`; `--sample` runs `scripts/factory-backlog.py --from-json tests/site/fixtures/issues.json --out site-data/backlog.json` offline. The factory-site workflow already on main (#206) runs that build script with `GH_TOKEN`, so the live stage is wired on the next deploy; do not edit `.github/`. Create `tests/site/fixtures/issues.json` (a GitHub API-shaped issues list including an epic with `subIssuesSummary` or `sub_issues_summary`, an issue with two `priority:*` labels, an issue with no labels, a pull request to exclude, and a title containing HTML/emoji) and `scripts/test-factory-backlog.sh` (offline: assert JSON counts by priority and risk against a hand count, assert titles are present, assert an empty list renders zero counts not the placeholder, render the tab via `scripts/factory-site.py` with a pinned `--now`, and grep the rendered table; never call `gh` or any network). Edit `factory/site/README.md` to describe the Backlog tab and the offline fixture build. The worker may edit `factory/site/style.css` if the cards or tables need it. Do not edit any protected spend/security script, any owner-only file, or `.github/`; do not add or re-pin a dependency. Fill the PR template; tick only what you proved.

## Design / approach

Split the work cleanly into a data producer and a consumer so it stays offline-testable. `scripts/factory-backlog.py` is a pure function over a GitHub API-shaped list: it filters out PRs, normalizes the `priority:*`, `risk:*` and `epic`/`owner-action`/`factory:selected` labels into fields, and always copies `title` through. The live `gh issue list` path is a thin wrapper around that same normalize step, so `--from-json` exercises the identical logic in the sandbox with no network. `scripts/factory-site.py` `backlog_html()` reads the normalized `site-data/backlog.json` and renders it with the existing `string.Template` + `html.escape` machinery already used by the other tabs, keeping the tab plug-in contract from #171: missing data still yields the placeholder. Sorts are stable and keys are enumerated so output is deterministic; a pinned `--now` keeps two renders byte-identical. The build script just inserts the backlog stage before render, mirroring the existing `--sample` vs live branch.

## Alternatives considered

Optional for simple/normal but noted: folding the normalization directly into `factory-site.py` was rejected because the issue explicitly wants a separate `scripts/factory-backlog.py` that can be run live by a deploy job without also re-rendering the whole site, and because a dedicated script keeps the live `gh` call out of the renderer and out of the offline tests. Querying `gh` inside the renderer was rejected for the same reason (the harness and tests must never call `gh`). A `--titles on|off` switch was rejected per the standing site decision — titles always show.

## Risks, rollback and revert trigger

Risk: an unescaped issue title (HTML, `<script>` or `&`) is injected into `site/backlog.html`. Mitigated by `html.escape` on every title and asserted by the escaping test. Risk: the live `gh` path fails or is called in the sandbox. Mitigated by keeping `gh` only in the non-`--from-json` branch (never exercised by tests or the harness) and printing a clear error when `gh` is missing or unauthenticated. Risk: an issue with two `priority:*` labels, no labels, or a PR mixed in produces wrong counts or a crash. Mitigated by the higher-priority rule, explicit defaults, and PR exclusion, all asserted on the fixture. Risk: non-deterministic output (dict ordering) breaks the byte-identical second-run check. Mitigated by stable sorts and enumerated keys. Rollback is a normal code revert of the new files and of the edited scripts (`scripts/factory-site.py`, `scripts/factory-site-build.sh`), `factory/site/README.md`, and `factory/site/style.css` if it was edited; no protected or owner-only file is touched. Revert trigger: if the Backlog tab omits a title that is in the data, or an unescaped title renders raw HTML, or a fixture count by priority/risk does not match the hand count, or two builds with the same pinned time are not byte-identical, revert.

## What changes in production on merge

The repository gains `scripts/factory-backlog.py` and a full Backlog tab. The factory-site workflow (#206, already on main) already runs `bash scripts/factory-site-build.sh` with `GH_TOKEN` on push to main (and on schedule / workflow_dispatch). Adding the live backlog stage to that script means the next site deploy after merge will call `gh issue list` and publish the Backlog tab, including titles, to the public GitHub Pages site. The `--sample` build path also produces `site-data/backlog.json` from the fixture and `site/backlog.html` from the full tab. The generated `site/` and `site-data/` remain gitignored and uncommitted. This PR does not edit `.github/` or any workflow, gate, spend, or model-routing behavior; no secrets or env values are printed.

## Success metric (baseline, target, how measured)

Baseline: `site/backlog.html` shows only a placeholder (or a plain title list) and there is no `scripts/factory-backlog.py`. Target: `bash scripts/factory-backlog.py --from-json tests/site/fixtures/issues.json --out <tmp>/backlog.json` produces JSON whose priority and risk counts match the hand count in the test, every issue includes a `title`, and `bash scripts/factory-site-build.sh --sample` renders `site/backlog.html` with the summary cards, priority × risk table, epic list with done/total, and the sorted, linked issue table. Measured by `bash scripts/test-factory-backlog.sh` run by the verification harness (final line `Results: 9 passed, 0 failed`) and by the Backlog-tab screenshot in the PR Evidence section.

## Test plan detail (broken case shown blocked)

Happy path: the fixture `tests/site/fixtures/issues.json` (an epic with `subIssuesSummary` or `sub_issues_summary`, a two-`priority:*` issue, a no-label issue, a PR to exclude, and an HTML/emoji title) feeds `scripts/factory-backlog.py --from-json`; the resulting JSON's priority and risk counts match a hand count written in the test; rendering via `scripts/factory-site.py` with a pinned `--now` produces the full Backlog tab. Broken cases shown blocked: a PR in the fixture must not appear in the counts; an issue with no labels must normalize to `priority: none` / `risk: unlabeled` / `status: open`; a two-`priority:*` issue must take the higher one; a title containing `<script>` must render escaped with no raw tag in `site/backlog.html`; a missing `site-data/backlog.json` must keep the "not available yet" placeholder; an empty list `[]` must render the full tab with zero counts, not the placeholder; two renders with the same pinned `--now` must be byte-identical. Any of these failing flips the corresponding check to FAIL and the final line reports 0 failed otherwise, so the harness cannot report a green run if a broken case slips through.

## Security and liability review (`liability-gates.md`)

No secrets, keys, tokens or environment values are read or printed. The live `gh issue list` call (which would use `GITHUB_TOKEN`) lives only in the non-`--from-json` branch and is never executed by `/oc` agents or the verification harness, which runs in an empty environment; the fixture path needs no token. All rendered titles and text pass through `html.escape` so no injected HTML or script reaches the page. The normalized `site-data/backlog.json` is gitignored and never committed. No protected spend/security script, workflow, or owner-only file is touched; no dependency is added or re-pinned; `.github/` is not edited. The repo is public and the factory-site workflow from #206 is already on main, so after merge the next site deploy will publish issue titles on the public Pages Backlog tab. That is intentional: Michael decided on 2026-11-11 "Backlog: always show titles". Titles and other rendered text are still HTML-escaped.

## Milestones / split plan (when near the cap)

Not required — simple/normal and expected to fit comfortably in one PR well under the cap. If the total changed lines approach ~300, the natural split is to land `scripts/factory-backlog.py` + `tests/site/fixtures/issues.json` + the build-stage line first, then the `factory-site.py` tab renderer + `test-factory-backlog.sh` + `factory/site/README.md` second, but no split is planned.
