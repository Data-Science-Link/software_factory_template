# Release checklist (factory-release.py)

Use `python3 scripts/factory-release.py` for a read-only release scorecard. It never tags, pushes, or opens a release — it only validates state and prints the exact owner commands.

## Five-step flow

1. **Pick the version** — semver tag `vMAJOR.MINOR.PATCH` (example: `v0.1.0`). Move the relevant [CHANGELOG.md](../CHANGELOG.md) items out of `[Unreleased]` into a `[X.Y.Z]` section before you cut the tag; add the release date to the heading when the tag lands.

2. **Run the helper (strict)** — from a clean working tree on the commit you intend to tag:

   ```bash
   python3 scripts/factory-release.py --version v0.1.0 --strict
   ```

   Fix any failing checks (semver, changelog section, dirty tree, duplicate tag). When `scripts/factory-doctor.py` or `scripts/test-reusable-workflows.sh` exist, their results are folded into the same scorecard.

3. **Draft notes (optional)** — generate a Keep a Changelog–style section from commits since the previous tag:

   ```bash
   python3 scripts/factory-release.py --version v0.1.0 --draft-changelog
   ```

   Copy the draft into `CHANGELOG.md` and edit as needed.

4. **Confirm CI** — `main` should be green on that commit (`pr-check`, `run-records`, `gitleaks`). See [RELEASING.md](RELEASING.md) for approval and #156 gates before the first public tag.

5. **Cut the release (owner)** — run the commands printed at the bottom of the helper output: annotated tag, push tag, `gh release create`, and `python3 scripts/factory-sync-repos.py --tag <tag> --dry-run` when that script is available. Product repos update pins or sync PRs per [RELEASING.md](RELEASING.md).

## JSON for automation

```bash
python3 scripts/factory-release.py --version v0.1.0 --json --strict
```

Offline tests: `bash scripts/test-factory-release.sh`.