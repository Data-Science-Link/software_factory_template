# Changelog

All notable changes to this template are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The first planned tag is **v0.1.0** (unreleased). No tag is cut until the owner approves; see [docs/RELEASING.md](docs/RELEASING.md) and [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md). Product repos pin reusable workflows at a semver tag once the #156 pilot completes.

### Added

**Reusable workflows and adoption**

- Reference GitHub Actions bodies under [docs/reusable-workflows/](docs/reusable-workflows/README.md) (`reusable-opencode-spec.yml`, `reusable-opencode-run.yml`, `reusable-opencode-fix.yml`, `reusable-pr-check.yml`, `reusable-factory-site.yml`) with thin caller examples in `callers/`.
- [`scripts/factory-reusable-check.py`](scripts/factory-reusable-check.py) validates caller pins, `factory_ref`, and workflow shape offline.
- Repo bootstrap and drift: [`scripts/factory-init-repo.py`](scripts/factory-init-repo.py), [`scripts/factory-migrate-adopter.py`](scripts/factory-migrate-adopter.py), [`scripts/factory-sync-repos.py`](scripts/factory-sync-repos.py).
- [docs/PILOT_RUNBOOK.md](docs/PILOT_RUNBOOK.md) for end-to-end adopter verification before pinning `factory_ref`.

**Standalone factory site (four tabs)**

- [`scripts/factory-site.py`](scripts/factory-site.py): static **Architecture**, **Financials** (pacing, table sort, CSV export), **Backlog** (live text filter), and **dbt** (lineage from `manifest.json`); light/dark theme and print-friendly Architecture UX.
- [`scripts/factory-site-build.sh`](scripts/factory-site-build.sh) live pipeline; [`--offline`](scripts/factory-site-build.sh) / `--sample` builds from committed fixtures or any `--runs-dir` without live CI or dbt.
- [`scripts/factory-site-smoke.py`](scripts/factory-site-smoke.py) for offline HTML/SVG checks.
- Golden fixtures: [examples/sample-runs/](examples/sample-runs/) and [examples/minimal-product-repo/](examples/minimal-product-repo/) validated by [`scripts/test-examples.sh`](scripts/test-examples.sh).

**CFO dbt marts and data quality**

- Marts [`mart_model_efficiency`](factory/dbt/models/marts/mart_model_efficiency.sql), [`mart_monthly_cfo`](factory/dbt/models/marts/mart_monthly_cfo.sql), [`mart_spend_by_work_type`](factory/dbt/models/marts/mart_spend_by_work_type.sql) with forecast and run-rate companions (`fct_forecast_vs_actual`, `rpt_run_rate`).
- Singular dbt tests: `assert_cfo_monthly_matches_runs`, `assert_forecast_grain_unique`, `assert_model_efficiency_bounds`, `assert_token_counts_non_negative`.
- Factory site **Financials** splits **Coding** vs **Review** via `mart_spend_by_work_type`; empty-seed handling avoids null CFO headlines on fresh installs.

**Unified factory CLI and owner tooling**

- [`scripts/factory-cli.py`](scripts/factory-cli.py): **31** grouped commands — see [docs/CLI.md](docs/CLI.md).
- Readiness and release: [`scripts/factory-doctor.py`](scripts/factory-doctor.py) ([docs/DOCTOR.md](docs/DOCTOR.md)), [`scripts/factory-owner-pack.py`](scripts/factory-owner-pack.py), [`scripts/factory-release.py`](scripts/factory-release.py), [`scripts/factory-monthly-review.py`](scripts/factory-monthly-review.py) ([docs/MONTHLY_REVIEW.md](docs/MONTHLY_REVIEW.md)).
- Hygiene and policy: [`scripts/factory-decision-log.py`](scripts/factory-decision-log.py), [`scripts/factory-branch-cleanup.py`](scripts/factory-branch-cleanup.py), [`scripts/factory-models-check.py`](scripts/factory-models-check.py), [`scripts/factory-spec-lint.py`](scripts/factory-spec-lint.py), [`scripts/factory-check-docs.py`](scripts/factory-check-docs.py), [`scripts/factory-audit-workflows.py`](scripts/factory-audit-workflows.py).
- Spend and models: [`scripts/factory-cost-digest.py`](scripts/factory-cost-digest.py) ([docs/COST_DIGEST.md](docs/COST_DIGEST.md)), [`scripts/factory-model-scout.py`](scripts/factory-model-scout.py) ([docs/MODEL_SCOUTING.md](docs/MODEL_SCOUTING.md)), [`scripts/factory-critic-run.py`](scripts/factory-critic-run.py) ([docs/CRITIC_REVIEW.md](docs/CRITIC_REVIEW.md)).

**Factory core, dispatch, and `/oc` pipeline**

- [`.factory/mode.yml`](.factory/mode.yml) template vs product mode; path policy in [`scripts/opencode-artifact-scan.sh`](scripts/opencode-artifact-scan.sh) with expanded **PROTECTED_SCRIPTS** (listed via `opencode-artifact-scan.sh --list-protected`).
- Sandboxed worker tests: [`scripts/opencode-worker-test.sh`](scripts/opencode-worker-test.sh) — approved bash test entry for `/oc` workers besides git.
- **`factory:selected`** auto-dispatch via [`scripts/factory-selected-dispatch.py`](scripts/factory-selected-dispatch.py) (owner workflow paste in [docs/OWNER_WORKFLOW_SYNC.md](docs/OWNER_WORKFLOW_SYNC.md)).
- Complex-build **1-fix-round circuit breaker** in [`scripts/factory-fix-policy.py`](scripts/factory-fix-policy.py) via [`scripts/factory-run-review.py`](scripts/factory-run-review.py).
- Prior issue spend preflight [`scripts/factory-issue-spend.py`](scripts/factory-issue-spend.py); triage **`Recommendation:`** / **`Why:`** from [`scripts/factory-issue-triage.py`](scripts/factory-issue-triage.py); merge gate [`scripts/factory-merge.sh`](scripts/factory-merge.sh).
- Two-tier utilization waterfall in [`.factory/MODEL_ROUTING.md`](.factory/MODEL_ROUTING.md): DeepInfra `/oc` required, optional $0 Cursor Cloud Agent when pool headroom allows.
- Owner-only [`factory/budget.yml`](factory/budget.yml) and [`scripts/factory-budget-vars.py`](scripts/factory-budget-vars.py).
- DeepInfra prompt-cache tooling, routing report, critic packager, and consolidated offline harness [`scripts/test-all.sh`](scripts/test-all.sh) (**72** scripts, all passing offline).
- [`.github/workflows/approve-oc-runs.yml`](.github/workflows/approve-oc-runs.yml) for same-repo `oc/` branch CI hold approval.

**Docs, examples, and governance**

- Adoption map: [ADOPTING.md](ADOPTING.md), [docs/SETUP.md](docs/SETUP.md), [docs/INIT_REPO.md](docs/INIT_REPO.md), [docs/MIGRATING.md](docs/MIGRATING.md), [docs/OWNER_WORKFLOW_SYNC.md](docs/OWNER_WORKFLOW_SYNC.md), [docs/TRIAGE.md](docs/TRIAGE.md), [docs/PITCH_20S.md](docs/PITCH_20S.md), [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
- [CONTRIBUTING.md](CONTRIBUTING.md), GitHub issue templates, [LICENSE](LICENSE) (MIT), [SECURITY.md](SECURITY.md).
- Shell guardrails: [`scripts/test-shell-hygiene.sh`](scripts/test-shell-hygiene.sh).

### Changed

- [`scripts/pr-check.sh`](scripts/pr-check.sh) enforces issue refs, **AI disclosure**, DeepInfra **Cost:** lines, factory-run block fields, and harness **Verification** without FAIL.
- Reusable-workflow-first release in [docs/RELEASING.md](docs/RELEASING.md); product repos pin `factory_ref` at a template tag.
- [`scripts/harden-repo.sh`](scripts/harden-repo.sh) and [`scripts/protect-main.sh`](scripts/protect-main.sh): configurable flags and `--verify` ruleset drift checks ([`scripts/test-protect-main.sh`](scripts/test-protect-main.sh)).

### Fixed

- Harness Verification: `opencode-verify.sh` and spec lint reject masked pipes (`| head`, `| tail`); Python **3.14+** guard for dbt workflows (pin 3.12/3.13 per [docs/OWNER_WORKFLOW_SYNC.md](docs/OWNER_WORKFLOW_SYNC.md)).
- Factory site Financials headline math, build pipeline, and weekly budget alignment with dbt assertions.
- `/oc run` refuses empty owner instructions; spec linter requires **Bad inputs** on normal/high specs.
- [`scripts/factory-model-scout.py`](scripts/factory-model-scout.py) stderr prefix `model-scout:` for catalog errors (consistent with edge-case tests).

### Security

- [`scripts/factory-prepublic-check.py`](scripts/factory-prepublic-check.py) — tracked-content scan before public launch; [docs/PUBLIC_LAUNCH_RUNBOOK.md](docs/PUBLIC_LAUNCH_RUNBOOK.md) for owner cut checklist.
- [`scripts/factory-audit-workflows.py`](scripts/factory-audit-workflows.py) — unpinned actions, missing offline test steps, Python pin drift.
- [`scripts/harden-repo.sh`](scripts/harden-repo.sh) and [`scripts/protect-main.sh`](scripts/protect-main.sh) per [`.factory/repo-security-baseline.md`](.factory/repo-security-baseline.md).
- `approve-oc-runs` uses `pull_request_target` without PR code checkout; approves only same-repo `oc/` heads.