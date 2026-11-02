# Software Factory

Copy this whole folder into a repo as `.factory/`. Works with any model or chat product. System of record: **GitHub**.

## 20-second pitch

Work enters as a GitHub issue. Michael **selects** what gets worked (`factory:selected`). The **Factory Manager** writes a spec; a **GitHub Actions** run on **DeepInfra** does the build; humans gate normal/high risk. Skills and decisions live here so the next agent can continue without the chat.

**Words:** **Complexity** is `simple | standard | complex` (picks the model). **Risk class** is `trivial | normal | high` (sets the merge gate). When Michael says "medium or high complexity" that means **standard or complex**; "medium or high risk" means **normal or high**.

## Triggers

| Trigger | What happens |
|---|---|
| **New / open GitHub issue** | **Intake** only — a valid work item with a one-sentence outcome. Most issues stop here. Coordinator handoff: `skills/intake-from-coordinator.md` files/refines the issue, then hands off to the Factory Manager. |
| **`factory:selected` label** (Michael) or **"select #N"** to Grok Bot | **Selection** — only selected issues get a spec and an Actions run. Not every issue becomes agent work. |
| **`/oc run`** on a selected issue (owner account only) | **Run** — GitHub Actions spins up a worker (OpenCode + DeepInfra) from the approved spec; see `.factory/VISION.md`. |
| **Message to project coordinator** | Start of the **production line** (same as a new issue path above). Coordinator = chief of staff, project lead bot, or any designated intake agent — not chat-as-queue. |

Chat alone is never the work item. The issue is.

**Rule:** Only issues with `factory:selected` get a spec or an Actions run. Epic/build work on the factory itself (e.g. Cursor cloud agents on child issues) follows the issue's scope; project issues use selection + spec + `/oc run` by default.

## Roles

| Role | Who / what | Does | Never |
|---|---|---|---|
| **CEO** | Michael (human owner) | Vision, chooses which issues get worked (`factory:selected`), spec approval for standard/complex work, product gate for **normal** and **high** risk PRs, budgets | Configures the line repeatedly; relays notes between bots by hand |
| **Factory Manager** | Grok Bot (one bot per repo; Cursor plan) | Michael's single contact: triage, **writes specs**, routes model and predicted cost, starts runs (`/oc`), **Factory review** on PRs, records approvals on the PR body, merges within authority, weekly spend report, watches failed gates — see `skills/factory-loop.md` | Decides product questions; merges normal/high without Michael; turns on on-demand spend |
| **Compute (CPU + VM)** | GitHub Actions runners (`ubuntu-latest`) | Clean VM per run: hosts the harness, cost capture, **pre-spin-down gate**, then disappears | Holds state between runs; merges |
| **Inference** | DeepInfra | Low-cost model tokens for worker runs | Sees the repo beyond what the harness sends |
| **System of record** | This GitHub repo | `.factory/` method, issues, `factory/specs/`, PR template + `pr-check`, security guardrails, `factory/runs/`, financials | — |
| **Worker** | Harness on Actions (OpenCode + a DeepInfra model) | Executes one approved spec on a branch; fills the PR template; opens or updates the PR | Merges; edits `.github/workflows/`; reads or prints secrets |
| **Coordinator** (optional) | Intake bot / chief of staff | Chat → issue → hand off to Factory Manager | Builds |
| **Giver** (optional, recommended) | One bot per repo | Asks ledger, drafts decisions, healthy challenge — `skills/giver.md` | Builds, merges, approves, spends |

Cursor cloud agents stay a **backup harness** and build the factory epic itself; they are not the default worker for selected project issues (Actions + DeepInfra is). Local open-weights on the desktop is an optional fallback — `skills/local-open-weights-run.md`.

## Loop

Cloud factory path (selected issues). Detail: `.factory/VISION.md` §4.

1. **Intake** — GitHub issue with a one-sentence outcome (coordinator handoff or native issue). Most issues stop here.
2. **Selection** — Michael adds `factory:selected` or tells Grok Bot "select #N". Only selected issues continue.
3. **Spec** — Factory Manager writes the spec from `.factory/templates/spec.md` (template content lands with the spec-template issue). Approved spec lives as a spec comment on the issue; the run commits `factory/specs/issue-<N>.md` in its PR.
4. **Classify** — Complexity (`simple | standard | complex` + reason), risk class (`trivial | normal | high`), model (`.factory/models.yaml` when present), predicted cost. Split before run if predicted cost exceeds $1.
5. **Spec approval** — Michael for standard/complex or normal/high risk; Grok Bot may self-approve **simple + trivial** only.
6. **Run** — `/oc run` on the issue: Actions worker on DeepInfra executes the spec.
7. **Gate** — Pre-spin-down checklist on the VM (cost tracked, run record, PR template + `pr-check`, gitleaks, budget, no workflow edits). Fails loudly on any miss.
8. **PR** — Standard PR contents (template v2 when landed); worker + gate fill human sections; run end fills the factory-run block.
9. **Review** — Grok Bot: one `Factory review` comment (`skills/review-local-pr.md`). Fixes via `/oc` on the PR.
10. **Approval by risk** — **trivial:** Factory Manager after green CI and passing gate. **Normal / high:** Michael (see merge authority below).
11. **Merge** — Factory Manager within authority; workers never merge. Update branch onto latest default branch; required CI green on head commit; merge commit only.
12. **Logging** — Run record JSON in the PR and a copy on the issue.
13. **Financials** — dbt + dashboard refresh (scheduled workflow); Grok Bot weekly spend report.

**Verify (every PR):** CI + evidence on the PR (screenshots required for UI); fill the **Factory loop** section of the PR template; never merge on red/skipped required checks. Acceptance numbers must include the metric from the original ask, not only proxies; the post-merge check reports that metric against its baseline. For high-risk output changes, show real before/after from a cloud agent before the product gate (capped spend, publishes nothing), using secrets in `DOCS.md`. Any user-facing output change shows the project's key view (`DOCS.md`) before and after. Revert triggers, done bars, cache proof, and docs-only vs full regeneration rules unchanged from prior practice — see Rules and Evidence rules below.

**Product gate (human)** — required for **normal** and **high** work; skipped only for **trivial**. When approval arrives in chat (or elsewhere), the manager **edits the PR description first** (Factory loop step 7 + Human reviewed before merge: yes + who), then merges — chat alone is not the audit trail. A human approver's approval that names the PR (e.g. "approve #88"), posted by them in the factory room or in a 1:1 chat with the manager, **is a direct merge instruction for that PR**: the manager merges once the PR body is updated, the branch is 0 behind the default branch, and required checks are green on the head commit. Blanket and pre-approval rules unchanged (see `skills/factory-loop.md`).

**Ship → monitor deploy → feed back** — merge only when authority allows; watch post-merge deploy CI; fix if red; lessons → rules/skills or new issues.

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
- **Default worker path:** selected issues run on **GitHub Actions + DeepInfra** via `/oc run` (see `.factory/VISION.md`). Only `factory:selected` issues get a spec or that run.
- **Local open-weights harness (optional fallback):** when Actions can't run, the human works from the approved spec in local Cursor with the Local open-weights model from `MODEL_ROUTING.md` (`skills/local-open-weights-run.md`). Same loop and gates; the API key is never committed; each issue aims for under $0.10 of provider spend with a hard cap of $1 (complex may scale up; split anything bigger)
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
