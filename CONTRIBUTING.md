# Contributing

Thank you for helping improve the software factory template. This repository is the **method source**: changes here flow to product repos through releases and copy/sync PRs.

## How to open an issue

Use **GitHub → New issue** and pick a structured form (blank issues stay enabled for quick triage):

| Form | When to use |
| --- | --- |
| **Factory idea / enhancement** | New capability, docs, or factory-loop improvement for this template. |
| **Bug report** | Something broken in scripts, docs, checks, or the adoption path. |
| **Factory problem found in a product repo** | Cross-repo feedback from an adopted product (`from-product` label). |

After filing, maintainers (or the Factory Manager) apply **priority** and **risk** labels so triage and routing stay comparable:

| Label family | Values | Role |
| --- | --- | --- |
| `priority:*` | `priority:high`, `priority:low` | Backlog ordering (`scripts/factory-issue-triage.py`; see [docs/TRIAGE.md](docs/TRIAGE.md)). |
| `risk:*` | `risk:high` (and implicit normal when absent) | Liability gates and merge authority (see [`.factory/skills/liability-gates.md`](.factory/skills/liability-gates.md)). |
| Type | `enhancement`, `bug` | Set by the issue forms where applicable. |

**Security:** Do not file vulnerabilities as public issues. Follow [SECURITY.md](SECURITY.md).

**Stuck during setup or CI?** See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## How the factory loop works

Work is tracked as **GitHub issues**, approved **specs**, and **pull requests** with evidence — not as open-ended chat threads.

| Resource | Purpose |
| --- | --- |
| [docs/PITCH_20S.md](docs/PITCH_20S.md) | Twenty-second pitch and adoption cheat sheet. |
| [examples/README.md](examples/README.md) | Golden sample spec, PR body, and minimal product layout. |
| [docs/CLI.md](docs/CLI.md) | `python3 scripts/factory-cli.py` command map. |
| [`.factory/FACTORY.md`](.factory/FACTORY.md) | Full playbook (spec gate, workers, merge rules). |
| [`.factory/skills/factory-loop.md`](.factory/skills/factory-loop.md) | Step-by-step loop for agents and humans. |

Selected template work uses the same shape as product repos: branch off `main`, scope limited to the issue, PR with standard sections, human gates for normal/high risk.

## Local verification before opening a PR

From the repository root, run these **before** you push (network not required):

```bash
bash scripts/test-all.sh
python3 scripts/factory-check-docs.py --strict
python3 scripts/factory-prepublic-check.py --strict
python3 scripts/factory-doctor.py --public
```

Fix any failures in the same branch. Claim a check in the PR only when command output backs it up.

## Pull request body (required fields)

Match [.github/pull_request_template.md](.github/pull_request_template.md) and the golden example [examples/sample-pr-body.md](examples/sample-pr-body.md):

| Field | Rule |
| --- | --- |
| Issue link | `Closes #N` when this PR **finishes** the issue; `Refs #N` for trackers, epics, or partial work. |
| **AI disclosure** | Single line: `AI disclosure: harness …; model <exact model ID>`. |
| **Cost** | Spend on the inference provider, or `Cost: not measured (…)` for harnesses that do not bill per token. |
| **Human review & approval** | Checkbox and name when a human product gate applies (normal/high). |

Include verification commands and evidence (test output, CI links). Workers and cloud agents **do not merge** and **do not edit** owner-only paths (below).

## Protected and owner-only paths

These are **not** for drive-by agent or contributor edits:

| Area | Policy |
| --- | --- |
| `.github/workflows/*` | Owner paste by hand only (workflow scope and supply-chain risk). |
| `PROTECTED_SCRIPTS` | Listed in `scripts/opencode-artifact-scan.sh` (`--list-protected`); cost, security, merge protection, and routing guards. |
| Other owner-only | Documented in [AGENTS.md](AGENTS.md) and [`.factory/FACTORY.md`](.factory/FACTORY.md) (e.g. `.factory/models.yaml`, `factory/budget.yml`). |

Propose workflow or protected-script changes through an issue and let a maintainer apply them.

## Questions

Open an issue with the closest form. For adoption in another repository, start with [ADOPTING.md](ADOPTING.md) and [docs/SETUP.md](docs/SETUP.md).