# Skill: factory-loop

Run when an **open GitHub issue** should move through the factory — including after a coordinator handoff (`intake-from-coordinator.md`).

Also follow `liability-gates.md` on every change.

## Before you start

1. **Sync to latest default branch** before you branch or push. Cursor cloud agents (and local checkouts) can be slightly stale — fetch and rebase/merge onto current `main` (or the repo’s default branch) first; do not build on an outdated tip.
2. Read `.factory/FACTORY.md`, `.factory/DOCS.md`, `.factory/skills/liability-gates.md`, and recent `.factory/DECISIONS.md`.
3. Open the issue. Ensure a one-sentence outcome is visible (comment if needed). If still unclear, ask once on the issue — then stop guessing.

## Triage

- **Easy** — clear, low risk: skip specs; branch and implement.
- **Hard** — write short product + technical specs on the issue (or linked files); wait for human approval before coding.
- **High-risk** (license, secrets, auth, crypto, safety, workflows): treat as hard; human review required before merge.
- Assign a **risk class** on the PR: `trivial` | `normal` | `high` (see merge authority).
- **Rate complexity, then pick the model** (required before any launch). Post a one-line triage note on the issue: `Complexity: simple | standard | complex — <reason>; Risk: trivial | normal | high; Model: <pinned model + effort>`. Complexity picks the model; risk class alone decides the merge gate. Never use risk words (trivial/normal/high) for complexity. Judge by what the change touches, not its size (workflows, algorithms, data stores, spend paths, security, multi-file logic are **complex**). Then pick the model from the full `.factory/MODEL_ROUTING.md` table — its writing, review, escalation and stuck rows included — not a two-model shortcut. Pin the model on every cloud-agent launch, including restarts and reviews (never Auto, never Fast). An unpinned or mismatched launch is stopped and relaunched pinned. Copy the triage line into the PR body.
- **Handoff block** on every ready-to-work issue, so any agent or harness (including a Local open-weights run, `local-open-weights-run.md`) can pick it up:
  ```
  Goal: <one sentence>
  Prompt: Read issue #N with `gh issue view N` and `.factory/FACTORY.md` first. <self-contained prompt: repo, issue #, what to change, constraints; sync latest default branch, branch, open a PR that references the issue, fill the PR template>. Tick the done checks in the PR body as you finish them.
  Read first: <paths on the current default branch, e.g. FACTORY.md, DOCS.md, relevant docs or style guides>
  Done checks: <acceptance checks>
  Complexity: S | M | L (simple | standard | complex); Risk: trivial | normal | high
  Budget: target < $0.10 (S/M); complex may scale up; hard cap $1 per issue (Local open-weights spend)
  Model: Cursor `<model>` · Local open-weights `<provider model ID; default Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo>` (MODEL_ROUTING.md)
  Cloud agents: ignore the Local open-weights line and use the model you were launched with.
  Local agents (Cursor desktop or another harness on the human's machine using an open-weights provider such as DeepInfra): use the Local open-weights model named above and follow skills/local-open-weights-run.md.
  ```
  Triage scopes each issue to hit the budget target and splits any issue likely to cost more than $1 into smaller issues.

## Build

- Branch from default; open a PR that references the issue.
- Run at most 4 coding agents at once (or the repo's number in DECISIONS); keep a restart list on the issue (running agent, branch, next step). Outside coding agents follow this same loop and need the owner's cost yes first (see FACTORY.md Rules).
- Stay inside issue scope. Lasting choices → `.factory/DECISIONS.md`.
- Follow repo conventions via `.factory/DOCS.md` and any repo-specific skills here.
- **Fill the whole PR template**, especially the **Factory loop** section (steps 1–8). That checklist is how humans audit process adherence — leave it blank only if a step is truly N/A, with a one-line note.
- Fill risk class, AI disclosure, safety checklist, evidence, and — for Local open-weights PRs — a `Cost:` line (from `scripts/factory-cost.sh end N`) and a `Caching:` line.
- **UI / frontend / website / pages:** put screenshots in the PR **Evidence** section of the description (embed or link; before/after when practical). Thread-only comments do **not** count. No Evidence screenshots → do not treat the PR as ready.

## Review & verify

- Self-review against the issue outcome / specs and `liability-gates.md`.
- A cloud agent's token may not be able to comment; if so, the manager posts that agent's reviews and reports.
- Run tests/CI; put evidence on the PR (CI links, tests, **screenshots for UI**).
- Any user-facing output change shows the project's key view (defined in `DOCS.md`, e.g. the top 10 items readers see first) before and after, before approval. A done claim on user-facing work waits for a hand audit of that real key view.
- A done bar or revert trigger is printed in the run log, has a written baseline definition, and its script/query is committed; it must first catch every case the human flagged by hand, with a hand-checked sample for misses and false alarms. A noisy metric is a hand-check flag list, not an auto-revert trigger (see FACTORY.md Verify).
- Save evidence under a path keyed to the head commit it shows; retake only if a catch-up touches front-end files or the PR's own diff.
- Tests never pair a hardcoded date with the real clock; freeze the clock and test edge dates on purpose.
- Quality or guard fixes are scored (raw N of M) on a fresh sample they weren't built from before they're called done.
- A reporting or check change can't mute a recurring fault without a linked root-cause issue.
- Do not merge if required CI is red, pending, or skipped.

### Merge authority (do not invent exceptions)

| Class | Merge rule |
|---|---|
| **trivial** | Typos, docs-only, comment-only, pure `.factory/` playbook with **no** product/behavior change. Manager **may** merge after green required CI. |
| **normal** | Features, bugfixes, behavior changes, **any UI**. **Wait for human product gate** — never auto-merge. |
| **high** | License/secrets/auth/crypto/safety/workflows/CODEOWNERS/supply chain. **Human required** before merge. |

If unsure → **normal** (wait for human). A PR that changes merge authority or approval rules is never trivial risk. Behavior changes (e.g. clustering thresholds, defaults users feel) are **normal**, not trivial.

### Record the human gate on the PR (required)

When a human gives product-gate (or similar) approval in **chat**, on the issue, or elsewhere:

1. **Edit the PR description before you merge** — do not merge on chat approval alone.
   - A human approver's "approve #N" (naming the PR) in the factory room or a 1:1 chat is a direct instruction to merge that PR on their behalf. Merge it yourself once the PR body, up-to-date, and green-head rules are met; don't ask them to re-confirm in another chat. It covers only the PRs they name, never follow-ups or a bot's relay. If a catch-up changes the PR's behavior, re-ask.
2. Check **Factory loop step 7 (Product gate)** as done.
3. Set **AI disclosure → Human reviewed before merge: yes** and name who (e.g. the repo owner; in the source repos this template came from, "Michael / @User").
4. Update any other matching fields (spec gate, safety “did not auto-merge”, Notes) so the PR body matches reality.
5. Then merge per risk class.

The PR body is the durable audit trail. Chat is ephemeral relative to GitHub.

## Ship & feed back

- Merge only when the table above allows.
- **Before handing a PR to the human for review:** update the branch onto latest default branch so it is current at review time.
- **Immediately before any merge** (trivial auto-merge, or after the human gate):
  1. Before you report a PR as behind or conflicting, check it is not already merged. Then check whether the PR branch is behind the default branch.
  2. If behind, update it (GitHub “Update branch” / `update_pull_request_branch`, or merge the default branch into the PR branch; no rebase, no force-push).
  3. Wait for required CI to pass on the **new head commit**; only then merge.
  4. A human approval given while the branch was behind still stands for a clean catch-up update. If the update hits conflicts or changes the PR’s own diff or behavior: resolve, re-verify, and tell the human what changed before merging (re-ask the gate for normal/high).
  5. Never merge a branch that is behind, and never merge on CI results from a stale commit.
  6. **Bypass merges:** If you merge with an admin/ruleset bypass, the bypass skips every rule including the up-to-date check, so first verify by hand that the branch is 0 commits behind the default branch and that all required checks are green on the current head SHA, then merge with a merge commit.
  7. Merge with a merge commit. Do not squash-merge or rebase-merge; keep those methods disabled in repo settings.
- **After merge — monitor deploy:** watch pages / deploy / CD workflows on the default branch. If deploy CI is red or stuck, open a fix promptly (same issue or new); comment status on the issue. Do not walk away after PR CI alone was green.
- Close or update the issue when ship + deploy are good (or note follow-ups).
- **Scheduled jobs:** at the start of each session, check the latest scheduled (cron) workflow runs on the default branch. A failed run becomes a bug issue (failing step + log excerpt), is reported to the human, and goes to the top of the queue. A scheduled run that skips because the job already succeeded that day (UTC) is not a failure. The daily check reports the project's headline health numbers listed in `DOCS.md` (e.g. items published, items hidden or dropped, items shown correctly). Flag big jumps in run duration too. Also confirm the job's output actually went live (a data commit pushed with the default workflow token won't trigger a deploy workflow). Cron jobs run early, at an odd minute, with a guarded backup cron for important daily jobs; flag a finding when no run has finished by the project's freshness deadline (GitHub often starts scheduled runs hours late). A routine check that hasn't posted its result by its deadline is a failure: say so in the project room right away; don't go quiet.
- Failures, monitor hits, process lessons → new GitHub issues and/or skill updates. After any slip, write the lesson into the rules or skills. Not chat-only.
- **Asking the owner:** one decision per question, as (a)/(b) with your recommended pick and its consequence.
- **End of day:** the manager posts a short summary in the room: decisions needed, what shipped, what went wrong, lessons.

- Use "Closes #N" only for the issue this PR finishes. Ledgers, trackers, and parent issues get "Refs #N" (see FACTORY.md).
