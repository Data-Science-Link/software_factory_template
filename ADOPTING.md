# Adopting the software factory

This factory runs AI workers on GitHub issues, with a human keeping the gates. Michael selects the issue, a worker drafts a spec or builds from an approved one, and a pull request has to pass checks and the product gate before it merges.

For the playbook itself, see [`.factory/FACTORY.md`](.factory/FACTORY.md). To install the factory in a new repo, use the [setup checklist](docs/SETUP.md).

## For people

**Select work.** Add the `factory:selected` label to a GitHub issue, or tell Grok Bot `select #N`. Only selected issues get a spec or a worker run. Other labels you may use: `epic`, `owner-action`, `priority:low`, `priority:high`, and `risk:high` (high-risk work needs Michael's spec approval).

**Approve a spec.** After an owner `/oc spec` comment, a draft spec is posted on the issue. Grok Bot reviews and approves **trivial** and **normal** risk specs. **High** risk (`risk:high`) goes to Michael. The approved copy is posted with:

```
python3 scripts/factory-approve-spec.py <issue> <draft-comment-URL> --approved-by grok-bot|michael
```

Use `michael` for high risk. If the predicted cost is over the issue target (`budget.issue_target_usd` in `.factory/models.yaml`, currently $0.15), Michael also passes `--over-target-ok`, or the issue is split.

**Merge a PR.** Before merge, the branch must be 0 commits behind `main`, and `pr-check`, `run-records`, and `gitleaks` must be green on the head commit. Merge with a merge commit only.

| Risk class | Who may merge |
|---|---|
| **trivial** (typos, docs-only, no behavior change) | Factory manager, after green checks |
| **normal** (features, bugfixes, any UI or pages) | Michael, after the product gate |
| **high** (secrets, workflows, license, supply chain) | Michael, after the product gate |

The product gate has to be written on the PR body (Factory loop step 7 checked, and Human reviewed filled in) before merge. Chat approval alone is not the audit trail. Workers never merge.

**Read the factory site.** Once the site is published (issue #56), a **private** install gets a downloadable Actions artifact; a **public** install publishes to GitHub Pages (decision D1). The site is not live yet. This template is planned to go public before that publish step.

## For agents

**Commands.** Post these only as the repo owner, as a new comment that *starts* with the command. Never post a bare `/oc` with no verb or instruction (#150).

| Where | Command | What it does |
|---|---|---|
| A `factory:selected` issue | `/oc spec` or `/oc spec [guidance]` | Drafts a spec (read-only). `/oc` never reads a draft; someone has to approve it first. |
| A selected issue with an approved spec | `/oc run` or `/oc <instruction>` | Builds from the approved spec and opens or updates a PR. |
| An open same-repo PR whose head is `oc/issue-<N>-<run_id>` | `/oc fix <what to fix>` | Pushes one fix commit to that branch. It does not open a new PR or merge. |

Today the workflows only run for comments from the GitHub account `Data-Science-Link` with owner association. A product repo has to change that login in the copied workflow files (owner paste; the `gh` token has no `workflow` scope).

**Hard rules.**

- Never read, print, or commit secrets, keys, or tokens, and never paste them into issues, PRs, or chat.
- Never enable on-demand spend.
- Never edit owner-only paths: `.github/`, `opencode.json`, `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, `factory/budget.yml`, `requirements-factory.txt`, and the protected scripts listed by `bash scripts/opencode-artifact-scan.sh --list-protected`. Workers also must not delete, rename, or chmod an existing script.
- Never run `curl`, `wget`, `gh api`, or `gh pr merge`; never push to `main`; never use `--no-verify`.
- Never merge. Humans give the product gate for normal and high risk.
- Stop and ask the owner when the spec is high risk, the predicted cost is over the issue target, a gate or required check fails, the change would touch an owner-only path, or the next step is a product choice.

**Report back** with the PR link, the status of `pr-check`, `run-records`, and `gitleaks`, the run cost (or "not measured"), and the decision the owner still needs to make (spec approval, over-target approval, or the product gate).

Standing rules are in [`AGENTS.md`](AGENTS.md).

## Setup, releases, and pinning

New repo? Start with the [setup checklist](docs/SETUP.md).

Version tags and the release checklist are in [docs/RELEASING.md](docs/RELEASING.md). **Pinning a product repo to a release tag, reusable workflows, and sync PRs are planned (#156).** Until then, a repo adopts the factory by copying the files in the setup checklist.

## Feedback intake

A factory problem found in a product repo (Perspectiverse first) is filed once, here in the template, with the `from-product` label and a required `Source repo` field, so it can be traced back to where it was found. Use the reusable template at [docs/factory-problem-issue-template.md](docs/factory-problem-issue-template.md).

**Triage rule.** Incoming cross-repo issues are reviewed here, fixed in the template, released as a new tag, and picked up by product repos through a sync PR. Pinning and sync PRs are planned (#156).

**No secrets.** Do not paste secrets, tokens, logs with keys, or private product data in the filing.
