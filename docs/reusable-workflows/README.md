# Reusable factory workflows (single management)

Product repositories stop copying factory `scripts/`, shared `.factory/` skills, and workflow bodies. They keep thin caller workflows under `.github/workflows/` that invoke versioned reusable workflows in this template repository. At run time the reusable workflow checks out this template at the pinned tag and installs tooling into the product workspace; secrets stay in the product repo and flow through `secrets: inherit`.

## Layout

| Path | Purpose |
|------|---------|
| `reusable-*.yml` | Owner-paste bodies for `.github/workflows/reusable-*.yml` **in this template repo** (`on: workflow_call`). |
| `callers/*.yml` | Owner-paste thin triggers for **product** repos (issue comment, pull request, push, and so on). |

Callers pin a semver tag on both the `uses:` line and `with.factory_ref`, for example `@v0.1.0` and `factory_ref: v0.1.0`.

## Owner steps (template repo)

1. Paste each file from `docs/reusable-workflows/reusable-*.yml` into `.github/workflows/` with the same filename (workflow scope required).
2. Cut an annotated semver tag when [RELEASING.md](../RELEASING.md) is satisfied and required checks are green.
3. While this repository is **private**, set **Settings → Actions → General → Access** to allow workflows to be used by other repositories owned by the same account. That requirement goes away after the template is public (see security baseline #44).

## Owner steps (product repo)

1. Remove copied factory `scripts/` and shared `.factory/` trees (keep per-repo config only; see below).
2. Paste the matching files from `docs/reusable-workflows/callers/` into `.github/workflows/`.
3. Replace every `YOUR_OWNER_GITHUB_LOGIN` with the account that may run `/oc` commands, and `YOUR_ORG` with the org or user that owns the template repository.
4. Set `DEEPINFRA_API_KEY` and repo variable `FACTORY_DEEPINFRA_KEY_NAME` in the product repo (names only; never commit values).
5. Align the pinned tag on each `uses:` line and matching `factory_ref:` with the template release you want.

## What stays local in a product repo

- `.factory/models.yaml` overrides (if any) and product-specific specs under `factory/specs/`
- `AGENTS.md`, product `DECISIONS.md`, and application source
- GitHub secrets and variables for that repo

Shared factory method files (`FACTORY.md`, skills, `scripts/`, and so on) are fetched from the template tag at workflow run time.

## Rollback

Revert the sync PR that bumped the pinned tag (one line per caller workflow). No other product-repo edits are required.

## Tag bump sync

After a new template tag, run `scripts/factory-sync-repos.py` with a repo list and target tag to open (or update) one sync PR per product repository. See [RELEASING.md](../RELEASING.md).

## Offline contract check

Before cutting a release tag or opening a sync PR, validate that each `reusable-*.yml` template and its paired `callers/<name>.yml` agree on pins, `workflow_call` inputs and secrets, and least-privilege `permissions:`:

```bash
python3 scripts/factory-reusable-check.py --strict
```

Use `--json` for machine-readable output, or `--dir <path>` to lint a fixture tree (see `scripts/test-factory-reusable-check.sh`).

Callers keep `YOUR_ORG/software_factory_template` on the `uses:` line; reusable bodies use `"{{TEMPLATE_REPO}}"` for template checkout steps. `scripts/factory-init-repo.py` and `scripts/factory-migrate-adopter.py` substitute the real `org/repo` at scaffold time.