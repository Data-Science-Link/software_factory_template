# Software factory template

Copyable method for repos where AI agents do most of the building and a human keeps the judgment calls. The playbook lives in `.factory/` as plain markdown so it survives model and tool changes.

**Peer pitch (~20 seconds):** [docs/PITCH_20S.md](docs/PITCH_20S.md)

## Adopt in 3 steps (`v0.1.0`)

From a checkout of this repo. Install validators once: `pip install -r requirements-factory.txt`.

| Step | What to run | Read next |
|---|---|---|
| **1 — Preview** | Offline Factory Site from golden run records (no product repo, no network): `bash scripts/factory-site-build.sh --offline --runs-dir examples/sample-runs --now "2026-11-20 12:00:00"` then open `site/index.html`. | [examples/README.md](examples/README.md) |
| **2 — Bootstrap** | One-command adopter init (preview with `--dry-run` first): `python3 scripts/factory-init-repo.py --target /path/to/product-repo --owner YOUR_GITHUB_LOGIN --template-repo YOUR_ORG/software_factory_template --tag v0.1.0` | [docs/INIT_REPO.md](docs/INIT_REPO.md) · [examples/minimal-product-repo/](examples/minimal-product-repo/) |
| **3 — Verify** | Readiness and public hygiene: `python3 scripts/factory-doctor.py --repo-dir /path/to/product-repo --public` | [docs/SETUP.md](docs/SETUP.md) · [docs/PILOT_RUNBOOK.md](docs/PILOT_RUNBOOK.md) |

Owner launch and workflow paste order: [docs/PUBLIC_LAUNCH_RUNBOOK.md](docs/PUBLIC_LAUNCH_RUNBOOK.md). Monthly spend ritual: [docs/MONTHLY_REVIEW.md](docs/MONTHLY_REVIEW.md). Pending workflow edits: [docs/OWNER_WORKFLOW_SYNC.md](docs/OWNER_WORKFLOW_SYNC.md).

CLI index: `python3 scripts/factory-cli.py --help` · [docs/CLI.md](docs/CLI.md)

## What it is

Work enters as a **GitHub issue**. The owner marks what to work on (`factory:selected`). A **Factory Manager** bot drafts a **spec**, routes model and cost, and starts **GitHub Actions** workers on **DeepInfra** via owner comments: `/oc spec`, `/oc run`, and `/oc fix`. Each run opens or updates a **PR** with a standard shape, a **gate** before the runner stops, and a **run record** under `factory/runs/`. Spend rolls into dbt marts and a static **factory site**; caps live in owner-only `factory/budget.yml` and `.factory/models.yaml`.

The loop is boring on purpose: same spec sections, same PR template, same JSON per run — comparable cost and quality issue to issue. Deep playbook: [`.factory/FACTORY.md`](.factory/FACTORY.md). Design notes: [`.factory/VISION.md`](.factory/VISION.md).

## Default worker path (cloud)

| Step | Who | What happens |
|---|---|---|
| Intake | Anyone | GitHub issue with a one-sentence outcome. |
| Selection | Owner | Label `factory:selected` (or manager selects). Only selected issues continue. |
| Spec | Manager (+ optional `/oc spec`) | Approved spec as issue comment; run commits `factory/specs/issue-<N>.md`. |
| Run | Owner | Comment `/oc run` → Actions worker (OpenCode + DeepInfra per [`.factory/models.yaml`](.factory/models.yaml)). |
| Fix | Owner | On the bot PR, comment `/oc fix <what to fix>`. |
| Review | Manager | One `Factory review` comment; CI + harness evidence on the PR. |
| Merge | Manager or owner | By risk class ([ADOPTING.md](ADOPTING.md)); workers never merge. |

**Inference** is billed per token on DeepInfra (Actions-only key in the `DEEPINFRA_API_KEY` secret). **Compute** is a clean `ubuntu-latest` runner per job. **Hosted cloud agents** help build the factory itself and remain a backup harness; they are not the default for selected product issues.

## Doc map (adoption and ops)

| Topic | Doc |
|---|---|
| Twenty-second pitch | [docs/PITCH_20S.md](docs/PITCH_20S.md) |
| CLI subcommands | [docs/CLI.md](docs/CLI.md) |
| Bootstrap a product repo | [docs/INIT_REPO.md](docs/INIT_REPO.md) |
| Migrate copied template files | [docs/MIGRATING.md](docs/MIGRATING.md) |
| Doctor / readiness | [docs/DOCTOR.md](docs/DOCTOR.md) |
| Using the factory day to day | [ADOPTING.md](ADOPTING.md) |
| New-repo setup checklist | [docs/SETUP.md](docs/SETUP.md) |
| Public launch | [docs/PUBLIC_LAUNCH_RUNBOOK.md](docs/PUBLIC_LAUNCH_RUNBOOK.md) |
| Monthly spend review | [docs/MONTHLY_REVIEW.md](docs/MONTHLY_REVIEW.md) |
| Releases and tags | [docs/RELEASING.md](docs/RELEASING.md) · [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md) |
| Spend digest | [docs/COST_DIGEST.md](docs/COST_DIGEST.md) |
| Backlog triage | [docs/TRIAGE.md](docs/TRIAGE.md) |
| Owner workflow sync | [docs/OWNER_WORKFLOW_SYNC.md](docs/OWNER_WORKFLOW_SYNC.md) |
| Reusable workflow pins | [docs/reusable-workflows/](docs/reusable-workflows/README.md) |
| Examples and fixtures | [examples/README.md](examples/README.md) |
| Contributing | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Independent Critic loop | [docs/CRITIC_REVIEW.md](docs/CRITIC_REVIEW.md) |
| Model scouting | [docs/MODEL_SCOUTING.md](docs/MODEL_SCOUTING.md) |
| Troubleshooting | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |
| Branch hygiene | [docs/BRANCH_HYGIENE.md](docs/BRANCH_HYGIENE.md) |

## Roles

| Role | What they do |
|---|---|
| **Human owner** | Chooses work, approves high-risk specs and the product gate before normal/high PRs merge, sets budgets. |
| **Factory Manager** (bot, one per repo) | Triage, specs, `/oc` kickoff, PR review, merges within authority, spend and gate watching. |
| **Giver** (optional) | Ledger, decision drafts, healthy challenge — never builds or merges. |
| **Coordinator** (optional) | Chat or intake → GitHub issue → hand off to the manager. |
| **Worker** | Actions harness on a branch: build, test, open/update PR — no merge, no workflow edits. |

## Factory site and budgets

Static HTML under `site/` (see [`factory/site/README.md`](factory/site/README.md)): Architecture, Financials, Backlog, and dbt tabs from run records and `factory/dbt/`. Public repos: owner-pasted `factory-site` workflow to GitHub Pages; private repos use the Actions artifact. Refresh on pushes to site inputs, weekly, and on demand — [docs/SETUP.md](docs/SETUP.md) §7. **`factory/budget.yml`** is owner-only; routing caps live in [`.factory/models.yaml`](.factory/models.yaml).

## Rollout checklist (copy into another repo)

1. **Bootstrap** — `python3 scripts/factory-init-repo.py` (step 2 above) or [docs/INIT_REPO.md](docs/INIT_REPO.md).
2. **Per-repo config** — [`.factory/DOCS.md`](.factory/DOCS.md), [`.factory/DECISIONS.md`](.factory/DECISIONS.md), repo `AGENTS.md`, [`.factory/MODEL_ROUTING.md`](.factory/MODEL_ROUTING.md), `factory/budget.yml`.
3. **Secrets (names only)** — `DEEPINFRA_API_KEY` and variable `FACTORY_DEEPINFRA_KEY_NAME` → `DEEPINFRA_API_KEY`. [docs/SETUP.md](docs/SETUP.md) §2.
4. **Workflows** — Thin caller stubs from [docs/reusable-workflows/](docs/reusable-workflows/README.md); owner pastes YAML ([docs/SETUP.md](docs/SETUP.md) §5–7, [ADOPTING.md](ADOPTING.md)).
5. **Labels and protection** — `factory:selected`, `epic`, `owner-action`, `priority:*`, `risk:high`; `scripts/protect-main.sh`; `scripts/install-hooks.sh`. [docs/SETUP.md](docs/SETUP.md) §3–4.
6. **Migrate legacy copies** — [docs/MIGRATING.md](docs/MIGRATING.md) and `python3 scripts/factory-cli.py migrate-adopter --repo-dir . --tag v0.1.0`.
7. **Smoke run** — `factory:selected` → `/oc spec` → `/oc run` → PR with run record and green `pr-check`, `run-records`, `gitleaks`.
8. **Stay current** — [docs/RELEASING.md](docs/RELEASING.md), `python3 scripts/factory-cli.py sync-repos --list factory/adopters.txt --dry-run`.

## File map (high level)

| Path | Purpose |
|---|---|
| [`.factory/FACTORY.md`](.factory/FACTORY.md) | Playbook: triggers, loop, merge authority, evidence rules. |
| [`.factory/VISION.md`](.factory/VISION.md) | Cloud factory design; what replaced the old default path. |
| [`.factory/DECISIONS.md`](.factory/DECISIONS.md) | Append-only decision log. |
| [`.factory/templates/spec.md`](.factory/templates/spec.md) | Standard spec sections. |
| [`.factory/models.yaml`](.factory/models.yaml) | DeepInfra prices and routing (owner-only). |
| [`.factory/skills/`](.factory/skills/) | Step-by-step skills. |
| [`factory/specs/`](factory/specs/) | Approved specs from runs. |
| [`factory/runs/`](factory/runs/) | One JSON run record per Actions worker run. |
| [`factory/dbt/`](factory/dbt/) | dbt-duckdb spend marts for the site. |
| [`factory/budget.yml`](factory/budget.yml) | Owner-only weekly/monthly budgets. |
| [`scripts/`](scripts/) | Routing, gate, site, `pr-check.sh`, factory CLI, guards. |

## Local open-weights (optional fallback)

**Retired as the default** (2026-11): selected product work runs on **Actions + DeepInfra**. For Actions outages, an owner may still run from an approved spec in local Cursor with their own provider key — see [`.factory/skills/local-open-weights-run.md`](.factory/skills/local-open-weights-run.md), [`.factory/skills/local-owner-setup.md`](.factory/skills/local-owner-setup.md), [`.factory/skills/local-agent-safety.md`](.factory/skills/local-agent-safety.md), and [`.cursor/rules/factory.mdc`](.cursor/rules/factory.mdc). Same gates and PR shape; API keys never go in the repo.

## How changes to the template flow

1. A lesson from a live repo or a design change becomes a PR here first.
2. The owner reviews and merges.
3. Product repos copy updated `.factory/` and `scripts/`, pin a release tag, or open a sync PR — [docs/MIGRATING.md](docs/MIGRATING.md).

Method history: this repo's [`.factory/DECISIONS.md`](.factory/DECISIONS.md). Release process: [docs/RELEASING.md](docs/RELEASING.md).