<!-- factory-spec v1 -->
---
spec_version: 1
issue: 145
title: 'Regression fixtures no longer rot when the scripts their specs create land on main'
status: approved
complexity: standard
complexity_reason: rework scripts/test-spec-check.sh to derive each pass fixture's own new-script list from its ## Files Create: lines, drop the hand-kept spec-check-new-scripts headers from the regression fixtures, and add a rot test case
risk: trivial
work_type: code
model: deepseek-ai/DeepSeek-V4-Flash-0731
model_override_reason: 
model_reason: 'Default for all other factory worker runs → V4 Flash'
predicted_tokens_in: 1000000
predicted_tokens_cached: 800000
predicted_tokens_out: 50000
predicted_cost_usd: 0.0330
budget_cap_usd: 1.00
price_table_version: '2026-11-02'
approved_by: grok-bot
approved_at: '2026-11-11T08:45:08-06:00'
drafted_by: oc-spec-run
---

## Outcome

Regression fixtures in `tests/specs/pass-regression-*.md` no longer go red on `scripts/test-spec-check.sh` when a merge lands a script their approved spec planned to `Create:`. The hand-kept `# spec-check-new-scripts:` first-line headers are gone; `test-spec-check.sh` derives each pass fixture's own new-script list from that fixture's own `## Files` `Create:` lines, and a new test proves a regression fixture stays green once its created scripts exist.

## Context

- Issue #145, part of #38. Found while merging #142/#143 (2026-11-07); seen three times in two days.
- `scripts/test-spec-check.sh` judges a spec's "existing script" against a base-scripts list built from the current base branch (`git ls-tree -r --name-only <base> -- scripts/`, HEAD fallback). `scripts/factory-spec-check.py` treats a `Create:` path that is already in that base list as a change to an existing script (protected ones fail).
- Regression fixtures copy real approved specs. Those specs `Create:` new scripts (e.g. `scripts/factory-usage.py`, `scripts/test-factory-usage.sh`, `scripts/factory-run-end.sh`, `scripts/test-run-end.sh`). Once those scripts land on `main`, the base list contains them, so the fixture's `Create:` line fails and `pr-check` goes red on every PR until someone adds them by hand to the fixture's `# spec-check-new-scripts:` header (#141).
- Current workaround is a hand-kept `# spec-check-new-scripts: <paths>` first line on `pass-regression-issue-133.md` and `pass-regression-issue-30-amended.md`; `test-spec-check.sh` greps it out of the fixture's base list. That list rots on every merge that adds a script the fixture's spec planned.
- Owner guidance: prefer the issue's Fix A (each fixture records the base sha it was approved against; build that fixture's base list with `git ls-tree <sha> scripts/`), but verify the CI and /oc harness have enough git history; if they may be shallow, use a simple deterministic alternative (e.g. a committed per-fixture base-scripts list generated once) and say why.

## Scope

- In `scripts/test-spec-check.sh`, replace the hand-kept `# spec-check-new-scripts:` header parsing with an automatic, deterministic derivation: for each `pass-*` fixture, parse the fixture's own `## Files` section, collect the `scripts/` paths on `Create:` / `Add:` / `New:` lines, and remove those from that fixture's base-scripts list before running `factory-spec-check.py`. This is self-maintaining (the fixture already names what it plans to create), needs no git history, and keeps the existing judgment for everything else.
- Remove the now-obsolete `# spec-check-new-scripts:` first-line headers from `tests/specs/pass-regression-issue-133.md` and `tests/specs/pass-regression-issue-30-amended.md`.
- Add a test case (inline in `test-spec-check.sh`, in the existing helper style) that proves a regression fixture stays green once its planned `Create:` scripts already exist on the base list — the exact rot scenario from the issue.
- Keep the existing cases proving a real "change to an existing script" spec is still caught (protected and non-protected): the new derivation removes only a fixture's own `## Files` `Create:` paths from that fixture's base list, never `Change:` paths and never paths absent from that fixture's own `## Files`.

## Out of scope

- Do not touch `scripts/factory-spec-check.py` or any other protected spend/security script (see `scripts/opencode-artifact-scan.sh --list-protected`). `scripts/test-spec-check.sh` is not protected and may be edited.
- Do not touch `.github/`, `opencode.json`, `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, `requirements-factory.txt`, or any other dot-path.
- Do not edit the non-regression fixtures (`pass-simple.md`, `fail-*.md`, `pass-files-*.md`, `pass-notes-*.md`, etc.) except as needed to keep `test-spec-check.sh` green.
- Do not change how `factory-spec-check.py` judges "existing script" for real (non-regression) specs; the existing fail cases must keep passing.

## Files

- Change: `scripts/test-spec-check.sh`
- Change: `tests/specs/pass-regression-issue-133.md`
- Change: `tests/specs/pass-regression-issue-30-amended.md`

## Acceptance criteria

- [ ] `scripts/test-spec-check.sh` has no `# spec-check-new-scripts:` parsing left; it derives each pass fixture's own new-script list from the fixture's own `## Files` `Create:` lines.
- [ ] `tests/specs/pass-regression-issue-133.md` and `tests/specs/pass-regression-issue-30-amended.md` no longer carry a `# spec-check-new-scripts:` first line.
- [ ] A test case proves a regression fixture stays green when a base-scripts list already contains that fixture's `Create:` scripts (the rot scenario), and that case passes.
- [ ] The existing fail cases still catch a real "change to an existing script" spec: protected (`Change: scripts/factory-spec-check.py` → `change to a protected spend/security script`) and non-protected behavior, and the underscore-name fail (`fail-files-underscore-script.md`, `fail-regression-issue-30-underscore.md`) still fail.
- [ ] `bash scripts/test-spec-check.sh` prints every line `PASS` and a final `Results: <n> passed, 0 failed`.

## Verification

```bash
bash scripts/test-spec-check.sh
git diff --name-only HEAD~1 | sort
```

Expected: every `test-spec-check.sh` line `PASS` and a final `Results: <n> passed, 0 failed` (the total now includes a new regression-rot case). The changed-file list contains only `factory/specs/issue-145.md`, `scripts/test-spec-check.sh`, `tests/specs/pass-regression-issue-133.md`, and `tests/specs/pass-regression-issue-30-amended.md`.

## Classification

- Complexity: standard. A moderate rework of one test script (a small `## Files` `Create:` parser plus a base-list subtraction), two fixture header edits, and one new test case; no orchestration, network, or production behavior.
- Risk: trivial. Test-only; no product, data, or runtime behavior changes; the existing spec-check fail cases must keep passing.
- Model: left for `factory-predict-cost.py` to route; `model_override_reason` is empty.

## Cost forecast

Small read-only/test change: about 30–50 changed lines in `test-spec-check.sh` plus two fixture edits. Well under the $1 cap and the $0.10 target; one worker window, no split.

## Manual steps for Michael

None. The change is test-only and trivial-risk; nothing at runtime changes and no workflow, secret, or setting is involved.

## Dependencies

None blocking. This is a standalone hardening fix for the `test-spec-check.sh` regression-fixture rot described in the issue.

## Worker prompt

Read issue #145 and `.factory/FACTORY.md` first. Then read `scripts/test-spec-check.sh`, `scripts/factory-spec-check.py`, and the fixtures `tests/specs/pass-regression-issue-133.md`, `tests/specs/pass-regression-issue-30-amended.md`, `tests/specs/fail-files-edit-existing-script.md`, `tests/specs/fail-files-underscore-script.md`, `tests/specs/fail-regression-issue-30-underscore.md`, `tests/specs/pass-files-hyphenated-script.md`. Change exactly three files: `scripts/test-spec-check.sh`, `tests/specs/pass-regression-issue-133.md`, `tests/specs/pass-regression-issue-30-amended.md`. In `test-spec-check.sh`, replace the `# spec-check-new-scripts:` header parsing with an automatic derivation: for each pass fixture, parse its own `## Files` section, take the `scripts/` paths on `Create:`/`Add:`/`New:` lines, and remove them from that fixture's base-scripts list before running `factory-spec-check.py`. Remove the now-obsolete `# spec-check-new-scripts:` first lines from the two regression fixtures. Add an inline test case that simulates the rot: build a base-scripts list that already includes a regression fixture's `Create:` scripts (for example `scripts/factory-usage.py`, `scripts/factory-run-end.sh`, `scripts/test-run-end.sh` for `pass-regression-issue-30-amended.md`) and assert the fixture still passes through the new derivation. Keep every existing fail case passing, especially the protected-script and underscore-name cases; the derivation must only remove a fixture's own `## Files` `Create:` paths from that fixture's base list, never `Change:` paths and never paths absent from that fixture's own `## Files`. Do not edit `scripts/factory-spec-check.py` or any other protected script, and do not touch `.github/`, `opencode.json`, `AGENTS.md`, `.factory/`, or `requirements-factory.txt`. Run `bash scripts/test-spec-check.sh` and confirm every line `PASS` and `Results: <n> passed, 0 failed`. Start writing after those reads; don't browse other directories. Fill the PR template; tick only what you proved.

## Design / approach

The clean fix is to make each regression fixture's base self-describing instead of frozen against the current tree. A pass fixture's own `## Files` already lists, as `Create:`, every script its approved spec planned to add. So `test-spec-check.sh` can derive that fixture's "new at approval time" set from the fixture itself and remove it from the fixture's base list. This is deterministic, requires no git history or network, and cannot rot: the moment a merge lands one of those scripts, the fixture already names it, so the fixture stays green. It keeps every existing check intact because it only removes a fixture's own `Create:` paths from that fixture's base list; a `Change:` to an existing script, or a `Create:` of a script the fixture never planned, still fails exactly as before.

Fix A from the issue (freeze each fixture's base sha and run `git ls-tree <sha> scripts/`) was preferred in the issue but is not reliable here: the `pr-check` CI uses `actions/checkout@v7` with its default `fetch-depth: 1` (shallow, head commit only) and the /oc harness (`scripts/opencode-verify.sh`) runs on a scratch copy of the base plus patch with HEAD~1 as base and no origin remote, so an arbitrary frozen fixture sha is not present locally and `git ls-tree <sha>` would fail. The owner guidance asked for a deterministic alternative if the git history may be shallow; deriving from the fixture's own `## Files` is that alternative, and it removes the hand-kept list entirely.

## Alternatives considered

- Fix A, freeze each fixture's base sha and build its base list with `git ls-tree <sha> scripts/`: rejected. The `pr-check` CI (default shallow `fetch-depth: 1`) and the /oc harness (base + patch, HEAD~1, no origin) do not have arbitrary historical SHAs locally, so `git ls-tree <sha>` would fail; the check could not run in CI or the harness.
- A committed per-fixture base-scripts list generated once (owner's suggested alternative): still rots. It would need regenerating on every merge that adds a script a fixture's spec planned, which is the exact hand-keeping problem (#141) the issue wants gone.
- Option B from the issue, derive new scripts automatically from the fixture's `## Files` `Create:` lines: chosen. It is self-maintaining and needs no git history. The issue's stated drawback (it hides a spec that wrongly says `Create` for a script that already existed) does not apply to the regression fixtures, whose approved `## Files` genuinely planned those scripts, and it does not weaken the real-change fail cases because those use `Change:` or a script not in the fixture's own `## Files`.

## Risks, rollback and revert trigger

- Risk: the derivation accidentally removes a `Create:` path that should still be judged against the base (e.g. a typo in the parser). Mitigated by keeping the existing fail fixtures green (protected script, underscore name, forbidden path) and by the new rot test, so a wrong parser shows up as a failing test immediately.
- Risk: a regression fixture whose `## Files` uses a different `Create:` wording than the parser expects. The parser should mirror the intent detection already used in `scripts/factory-spec-check.py` (`files_line_intent`); the two real regression fixtures use the standard `Create: \`path\`` form.
- Rollback: revert the merge commit. This changes only a test script and two fixtures; no runtime or data behavior is affected.
- Revert trigger: none needed (test-only, trivial risk). If `test-spec-check.sh` starts failing on `main`, the fixture/parser that broke it is identified by the failing case name and reverted.

## What changes in production on merge

Nothing at runtime. The change is confined to the spec-check test suite: `scripts/test-spec-check.sh` derives each pass fixture's new-script list from the fixture's own `## Files` instead of a hand-kept header, the two regression fixtures drop their `# spec-check-new-scripts:` lines, and one new rot test case is added. `scripts/factory-spec-check.py` and all protected scripts are untouched.

## Success metric (baseline, target, how measured)

- Baseline: a merge that adds a script a regression fixture's spec planned turns `scripts/test-spec-check.sh` red, requiring a hand edit to the fixture's `# spec-check-new-scripts:` header (seen three times in two days, #141, `73e8294`).
- Target: no hand-kept `# spec-check-new-scripts:` lists remain, and a regression fixture stays green once its planned `Create:` scripts exist, proven by a dedicated test case.
- How measured: `bash scripts/test-spec-check.sh` prints every line `PASS` and a final `Results: <n> passed, 0 failed`, including the new rot case; the two regression fixtures no longer carry a `# spec-check-new-scripts:` first line.

## Test plan detail (broken case shown blocked)

`scripts/test-spec-check.sh` already drives every case through `factory-spec-check.py` and checks exit code plus output, so the real sequence is exercised:

- Rot case (new): a base-scripts list that already contains `scripts/factory-usage.py`, `scripts/factory-run-end.sh`, `scripts/test-run-end.sh` (simulating those merged) is passed for `pass-regression-issue-30-amended.md`; the fixture must pass through the new `## Files`-derived subtraction. Without the fix, this fixture fails as a change to an existing script — that is the broken case now shown green by the fix and asserted by the test.
- Real-change cases (must stay blocked): `fail-files-edit-existing-script.md` (`Change: scripts/factory-spec-check.py`) still fails with `change to a protected spend/security script`; `pass-files-edit-existing-script.md` (`Change: scripts/factory-run-review.py`, non-protected) still passes as an allowed change; `fail-files-underscore-script.md` and `fail-regression-issue-30-underscore.md` (`Create: scripts/factory_usage.py`) still fail with `new script needs a hyphenated name`, because `scripts/factory_usage.py` is not in any base list and the derivation does not touch it.

## Security and liability review (`liability-gates.md`)

- No secrets, keys, network, or env reads are added or changed; the test already runs offline with an empty environment.
- No protected or owner-only file is edited: `scripts/test-spec-check.sh` is not in `PROTECTED_SCRIPTS`, and the two fixture edits are plain markdown. No workflow, dependency, or supply-chain change.
- No public claims or license impact; test-only change. Trivial risk, so the Factory Manager may merge on green required CI without a human product gate.

## Milestones / split plan

One small PR (~40–60 changed lines) well under the cap; no split needed.
