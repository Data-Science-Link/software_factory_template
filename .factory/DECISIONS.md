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
