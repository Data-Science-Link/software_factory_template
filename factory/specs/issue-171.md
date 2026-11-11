<!-- factory-spec v1 -->
---
spec_version: 1
issue: 171
title: 'Site generator skeleton + Architecture tab (static HTML from FACTORY.md and models.yaml) + one-command build'
status: approved
complexity: standard
complexity_reason: 'one Python renderer plus a build orchestrator and a test script, with tolerant parsing of two source documents and a tab plug-in contract'
risk: normal
work_type: code
model: deepseek-ai/DeepSeek-V4-Flash-0731
model_override_reason: 
model_reason: 'Default for all other factory worker runs → V4 Flash'
predicted_tokens_in: 1000000
predicted_tokens_cached: 800000
predicted_tokens_out: 50000
predicted_cost_usd: 0.0330
budget_cap_usd: 1.00
price_table_version: '2026-11-02'
approved_by: michael
approved_at: '2026-11-11T12:16:45-06:00'
drafted_by: oc-spec-run
---

## Outcome

One script turns factory files into a static four-tab site in `site/`, with the Architecture tab filled in from `.factory/models.yaml` and `.factory/FACTORY.md`, the other three tabs showing "not available yet", and a one-command build (`bash scripts/factory-site-build.sh --sample`) that writes the four HTML files offline.

## Context

Part of #169 (the factory site). The site generator is the next slice: it must read the factory's own source files and emit a static, phone-readable, no-JS site. `scripts/factory-site-data.py` (#170) already exports the marts the Financials tab will need into the gitignored `site-data/`, and `scripts/factory-collect-runs.py` (#191) collects run records, but the renderer does not exist yet. This issue builds the site skeleton and the Architecture tab; full Financials, Backlog and dbt tabs are the later sub-issues #174, #172 and #173. A site decision already stands: the Backlog tab always shows titles (the full Backlog tab lands in #172). There is no risk:high label on this issue and it is pages/website work, so risk is normal.

## Scope

- Create `scripts/factory-site.py --out site --data site-data [--repo-root .]` that writes `index.html` (Architecture), `financials.html`, `backlog.html` and `dbt.html` with a shared header and tab nav, using stdlib `string.Template` + PyYAML, `html.escape` on all text, no JS, and no external CSS, fonts or images; phone-readable via `factory/site/style.css`.
- Architecture tab generated from `.factory/models.yaml` (the models and prices table, the routing rules in first-match order, and the guard checks) and `.factory/FACTORY.md` (the numbered loop steps, the roles table and the merge-authority table). Tolerant parsing of those two sources is different: if a FACTORY.md heading is missing or renamed, show a "section not found in FACTORY.md" note instead of crashing. A missing `models.yaml` key fails softly (omit or note that item; do not crash) and must not use the "section not found in FACTORY.md" message, which applies only to a renamed or missing FACTORY.md heading.
- A footer with the factory version (`git describe --tags --always`, or "unknown") and the build time in UTC, pinned by `--now` or `SOURCE_DATE_EPOCH` so two runs are byte-identical.
- No hard-coded repo name. `GITHUB_REPOSITORY` appears only in the page title, and only if it is set.
- The tab plug-in contract: each tab reads its own input (`site-data/marts/*.json`, `site-data/backlog.json`, `factory/dbt/target/manifest.json`) and shows a placeholder when the input is missing. Financials, Backlog and dbt tabs stay "not available yet" here. When Backlog data later lands, titles always show (site decision); do not build the full Backlog tab in this issue (that is #172).
- Create `scripts/factory-site-build.sh [--sample]` that runs stages in order: collect runs (`scripts/factory-collect-runs.py`) → seeds (`factory/dbt/runs_to_seeds.py`) → budget vars + `dbt build` → export (`scripts/factory-site-data.py`) → render. With `--sample` it uses the committed fixtures under `tests/site/fixtures/` and `tests/site-data/sample-marts/`, never invokes `scripts/factory-collect-runs.py`, and makes no network calls of any kind; a stage whose script does not exist is skipped with a printed note. Never run a live `dbt build`/`dbt run` in `--sample` or in Verification. (Collect and export already exist on main; do not treat them as missing, but `--sample` still must not call collect.)
- Create `factory/site/README.md`: what the site is, how to build and preview it locally (`python -m http.server -d site`), and how it ships with the factory.

## Out of scope

Do not build the full Financials, Backlog or dbt tabs (those are #174, #172 and #173). Do not implement GitHub Pages publishing, the deploy workflow, or a downloadable artifact (that is #56). Do not edit any existing script (`scripts/factory-collect-runs.py`, `scripts/factory-budget-vars.py`, `scripts/factory-site-data.py`, or any protected script in `bash scripts/opencode-artifact-scan.sh --list-protected`). Do not touch `.github/` (the token lacks workflow scope; workers cannot edit it), `opencode.json`, any `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, `.factory/FACTORY.md`, `factory/budget.yml` (owner-only budgets), or `requirements-factory.txt`. Do not add, remove or re-pin a Python package (PyYAML comes from the pinned `requirements-factory.txt`). Generated output goes in the already-gitignored `/site` and `/site-data/` and is never committed; do not edit `.gitignore` unless you only add lines. Keep the work to one PR of roughly 300 changed lines or less.

## Files

- Create: `scripts/factory-site.py`
- Create: `scripts/factory-site-build.sh`
- Create: `scripts/test-factory-site.sh`
- Create: `factory/site/base.html`
- Create: `factory/site/style.css`
- Create: `factory/site/README.md`
- Create: `tests/site/fixtures/FACTORY.md`
- Create: `tests/site/fixtures/models.yaml`
- Create: `tests/site/fixtures/malicious.md`

## Acceptance criteria

- [ ] `bash scripts/factory-site-build.sh --sample` writes `site/index.html`, `site/financials.html`, `site/backlog.html` and `site/dbt.html` offline, never invokes `scripts/factory-collect-runs.py` or any network, and a second run is byte-identical when the build-time line is pinned (`--now` or `SOURCE_DATE_EPOCH`).
- [ ] The Architecture tab lists every routing rule in `tests/site/fixtures/models.yaml`, in order, with its model.
- [ ] `scripts/test-factory-site.sh` asserts that `site/*.html` has no `<script src=`, no remote CSS, and that `rg -n 'https?://' site/*.html` finds only links to GitHub or dbt docs.
- [ ] The Financials, Backlog and dbt tabs render their placeholder when their data is missing. When Backlog data later lands, titles always show (full tab in #172).
- [ ] A malicious string in an issue title or a markdown cell renders `html.escape`-d (no raw `<script>` or `<img>`).
- [ ] A renamed FACTORY.md heading produces a "section not found in FACTORY.md" note, not a crash. A missing `models.yaml` key fails softly (no crash) and does not emit that FACTORY.md section-not-found message.
- [ ] Screenshots of the Architecture tab are in the PR Evidence section.
- [ ] `bash scripts/test-factory-site.sh` passes, covering rule/model listing, escaping, tolerant parsing of both sources, determinism, the placeholder tabs, and the no-script-src / no-remote-CSS / GitHub-or-dbt-docs-only link check.

## Verification

```bash
bash scripts/test-factory-site.sh
```

Expected:
```
PASS  site renders the four HTML files offline
PASS  architecture lists every routing rule in order with its model
PASS  malicious string is html.escape-d (no raw <script>)
PASS  renamed FACTORY.md heading shows section-not-found note, not a crash
PASS  missing models.yaml key fails softly without a FACTORY.md section-not-found note
PASS  second render is byte-identical with pinned build time
PASS  financials/backlog/dbt tabs show placeholder when data missing
PASS  site HTML has no script src or remote CSS, and only GitHub or dbt-docs http(s) links
Results: 8 passed, 0 failed
```
The final line must report `Results: 8 passed, 0 failed`. The test script must not run a live `dbt build` or `dbt run` (dbt crashes in the `/oc` sandbox on Python 3.14, #148); with `--sample` it feeds `scripts/factory-site.py` and the build script the committed fixtures under `tests/site/fixtures/` and `tests/site-data/sample-marts/`, and `scripts/factory-site-build.sh --sample` must never invoke `scripts/factory-collect-runs.py` or make any network call. The build-time line is pinned (via `--now` or `SOURCE_DATE_EPOCH`) so the determinism check compares two runs byte-for-byte. The link/asset check must inspect the generated `site/*.html` files and fail if it finds `<script src=`, remote CSS, or an `http(s)` link that is not to GitHub or dbt docs. No checked command is piped into `head`, `tail` or `grep -q` without `set -o pipefail`; the harness already enables `pipefail`, so full output is printed.

## Classification

- complexity: standard — one Python renderer (with tolerant parsing of two source documents and a tab plug-in contract) plus a build orchestrator, a style sheet, a README and a test script; more than a single small change but not a large refactor.
- risk: normal — pages/website work, per FACTORY.md merge authority; UI evidence (screenshots) is required, and a human product gate applies. Not high, because it adds no secrets, auth, licenses or workflows and touches no protected or owner-only paths.
- work_type: code.
- Model routing and reason match the front matter; the harness fills the model fields.

## Cost forecast

Tokens in/cached/out and predicted cost are left for `factory-predict-cost.py` to route. This is a moderate build (two new scripts, a test script, a base template, a style sheet, a README and three small fixtures) expected to land around the issue's estimate of $0.06–$0.12 and well under the $1 cap; no split is planned.

## Manual steps for Michael

None. Live `dbt build` in the full (non-`--sample`) build path is not run by the harness (dbt crashes in the `/oc` sandbox on Python 3.14, #148) and is not part of this issue's acceptance; the `--sample` path uses committed fixtures and never invokes `scripts/factory-collect-runs.py` or any network. GitHub Pages publishing and the deploy workflow are #56, not this issue.

## Dependencies

None blocking. Part of #169; the renderer can be built in parallel with the later tab sub-issues #174, #172 and #173. The build script's collect (`scripts/factory-collect-runs.py`, #191) and export (`scripts/factory-site-data.py`, #170) stages already exist on main; do not treat them as missing, but `--sample` must still never invoke collect. `factory/dbt/runs_to_seeds.py` already exists.

## Worker prompt

Read issue #171 and `.factory/FACTORY.md` first. Create `scripts/factory-site.py --out site --data site-data [--repo-root .]` that writes `index.html` (Architecture), `financials.html`, `backlog.html` and `dbt.html` with a shared header and tab nav, using stdlib `string.Template` + PyYAML, `html.escape` on all text, no JS, and no external CSS, fonts or images, and that is phone-readable via `factory/site/style.css`. Generate the Architecture tab from `.factory/models.yaml` (models and prices table, routing rules in first-match order, guard checks) and `.factory/FACTORY.md` (numbered loop steps, roles table, merge-authority table). Tolerant parsing: a missing or renamed FACTORY.md heading shows a "section not found in FACTORY.md" note instead of crashing; a missing `models.yaml` key fails softly (omit or note that item; do not crash) and must not use the "section not found in FACTORY.md" message. Add a footer with the factory version (`git describe --tags --always`, or "unknown") and the build time in UTC, pinned by `--now` or `SOURCE_DATE_EPOCH` so two runs are byte-identical. Do not hard-code a repo name; `GITHUB_REPOSITORY` appears only in the page title and only if it is set. Implement the tab plug-in contract so each tab reads its own input (`site-data/marts/*.json`, `site-data/backlog.json`, `factory/dbt/target/manifest.json`) and shows a placeholder when the input is missing; the Financials, Backlog and dbt tabs stay "not available yet" in this issue. When Backlog data later lands, titles always show (site decision); do not build the full Backlog tab here (that is #172). Create `scripts/factory-site-build.sh [--sample]` that runs stages in order — collect runs (`scripts/factory-collect-runs.py`) → seeds (`factory/dbt/runs_to_seeds.py`) → budget vars + `dbt build` → export (`scripts/factory-site-data.py`) → render — where `--sample` uses the committed fixtures under `tests/site/fixtures/` and `tests/site-data/sample-marts/`, never invokes `scripts/factory-collect-runs.py`, makes no network calls of any kind, never runs a live `dbt build`/`dbt run`, and a stage whose script does not exist is skipped with a printed note (collect and export already exist on main; `--sample` still must not call collect). Create `factory/site/README.md` explaining what the site is, how to build and preview it locally (`python -m http.server -d site`), and how it ships with the factory. Create `scripts/test-factory-site.sh` and the fixtures `tests/site/fixtures/FACTORY.md`, `tests/site/fixtures/models.yaml` and `tests/site/fixtures/malicious.md` (trimmed copies plus a malicious-string cell). The test script must include an explicit assertion that generated `site/*.html` has no `<script src=`, no remote CSS, and only GitHub or dbt-docs `http(s)` links, and its PASS lines must match the Verification expected transcript exactly, ending with `Results: 8 passed, 0 failed`. Handle the bad inputs and edge cases: a `models.yaml` missing a key (fails softly, no FACTORY.md section-not-found message), a renamed FACTORY.md heading (that message, no crash), HTML or `<script>` in an issue title or markdown cell rendered escaped, and an empty `site-data/`. Generated output goes in the gitignored `site/` and `site-data/` and is never committed. Put Architecture-tab screenshots in the PR Evidence section. Fill the PR template; tick only what you proved.

## Design / approach

Keep the renderer as a single pure-Python script with no framework: `scripts/factory-site.py` loads `.factory/models.yaml` with the pinned PyYAML, reads the relevant sections of `.factory/FACTORY.md` with tolerant heading lookup, and fills `factory/site/base.html` (a `string.Template` with a shared header and tab nav) once per tab. Every value that came from user- or file-supplied text is passed through `html.escape`; the models table, routing-rule list and guard checks are rendered in `models.yaml` order. A missing `models.yaml` key is skipped or noted without crashing and without the FACTORY.md section-not-found wording. `factory/site/style.css` is a single in-repo stylesheet so there is no external CSS or image and the layout is phone-readable. `scripts/factory-site-build.sh` is a thin orchestrator that, on a live (non-`--sample`) run, runs the existing collect and export scripts (both on main) and calls the renderer; with `--sample` it never invokes `scripts/factory-collect-runs.py` or any network, substitutes committed fixtures for the live data, and skips live `dbt`, so the whole `--sample` build runs offline. Determinism comes from pinning the build-time string (via `--now` or `SOURCE_DATE_EPOCH`) and a stable sort of rows.

## Alternatives considered

Optional for standard/normal but noted: a JavaScript SPA was rejected because the issue explicitly wants no JS and a static, phone-readable site; a full templating framework (Jinja2) was rejected to avoid a new dependency beyond the pinned `requirements-factory.txt` (PyYAML) — stdlib `string.Template` is enough for the four static tabs; generating the Financials/Backlog/dbt tabs now was rejected because those are their own sub-issues and this one only needs the skeleton plus placeholders (with the standing rule that the Backlog tab will always show titles when #172 lands).

## Risks, rollback and revert trigger

Risk: an unescaped value (an issue title or a markdown cell containing HTML or `<script>`) is injected into the page. Mitigated by `html.escape` on all text and asserted by the malicious-string test. Risk: a renamed FACTORY.md heading crashes the renderer. Mitigated by tolerant parsing that shows a "section not found in FACTORY.md" note, asserted by the rename test. Risk: a missing `models.yaml` key crashes the renderer or is misreported as a FACTORY.md section-not-found. Mitigated by a soft failure that does not use that message, asserted by the missing-key test. Risk: the generated HTML includes `<script src=`, remote CSS, or a non-GitHub / non-dbt-docs `http(s)` link. Mitigated by the link/asset assertion in `scripts/test-factory-site.sh`. Risk: non-deterministic output (build time or dict ordering) breaks the byte-identical second-run check. Mitigated by pinning the build time and sorting rows, asserted by the determinism test. Rollback is a normal code revert of the new files (all under `scripts/`, `factory/site/` and `tests/site/fixtures/`); no existing file is edited. Revert trigger: if the Architecture tab omits a routing rule that exists in `models.yaml`, or an unescaped string renders raw HTML, or two builds with the same pinned time are not byte-identical, revert.

## What changes in production on merge

The repository gains a working static-site generator and a one-command offline build. The site is not yet published (that is #56), so production behavior is unchanged: no workflow, spend, gate or model-routing behavior changes. The generated `site/` and `site-data/` remain gitignored and uncommitted. The new `scripts/factory-site-build.sh` becomes the one command that a future deploy job and the remaining tab sub-issues will build on.

## Success metric (baseline, target, how measured)

Baseline: there is no site generator; no HTML is produced from the factory files. Target: `bash scripts/factory-site-build.sh --sample` writes the four HTML files offline without invoking `scripts/factory-collect-runs.py` or any network, the Architecture tab lists every routing rule in `models.yaml` in order with its model, the other three tabs show their placeholder when data is missing, malicious strings are escaped, a missing `models.yaml` key fails softly without a FACTORY.md section-not-found note, generated HTML has no `<script src=` or remote CSS and only GitHub or dbt-docs `http(s)` links, and a second run is byte-identical with a pinned build time. Measured by `bash scripts/test-factory-site.sh` run by the verification harness, plus the Architecture-tab screenshots in the PR Evidence section.

## Test plan detail (broken case shown blocked)

Happy path: `scripts/factory-site-build.sh --sample` renders the four HTML files without invoking `scripts/factory-collect-runs.py` or any network, and `scripts/factory-site.py` lists every routing rule in `tests/site/fixtures/models.yaml` in order with its model. Broken cases shown blocked: a malicious string (e.g. `<script>alert(1)</script>` in an issue title or a markdown cell) renders as escaped text with no raw tag in `site/*.html`; a `FACTORY.md` with a renamed heading renders a "section not found in FACTORY.md" note rather than crashing; a `models.yaml` with a missing key fails softly (no crash) and does not emit that FACTORY.md section-not-found message; an empty `site-data/` renders the placeholder tabs; generated `site/*.html` has no `<script src=`, no remote CSS, and only GitHub or dbt-docs `http(s)` links. Determinism: two renders with the same pinned build time are byte-identical. The test never runs a live `dbt build`/`dbt run` in the harness; with `--sample` it uses the committed fixtures under `tests/site/fixtures/` and `tests/site-data/sample-marts/`.

## Security and liability review (`liability-gates.md`)

No secrets, keys, tokens or environment values are read or printed; `html.escape` is applied to all text rendered from `models.yaml`, `FACTORY.md` or issue data so no injected HTML or script can reach the page. `GITHUB_REPOSITORY` is used only for the page title and only when set; no repo name is hard-coded. No protected spend/security script, workflow, or owner-only file is touched; no dependency is added or re-pinned; `.github/` is not edited. Generated `site/` and `site-data/` output is gitignored and never committed. The site is not published by this issue, so no public claim or deploy liability is introduced.

## Milestones / split plan (when near the cap)

Not required — standard/normal and expected to fit in one PR well under the cap. If the total changed lines approach ~300, the natural split is to land `scripts/factory-site.py` + `factory/site/base.html` + `factory/site/style.css` + the fixtures and test script first, then `scripts/factory-site-build.sh` + `factory/site/README.md` second, but no split is planned.
