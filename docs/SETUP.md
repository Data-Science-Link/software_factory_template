# New-repo setup checklist

Use this when adding the factory to another repo. Names only for secrets and variables; never put values in the repo, issues, PRs, or chat.

Reusable workflows pin a template release tag (**#156**). Bootstrap with the CLI or copy the tree below, then fill in per-repo config. After #156, the product repo keeps only local config and pins `factory_ref` at a tag (see [RELEASING.md](RELEASING.md)).

**Stuck?** [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## 0. Three-step quickstart (recommended)

From a checkout of this template on tag `v0.1.0` (or `main` until the tag is cut). Install once: `pip install -r requirements-factory.txt`. Full narrative: [README.md](../README.md), [ADOPTING.md](../ADOPTING.md).

**Step 1 — Preview the Factory Site (offline, no product repo)**

```bash
bash scripts/factory-site-build.sh --offline --runs-dir examples/sample-runs --now "2026-11-20 12:00:00"
```

Open `site/index.html`. Golden fixtures live under [examples/](../examples/README.md). Optional monthly packet: `python3 scripts/factory-monthly-review.py --runs-dir examples/sample-runs --as-of 2026-11-20` ([MONTHLY_REVIEW.md](MONTHLY_REVIEW.md)).

**Step 2 — Bootstrap the product repo**

```bash
python3 scripts/factory-init-repo.py \
  --target /path/to/product-repo \
  --owner YOUR_GITHUB_LOGIN \
  --template-repo YOUR_ORG/software_factory_template \
  --tag v0.1.0
```

Use `--dry-run` first. Compare stamped files to [examples/minimal-product-repo/](../examples/minimal-product-repo/) (`mode.yml`, `models.yaml`, `factory/budget.yml`, `DECISIONS.md`, `AGENTS.md`). CLI alias: `python3 scripts/factory-cli.py init --target /path/to/product-repo` ([docs/CLI.md](CLI.md), [INIT_REPO.md](INIT_REPO.md)).

**Step 3 — Verify and run the pilot**

```bash
python3 scripts/factory-doctor.py --repo-dir /path/to/product-repo --public
```

Then secrets, labels, and owner workflow paste from the sections below, and [PILOT_RUNBOOK.md](PILOT_RUNBOOK.md). Template owners before going public: [PUBLIC_LAUNCH_RUNBOOK.md](PUBLIC_LAUNCH_RUNBOOK.md) and [OWNER_WORKFLOW_SYNC.md](OWNER_WORKFLOW_SYNC.md).

**Legacy copy** — Repos with full copied `scripts/` and workflows: [MIGRATING.md](MIGRATING.md) and `python3 scripts/factory-cli.py migrate-adopter --repo-dir /path/to/product-repo --tag v0.1.0`.

## 1. Copy the factory (manual alternative)

1. Copy `.factory/`, `scripts/`, and `.github/` (workflows, the PR template, and the `protect-main` ruleset) into the repo.
2. Set **product** mode in owner-only [`.factory/mode.yml`](../.factory/mode.yml): `mode: product` (workers must not edit this file). The template repo keeps `mode: template` so factory work can still add scripts and edit `.factory/` docs; if `mode` is missing or invalid, the artifact scan fails closed to product mode (no changes under `scripts/` or `.factory/`).
3. Fill in [`.factory/DOCS.md`](../.factory/DOCS.md) with that repo's real paths, secret *names* (never values), key view, and health numbers.
4. Add repo-specific skills under `.factory/skills/` as needed.
5. Keep `.factory/DECISIONS.md` append-only for that repo's own decisions.
6. Set [`.factory/MODEL_ROUTING.md`](../.factory/MODEL_ROUTING.md) and review [`.factory/models.yaml`](../.factory/models.yaml) for the models and caps you will use (`python3 scripts/factory-cli.py models-check --models-yaml .factory/models.yaml`).
7. In each clone, run `scripts/install-hooks.sh`. Once per repo, as an admin, run `scripts/protect-main.sh` (step 4).
8. Copy the starters in `.factory/sketches/` into place if the repo does not already have them, and add your own `LICENSE` and `SECURITY.md`.
9. Or install thin caller stubs from [docs/reusable-workflows/](reusable-workflows/README.md) once pinned at a template tag instead of copying full workflow bodies.

## 2. DeepInfra key (secret + variable)

1. Create a repo secret named `DEEPINFRA_API_KEY` with the DeepInfra key the Actions workers will use. Never commit the key or paste it into issues, PRs, or chat.
2. Create a repo **variable** named `FACTORY_DEEPINFRA_KEY_NAME` whose value is the *name* of that secret (`DEEPINFRA_API_KEY`). This is a variable, not a secret. Without it, run records skip the key-spend check.

Do not turn on on-demand spend.

## 3. Labels

Create these labels (names must match exactly):

| Label | What it's for |
|---|---|
| `epic` | Parent issue that tracks child issues |
| `owner-action` | A manual step the owner must do (workflow paste, secret, setting) |
| `factory:selected` | The owner has chosen this issue to be specced and worked |
| `priority:low` | Do when convenient |
| `priority:high` | Failed run, wasted spend, guardrail bypass, or factory mechanics bug |
| `risk:high` | High-risk issue: `/oc spec` uses V4 Pro and needs the owner's spec approval |

Standard GitHub labels (`bug`, `documentation`, `enhancement`, and so on) can stay. There is no `priority:medium` or `risk:normal` label; risk class for trivial and normal work lives on the spec and the PR, not as a label.

## 4. Branch protection and required checks

Run `scripts/protect-main.sh` once, logged in as an account with admin rights on the repo (not a scoped agent token). It applies [`.github/rulesets/protect-main.json`](../.github/rulesets/protect-main.json):

- the default branch cannot be deleted or force-pushed
- changes reach it only through a pull request, with merge commits only
- `gitleaks` and `pr-check` must pass on a branch that is up to date with `main`
- no one can bypass the ruleset

Before *any* merge, the factory rule is stricter: the branch must be 0 commits behind `main`, and **`pr-check`, `run-records`, and `gitleaks`** must all be green on the head commit. `run-records` is a job in the `pr-check` workflow. The ruleset file currently names `gitleaks` and `pr-check`; still wait for all three.

Private repos on GitHub Free cannot enforce rulesets. Options are GitHub Pro or making the repo public; until then, the local pre-push hook and the factory merge gate are the controls.

## 5. `gh` token scope

The token the factory and its agents use should **not** have the `workflow` scope (or the Workflows permission on a fine-grained token). Changes under `.github/workflows/` are pasted by the owner. Leave Administration off the agent token too; `protect-main.sh` is an owner step.

Suggested fine-grained permissions are in [`.factory/skills/local-agent-safety.md`](../.factory/skills/local-agent-safety.md): Contents, Pull requests, and Issues read/write, and Metadata read-only.

## 6. Per-repo config

These stay local to the install repo. After #156, factory scripts and workflows come from the pinned tag; only this kind of config stays in the product repo.

| File | What you set |
|---|---|
| `.factory/mode.yml` | `mode: product` in product repos (`mode: template` only in this template repo). Owner-only: workers must not edit it. Missing or invalid `mode` fails closed to product (no worker changes under `scripts/` or `.factory/`). |
| `.factory/models.yaml` | Model routing, prices, and today's spend caps (`budget.issue_target_usd`, `budget.issue_cap_usd`, `budget.deepinfra_monthly_limit_usd`). Owner-only: workers must not edit it. |
| `factory/budget.yml` | Weekly and monthly site budgets (**#169 D3**, added by #170). Starting values (**#169 D4**): $10 per month, $2.50 per week. Owner-only (#56): workers must not edit it, and the path-policy scan rejects any worker patch that does. |
| Protected-path list | Spend and security scripts workers must not edit. Printed by `bash scripts/opencode-artifact-scan.sh --list-protected`. The list lives in that script today; after #156 it comes from the pinned tag. |
| `.factory/DOCS.md`, `.factory/DECISIONS.md`, repo `AGENTS.md` | That repo's doc map, decision log, and standing agent rules. Validate: `python3 scripts/factory-cli.py decision-log check --file .factory/DECISIONS.md`. |

## 7. Site hosting

Per epic #169 decision D1:

- **Private repo:** the site is a downloadable Actions artifact only. Do not enable GitHub Pages; a Pages site from a private repo on this plan would be public.
- **Public repo:** publish to GitHub Pages (Settings → Pages → Source: GitHub Actions), once the site workflow exists.

The site workflow is `.github/workflows/factory-site.yml`, an owner paste (high risk, #56). It runs on every push to `main` that touches the site inputs, weekly (Mondays 13:23 UTC), and on demand from the Actions tab (**#169 D5**). It checks the repo's visibility at run time: a public repo deploys to Pages, a private repo only uploads a `factory-site` artifact.

**Turning on Pages (public repos only):**
1. Paste `.github/workflows/factory-site.yml` (or the thin caller that delegates to the template reusable workflow).
2. Go to **Settings → Pages → Build and deployment → Source** and choose **GitHub Actions** (not "Deploy from a branch"). There is no branch or folder to pick.
3. Run the workflow once from the Actions tab (factory-site → Run workflow). The deploy job's summary links the site, normally `https://<owner>.github.io/<repo>/`.

The first deploy creates the `github-pages` environment. If a run fails with "Get Pages site failed" or a 404 on deploy, the Source setting in step 2 isn't saved yet. On a private repo, skip steps 2 and 3 and download the artifact from the run page instead.

## 8. Actions access to this template

When the template repo is **public**, product repos reference its reusable workflows by org/repo path; no extra Actions access setting is required.

While the template is still **private**, sibling repos in the same GitHub account or org may need **Settings → Actions → General → Access** so workflows are reachable. That step goes away once the template is public (#185).

## 9. Workflow owner login

The `/oc` workflows in this template only run when the comment author is the template **owner** GitHub account and the author association is `OWNER`. In a product repo, change that login to your repo's owner account when you paste or copy the workflow files.

## Check the install

- [ ] `python3 scripts/factory-cli.py doctor --repo-dir .` passes (add `--public` before launching a public repo)
- [ ] Secret `DEEPINFRA_API_KEY` and variable `FACTORY_DEEPINFRA_KEY_NAME` are set (values never committed)
- [ ] The labels in step 3 exist
- [ ] `scripts/protect-main.sh` has been run (or the Free-plan limitation is recorded)
- [ ] The `gh` token has no `workflow` scope
- [ ] `.factory/mode.yml` is `mode: product` and per-repo config is filled in; no secrets are in those files; layout matches [examples/minimal-product-repo/](../examples/minimal-product-repo/) where applicable
- [ ] Site hosting matches whether the repo is private or public
- [ ] Workflow comment login matches the repo owner
- [ ] A first selected issue can take `/oc spec` from the owner account
