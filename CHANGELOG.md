# Changelog

All notable changes to this template are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The first planned tag is **v0.1.0**. It is unreleased. No tag is cut until Michael approves; see [docs/RELEASING.md](docs/RELEASING.md). Product repos cannot pin a tag until #156 lands.

### Added

- `factory/budget.yml` is owner-only (#56): the path-policy scan, `opencode.json` and the docs reject worker edits to it, and `scripts/factory-budget-vars.py` joins the protected spend/security scripts. `docs/SETUP.md` explains turning on Pages for the site workflow.
- [ADOPTING.md](ADOPTING.md): short guide for a person or an agent using the factory.
- [docs/SETUP.md](docs/SETUP.md): new-repo setup checklist (secrets, labels, branch protection, token scope, per-repo config, site hosting).
- [docs/RELEASING.md](docs/RELEASING.md): manual release checklist. Reusable workflows, pinned tags in product repos, and sync PRs remain planned (#156).
- [LICENSE](LICENSE) (MIT) and [SECURITY.md](SECURITY.md) (private vulnerability reporting), required before the repo is public (#185).
