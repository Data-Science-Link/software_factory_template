# Software Factory

Copy this whole folder into a repo as `.factory/`. Works with any model or chat product. System of record: **GitHub**.

## 20-second pitch

Work enters as a GitHub issue. Agents triage → (specs if hard) → build → review → verify → ship. Humans only at judgment gates. Skills and decisions live here so the next agent can continue without the chat.

## Triggers

| Trigger | What happens |
|---|---|
| **New / open GitHub issue** | Valid factory work item. The repo’s **factory manager** (or any agent with repo access) runs `skills/factory-loop.md`. |
| **Message to project coordinator** | Valid start of the **production line**. Coordinator = chief of staff, project lead bot, or any designated intake agent — not chat-as-queue. They run `skills/intake-from-coordinator.md`: file/refine a GitHub issue, then **hand off to the factory manager** to start the loop. |

Chat alone is never the work item. The issue is. Messaging the coordinator is how a human (or another agent) **kicks the line**: issue + explicit handoff to the manager.

If there is no separate manager yet, the coordinator may run `factory-loop` themselves after filing — still issue-first.

## Roles

| Role | Who | Does | Never |
|---|---|---|---|
| **Human owner** | The person | Product judgment, spec and product gates, approvals | — |
| **Coordinator** (optional) | Chief of staff / intake bot | Turns chat asks into issues, hands off | Builds |
| **Factory manager** | One bot per repo | Runs the loop, sequences work, launches and reviews worker agents, merges per gates | Decides product questions |
| **Workers** | Child cloud agents | Build, review, test on a branch/PR | Merge without the manager |
| **Giver** (recommended) | One bot per repo | Keeps the asks ledger, drafts decisions, challenges claims against the owner's asks — see `skills/giver.md` | Builds, merges, approves, spends |

## Loop

1. **Intake** — GitHub issue with a clear outcome (from coordinator handoff or native issue).
2. **Triage** — easy → build; hard → product + tech specs on the issue. Pick the model per `MODEL_ROUTING.md`.
3. **Spec gate (human)** — approve, or skip if trivial.
4. **Build** — sync latest default branch first (agents often have a stale tip), then branch + PR linked to the issue.
5. **Review** — agent first; human on risk and product (see merge authority below + `skills/liability-gates.md`). A cloud agent's token may not be able to comment; if so, the manager posts that agent's reviews and reports.
6. **Verify** — CI + evidence on the PR (screenshots required for UI); fill the **Factory loop** section of the PR template so adherence is auditable; never merge on red/skipped required checks. Acceptance numbers must include the metric from the original ask (what the human actually complained about), not only proxies; the post-merge check reports that metric against its baseline. For high-risk changes to model or data output, show real before/after output from a cloud agent before the product gate (capped spend, publishes nothing), using the secrets listed in `DOCS.md`; don't defer the evidence to after merge. Any user-facing output change shows the project's key view (defined in `DOCS.md`, e.g. the top 10 items readers see first) before and after, before approval. A done claim on user-facing work waits for a hand audit of that real key view. If the owner explicitly chooses to verify on the next scheduled run instead (allowed only when the revert trigger can be checked from the run's numbers), record that choice and the revert trigger in the PR body. A revert trigger anyone can check from the run's numbers (e.g. a health number gets worse, a key-view item loses something) fires on its own: revert with a merge commit and tell the owner right after. A done bar or revert trigger must be rerunnable: the run log prints the number, the baseline has a written definition of how it is measured next to it, and the script or query that computes it is committed to the repo; a baseline no one can rerun can't be a done bar or revert trigger. Before a metric becomes a done bar, test it against the cases the human flagged by hand (they are must-pass tests) and hand-check a sample of unflagged and extra-flagged items for misses and false alarms; a noisy metric becomes a hand-check flag list, not an auto-revert trigger. A trigger that needs judgment (e.g. deciding an output is wrong, or unclear cause) waits for the owner's word. A performance or cost feature (e.g. a cache) doesn't count as shipped until a real run shows it working (e.g. logged cache hits on a second run over the same input). Merges that touch only docs or `.factory/` files skip expensive data-regeneration jobs; merges that change the code producing user-facing output still run them in full.
7. **Product gate (human)** — required for **normal** and **high** work; skipped only for **trivial**. When approval arrives in chat (or elsewhere), the manager **edits the PR description first** (step 7 checked + Human reviewed before merge: yes + who), then merges — chat alone is not the audit trail. A human approver's approval that names the PR (e.g. "approve #88"), posted by them in the project's factory room or in a 1:1 chat with the manager, **is a direct merge instruction for that PR**: the manager merges it itself, with no second confirmation in another chat, once the PR body is updated, the branch is 0 behind the default branch, and required checks are green on the head commit. It covers only the named PR; a relay from another bot is not approval. A blanket approval ("approve all open PRs") covers only PRs that were review-ready with evidence posted at that moment; it doesn't cover drafts, later revisions, or open product choices inside a PR (thresholds, options), which still need the human's explicit pick. A human may explicitly pre-approve a named PR before it's finished ("I preemptively approve #N, no need to check back"); then it merges once agent review and CI pass, the PR body records the pre-approval and its conditions, and anything beyond the agreed scope still comes back.
8. **Ship → monitor deploy → feed back** — merge only when authority allows; **right before merge, update the PR branch onto latest default branch and wait for required CI green on that new head commit** (see Rules); watch post-merge deploy CI; fix if red; after any slip, write the lesson into the rules or skills (propose rule changes to the owner). Monitor hits and cron or deploy failures still become issues.

## Merge authority (by design)

| Risk class | Examples | Who may merge |
|---|---|---|
| **trivial** | Typos, docs-only, comment-only, pure playbook sync with **no** product/behavior change | Factory manager **may** merge after green required CI (no human wait) |
| **normal** | Features, bugfixes, behavior changes, **any UI / frontend / website / pages** | **Human product gate first** — do **not** auto-merge |
| **high** | License, secrets, auth, crypto, safety claims, workflows, CODEOWNERS, supply chain | **Human required** before merge |

If unsure whether something is trivial vs normal, treat it as **normal** and wait for a human.

## UI / frontend evidence

Any PR that changes a website, page, or UI **must** put screenshots in the PR **Evidence** section (embed or link; before/after when practical, or current state + what changed). Thread-only comments do **not** count. No Evidence screenshots → incomplete; do not ask for merge.

## Post-merge deploy

After merge: watch the repo’s deploy / pages / CD workflows on the default branch. If deploy CI fails, open a fix PR (or continue on the same issue) promptly — do not walk away after a green PR CI. Comment deploy status on the issue.

## Scheduled jobs (cron) watch

Scheduled workflows (daily data jobs, nightly builds) can fail with no PR in flight. At the start of each work session, and after any merge that touches a scheduled job, check the latest scheduled runs on the default branch. If one failed, open (or reopen) a bug issue with the failing step and log excerpt, tell the human, and treat it as top priority. Also note run duration trends; a big jump is worth an issue. A green run is not enough: confirm the job's output actually reached its destination (for example, the published site shows today's data). Pushes made with the default workflow token do not trigger other workflows, so a job that commits data can silently skip the deploy. Also check that scheduled runs actually start: GitHub delays or drops scheduled runs under load, worst at the top of the hour, so schedule cron jobs at an odd minute (for example `17 6 * * *`, not `0 6 * * *`) and schedule early enough that a delay of several hours is harmless. Keep scheduling inside GitHub Actions (no outside scheduler). For a daily job that matters, schedule several guarded crons spread over a few hours (each exits immediately if today's run already succeeded, all in one concurrency group, and no-op runs must not redeploy or publish), because GitHub can create scheduled runs many hours late. Also note GitHub disables schedules on public repos after 60 days without repository activity; confirm the project's activity keeps them alive. Flag a finding only when no run has *finished* by the project's freshness deadline (e.g. late morning), not merely when a start is late. A routine or scheduled check that hasn't posted its result by its deadline counts as a failure: the manager or worker says so in the project room right away instead of going quiet. If a job has a time or cost limit that degrades quietly when hit (skips work instead of failing), the daily check flags any run above about 80% of that limit (judge headroom by the worst of the last ~7 runs, not one run, since run time can swing 2x day to day), and any PR that adds work to that job must show a projection of the whole job, with every step scaled to the expected growth, under the limit before merge. A scheduled run that skips because the job already succeeded that day (UTC) is not a failure. The daily check reports the project's headline health numbers listed in `DOCS.md` (e.g. items published, items hidden or dropped, items shown correctly).

## Folder map

```
.factory/
  FACTORY.md                      ← this playbook (keep thin)
  DECISIONS.md                    ← append-only project decisions for this repo (giver drafts, manager commits). Separate from the template's DECISIONS.md, which logs method changes.
  DOCS.md                         ← map to repo docs (pointers only, no copies)
  MODEL_ROUTING.md                ← which model per task; what to do when spend limits hit
  skills/
    factory-loop.md               ← run the loop on an issue
    intake-from-coordinator.md    ← coordinator: chat → issue → hand off to manager
    giver.md                      ← giver: asks ledger, decision drafts, healthy challenge
    liability-gates.md            ← hard stops (secrets, license, CI, over-claims, merge authority)
    local-open-weights-run.md     ← local agents only: run an issue on a Local open-weights model with your own provider key
    local-owner-setup.md          ← owner, once per computer: gh, hooks, DeepInfra key, antivirus, allowlist
    local-agent-safety.md         ← owner, once: secret-scan hook, scoped gh token, command approvals, protect main
    review-local-pr.md            ← reviewing bot: Factory review comment on a local agent's PR
  sketches/                       ← copy these into the repo root / .github/
    CONTRIBUTING.md
    github/pull_request_template.md
    github/CODEOWNERS.example
    (add repo-specific skills under skills/, not sketches/)
```

- **Factory skills** → `.factory/skills/`
- **Local agent rule** → `.cursor/rules/factory.mdc` (always on in Cursor; `do issue N`, `address the review on PR N`)
- **Repo documentation** → stays in the repo (`README`, `docs/`, …); list paths in `DOCS.md`
- **Contributor / PR / owners sketches** → copy from `.factory/sketches/` into the repo, then point `DOCS.md` at them

## Rules

- Pin a model on every agent launch per `MODEL_ROUTING.md`; cheapest capable model first; never enable on-demand spend yourself

- Humans own “is this useful?” for all **normal** and **high** work; only **trivial** may auto-merge
- Chat (or issue) product-gate approval must be **written onto the PR description** before merge
- **Update the branch right before every merge** (trivial, or after the human gate): if behind the default branch, update it, wait for required CI green on the new head, then merge — never a behind branch or stale-commit CI. Clean catch-up keeps approval; conflicts or changes to the PR’s own diff/behavior → re-verify and tell the human (re-ask the gate for normal/high). Update before human review, too. Before you report a PR as behind or conflicting, check it is not already merged.
- **Bypass merges:** If you merge with an admin/ruleset bypass, the bypass skips every rule including the up-to-date check, so first verify by hand that the branch is 0 commits behind the default branch and that all required checks are green on the current head SHA, then merge with a merge commit.
- **Merge commits.** Merge with a merge commit. Do not squash-merge or rebase-merge; keep those methods disabled in repo settings.
- History in GitHub + this folder — not only chat
- Leave work pick-uppable from issue/PR alone
- Agents see their own CI/evidence (incl. UI screenshots) before asking for review
- Follow `skills/liability-gates.md` on every change
- After merge, monitor deploy CI and correct failures
- Check scheduled (cron) workflow runs each session; a failure becomes a top-priority bug issue
- Drop process that stopped helping
- **Agent cap:** run at most 4 coding agents at once (a repo may set its own number in DECISIONS). Keep a restart list on each issue (what's running, its branch, the next step) so a pause or usage limit loses nothing
- **Outside coding agents** (outside the default harness) run this same loop and gates. Their cost needs its own explicit yes from the owner (this rule is not that yes); once approved, record the route in DECISIONS and `MODEL_ROUTING.md` before first use
- **Local open-weights harness:** when cloud agents can't run, the human works the issue's handoff block in local Cursor (or another local harness) with the Local open-weights model from `MODEL_ROUTING.md` (`skills/local-open-weights-run.md`). Cloud agents ignore the Local open-weights line and use the model they were launched with. Same loop and gates; the API key is never committed; each issue aims for under $0.10 of provider spend with a hard cap of $1 (complex may scale up; split anything bigger)
- **Local agent safety:** a local agent runs only after the owner has done the one-time setup in `skills/local-agent-safety.md` (gitleaks pre-commit hook, scoped `gh` token, command approvals on)
- **Local-agent PRs:** pass the PR check (`scripts/pr-check.sh`) and get a `Factory review` comment from the reviewing bot (`skills/review-local-pr.md`) before the human merge gate
- **Questions to the owner** are one decision each, phrased as (a)/(b) with a recommended pick and its consequence (e.g. cost or done-bar impact), so a short reply can't be read two ways

## Private repos

The loop and gates are the same; a few settings and costs differ. Check GitHub's current plan docs when setting up, since limits change.
- **Plan:** branch protection, rulesets, and GitHub Pages on a private repo need a paid plan (Pro, Team, or higher). Without them, merge gates are enforced by the manager alone, so record that in DECISIONS and keep the bypass-merge checks by hand.
- **Actions minutes are capped** on private repos (included minutes per month, then billed or blocked). Count CI and scheduled jobs against that budget: add the monthly minutes used to the daily check, flag at about 80% of the allowance, and avoid redundant runs (path filters, concurrency groups, one guarded backup cron instead of many).
- **Access is explicit:** every bot, cloud agent, and GitHub app needs to be granted the repo. Check this first when an agent can't see the repo, issues, or CI.
- **What relaxes:** no outside issues or PRs, and no 60-day schedule shutoff (that only applies to public repos). Liability gates about public claims, license notices, and contributor terms matter less while the repo stays private, but secrets, CI, risk-class, and merge gates stay in full. Before making a private repo public, run the full `skills/liability-gates.md` review first (secrets in history, licenses, claims).

## Daily newcomer review (optional, recommended for live products)

Once a day, after the scheduled job finishes, the manager launches a short cloud-agent review (pinned to the trivial/normal model, a few minutes' cap) that looks at the live product as a newcomer would, against `DOCS.md` and the project goals. It logs only obvious problems (misaligned with goals, unhelpful, clearly bad data or output) as issues: at most ~3 per day, de-duplicated against open issues, each with evidence (screenshot or live data) and the goal it misses, plus the review's run ID. Fixes go through the normal loop and risk gates; only true trivial fixes auto-merge.


## Evidence rules (from live misses)

- **Close on proof, not on merge.** A fix for a production failure closes its issue only when a real production run's log shows the fix actually executed. A merged PR or a passing unit test is not enough.
- **"Closes" only for the issue a PR finishes.** Ledgers, trackers, and parent issues that stay open get "Refs #N" in the PR, never Closes/Fixes/Resolves, because GitHub auto-closes them on merge. Agent review flags a closing keyword that points at a standing issue.
- **Test the real sequence.** Tests for guards, gates, and workflow steps must reproduce the real order and environment (branch switches, checkouts, secrets), and must show a deliberately broken case being blocked, not only a healthy case passing. Say in the PR whether evidence came from a real Actions run or a reproduction.
- **Benchmarks can't grade themselves.** A benchmark labeled by a model must use a different model (ideally a different family) than the one the change uses, with agreement reported; a human spot-check is a bonus. The same goes for reference lists: fix them before the code changes, independent of the code being measured.
- **Stochastic outputs need a stability check.** When a change relies on sampling or model judgment, run the same input several times with different seeds before merge and report how many results flip; fix the seed for production only after that. Any extra model gate that can veto the human's rule (e.g. a "coherence" check on top of a threshold) is a product choice: surface it, and count its blocks as failures rather than quiet defaults.
- **"Approve whatever you recommend"** is a valid approval only for a recommendation already stated in the room for that PR, with its option named in the PR body ("approved as recommended: keep the check").
- **Standing approval ("you have my approval, use your judgment")** is logged in DECISIONS with its date, scope, and how to revoke it. Under it the manager still posts evidence before each normal/high merge, and still brings back: liability-gate items (workflow/CI permissions, secrets, licensing, public claims), anything that raises steady-state cost past the owner's target, and new reader-facing behavior. It lapses if the owner narrows or revokes it.
- **Count every quiet drop.** Any step that silently drops, skips, or filters output a reader would see (planets, items, rows) must report a count in the run summary and the daily check, and name large ones. A drop that's only visible in raw logs is a hidden failure.
- **The manager may decline a check.** When a challenge (from the giver or a reviewer) costs more than it's worth, the manager says so with a reason instead of absorbing every check; the owner can overrule. Agreeing by default turns every catch into scope.
- **Owner updates.** The manager keeps posting status on ongoing work in the room, and posts one short end-of-day summary there (at a fixed time): decisions needed from the owner, what shipped, open risks. The debate stays in the room for when the owner wants it.
- **DECISIONS authorship.** Commits may show the owner's account or a bot account, because commits go through those accounts; the giver drafts and the manager commits.
- **Evidence tied to code.** Screenshots and verification evidence are saved under a path keyed to the commit they show (e.g. `docs/evidence/pr-N/head-<sha>/`). Retake them only when a catch-up touches front-end files or changes the PR's own diff.
- **No hidden faults.** A change to a report, monitor, or check may not mute a recurring fault unless that fault has its own linked root-cause issue; the report keeps showing it (e.g. how many days in a row).
- **Date-proof tests.** Tests never pair a hardcoded date with the real clock: freeze or inject the clock, and test expiry and edge dates on purpose with a case just past the limit. When one such test turns up, sweep for others.
- **Fresh-sample proof.** A quality or guard fix keeps its regression fixtures, but isn't done until it's scored (raw N of M) on fresh data it wasn't built from.
- **Paid tests check their inputs first and stop hard.** Before a paid test spends, confirm its preconditions can be met (e.g. the input volume actually exists); if not, stop and report rather than top up. A cost cap must abort the run, not just log, and is proven by a deliberately over-cap case before it guards real spend. An overrun is reported as a finding with the actual amount.
