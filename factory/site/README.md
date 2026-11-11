# Factory site

A small static four-tab website generated from the factory's own source files:

- **Architecture** (`index.html`) — a newcomer pitch, an inline SVG loop diagram,
  one card per loop step, a "What a human decides" box and depth links to the docs,
  followed by the roles, merge authority, models and prices, routing rules and guard
  checks tables, read from `.factory/FACTORY.md` and `.factory/models.yaml`.
- **Financials** (`financials.html`) — not available yet; lands in issue #174.
- **Backlog** (`backlog.html`) — not available yet; lands in issue #172.
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
full (non-`--sample`) build also runs the collect and export stages in order.

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
