# Release checklist

This template is versioned with semver tags (`v0.1.0` and up) so a product repo can pin an exact release. **No tag is cut until Michael approves.** The first tag also waits for the #156 gate before product repos pin it.

See [CHANGELOG.md](../CHANGELOG.md) for the notes. Pinning, reusable workflows, and automatic sync PRs are **planned (#156)**; this page is the manual process.

## Before you tag

- [ ] Michael has approved cutting this tag (and, for the first tag, the #156 gate is understood: five straight successful worker builds, plus #174 passing).
- [ ] The commit to tag is on `main`.
- [ ] `main` is green on that commit: `pr-check`, `run-records`, and `gitleaks` all passed.
- [ ] [CHANGELOG.md](../CHANGELOG.md) has a section for this version. Move the relevant items out of Unreleased and put the release date on the heading only when the tag is actually cut.
- [ ] The notes say what changed and, if anything, what a product repo has to do after it picks up the tag.

## Cut the tag (owner, after the approval above)

1. Tag the agreed commit with an annotated semver tag, for example `v0.1.0`. Do not retag or move a published tag.
2. Push the tag to GitHub and write the GitHub Release notes from the changelog section.
3. Leave a short note on the release (or on #156 / #181) about what product repos must change.

Until #156 lands, product repos still copy factory files; a new tag is a signal to copy again, not an automatic update.

## After #156 (planned)

A product repo will pin the template's reusable workflows at a tag, for example:

```
uses: Data-Science-Link/software_factory_template/.github/workflows/opencode-fix.yml@v0.1.0
```

Scripts will be fetched at that same tag. Updating a product repo is usually a one-line pin bump in a **sync PR** the owner approves or holds. Rollback is reverting that line. Automatic sync PRs are part of #156; until then, the bump is manual.
