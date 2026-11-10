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
model_override_reason:  # leave empty to let factory-predict-cost.py route the model; fill only to keep model as an owner override
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

<!-- Harness rules (#149): delete every <!-- --> note in this template before posting. Raw HTML
     comments in prose fail the draft. To quote an exact literal marker the build must copy, put
     it in a backtick code span or a fenced code block. When risk is high (or complexity complex),
     "## Test plan detail (broken case shown blocked)" is required. Verification must not pipe
     checked commands into head/tail/grep -q without set -o pipefail. -->

## Outcome
<!-- One sentence when done. -->

## Context
<!-- Why; links to issue, Michael's words, files. -->

## Scope
<!-- What changes. -->

## Out of scope
<!-- What the worker must not touch. The /oc path policy (`scripts/opencode-artifact-scan.sh --list-rules`) already forbids `.github/`, `opencode.json`, `.factory/actions-security.md`, `.factory/models.yaml`, other dot-paths and edits to existing scripts; don't ask for those. Say what not to touch here in plain words, never as a Files entry. -->

## Files
<!-- Only exact paths to create, change, or read first, one per bullet; no exclusion sentences (every path here counts as planned work; what not to touch goes under Out of scope). New scripts: a new hyphenated file directly under scripts/ (e.g. scripts/dbt-seed-check.sh). Never plan an edit to an existing script, .github/, or an owner-only .factory/ file for the worker; list it under Manual steps for Michael. .gitignore: added lines only. -->

## Acceptance criteria
<!-- Tick only when diff or command output proves it. -->

## Verification
<!-- Commands + expected output. Put the commands in ONE ```bash block: the /oc harness runs that block
     itself after the worker (scripts/opencode-verify.sh: scratch copy of the base + the patch, HEAD~1 is the
     base, no origin remote, empty environment, network allowed, ~5 min cap; pipefail is on) and pastes
     the output into the PR Evidence. The worker can't run commands. Do not hide failures: never pipe a
     checked command into head, tail, or grep -q unless the block also has set -o pipefail (prefer full output). -->

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
<!-- Required when complexity is complex OR risk is high; optional for standard/normal. -->

## Risks, rollback and revert trigger
<!-- Required: standard/normal or complex/high. -->

## What changes in production on merge
<!-- Required: standard/normal or complex/high. -->

## Success metric (baseline, target, how measured)
<!-- Required: standard/normal or complex/high. -->

## Test plan detail (broken case shown blocked)
<!-- Required when complexity is complex OR risk is high (risk high alone is enough); optional for standard/normal. A high-risk draft without this heading is refused. -->

## Security and liability review (`liability-gates.md`)
<!-- Required when complexity is complex OR risk is high; optional for standard/normal. -->

## Milestones / split plan (when near the cap)
<!-- Required when complexity is complex OR risk is high; optional for standard/normal. -->
