# Software Factory

## Roles

| Role | Who / what | Does | Never |
|---|---|---|---|
| **CEO** | Michael (human owner) | Vision, chooses which issues get worked (`factory:selected`), spec approval | Configures the line repeatedly |
| **Factory Manager** | Grok Bot | Michael's single contact: triage, writes specs, starts runs | Decides product questions; merges normal/high without Michael |
| **Worker** | Harness on Actions (OpenCode + a DeepInfra model) | Executes one approved spec on a branch; opens or updates the PR | Merges; reads or prints secrets |

## Loop

1. **Intake** — GitHub issue with a one-sentence outcome. Most issues stop here.
2. **Selection** — Michael adds `factory:selected`. Only selected issues continue.
3. **Spec** — Factory Manager writes the spec.
4. **Classify** — Complexity, risk class, model, predicted cost.
5. **Spec approval** — by risk class.

## Merge authority (by design)

| Risk class | Examples | Who may merge |
|---|---|---|
| **trivial** | Typos, docs-only | Factory manager **may** merge after green required CI |
| **normal** | Features, any UI / website / pages | **Human product gate first** — do **not** auto-merge |
| **high** | License, secrets, workflows | **Human required** before merge |
