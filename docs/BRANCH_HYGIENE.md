# Branch hygiene (factory workers)

Factory workers push to prefixed branches such as `oc/issue-<N>-<run>` and `cursor/<task>-<id>`. Those branches accumulate after runs finish. This repo ships a **read-only** helper that lists safe delete candidates without touching the remote.

## Tooling

Live report (requires `gh` and network):

```bash
python3 scripts/factory-branch-cleanup.py --repo OWNER/REPO
```

Equivalent via the grouped CLI:

```bash
python3 scripts/factory-cli.py branch-cleanup --repo OWNER/REPO
```

Use fixture mode in CI and offline tests:

```bash
python3 scripts/factory-branch-cleanup.py \
  --branches-json tests/branch-cleanup/branches.json \
  --prs-json tests/branch-cleanup/prs.json \
  --now 2026-11-20T00:00:00Z
```

### Flags

| Flag | Purpose |
|---|---|
| `--prefixes` | Comma-separated factory prefixes (default `oc/,cursor/`) |
| `--older-than-days` | Stale threshold for orphan and closed-unmerged branches (default `7`; must be non-negative) |
| `--json` | Machine-readable report (`summary`, `candidates`, `kept`); keys sorted for deterministic output |
| `--now` | Fixed UTC timestamp for offline age tests |

Malformed or non-UTF-8 JSON fixtures exit with a stderr message (no Python traceback). Duplicate branch names in a fixture keep the **last** occurrence and log a stderr warning.

## What never gets flagged

- Default branch (`main` / `master` / repo default)
- `release/*` and version branches matching `v*`
- Any branch with an **open** pull request
- Non-factory branches (no matching prefix)

## Candidate categories

| Category | Meaning | Typical action |
|---|---|---|
| `merged_pr` | PR merged; branch likely redundant | Delete when CI is done |
| `closed_unmerged_old` | PR closed without merge; last commit older than threshold | Delete after confirming abandon |
| `orphan_old` | Factory prefix, no PR, stale last commit | Delete after confirming abandon |
| `keep` | Active, protected, recent, or non-factory | Leave alone |

## Safe workflow

1. Run the script (default Markdown output). Nothing is deleted.
2. Review `candidates` and spot-check any surprising branch names.
3. Copy the printed `git push origin --delete …` or `gh api -X DELETE …` lines only for branches you intend to remove.
4. Re-run after deletes to confirm counts dropped.
5. Run `bash scripts/test-factory-branch-cleanup.sh` when changing the script or fixtures.

Dry-run by default is intentional: branch deletion is irreversible on shared remotes unless your hosting provider offers recovery windows.