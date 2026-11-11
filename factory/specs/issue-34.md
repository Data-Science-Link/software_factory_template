<!-- factory-spec v1 -->
---
spec_version: 1
issue: 34
title: 'Site data: collect run records from issue comments for the factory site build'
status: approved
complexity: simple
complexity_reason: 'one new collector script plus its fixture and test; no cross-file refactor'
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
approved_at: '2026-11-11T11:32:22-06:00'
drafted_by: oc-spec-run
---

## Outcome

The site build gets every real run record (including failed, rejected and closed runs) collected from the issue comments where the record job posts them, written to `site-data/runs/` by a new read-only collector that never runs inside `/oc` agents.

## Context

Part of the standalone factory site epic (#169). The `factory/runs/` directory on `main` is empty by design: real run records live only as fenced `json` blocks under the HTML marker `<!-- factory-run-record -->` in issue comments posted by `github-actions[bot]` (see `factory/runs/README.md` "Where records live"). Issue #34 builds the collector that turns those comments into per-run JSON files so the site seed step (`factory/dbt/runs_to_seeds.py`) can build `agent_runs.csv`. This is the recommended first build of the epic and depends on nothing.

## Scope

- Create `scripts/factory-collect-runs.py` with the CLI `--out site-data/runs [--from-json FILE] [--repo OWNER/NAME]`:
  - **Live mode** (no `--from-json`): list issue comments repo-wide with `gh api --paginate repos/{repo}/issues/comments`. This runs only in the site deploy job with `GITHUB_TOKEN`, never inside `/oc` agents.
  - **Filter:** keep only comments whose author is `github-actions[bot]` and whose body contains `<!-- factory-run-record -->`; extract the first fenced `json` block that appears after the marker.
  - **Validate and deduplicate:** validate each record by importing `scripts/factory-validate-run.py` (use `load_record` and `validate_record` as `factory/dbt/runs_to_seeds.py` already does; do not edit that script — it is a protected spend/security script). Dedupe by `run_id`, keeping the most recently updated comment.
  - **Write:** one `site-data/runs/<run_id>.json` per valid, deduped record, in stable key order (sort keys).
  - **Report:** print a summary of records found, written, skipped as invalid (with the reason) and duplicates.
- Feed the existing seed step unchanged: `python factory/dbt/runs_to_seeds.py --runs 'site-data/runs/*.json'`. Do not edit `runs_to_seeds.py`; its `--runs` glob already supports this. If a required flag turns out to be genuinely missing, stop and say so in the final message rather than editing it.
- Create a fixture `tests/collect-runs/comments.json` with exactly: a valid bot record; a record posted by a human (ignored); a comment without the marker (ignored); an invalid JSON block (skipped); and a duplicate `run_id` (deduped to the most recently updated comment).
- Create `scripts/test-factory-collect-runs.sh` that runs the collector on the fixture offline (no live `gh`), asserts the written file names and counts, feeds the output to `runs_to_seeds.py`, and diffs a second run for byte-identical output.
- Edit `factory/runs/README.md` with one line noting the site collects records from issue comments via `scripts/factory-collect-runs.py`.

## Out of scope

Do not edit `.gitignore` — issue #170 owns adding `site-data/` there, so these parallel specs do not touch the same file. Do not edit any protected spend/security script, including `scripts/factory-validate-run.py`, `scripts/factory-collect-runs.sh` (the superseded shell name, if present) or any script in `scripts/opencode-artifact-scan.sh --list-protected`. Do not touch `.github/`, `opencode.json`, any `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, or `requirements-factory.txt`. No live `gh` API calls in tests or in `/oc` agents; live mode is only for the site deploy job. Do not add or re-pin a Python dependency. Do not wire the collector into any workflow (workflows are owner-only and that is Manual work). Generated output under `site-data/` is never committed.

## Files

- Create: `scripts/factory-collect-runs.py`
- Create: `scripts/test-factory-collect-runs.sh`
- Create: `tests/collect-runs/comments.json`
- Edit: `factory/runs/README.md`

## Acceptance criteria

- [ ] Running the collector on `tests/collect-runs/comments.json` with `--out <tmp>/runs` writes exactly the valid bot record files and ignores the human-posted record, the no-marker comment, and the invalid JSON block, and dedupes the duplicate `run_id` to the most recently updated comment.
- [ ] Every written `site-data/runs/*.json` file passes `scripts/factory-validate-run.py`, and a second collector run produces byte-identical files.
- [ ] `python factory/dbt/runs_to_seeds.py --runs 'site-data/runs/*.json'` builds `agent_runs.csv` from the output with no errors.
- [ ] Nothing is written outside `site-data/` (the `--out` directory) and no live `gh` call happens during the test.
- [ ] The collector's summary reports records found, written, skipped-as-invalid (with reasons) and duplicates.

## Verification

```bash
bash scripts/test-factory-collect-runs.sh
```

Expected:
```
PASS  collector: valid bot record written
PASS  collector: human-posted record ignored
PASS  collector: no-marker comment ignored
PASS  collector: invalid JSON block skipped
PASS  collector: duplicate run_id deduped to newest comment
PASS  collector: runs_to_seeds builds agent_runs.csv from output
PASS  collector: second run byte-identical
Results: 7 passed, 0 failed
```

## Classification

- complexity: simple — one new collector script, a fixture, and its test; no changes to existing protected scripts.
- risk: normal — it reads issue data for reporting and does not enforce spend; the human product gate applies on merge.
- work_type: code.
- model routing and reasons match the front matter (simple code default → V4 Flash).

## Cost forecast

Tokens in 300k, cached 240k, out 20k; predicted cost about $0.04–$0.08, well under the $1 cap and under the $0.10 split threshold, so no split is needed.

## Manual steps for Michael

None required by this issue itself. Wiring the collector into the site deploy workflow (calling live mode with `GITHUB_TOKEN`, then the seed step) is a later step in the #169 epic and stays owner-only.

## Dependencies

None. This is the recommended first build of the #169 epic.

## Worker prompt

Read issue #34 and `.factory/FACTORY.md` first. Create `scripts/factory-collect-runs.py` exactly per this spec: CLI `--out site-data/runs [--from-json FILE] [--repo OWNER/NAME]`; live mode uses `gh api --paginate repos/{repo}/issues/comments` and must never run inside `/oc` agents; keep only `github-actions[bot]` comments containing `<!-- factory-run-record -->`; extract the first fenced `json` block after the marker; validate each record by importing `scripts/factory-validate-run.py` (never edit it — it is protected); dedupe by `run_id` keeping the most recently updated comment; write `site-data/runs/<run_id>.json` with stable key order; print a summary of found, written, skipped-invalid (with reasons) and duplicates. Do not edit `factory/dbt/runs_to_seeds.py` unless a required flag is genuinely missing, and say so if it is. Create `tests/collect-runs/comments.json` covering a valid bot record, a human-posted record (ignored), a no-marker comment (ignored), an invalid JSON block (skipped) and a duplicate `run_id` (deduped). Create `scripts/test-factory-collect-runs.sh` that runs the collector offline on the fixture, asserts the written file names and counts, feeds the output to `runs_to_seeds.py`, and diffs a second run for byte-identical output; use a fixed `Results: 7 passed, 0 failed` line. Add one line to `factory/runs/README.md` noting the site collects records from issue comments via `scripts/factory-collect-runs.py`. Do not edit `.gitignore` (#170 owns `site-data/`), do not touch any protected script, `.github/`, `opencode.json`, AGENTS.md files, owner-only `.factory/` files, or `requirements-factory.txt`, and wire nothing into workflows. Keep the PR under about 300 changed lines. Fill the PR template; tick only what you proved.

## Design / approach

The collector is a single stdlib Python script that reuses the existing validator by importing it exactly as `factory/dbt/runs_to_seeds.py` does (`importlib.util` on `scripts/factory-validate-run.py`), so validation logic stays in one place. Input is either a local JSON fixture (`--from-json`, an array of comment objects) or live `gh api` output in live mode. Each comment is filtered by author and marker, its fenced `json` block is extracted, parsed and validated, then records are grouped by `run_id` and the most recently `updated_at` comment wins. Output files are written with `json.dump(..., sort_keys=True, indent=2)` for stable key order and byte-identical second runs. The script prints only the summary counts, never a key, token or env value. The test script drives the offline path against the fixture into a temp `--out` directory, so the harness never touches the live API.

## Alternatives considered

Optional for simple complexity. The import-reuse of `factory-validate-run.py` (rather than re-implementing validation or shelling out to its CLI) matches the existing `runs_to_seeds.py` pattern and keeps a single source of truth for validation. A shell collector was considered in the earlier rewrite of the issue but was replaced by Python so the collector can import the validator and reuse `json.dump` stable ordering without duplicating logic.

## Risks, rollback and revert trigger

Risk: the collector could pick up a forged record from a non-bot author, mis-parse a comment, or write outside `site-data/`. Mitigations: author + marker filtering, taking only the first fenced block after the marker, validating every record through the protected validator, and writing only inside `--out`. The collector is additive (new files) and read-only against GitHub, so rollback is deleting the new script, fixture and test, and reverting the one-line README edit. Revert trigger: if the fixture or a live run shows a non-bot record being written, a file written outside `--out`, or any validator-failing record reaching `site-data/`, revert and re-check the filters.

## What changes in production on merge

Merging adds a new collector script, its fixture and its test, and one documentation line. Production behavior does not change until the site deploy workflow (a later #169 step, owner-only) calls the collector in live mode; once wired, the site build gains every real run record, including failed, rejected and closed runs, from issue comments.

## Success metric (baseline, target, how measured)

Baseline: the site build sees no run records (empty `factory/runs/` by design). Target: the collector, given the full issue-comment set, writes one valid, deduped record per real bot-posted run (including failed/rejected/closed) and zero non-bot or invalid records, and every written file passes `scripts/factory-validate-run.py`. Measured by the offline fixture test (fixed pass count) and by the reported summary counts in a live dry run.

## Test plan detail (broken case shown blocked)

Optional for simple complexity but included. Happy path: the fixture's valid bot record is written; `runs_to_seeds.py` builds `agent_runs.csv` from the output with no errors; a second collector run is byte-identical. Broken cases shown blocked: the human-posted record is ignored (not written), the no-marker comment is ignored, and the invalid JSON block is skipped with a reason in the summary — each asserted as absent from the output directory and reflected in the summary counts, so the test fails if any of them leaks through.

## Security and liability review (`liability-gates.md`)

Optional for simple complexity but included. The collector reads only GitHub issue-comment data and validates through the protected validator; it never prints a key, token or env value, and live mode only runs in the site deploy job with `GITHUB_TOKEN`, never inside `/oc` agents. It does not enforce spend or change any owner-only file, and introduces no new dependency. All generated output stays under the gitignored `site-data/` and is never committed.

## Milestones / split plan (when near the cap)

Not required — a single simple change well under the cap.
