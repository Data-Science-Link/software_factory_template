# Factory site

A small static four-tab website generated from the factory's own source files:

- **Architecture** (`index.html`) — a newcomer pitch, an inline SVG loop diagram,
  one card per loop step, a "What a human decides" box and depth links to the docs,
  followed by the roles, merge authority, models and prices, routing rules and guard
  checks tables, read from `.factory/FACTORY.md` and `.factory/models.yaml`.
- **Financials** (`financials.html`) — a CFO-style view with headline cost cards, budget vs spend charts,
  per-issue economics, model/work-type breakdown, prediction accuracy, and data freshness.
  Reads from `site-data/marts/*.json` (from issue #170) only, offline, with no JS and no
  chart library. Every number is asserted against the fixture values.
- **Backlog** (`backlog.html`) — summary cards, a priority × risk count table, an
  epic list with done/total, and a sorted issue table linking to each issue, always
  showing titles (issue #172). The data comes from `site-data/backlog.json`,
  produced by `scripts/factory-backlog.py`.
- **dbt** (`dbt.html`) — not available yet; lands in issue #173.

The renderer is `scripts/factory-site.py`. It uses only the Python standard library
(`string.Template`) and PyYAML, applies `html.escape` to every text value, and emits
no JavaScript and no external CSS, fonts or images (styling is the single in-repo
`factory/site/style.css`, which is also phone-readable).

## Build

```bash
bash scripts/factory-site-build.sh --sample
```

Writes `site/index.html`, `site/financials.html`, `site/backlog.html` and
`site/dbt.html` into the gitignored `site/` directory, entirely offline, from the
committed fixtures under `tests/site/fixtures/` and `tests/site-data/sample-marts/`.
It never invokes `scripts/factory-collect-runs.py` and makes no network calls. The
full (non-`--sample`) build also runs the collect, export and live backlog stages in
order (the live backlog stage calls `gh issue list` and is only run by the deploy
job, never in the offline sample build).

## Backlog data

`scripts/factory-backlog.py --from-json tests/site/fixtures/issues.json --out site-data/backlog.json`
builds the Backlog data offline from the committed fixture (a GitHub API-shaped
issues list). Live mode runs `gh issue list --state open --limit 500 --json
number,title,labels,createdAt,updatedAt,url,subIssuesSummary`; pull requests are
excluded and labels are normalized into `priority`, `risk` and `status`, with
`title` always included. Epic issues carry `done`/`total` from
`subIssuesSummary` when present.

For a byte-identical second build, pin the build time:

```bash
SOURCE_DATE_EPOCH=$(date +%s) bash scripts/factory-site-build.sh --sample
# or
scripts/factory-site.py --out site --data site-data --now "2026-11-11 12:00:00"
```

## Preview locally

```bash
python -m http.server -d site
```

then open <http://localhost:8000/> in a browser.

## How it ships

The generated `site/` and `site-data/` directories are gitignored and never
committed. Publishing to GitHub Pages is issue #56; until then the build script is
the one command a future deploy job and the remaining tab sub-issues will build on.
