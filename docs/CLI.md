# Factory CLI

Single entrypoint for offline factory maintenance scripts:

```bash
python3 scripts/factory-cli.py <command> [args...]
```

Run `python3 scripts/factory-cli.py --help` for a grouped command list with script availability, or `python3 scripts/factory-cli.py list --json` for machine-readable output.

## Setup & Health

| Command | Example |
|---------|---------|
| `doctor` | `python3 scripts/factory-cli.py doctor --repo-dir .` |
| `init` | `python3 scripts/factory-cli.py init --target /path/to/product` |
| `models-check` | `python3 scripts/factory-cli.py models-check --models-yaml .factory/models.yaml` |
| `model-scout` | `python3 scripts/factory-cli.py model-scout --catalog tests/model-scout/catalog-no-change.json` |

## Planning & Specs

| Command | Example |
|---------|---------|
| `triage` | `python3 scripts/factory-cli.py triage --issues-json tests/factory-triage/backlog.json` |
| `spec-lint` | `python3 scripts/factory-cli.py spec-lint factory/specs/issue-1.md` |
| `spec-check` | `python3 scripts/factory-cli.py spec-check factory/specs/issue-1.md` |
| `backlog` | `python3 scripts/factory-cli.py backlog --from-json tests/factory-triage/backlog.json --out /tmp/backlog.json` |
| `decision-log` | `python3 scripts/factory-cli.py decision-log check --file .factory/DECISIONS.md` |

## Build & Review

| Command | Example |
|---------|---------|
| `run-review` | `python3 scripts/factory-cli.py run-review --input tests/factory-run-review/run-verification-fail.json` |
| `fix-policy` | `python3 scripts/factory-cli.py fix-policy --issue 42 --repo-dir .` |
| `audit-workflows` | `python3 scripts/factory-cli.py audit-workflows --repo-dir .` |
| `check-docs` | `python3 scripts/factory-cli.py check-docs` |
| `critic-context` | `python3 scripts/factory-cli.py critic-context --from-json tests/critic-context/pass.json --out-dir /tmp/critic-out` |
| `critic-run` | `python3 scripts/factory-cli.py critic-run --print-model --coder-model example/model --input /tmp/critic-out/critic-input.md` |
| `test-all` | `python3 scripts/factory-cli.py test-all` |

## Spend & Site

| Command | Example |
|---------|---------|
| `cost-digest` | `python3 scripts/factory-cli.py cost-digest --runs-dir tests/factory-cost-digest/fixture-runs` |
| `cost-reconcile` | `python3 scripts/factory-cli.py cost-reconcile --runs-dir tests/cost-reconcile --models-yaml tests/cost-reconcile/models-fixture.yaml --json` |
| `predict-cost` | `python3 scripts/factory-cli.py predict-cost factory/specs/issue-1.md` |
| `routing-report` | `python3 scripts/factory-cli.py routing-report --runs-dir tests/cost-reconcile` |
| `cache-report` | `python3 scripts/factory-cli.py cache-report --runs-dir factory/runs` |
| `monthly-review` | `python3 scripts/factory-cli.py monthly-review --runs-dir examples/sample-runs --as-of 2026-11-20` |
| `site` | `python3 scripts/factory-cli.py site --out /tmp/site --data /tmp/site-data` |
| `site-smoke` | `python3 scripts/factory-cli.py site-smoke tests/site-smoke/raw-bold` |

## Release & Ops

| Command | Example |
|---------|---------|
| `prepublic` | `python3 scripts/factory-cli.py prepublic` |
| `branch-cleanup` | `python3 scripts/factory-cli.py branch-cleanup --branches-json tests/branch-cleanup/branches.json --prs-json tests/branch-cleanup/prs.json` |
| `release` | `python3 scripts/factory-cli.py release --dry-run` |
| `sync-repos` | `python3 scripts/factory-cli.py sync-repos --list factory/adopters.txt --dry-run` |
| `reusable-check` | `python3 scripts/factory-cli.py reusable-check --strict` |
| `migrate-adopter` | `python3 scripts/factory-cli.py migrate-adopter --repo-dir /path/to/product --tag v0.1.0` |
| `owner-pack` | `python3 scripts/factory-cli.py owner-pack --version v0.1.0` |

All flags after the subcommand are passed through to the underlying script unchanged.