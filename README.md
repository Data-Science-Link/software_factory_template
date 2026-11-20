# Software factory template

A copyable way to run a repo where AI agents do most of the building and a human keeps the judgment calls. The method lives in `.factory/` as plain markdown, so it survives model and tool changes.

## The idea in about 20 seconds

Work enters as a **GitHub issue**. The **owner** marks what to work on (`factory:selected`). The **Factory Manager** (one bot per repo) drafts a **spec**, routes model and cost, and starts **GitHub Actions** workers on **DeepInfra** via owner comments: `/oc spec`, `/oc run`, and `/oc fix`. Each run opens or updates a **PR** with a standard shape, a **gate** before the runner stops, and a **run record** (`factory/runs/`). The owner gives the **product gate** for normal and high risk; trivial work may merge on green checks. A generated **factory site** (Architecture, Financials, Backlog, dbt tabs) tracks the loop and spend; weekly and monthly caps live in owner-only **`factory/budget.yml`**. Lessons go back into skills and [`DECISIONS.md`](.factory/DECISIONS.md).

The loop is intentionally boring: same spec sections, same PR template, same JSON per run, so cost and quality are comparable issue to issue. Full playbook: [`.factory/FACTORY.md`](.factory/FACTORY.md). Vision and retirement notes: [`.factory/VISION.md`](.factory/VISION.md).

## Default worker path (cloud)

| Step | Who | What happens |
|---|---|---|
| Intake | Anyone | GitHub issue with a one-sentence outcome. |
| Selection | Owner | Label `factory:selected` or tell the manager to select the issue. Only selected issues continue. |
| Spec | Manager (+ optional `/oc spec`) | Approved spec as an issue comment; the run commits `factory/specs/issue-<N>.md`. |
| Run | Owner | Comment `/oc run` on the issue → Actions worker (OpenCode + DeepInfra per [`.factory/models.yaml`](.factory/models.yaml)). |
| Fix | Owner | On the bot PR (`oc/issue-<N>-<run_id>`), comment `/oc fix <what to fix>`. |
| Review | Manager | One `Factory review` comment; CI + harness evidence on the PR. |
| Merge | Manager or owner | By risk class (see [ADOPTING.md](ADOPTING.md)); workers never merge. |

**Inference** is billed per token on DeepInfra (separate Actions-only key in the `DEEPINFRA_API_KEY` secret). **Compute** is a clean `ubuntu-latest` runner per job. **Cursor cloud agents** remain useful for building the factory itself and as a backup harness; they are not the default for selected product issues.

## Roles

| Role | What they do |
|---|---|
| **Human owner** | Chooses work, approves high-risk specs and the product gate before normal/high PRs merge, sets budgets. |
| **Factory Manager** (bot, one per repo) | Triage, specs, `/oc` kickoff, PR review, merges within authority, spend and gate watching. |
| **Giver** (optional) | Asks ledger, decision drafts, healthy challenge — never builds or merges. |
| **Coordinator** (optional) | Chat or intake → GitHub issue → hand off to the manager. |
| **Worker** | Actions harness on a branch: build, test, open/update PR — no merge, no workflow edits. |

## Factory site and budgets

The **factory site** is static HTML generated under `site/` (see [`factory/site/README.md`](factory/site/README.md)):

- **Architecture** — loop, roles, routing, and guards from `FACTORY.md` and `models.yaml`.
- **Financials** — spend, forecasts, and run rate from dbt marts (via `factory/dbt/` and run records).
- **Backlog** — open issues and epics (titles always shown).
- **dbt** — model lineage for the financial pipeline.

On a **public** repo, deploy with the owner-pasted `factory-site` workflow to **GitHub Pages**. On a **private** repo, the same build is a downloadable Actions artifact (Pages would expose the site). Refresh: every push to `main` that touches site inputs, weekly, and on demand — see [docs/SETUP.md](docs/SETUP.md) §7.

**`factory/budget.yml`** holds weekly/monthly site budgets and related caps. It is **owner-only**; workers must not edit it. Routing caps and per-issue targets also live in [`.factory/models.yaml`](.factory/models.yaml) (owner-only).

## Using or adopting the factory

| Audience | Start here |
|---|---|
| People already in an install | [ADOPTING.md](ADOPTING.md) — labels, `/oc` commands, merge rules, factory site. |
| New repo install | [docs/SETUP.md](docs/SETUP.md) — copy checklist, secrets, labels, protection, site hosting. |
| Releases and pinning | [docs/RELEASING.md](docs/RELEASING.md) and [CHANGELOG.md](CHANGELOG.md). Reusable workflow pins are planned (#156); until then, copy files from a release tag. |
| The full loop and gates | [`.factory/FACTORY.md`](.factory/FACTORY.md). |

## Rollout checklist (copy into another repo)

Use this as a map; detail and copy-paste steps are in the linked docs.

1. **Copy the factory tree** — `.factory/`, `scripts/`, `.github/` (workflows, PR template, `protect-main` ruleset), and `opencode.json`. See [docs/SETUP.md](docs/SETUP.md) §1.
2. **Per-repo config** — Fill [`.factory/DOCS.md`](.factory/DOCS.md), append-only [`.factory/DECISIONS.md`](.factory/DECISIONS.md), and repo `AGENTS.md`. Set [`.factory/MODEL_ROUTING.md`](.factory/MODEL_ROUTING.md); review owner-only [`.factory/models.yaml`](.factory/models.yaml) and create **`factory/budget.yml`** with your caps.
3. **Secrets (names only in docs)** — `DEEPINFRA_API_KEY` (Actions-only key, spending limit on the provider) and variable `FACTORY_DEEPINFRA_KEY_NAME` → `DEEPINFRA_API_KEY`. Never commit values. [docs/SETUP.md](docs/SETUP.md) §2.
4. **Owner-pasted workflows** — OpenCode run/spec/fix workflows and `factory-site` (and financials refresh when used) are **high risk**: the owner's account pastes YAML under `.github/workflows/`; agent tokens must not have `workflow` scope. [docs/SETUP.md](docs/SETUP.md) §5–7, [ADOPTING.md](ADOPTING.md).
5. **Labels and protection** — `factory:selected`, `epic`, `owner-action`, `priority:*`, `risk:high`; run `scripts/protect-main.sh` once as admin; `scripts/install-hooks.sh` in every clone. [docs/SETUP.md](docs/SETUP.md) §3–4.
6. **Factory site** — Public repo: enable Pages (Source: GitHub Actions) and run the site workflow once. Private repo: use the artifact only. [docs/SETUP.md](docs/SETUP.md) §7.
7. **Adjust workflow trigger login** — `/oc` workflows run only for comments from the repo **owner** account; change the hardcoded login when you copy workflows. [docs/SETUP.md](docs/SETUP.md) §9.
8. **First smoke run** — Owner adds `factory:selected`, posts `/oc spec` (if needed), approves the spec, posts `/oc run`, confirms a PR with run record and green `pr-check`, `run-records`, and `gitleaks`. Commands and gates: [ADOPTING.md](ADOPTING.md) and [`.factory/FACTORY.md`](.factory/FACTORY.md).
9. **Stay current** — Cut or follow [semver tags](docs/RELEASING.md) on this template; product repos pick up changes via copy or a future sync PR (#156).

## File map (high level)

| Path | Purpose |
|---|---|
| [`.factory/FACTORY.md`](.factory/FACTORY.md) | Playbook: triggers, loop, merge authority, evidence rules. |
| [`.factory/VISION.md`](.factory/VISION.md) | Cloud factory design; what replaced the old default path. |
| [`.factory/DECISIONS.md`](.factory/DECISIONS.md) | Append-only decision log (method history here; your repo keeps its own). |
| [`.factory/templates/spec.md`](.factory/templates/spec.md) | Standard spec sections for selected issues. |
| [`.factory/models.yaml`](.factory/models.yaml) | DeepInfra prices and routing (owner-only). |
| [`.factory/skills/`](.factory/skills/) | Step-by-step skills (`factory-loop.md`, liability gates, review, intake). |
| [`factory/specs/`](factory/specs/) | Approved specs committed from runs. |
| [`factory/runs/`](factory/runs/) | One JSON run record per Actions worker run. |
| [`factory/dbt/`](factory/dbt/) | dbt-duckdb project for spend marts feeding the site. |
| [`factory/budget.yml`](factory/budget.yml) | Owner-only weekly/monthly budgets for the site and reports. |
| [`scripts/`](scripts/) | Routing, gate, publish, site build, `pr-check.sh`, and guards. |

## Local open-weights (optional fallback)

**Retired as the default** (2026-11): selected product work runs on **Actions + DeepInfra**, not on a desktop harness. If Actions cannot run, the owner may still work from an approved spec in local Cursor with their own provider key — see [`.factory/skills/local-open-weights-run.md`](.factory/skills/local-open-weights-run.md), [`.factory/skills/local-owner-setup.md`](.factory/skills/local-owner-setup.md), [`.factory/skills/local-agent-safety.md`](.factory/skills/local-agent-safety.md), and the always-on rule [`.cursor/rules/factory.mdc`](.cursor/rules/factory.mdc) (`do issue N`, `address the review on PR N`). Same gates and PR shape; API keys never go in the repo.

## How changes to the template flow

1. A lesson from a live repo or a design change becomes a PR here first.
2. The owner reviews and merges.
3. Product repos copy updated `.factory/` and `scripts/`, or pin a release tag when #156 lands.

Method history stays in this repo's [`.factory/DECISIONS.md`](.factory/DECISIONS.md); each product repo keeps a separate log. Release process: [docs/RELEASING.md](docs/RELEASING.md).