# Adopting the software factory

AI workers run on GitHub issues; the **owner** and **Factory Manager** keep the gates. The owner selects work, workers draft specs or build from approved ones, and each pull request must pass checks and the product gate before merge.

Playbook: [`.factory/FACTORY.md`](.factory/FACTORY.md). **New repo:** [docs/SETUP.md](docs/SETUP.md). **Stuck:** [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Three-step quickstart (public `v0.1.0`)

Same flow as [README.md](README.md); run from a template checkout with `pip install -r requirements-factory.txt` once.

1. **Preview spend and site tabs** — golden run records only, no network:

   ```bash
   bash scripts/factory-site-build.sh --offline --runs-dir examples/sample-runs --now "2026-11-20 12:00:00"
   ```

   Open `site/index.html`. Optional 30-day packet: `python3 scripts/factory-monthly-review.py --runs-dir examples/sample-runs --as-of 2026-11-20` ([docs/MONTHLY_REVIEW.md](docs/MONTHLY_REVIEW.md)).

2. **Bootstrap a product repo** — dry-run first, then write callers pinned to your org:

   ```bash
   python3 scripts/factory-init-repo.py \
     --target /path/to/product-repo \
     --owner YOUR_GITHUB_LOGIN \
     --template-repo YOUR_ORG/software_factory_template \
     --tag v0.1.0 \
     --dry-run

   python3 scripts/factory-init-repo.py \
     --target /path/to/product-repo \
     --owner YOUR_GITHUB_LOGIN \
     --template-repo YOUR_ORG/software_factory_template \
     --tag v0.1.0
   ```

   Compare output to [examples/minimal-product-repo/](examples/minimal-product-repo/). Detail: [docs/INIT_REPO.md](docs/INIT_REPO.md).

3. **Verify and pilot** — `python3 scripts/factory-doctor.py --repo-dir /path/to/product-repo --public`, then follow [docs/PILOT_RUNBOOK.md](docs/PILOT_RUNBOOK.md). Template owners cutting a public release: [docs/PUBLIC_LAUNCH_RUNBOOK.md](docs/PUBLIC_LAUNCH_RUNBOOK.md) and pending workflow pastes in [docs/OWNER_WORKFLOW_SYNC.md](docs/OWNER_WORKFLOW_SYNC.md).

## Bootstrap and health (CLI)

`python3 scripts/factory-cli.py` wraps the same tools ([docs/CLI.md](docs/CLI.md)):

```bash
python3 scripts/factory-cli.py init --target /path/to/product-repo
python3 scripts/factory-cli.py doctor --repo-dir /path/to/product-repo --public
python3 scripts/factory-cli.py migrate-adopter --repo-dir /path/to/product-repo --tag v0.1.0
```

Template owners before a public tag: `python3 scripts/factory-cli.py owner-pack --version v0.1.0` ([docs/PUBLIC_LAUNCH_RUNBOOK.md](docs/PUBLIC_LAUNCH_RUNBOOK.md)).

Compare the stamped layout to [examples/minimal-product-repo/](examples/minimal-product-repo/). Detail: [docs/MIGRATING.md](docs/MIGRATING.md), [docs/DOCTOR.md](docs/DOCTOR.md).

## For people

**Select work.** Add the `factory:selected` label to a GitHub issue, or ask the Factory Manager to select `#N`. Only selected issues get a spec or a worker run. Other labels: `epic`, `owner-action`, `priority:low`, `priority:high`, and `risk:high` (high-risk work needs the owner's spec approval).

**Approve a spec.** After an owner `/oc spec` comment, a draft spec is posted on the issue. The Factory Manager reviews and approves **trivial** and **normal** risk specs. **High** risk (`risk:high`) goes to the **owner**. Post the approved copy with:

```bash
python3 scripts/factory-approve-spec.py <issue> <draft-comment-URL> \
  --approved-by <factory-manager-id>|<owner-login>
```

Use the Factory Manager bot id for trivial and normal risk; use the **owner login** for high risk. If predicted cost is over the issue target (`budget.issue_target_usd` in `.factory/models.yaml`), the owner also passes `--over-target-ok`, or the issue is split.

**Merge a PR.** Before merge, the branch must be 0 commits behind `main`, and `pr-check`, `run-records`, and `gitleaks` must be green on the head commit. Merge with a merge commit only.

| Risk class | Who may merge |
|---|---|
| **trivial** (typos, docs-only, no behavior change) | Factory manager, after green checks |
| **normal** (features, bugfixes, any UI or pages) | Owner, after the product gate |
| **high** (secrets, workflows, license, supply chain) | Owner, after the product gate |

The product gate has to be written on the PR body (Factory loop step 7 checked, and Human reviewed filled in) before merge. Chat approval alone is not the audit trail. Workers never merge.

**Read the factory site.** After the owner pastes the `factory-site` workflow, a **private** install gets a downloadable Actions artifact; a **public** install can publish to GitHub Pages ([docs/SETUP.md](docs/SETUP.md) §7). Architecture, Financials (including Coding vs Review spend), Backlog, and dbt tabs come from `factory/runs/` and `factory/dbt/`.

## For agents

**Commands.** Post these only as the repo owner, as a new comment that *starts* with the command. Never post a bare `/oc` with no verb or instruction (#150).

| Where | Command | What it does |
|---|---|---|
| A `factory:selected` issue | `/oc spec` or `/oc spec [guidance]` | Drafts a spec (read-only). `/oc` never reads a draft; someone has to approve it first. |
| A selected issue with an approved spec | `/oc run` or `/oc <instruction>` | Builds from the approved spec and opens or updates a PR. |
| An open same-repo PR whose head is `oc/issue-<N>-<run_id>` | `/oc fix <what to fix>` | Pushes one fix commit to that branch. It does not open a new PR or merge. |

`/oc` workflows only run for comments from the repo **owner** GitHub account (with `OWNER` association). Change the hardcoded login in copied workflow files when you adopt the factory (owner paste; agent tokens must not have `workflow` scope).

**Hard rules.**

- Never read, print, or commit secrets, keys, or tokens, and never paste them into issues, PRs, or chat.
- Never enable on-demand spend.
- Never edit owner-only paths: `.github/`, `opencode.json`, `AGENTS.md`, `.factory/mode.yml`, `.factory/actions-security.md`, `.factory/models.yaml`, `factory/budget.yml`, `requirements-factory.txt`, and the protected scripts listed by `bash scripts/opencode-artifact-scan.sh --list-protected` (in **product** mode, defined in `.factory/mode.yml`, the entire `scripts/` and `.factory/` trees are owner-only). Workers also must not delete, rename, or chmod an existing script.
- Never run `curl`, `wget`, `gh api`, or `gh pr merge`; never push to `main`; never use `--no-verify`.
- Never merge. Humans give the product gate for normal and high risk.
- Stop and ask the owner when the spec is high risk, the predicted cost is over the issue target, a gate or required check fails, the change would touch an owner-only path, or the next step is a product choice.

**Report back** with the PR link, the status of `pr-check`, `run-records`, and `gitleaks`, the run cost (or "not measured"), and the decision the owner still needs to make (spec approval, over-target approval, or the product gate).

Standing rules are in [`AGENTS.md`](AGENTS.md). Independent Critic and model scouting: [docs/CRITIC_REVIEW.md](docs/CRITIC_REVIEW.md), [docs/MODEL_SCOUTING.md](docs/MODEL_SCOUTING.md).

## Setup, releases, and pinning

New repo? Start with [docs/SETUP.md](docs/SETUP.md) and [docs/PITCH_20S.md](docs/PITCH_20S.md).

Version tags: [docs/RELEASING.md](docs/RELEASING.md), [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md). Product repos pin reusable workflows at a semver tag once the #156 pilot completes; until then, bootstrap with `python3 scripts/factory-cli.py init` or copy files from the setup checklist.

## Feedback intake

A factory problem found in a product repo is filed once here with the `from-product` label and a required **Source repo** field. Use [CONTRIBUTING.md](CONTRIBUTING.md) (structured issue forms) or [docs/factory-problem-issue-template.md](docs/factory-problem-issue-template.md).

**Triage rule.** Incoming cross-repo issues are reviewed here, fixed in the template, released as a new tag, and picked up by product repos through a sync PR (`python3 scripts/factory-cli.py sync-repos --list factory/adopters.txt --dry-run`).

**No secrets.** Do not paste secrets, tokens, logs with keys, or private product data in the filing.
