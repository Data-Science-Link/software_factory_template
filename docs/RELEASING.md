# Release checklist

This template is versioned with semver tags (`v0.1.0` and up) so a product repo can pin an exact release. **No tag is cut until the owner approves.** The first tag a product repo pins also waits for the #156 pilot (reusable workflows live in `.github/workflows/` on the template and one product repo verified end to end).

See [CHANGELOG.md](../CHANGELOG.md) for the notes.

## Before you tag

- [ ] The owner has approved cutting this tag (and, for the first product pin, the #156 pilot gate is understood).
- [ ] Reusable workflow bodies are pasted into `.github/workflows/reusable-*.yml` from [docs/reusable-workflows/](reusable-workflows/README.md) when this release changes workflow behavior.
- [ ] The commit to tag is on `main`.
- [ ] `main` is green on that commit: `pr-check`, `run-records`, and `gitleaks` all passed.
- [ ] [CHANGELOG.md](../CHANGELOG.md) has a section for this version. Move the relevant items out of Unreleased and put the release date on the heading only when the tag is actually cut.
- [ ] The notes say what changed and, if anything, what a product repo has to do after it picks up the tag.

## Cut the tag (owner, after the approval above)

1. Tag the agreed commit with an annotated semver tag, for example `v0.1.0`. Do not retag or move a published tag.
2. Push the tag to GitHub and write the GitHub Release notes from the changelog section.
3. Leave a short note on the release (or on #156) about what product repos must change.

## Product repo pins

A product repo keeps thin caller workflows (see [docs/reusable-workflows/callers/](reusable-workflows/callers/)) that call the template at a pinned tag, for example:

```
uses: Data-Science-Link/software_factory_template/.github/workflows/reusable-opencode-fix.yml@v0.1.0
```

with matching `factory_ref: v0.1.0`. Scripts and shared factory files are fetched at that tag during the run.

## Bump product repos after a new tag

1. Maintain a newline-separated repo list (for example `factory/adopters.txt`, one `owner/repo` per line).
2. Run a dry run from a machine with `gh` authenticated as someone who can push branches to each product repo:

   ```bash
   python3 scripts/factory-sync-repos.py --repos-file factory/adopters.txt --tag v0.2.0 --dry-run
   ```

3. Open or update sync PRs:

   ```bash
   python3 scripts/factory-sync-repos.py --repos-file factory/adopters.txt --tag v0.2.0
   ```

4. The owner merges or holds each sync PR. **Rollback** in a product repo is revert the sync PR (one pin line per caller workflow).

Validate the paste templates any time with:

```bash
bash scripts/test-reusable-workflows.sh
```