# Software Factory

## Roles

| Role | Who / what | Does | Never |
|---|---|---|---|
| **CEO** | Michael (human owner) | Vision, chooses which issues get worked | <script>alert(1)</script> |
| **Worker** | Harness on Actions | Executes one approved spec; opens the PR | <img src=x onerror=alert(1)> |

## Loop

1. **Intake** — GitHub issue with a one-sentence outcome. Most issues stop here.
2. **Selection** — Michael adds `factory:selected`.
3. **Spec** — Factory Manager writes the spec.

## Merge authority (by design)

| Risk class | Examples | Who may merge |
|---|---|---|
| **trivial** | Typos, docs-only | Factory manager **may** merge after green required CI |
| **normal** | Features, any UI / website / pages | **Human product gate first** — do **not** auto-merge |
