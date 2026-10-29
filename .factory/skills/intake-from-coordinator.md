# Skill: intake-from-coordinator

Use when someone messages the **project coordinator** (chief of staff, project lead bot, or other designated intake agent) with work that belongs in the factory.

This skill **starts the production line**: create the GitHub issue, then hand off to the factory manager. Do not leave the ask sitting only in chat.

## Job

1. Turn the ask into a **GitHub issue**.
2. **Hand off** to the repo’s factory manager to run `factory-loop` on that issue.

Do not implement the feature in the coordinator chat.

## Steps

1. Confirm the target repo (and labels if used).
2. Create or refine one issue: title (outcome), body (context, constraints, done-when), links. When it's ready to work, add the **handoff block** (see `factory-loop.md` → Triage), including its `Model: Cursor … · Local open-weights …` line and the cloud-vs-local lines under it (cloud agents ignore the Local open-weights model; local agents use it and follow `local-open-weights-run.md`).
3. Reply in chat with the issue URL.
4. **Kick the line:** message the factory manager (same room, SendToAgent, or project convention) with the issue URL and “run factory-loop.” If you *are* also the manager for this repo, start `factory-loop` yourself after filing.
5. Coordinator stops building; manager owns triage → PR → verify.

## Rules

- Chat clarifies; the **issue** is the work item; the **handoff** is what makes coordinator-chat a trigger.
- Don’t duplicate an existing issue — comment or refine it, then hand off that issue.
- Fuzzy scope: still file the issue; mark what needs a human before build; hand off anyway so the manager can stop at the spec gate.
