# Changelog

All notable changes to this template are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The first planned tag is **v0.1.0** (unreleased). No tag is cut until the owner approves; see [docs/RELEASING.md](docs/RELEASING.md) and [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md). Product repos pin reusable workflows at a semver tag once the #156 pilot completes.

### Added

**Factory core and guardrails**

- [`.factory/mode.yml`](.factory/mode.yml) distinguishes **template** mode (this repo) from **product** mode (adopter repos). Missing or invalid mode fails closed to product rules in [`scripts/opencode-artifact-scan.sh`](scripts/opencode-artifact-scan.sh).
- Sandboxed worker tests via [`scripts/opencode-worker-test.sh`](scripts/opencode-worker-test.sh): the only approved bash test entry point for `/oc` workers besides git.
- Complex-build **1-fix-round circuit breaker** in [`scripts/factory-fix-policy.py`](scripts/factory-fix-policy.py), wired into [`scripts/factory-run-review.py`](scripts/factory-run-review.py) so a failed first fix round on a complex issue escalates instead of churning.
- **Prior issue spend preflight** in [`scripts/factory-issue-spend.py`](scripts/factory-issue-spend.py) (used by `factory-run-start.py` and spec draft flows).
- Factory Manager triage output with **`Recommendation:`** and **`Why:`** lines from [`scripts/factory-issue-triage.py`](scripts/factory-issue-triage.py); human merge gate recording in [`scripts/factory-merge.sh`](scripts/factory-merge.sh).
- Optional **two-tier utilization waterfall** documented in [`.factory/MODEL_ROUTING.md`](.factory/MODEL_ROUTING.md) and [`.factory/DECISIONS.md`](.factory/DECISIONS.md): DeepInfra `/oc` as the required tier, optional **$0** Cursor Cloud Agent dispatch when subscription pool headroom allows.
- Owner-only [`factory/budget.yml`](factory/budget.yml) and [`scripts/factory-budget-vars.py`](scripts/factory-budget-vars.py); path policy blocks worker edits.

**Standalone factory site**

- [`scripts/factory-site.py`](scripts/factory-site.py): static site with **Architecture**, **Financials**, **Backlog**, and **dbt** tabs; light/dark theme toggle, live backlog text filter, Financials table sort and CSV export.
- [`scripts/factory-site-smoke.py`](scripts/factory-site-smoke.py) for offline HTML/SVG smoke checks.
- dbt marts [`mart_model_efficiency`](factory/dbt/models/marts/mart_model_efficiency.sql) and [`mart_monthly_cfo`](factory/dbt/models/marts/mart_monthly_cfo.sql) with dbt tab lineage from `manifest.json`; empty-seed handling fixes null CFO headline metrics on fresh installs.

**Adoption and operations CLI**

- [`scripts/factory-cli.py`](scripts/factory-cli.py) grouped entrypoint; see [docs/CLI.md](docs/CLI.md).
- Repo lifecycle: [`scripts/factory-init-repo.py`](scripts/factory-init-repo.py), [`scripts/factory-migrate-adopter.py`](scripts/factory-migrate-adopter.py), [`scripts/factory-doctor.py`](scripts/factory-doctor.py) ([docs/DOCTOR.md](docs/DOCTOR.md)), [`scripts/factory-release.py`](scripts/factory-release.py), [`scripts/factory-sync-repos.py`](scripts/factory-sync-repos.py).
- Spec and workflow hygiene: [`scripts/factory-spec-lint.py`](scripts/factory-spec-lint.py), [`scripts/factory-audit-workflows.py`](scripts/factory-audit-workflows.py), [`scripts/factory-check-docs.py`](scripts/factory-check-docs.py).
- Spend and launch: [`scripts/factory-cost-digest.py`](scripts/factory-cost-digest.py) ([docs/COST_DIGEST.md](docs/COST_DIGEST.md)), [`scripts/factory-prepublic-check.py`](scripts/factory-prepublic-check.py).
- Owner helpers: [`scripts/protect-main.sh`](scripts/protect-main.sh) (apply and `--verify` ruleset compliance), [`scripts/harden-repo.sh`](scripts/harden-repo.sh) ([`.factory/repo-security-baseline.md`](.factory/repo-security-baseline.md)).

**Reusable workflows and docs**

- Reference workflow bodies under [docs/reusable-workflows/](docs/reusable-workflows/README.md) with thin caller examples in `callers/`.
- Adoption docs: [ADOPTING.md](ADOPTING.md), [docs/SETUP.md](docs/SETUP.md), [docs/INIT_REPO.md](docs/INIT_REPO.md), [docs/MIGRATING.md](docs/MIGRATING.md), [docs/OWNER_WORKFLOW_SYNC.md](docs/OWNER_WORKFLOW_SYNC.md), [docs/TRIAGE.md](docs/TRIAGE.md), [docs/PITCH_20S.md](docs/PITCH_20S.md), [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
- [LICENSE](LICENSE) (MIT) and [SECURITY.md](SECURITY.md) for public template launch.

**OpenCode `/oc` pipeline**

- DeepInfra prompt-cache tuning, routing report, critic review packager/runner, model scout, and consolidated offline harness via [`scripts/test-all.sh`](scripts/test-all.sh).
- [`.github/workflows/approve-oc-runs.yml`](.github/workflows/approve-oc-runs.yml) auto-approves held CI for same-repo `oc/` branches (public-repo first-time contributor hold).

### Changed

- [`scripts/pr-check.sh`](scripts/pr-check.sh) enforces issue refs, agent **AI disclosure**, DeepInfra **Cost:** lines, factory-run block fields, and harness **Verification** must not report FAIL.
- Reusable-workflow-first release process in [docs/RELEASING.md](docs/RELEASING.md); product repos keep local config and pin `factory_ref` at a template tag.
- [`scripts/harden-repo.sh`](scripts/harden-repo.sh) and [`scripts/protect-main.sh`](scripts/protect-main.sh) gained configurable flags and `--verify` for ruleset drift checks (see [`scripts/test-protect-main.sh`](scripts/test-protect-main.sh)).

### Fixed

- Harness Verification: `opencode-verify.sh` and spec lint reject masked pipes (`| head`, `| tail`) that hide non-zero test exits; Python **3.14+** guard for dbt workflows (pin 3.12/3.13 per [docs/OWNER_WORKFLOW_SYNC.md](docs/OWNER_WORKFLOW_SYNC.md)).
- Factory site Financials headline math, live build pipeline, and weekly budget percentage alignment with dbt assertions.
- `/oc run` refuses empty owner instructions; spec linter requires **Bad inputs** on normal/high specs.

### Security

- [`scripts/factory-prepublic-check.py`](scripts/factory-prepublic-check.py) scans tracked content before going public.
- [`scripts/factory-audit-workflows.py`](scripts/factory-audit-workflows.py) detects unpinned actions, missing offline test steps, and Python pin drift in workflows.
- `approve-oc-runs` uses `pull_request_target` with no PR code checkout; approves only same-repo `oc/` heads.