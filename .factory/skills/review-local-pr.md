# Skill: review-local-pr

**For the reviewing bot:** the repo's Factory Manager (or the Builder on the template repo). Use it on every PR from a local agent, after the PR check has run and before the human merge gate. The review lives on the PR, so the owner never copies notes by hand.

## Steps

1. Read the issue: `gh issue view N --comments` (outcome, scope list, done checks, handoff block).
2. Read the PR: `gh pr view P --comments` and `gh pr diff P`. Note the PR check and secret scan results (`gh pr checks P`). If the PR changes `scripts/pr-check.sh`, run `bash scripts/test-pr-check.sh` and check it passes.
3. Compare and note each miss:
   - **Scope:** only the files the issue lists change; nothing extra.
   - **Done checks:** each one is ticked in the PR body and actually true in the diff or evidence.
   - **PR body:** `Closes #N` or `Refs #N`, `AI disclosure: harness <name>; model <model ID>`, a `Cost:` line for Local open-weights runs, risk class, evidence (screenshots for UI).
   - **Rules:** `FACTORY.md` and `liability-gates.md` (no secrets, no workflow or merge-rule changes the issue didn't ask for, no over-claims).
4. Post **one** PR comment, headed `Factory review`, in the format below. A later round posts a new comment (`Factory review (round 2)`) instead of editing the old one.
5. Tell the owner in one line: pass, or fix with the item count and the PR link.

Each fix item is an instruction the agent can act on alone: what to change, in which file, and how to tell it's done. Leave anything that needs the owner's judgment out of the fix list and put it under "For the owner".

Never push to the branch, edit the PR body, approve or merge. The review is a comment only.

## Comment format

```
Factory review

Verdict: fix (3 items)    <- or: pass

Fixes for the agent (address the review on PR #P):
1. <file or PR body>: <what to change>. Done when <check>.
2. ...

Checked: scope, done checks, PR body, FACTORY.md rules, CI (PR check, secret scan).
For the owner: <judgment calls, or "nothing">
```

## Sample

```
Factory review

Verdict: fix (3 items)

Fixes for the agent (address the review on PR #12):
1. PR body: add the Cost line from the provider's usage page, e.g. "Cost: $0.05 on DeepInfra". Done when the PR check passes.
2. README.md: the issue asks for one Quickstart line; the PR adds a whole section. Cut it back to one line under Quickstart. Done when the README diff is one added line.
3. PR body: done check 2 ("test commit with a fake key is blocked") is ticked but there's no evidence. Paste the blocked commit output (secret shown as REDACTED) under Evidence, or untick it.

Checked: scope, done checks, PR body, FACTORY.md rules, CI (PR check failing on item 1; secret scan green).
For the owner: nothing.
```
