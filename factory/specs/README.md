# Factory specs

Specs for factory work live at **`factory/specs/issue-<N>.md`**. For a group spec, use the **lowest** issue number in `issues: [...]` and the same filename (`issue-<lowest>.md`).

**Status:** `draft` | `approved` | `superseded`.

**Approval:** Michael for standard/complex complexity or normal/high risk. Grok Bot may self-approve **simple + trivial** (`approved_by: grok-bot (simple+trivial)`).

## Flow (vision §18 decisions 6 and 7)

1. Grok Bot drafts on its Cursor plan (`drafted_by: grok-bot`). A complex spec may use `/oc spec` on `deepseek-ai/DeepSeek-V4-Pro-0813` (`drafted_by: oc-spec-run`).
2. Approved spec is posted on the issue as a comment starting with the marker below, then the full spec (front matter + sections).
3. The run commits it in the run PR as `factory/specs/issue-<N>.md`, written by the harness as an exact copy of the comment (marker line on, LF line ends). The worker never copies or edits it; publish refuses a PR whose copy differs from the comment (#75). No separate spec PR.
4. Front matter: plain or single-quoted values. `factory-spec-check.py` rejects escaped quotes (`\"`).
5. Verification: put the commands in one `bash` fenced block under `## Verification`. The harness runs it after the worker (`scripts/opencode-verify.sh`, a scratch copy of the base plus the patch, HEAD~1 is the base, no `origin` remote) and pastes the output into the PR Evidence (#76).

**Comment format (marker line first):**

```markdown
<!-- factory-spec v1 -->
---
spec_version: 1
issue: 42
title: Example
status: approved
complexity: simple
complexity_reason: …
risk: trivial
work_type: code
model: deepseek-ai/DeepSeek-V4-Flash-0731
model_reason: …
predicted_tokens_in: 300000
predicted_tokens_cached: 240000
predicted_tokens_out: 20000
predicted_cost_usd: 0.011
budget_cap_usd: 1.00
price_table_version: 2026-11-01
approved_by: grok-bot (simple+trivial)
approved_at: 2026-11-02T12:00:00Z
drafted_by: grok-bot
---

## Outcome
…
```

Template: `.factory/templates/spec.md`. Validate: `python3 scripts/factory-spec-check.py <path>`.
