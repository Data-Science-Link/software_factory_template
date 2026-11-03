<!-- factory-spec v1 -->
---
spec_version: 1
issue: 7
title: 'Add a hello doc'
status: approved
complexity: standard
complexity_reason: one new doc plus a test fixture
risk: normal
work_type: docs
model: deepseek-ai/DeepSeek-V4-Pro-0813
model_override_reason: the worker should not set this
model_reason: worker guess
predicted_tokens_in: 0
predicted_tokens_cached: 0
predicted_tokens_out: 0
predicted_cost_usd: 0
budget_cap_usd: 1.00
price_table_version: ''
approved_by: michael
approved_at: '2026-11-02T12:00:00Z'
drafted_by: grok-bot
---

## Outcome
`factory/x/hello.md` exists and says hello.

## Context
Issue #7 asks for a hello doc.

## Scope
1. Create `factory/x/hello.md` with one line: `hello`.

## Out of scope
Anything else.

## Files
- Create: `factory/x/hello.md`

## Acceptance criteria
- [ ] The file exists with one line.

## Verification
```bash
cat factory/x/hello.md
```
Expected: `hello`.

## Classification
Standard, normal.

## Cost forecast
Small.

## Manual steps for Michael
None.

## Dependencies
None.

## Worker prompt
Read issue #7 and `.factory/FACTORY.md` first. Create the file. Fill the PR template; tick only what you proved.

## Design / approach
One file.

## Risks, rollback and revert trigger
Revert the commit.

## What changes in production on merge
Nothing runs it.

## Success metric (baseline, target, how measured)
Baseline no file; target the file; measured by the Verification block.
