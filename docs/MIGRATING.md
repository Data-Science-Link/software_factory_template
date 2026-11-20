# Migrating a copied factory product repo

Use this when a product repository still carries **copied** template `scripts/`, full workflow bodies under `.github/workflows/`, and may lack `.factory/mode.yml`. The goal is thin **caller** workflows pinned to a template release tag and `mode: product`, without deleting local customizations.

Run commands from a checkout of [Data-Science-Link/software_factory_template](https://github.com/Data-Science-Link/software_factory_template) (pass `--template-dir` if needed).

## 1. Pick a template tag

Choose a released semver tag from [RELEASING.md](RELEASING.md) (for example `v0.2.0`). Product repos pin that tag on each `uses:` line and matching `factory_ref:`.

## 2. Dry-run migration plan

```bash
python3 scripts/factory-migrate-adopter.py \
  --repo-dir /path/to/product-repo \
  --tag v0.2.0
```

The default is **dry-run**: nothing in the product repo changes. The report lists:

- Scripts byte-identical to the template (safe to retire after callers work)
- Scripts with the same name but local edits (kept; review manually)
- Product-only scripts (never touched)
- Legacy copied workflows vs existing thin callers
- Missing caller stubs and recommended `mode: product`

Add `--json` for machine-readable output.

## 3. Apply local-safe changes

```bash
python3 scripts/factory-migrate-adopter.py \
  --repo-dir /path/to/product-repo \
  --tag v0.2.0 \
  --apply
```

This writes:

- `.factory/mode.yml` with `mode: product` when missing or unreadable (use `--force` to replace a non-product mode)
- Ready-to-paste caller YAML under `.factory/migration-callers/` (pinned to `--tag`)

It does **not** modify `.github/workflows/` unless you pass `--write-workflows` (owner risk).

## 4. Owner paste workflows

Copy each file from `.factory/migration-callers/` into `.github/workflows/` (replace legacy copies). Adjust `YOUR_OWNER_GITHUB_LOGIN` per [reusable-workflows/README.md](reusable-workflows/README.md).

Validate with:

```bash
python3 scripts/factory-doctor.py --repo-dir /path/to/product-repo
python3 scripts/factory-audit-workflows.py --strict
```

## 5. Retire identical script copies

After callers are green on CI, archive byte-identical script copies:

```bash
python3 scripts/factory-migrate-adopter.py \
  --repo-dir /path/to/product-repo \
  --tag v0.2.0 \
  --apply --prune-identical
```

Identical template scripts move to `.factory/migration-archive/scripts/`. Customized and product-only scripts stay in `scripts/`.

## 6. Ongoing tag bumps

Use `scripts/factory-sync-repos.py` to open sync PRs that bump pins across adopters. See [OWNER_WORKFLOW_SYNC.md](OWNER_WORKFLOW_SYNC.md).

## Tests

```bash
bash scripts/test-factory-migrate-adopter.sh
```

## Flags (summary)

| Flag | Meaning |
| --- | --- |
| `--repo-dir` | Product repo root (required) |
| `--tag` | Semver pin `vX.Y.Z` (required format) |
| `--template-repo` | Default `Data-Science-Link/software_factory_template` |
| `--template-dir` | Local template checkout for SHA compares (default: this repo) |
| `--apply` | Write mode.yml and migration-callers (default: dry-run only) |
| `--force` | Overwrite migration-callers; replace non-product mode.yml |
| `--prune-identical` | With `--apply`, archive identical script copies |
| `--write-workflows` | With `--apply`, write `.github/workflows/` stubs |
| `--json` | JSON report on stdout |