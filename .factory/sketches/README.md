# Sketches (copy into the repo — not used from `.factory/` automatically)

Portable starters for a **product** repo adopting the factory. After copying `.factory/` (or running `python3 scripts/factory-init-repo.py` from a template checkout):

| Sketch | Copy to |
|---|---|
| `CONTRIBUTING.md` | repo root `CONTRIBUTING.md` |
| `github/pull_request_template.md` | `.github/pull_request_template.md` (live copy in the template repo; keep sketch in sync) |
| `github/CODEOWNERS.example` | `.github/CODEOWNERS` (edit owners) |

Also ensure the repo has a real `LICENSE` and `SECURITY.md` at the root (not shipped here — choose your license deliberately).

Pin reusable workflow callers at an approved semver tag (for example `v0.1.0` on `YOUR_ORG/software_factory_template`) per [docs/RELEASING.md](../../docs/RELEASING.md).

Point `.factory/DOCS.md` at these once copied.