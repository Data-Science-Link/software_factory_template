# Factory JSON schemas

Authoritative machine-readable definitions live beside this file. Human-oriented run-record storage notes: [factory/runs/README.md](../../factory/runs/README.md).

## Run record (`run-record.schema.json`)

Each agent harness run produces one JSON object validated by [`run-record.schema.json`](./run-record.schema.json). The record is schema version **1** (`schema_version` must be `1`). Top-level **`additionalProperties` is false** — unknown keys are rejected.

Golden examples (repo-agnostic): [`examples/sample-runs/`](../../examples/sample-runs/) — `gha-100001-1.json` (`work_type: code`), `gha-100002-1.json` (`work_type: review`), `gha-100003-1.json` (fix/build coding run). Fixture copies for offline tests: `tests/run-records/pass-*.json`.

### Required fields

Every record must include all of the following (optional extension **`steps[]`** is documented below):

| Field | Type | Notes |
|---|---|---|
| `schema_version` | int | Must be `1` |
| `run_id` | string | Pattern `gha-<github.run_id>-<run_attempt>` (example `gha-100001-1`) |
| `repo` | string | `owner/name` |
| `issue` | int | Primary issue (≥ 1) |
| `issues` | int[] | All issues covered (min length 1; each ≥ 1) |
| `pr` | int \| null | GitHub PR number, or `null` if none |
| `spec_path` | string | Path to spec at run time (e.g. `factory/specs/issue-101.md`) |
| `spec_link` | string | URI to spec comment or file |
| `trigger` | enum | `issue_comment` \| `workflow_dispatch` |
| `triggered_by` | string | Account that started the run |
| `trigger_url` | string | URI (issue comment or dispatch) |
| `workflow_run_url` | string | Actions run URI |
| `harness` | string | Harness identifier |
| `harness_version` | string | Pinned harness ref or version |
| `provider` | string | Model API provider |
| `model` | string | Exact model ID used for the run total |
| `escalated_from` | string \| null | Previous model if escalated |
| `complexity` | enum | `simple` \| `standard` \| `complex` |
| `risk` | enum | `trivial` \| `normal` \| `high` |
| `work_type` | enum | `code` \| `docs` \| `spec` \| `review` \| `data` |
| `price_table_version` | string | Version string copied from the committed price table |
| `price_in_per_mtok` | number | USD per million input tokens (≥ 0) |
| `price_cached_per_mtok` | number | USD per million cached input tokens (≥ 0) |
| `price_out_per_mtok` | number | USD per million output tokens (≥ 0) |
| `requests` | int | Model API calls for the run total (≥ 0) |
| `tokens_in` | int | Prompt tokens, including cached (≥ 0) |
| `tokens_cached` | int | Subset of `tokens_in` billed at cached price (≥ 0) |
| `tokens_out` | int | Completion tokens, including reasoning (≥ 0) |
| `tokens_reasoning` | int | Subset of `tokens_out` (≥ 0) |
| `predicted_cost_usd` | number | From the spec (≥ 0) |
| `actual_cost_usd` | number | Primary run cost (≥ 0) |
| `cost_method` | enum | See [Cost method](#cost-method) |
| `key_spend_delta_usd` | number \| null | Key spend after − before when readable (≥ 0 if set) |
| `cost_check` | enum | See [Cost check](#cost-check) |
| `budget_cap_usd` | number | Per-issue cap (≥ 0) |
| `issue_spend_to_date_usd` | number | Cumulative issue spend including this run (≥ 0) |
| `started_at` | string | UTC ISO 8601 timestamp ending in `Z` |
| `ended_at` | string | UTC ISO 8601 timestamp ending in `Z` |
| `duration_s` | int | Wall-clock seconds (≥ 0) |
| `actions_minutes` | int | Billable Actions minutes, rounded up (≥ 0) |
| `runner` | string | Runner label |
| `base_sha` | string | 40-char lowercase hex git SHA |
| `head_sha` | string | 40-char lowercase hex git SHA |
| `outcome` | enum | See [Outcome](#outcome) |
| `gate` | object | Required gate map; see [Gate object](#gate-object) |
| `gate_passed` | bool | Whether required gates passed |
| `notes` | string | Free text; no secrets |

### Enumerations

#### work_type

What the run did (financials and routing use this); field name **`work_type`**:

| Value | Typical use |
|---|---|
| `code` | Build / fix implementation work |
| `docs` | Documentation-only changes |
| `spec` | Spec authoring (`/oc spec`) |
| `review` | Independent reviewer pass ([#41](https://github.com/Data-Science-Link/software_factory_template/issues/41)) |
| `data` | Data / analytics pipelines |

#### Outcome

How the run ended; field name **`outcome`**:

`pr_opened` \| `pr_updated` \| `no_changes` \| `failed` \| `cap_exceeded` \| `gate_failed` \| `cancelled`

#### Cost method

How `actual_cost_usd` was determined; field name **`cost_method`**:

`provider_reported` \| `usage_x_price_table` \| `key_spend_delta` \| `not_measured`

When `cost_method` is `usage_x_price_table`, `scripts/factory-validate-run.py` recomputes cost from run-level tokens × run-level `price_*_per_mtok` (tolerance `$0.0001`).

#### Cost check

Key-spend cross-check result; field name **`cost_check`** (there is no separate `error_class` field on the record):

`match` \| `mismatch` \| `skipped_concurrent` \| `skipped_unavailable`

#### Gate object

Each gate key is required; values are `pass` \| `fail` \| `skip`:

`gitleaks`, `run_record_valid`, `cost_recorded`, `pr_template`, `pr_check`, `budget_cap`, `no_workflow_changes`, `spec_present`

### Token and price rules (validator)

Beyond JSON Schema, `scripts/factory-validate-run.py` enforces:

- `tokens_cached` ≤ `tokens_in`; `tokens_reasoning` ≤ `tokens_out`
- `started_at` and `ended_at` are UTC `...Z`; `ended_at` ≥ `started_at`
- When `cost_method` is `usage_x_price_table`, `actual_cost_usd` matches token math at run-level prices
- File name `factory/runs/<run_id>.json` must match the `run_id` field when validating on-disk records

Negative token counts or costs fail schema validation (`minimum: 0`).

### Extensions beyond vision §8

These were added so later issues (#30 cost capture, #41 independent reviewer) do not need a breaking schema change. Vision §8 will be updated to match when those issues land.

| Extension | Why | Validator behavior |
|---|---|---|
| `cost_method`: `provider_reported` | Provider may expose per-request cost in session data (#30) | Same enum as other methods; cost recompute applies only when method is `usage_x_price_table` |
| Optional `steps[]` | Separate harness vs **review** token/cost lines on one run (#41) | Each step includes its own `price_*_per_mtok` for its `model`; step cost is checked against **step** prices, not the run-level prices |

#### Optional `steps[]` items

Each element is a `run_step` object (`additionalProperties: false`). Required fields:

| Field | Type | Notes |
|---|---|---|
| `step_kind` | enum | `harness` \| `review` |
| `model` | string | Model ID for this step |
| `price_in_per_mtok`, `price_cached_per_mtok`, `price_out_per_mtok` | number | Step-specific prices (≥ 0) |
| `requests` | int | ≥ 0 |
| `tokens_in`, `tokens_cached`, `tokens_out`, `tokens_reasoning` | int | ≥ 0; same subset rules as the run |
| `predicted_cost_usd`, `actual_cost_usd` | number | ≥ 0 |
| `cost_method` | enum | Same as run-level `cost_method` |

Example with two steps: `tests/run-records/pass-with-steps.json`.

### Validation and collection

- **Validate:** `python3 scripts/factory-validate-run.py path/to/record.json` (or an issue comment `.md` containing a fenced `json` block). Offline suite: `bash scripts/test-run-records.sh`.
- **Collect from issue comments:** `python3 scripts/factory-collect-runs.py --from-json …` (offline: `bash scripts/test-factory-collect-runs.sh`). Live mode uses `gh api` and requires `GITHUB_TOKEN`.

Authoritative types and patterns: [run-record.schema.json](./run-record.schema.json).