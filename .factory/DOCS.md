# Repo documentation map

Pointers only — do not duplicate long docs here. Update paths when you drop this folder into a real repo.

| Topic | Path | Notes |
|---|---|---|
| Overview / setup | `README.md` | include limitations / non-goals |
| License | `LICENSE` | required on public repos |
| Security policy | `SECURITY.md` | real contact; monitor it |
| Contributing / factory | `CONTRIBUTING.md` | copy from `.factory/sketches/CONTRIBUTING.md` |
| PR template | `.github/pull_request_template.md` | copy from sketches |
| Code owners | `.github/CODEOWNERS` | copy from sketches; set handles |
| Architecture | `docs/architecture.md` | create or retarget |
| How to run tests / CI | *(fill in)* | agents need this for verify |
| Deploy / release | *(fill in)* | |
| Domain / product glossary | *(fill in)* | |
| Liability research (optional) | *(external)* | see Software Factory Builder notes; not legal advice |

Agents: read this map, then open the linked files. Prefer linking over pasting.

## Secrets available to agents

<!-- Fill per repo. Names only, never values. Lets the manager know what a build or test can actually exercise before merge. -->

| Secret (name only) | CI / pipeline | Cloud agents | Manager's own machine | Notes |
| --- | --- | --- | --- | --- |
| | | | | |

## Key view and health numbers (fill per repo)

- **Key view:** what users see first (e.g. top 10 items). Shown before/after on user-facing PRs and hand-audited before a done claim.
- **Headline health numbers:** 2–4 numbers the daily check reports (e.g. items published, items hidden or dropped, items shown correctly).
