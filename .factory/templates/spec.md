---
spec_version: 1
issue: 0
title: Short title
status: draft
complexity: simple
complexity_reason: one line
risk: trivial
work_type: code
model: deepseek-ai/DeepSeek-V4-Flash-0731
model_reason: default for simple code
predicted_tokens_in: 300000
predicted_tokens_cached: 240000
predicted_tokens_out: 20000
predicted_cost_usd: 0.011
budget_cap_usd: 1.00
price_table_version: 2026-11-01
approved_by: null
approved_at: null
drafted_by: grok-bot
---

## Outcome
<!-- One sentence when done. -->

## Context
<!-- Why; links to issue, Michael's words, files. -->

## Scope
<!-- What changes. -->

## Out of scope
<!-- What the worker must not touch. The /oc path policy (`scripts/opencode-artifact-scan.sh --list-rules`) already forbids `.github/`, `opencode.json`, `.factory/actions-security.md`, `.factory/models.yaml`, other dot-paths and edits to existing scripts; don't ask for those. -->

## Files
<!-- Create, change, or read first. New scripts: a new hyphenated file directly under scripts/ (e.g. scripts/dbt-seed-check.sh). Never plan an edit to an existing script, .github/, or an owner-only .factory/ file for the worker; list it under Manual steps for Michael. .gitignore: added lines only. -->

## Acceptance criteria
<!-- Tick only when diff or command output proves it. -->

## Verification
<!-- Commands + expected output. Put the commands in ONE ```bash block: the /oc harness runs that block
     itself after the worker (scripts/opencode-verify.sh: scratch copy of the base + the patch, HEAD~1 is the
     base, no origin remote, empty environment, network allowed, ~5 min cap) and pastes the output into
     the PR Evidence. The worker can't run commands. -->

## Classification
<!-- Complexity, risk, model + reasons (match front matter). -->

## Cost forecast
<!-- Tokens in/cached/out, predicted cost, $1 cap, split plan if > $0.10. -->

## Manual steps for Michael
<!-- Workflow, secret, setting, or none. -->

## Dependencies
<!-- Blocking issues/PRs or none. -->

## Worker prompt
<!-- Harness text: start "Read issue #N and `.factory/FACTORY.md` first"; end "Fill the PR template; tick only what you proved". -->

## Design / approach
<!-- Required: standard/normal or complex/high (vision §5.3). -->

## Alternatives considered
<!-- Required for complex/high; optional for standard/normal. -->

## Risks, rollback and revert trigger
<!-- Required: standard/normal or complex/high. -->

## What changes in production on merge
<!-- Required: standard/normal or complex/high. -->

## Success metric (baseline, target, how measured)
<!-- Required: standard/normal or complex/high. -->

## Test plan detail (broken case shown blocked)
<!-- Required for complex/high; optional for standard/normal. -->

## Security and liability review (`liability-gates.md`)
<!-- Required for complex/high; optional for standard/normal. -->

## Milestones / split plan (when near the cap)
<!-- Required for complex/high; optional for standard/normal. -->
