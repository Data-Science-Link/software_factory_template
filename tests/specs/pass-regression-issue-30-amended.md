<!-- factory-spec v1 -->
---
spec_version: 1
issue: 30
title: 'Run end: deterministic cost capture (usage × price table) into the run record and PR'
status: approved
complexity: complex
complexity_reason: new end-of-run script plus a Python usage parser, cross-check of key spend, PR-body substitution, and a full fixture-driven test suite over several scripts
risk: high
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
approved_at: '2026-11-06T15:32:49-06:00'
drafted_by: oc-spec-run
---

## Outcome

`scripts/factory-run-end.sh` (plus a thin Python helper `scripts/factory-usage.py`) deterministically captures a completed run's token usage from OpenCode session storage, converts it to `actual_cost_usd` using `.factory/models.yaml` prices, cross-checks it against the Actions-only DeepInfra key spend, writes a schema-valid `factory/runs/<run_id>.json`, and rewrites only the `factory-run` block and `Cost:` line of the PR body — all without the model generating any of those numbers.

## Context

- Part of epic #38, vision §8 and §11, order 9 of 16. Michael (2026-11-02): "Cost should be logged per agent spin up run on GitHub Actions deterministically."
- Decisions applied: #1 the record is committed in the run's PR and a copy goes on the issue (posted by #31); #4 the key-spend cross-check reads the Actions-only DeepInfra key, so `skipped_concurrent` means another Actions run overlapped, never local use.
- Today `scripts/factory-cost.sh` uses only key-spend difference; in Actions, usage × price table is the primary method.
- Start state on `main` (`scripts/factory-run-start.py` from #91/#92) writes `$OC_ARTIFACT_DIR/run-start.json` with keys `model`, `model_id`, `routed_rule`, `route_reason`, `retry_of`, `predicted_cost_usd`, `prior_spend_usd`, `cap_usd`, `run_id` (`gha-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}`). It does **not** write `started_at` or `base_sha`, so the end script must take/compute `ended_at`, `duration_s`, `head_sha`, `actions_minutes` (and `started_at`/`base_sha`) from environment/git/workflow without editing `factory-run-start.*`.
- The run record schema (`factory-validate-run.py` reads `.factory/schemas/run-record.schema.json`) already defines every field this script writes, including `cost_method` enum `provider_reported | usage_x_price_table | key_spend_delta | not_measured`, `cost_check` enum `match | mismatch | skipped_concurrent | skipped_unavailable`, and inputs `requests`, `tokens_in`, `tokens_cached`, `tokens_out`, `tokens_reasoning`. The validator recomputes cost from tokens × prices when `cost_method` is `usage_x_price_table`, so the script's multiplication must match exactly (formula at `scripts/factory-validate-run.py:60`).
- Owner comment (2026-11-02) additions: (1) prefer a per-request provider-reported cost if DeepInfra responses expose one (e.g. `usage.estimated_cost`) that OpenCode keeps in session data — sum it as `cost_method: provider_reported` (primary) with usage × price table as the cross-check; if not present, usage × price table stays primary. (2) Add a daily/weekly reconciliation (sum of run records vs total key spend for the period) because the per-run key-spend difference is skipped when runs overlap. (3) Fix the empty "Token usage" section seen in spike PR #45 (`opencode stats` printed nothing) — capture must not rely on that path.

## Scope

Create only **new** files; never edit any existing `scripts/*` (blocked by the path policy, which discards the whole run):

1. `scripts/factory-usage.py` — parses OpenCode session usage. Reads the usage source the #22 spike found (session export/storage), summing across **every** session of the run: `tokens_in`, `tokens_cached`, `tokens_out`, `tokens_reasoning`, `requests`, and (if present) a per-request provider-reported cost. Never reads env vars for the numbers; takes the source as an explicit path/`--usage-dir` argument (plus a `$OPENCODE_USAGE_FIXTURE`-style env override for tests, patterned after the existing `OPENCODE_STATS_FIXTURE`). Emits one JSON object to stdout with sorted keys. Returns non-zero and prints nothing usable if usage is absent.
2. `scripts/factory-run-end.sh` — `set -euo pipefail`; orchestration in shell (never the model computes cost). It:
   - Reads the start state from `$OC_ARTIFACT_DIR/run-start.json` for `run_id`, `model`, `predicted_cost_usd`, `prior_spend_usd`, `cap_usd`.
   - Captures `ended_at` (now, UTC, ISO-8601 ending in `Z`), `duration_s`, `head_sha` (from git), `actions_minutes` (ceil of job minutes), and `started_at`/`base_sha` from environment/`git` as the workflow exposes them.
   - Uses `factory-usage.py` to obtain tokens (and provider cost if available).
   - Computes `actual_cost_usd` from `.factory/models.yaml` prices for the routed model, copying `price_table_version`, `price_in_per_mtok`, `price_cached_per_mtok`, `price_out_per_mtok` into the record; sets `cost_method`.
   - Cross-checks via the existing key-spend helper on the Actions-only DeepInfra key (call the existing `scripts/deepinfra-cost.sh`; do not edit it): `key_spend_delta_usd` and `cost_check` (`match` when within 10% or $0.005, `mismatch`, `skipped_concurrent` when another factory run overlapped, `skipped_unavailable`).
   - On missing usage: `cost_method: key_spend_delta` if key-spend is available, else `not_measured`.
   - Writes `factory/runs/<run_id>.json` (schema-valid, sorted keys) and validates it by calling `python3 scripts/factory-validate-run.py`. A failed run with no PR still writes the file so #31 can post it.
   - Rewrites only the `factory-run` block and the `Cost:` line of the PR body (PR template v2 from #28) using `gh pr edit` with a body that replaces only text between the markers.
   - Never prints a key, token, or environment value.
3. `scripts/test-run-end.sh` — offline test harness (`set -euo pipefail`, `mktemp -d`, prints `PASS`/`FAIL` per case and a final `Results: <n> passed, <m> failed`, exit 1 on any failure).
4. `tests/run-end/` fixtures — recorded usage fixtures redacted from the spike, including: a two-session run, a cache-heavy run, missing usage, a provider-reported-cost case, and a before/after PR-body fixture.

## Out of scope

- Gate checks and publishing to the issue (#31); the daily/weekly reconciliation feed to the financials page (#34), except computing the period reconciliation is noted under Design as a stub/extension point, not a delivered feature here.
- dbt.
- Any edit to `.github/`, `opencode.json`, `.factory/actions-security.md`, `.factory/models.yaml`, `requirements-factory.txt`, or any existing `scripts/*` (including `factory-cost.sh` and `deepinfra-cost.sh`). Any wiring of `factory-run-end.sh` into a workflow file belongs in the PR body as a fenced YAML block for Michael to add by hand.
- `factory/specs/issue-30.md`: the harness writes it; do not create or edit it.

## Files

- Create: `scripts/factory-usage.py`, `scripts/factory-run-end.sh`, `scripts/test-run-end.sh`, `tests/run-end/*` (usage fixtures, a run-start fixture, a PR-body before/after fixture).
- Read first: `scripts/factory-run-start.py`, `scripts/factory-validate-run.py`, `.factory/schemas/run-record.schema.json`, `.factory/models.yaml`, `scripts/factory-cost.sh`, `scripts/deepinfra-cost.sh`, `scripts/opencode-capture-usage.sh`, `.factory/sketches/github/pull_request_template.md`, `tests/specs/pass-simple.md`, `scripts/test-run-start.sh` (test style).

## Acceptance criteria

- [ ] Fixture runs produce schema-valid records whose `actual_cost_usd` matches a hand calculation shown in the PR.
- [ ] Multi-session fixture sums all sessions (tokens and requests).
- [ ] Missing usage yields `key_spend_delta` if DeepInfra key spend delta is available, else `not_measured` (never a guessed number), and cost never appears fabricated.
- [ ] Only the `factory-run` block (and `Cost:` line) of the PR body changes, shown with a before/after fixture.
- [ ] No key or token printed; `set -euo pipefail` on the shell scripts.
- [ ] A failed run with no PR still produces a valid record file for #31 to post on the issue.
- [ ] A cache-heavy run records `tokens_cached` correctly and its cost reflects cached pricing within validator tolerance.
- [ ] Bad inputs are covered: absent start state, unparseable usage, mismatched `run_id`, and key-spend unavailable each degrade to `not_measured`/`skipped_unavailable` without crashing.

## Verification

```bash
python3 -m pip install -q -r requirements-factory.txt
bash scripts/test-run-end.sh
git diff --name-only HEAD~1 | sort
```

Expected: every `test-run-end.sh` line `PASS` and a final `Results: <n> passed, 0 failed`; the changed-file list contains only `factory/specs/issue-30.md`, `scripts/factory-usage.py`, `scripts/factory-run-end.sh`, `scripts/test-run-end.sh`, and files under `tests/run-end/`.

## Classification

- Complexity: complex — a new coordination script, a parser, cost math that must match the validator formula, PR-body substitution, and a broad fixture matrix across several files.
- Risk: high — spend accounting is a financial correctness surface; a wrong number here misreports money.
- Model: models.yaml rule 1 (high risk or complex → `deepseek-ai/DeepSeek-V4-Pro-0813`). Front-matter `model` is left as the template's default so `factory-predict-cost.py` picks the right one at run; `model_override_reason` is empty.

## Cost forecast

Complex prior: 800K in (560K cached), 50K out on V4 Pro predicts $0.4980; cap $1.00. Fits in one PR (~300 lines plus fixtures).

## Manual steps for Michael

- Workflow wiring: any `.github/workflows/` file that calls `factory-run-end.sh` after the harness goes in the PR body as a fenced YAML block for Michael to add by hand (#31 owns the final wiring).
- The Actions-only DeepInfra key and a `gh` token with `issues/pulls: write` for `gh pr edit` are secrets set in the repo; not stored in any file this PR creates.

## Dependencies

Depends on #22 (usage format), #25 (validator/schema), #26, #28 (PR template v2), #29/#91/#92 (start state). Publishing is #31 and runs after this.

## Worker prompt

Read issue #30 and `.factory/FACTORY.md` first. Then read `scripts/factory-run-start.py`, `scripts/factory-validate-run.py`, `.factory/schemas/run-record.schema.json`, `.factory/models.yaml`, `scripts/factory-cost.sh`, `scripts/deepinfra-cost.sh`, `scripts/opencode-capture-usage.sh`, `.factory/sketches/github/pull_request_template.md` and `scripts/test-run-start.sh`. Create `scripts/factory-usage.py`, `scripts/factory-run-end.sh`, `scripts/test-run-end.sh` and fixtures under `tests/run-end/`, following the Scope exactly: sum every session's tokens and requests, prefer provider-reported cost when present (fall back to usage × price table), compute cost with the same formula as `factory-validate-run.py` so it validates, cross-check key spend on the Actions-only key with the documented thresholds and `skipped_concurrent`/`skipped_unavailable` codes, write `factory/runs/<run_id>.json` (schema-valid, sorted keys) even for a failed/no-PR run, and rewrite only the `factory-run` block and `Cost:` line between the PR markers. Cover every acceptance criterion with a test case, including a deliberately broken/bad-input case shown blocked. Never print a key, token, or environment value; never edit any existing file, `.github/`, `.factory/models.yaml` or `requirements-factory.txt`. Keep the change under about 300 lines plus fixtures. Fill the PR template; tick only what you proved.

## Design / approach

A deterministic, model-free script: shell orchestrates, Python parses usage, the existing validator confirms the record, and the existing `deepinfra-cost.sh` supplies key-spend. Everything is file/env driven so the test harness reproduces real ordering without network or secrets. Cost math reuses the exact formula in `factory-validate-run.py` (`cost_from_usage`) so the written `actual_cost_usd` always validates within tolerance. Usage parsing reads OpenCode session storage (the #22 spike's source), not `opencode stats`, which printed nothing in spike PR #45. Missing usage degrades to `key_spend_delta`, then `not_measured`, never a fabricated number; the gate (#31) then fails, as intended. The daily/weekly reconciliation (owner addition 2) is recorded in the record as an extension field/note in this issue's design scope but the full financials feed is #34; the per-run cross-check remains the delivered correctness check here.

## Alternatives considered

- Use `opencode stats` as the usage source: rejected — it printed nothing in spike PR #45 (owner addition 3).
- Compute cost in the model: rejected — violates "a script, never the model" and is non-deterministic.
- Edit `scripts/factory-cost.sh` in place: rejected and blocked — the path policy discards any edit to an existing script.
- Key-spend difference as primary: rejected — decisions say usage × price table is primary in Actions; key-spend is the cross-check.
- Emit a single even-simpler script with no Python helper: considered but rejected — parsing session JSON is cleaner in Python and keeps the shell shell-only.

## Risks, rollback and revert trigger

- Risk: a wrong price or a mis-summed session misreports spend; a bad `gh pr edit` could clobber the PR body. Mitigated by schema validation, the exact-formula reuse, and a before/after-substitution fixture that asserts only the markers' block changes.
- Rollback: revert the merge commit; the run-record files this script writes are data and are regenerated each run, and no existing script is edited.
- Revert trigger (number-checkable): any run whose `actual_cost_usd` fails `factory-validate-run.py` (cost vs tokens × prices mismatch beyond $0.0001), or whose `cost_check` reports `mismatch` on a non-overlapping run, after merge.

## What changes in production on merge

Nothing at runtime until #31 wires `factory-run-end.sh` into the workflow. On merge the new script, parser, and tests land; the existing `factory-cost.sh` keeps running (unchanged) as before.

## Success metric (baseline, target, how measured)

- Baseline: cost is captured only as a key-spend difference in `factory-cost.sh`; no per-run usage × price table record exists, and `opencode stats` prints nothing in Actions.
- Target: 100% of `/oc` runs produce a schema-valid `factory/runs/<run_id>.json` whose `actual_cost_usd` matches tokens × prices within validator tolerance, once #31 wires it.
- How measured: `bash scripts/test-run-end.sh` now (all cases pass); after #31, every run's log shows `factory-validate-run.py` returning `OK`, and the PR shows the populated `factory-run` block.

## Test plan detail (broken case shown blocked)

`scripts/test-run-end.sh` covers, in real order with a scratch work dir and no network/secrets:
- Valid single-session fixture → record valid; `actual_cost_usd` equals the hand value shown in the PR.
- Two-session fixture → tokens/requests summed across both sessions to the expected totals.
- Cache-heavy fixture → `tokens_cached` carried correctly and pricing reflects cached rate (validator `OK`).
- Missing-usage fixture → `cost_method: key_spend_delta` if DeepInfra key spend delta is available, else `not_measured`; no fabricated cost; record still schema-valid.
- Provider-reported-cost fixture → `cost_method: provider_reported`, usage × price table retained as the cross-check value.
- Broken/blocked case: a deliberately bad input (e.g. `tokens_cached > tokens_in`, or a non-matching `run_id` between preamble and filename, or absent start state) is shown **blocked** — the script exits non-zero and writes no record / prints an error — proving it does not silently emit a bogus record. This mirrors the "test the real sequence, show the broken case blocked" rule.

## Security and liability review (`liability-gates.md`)

- Secrets: the script never prints or stores the DeepInfra key or any token; key read lives in the existing `deepinfra-cost.sh` (read, not printed). Tests run with no key set and assert no env value appears in any output or file.
- No workflow/CI changes by the worker (owner-only). No supply-chain changes (no new pinned dependency; uses only Python stdlib + PyYAML already in `requirements-factory.txt`).
- No public claims or license impact; this is internal factory accounting. Merge stays behind the human gate (high risk).

## Milestones / split plan

Single PR (~300 lines plus fixtures), well under the $1 cap; no split needed. If it grows past ~300 lines, split: (1) `factory-usage.py` + parsing tests, then (2) `factory-run-end.sh` orchestration + record writing + cross-check, then (3) PR-body substitution + its fixture.

