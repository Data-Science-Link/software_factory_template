# Factory vision: a standardized cloud factory (GitHub Actions + DeepInfra + Factory Manager)

- **Status:** Accepted design for template release `v0.1.0` on `main` (2026-11); child issues of epic **#38** continue to refine details. Decisions live in [§18](#18-decisions-2026-11-02) and `.factory/DECISIONS.md`.
- **Audience:** repo owner and Factory Manager. **Lives at:** `.factory/VISION.md` (method docs live in `.factory/`).
- **Epic:** #38 — standardized Actions + DeepInfra factory (replaces desktop-only default).
- **Replaces as the default path:** the Local open-weights harness (desktop editor + DeepInfra) described in `MODEL_ROUTING.md` and `skills/local-open-weights-run.md`. See [What's retired](#15-whats-retired-and-whats-kept).

> Words used here match the rest of `.factory/`. **Complexity** is `simple | standard | complex` (it picks the model). **Risk class** is `trivial | normal | high` (it sets the merge gate). When the owner says "medium or high complexity" that means **standard or complex**; "medium or high risk" means **normal or high**.

---

## 1. North star

> "If code truly is a commodity I want to track the tokens, cost, predicted cost, and have a standard simple dashboard to track my commodity spend on the project and future spend. I want to show efficient capital allocation and make calculated development decisions." (the owner, 2026-11-01)

The factory buys code the way a plant buys a commodity input: from a cheap, interchangeable supplier (DeepInfra open-weights models), on rented machines (GitHub Actions runners), through one standard process, with every unit metered. The owner sets direction and approves risk. The Factory Manager runs the line. Every run leaves the same paper trail, and every dollar ends up in one dataset and one simple dashboard.

**What success looks like:** the owner picks an issue from their phone, a spec appears, a run happens in GitHub Actions on a cheap DeepInfra model, a PR shows up with the same sections as every other PR plus its exact token count and cost, and the factory site shows forecast vs actual and the monthly run rate, all without the owner touching a laptop or a config file after the one-time setup.

## 2. Principles

1. **Standardize everything that repeats.** Every worked issue gets a spec with the same base sections. Every PR has the same contents. Every agent run writes the same run record. (the owner: "What I want is standardization and every worked on issue to have a spec, the same contents of a PR, the same logged data per agent run.")
2. **The owner chooses the work.** Not every issue becomes agent work, and some are never worked on. Only issues the owner selects (`factory:selected`) get a spec and a run.
3. **Deterministic cost, per run.** Cost is computed from the token usage the harness reports times a price table committed in the repo, not estimated after the fact. Provider spend is a cross-check, not the source.
4. **Cheapest capable model, chosen by rule.** Routing picks the DeepInfra model from complexity, risk and type of work, using `.factory/models.yaml`. Escalate one step at a time, with a reason.
5. **Workers never merge.** Runs open or update a PR and stop. Merge follows the existing risk-class rules (`FACTORY.md` → Merge authority).
6. **The VM can't leave without passing the gate.** Before a runner spins down it must prove it tracked cost from start to finish, wrote the run record, filled the PR template and passed the security checks. A failed check fails the run loudly.
7. **GitHub is the system of record.** Intake, specs, PRs, approvals, run records and financials live in the repo or on its issues and PRs, never only in chat.
8. **Thin workflows, fat scripts.** Workflow YAML stays small and stable because the owner has to paste it by hand (the factory's token can't write `.github/workflows/`). The logic lives in `scripts/`, where agents can change it through normal PRs.
9. **One-time setup, then phone-only.** One setup session (secret, workflow files, a spending limit), then everything starts from a GitHub mobile comment or a message to Factory Manager.
10. **Budgets are hard.** $1 hard cap per issue, most issues under $0.10, on-demand spend never turned on.

## 3. Roles

| Role | Who / what | Does | Never |
|---|---|---|---|
| **CEO** | the owner | Gives the vision. Chooses which issues get worked (`factory:selected`). Approves specs for standard/complex work. Approves PRs for **normal** and **high** risk work. Sets budgets. | Configures things repeatedly; relays notes between bots by hand. |
| **Factory Manager** | Factory Manager (manager subscription plan, about $20/month) | The persistent manager and the owner's single contact for vision and approvals. Persistent memory, routines and active management: triages, writes specs, routes the model, predicts cost, starts runs (`/oc`), reviews PRs (`Factory review` comment), records approvals on the PR, merges within its authority, runs the weekly spend report, watches failed gates. | Decides product questions; merges normal/high without the owner; turns on on-demand spend. |
| **Compute (CPU + VM)** | GitHub Actions runners (`ubuntu-latest`) | Spins up a clean VM per run, hosts the harness (OpenCode GitHub Action), runs the cost capture and the pre-spin-down gate, then disappears. 2,000 free minutes a month on a private repo (GitHub Free). | Holds state between runs; merges. |
| **Inference** | DeepInfra | Serves the models: low-cost tokens, parallel development without buying a GPU, and a wide range of cheap models for low- and high-complexity work. Billed per token. | Sees the repo beyond what the harness sends. |
| **System of record** | The GitHub repo | Project context (`.factory/`, README, docs), work intake (issues), spec tracking (`factory/specs/`), the PR approval workflow (PR template, `pr-check`, risk classes), security guardrails (gitleaks, secret-scan, owner-only triggers), run records and financials (`factory/runs/`, `factory/dbt/`, `factory/financials/`). | — |
| **Worker** | The harness run on Actions (OpenCode + a DeepInfra model) | Does the work in one spec on a branch, fills the PR template, opens the PR. | Merges; edits `.github/workflows/`; reads or prints secrets. |
| **Giver** (optional, unchanged) | See `skills/giver.md` | Asks ledger and healthy challenge. | Builds, merges, spends. |

Hosted cloud agents stay available as a backup harness and are what the owner uses to build this system itself (the epic's children), but they're no longer the default worker for project issues.

## 4. Issue lifecycle

```
intake → selection → spec → risk + complexity + model + predicted cost → (spec approval) → run → gate → PR → review → approval by risk → merge → logging → financials
```

| # | Stage | Who | What happens | Record |
|---|---|---|---|---|
| 1 | **Intake** | Anyone (the owner, Factory Manager, coordinator) | A GitHub issue with a one-sentence outcome. Most issues stop here. | The issue |
| 2 | **Selection** | the owner | the owner adds `factory:selected` (GitHub mobile) or tells Factory Manager "select #N". Only selected issues go further. A group of related issues can share one spec. | Label |
| 3 | **Spec** | Factory Manager | Writes the spec from `.factory/templates/spec.md` (same base sections every time; extended sections for standard/complex). A complex spec may instead be drafted by an `/oc spec` run on V4 Pro, logged like any run. The approved spec lives as a spec comment on the issue (`<!-- factory-spec v1 -->`); the run commits it into its PR as `factory/specs/issue-<N>.md`. No separate spec PR. | Spec comment → file in the run's PR |
| 4 | **Classify** | Factory Manager | Complexity (`simple / standard / complex` + reason), risk class (`trivial / normal / high`), model from `.factory/models.yaml`, predicted cost from `scripts/factory-predict-cost.py`. Anything predicted above $1 is split first. | Spec front matter |
| 5 | **Spec approval** | By risk class (the owner, 2026-11-02; DECISIONS.md): Factory Manager approves trivial and normal risk; the owner approves high risk | the owner replies "approve spec" (or edits). | Spec `status: approved` |
| 6 | **Run** | the owner or Factory Manager (on the owner's account) comments `/oc run` on the issue | GitHub Actions spins up a VM, starts the cost clock, runs OpenCode on the routed DeepInfra model with the spec as the prompt, opens a PR. | Workflow run |
| 7 | **Gate** | The VM, before it spins down | Pre-spin-down checklist (section 9): cost tracked, run record written and valid, PR template filled and `pr-check` passing, gitleaks clean, within budget. Fails loudly on any miss. | Gate results in the run record + job summary |
| 8 | **PR** | The worker + the gate | Standard PR contents (section 7), including the machine-filled `factory-run` block. | PR |
| 9 | **Review** | Factory Manager | One `Factory review` comment (`skills/review-local-pr.md`, generalized). Fixes go back as `/oc` comments on the PR. | PR comment |
| 10 | **Approval by risk** | trivial: Factory Manager after green CI and gate · normal / high: the owner | the owner approves from his phone ("approve #P" to Factory Manager, or a GitHub review). Factory Manager records the gate in the PR body first, per DECISIONS. | PR body |
| 11 | **Merge** | Factory Manager, within its authority | Branch updated onto latest `main`, required checks green on the head commit, merge commit. Workers never merge. | Merge commit |
| 12 | **Logging** | Automatic | The run record JSON (`factory/runs/<run_id>.json`) lands with the PR; a copy is posted on the issue so rejected or failed runs still count. | Run record |
| 13 | **Financials** | Scheduled/manual workflow + Factory Manager routine | dbt builds the dataset; the financials page regenerates; Factory Manager posts the weekly spend report. | `factory/financials/` |

**Proposed labels (keep the set small):** `factory:selected` (the owner picked it), `epic` (parent issues), `owner-action` (the owner has a manual step). Spec approval and run state live in the spec status and the run record, not in more labels. A `factory:gate-failed` label is optional if Factory Manager needs a filter.

## 5. The standard spec

Template: `.factory/templates/spec.md`. Every selected issue, or group of issues worked together, gets one. The base is mandatory for every spec, however small; standard/complex work adds the extended sections. The spec replaces today's handoff block (`skills/factory-loop.md`); its front matter carries the same facts in machine-readable form.

### 5.1 Front matter (machine-read by the routing, prediction and gate scripts)

```yaml
---
spec_version: 1
issue: 42                 # or issues: [42, 43] for a group
title: Short title
status: draft             # draft | approved | superseded
complexity: simple        # simple | standard | complex
complexity_reason: one line
risk: trivial             # trivial | normal | high
work_type: code           # code | docs | spec | review | data
model: deepseek-ai/DeepSeek-V4-Flash-0731
model_reason: default for simple code
predicted_tokens_in: 300000
predicted_tokens_cached: 240000
predicted_tokens_out: 20000
predicted_cost_usd: 0.011
budget_cap_usd: 1.00
price_table_version: 2026-11-01
approved_by: null         # "grok-bot" (trivial/normal risk) or "michael" (any; required for high)
approved_at: null         # UTC ISO 8601
---
```

### 5.2 Base sections (every spec)

1. **Outcome** — one sentence: what's true when this is done.
2. **Context** — why, with links to the issue, the owner's words and related files.
3. **Scope** — what changes.
4. **Out of scope** — what the worker must not touch.
5. **Files** — to create, change or read first.
6. **Acceptance criteria** — checkboxes the worker ticks only when the diff or command output proves them.
7. **Verification** — the exact commands to run and the evidence to paste in the PR.
8. **Classification** — complexity + reason, risk class + reason, model + reason (copied from the front matter in words).
9. **Cost forecast** — predicted tokens in / cached / out, predicted cost, the $1 cap, and the split plan if the prediction is above $0.10.
10. **Manual steps for the owner** — a workflow file, a secret, a setting, or "none".
11. **Dependencies** — issues or PRs that must land first.
12. **Worker prompt** — the self-contained instructions the run passes to the harness (starts with "Read issue #N and `.factory/FACTORY.md` first", ends with "Fill the PR template; tick only what you proved").

### 5.3 Extended sections

| Section | standard or normal risk | complex or high risk |
|---|---|---|
| 13. Design / approach | required | required |
| 14. Alternatives considered | optional | required |
| 15. Risks, rollback and revert trigger | required | required |
| 16. What changes in production on merge | required | required |
| 17. Success metric (baseline, target, how measured) | required | required |
| 18. Test plan detail (broken case shown blocked) | optional | required |
| 19. Security and liability review (`liability-gates.md`) | optional | required |
| 20. Milestones / split plan (when near the cap) | optional | required |

The gate script checks that every base section heading exists and, for standard/complex, that the required extended headings exist. Empty sections must say "N/A — reason".

## 6. Where things live

| Path | What | Copied into project repos? |
|---|---|---|
| `.factory/` | The method: playbook, decisions, routing, skills, templates, schema, price table | Yes, as-is |
| `.factory/VISION.md` | This document | Yes |
| `.factory/templates/spec.md` | Spec template (base + extended) | Yes |
| `.factory/schemas/run-record.schema.json` | Run record JSON Schema | Yes |
| `.factory/models.yaml` | DeepInfra price table, token priors per complexity, routing rules | Yes |
| `factory/specs/issue-<N>.md` | Specs actually worked | Starts empty |
| `factory/runs/<run_id>.json` | One run record per agent run | Starts empty |
| `factory/dbt/` | dbt-duckdb project (seeds, staging, marts, tests) | Yes (code), empty seeds |
| `factory/site/` (generated) | Static four-tab factory site (financials, backlog, decisions, health) | Generated |
| `scripts/` | All logic: routing, prediction, run start/end, gate, seeds, site build, `pr-check.sh` | Yes |
| `.github/pull_request_template.md` | PR template v2 (also kept as `.factory/sketches/github/pull_request_template.md`) | Yes |
| `.github/workflows/` callers + `docs/reusable-workflows/reusable-*.yml` | Thin caller workflows in each repo pin a template tag; reusable bodies live in the template (#156) | Owner paste |
| `opencode.json` | OpenCode config with the DeepInfra provider (no key in it) | Yes |

Rule of thumb: `.factory/` is how the factory works; `factory/` is what this repo's factory has done.

## 7. The standard PR

Every factory PR uses `.github/pull_request_template.md` v2. The worker copies it, fills the human sections, and the run's end step fills the machine block. The existing sections stay (Factory loop steps 1–8, risk class, safety checklist, Evidence) so `pr-check.sh` and reviewers keep working.

| Section | Filled by | Notes |
|---|---|---|
| Summary + `Closes #N` (or `Refs #N` for epics, ledgers and trackers) | Worker | Existing rule |
| Spec link (`factory/specs/issue-<N>.md`) | Worker | New |
| Success metric from the original ask | Worker | normal/high |
| What changes in production on merge | Worker | normal/high |
| Factory loop (1–8) | Worker, then Factory Manager for step 7 | Existing |
| Risk class | Worker (from the spec) | Existing |
| AI disclosure: `AI disclosure: harness opencode-actions; model <id>` | Worker | Existing `pr-check` rule |
| **Factory run block** (between `<!-- factory-run:start -->` and `<!-- factory-run:end -->`) | `scripts/factory-run-end.sh` (deterministic, never the model) | New: run_id, workflow run link, model, tokens in / cached / out, predicted cost, actual cost, cost method, key-spend cross-check, Actions minutes, gate results, run record path |
| `Cost: $0.0123 on DeepInfra (usage × price table)` | Run end step | Existing `pr-check` rule, now machine-written |
| Safety checklist | Worker | Existing, plus "no change under `.github/workflows/`" |
| Evidence | Worker | Existing |
| Notes for reviewers | Worker | Existing |

`pr-check.sh` gains rules for PRs whose body says `harness opencode-actions` (or carries a factory-run block): run_id present, tokens and both costs present, gate results present, spec link present. Human and older PRs keep passing as today.

## 8. The standard run record

One JSON file per agent run, written by `scripts/factory-run-end.sh`, validated against `.factory/schemas/run-record.schema.json`. Every run writes one, including failed, cancelled and over-cap runs.

| Field | Type | Example | Notes |
|---|---|---|---|
| `schema_version` | int | `1` | |
| `run_id` | string | `gha-11873450021-1` | `gha-<github.run_id>-<run_attempt>`; also the file name |
| `repo` | string | `org/repo` | |
| `issue` | int | `42` | First issue if a group |
| `issues` | int[] | `[42, 43]` | All issues the spec covers |
| `pr` | int \| null | `57` | null when no PR was opened |
| `spec_path` | string | `factory/specs/issue-42.md` | |
| `spec_link` | string | URL of the spec comment or file at the run's commit | |
| `trigger` | string | `issue_comment` | or `workflow_dispatch` |
| `triggered_by` | string | `owner-login` | Must be the owner account |
| `trigger_url` | string | comment URL | |
| `workflow_run_url` | string | Actions run URL | |
| `harness` | string | `opencode-github-action` | |
| `harness_version` | string | pinned action ref / CLI version | |
| `provider` | string | `deepinfra` | |
| `model` | string | `deepseek-ai/DeepSeek-V4-Flash-0731` | Exact ID |
| `escalated_from` | string \| null | previous model if escalated | |
| `complexity` | enum | `simple` | simple / standard / complex |
| `risk` | enum | `trivial` | trivial / normal / high |
| `work_type` | enum | `code` | code / docs / spec / review / data |
| `price_table_version` | string | `2026-11-01` | From `.factory/models.yaml` |
| `price_in_per_mtok`, `price_cached_per_mtok`, `price_out_per_mtok` | number | `0.06`, `0.015`, `0.18` | Copied in so the record stands alone |
| `requests` | int | `37` | Model API calls |
| `tokens_in` | int | `412000` | All prompt tokens, **including** cached |
| `tokens_cached` | int | `350000` | Subset of `tokens_in` billed at the cached price |
| `tokens_out` | int | `18200` | All completion tokens, **including** reasoning |
| `tokens_reasoning` | int | `6100` | Subset of `tokens_out`, for insight |
| `predicted_cost_usd` | number | `0.011` | From the spec |
| `actual_cost_usd` | number | `0.0122` | `(in − cached)×p_in + cached×p_cached + out×p_out`, per million |
| `cost_method` | enum | `usage_x_price_table` | `usage_x_price_table` / `key_spend_delta` / `not_measured` |
| `key_spend_delta_usd` | number \| null | `0.0124` | DeepInfra key spend after − before, when readable |
| `cost_check` | enum | `match` | `match` (within 10% or $0.005) / `mismatch` / `skipped_concurrent` / `skipped_unavailable` |
| `budget_cap_usd` | number | `1.00` | |
| `issue_spend_to_date_usd` | number | `0.0122` | Sum of all runs for this issue including this one |
| `started_at`, `ended_at` | string | `2026-11-02T14:03:11Z` | UTC ISO 8601; started before the harness, ended after it |
| `duration_s` | int | `412` | |
| `actions_minutes` | int | `7` | Billable minutes, rounded up per job |
| `runner` | string | `ubuntu-latest` | |
| `base_sha`, `head_sha` | string | | |
| `outcome` | enum | `pr_opened` | `pr_opened` / `pr_updated` / `no_changes` / `failed` / `cap_exceeded` / `gate_failed` / `cancelled` |
| `gate` | object | `{ "gitleaks": "pass", "run_record_valid": "pass", "cost_recorded": "pass", "pr_template": "pass", "pr_check": "pass", "budget_cap": "pass", "no_workflow_changes": "pass", "spec_present": "pass" }` | Each `pass` / `fail` / `skip` |
| `gate_passed` | bool | `true` | All required checks pass |
| `notes` | string | | Free text, no secrets |

## 9. The pre-spin-down gate

`scripts/factory-run-finish.sh` runs as the last steps of the run job with `if: always()`, so it runs even when the harness fails. It writes its results into the run record and the job summary, posts a short comment on the issue, and exits non-zero on any failed check, which turns the run red. The VM asks itself, in order:

1. **Did I track cost from start to finish?** A start timestamp was taken before the harness started; usage was read after the harness ended; usage covers every session the harness ran; tokens are non-zero if any model call happened.
2. **Did I put the cost into a log?** `factory/runs/<run_id>.json` exists, validates against the schema, and is committed to the PR branch (or, with no PR, posted on the issue). A copy is in the job summary and uploaded as an artifact.
3. **Did I go through the checklist and use the PR template?** The PR body was built from `.github/pull_request_template.md`; the base sections are present; the factory-run block and `Cost:` line are filled; `scripts/pr-check.sh` passes on the final body.
4. **Did I pass the security checks?** gitleaks finds nothing on the branch; the diff touches nothing under `.github/workflows/`; no secret-looking string in the PR body or comments; the spec was present and approved (or simple + trivial).
5. **Am I inside the budget?** This run and the issue's total are at or under $1. Warn (don't fail) above $0.10 or above 2× the prediction, so the forecast gets better.
6. **Did I stay PR-only?** No merge, no push to `main`.

A run whose gate fails still has its cost logged; the failure is a finding for Factory Manager to triage, and the PR is not reviewable until a rerun passes.

**GitHub limitation to design around:** PRs and pushes made with the default `GITHUB_TOKEN` don't trigger other workflows, so `pr-check.yml` and `secret-scan.yml` won't start on a PR the harness opened that way. The gate therefore runs `pr-check.sh` and gitleaks **inside the same job**. They re-run normally whenever the owner (a human) edits the PR body or pushes. **Decided (2026-11-02, §18 decision 3):** runs use the default `GITHUB_TOKEN` with these in-job checks and a `factory-gate` commit status on the head commit. The OpenCode GitHub App (OIDC) and a fine-grained token secret are not used.

## 10. Model routing

`.factory/models.yaml` is the single, dated price table and rule set; `MODEL_ROUTING.md` explains it in words. Prices are DeepInfra standard tier, per million tokens, checked 2026-11-01 on deepinfra.com model pages.

| Model (DeepInfra ID) | In | Cached in | Out | Role |
|---|---|---|---|---|
| `deepseek-ai/DeepSeek-V4-Flash-0731` | $0.06 | $0.015 | $0.18 | **Default** for simple and standard work |
| `deepseek-ai/DeepSeek-V4-Pro-0813` | $1.30 | $0.10 | $2.60 | Architect: specs written by a run; one retry after Flash fails |
| `Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo` | $0.30 | $0.10 | $1.00 | Complex/high-risk builds and fixes (#128); fallback if a DeepSeek model fails on tool calls |

**Rules (first match wins; `models.yaml` checks 5, 4, 7, 2, 1, 3 in that order):**

1. `risk: high` or `complexity: complex` → Qwen3-Coder (#128; was V4 Pro, whose ~35 s thinking per tool turn timed out the #30 build).
2. `work_type: spec` (an `/oc spec` run, used only for complex specs) → V4 Pro. By default Factory Manager writes specs on its own plan with no DeepInfra spend (§18 decision 6).
3. Everything else → V4 Flash.
4. One failed attempt on Flash for standard work → rerun once on Pro, recorded as `escalated_from`.
5. Tool-call or reasoning-format errors on a DeepSeek model → Qwen3-Coder, and file an issue.
6. If the predicted cost on the chosen model is above $1, don't run: split the issue.
7. Review uses a different model from the builder (Factory Manager's review on its own plan counts).
8. Standard tier only; no Priority tier (1.5×) unless the owner asks. Flex (0.8×) is a later option for non-urgent runs.

**Token priors** (used for predicted cost; starting guesses, recalibrated monthly from `fct_forecast_vs_actual`):

| Complexity | tokens_in | of which cached | tokens_out | Predicted on Flash | Predicted on Pro |
|---|---|---|---|---|---|
| simple | 300k | 80% | 20k | ≈ $0.011 | ≈ $0.15 |
| standard | 1.0M | 80% | 50k | ≈ $0.033 | ≈ $0.47 |
| complex | 800k | 70% | 50k | ≈ $0.032 | ≈ $0.50 |

(Complex gets a smaller token prior than standard on purpose: complex work must be split into smaller specs to stay under the $1 cap on Pro.)

**Caching:** DeepInfra prefix caching is automatic, so the worker prompt puts the stable parts first (spec, rules) and nothing time-stamped up front; no model switches mid-run.

## 11. The cost pipeline

```
harness usage  ─┐
price table   ──┼─► scripts/factory-run-end.sh ─► factory/runs/<run_id>.json ─► (PR + issue comment copy)
key spend (opt)─┘                                         │
                                                          ▼
        factory/dbt/runs_to_seeds.py (+ scripts/factory-collect-runs.py) ─► factory/dbt/seeds/*.csv
                                                          ▼
                       dbt-duckdb (no warehouse; a local .duckdb file, gitignored)
                                                          ▼
           staging: stg_agent_runs, stg_run_gates, stg_model_prices, stg_fixed_costs, stg_budget
                                                          ▼
   marts: fct_agent_runs, agg_spend_daily, agg_spend_by_issue, agg_spend_by_model,
          fct_forecast_vs_actual, rpt_run_rate
                                                          ▼
      scripts/factory-site-data.py + scripts/factory-site.py ─► factory/site/ (static HTML)
```

- **Capture (deterministic).** OpenCode records token usage per message in its session data; the run end step reads it (exact source, such as `opencode export` or `opencode stats`, is confirmed by the spike) and multiplies by the price table. When the DeepInfra key's spend can be read before and after (`scripts/deepinfra-cost.sh`, `GET /payment/key-limits`), it's recorded as a cross-check; when other runs overlapped on the same key, the check is `skipped_concurrent`.
- **Every dollar counts.** Records are committed in the PR **and** posted as an issue comment (marker `<!-- factory-run-record -->`, trusted only from `github-actions[bot]`). `scripts/factory-collect-runs.py` pulls comment copies for runs with no merged PR (failed, rejected, closed), so spend on abandoned work still lands in the dataset.
- **Seeds.** `factory/dbt/runs_to_seeds.py` flattens `factory/runs/*.json` into `agent_runs.csv`; `scripts/factory-collect-runs.py` ingests issue-comment copies when no PR merged. `model_prices.csv` comes from `models.yaml`. Hand-kept seeds: `fixed_costs.csv` (manager subscription and other fixed costs) and `budget.csv` (monthly DeepInfra budget and forecast).
- **dbt-duckdb.** `factory/dbt/` with an in-repo `profiles.yml` pointing at a local DuckDB file. No warehouse, no credentials. `dbt build` runs seeds, models and tests in CI or on any laptop.
- **Staging** cleans and types: dedupe on `run_id`, UTC timestamps, recompute cost from tokens × price as a test, normalize model IDs.
- **Marts:** `fct_agent_runs` (one row per run, with cost variance and cost per merged PR); `agg_spend_daily`, `agg_spend_by_issue`, `agg_spend_by_model`; `fct_forecast_vs_actual` (per issue and per complexity: predicted, actual, error %); `rpt_run_rate` (trailing 7- and 30-day spend, month-to-date, projected month-end, Actions minutes used vs 2,000, fixed + variable total).
- **Tests:** unique and not-null `run_id`; accepted values for enums; `actual_cost_usd ≥ 0`; recomputed cost matches; per-issue spend ≤ $1 (fails); prediction error flagged (warns).

## 12. Factory financials (site)

Ship a **static factory site** under `factory/site/` (four tabs: financials, backlog, decisions, health), built by `scripts/factory-site-data.py` and `scripts/factory-site.py`. Host via GitHub Pages or open the files locally; see `docs/reusable-workflows/reusable-factory-site.yml`.

Contents (Financials tab):

1. **Headline:** month-to-date variable spend (DeepInfra), fixed spend (subscriptions), total; projected month-end; budget and % used; Actions minutes used / 2,000.
2. **Run rate:** trailing 7- and 30-day spend per day and per merged PR.
3. **Forecast vs actual:** per complexity tier (predicted, actual, error %), and the last 10 issues.
4. **By model:** runs, tokens in / cached / out, cost, cache hit rate, success rate.
5. **By issue:** top 10 by spend, with cap headroom.
6. **Quality of spend:** % of runs that passed the gate first time, % merged, cost of abandoned runs.
7. **Data freshness:** last run included, last refresh time (UTC and Central).

Refresh: the **factory-site** reusable workflow runs weekly at an odd minute and on demand: collect runs, build seeds, `dbt build`, regenerate `factory/site/`, and open a trivial-risk PR that the Factory Manager may merge.

## 13. Security guardrails

Kept from today: gitleaks pre-commit hook (`scripts/install-hooks.sh`), the `secret-scan` workflow, `pr-check`, the pre-push block on `main`, `liability-gates.md`, merge commits only, and `protect-main` ruleset ready for when the repo is on a paid plan or public. On a private GitHub Free repo, branch protection and rulesets aren't enforced, so the merge gate stays with Factory Manager and the owner.

New for Actions runs:

- **Owner-only trigger.** The run job's `if:` requires the comment author's login to match the configured owner account and `author_association == 'OWNER'`, and the comment must **start with** `/oc` (not merely contain it), so pasted text or bot comments can't start a run.
- **PR-only.** The harness opens or updates a PR and stops. No merge step exists in any workflow.
- **Least privilege.** Job permissions are `contents: write`, `pull-requests: write`, `issues: write` and nothing else. The only secret in the job is `DEEPINFRA_API_KEY`. Workflow files can't be changed by the factory's token, and the gate fails a diff that touches `.github/workflows/`.
- **Key safety.** Actions uses **its own DeepInfra key**, separate from the local factory key (§18 decision 4). It lives only as the `DEEPINFRA_API_KEY` Actions repo secret (never in a file, issue, PR or log) and has its own **$10/month** DeepInfra spending limit as the hard backstop (§18 decision 5). `opencode.json` sets tool permissions to deny commands that print the environment or call the network directly (`env`, `printenv`, `curl`, `wget`) where OpenCode allows it.
- **Prompt injection.** Issue and PR text is untrusted input for the model. The worker prompt says so, the scope comes from the approved spec, and the gate checks the diff, not the model's claims.
- **Concurrency.** One run per issue at a time (`concurrency: factory-issue-<N>`); at most 4 runs at once across the repo (existing agent cap).
- **Timeouts and caps.** `timeout-minutes` on the job (about 20 minutes by default) protects the 2,000-minute monthly allowance; the gate fails any run over the $1 cap; the DeepInfra spending limit stops spend outright.
- **Never** a secret, key or token in a file, issue or PR; never on-demand spend; never merge from a run.

## 14. Phone kickoff

One-time setup by the owner (about 15 minutes, on a laptop once): create a new DeepInfra key used only by Actions and set its spending limit to $10/month; add it as the `DEEPINFRA_API_KEY` Actions secret; paste caller workflows from `docs/reusable-workflows/callers/` (or run `factory-init-repo.py` / `factory-migrate-adopter.py`); allow GitHub Actions to create pull requests (Settings → Actions → General → Workflow permissions). No GitHub App to install: runs use the default `GITHUB_TOKEN`.

After that, from the phone:

1. **Select:** add `factory:selected` in GitHub mobile, or tell Factory Manager "work on #42".
2. **Spec:** Factory Manager posts the spec comment on the issue with model and predicted cost (for a complex spec it may run `/oc spec` on V4 Pro first). For standard/complex or normal/high work, the owner replies "approve spec".
3. **Run:** the owner comments `/oc run` on the issue, or tells Factory Manager "run #42" and it posts the comment from the owner's account.
4. **Review:** Factory Manager posts a `Factory review` and tells the owner: "PR #57 ready, normal risk, cost $0.03 (predicted $0.03). Approve?"
5. **Approve:** "approve #57" to Factory Manager, or a GitHub review. Factory Manager records it in the PR body and merges per the risk rules.
6. **Fix:** "fix the review on #57" makes Factory Manager post `/oc` with the fix list on the PR.
7. **Money:** every Monday Factory Manager sends the spend report from the financials page; the owner can ask "what did the factory cost this month?" any time.

## 15. What's retired and what's kept

| Piece | Status | Replacement |
|---|---|---|
| Local open-weights harness (desktop editor + DeepInfra) — `skills/local-open-weights-run.md`, `skills/local-owner-setup.md` | **Retired as the default**; kept as an optional, documented fallback | Actions runs (`factory-run.yml`) |
| `.cursor/rules/factory.mdc` (`do issue N`) | Kept only for the optional local path | `/oc run` |
| `scripts/factory-cost.sh` (issue-comment start marker, key spend difference) | Retired for Actions | `scripts/factory-run-start.sh` / `factory-run-end.sh` (usage × price table) |
| `scripts/deepinfra-cost.sh` | **Kept** as the key-spend cross-check reader | — |
| Handoff block in `skills/factory-loop.md` | Replaced | The spec (`.factory/templates/spec.md`) |
| Hosted-agent routing table in `MODEL_ROUTING.md` | Kept for Factory Manager and backup hosted cloud agents | DeepInfra table in `.factory/models.yaml` for workers |
| `Cost:` line read from the usage page | Replaced | Machine-written factory-run block |
| `scripts/pr-check.sh`, `tests/pr-check/`, `pr-check.yml`, `secret-scan.yml`, `install-hooks.sh`, `protect-main.sh`, `liability-gates.md`, `review-local-pr.md` | **Kept**, extended where noted | — |
| PR template sketch | Kept and promoted to `.github/pull_request_template.md` v2 | — |

## 16. Budget rules

- **$1 hard cap per issue**, summed over every run for that issue. The run start step refuses when the issue has already spent $1; the gate fails a run that ends over it.
- **Target under $0.10** for most issues; complex work may go higher but never above $1. An issue predicted above $1 is split before any run.
- **On-demand spend is never turned on** (subscriptions or API pools).
- **DeepInfra spending limit:** $10/month to start, on the Actions-only key (decided 2026-11-02). It's the hard backstop; at about $0.10 per issue that's roughly 100 issues a month.
- **Actions minutes:** 2,000 per month on GitHub Free private repos; the financials page and Factory Manager's daily check flag at 80%.
- **Fixed cost:** the manager subscription plan for Factory Manager (about $20/month) is tracked in `fixed_costs.csv` so the dashboard shows the full cost of the factory.

## 17. Risks and unknowns

- **The OpenCode + DeepInfra + Actions combination is untested.** The first child issue is a spike on one trivial issue. **Decided fallback (§18 decision 10):** if the spike fails, switch to the Claude Code Action with `ANTHROPIC_BASE_URL=https://api.deepinfra.com/anthropic`.
- **Where exactly the harness reports token usage** in a CI run (and whether it includes every sub-session) is unknown until the spike.
- **DeepSeek V4 thinking mode and tool calls:** desktop-harness `reasoning_content` bugs may not apply to the Actions harness, but they must be tested.
- **Mid-run cost cap:** the harness may not stop itself at $1 mid-run. Backstops are the job timeout, OpenCode step limits and the DeepInfra spending limit; the gate catches the overrun after.
- **Key-spend cross-check under parallel runs** can't separate runs that share a key; the record says `skipped_concurrent` rather than guess.

## 18. Decisions (2026-11-02)

These were the open questions in the first draft of this vision. the owner accepted every recommended pick: "All recommended" (the owner, 2026-11-02 12:19 AM CT, in chat). Each one has a matching dated entry in `.factory/DECISIONS.md`.

| # | Question | Decision | What it means for the build |
|---|---|---|---|
| 1 | Where run records live | Each run record is committed in the run's PR as `factory/runs/<run_id>.json`, **plus** a copy posted on the issue (`<!-- factory-run-record -->`, trusted only from `github-actions[bot]`). No separate data branch. | Failed, rejected and closed runs still count: `scripts/factory-collect-runs.py` pulls issue copies that aren't in `factory/runs/`. |
| 2 | Dashboard format | A generated markdown page, `factory/financials/README.md`, with Mermaid charts. **Not** GitHub Pages. | Works on a private GitHub Free repo and on GitHub mobile. |
| 3 | GitHub identity for runs | The default `GITHUB_TOKEN`, with `pr-check.sh` and gitleaks run **inside the run job**, plus a `factory-gate` commit status. No OpenCode GitHub App, no extra token. | The harness action runs with `use_github_token: true`; the gate is the in-job check of record. |
| 4 | DeepInfra key for Actions | A **new DeepInfra key used only by Actions**, with its own spending limit. It supersedes the 2026-10-31 single-key decision for Actions runs only; the local key stays as is. | Separates Actions spend and limits the blast radius; the key-spend cross-check reads that key. |
| 5 | Monthly DeepInfra limit | **$10/month** on the Actions key to start. | About 100 typical issues a month at the $0.10 target. |
| 6 | Who writes specs | **Factory Manager writes specs** on its manager subscription plan (no DeepInfra spend). A **complex** spec may use an `/oc spec` run on DeepSeek-V4-Pro-0813, logged like any other run. | Run start accepts `/oc spec` as well as `/oc run`. |
| 7 | Where an approved spec lives | As a **spec comment on the issue** (`<!-- factory-spec v1 -->`); the run commits it into its PR as `factory/specs/issue-<N>.md`. No separate spec PR. | Specs reach `main` with the work they describe. |
| 8 | Financials refresh | **Weekly** (scheduled, odd minute) and **on demand** (`workflow_dispatch`); the workflow opens a trivial-risk refresh PR. | Run PRs don't touch the dashboard, so parallel PRs don't conflict. |
| 9 | Trivial-risk merges | **Keep today's rule:** Factory Manager may merge trivial-risk PRs after green checks and a passing gate. Normal and high still need the owner. | No change to merge authority in `FACTORY.md`. |
| 10 | If the spike fails | Fall back to the **Claude Code Action** on DeepInfra's Anthropic-compatible endpoint (`ANTHROPIC_BASE_URL=https://api.deepinfra.com/anthropic`). | No custom harness. |

## 19. Definition of done (for the epic)

- A real selected issue runs end to end in Actions from a phone comment: spec → `/oc run` → PR.
- The pre-spin-down gate passes, and a deliberately broken case is shown failing.
- The run record is committed and valid, and its cost is logged (usage × price table, cross-checked where possible).
- `dbt build` passes on the real run records.
- The financials page updates with that run, showing forecast vs actual and run rate.
- The README is rewritten around this system; the Local open-weights path is marked retired/optional.
- Every new rule has a `DECISIONS.md` entry naming who decided.

The work is broken into child issues on epic #38, each one PR, ideally under about 300 changed lines.
