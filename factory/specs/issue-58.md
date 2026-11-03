<!-- factory-spec v1 -->
---
spec_version: 1
issue: 58
title: 'Spec template: add model_override_reason field'
status: approved
complexity: simple
complexity_reason: one template line plus two small spec-check fixtures; no script changes
risk: trivial
work_type: docs
model: deepseek-ai/DeepSeek-V4-Flash-0731
model_reason: default for simple work
predicted_tokens_in: 300000
predicted_tokens_cached: 240000
predicted_tokens_out: 20000
predicted_cost_usd: 0.011
budget_cap_usd: 1.00
price_table_version: '2026-11-02'
approved_by: grok-bot (simple+trivial)
approved_at: '2026-11-02T18:45:00-06:00'
drafted_by: grok-bot
---

## Outcome
`.factory/templates/spec.md` has an empty `model_override_reason:` line right after `model:` with a one-line comment, and `tests/specs/` has one passing fixture with it empty and one with it filled.

## Context
- Issue #58 (part of epic #38), from the Factory review on PR #53.
- `scripts/factory-predict-cost.py` keeps a spec's `model` only when `model_override_reason` is not empty; otherwise it re-routes from `.factory/models.yaml`. The template has no such line, so owners can't find the override.
- `scripts/factory-spec-check.py` already ignores extra front matter keys, so no script change is needed. `scripts/test-spec-check.sh` runs every `tests/specs/*.md`: `pass-*` files must exit 0.
- This is also the live validation run for the Phase 1 harness changes (PR #81).

## Scope
1. In `.factory/templates/spec.md` front matter, add this line directly after the `model:` line, and change nothing else in the file:
   `model_override_reason:  # leave empty to let factory-predict-cost.py route the model; fill only to keep model as an owner override`
2. Add `tests/specs/pass-model-override-reason-empty.md`: a copy of `tests/specs/pass-simple.md` with `title: Override reason empty fixture` and an empty `model_override_reason:` line after `model:`.
3. Add `tests/specs/pass-model-override-reason-filled.md`: a copy of `tests/specs/pass-simple.md` with `title: Override reason filled fixture` and `model_override_reason: owner wants the cheaper model for a docs-only fixture` after `model:`.

## Out of scope
- Any edit to existing scripts, including `scripts/factory-spec-check.py` and `scripts/factory-predict-cost.py`.
- Other template fields (#61 covers model/cost defaults and `price_table_version`).
- `factory/specs/issue-58.md`: the harness writes it; don't create or edit it.

## Files
- Change: `.factory/templates/spec.md` (one added line)
- Create: `tests/specs/pass-model-override-reason-empty.md`, `tests/specs/pass-model-override-reason-filled.md`
- Read first: `tests/specs/pass-simple.md`, `scripts/test-spec-check.sh`

## Acceptance criteria
- [ ] The template's front matter has `model_override_reason:` directly after `model:`, with the comment, empty value
- [ ] Both new fixtures pass `scripts/factory-spec-check.py`
- [ ] `scripts/test-spec-check.sh` passes with 9 fixtures
- [ ] No other files change (besides the harness-written spec file)

## Verification
```bash
grep -n -A1 '^model:' .factory/templates/spec.md
python3 scripts/factory-spec-check.py tests/specs/pass-model-override-reason-empty.md && echo "OK empty"
python3 scripts/factory-spec-check.py tests/specs/pass-model-override-reason-filled.md && echo "OK filled"
bash scripts/test-spec-check.sh
git diff --stat HEAD~1 HEAD
```
Expected: the line after `model:` is `model_override_reason:` with the comment, both fixtures print OK, the test script reports 9 passed and 0 failed, and the diff touches only the three files above plus `factory/specs/issue-58.md`.

## Classification
Simple (one line plus two fixtures), trivial (template and test fixtures only, no behavior change). Model: DeepSeek V4 Flash, the default for simple work.

## Cost forecast
About 300k tokens in (240k cached) and 20k out: predicted $0.011 against the $1 issue cap and the $0.25 per-run limit. No split needed.

## Manual steps for Michael
None.

## Dependencies
None. PR #81 (merged) is the harness under test.

## Worker prompt
Read issue #58 and `.factory/FACTORY.md` first. Make only the three changes in Scope: one line in `.factory/templates/spec.md` and two new fixtures under `tests/specs/`, copied from `tests/specs/pass-simple.md`. The harness writes `factory/specs/issue-58.md` and runs the Verification block itself. Fill the PR template; tick only what you proved.
