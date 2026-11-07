# Decision log

Append-only. Newest at the bottom.

> **About the examples below:** these entries are this template's own history. The repo names, issue and PR numbers, and people's names in them come from specific source repos where the method was run (for example [Data-Science-Link/perspectiverse](https://github.com/Data-Science-Link/perspectiverse)), included for illustration. A number like "perspectiverse #88" refers to that repo, not this one. "Michael" is the template owner.

## Template

```
### YYYY-MM-DD — Short title
- **Decision:** what we chose
- **Decided by:** owner (quote or link) / manager (sequencing or technical call) / other human
- **Why:** one or two sentences
- **Alternatives:** what we rejected (optional)
- **Revisit when:** trigger to reconsider (optional)
```

## Log

### 2026-10-06 — Factory layout
- **Decision:** Ship a copy-paste `.factory/` template: `FACTORY.md`, `DECISIONS.md`, `DOCS.md`, `skills/`
- **Why:** Portable across repos and models; process separate from product docs
- **Alternatives:** Root-level files only; heavyweight monorepo factory infra
- **Revisit when:** A target repo already uses `.factory` for something else

### 2026-10-06 — GitHub issues as sole intake
- **Decision:** Factory work = GitHub issues only. CoS chat files issues; open issues start the loop when a watcher/agent picks them up.
- **Why:** Durable, multiplayer, pick-uppable; history out of chat
- **Alternatives:** Chat-as-queue; external tracker as primary
- **Revisit when:** Need a label/filter so not every issue enters the factory

### 2026-10-06 — Coordinator message kicks the production line
- **Decision:** A message to the project coordinator (CoS or similar) is a factory trigger: file/refine a GitHub issue, then hand off to the factory worker (`intake-from-coordinator.md`). Renamed skill from intake-from-cos.
- **Why:** Stakeholder chat should start the line, not only create a dormant issue; still issue-first and multiplayer.
- **Alternatives:** CoS files issue and always stops; chat-as-queue with no GitHub issue.
- **Revisit when:** A project uses labels so only some coordinator asks enter the factory.

### 2026-10-06 — Liability gates + contributor sketches
- **Decision:** Add `skills/liability-gates.md` and portable sketches (`CONTRIBUTING.md`, PR template, CODEOWNERS example) under `.factory/sketches/`. Factory-loop must follow liability-gates. Not legal advice; does not eliminate liability.
- **Why:** Light-review public factories need machine-readable hard stops (secrets, license, CI, over-claims) and copy-paste diligence artifacts.
- **Alternatives:** Repo-only ad hoc docs; no agent-enforced gates.
- **Revisit when:** Counsel provides project-specific terms, or CLA is chosen over DCO.

### 2026-10-06 — Always sync latest main before factory work
- **Decision:** Factory skills require fetching/updating onto the current default branch before branching or continuing work; cloud agents may have a slightly stale main.
- **Why:** Avoid PRs based on outdated tips and painful rebase conflicts.
- **Alternatives:** Hope the agent environment is fresh; only sync when conflicts appear.
- **Revisit when:** Agent harnesses guarantee up-to-date default branch at start.

### 2026-10-07 — Merge authority: trivial may auto-merge; normal/high need human
- **Decision:** Only **trivial** PRs (typo/docs/comment/playbook-only, no product/behavior change) may be merged by the factory worker after green required CI. **Normal** (features, bugfixes, behavior, any UI) and **high** require a human before merge. Unsure → normal.
- **Why:** Auto-merges on green CI for user-facing work surprised stakeholders; design allows simple stuff to ship without blocking, but product judgment stays human.
- **Alternatives:** Never auto-merge; always auto-merge on green CI.
- **Revisit when:** Branch protection / CODEOWNERS enforce the same split mechanically.

### 2026-10-07 — UI PRs require screenshots
- **Decision:** Any factory PR that changes websites, pages, or UI must attach screenshots on the PR before it is treated as ready / mergeable.
- **Why:** Text diffs under-communicate visual regressions; humans need a fast visual gate.
- **Alternatives:** Optional screenshots; video-only; rely on live preview links alone.
- **Revisit when:** Automated visual regression is wired into CI.

### 2026-10-07 — Post-merge deploy monitoring
- **Decision:** After merge, the factory worker watches deploy/pages/CD on the default branch and opens a fix if it fails; status is commented on the issue.
- **Why:** Green PR CI is not the same as a healthy deployment; walking away after merge leaves broken sites.
- **Alternatives:** Rely only on humans noticing Pages failures; separate deploy-only bot.
- **Revisit when:** Deploy notifications are automatic and always routed to the worker.

### 2026-10-07 — Factory-loop section required on every factory PR
- **Decision:** The GitHub PR template includes a succinct **Factory loop** checklist (intake → triage → spec gate → build → review → verify → product gate → ship/monitor). Factory workers and Cursor agents must fill it on every factory PR so humans can audit process adherence from the PR alone.
- **Why:** Hard to tell from chat whether workers followed the playbook; PR is the durable, multiplayer surface.
- **Alternatives:** Chat-only status updates; separate process ticket per change.
- **Revisit when:** Checklist becomes noise or steps change.

### 2026-10-07 — UI screenshots must be in PR Evidence section
- **Decision:** For UI/frontend/website/pages PRs, screenshots must appear in the PR description **Evidence** section (embedded or linked). Screenshots only in a conversation comment do not satisfy the gate.
- **Why:** Comment-only shots are easy for humans to miss when auditing adherence from the PR body.
- **Alternatives:** Allow either body or comment; require attached image files only.
- **Revisit when:** GitHub UX makes comment evidence as visible as the description.

### 2026-10-07 — Chat product-gate approval must update the PR description
- **Decision:** When a human product gate (or similar review) is given in chat or another channel, the factory worker must **edit the PR description** before merging: check **Factory loop step 7 (Product gate)**, set **Human reviewed before merge: yes** (and who), and any other matching review fields. Chat approval alone is not enough — the PR body is the durable audit trail.
- **Why:** Workers were merging after chat “Approved” without reflecting that on the PR; humans auditing the PR later could not see that a product gate happened.
- **Alternatives:** Rely on chat history only; require a GitHub review click instead of chat.
- **Revisit when:** Branch protection requires an approving GitHub review for all normal/high PRs.

### 2026-10-07 — Watch scheduled (cron) workflow runs, not just post-merge deploys
- **Decision:** Factory workers check the latest scheduled workflow runs on the default branch at the start of each session and after merges touching scheduled jobs. A failed run becomes a top-priority bug issue (failing step + log excerpt) and is reported to the human; large duration jumps are flagged.
- **Why:** A daily data job failed and the site silently served stale data; it surfaced only when a human asked about something else. Post-merge deploy watching doesn't cover cron jobs with no PR in flight.
- **Alternatives:** GitHub email notifications only; a separate monitoring bot.
- **Revisit when:** The repo has real alerting on scheduled job failures.

### 2026-10-07 — Model routing table; pin models, cheapest capable first
- **Decision:** Add `MODEL_ROUTING.md`. Workers pick a model at triage from risk class + type of work, pin it on every cloud-agent launch (never Auto), escalate one step at a time, and record the model in the PR body. Cursor Models pool (Composer 2.5, Grok 4.7) first; third-party models only when stuck or for a high-risk second opinion. Other Models exhausted → stay on Cursor Models; Cursor Models exhausted → stop new work and ask the human. Workers never enable on-demand spend.
- **Why:** The Other Models pool hit 100% while Cursor Models sat at 1%, blocking agent launches; model choice was implicit and cost-blind.
- **Alternatives:** Leave everything on Auto; one model for all work.
- **Revisit when:** Plan, pool rules, or model lineup changes.

### 2026-10-07 — Update PR branch onto latest main right before merge; repo setting requires up-to-date branches
- **Decision:** Immediately before any merge (trivial auto-merge, or after the human gate), the worker updates the PR branch onto the latest default branch if it is behind and merges only after required CI is green on that new head commit. PRs are also updated before handing them to the human for review. A clean catch-up keeps prior approval; conflicts or changes to the PR’s own diff/behavior are re-verified and reported to the human (gate re-asked for normal/high). As a second layer, repos enable "Always suggest updating pull request branches" and require branches to be up to date (strict status checks) on the default branch. An admin/ruleset bypass merge skips every rule, including the up-to-date check, so before a bypass merge the worker verifies by hand that the branch is 0 commits behind and all required checks are green on the current head SHA, and uses a merge method the ruleset allows.
- **Why:** PRs were reaching human review, and could be merged, while out of date with main, so CI results no longer described what would actually land.
- **Alternatives:** Rely on the start-of-work sync only; merge queue.
- **Revisit when:** The repo adopts a merge queue or the platform auto-updates branches before merge.

### 2026-10-07 — Scheduled-job watch checks the output, not just the run
- **Decision:** The scheduled-job watch also confirms that the job's output reached its destination (for example, the live site shows today's data), not just that the run went green.
- **Why:** A daily data job ran green for days while the site stayed stale. Commits pushed with the default workflow token don't trigger other workflows, so the data push never started the deploy.
- **Alternatives:** Trust run status alone.
- **Revisit when:** The deploy is triggered directly by the job (for example, workflow_run or a deploy step inside the job).

### 2026-10-08 — Cron at an odd minute; a late-starting scheduled run is a finding
- **Decision:** Schedule cron workflows at an odd minute (not :00 or :30), and have the scheduled-job watch flag any run that hasn't started within about 2 hours of its scheduled time.
- **Why:** A daily job scheduled at `0 6 * * *` started about 6.5 hours late; GitHub delays or drops scheduled runs under load, worst at the top of the hour, and the watch treated the delay as normal.
- **Alternatives:** Accept GitHub's scheduling delays; trigger the job from an external scheduler.
- **Revisit when:** The job is triggered by something other than GitHub's cron, or GitHub's scheduling becomes reliable.

### 2026-10-08 — A named approval in the factory room is a merge instruction

- **Decision:** When the human approver posts an approval naming a PR (e.g. "approve #88") in the project's factory room or a 1:1 chat with the worker, that message is a direct instruction for the worker to merge that PR on their behalf. The worker records the approval in the PR body, makes sure the branch is 0 behind the default branch with required checks green on the head commit, and merges, without asking for a second confirmation in another chat. Scope is the named PR only; it does not cover follow-ups, other PRs, or approvals relayed by another bot. If a catch-up changes the PR's behavior, the gate is re-asked.
- **Why:** On Perspectiverse ([perspectiverse #88](https://github.com/Data-Science-Link/perspectiverse/pull/88)) the worker asked the approver to repeat an approval from the factory room in a 1:1 chat before it would merge. That duplicate step added friction and no safety: the PR body is the audit trail either way.
- **Alternatives:** Require 1:1 confirmation for every merge (rejected: duplicate step); allow any room member or bot to approve (rejected: only the human approver holds the product gate).
- **Revisit:** If a room ever includes humans who are not approvers, name the approvers explicitly.

### 2026-10-08 — PRs state what changes in production on merge

- **Decision:** The PR template gains a "What changes in production on merge" section, required for normal and high-risk PRs: what users, live data, or scheduled jobs see differently as soon as the PR merges, which parts stay off, and what would turn them on.
- **Why:** On Perspectiverse ([perspectiverse #92](https://github.com/Data-Science-Link/perspectiverse/pull/92)) the summary said nothing in the daily run would change until a test passed, but a filter and cache with no switch went live on merge and dropped real data. The human gate only means something if the approver knows what goes live.
- **Alternatives:** Rely on the summary (rejected: it was wrong once already); require feature flags for everything (rejected: too heavy for small changes).
- **Revisit:** If the section is routinely boilerplate, fold it into Verify.

### 2026-10-08 — Quiet limits get an 80% warning and full-job projections

- **Decision:** For any job whose time or cost limit degrades quietly when hit (it skips work rather than failing), the daily check flags runs above about 80% of the limit, and PRs that add work to that job must project the whole job, every step scaled to expected growth, under the limit before merge.
- **Why:** On Perspectiverse, a labeling step with a 1,200s limit hit 1,212s after a merge and skipped part of its work without failing; a follow-up projection held one step fixed and understated the time.
- **Alternatives:** Make the limit fail the run (sometimes right, but can take the site down); check only after merge (rejected: the damage is already live).
- **Revisit:** If a job gains real headroom (under 60% for two weeks), drop its warning back to failures only.

### 2026-10-09 — Scheduled jobs: GitHub-only, early, backup cron, flag on freshness deadline (supersedes the 2-hour late-start rule of 2026-10-08)

- **Decision:** Keep scheduling in GitHub Actions; no outside scheduler. Schedule daily jobs early at an odd minute so multi-hour delays are harmless, add a guarded backup cron a couple of hours later (exits if today's run already succeeded; same concurrency group), and flag a finding only when no run has finished by the project's freshness deadline.
- **Why:** On Perspectiverse every scheduled run in a week started 4.5–7 hours late, so a 2-hour late-start flag fired daily and was noise. The owner preferred not to depend on another system and only needs one run per day.
- **Alternatives:** Outside scheduler calling the manual trigger (rejected: extra dependency); keep the 2-hour flag (rejected: noise).
- **Revisit:** If a job truly needs on-time runs, reconsider an outside trigger for that job only.

### 2026-10-09 — Daily newcomer review of the live product

- **Decision:** Add an optional daily cloud-agent review that inspects the live product as a newcomer against the project's docs and goals, logs at most ~3 obvious issues a day with evidence and run ID, and routes fixes through the normal gates.
- **Why:** Requested by the Perspectiverse owner; catches obviously bad output (groupings, data, UX) that CI and pipeline checks can't see.
- **Alternatives:** Wait for the owner to notice (rejected: slow); unlimited findings (rejected: floods the queue).
- **Revisit:** If it repeatedly finds nothing for two weeks, drop it to weekly.

### 2026-10-09 — Several guarded crons; watch the 60-day schedule shutoff (refines the backup-cron entry above)

- **Decision:** Important daily jobs use several guarded crons spread over a few hours instead of one backup; no-op runs exit without redeploying or publishing. Projects confirm their activity keeps GitHub from disabling schedules after 60 idle days.
- **Why:** Perspectiverse found GitHub creating scheduled runs 5–7 hours late every day for two weeks (config was not the cause), and its schedules had been silently disabled for three months over the summer after 60 days without commits.
- **Alternatives:** One backup cron (too few at multi-hour delays); outside scheduler (owner rejected the extra dependency).
- **Revisit:** If GitHub scheduling becomes reliable, drop to one guarded backup.

### 2026-10-09 — Real output before the gate for high-risk output changes

- **Decision:** When cloud agents hold the needed keys, high-risk PRs that change model or data output show real before/after output from a cloud agent (capped spend, nothing published) before the human product gate.
- **Why:** On Perspectiverse, several labeling PRs only showed real results after merge because the key was assumed to live only in the pipeline; the owner's cloud agents had it all along.
- **Alternatives:** Post-merge check only (rejected: the approver judges blind); a preview workflow (rejected by the owner there; cloud-agent runs need no workflow change).
- **Revisit:** If a run's cost is material relative to the change, ask before spending.

### 2026-10-09 — Separate production cost from test and merge spend

- **Decision:** Cost tracking tags each paid run by trigger (scheduled, merge, manual/test). Cost targets and alerts apply to steady-state production runs; test and merge spend is tracked but not held to the production target unless the owner sets a test budget.
- **Why:** On Perspectiverse a merge-day rerun pushed the daily total over the production target and read like a regression; the owner is fine spending more during testing as long as production settles low.
- **Alternatives:** One combined daily cap (rejected: blocks testing and misreads merge days).
- **Revisit:** If test spend becomes material, ask the owner for a test budget.

### 2026-10-09 — Acceptance includes the original ask's metric

- **Decision:** Normal and high PRs state the success metric from the original request (baseline, target, measured or projected value) and the post-merge check reports it. Proxy checks alone don't make a PR done.
- **Why:** On Perspectiverse, a grouping PR passed its own checks (fewer filler faces, labeling time) and shipped, but the owner's actual complaint (top planets too small) got worse: 297 to 165 posts.
- **Alternatives:** Trust proxy metrics (rejected: this miss).
- **Revisit:** If the metric can't be measured pre-merge, say so and make the post-merge check mandatory.

### 2026-10-09 — Roles: Factory Manager (renamed from factory worker) and an optional Giver

- **Decision:** The repo's coordinating bot is the **factory manager** (previously "factory worker"); child cloud agents are the **workers**. Add a recommended **giver** role per repo (`skills/giver.md`): asks ledger as a pinned issue, decision drafts for the manager to commit, healthy challenge, daily digest; never builds, merges, approves, or spends. Earlier entries that say "factory worker" mean the factory manager.
- **Why:** On Perspectiverse the coordinating bot spent most of its effort facilitating, and the owner wanted dedicated memory of asks and decisions plus a challenger; a grouping PR shipped that passed its checks but missed the owner's actual ask.
- **Alternatives:** Keep one bot for everything (rejected: overloaded memory); have the cross-repo methodology bot do it (rejected: its memory spans repos and should stay generic).
- **Revisit:** If the giver adds noise without catching misses after two weeks, drop it to digest-only.

### 2026-10-09 — The owner talks with the manager; the giver stays mostly quiet

- **Decision:** The manager is the owner's single voice in the factory room. The giver tracks in GitHub, speaks only to catch a real miss, addresses challenges to the manager, and never restates the manager's messages.
- **Why:** On the giver's first morning the owner got parallel explanations from both bots and asked not to double-communicate.
- **Alternatives:** Giver posts a daily room digest (dropped: the digest lives on the ledger unless an ask stalls).
- **Revisit:** If misses slip through because the giver stayed silent, loosen the rule.

### 2026-10-09 — Giver talks to the manager in the open; issue-only access (refines the quiet-giver entry above)

- **Decision:** The giver's challenges and back-and-forth with the manager happen in the shared room so the owner can oversee them; coordination with the owner still goes through the manager. The giver has read access plus issue/comment writes only; the manager is the single committer.
- **Why:** The owner wanted oversight of giver–manager exchanges without double-communicating; a checker shouldn't own the code it checks.
- **Alternatives:** Private giver–manager channel (rejected: no oversight); giver with repo write (rejected: blurs roles, DECISIONS conflicts).
- **Revisit:** If room traffic gets noisy, move routine exchanges to issue comments.

### 2026-10-09 — Every decision names who made it

- **Decision:** Each entry carries a "Decided by" line: the owner, with a quote or link, or the manager for its own sequencing and technical calls.
- **Why:** On Perspectiverse a log entry credited the owner with a call the manager had made; the giver caught it.
- **Revisit when:** never needed unless entries get noisy.

### 2026-10-11 — Close on proof; test the real sequence; independent benchmarks

- **Decision:** Production fixes close on a real run's log, not on merge. Guard and workflow tests reproduce the real step order and show a broken case blocked. Model-labeled benchmarks use a different model than the change being measured.
- **Decided by:** Builder (methodology), from Perspectiverse catches by the giver.
- **Why:** A publish guard was merged and its issue closed, but it never ran in production, because the workflow switched branches before calling it and the tests loaded it from main. Separately, a stance benchmark and the fix being graded would have used the same model.
- **Revisit when:** a cheaper equally reliable proof appears.

### 2026-10-11 — Blanket approvals cover only what was ready

- **Decision:** "Approve all open PRs" applies to PRs that were review-ready with evidence posted when the human said it. Drafts, later revisions, and product choices inside a PR still need an explicit approval.
- **Decided by:** Builder (methodology).
- **Why:** On Perspectiverse a blanket approval was about to stretch over an unreviewed PR and a draft whose threshold the owner had been promised a choice on.
- **Revisit when:** the owner prefers broader standing approval for a class of PRs.

### 2026-10-12 — Giver challenges priorities; manager may decline checks; end-of-day summary
- **Decision:** Giver asks "is this the right next thing?" once per issue; manager may decline a check with a reason; manager adds a short end-of-day summary on top of in-room status checks. No separate chief-of-staff/strategy bot for now.
- **Decided by:** owner (Michael, 2026-10-12: "Yeah that sounds good - I just don't want to lose status checks")
- **Why:** challenge was all rigor, little direction; manager agreed by default; owner had to dig for what needed him.
- **Revisit when:** after about a week, if priorities still aren't getting challenged, add a strategy seat.

## 2026-10-12 — Complexity rating required before model choice
- **Decision:** Every issue gets a written complexity rating (simple / standard / complex + reason) and a pinned model before any cloud-agent launch, recorded on the issue and PR body. Complex work uses `grok-4.7`; unpinned launches are stopped and relaunched.
- **Why:** Owner asked to make sure task complexity is evaluated; a launch went out unpinned and some trivial work ran on Fast mode.
- **Alternatives:** Leave routing as guidance only (rejected: it slipped).
- **Decided by:** Owner, in the factory room.
- **Revisit:** After two weeks of PR bodies, check ratings matched the outcome.

## 2026-10-12 — Complexity uses simple/standard/complex, separate from risk
- **Decision:** Complexity ratings use simple / standard / complex (they pick the model). Risk class keeps trivial / normal / high (it sets the merge gate). Trivial-risk PRs may merge on green CI without the owner.
- **Why:** Owner: "Trivial complexity is different than trivial risk"; he is fine with trivial-risk PRs merging without him.
- **Alternatives:** Reuse the same words for both (rejected: ambiguous gates).
- **Decided by:** Owner, in the factory room.
- **Revisit:** With the routing review in two weeks.

### 2026-10-12 — Document audit habits; merge commits only
- **Decision:** From a repo audit of intent vs practice: user-facing changes show the repo's key view before and after, and done claims wait for a hand audit of it; the daily check reports the repo's headline health numbers; a guarded scheduled run that skips after a same-day success is not a failure; check a PR isn't already merged before reporting it behind; the manager posts cloud-agent reviews when the agent can't comment; repo DECISIONS is giver-drafted, manager-committed and separate from this method log; the end-of-day summary and the lessons step are active; merge with merge commits only (no squash or rebase). If the owner chooses to verify on the next scheduled run instead of before merge, the PR body records that choice and the revert trigger.
- **Why:** These were working in practice but lived only in chat; squash merges lost branch history.
- **Alternatives:** Leave them unwritten; allow squash merges.
- **Revisit when:** A written habit stops matching practice, or a merge queue needs another method.

## 2026-10-13 — Number-checkable revert triggers fire automatically
- **Decision:** A revert trigger recorded in a PR body fires without a fresh owner OK when anyone can check it from the run's numbers; the manager reverts with a merge commit and reports right after. Triggers that need judgment still wait for the owner.
- **Why:** The owner already approves the trigger with the PR, reverts are cheap to redo, and waiting leaves a known-bad output live; judgment calls stay human.
- **Alternatives:** Always wait for the owner; always auto-revert.
- **Revisit:** If an automatic revert fires on a false alarm.

## 2026-10-14 — Lessons from a same-day revert
- **Decision:** (1) Verifying on the next scheduled run instead of showing the key view before merge is allowed only when the revert trigger can be checked from the run's numbers. (2) Merges touching only docs or `.factory/` skip expensive data-regeneration; merges changing output-producing code still run in full. (3) A performance or cost feature isn't shipped until a real run shows it working.
- **Why:** A user-facing change shipped without before/after evidence under a judgment-only trigger and had to be reverted; several code merges in one day each triggered a full paid run (lesson 2 only records that docs-only merges shouldn't; code-merge run cost stays an open problem); a cache was counted as done while showing zero hits.
- **Alternatives:** Keep the opt-out unrestricted; run full jobs on every merge.
- **Revisit:** If the opt-out is never used, or skipped regenerations leave stale output.

## 2026-10-14 — Missed deadlines are failures; done bars are logged, rerunnable, and catch the human's examples
- **Decision:** (1) A routine or scheduled check that hasn't posted its result by its deadline counts as a failure, and the manager or worker says so in the project room right away. (2) A done bar or revert trigger is printed in the run log, its baseline has a written measurement definition next to it, and the script or query that computes it is committed; a baseline no one can rerun can't be a done bar or revert trigger. (3) Before a metric becomes a done bar, it must pass the cases the human flagged by hand, plus a hand-checked sample of unflagged and extra-flagged items; a noisy metric becomes a hand-check flag list, not an auto-revert trigger.
- **Decided by:** Owner (Michael, 2026-10-14).
- **Why:** A routine check broke mid-morning and nobody noticed for hours; a revert was judged on a number whose script was lost and couldn't be reproduced; a replacement metric missed every hand-flagged case.
- **Alternatives:** Report only failures that post an error; keep metrics as ad-hoc numbers in chat; trust a new metric without testing it against the human's examples.
- **Revisit:** If missed-deadline alerts are mostly false alarms, or must-pass testing blocks useful metrics.

## 2026-10-16 — "Refs", not "Closes", for standing issues
- **Decision:** PRs use closing keywords only for the issue they finish. Ledgers, trackers, and parent issues get "Refs #N". Agent review checks for this.
- **Why:** A PR's "Closes" auto-closed a pinned asks ledger on merge ([perspectiverse #106](https://github.com/Data-Science-Link/perspectiverse/issues/106)).
- **Alternatives:** Re-open by hand after each mistake; lock the issue.
- **Revisit:** If GitHub adds per-issue protection from auto-close.

## 2026-10-23 — Seven rules from running a live factory
- **Decision:** (1) At most 4 coding agents at once, with a restart list on each issue. (2) Evidence saved under the commit it shows; retake only when a catch-up touches front-end files or the PR's diff. (3) A reporting or check change can't mute a recurring fault without a linked root-cause issue. (4) Outside coding agents run the same loop and gates, and need their own cost yes from the owner (this rule isn't that yes). (5) Tests never pair a hardcoded date with the real clock. (6) Quality or guard fixes are scored on a fresh sample they weren't built from. (7) Questions to the owner are one decision each, (a)/(b) with a recommended pick.
- **Decided by:** Owner (Michael, 2026-10-23).
- **Why:** Each came from a real slip: a usage limit stopped many agents at once, screenshots were retaken needlessly, a late-schedule fault nearly got reported away, a test broke when its cache aged out, a fix was scored only on the data it was tuned on, and a one-line answer was read two ways.
- **Alternatives:** Leave them as per-repo one-offs. A spend or usage ledger was proposed and declined; the owner checks usage himself.
- **Revisit:** On the next rollout to a new repo.

## 2026-10-23 — Private-repo note
- **Decision:** The method works the same on private repos. FACTORY.md gets a "Private repos" section: paid plan needed for branch protection, rulesets, and Pages; Actions minutes are a budget the daily check tracks (flag near 80%); access is granted explicitly to each bot and agent; public-facing liability gates relax, but secrets, CI, risk-class, and merge gates don't; re-run the full liability review before going public.
- **Decided by:** Owner (Michael, 2026-10-23).
- **Why:** The factory will be deployed to private repos too, where the main differences are cost and plan limits, not the loop.
- **Alternatives:** A separate private-repo template (more to maintain); no note (surprises on minutes and missing branch protection).
- **Revisit:** After the first private-repo rollout.

## 2026-10-27 — Local fallback harness (DeepInfra default)
- **Decision:** Every ready-to-work issue carries a handoff block (goal, self-contained prompt, files to read, done checks, complexity S/M/L, Cursor model + fallback model). When cloud agents can't run, the human works the issue in local desktop Cursor with their own OpenAI-compatible provider key; DeepInfra is the default filled-in provider, with one model per tier in `MODEL_ROUTING.md` (prices dated). Specs, high-stakes writing and high-risk work always use the strongest tier. Review and human gates are unchanged. The API key is never committed.
- **Decided by:** Owner (Michael, 2026-10-27: "please add this to the template and all other repos you have been helping with. Make sure to do the work fully as grok bot since cursor has no usage left."). This is the owner's cost yes for this route (FACTORY.md Rules, outside coding agents).
- **Why:** Cursor usage ran out and work stopped; a dated handoff block and a cheap open-weights route let work continue without the cloud harness.
- **Alternatives:** Wait for the monthly reset; enable Cursor on-demand spend; a different provider (any OpenAI-compatible one works with the same steps).
- **Revisit:** When model IDs or prices change, or if fallback-built PRs fail review noticeably more often.

## 2026-10-27 — Local fallback renamed to Local open-weights
- **Decision:** Renamed the DeepInfra local fallback to Local open-weights (handoff line, MODEL_ROUTING section, skill renamed to local-open-weights-run.md). Handoff block now tells cloud agents to ignore it and local agents to use it.
- **Decided by:** Owner (Michael's ask, 2026-10-27 11:17 PM CT).
- **Why:** "Fallback" didn't tell a local agent that the line was meant for it; an explicit name plus a cloud-vs-local rule removes the guesswork.
- **Alternatives:** Keep "fallback" (ambiguous for local agents); a separate handoff block per harness (more to keep in sync).
- **Revisit:** If another harness type (not cloud, not local) is added.

## 2026-10-27 — Qwen3-Coder is the default Local open-weights model
- **Decision:** Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo is the default Local open-weights model for every tier and all agentic runs. DeepSeek-V4-Flash, DeepSeek-V4-Pro and Kimi-K2.6 stay listed but are marked Needs test: a known Cursor custom-key bug drops reasoning_content after tool calls, so thinking-mode DeepSeek V4 and Kimi fail with 400 (Cursor staff, Jul 2026: https://forum.cursor.com/t/the-deepseek-v4-pro-api-cannot-be-used-normally/159042); use one only after a short local test with thinking off passes. Added a Caching and context note (DeepInfra prefix caching is automatic; stable handoff prompt first, no mid-run switches, small issues, new chat at about 60-70% of context, verify cached_tokens). The handoff-block example now names Qwen3-Coder.
- **Decided by:** Owner (Michael, 2026-10-27 11:36 PM CT: 'Yes, make Qwen3-Coder the default and mark the others as needing a test'.)
- **Why:** Qwen3-Coder is a non-thinking coder model, so it avoids the Cursor custom-key tool-call bug; the others may work with thinking off but are unproven.
- **Revisit:** When Cursor fixes reasoning_content handling for custom keys, or after a model passes the local test.

## 2026-10-28 — Labeled examples from real repos are allowed
- **Decision:** Examples from real repos are allowed in the template when they teach something and are labeled with their source repo, for illustration. The existing Perspectiverse examples in this log stay, with a note at the top and repo-qualified issue/PR numbers; the factory-loop and DOCS examples are marked the same way.
- **Decided by:** Owner (Michael, 2026-10-28: "It is ok to have specific examples so long as they are instructing and it is known to be from another specific repo for illustrative purposes."). Came through the Software Factory Builder.
- **Why:** Real cases explain why a rule exists better than invented ones, but a reader of a copied repo needs to know they came from elsewhere.
- **Alternatives:** Strip all project-specific names and numbers (loses the teaching value); leave them unlabeled (reads as if they were this repo's issues).
- **Revisit:** If an example can't be labeled without exposing something private, generalize that one instead.

## 2026-10-28 — Per-issue spend budget for Local open-weights runs
- **Decision:** For Local open-weights runs (the owner's own provider key, e.g. DeepInfra), every issue has a hard spend cap of $1. Issues are scoped to aim for under $0.10 each; complex (L) issues may go above $0.10 but never above $1. An issue that looks likely to need more than $1 is split into smaller issues. The handoff block carries a Budget line; after a run the spend is read from the provider's usage page and noted on the issue, and the run stops with a comment on the issue if spend nears $1. Cloud-agent Cursor usage is governed by the plan and is not covered by this rule.
- **Decided by:** Owner (Michael, 2026-10-28: "We should have a $1 cap on any issue and we should scope the complexity to shoot for less than a dime on all issues and high complexity can scale up"). Came through the Software Factory Builder.
- **Why:** Keeps the cost of one issue small and predictable, and makes oversized issues get split.
- **Alternatives:** A monthly cap only; no cap.
- **Revisit:** Once issue #2's cache test reports real per-issue costs.

## 2026-10-31 — Local agents: gitleaks pre-commit + CI backstop, scoped gh token, human approval for merge/repo/api commands
- **Status:** Proposed, pending Michael.
- **Decision:** Before any local agent run, the owner does the one-time setup in `skills/local-agent-safety.md`: a gitleaks pre-commit hook (`scripts/install-hooks.sh`) that blocks commits with secrets, a `secret-scan` CI workflow as a backstop, `gh` logged in with a fine-grained token limited to the factory repos (Contents, Pull requests and Issues read/write, Metadata read; no Administration, no Workflows), and the harness's command approvals left on, with `gh pr merge`, `gh repo …`, `gh api …`, pushes to `main`, force pushes and deletes always left to the human. `.env` and `.env.*` are gitignored (`.env.example` kept). `main` changes only through a PR: the owner runs `scripts/protect-main.sh` once per repo to apply the `protect-main` ruleset (`.github/rulesets/protect-main.json`: no direct push, force push or delete; PR required with 0 approvals so a solo owner can merge; merge commits only; `gitleaks` check green and branch up to date; no bypass), and `scripts/install-hooks.sh` also installs a pre-push hook that blocks pushes to `main`/`master` (human-only override `FACTORY_ALLOW_MAIN_PUSH=1`, never used by agents). On a private repo on GitHub Free, GitHub refuses rulesets (403, "Upgrade to GitHub Pro or make this repository public"), so there the pre-push hook and the merge gate are the controls.
- **Decided by:** Proposed by the Software Factory Builder at the owner's ask (Michael, 2026-10-31, issue #6; protect-main added the same day at his ask: "make sure this repo has no ability to merge to main"); waiting on the owner's approval of the PR.
- **Why:** A local agent runs commands as the owner, so a mistake or a prompt injected into something it reads could leak a secret or take a broad GitHub action. A pushed secret stays in history, so the stop has to be local and before the commit; CI only reports.
- **Alternatives:** CI scan only (finds a leak after it's public in history); the owner's full-account `gh` login (too broad); auto-run commands (no human check on merge or delete).
- **Revisit:** If the harness gets per-command allow and deny lists, if the repo moves to GitHub Pro or goes public (then run `scripts/protect-main.sh`), or after the first local run (#5).

## 2026-10-31 — Local agents stay on the factory rules: rules-first prompt, PR check, Factory review comment
- **Status:** Proposed, pending Michael.
- **Decision:** Three layers, cheapest first. (1) Every handoff Prompt starts with "Read issue #N with `gh issue view N` and `.factory/FACTORY.md` first" and ends with "Tick the done checks in the PR body as you finish them." (2) A script-only PR check (`scripts/pr-check.sh`, run by `.github/workflows/pr-check.yml`; no model, no spend) fails a PR without `Closes #N`/`Refs #N`, an agent-written PR without `AI disclosure: harness <name>; model <model ID>`, and a Local open-weights PR without a `Cost:` amount; it warns on changes to `DECISIONS.md`, `.github/workflows/` or the check itself. (3) The reviewing bot (Manager, or Builder on this repo) posts one `Factory review` comment with a pass/fix verdict and a numbered fix list (`skills/review-local-pr.md`); the owner tells the local agent "address the review on PR #N", and it fixes, pushes and replies on the PR. Local-agent PRs pass the check and the review before the human merge gate.
- **Decided by:** Proposed by the Software Factory Builder at the owner's ask (Michael, 2026-10-31, issue #7); waiting on the owner's approval of the PR.
- **Why:** Local runs skip the Manager's launch and review loop; in #2 the agent skipped plan steps and left required PR lines out. Review against the issue belongs on the PR, where it lasts, not in a chat the owner relays.
- **Alternatives:** Owner copies review notes into the local chat by hand (slow, lost); a model-based CI review (costs per run); no check (misses repeat).
- **Revisit:** After #5, the first local run through all three layers; or if the check flags too many false failures.

## 2026-10-31 — Local open-weights cost comes from the single factory key's spend difference
- **Status:** Proposed, pending Michael.
- **Decision:** Cost for a Local open-weights run is measured by calling the DeepInfra billing API (`GET /payment/key-limits`) before and after the run using the owner's single factory DeepInfra key exported as `DEEPINFRA_API_KEY`. The `scripts/deepinfra-cost.sh` script saves the pre-run spend, computes the difference on `end`, and prints the issue's `Cost:` and `Caching:` lines for the PR body. A new key per issue was considered but rejected at the owner's request (2026-10-31).
- **Decided by:** Proposed by the Software Factory Builder at the owner's ask (Michael, 2026-10-31, issue #5).
- **Why:** Cursor doesn't expose token cost to the local agent, so the only authoritative source is the provider's billing API. A single factory key avoids key-management overhead per issue.
- **Alternatives:** One new DeepInfra key per issue (rejected: too much overhead; owner asked to use the existing factory key).
- **Revisit:** If the DeepInfra billing API changes or per-issue cost tracking needs a different approach.

## 2026-10-31 — Seamless local runs: always-on rule, cost via issue comment, allowlist, automatic review
- **Status:** Proposed, pending Michael.
- **Decision:** (1) An always-on Cursor rule (`.cursor/rules/factory.mdc`) handles `do issue N` and `address the review on PR N`, lists the never rules, and tells the agent to tick a box only when the diff or a command's output proves it. (2) `scripts/factory-cost.sh start|end N` keeps the start spend in a hidden issue comment (`<!-- factory-cost-start: <spend> -->`) instead of a local state file; the key name comes from `FACTORY_DEEPINFRA_KEY_NAME`. The owner keeps `DEEPINFRA_API_KEY` and the key name in `~/.zshrc` (Keychain optional) with a spending limit on the key (`skills/local-owner-setup.md`). (3) The owner allowlists a short list of command prefixes in Cursor and runs `gh` outside the sandbox; `curl`, `gh api`, `gh pr merge`, bare `git push`, `--no-verify`, `env` and `printenv` are never allowed (`skills/local-open-weights-run.md`). (4) The Builder bot (Manager in project repos) posts a `Factory review (Builder)` comment on PR open and push, as a bot routine, not repo code.
- **Decided by:** Proposed by the Software Factory Builder at the owner's ask (Michael, 2026-10-31, issues #12 and #10); waiting on the owner's approval of the PR.
- **Why:** On the #5 run the owner pasted a long prompt, approved many commands, read cost off the usage page and relayed the review. The sandbox couldn't write `.factory-cost-start` or read the Keychain, and the agent ticked boxes it hadn't earned. Goal: the owner types `do issue N` and the run is complete, with the human gates kept.
- **Alternatives:** Local state file for cost (sandbox can't write it); pasting the handoff prompt each run (slow, drifts); turning the sandbox off or auto-approving everything (too broad); GitHub token in `~/.zshrc` (covers all repos).
- **Revisit:** After the first `do issue N` test on a small issue, or if Cursor's allowlist or sandbox rules change.

## 2026-10-31 — Local cost runs: auto-pick the key, refuse a late start, stop on failure
- **Status:** Proposed, pending Michael.
- **Decision:** (1) When no key name is set, the cost scripts read the `/payment/key-limits` list and use the only key. With more than one key they stop, list the names and ask the owner to set `FACTORY_DEEPINFRA_KEY_NAME`, so the key name is optional setup. The API key still comes only from `DEEPINFRA_API_KEY` in the environment. (2) `scripts/factory-cost.sh end N` refuses when the issue's trusted start marker was posted after the branch's first commit not on `origin/main` (author time, in UTC). The cost can't be measured then, and the PR says `Cost: not measured on DeepInfra (start was late on issue #N)`. (3) The always-on rule and `local-open-weights-run.md` make `bash scripts/factory-cost.sh start N` the first action for `do issue N`. If it fails, the agent stops and tells the owner the error. It never reads dotfiles, never searches for keys or key names, and never uses `curl`.
- **Decided by:** Proposed by the Software Factory Builder at the owner's ask (Michael, 2026-10-31, after PR #17: "I want it to work locally without all this craziness"; issue #18); waiting on the owner's approval of the PR.
- **Why:** On #16 the key name wasn't in the agent's environment, so the start failed. The agent kept going, read `~/.zshrc` (which holds the API key) to find the name, and posted the start marker after the work, so the reported cost covered only PR creation.
- **Alternatives:** Keep the key name required (the same failure again); have the agent find the name itself (the agent ends up reading secrets); accept a late marker with a warning (reports a wrong cost).
- **Revisit:** If the owner adds a second DeepInfra key, or if `/payment/key-limits` changes shape.

## 2026-11-02 — Cloud factory: run records in the PR plus an issue copy
- **Status:** Accepted.
- **Decision:** Each Actions run's record is committed in its PR as `factory/runs/<run_id>.json`, and a copy is posted on the issue (`<!-- factory-run-record -->`, trusted only from `github-actions[bot]`), so failed, rejected and closed runs still count. No separate data branch. (`.factory/VISION.md` §18, decision 1.)
- **Decided by:** Owner: "All recommended" (Michael, 2026-11-02 12:19 AM CT, in chat), accepting the recommended picks in vision §18.
- **Why:** Every dollar has to reach the dataset, including spend on abandoned work, without a second branch to manage.
- **Alternatives:** A `factory-data` branch the workflow writes to directly.
- **Revisit:** If PR conflicts on `factory/runs/` become common.

## 2026-11-02 — Cloud factory: financials dashboard is generated markdown, refreshed weekly and on demand
- **Status:** Accepted.
- **Decision:** The dashboard is a generated markdown page, `factory/financials/README.md` (Mermaid charts allowed), not GitHub Pages. A workflow refreshes it weekly at an odd minute and on demand, and opens a trivial-risk refresh PR. (Vision §18, decisions 2 and 8.)
- **Decided by:** Owner: "All recommended" (Michael, 2026-11-02 12:19 AM CT, in chat).
- **Why:** It works on a private GitHub Free repo (Pages there needs a paid plan) and reads well on GitHub mobile. Keeping it out of run PRs avoids conflicts between parallel PRs.
- **Alternatives:** GitHub Pages; regenerating the page inside every run PR.
- **Revisit:** If the repo moves to a paid plan or goes public.

## 2026-11-02 — Cloud factory: runs use the default GITHUB_TOKEN with in-job checks
- **Status:** Accepted.
- **Decision:** Actions runs use the default `GITHUB_TOKEN`. Because its PRs and pushes don't trigger other workflows, the run job runs `scripts/pr-check.sh` and gitleaks itself and sets a `factory-gate` commit status. No OpenCode GitHub App and no extra token. (Vision §18, decision 3.)
- **Decided by:** Owner: "All recommended" (Michael, 2026-11-02 12:19 AM CT, in chat).
- **Why:** No third-party app with write access and no extra secret to manage. The in-job gate is the check of record anyway.
- **Alternatives:** OpenCode GitHub App (OIDC); a fine-grained token stored as an Actions secret.
- **Revisit:** If in-job checks drift from `pr-check.yml` / `secret-scan.yml`.

## 2026-11-02 — Cloud factory: Actions-only DeepInfra key, $10/month limit (refines the 2026-10-31 single-key entry for Actions)
- **Status:** Accepted.
- **Decision:** GitHub Actions runs use a new DeepInfra key of their own, stored only as the `DEEPINFRA_API_KEY` Actions secret, with a DeepInfra spending limit of $10/month to start. The single factory key from 2026-10-31 stays for local runs only. (Vision §18, decisions 4 and 5.)
- **Decided by:** Owner: "All recommended" (Michael, 2026-11-02 12:19 AM CT, in chat).
- **Why:** Separates Actions spend from local spend, limits the blast radius if the key leaks from a runner, and gives the key-spend cross-check a cleaner number. $10 covers about 100 issues at the $0.10 target.
- **Alternatives:** Reuse the single factory key; a different starting limit.
- **Revisit:** When monthly spend nears $8 (80%), or after the first full month.

## 2026-11-02 — Cloud factory: Grok Bot writes specs; specs live as issue comments
- **Status:** Accepted.
- **Decision:** Grok Bot writes specs on its Cursor plan. A complex spec may instead be drafted by an `/oc spec` run on `deepseek-ai/DeepSeek-V4-Pro-0813`, logged like any run. The approved spec lives as a spec comment on the issue (`<!-- factory-spec v1 -->`), and the run commits it into its PR as `factory/specs/issue-<N>.md`. No separate spec PR. (Vision §18, decisions 6 and 7.)
- **Decided by:** Owner: "All recommended" (Michael, 2026-11-02 12:19 AM CT, in chat).
- **Why:** No DeepInfra spend for most specs, no extra PR before each run, and specs reach `main` with the work they describe.
- **Alternatives:** Every complex spec on V4 Pro; a spec PR merged to `main` before the run.
- **Revisit:** If Grok Bot's specs for complex work need more than one revision on average.

## 2026-11-02 — Cloud factory: keep the trivial-risk merge rule
- **Status:** Accepted.
- **Decision:** Grok Bot may still merge trivial-risk PRs after green checks and, for Actions runs, a passing gate. Normal and high risk still need Michael's approval. Workers never merge. (Vision §18, decision 9; no change to the 2026-10-07 and 2026-10-12 entries.)
- **Decided by:** Owner: "All recommended" (Michael, 2026-11-02 12:19 AM CT, in chat).
- **Why:** Simple work ships without waiting on Michael; product judgment stays with him.
- **Alternatives:** Michael approves every PR.
- **Revisit:** If a trivial merge ever changes behavior.

## 2026-11-02 — Cloud factory: fallback harness is the Claude Code Action on DeepInfra
- **Status:** Accepted.
- **Decision:** If the OpenCode + DeepInfra + Actions spike (#22) fails, switch to the Claude Code Action with `ANTHROPIC_BASE_URL=https://api.deepinfra.com/anthropic`. No custom harness. (Vision §18, decision 10.)
- **Decided by:** Owner: "All recommended" (Michael, 2026-11-02 12:19 AM CT, in chat).
- **Why:** A maintained action on the same provider keeps the rest of the design (specs, run records, gate) unchanged.
- **Alternatives:** A thin custom harness script.
- **Revisit:** If both actions fail with DeepInfra models.

### 2026-11-01 — Cloud factory roles (CEO, manager, compute, inference, repo, worker)
- **Status:** Proposed, pending Michael.
- **Decision:** Adopt the vision roles in `FACTORY.md`: **CEO** (Michael), **Factory Manager** (Grok Bot), **Compute** (GitHub Actions runners), **Inference** (DeepInfra), **System of record** (the GitHub repo), **Worker** (OpenCode harness on Actions). Optional **Giver** unchanged. Cursor cloud agents and Local open-weights are backup/optional paths, not the default worker for selected project issues.
- **Decided by:** Owner (Michael, 2026-11-01, factory vision notes: standardized cloud factory with Michael setting direction and Grok Bot running the line).
- **Why:** One shared vocabulary for who does what; separates judgment (CEO), orchestration (manager), rented compute, token supplier, and the non-merge worker.
- **Alternatives:** Keep the older "human owner / factory manager / child cloud agents" table only (rejected: blurs Actions worker vs Cursor agents).
- **Revisit:** After the first end-to-end `/oc run` on a selected issue.

### 2026-11-01 — Michael chooses which issues get worked (`factory:selected`)
- **Status:** Proposed, pending Michael.
- **Decision:** Not every issue becomes agent work. Only issues Michael selects — label `factory:selected` on GitHub or "select #N" to Grok Bot — get a spec and an Actions run. Intake issues without selection stop at the issue record.
- **Decided by:** Owner (Michael, 2026-11-01: "What I want is standardization… Michael chooses the work" and "Only issues Michael selects get a spec and a run" in vision notes).
- **Why:** Prevents the factory from running on every filed idea; keeps spend and attention on chosen work.
- **Alternatives:** Auto-triage every open issue (rejected: no explicit CEO choice).
- **Revisit:** If selection becomes a bottleneck, add a lightweight queue view — not auto-selection.

### 2026-11-01 — Standard spec, standard PR, standard run record
- **Status:** Proposed, pending Michael.
- **Decision:** Every worked (selected) issue gets a spec with the same base sections (from `.factory/templates/spec.md`). Every factory PR uses the same template contents (PR template v2). Every Actions agent run writes the same run record JSON (`factory/runs/<run_id>.json`, schema in `.factory/schemas/run-record.schema.json` when landed). Cost is deterministic from usage × the committed price table, not guessed after the fact.
- **Decided by:** Owner (Michael, 2026-11-01: "every worked on issue to have a spec, the same contents of a PR, the same logged data per agent run" and track tokens/cost on a standard dashboard).
- **Why:** Commodity spend needs comparable units; auditors and Michael can read any PR or run the same way.
- **Alternatives:** Ad-hoc issue comments and hand-filled PR bodies only (rejected: already caused misses on local runs).
- **Revisit:** After ten runs, check whether extended spec sections are too heavy for simple issues.

### 2026-11-01 — Default worker path: GitHub Actions + DeepInfra
- **Status:** Proposed, pending Michael.
- **Decision:** The default harness for selected project issues is a GitHub Actions run (`/oc run`) using OpenCode (or the decided fallback action) and DeepInfra models per `.factory/models.yaml`. Local open-weights and Cursor cloud agents remain documented fallbacks for building the factory and when Actions can't run.
- **Decided by:** Owner (Michael, 2026-11-01: buy code on rented machines through one standard process with every unit metered; phone kickoff via `/oc run`).
- **Why:** Matches the commodity-factory model: metered tokens, clean VM per run, no laptop required after one-time setup.
- **Alternatives:** Cursor cloud agents as default (rejected for project issues: plan pooling and less deterministic cost capture).
- **Revisit:** If the OpenCode spike fails, switch default worker to Claude Code Action on DeepInfra (2026-11-02 accepted fallback).

### 2026-11-02 — DeepInfra default worker model and escalation (models.yaml)
- **Status:** Proposed, pending Michael.
- **Decision:** GitHub Actions factory workers default to `deepseek-ai/DeepSeek-V4-Flash-0731` (standard tier). Escalate to `deepseek-ai/DeepSeek-V4-Pro-0813` for high risk, complex work, `/oc spec` runs, and one retry after Flash fails on standard work. On DeepSeek tool-call or reasoning-format errors, fall back to `Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo` and open an issue. Prices, priors, and rules live in `.factory/models.yaml`; `MODEL_ROUTING.md` explains them for humans.
- **Decided by:** Proposed by a Cursor cloud agent (composer-2.5) implementing issue #26; Michael decides at merge.
- **Why:** One machine-readable table lets routing and cost scripts stay deterministic; Flash is the cheapest capable default for simple/standard work under the $0.10 target.
- **Alternatives:** Keep Qwen3-Coder as the local default only (2026-10-27) without a separate Actions table; duplicate prices in scripts instead of YAML.
- **Revisit:** After the OpenCode spike (#22) reports tool-call results; after the first month of forecast vs actual (#36).

### 2026-11-02 — PR template v2 factory-run block and pr-check detection
- **Status:** Proposed, pending Michael.
- **Decision:** Live PR template v2 (`.github/pull_request_template.md`) adds Spec, a factory-run field block (labels aligned with run record `run_id`, token fields, `predicted_cost_usd`, `actual_cost_usd`, `gate`, `spec_path`), and a workflows safety line. `scripts/pr-check.sh` applies the extra factory-run rules only when the body contains `<!-- factory-run:start -->` (inserted by `scripts/factory-run-end.sh`, not in the empty template) or the AI disclosure line names harness opencode-actions. Scripts fill run facts deterministically; the worker model writes only the labeled "What I changed and why" narrative (#28 issue comment).
- **Decided by:** Proposed by Cursor cloud agent implementing issue #28; Michael decides at merge (high-risk CI check change).
- **Why:** Same PR shape for every Actions run without breaking human or Cursor-agent PRs that omit the factory marker; empty template placeholders must not fail pr-check.
- **Alternatives:** Treat any `Run ID:` line in the template as a factory PR (rejected: fails every PR opened from the default template).
- **Revisit:** After #30 lands and the first real `/oc run` PR body is gate-filled.

### 2026-11-02 — /oc worker path policy: new scripts allowed, existing guardrails locked (#63)
- **Decision:** The `/oc` worker may add new files directly under `scripts/` (hyphenated names, no subdirectories) and edit or add docs under `.factory/`. It may not modify, delete, rename, move out or chmod an existing script. Still always forbidden: `.github/**`, `opencode.json`, `.factory/actions-security.md`, `.factory/models.yaml` (routing and budget caps are owner-only), archives, `gitleaks_*`, every other dot-path at any depth, symlinks, submodules and binary files. `.gitignore` files accept added lines only (no deleted or changed lines, no delete, rename or mode change). The rules live once in `scripts/opencode-artifact-scan.sh` (`--list-rules` feeds the worker prompt; the patch parser enforces them by file status), and publish keeps judging each patch with the pristine `HEAD` copy of the scan.
- **Decided by:** Owner. Michael, 2026-11-02 11:58 AM CT, on the recommendation for #63: "I like your recommendation - feel free to implement that".
- **Why:** Run 41487596046 (#32) lost about 7 minutes of work because a `.gitignore` line tripped the old blanket `scripts/` and dot-path rules. New tooling belongs next to the other scripts, but the existing scripts are the guardrails that judge, push and check every run, so they stay locked.
- **Alternatives:** Keep `scripts/` fully blocked and steer tooling to `factory/<area>/` (rejected: wrong home for new tooling, and the worker kept falling into it); allow edits to existing scripts (rejected: a patch could weaken its own guard after merge); drop only the offending hunks (deferred).
- **Revisit when:** A workflow starts globbing `scripts/*` (a new script would then run in CI), or a run is lost to a rule that should have been allowed.

### 2026-11-02 — requirements-factory.txt is owner-only for /oc workers (#63)
- **Decision:** Add `requirements-factory.txt` to `FORBIDDEN_PATTERNS` in `scripts/opencode-artifact-scan.sh`, the single path-policy list shown to the worker by `--list-rules` and `--list-forbidden`. An `/oc` patch that creates, edits, renames or deletes it is discarded whole. Other requirements files, such as a future `factory/dbt/requirements-dbt.txt` (#64), aren't affected.
- **Decided by:** Owner. Michael, 2026-11-02 1:57 PM CT: "Yes on the requirements.txt that sounds good".
- **Why:** CI (`pr-check`, run-record tests) and the worker job both `pip install -r requirements-factory.txt`, so a worker that adds or re-pins a package changes the supply chain for every later run and check. Dependency changes are high risk under `.factory/skills/liability-gates.md` and need the owner.
- **Alternatives:** Leave it writable and rely on review (rejected: a pin change is easy to miss in a large diff); allow added lines only, like `.gitignore` (rejected: adding a package is the risky case).
- **Revisit when:** #64 splits the requirements files, or a spec legitimately needs a new pinned dependency often enough that owner-only edits become a bottleneck.

### 2026-11-02 — `/oc fix`: review fixes on an existing bot PR (#55)
- **Status:** Proposed, pending Michael (takes effect when the PR merges and the owner pastes `.github/workflows/opencode-fix.yml`).
- **Decision:** An owner `/oc fix <instruction>` comment on an open same-repo PR whose head is `oc/issue-<N>-<run_id>` starts a two-job run. Job A (read tokens only for the context step) checks out the PR head next to the trusted default-branch checkout and gives the worker the linked issue body + approved spec (reusing `opencode-build-context.py`), the PR file list, and owner review/PR comments since the last push (capped, untrusted data), plus the text after `/oc fix`. The patch is relative to the PR head and passes the same artifact scan and path policy. Job B re-checks the PR, pushes one commit to the same branch with `--force-with-lease` on job A's head SHA, and comments run facts and the labeled worker note on the PR. No new PR, no merge.
- **Decided by:** Proposed by Grok Bot (Software Factory Builder) for issue #55; Michael decides at merge.
- **Why:** Review fix rounds need a path that doesn't depend on Cursor credits (#55). Pushing to the same branch keeps one PR per issue and one review thread; the lease means a hand push during the run is never overwritten.
- **Alternatives:** Stacked PR per fix round (rejected for now: splits review and cost records; still the fallback if the branch isn't writable); fixing only the latest Factory review comment (rejected: inline review comments and short follow-ups were missed); letting the fix patch edit scripts the PR itself added (deferred: the scan judges against the PR head, so those count as existing scripts).
- **Revisit when:** #74 lands (checks on workflow-token pushes), or a fix round is lost because it needed to edit a script the earlier run added.


### 2026-11-02 — /oc spec file is written by the harness, not copied by the worker (#75)
- **Status:** Proposed, pending Michael (takes effect when the PR merges; no workflow paste needed).
- **Decision:** Job A's context step saves the validated approved spec comment as `spec.md` (from the marker line on, LF line ends, one trailing newline) with its sha256. The agent script writes `factory/specs/issue-<N>.md` from it before the model runs, tells the worker not to touch it, and overwrites any worker edit before building the patch (a patch that changes only that file counts as no work). `/oc fix` restores the same exact copy on the PR branch. Publish (build and fix) re-fetches the spec comment by id with its own token, re-validates it with the pristine `opencode-build-context.py --print-spec`, and refuses if the committed file differs. `factory-spec-check.py` now rejects escaped quotes (`\"`) in front matter, and spec comments with CRLF line ends are recognized.
- **Decided by:** Proposed by Grok Bot (Software Factory Builder) for issue #75; Michael decides at merge.
- **Why:** On #72 the worker hand-copied the spec, escaped its quotes (breaking `approved_at`) and appended a stray context heading, and the checker passed it. Facts come from scripts (#28/#31); the spec is a fact.
- **Alternatives:** Let the worker copy it and only check the result (rejected: still model-copied, and a check after the fact discards the run); write the file only in publish (rejected: the worker and the verification step need it in the tree).
- **Revisit when:** A spec needs per-run edits (it shouldn't), or specs move to their own PR.

### 2026-11-02 — /oc verification is run by the harness; the worker shell stays git-only (#76, #80)
- **Status:** Proposed, pending Michael (takes effect when the PR merges; the optional workflow paste raises the agent job timeout from 15 to 20 minutes).
- **Decision:** Build and fix workers keep the same git-only shell from the shared `opencode.json` (the build run on #72 could not run dbt either; its log shows every non-git command denied). After the worker finishes and the patch passes the scan, `scripts/opencode-verify.sh` runs the first `bash` block under the spec's `## Verification` on a scratch copy of the base commit plus the patch, as a separate unprivileged user with an empty environment, under a time budget, and saves the output as `evidence.md`. Publish pastes it into the PR body's Evidence (and the `/oc fix` comment), fenced, capped at 12 KB and labeled as run by the harness, not the model.
- **Decided by:** Proposed by Grok Bot (Software Factory Builder) for issues #76 and #80; Michael decides at merge.
- **Why:** The worker's environment holds `DEEPINFRA_API_KEY`, so allowing python, dbt or bash in its shell would put the key one `env_var()` away from a prompt-injected worker. A script-run verification also makes the evidence a fact rather than a model claim, in line with #28/#31.
- **Alternatives:** Allow `python3*`, `dbt*`, `bash scripts/test-*` in `opencode.json` and have the worker write `.oc/evidence.md` (rejected: key exposure, and the evidence would be model-written); block the network during verification with a network namespace (deferred: the spec's `pip install` needs the network; would need a trusted pre-install step).
- **Revisit when:** A spec needs the worker to iterate on failing tests inside the run, or OpenCode can keep the provider key out of the tool environment.

### 2026-11-02 — /oc PR body: risk from the spec, labeled worker note, fenced text ignored by pr-check (#76)
- **Status:** Proposed, pending Michael (takes effect when the PR merges).
- **Decision:** The publish PR body ticks the Risk class box from the spec's front matter (`opencode-run-facts.sh --risk`; no spec or no risk → high), the same source as its `Gate:` line, and adds `## What I changed and why` with the worker's labeled note (model-written, unverified; fenced, capped at 3000 bytes, mentions and HTML comments defanged by `scripts/opencode-text-block.sh`, the same treatment the fix comment had). `scripts/pr-check.sh` ignores fenced code blocks, so pasted evidence or a note can't satisfy a missing rule line. `/oc fix` comments say `Predicted cost: not predicted (fix run)` instead of repeating the build's prediction.
- **Decided by:** Proposed by Grok Bot (Software Factory Builder) for issues #76 and #80; Michael decides at merge.
- **Why:** #72's body said "risk normal" in the Gate line while the box was hard-coded high, dropped the worker's narrative, and the fix comment repeated the build's predicted cost.
- **Alternatives:** Keep every /oc PR high risk (rejected: the spec's risk class is the gate of record); a separate prediction for fix runs (deferred until fix runs have enough history to predict from).
- **Revisit when:** Fix runs have ten or more records to base a prediction on.

### 2026-11-02 — Checks on bot PRs: approve the waiting runs or close/reopen as the owner (#74)
- **Status:** Proposed, pending Michael (docs + `scripts/factory-kick-checks.sh`; no workflow change).
- **Decision:** No new secret and no workflow trigger change. A PR opened or pushed with `GITHUB_TOKEN` gets its `pull_request` runs in an approval-required state (seen on #72: runs created at PR open and after the fix push sat waiting until the PR was closed). Before review, Michael clicks **Approve workflows to run** on the PR, or Grok Bot runs `bash scripts/factory-kick-checks.sh <PR>` from the owner's gh login, which closes and reopens the PR only when pr-check or gitleaks is missing on the head commit and only for open same-repo `oc/issue-<N>-<run_id>` PRs.
- **Decided by:** Proposed by Grok Bot (Software Factory Builder) for issue #74; Michael decides at merge.
- **Why:** GitHub documents that checks from `workflow_dispatch` (and other non-PR events) are not evaluated for pull requests or required status checks in a ruleset, so a dispatch from job B can't satisfy `pr-check` / `gitleaks`; `workflow_run` runs on the default branch's commit. A PAT or GitHub App would let checks start on their own but is a new long-lived secret.
- **Alternatives:** Job B dispatches the check workflows (rejected: checks don't count for the PR); a fine-grained PAT or GitHub App token in job B (rejected for now: new long-lived secret with write access); job B creates check runs itself via the Checks API (rejected: a workflow could mint a passing required check).
- **Revisit when:** The manual step is missed on a merge, or GitHub lets workflow-created PRs run checks without approval.

### 2026-11-02 — Live /oc run fixes: verification scratch under /tmp; spec re-check falls back on HTTP 403 (#75, #76)
- **Status:** Proposed, pending Michael (scripts take effect when the PR merges; full-strength spec re-check needs `issues: read` pasted on both publish jobs).
- **Decision:** `scripts/opencode-verify.sh` puts its scratch copy under `/tmp` (not `RUNNER_TEMP`, which is under `/home/runner`, mode 750) and reports "not run" if the sandbox user can't reach it. When publish can't re-fetch the spec comment because its token lacks `issues: read` (HTTP 403), it validates job A's `spec.md` with the pristine checker, requires the `spec_sha256` job A recorded, and labels the PR's spec line `checked by publish against job A's copy only`. Any other fetch failure still refuses. Proposed workflow paste: `issues: read` on the publish job of `opencode-spike.yml` and `opencode-fix.yml`.
- **Decided by:** Proposed by Grok Bot (Software Factory Builder) after live run 41553660354 on #58; Michael decides at merge.
- **Why:** That run's verification failed at `cd` (Permission denied) and its publish failed on the re-fetch (no `issues: read`), so no PR opened. Both were missed offline: the tests used `/tmp` and a fixture instead of `gh api`.
- **Alternatives:** Refuse on 403 until the paste (rejected: every `/oc` run fails until Michael is back); drop the re-fetch (rejected: job A's copy is the weaker anchor and should stay the fallback only).
- **Revisit when:** `issues: read` is pasted (the fallback then never fires; keep it or drop it).

### 2026-11-02 — `/oc spec`: a read-only V4 Pro worker drafts specs as draft comments (#78)
- **Status:** Proposed, pending Michael (scripts take effect when the PR merges; the run needs the owner paste of `.github/workflows/opencode-spec.yml` and the one-line `/oc spec` exclusion in `opencode-spike.yml`).
- **Decision:** An owner `/oc spec [guidance]` comment on an issue starts a two-job run. Job A has the DeepInfra key and read tokens only. It gets the same issue context as `/oc`, and a read-only OpenCode worker (edit, bash, web and external directories denied for the run) drafts one spec. The worker uses DeepSeek V4 Pro, the models.yaml rule with `when: {work_type: spec}` (rule 2), set by the script. `scripts/opencode-spec-draft.py` extracts the spec between marker lines, sets the harness-owned front matter (status draft, approved_by/at null, drafted_by oc-spec-run, model and predicted cost from `factory-predict-cost.py`), and runs the spec checker plus the #78 checks. Job B has `issues: write` and `contents: read` only. It rescans and re-checks, then posts the draft, or a "no draft" note that lists what failed. If job A fails, it posts a failure note with the run link. Spend: preflight refuses above the $1 cap, the worker stops at 480 s, a run that cost more than $1 posts no draft, and the comment shows cost against the $0.10 target. Review and approval: Grok Bot for trivial and normal risk, Michael for high (see the spec-approval entry dated 2026-11-02 below).
- **Decided by:** Proposed by Grok Bot (Software Factory Builder) for issue #78; Michael decides at merge.
- **Why:** Michael wants a high-intelligence spec worker so Grok Bot stays the coordinator (#78). Keeping facts in scripts (#28/#31) and approval with the owner keeps a model from approving or pricing its own spec.
- **Alternatives:** Flash for simple issues (deferred: spec quality matters most and the prediction is about $0.08 on Pro); letting the worker read the repo with a shell (rejected: key exposure, as for build runs); posting drafts from job A (rejected: job A would need a write token next to the key).
- **Revisit when:** The first few drafts have been reviewed (#78 says check them closely), or models.yaml gets a `token_priors.spec` row from real spec-run costs.

### 2026-11-02 — Spec approval stays "owner posts the approved copy"; helper script, no `/oc approve-spec` (#78)
- **Status:** Proposed, pending Michael (takes effect when the PR merges).
- **Decision:** No new approval command or workflow. `/oc` keeps reading only the latest OWNER comment with the marker and `status: approved` (`opencode-build-context.py`, unchanged). To approve a draft, Grok Bot or Michael runs `python3 scripts/factory-approve-spec.py <issue> <draft URL> --approved-by <who> [--from-file edited.md]` from the owner's gh login. It checks that the draft came from the workflow, sets status, approved_by and approved_at, re-runs the checks and the prediction, and posts the approved copy, which the build run then copies byte for byte. `approved_by` is `grok-bot` for trivial or normal risk and must be `michael` for high risk (the spec-approval entry below). Grok Bot passes `michael` only after Michael approves in chat.
- **Decided by:** Proposed by Grok Bot (Software Factory Builder) for issue #78; Michael decides at merge.
- **Why:** This is the least new machinery and the current context code needs no change. An `/oc approve-spec` reply would need a workflow that posts as `github-actions`, and the context step rightly ignores non-owner comments.
- **Alternatives:** `/oc approve-spec <url>` handled by a workflow (rejected: bot-authored approvals, a new write path); approving by editing the draft comment (rejected: the bot authored it, and edits leave no new comment).
- **Revisit when:** Michael wants to approve from his phone without Grok Bot; a phone reply could then trigger Grok Bot to run the helper.

### 2026-11-02 — factory-predict-cost.py reads specs that start with the marker line (#60, marker part)
- **Status:** Proposed, pending Michael (takes effect when the PR merges).
- **Decision:** `factory-predict-cost.py` skips everything up to and including the `<!-- factory-spec v1 -->` line, so it runs on a spec comment body, and `--write` keeps that prefix. The `--write` reformatting part of #60 (YAML dump) is unchanged and stays open. `/oc spec` and the approval helper do their own line edits instead of `--write`.
- **Decided by:** Proposed by Grok Bot (Software Factory Builder) for issue #60; Michael decides at merge.
- **Why:** The #58 spec comment had to have its marker stripped by hand before prediction (live run 2026-11-02).
- **Alternatives:** Strip the marker in every caller (rejected: the same bug in each caller).
- **Revisit when:** #60's `--write` fix lands.

### 2026-11-02 — Spec approval by risk class: Grok Bot approves trivial and normal, Michael approves high
- **Status:** Accepted (Michael's standing decision, 2026-11-02). Enforced by `scripts/factory-approve-spec.py` when the `/oc spec` PR (#86) merges.
- **Decision:** Grok Bot reviews and approves specs with risk **trivial** or **normal** (`approved_by: grok-bot`), whatever their complexity. Michael reviews and approves **high**-risk specs (`approved_by: michael`) and may approve any spec. The `/oc spec` draft's Review and Approval lines, `factory-approve-spec.py` and the docs (`factory/specs/README.md`, `.factory/FACTORY.md` step 5, `.factory/skills/factory-loop.md`, `.factory/VISION.md` step 5) follow this. It supersedes the earlier rule (Michael for standard/complex or normal/high; Grok Bot only simple + trivial, `grok-bot (simple+trivial)`); specs already approved under it stay valid.
- **Decided by:** Michael, 2026-11-02 (standing decision, relayed by the Factory Manager).
- **Why:** Keeps Grok Bot as the coordinator for routine specs (#78) and keeps Michael's attention on high-risk work.
- **Alternatives:** The earlier rule (Michael for normal risk too); complexity-based approval (dropped: risk is what needs a human).
- **Revisit when:** A Grok Bot-approved normal-risk spec leads to a bad merge, or the first `/oc spec` drafts show review gaps.

### 2026-11-06 — Rule 1 builds go to Qwen3-Coder; V4 Pro stays the spec architect (#128)
- **Status:** Accepted (Michael, 2026-11-06). Takes effect when the PR merges.
- **Decision:** In `.factory/models.yaml`, rule 1 (`risk: high` or `complexity: complex`) now routes `/oc` builds and `/oc fix` runs to `Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo` instead of `deepseek-ai/DeepSeek-V4-Pro-0813`. Rule 2 (`work_type: spec` → V4 Pro) now sits above rule 1, so a spec run always stays on Pro. The build worker prompt (`scripts/opencode-agent-run.sh`) also says: no `bash` for `ls`, `find` or reading files; `glob` and `grep` skip dot-directories, so use `read` with an exact path under `.factory/`; and with an approved spec, read only the files it names and start editing promptly.
- **Decided by:** Michael, 2026-11-06 in chat: "This all sounds good" (Grok Bot's recommendation to keep V4 Pro as the `/oc spec` architect, move rule 1 builds to Qwen3-Coder-480B-Turbo, and tighten the worker prompt).
- **Why:** The #30 build (run 42282682618) hit the 780 s worker limit before writing a file. V4 Pro spent about 35 s thinking per tool turn across about 25 reads, including a denied `ls` and empty globs over `.factory/`. The spec run had already done the deep thinking. Qwen3-Coder takes about 2–4 s per tool turn and predicts $0.178 (complex) or $0.19 (standard, high risk), vs $0.498 / $0.47 on Pro.
- **Alternatives:** A longer worker timeout on Pro (rejected: slower and pricier per run); `thinking: off` on V4 Pro (unproven); routing builds to Cursor or Grok models (deferred to #127 under #117, because DeepInfra open weights stay the primary backbone).
- **Revisit when:** Qwen3-Coder builds fail review noticeably more often than Pro builds, or a high-risk build needs deeper reasoning than the spec gives.

### 2026-11-07 — $0.15 issue target with an explicit over-target approval; V4 Flash for non-high-risk `/oc spec`
- **Status:** Accepted (Michael, 2026-11-07). Takes effect when the PR merges.
- **Decision:** `budget.issue_target_usd` is $0.15. When an approved spec's own build prediction (current `models.yaml`, no retry context) is above it, `factory-run-start.py` refuses `/oc` and `/oc fix` with `over_target_unapproved` unless the spec's front matter has `over_target_approved_by: michael`, whatever the risk class. Only Michael sets it, through the existing approval helpers (`opencode-spec-draft.py approve` / `factory-approve-spec.py` with `--approved-by michael --over-target-ok`). `/oc spec` drafts strip the field, and their comment's first line says `Over $0.15 target: needs Michael's approval`. Routing: rule 2 (`work_type: spec`, `risk: high`) keeps V4 Pro; new rule 9 (`work_type: spec`) sends other spec runs to V4 Flash. The spec run treats an issue as high risk when its context or the `/oc spec` guidance says so, or when there is no context (fail safe to Pro).
- **Decided by:** Michael, 2026-11-07 in chat: "Yes: open the owner PR for the $0.15 target with the explicit over-target approval flag, and trial Flash for the #64 spec, keeping Pro for high-risk specs."
- **Why:** Standard-prior builds on Qwen3-Coder predict $0.19, above the old $0.10 target, which only warned. A hard stop with a one-line flag keeps spend visible without new machinery. Flash costs about 1/15 of Pro per spec run; #64 is the trial.
- **Alternatives:** A label or a separate approval comment (rejected: new parsing and a new trust path); gating on the routed prediction including retries (rejected: a Pro retry would need a second approval).
- **Revisit when:** Flash spec drafts fail the checks or review noticeably more often than Pro drafts, or most builds need the over-target flag.

