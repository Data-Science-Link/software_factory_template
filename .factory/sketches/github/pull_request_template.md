<!-- Copy to .github/pull_request_template.md -->
<!-- Factory managers + Cursor agents: fill every section. This is how humans audit adherence. -->

## Summary

<!-- One or two sentences. -->

Closes #   <!-- only the issue this PR finishes. Ledgers, trackers, epics: use "Refs #N" -->

## Spec

<!-- Link to the approved spec file committed in this PR (factory/specs/issue-<N>.md). -->

## Success metric from the original ask

<!-- Normal/high: the number the requester cares about, its baseline, the target, and the pre-merge or projected value. Checked again after merge. -->

## What changes in production on merge

<!-- Required for normal/high. What users, live data, or scheduled jobs will see differently the moment this merges, including anything with no feature flag. Say what stays off and what turns it on. "Nothing" only if truly nothing. -->

## Factory loop

<!-- Required on every factory PR. Check what’s done; for N/A add a short note on the same line. -->

- [ ] **1. Intake** — Linked issue; one-sentence outcome stated on issue or below:
- [ ] **2. Triage** — easy / hard / high-risk → risk class: **trivial** | **normal** | **high**
- [ ] **3. Spec gate** — human approved specs / skipped (easy or trivial only)
- [ ] **4. Build** — synced latest default branch; branch + PR linked to issue; scope matches
- [ ] **5. Review** — agent self-review vs issue outcome + `.factory/skills/liability-gates.md`
- [ ] **6. Verify** — required CI green (or N/A + reason); evidence below; **UI → screenshots in Evidence section of this PR body** (not only a comment)
- [ ] **7. Product gate** — human approved (**required** for normal/high) / N/A trivial only — **when approved in chat, check this and update Human reviewed below before merge**
- [ ] **8. Ship + monitor** — merge only per risk class; branch updated onto latest main and CI green on that commit right before merge; after merge watch deploy/pages and fix if red

## Risk class

- [ ] trivial (typo/docs/comment/playbook-only — no product/behavior change; manager may merge after green CI)
- [ ] normal (feature/bugfix/behavior/**UI** — **human product gate before merge**)
- [ ] **high** (license, secrets, auth, crypto, safety, workflows, supply chain — human required)

## AI disclosure

AI disclosure: harness <!-- opencode-actions | Cursor cloud agent | local Cursor | … -->; model <!-- exact model ID -->

<!-- Optional detail (legacy template lines still accepted by pr-check): -->
- Tools used (factory manager / Cursor agent / both):
- Model(s) used (per `.factory/MODEL_ROUTING.md`; note any escalation):
- Cloud agent run ID(s) (for cost attribution):
- Approx. share AI-authored: [ ] little [ ] mixed [ ] mostly
- Human reviewed before merge: [ ] yes [ ] no — who: <!-- manager: set yes + name when chat/issue gate is given, BEFORE merge -->

Cost: <!-- $ amount on DeepInfra, or "not measured" for non-DeepInfra harnesses -->

## Factory run

<!-- The block below is filled by scripts/factory-run-end.sh only — never by hand or by the model.
     That script wraps the filled lines in the factory-run start/end HTML marker lines. -->

Run ID:
Workflow run:
Model:
Tokens in / cached / out:
Predicted cost:
Actual cost:
Cost method:
Key spend check:
Actions minutes:
Gate:
Run record:

## What I changed and why

<!-- Worker narrative only: the run end script pastes this section from your labeled note. -->

## Safety checklist

- [ ] No secrets, credentials, or `.env` content
- [ ] No `LICENSE` / `NOTICE` / SPDX change (or human approved + logged in `.factory/DECISIONS.md`)
- [ ] New deps: licenses checked / allowlisted (or N/A)
- [ ] Did not over-claim safety, security, or compliance in docs
- [ ] Did not auto-merge normal/high work
- [ ] **No change under `.github/workflows/`** (workflow edits are owner paste-by-hand only)
- [ ] **UI / frontend / pages:** screenshots embedded or linked in **Evidence** (not only a PR comment)
- [ ] Evidence saved under the head commit it shows (or N/A)
- [ ] No test pairs a hardcoded date with the real clock
- [ ] Quality/guard fix: scored on a fresh sample, raw N of M (or N/A)
- [ ] Report/check change doesn't mute a recurring fault without a linked root-cause issue (or N/A)

## Evidence

<!-- CI links, test output. UI/frontend/pages: embed or link screenshots HERE in this section (before/after when practical). Thread-only comments do not count. -->

## Notes for reviewers

<!-- Risks, follow-ups, what you want them to focus on -->

## Post-merge (manager)

- [ ] Deploy / pages / CD on default branch checked; fix opened if red; status on issue
