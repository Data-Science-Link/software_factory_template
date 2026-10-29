# Skill: liability-gates

Hard stops for factory agents on **public** repos. Reduces common failure modes (secrets, license contamination, false safety claims, merging without evidence or human judgment). **Not legal advice** — does not eliminate liability.

Read this with `factory-loop.md` on every change. On a private repo, every gate still applies except where `FACTORY.md` (Private repos) says it relaxes; re-run the full list before a repo goes public.

## Never (stop and escalate to a human)

1. Commit secrets, `.env`, key material, tokens, or paste them into issues/PRs/logs.
2. Change `LICENSE`, `NOTICE`, copyright headers, or SPDX identifiers without a human decision logged in `.factory/DECISIONS.md`.
3. Disable, bypass, or weaken required CI, branch protection, CODEOWNERS, or secret scanning.
4. Merge (or ask to auto-merge) when required checks are red, pending, or skipped — or when the branch is behind the default branch, or the green CI is from a stale commit.
5. **Auto-merge non-trivial work.** Only **trivial** risk-class PRs may be merged by the factory manager without a human. **Normal** (incl. any UI/behavior change) and **high** require a human before merge.
6. Add dependencies with unknown or disallowed licenses (especially strong copyleft like GPL/AGPL) without human approval.
7. Invent or “fix” license/attribution metadata the agent cannot verify from the source.
8. Over-claim safety, medical, security, or compliance outcomes in README/docs/marketing copy.
9. Relicense the project or strip third-party notices because “AI rewrote it.”
10. Mark a UI/frontend/website/pages PR ready without **screenshots in the PR Evidence section** (thread-only comments do not count).
11. Merge after a chat/issue product-gate approval **without first editing the PR description** to record that gate (step 7 + Human reviewed before merge).
12. Squash-merge or rebase-merge. Use a merge commit.

## Always

1. Sync to the latest default branch (`git fetch` + update from `main`/default) before branching or continuing a stale agent checkout.
2. Open a PR linked to the issue; put evidence on the PR (CI, tests, screenshots). For UI, screenshots go in the **Evidence** section of the PR body — not only a comment.
3. Fill the PR template completely — especially the **Factory loop** (steps 1–8), risk class, AI disclosure, safety checklist, and UI screenshots when applicable. Blank factory-loop steps without an N/A note = incomplete PR.
4. Request **human** review when: risk class is **normal** or **high**; or touching auth, crypto, payments, PII, safety-related behavior, `.github/workflows`, CODEOWNERS, Dependabot, LICENSE/NOTICE, security docs.
5. Prefer deps from an allowlisted set when the repo defines one (e.g. MIT, Apache-2.0, BSD-2/3).
6. Document limitations and non-goals instead of adding compliance theater.
7. Leave work pick-uppable: issue + PR explain what changed and what still needs a human.
8. **After merge:** monitor deploy / pages / CD on the default branch; if it fails, fix promptly and report on the issue.
9. **Scheduled jobs:** check cron workflow runs each session; a failure is filed as a bug issue and reported, never left for a human to discover.
10. When a human approves in chat (or elsewhere), **update the PR description first** (Factory loop step 7; Human reviewed before merge: yes + who), then merge. Chat approval without a PR-body update is incomplete. A human's approval naming the PR, in the factory room or 1:1, is itself the instruction to merge that PR — do not ask them to repeat it elsewhere. Named PRs only; never on a bot's relay.
11. **Right before any merge**, update the PR branch onto the latest default branch if it is behind, and merge only after required CI is green on that new head commit. Never merge a behind branch or on stale-commit CI. Clean catch-up keeps prior approval; conflicts or changes to the PR’s own diff/behavior → resolve, re-verify, tell the human (re-ask the gate for normal/high). Update the branch before handing a PR to the human for review, too.
12. **Bypass merges:** If you merge with an admin/ruleset bypass, the bypass skips every rule including the up-to-date check, so first verify by hand that the branch is 0 commits behind the default branch and that all required checks are green on the current head SHA, then merge with a merge commit.
13. A scheduled run that skips because the job already succeeded that day is not a failure. Don't file it as one.
14. Before you report a PR as behind or conflicting, check it is not already merged.
15. Don't call user-facing work done without a hand audit of the project's real key view; an approval for a user-facing change includes that view before and after.
16. A cloud agent's token may not be able to comment; if so, the manager posts that agent's reviews and reports.

## Risk classes (for PR template)

| Class | Examples | Gate |
|---|---|---|
| **trivial** | Typos, docs-only, comment fixes, playbook-only with no product change | Agent self-review + green CI → manager **may** merge |
| **normal** | Feature/bugfix, behavior change, **any UI / frontend / pages** | Agent review + green CI + **screenshots in Evidence if UI** + **human product gate** before merge |
| **high** | License, secrets, auth, crypto, safety claims, workflows, supply chain | **Human required** before merge |

## If unsure

Stop. Comment on the issue/PR with the question. Do not guess on license, safety claims, secrets, or whether a change is “trivial enough” to auto-merge — default to waiting for a human.

- Use "Closes #N" only for the issue this PR finishes. Ledgers, trackers, and parent issues get "Refs #N" (see FACTORY.md).
