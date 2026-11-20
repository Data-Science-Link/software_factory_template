# One-command product repo bootstrap

Scaffold a **product** repository to adopt the Software Factory without copying the full template tree. The bootstrap writes only local config, docs starters, and (by default) thin GitHub Actions **caller** stubs that pin a release tag on the template repo (#156).

Run this from a checkout of [Data-Science-Link/software_factory_template](https://github.com/Data-Science-Link/software_factory_template) (or pass `--template-dir`).

## Command

```bash
python3 scripts/factory-init-repo.py --target /path/to/product-repo
```

### Flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `--target` | (required) | Product repo root to create or update |
| `--tag` | `v0.1.0` | Semver tag pinned in caller stubs |
| `--repo-name` | basename of `--target` | Name used in `AGENTS.md` and `DECISIONS.md` |
| `--template-repo` | `Data-Science-Link/software_factory_template` | Upstream factory template |
| `--template-dir` | parent of `scripts/` | Template checkout used to copy the PR template and caller sources |
| `--dry-run` | off | Print planned files; write nothing |
| `--force` | off | Overwrite files this tool would create (never touches unknown paths) |
| `--with-callers` / `--no-with-callers` | callers on | Write `.github/workflows/*.yml` caller stubs |

## What it creates

| Path | Purpose |
| --- | --- |
| `.factory/mode.yml` | `mode: product` |
| `.factory/models.yaml` | Starter budget caps + minimal model row (owner-only) |
| `.factory/DECISIONS.md` | Append-only log with a dated adoption entry |
| `AGENTS.md` | Standing agent rules + toolchain registry template |
| `docs/specs/.gitkeep` | Placeholder for product specs |
| `.github/pull_request_template.md` | Copied from the template |
| `.github/dependabot.yml` | Weekly GitHub Actions updates (if missing) |
| `.github/workflows/*.yml` | Caller stubs → `reusable-*.yml@<tag>` with `secrets: inherit` |

If `docs/reusable-workflows/callers/` exists in the template checkout, those files are copied with `{{TEMPLATE_REPO}}` / `{{TAG}}` substitution. Otherwise the script emits minimal caller stubs for `pr-check`, `secret-scan`, OpenCode workflows, and `approve-oc-runs`.

## Examples

Initialize a new clone directory with a specific pin:

```bash
python3 scripts/factory-init-repo.py \
  --target ../my-product \
  --tag v0.2.0 \
  --repo-name my-product
```

Preview without writing:

```bash
python3 scripts/factory-init-repo.py --target ../my-product --dry-run
```

Config only (no workflow callers):

```bash
python3 scripts/factory-init-repo.py --target ../my-product --no-with-callers
```

Re-apply generated files after editing the template pin:

```bash
python3 scripts/factory-init-repo.py --target ../my-product --tag v0.3.0 --force
```

## After init (owner)

The script prints these steps; they are not automated:

1. Add the `DEEPINFRA_API_KEY` Actions secret (and `FACTORY_DEEPINFRA_KEY_NAME` repo variable). See [SETUP.md](SETUP.md).
2. Run `bash scripts/harden-repo.sh` once with admin rights (branch protection and security baseline; [#37](https://github.com/Data-Science-Link/software_factory_template/issues/37)).
3. Run `python3 scripts/factory-doctor.py --repo-dir /path/to/product-repo` and fix any failures. Add `LICENSE` and `SECURITY.md` before using `--strict`.

## Tests

```bash
bash scripts/test-factory-init-repo.sh
bash scripts/test-factory-doctor.sh
```

Related: [SETUP.md](SETUP.md), [DOCTOR.md](DOCTOR.md), [RELEASING.md](RELEASING.md). Issues [#178](https://github.com/Data-Science-Link/software_factory_template/issues/178), [#156](https://github.com/Data-Science-Link/software_factory_template/issues/156), [#37](https://github.com/Data-Science-Link/software_factory_template/issues/37).