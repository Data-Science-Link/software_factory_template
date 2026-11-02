# Factory run records

One JSON file per agent run: the atom of the factory cost dataset. Every harness run (including failed, cancelled, and over-cap runs) writes exactly one record with the same field names, validated by [`.factory/schemas/run-record.schema.json`](../../.factory/schemas/run-record.schema.json).

## File naming

- Path: `factory/runs/<run_id>.json`
- `run_id` format: `gha-<github.run_id>-<run_attempt>` (example: `gha-11873450021-1`)

The file name must match `run_id` (enforced by `scripts/factory-validate-run.py`).

## Who writes records

Only **`scripts/factory-run-end.sh`** (the run end step on the Actions worker) writes or updates run records. The model never authors this JSON.

## Where records live (decision 1, vision §18)

1. **In the run's PR** — committed on the worker branch as `factory/runs/<run_id>.json` when a PR is opened or updated.
2. **On the issue** — a copy in a fenced `json` block under the HTML marker `<!-- factory-run-record -->`, posted by **`github-actions[bot]`** only. Failed, rejected, or closed runs still count in financials because `scripts/factory-collect-runs.sh` can ingest issue copies when no PR merged.

This directory on `main` holds **only this README** until real runs land; do not commit example records here (fixtures live under `tests/run-records/`).

## Validation

```bash
python3 -m pip install -r requirements-factory.txt
python3 scripts/factory-validate-run.py factory/runs/gha-....json
python3 scripts/factory-validate-run.py path/to/issue-comment.md   # extracts ```json block
bash scripts/test-run-records.sh
```

The validator checks JSON Schema, `run_id` vs file name, token subset rules, UTC `...Z` timestamps, and recomputed cost when `cost_method` is `usage_x_price_table`.

## Field reference

| Field | Type | Notes |
|---|---|---|
| `schema_version` | int | `1` |
| `run_id` | string | `gha-<run_id>-<attempt>`; also the file name |
| `repo` | string | `owner/name` |
| `issue` | int | First issue when a spec covers a group |
| `issues` | int[] | All issues in the spec |
| `pr` | int \| null | GitHub PR number, or null if none |
| `spec_path` | string | e.g. `factory/specs/issue-42.md` |
| `spec_link` | string | URL to spec comment or file at run commit |
| `trigger` | enum | `issue_comment` \| `workflow_dispatch` |
| `triggered_by` | string | Must be the owner account for `/oc` runs |
| `trigger_url` | string | Comment or dispatch URL |
| `workflow_run_url` | string | Actions run URL |
| `harness` | string | e.g. `opencode-github-action` |
| `harness_version` | string | Pinned action ref / CLI version |
| `provider` | string | e.g. `deepinfra` |
| `model` | string | Exact model ID |
| `escalated_from` | string \| null | Previous model if escalated |
| `complexity` | enum | `simple` \| `standard` \| `complex` |
| `risk` | enum | `trivial` \| `normal` \| `high` |
| `work_type` | enum | `code` \| `docs` \| `spec` \| `review` \| `data` |
| `price_table_version` | string | From `.factory/models.yaml` |
| `price_in_per_mtok`, `price_cached_per_mtok`, `price_out_per_mtok` | number | USD per million tokens, copied into the record |
| `requests` | int | Model API calls (run total) |
| `tokens_in` | int | Prompt tokens, including cached |
| `tokens_cached` | int | Subset of `tokens_in` at cached price |
| `tokens_out` | int | Completion tokens, including reasoning |
| `tokens_reasoning` | int | Subset of `tokens_out` |
| `predicted_cost_usd` | number | From the spec |
| `actual_cost_usd` | number | Primary cost for the run total |
| `cost_method` | enum | `provider_reported` \| `usage_x_price_table` \| `key_spend_delta` \| `not_measured` |
| `key_spend_delta_usd` | number \| null | Key spend after − before when readable |
| `cost_check` | enum | `match` \| `mismatch` \| `skipped_concurrent` \| `skipped_unavailable` |
| `budget_cap_usd` | number | Per-issue cap (default $1) |
| `issue_spend_to_date_usd` | number | Sum of all runs for this issue including this one |
| `started_at`, `ended_at` | string | UTC ISO 8601 with `Z` |
| `duration_s` | int | Wall time |
| `actions_minutes` | int | Billable Actions minutes (rounded up) |
| `runner` | string | e.g. `ubuntu-latest` |
| `base_sha`, `head_sha` | string | 40-char git SHAs |
| `outcome` | enum | `pr_opened` \| `pr_updated` \| `no_changes` \| `failed` \| `cap_exceeded` \| `gate_failed` \| `cancelled` |
| `gate` | object | Each of `gitleaks`, `run_record_valid`, `cost_recorded`, `pr_template`, `pr_check`, `budget_cap`, `no_workflow_changes`, `spec_present` → `pass` \| `fail` \| `skip` |
| `gate_passed` | bool | All required gate checks passed |
| `notes` | string | Free text; no secrets |
| `steps` | array (optional) | Per-step costs for harness vs **review** jobs ([#41](https://github.com/Data-Science-Link/software_factory_template/issues/41)); each step has `step_kind` (`harness` \| `review`), model, tokens, and costs |

Authoritative types and enums: [run-record.schema.json](../../.factory/schemas/run-record.schema.json).
