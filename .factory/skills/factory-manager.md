# Skill: factory-manager

**For the Factory Manager** — the repo’s persistent coordinating bot on the owner’s chat plan. This is the operating manual for running the cloud factory day to day. Workers follow [`factory-loop.md`](factory-loop.md); this skill is how the manager orchestrates selection, specs, runs, gates, reviews, merges within authority, and routines.

**Read first:** [`.factory/FACTORY.md`](../FACTORY.md) (thin playbook), [`.factory/VISION.md`](../VISION.md) §4 (lifecycle), [`ADOPTING.md`](../../ADOPTING.md) (owner/agent commands). **Review format:** [`review-local-pr.md`](review-local-pr.md) applies to **every** factory PR — Actions `/oc` PRs and local-agent PRs alike; only the harness name in the PR body differs.

**Repo-agnostic:** say **the owner** and **the Factory Manager**; copy this file into any adopting repo unchanged except where `DOCS.md` names repo-specific paths.

---

## Manager never

- Merge **normal** or **high** risk without the owner’s named approval recorded on the PR body first.
- Turn on on-demand spend.
- Decide product trade-offs (thresholds, UX choices, “which option”) without an owner pick.
- Start `/oc run` or `/oc fix` when the issue is already at the **$1** cap, or when more than **four** coding runs are active repo-wide (or the cap in `DECISIONS.md`).
- Post owner-only workflow YAML; paste proposed workflow blocks for the owner to add by hand.

Workers **never** merge.

---

## Lifecycle: what the manager does

Aligned with [`.factory/VISION.md`](../VISION.md) §4.

| Stage | Manager does |
|---|---|
| **1. Intake** | Ensure a one-sentence **outcome** on the issue; hand off from coordinator if used (`intake-from-coordinator.md`). Stop if not selected. |
| **2. Selection** | React to `factory:selected` or “work on #N” / “select #N”: confirm outcome, label if needed, group related issues under **one spec** when cheaper. |
| **3. Spec** | Write spec from [`.factory/templates/spec.md`](../templates/spec.md); run checks; post draft or approved comment; route approval (below). |
| **4. Classify** | Set complexity, risk, model, predicted cost in front matter; split if predicted **> $1**. |
| **5. Spec approval** | Review draft; approve trivial/normal via helper; escalate high risk and over-target spend to owner. |
| **6. Run** | Post `/oc run` (owner account) or tell owner to; watch concurrency and cap. |
| **7. Gate** | Read run record / PR `Gate:` line; on fail, triage once (escalation) or report; on pass, continue. |
| **8. PR** | Ensure template + factory-run block; kick `pr-check` / `gitleaks` on bot PRs if needed (`scripts/factory-kick-checks.sh`). |
| **9. Review** | One **`Factory review`** comment per round (`review-local-pr.md`). |
| **10. Approval by risk** | Trivial: merge after green CI + gate. Normal/high: **owner gate** on PR body, then merge. |
| **11. Merge** | Update branch to default; green head; merge commit only; within authority table in `FACTORY.md`. |
| **12. Logging** | Confirm run record on issue/PR; failed runs still logged. |
| **13. Financials** | Rely on site/dataset refresh routines (below); weekly spend message to owner. |

---

## Selecting and triaging

1. **Selection gate:** No spec and no `/oc` without `factory:selected` (owner label or explicit “select #N”).
2. **Outcome:** If missing, ask once on the issue, then stop guessing.
3. **Grouping:** Multiple issues with one build → one spec (`issues: [N, M]` in front matter).
4. **Triage note** on the issue before spec work: complexity, risk, intended model tier (from `.factory/models.yaml` / `MODEL_ROUTING.md`).
5. **High-risk intake** (license, secrets, auth, workflows, safety): standard/complex spec, owner spec approval, owner merge gate.

---

## Writing specs

**Default:** Factory Manager writes the spec on the **chat plan** (no DeepInfra spend).

**`/oc spec` (complex only):** For **complex** work, the manager may comment `/oc spec [guidance]` on the issue. That run uses the spec architect model (`work_type: spec` in `models.yaml`), is **metered like any run**, and posts a **draft** comment (`<!-- factory-spec-draft v1 -->`, `status: draft`). Do **not** use `/oc spec` for simple/standard specs unless the owner explicitly asks for a trial. After the draft:

1. Edit if needed.
2. Run `python3 scripts/factory-spec-check.py` on the body.
3. Run `python3 scripts/factory-predict-cost.py` (use `--write` when refreshing front matter).
4. Approve with `python3 scripts/factory-approve-spec.py` (below).

**Posting an approved spec:** Comment on the issue with marker `<!-- factory-spec v1 -->`, front matter `status: approved`, and complete base sections (extended sections per complexity/risk in the template). The build run copies it byte-for-byte to `factory/specs/issue-<N>.md`; the worker must not author that file.

**Checks before approval:**

```bash
python3 scripts/factory-spec-check.py path/to/spec.md
python3 scripts/factory-predict-cost.py --write path/to/spec.md   # when updating front matter
```

---

## Spec approval and `factory-approve-spec.py`

| Risk class | Who approves spec (`approved_by`) |
|---|---|
| trivial, normal | Factory Manager (`--approved-by grok-bot` or your bot id) |
| high | **Owner only** (`--approved-by michael` or owner login) |

From the owner’s trusted `gh` login (or manager acting after owner says “approve spec #N”):

```bash
python3 scripts/factory-approve-spec.py <issue> <draft-comment-URL> \
  --approved-by grok-bot|michael [--from-file edited.md]
```

`/oc run` reads only the latest **owner** comment with `status: approved` and the marker — not drafts.

**Cost gates on specs and runs**

| Limit | Source | Manager action |
|---|---|---|
| **$0.15 issue target** | `factory/budget.yml` → `issue_target_usd` (also in `models.yaml` budget) | If predicted build cost is above target, spec comment must carry owner **`over_target_approved_by`** via `factory-approve-spec.py ... --approved-by michael --over-target-ok`, or **split the issue**. |
| **$1 hard cap per issue** | `issue_cap_usd` | Do not start a run if issue spend ≥ $1; split first. Target most issues **under $0.15**; complex work may approach but never exceed **$1** summed over all runs. |

---

## Phone kickoff and owner commands

After one-time setup ([`ADOPTING.md`](../../ADOPTING.md), owner workflows pasted), the owner can drive the line from a phone.

**Owner phrases (match vision §14)**

| Phrase | Manager action |
|---|---|
| `work on #N` / `select #N` | Select; confirm outcome; start spec if missing. |
| `approve spec #N` | Run approve helper on the latest draft URL after review. |
| `run #N` | Post `/oc run` on #N (if spec approved and under cap). |
| `approve #P` | Record product gate on PR #P; merge if trivial or after body updated for normal/high. |
| `fix the review on #P` | Post `/oc fix <numbered list from Factory review>` on PR #P. |
| `what did the factory cost this month?` | Summarize from latest **factory site** / financials dataset (MTD, run rate). |

**Slash commands (owner comment only; must *start* with the command)**

| Command | Purpose |
|---|---|
| `/oc spec [guidance]` | Draft spec (complex / owner-directed). |
| `/oc run` or `/oc <instruction>` | Build from approved spec. |
| `/oc fix <what to fix>` | Fix round on open `oc/issue-<N>-<run_id>` PR. |

---

## Batched checkpoints (recommendation-first gates)

Batch owner decisions at natural pauses — **one chat message**, multiple choices, each with **Recommendation** and **Why**. Use phone-friendly **(a) / (b)** (one decision per question). Do not merge on chat alone; mirror the choice on the PR body when it is a product gate.

**Typical batches**

1. **Spec ready** — (a) approve spec as posted (b) edit scope first. Recommendation + cost/risk consequence.
2. **PR ready (normal/high)** — (a) approve #P for merge (b) hold for X. Include risk class, cost actual vs predicted, gate summary, link to Evidence.
3. **Fix vs split** — after two failed fix rounds or repeated gate fail: (a) one more `/oc fix` (b) split issue / owner patch.
4. **End of day** — open decisions only; what shipped; what failed gates need owner.

**Standing rules:** “Approve whatever you recommend” counts only when the recommendation was stated **for that PR** in the room and named in the PR body. Blanket “approve all open PRs” covers only PRs that were review-ready at that moment.

---

## Starting and monitoring runs

1. Confirm **approved spec**, under **$1** issue spend, prediction acceptable (or `over_target_approved_by` set).
2. Post `/oc run` as the **owner** GitHub user (manager uses owner’s account per repo policy).
3. **Concurrency:** at most **four** active coding runs; keep a **restart list** on each issue (branch, run id, next step).
4. On workflow failure notification, read `refused=` reason (spec missing, over target, cap, etc.) and act from `scripts/opencode-notify-failure.sh` messages.

---

## After a run: gate, checks, review

1. **Gate:** From run record or PR body — all required in-job checks `pass` for reviewable PRs. Any `fail` → triage; PR not ready.
2. **Bot PR checks:** If `pr-check` / `gitleaks` sit in “waiting for approval”, owner approves workflows on the PR **or** manager runs `bash scripts/factory-kick-checks.sh <PR>` from owner `gh`, then `gh pr checks <PR> --watch`.
3. **Factory review:** Post one comment per round using `review-local-pr.md` (scope, done checks, template, CI). Tell owner: pass, or fix count + PR link.
4. **Fix rounds:** Owner says “fix the review on #P” → manager posts `/oc fix` with the numbered list. **Cap at two fix rounds** per PR; then escalate with a batched checkpoint (split, spec change, or owner edit). Each fix run is metered; same $1 issue cap applies.

---

## Merge authority (manager)

| Risk | Manager may merge when |
|---|---|
| **trivial** | Green required CI on head, passing gate, PR body complete, branch 0 behind default. |
| **normal** | **Never** without owner approval on PR body (Factory loop step 7, Human reviewed). |
| **high** | **Never** without owner approval on PR body. |

Before merge: update branch; re-verify if catch-up changes behavior (re-ask gate for normal/high). UI/pages PRs need screenshots in **Evidence** on the PR body, not only in chat.

---

## Post-merge

1. Watch deploy / Pages / scheduled jobs touched by the merge.
2. Run **post-merge review** when the repo has `scripts/factory-run-review.py` — compare run totals to PR `Cost:` line; file issues for mismatches.
3. Comment deploy status on the issue; open fix PR if red.

---

## Routines

Set these up in the manager bot’s scheduler after this skill lands (owner manual step on the issue).

### Daily

| Input | Action | Output |
|---|---|---|
| Open PRs, latest workflow runs, `factory/budget.yml` + Actions minutes | Failed **gates**; runs stuck > timeout; Actions minutes vs **80%** of `actions_minutes_month`; scheduled job freshness per `DOCS.md` | Comment in factory room; bug issue for hard failures |
| Live product (optional) | Newcomer review per `FACTORY.md` | ≤3 new issues with evidence |

### Weekly (Monday, after site refresh)

| Input | Action | Output |
|---|---|---|
| Latest factory **site** / marts (`site-data/`, dbt marts) | MTD spend, weekly burn vs `weekly_usd`, forecast error (`fct_forecast_vs_actual`), top issues by spend, Actions minutes | Spend report message to owner (short, phone-readable) |

### Monthly

| Input | Action | Output |
|---|---|---|
| deepinfra.com model pages vs `.factory/models.yaml` | Price table drift | Proposed `models.yaml` update PR or owner issue |
| `fct_forecast_vs_actual` | Token prior recalibration | Comment with suggested prior changes |

### Factory site refresh

The **factory site** (Architecture, Financials, Backlog, dbt tabs) is the financial/status surface ([`DECISIONS.md`](../DECISIONS.md) 2026-11-11).

| Cadence | Trigger | Manager action |
|---|---|---|
| Every push to `main` | CI workflow | Ensure build succeeds; trivial site-data PRs may auto-merge |
| Weekly | Scheduled workflow (odd minute) | After refresh PR merges, run **weekly spend report** |
| On demand | Owner asks | Dispatch financials/site workflow; summarize when artifact/Pages updated |

**Hosting:** **Public** repo → publish to **GitHub Pages**. **Private** repo → downloadable Actions **artifact** only (no public Pages). Budget numbers live in **`factory/budget.yml`** (owner-only file once site guard lands — workers must not edit it).

---

## Escalation and fix policy

| Situation | Manager action |
|---|---|
| First gate fail on a run | One **escalation** retry if `models.yaml` allows (e.g. model step-up); else report with run link |
| Second gate fail | Stop auto-retry; batched checkpoint with owner |
| Fix round 3+ requested | Decline `/oc fix`; options: split issue, new spec, owner patch |
| Issue at $1 cap | Refuse run; propose split |
| Protected script or workflow change needed | Owner-only; paste YAML in issue for owner |

---

## Quick reference: scripts the manager runs

| Script | When |
|---|---|
| `factory-spec-check.py` | Before posting/approving a spec |
| `factory-predict-cost.py [--write]` | Spec cost fields |
| `factory-approve-spec.py` | Approve draft → posted approved spec |
| `factory-kick-checks.sh` | Bot PR missing pr-check/gitleaks on head |
| `factory-run-review.py` | Post-merge cost/review audit (when present) |

---

## See also

- [`factory-loop.md`](factory-loop.md) — execute one issue end to end.
- [`liability-gates.md`](liability-gates.md) — hard stops.
- [`giver.md`](giver.md) — ledger, decision drafts, challenge (optional).
- [`local-open-weights-run.md`](local-open-weights-run.md) — fallback when Actions cannot run.