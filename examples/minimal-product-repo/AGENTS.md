# AGENTS.md

Short pointer for agents in an adopted **product** repo.

- Work enters as GitHub issues only; humans keep merge gates.
- Read factory loop and liability gates on the **pinned template tag**; keep local config under `.factory/` (mode, models, decisions).
- Ship on a feature branch with `Closes #N` or `Refs #N`; never merge without human approval for normal/high risk.
- Do not edit owner-only paths (`.factory/models.yaml`, workflows, guardrail scripts listed on the pinned tag).