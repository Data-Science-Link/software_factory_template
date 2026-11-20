<!-- factory-spec v1 -->
---
spec_version: 1
issue: 7
title: Harness verification fixture (spec-pass)
status: approved
complexity: simple
complexity_reason: offline harness verify tests only
risk: normal
work_type: docs
model: deepseek-ai/DeepSeek-V4-Flash-0731
model_override_reason:
model_reason: fixture default
predicted_tokens_in: 1000
predicted_tokens_cached: 800
predicted_tokens_out: 100
predicted_cost_usd: 0.001
budget_cap_usd: 1.00
price_table_version: 2026-11-02
approved_by: grok-bot
approved_at: 2026-11-02T12:00:00Z
drafted_by: grok-bot
---

## Outcome
`factory/x/hello.md` exists for offline `scripts/opencode-verify.sh` tests.

## Context
Fixture for `scripts/test-opencode-verify.sh`; not used in live runs.

## Scope
Read `factory/x/hello.md` when present.

## Out of scope
Everything else.

## Files
- Read: `factory/x/hello.md`

## Acceptance criteria
- [ ] Harness verification runs the bash block without touching secrets.

## Bad inputs and edge cases
- Missing spec path → verify writes "not run (no approved spec in this run)".
- Spec with no bash block under ## Verification → verify writes "not run" for missing commands.
- Empty ## Bad inputs and edge cases on normal/high risk → factory-spec-check.py refuses the spec.

## Verification
```bash
cat factory/x/hello.md
echo "key=${DEEPINFRA_API_KEY:-unset} gh=${GH_TOKEN:-unset}"
git diff --name-only HEAD~1
```

## Classification
Simple, normal.

## Cost forecast
Fixture only.

## Manual steps for Michael
None.

## Dependencies
None.

## Worker prompt
Harness-owned fixture; workers must not edit this file in tests.

## Design / approach
Offline fixture only.

## Risks, rollback and revert trigger
None; delete the file.

## What changes in production on merge
Nothing.

## Success metric (baseline, target, how measured)
Baseline: n/a; target: verify harness PASS; measured by `scripts/test-opencode-verify.sh`.