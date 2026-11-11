<!-- factory-spec v1 -->
---
spec_version: 1
issue: 183
title: 'Feedback intake: cross-repo issue convention'
status: approved
complexity: simple
complexity_reason: 'Docs and one markdown template only; no workflow or script edits.'
risk: normal
work_type: docs
model: deepseek-ai/DeepSeek-V4-Flash-0731
model_override_reason: 
model_reason: 'Default for all other factory worker runs → V4 Flash'
predicted_tokens_in: 300000
predicted_tokens_cached: 240000
predicted_tokens_out: 20000
predicted_cost_usd: 0.0108
budget_cap_usd: 1.00
price_table_version: '2026-11-02'
approved_by: michael
approved_at: '2026-11-11T12:52:53-06:00'
drafted_by: oc-spec-run
---

## Outcome

A factory problem found in a product repo (Perspectiverse first) is filed once, here in the template, with the `from-product` label and a required `Source repo` field, and can be traced back to where it was found; the convention and triage rule are documented in `ADOPTING.md` and the reusable markdown template lives in `docs/factory-problem-issue-template.md`.

## Context

Issue #183, part of epic #178. Factory work is consumed by product repos that pin the template to a release tag and pick up changes through a sync PR (#156, planned). When a product repo hits a factory problem, there is currently no agreed, traceable way to file it once here so it can be fixed in the template and released back. This issue adds the simplest readable convention: one reusable label `from-product` plus a required `Source repo` field in an issue template (not a family of `from:<repo>` labels). Docs and a template only; no workflow edits. `ADOPTING.md` already documents selection, approval, merge and setup conventions; a Feedback intake section belongs there. `docs/` already holds `SETUP.md` and `RELEASING.md`, so the template doc fits the existing doc layout.

## Scope

Edit `ADOPTING.md` to add a short Feedback intake section, and create `docs/factory-problem-issue-template.md` as the canonical markdown issue template.

- `ADOPTING.md`: a Feedback intake section stating the convention (a factory problem found in a product repo is filed once, here, with the `from-product` label and the `Source repo` field), the triage rule (incoming cross-repo issues are reviewed here, fixed in the template, released as a new tag, and picked up by product repos through a sync PR; pinning and sync PRs are planned, see #156), and the no-secrets reminder (no secrets, tokens, logs with keys, or private product data in the filing).
- `docs/factory-problem-issue-template.md`: a markdown template with YAML front matter (`name`, `about`, `labels: [from-product]`) and these exact required field headings — `## Source repo`, `## Pinned factory tag`, `## Product-repo issue or PR`, `## What happened`, `## Expected`, `## Actual` — plus the same no-secrets reminder. This file is the source of truth for filers and for the Manual step below. A markdown template can only present those headings; GitHub does not enforce them as required unless Michael adds a YAML issue form in the Manual step.

Quote any front-matter value that contains a colon in single quotes (for example the `about` line), so the harness does not fail as in #189. Do not use numbered placeholders.

## Out of scope

Do not touch `.github/` (workers cannot edit it; the path policy forbids `.github/**`); the worker must not create the GitHub label and must not create anything under `.github/`. Do not edit any protected spend/security script (see `bash scripts/opencode-artifact-scan.sh --list-protected`). Do not touch `opencode.json`, any `AGENTS.md`, `.factory/actions-security.md`, `.factory/models.yaml`, `factory/budget.yml`, or `requirements-factory.txt`. No workflow, script, or issue-template-file-under-`.github/` change is made by the worker. Keep the change to one PR well under 300 changed lines.

## Files

- Edit: `ADOPTING.md`
- Create: `docs/factory-problem-issue-template.md`

## Acceptance criteria

- [ ] `ADOPTING.md` has a Feedback intake section that states the convention: a factory problem found in a product repo is filed once here with the `from-product` label and a required `Source repo` field, and can be traced back to where it was found.
- [ ] `ADOPTING.md` states the triage rule: incoming cross-repo issues are reviewed here, fixed in the template, released as a new tag, and picked up by product repos through a sync PR, and it mentions #156 (pinning and sync PRs are planned).
- [ ] `ADOPTING.md` reminds filers not to paste secrets, tokens, logs with keys, or private product data.
- [ ] `docs/factory-problem-issue-template.md` exists and is the canonical markdown template with YAML front matter including `labels: [from-product]`.
- [ ] The template has the exact headings `## Source repo`, `## Pinned factory tag`, `## Product-repo issue or PR`, `## What happened`, `## Expected`, and `## Actual`.
- [ ] The template reminds filers not to paste secrets, tokens, logs with keys, or private product data.
- [ ] No `.github/`, script, workflow, or owner-only path is changed; no label is created by the worker.
- [ ] The `## Verification` harness block prints `Results: 2 passed, 0 failed`.

## Verification

```bash
set -uo pipefail
pass=0
fail=0
note() {
  local status="$1" desc="$2"
  echo "$status  $desc"
  if [ "$status" = PASS ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
}
all_found() {
  local file="$1"; shift
  local p
  for p in "$@"; do
    grep -qF -- "$p" "$file" || return 1
  done
  return 0
}
if all_found ADOPTING.md "from-product" "Source repo" "reviewed here" "fixed in the template" "released as a new tag" "sync PR" "#156" "secrets, tokens, logs with keys, or private product data"; then
  note PASS "ADOPTING.md carries the convention, triage rule, #156, and no-secrets reminder"
else
  note FAIL "ADOPTING.md carries the convention, triage rule, #156, and no-secrets reminder"
fi
if all_found docs/factory-problem-issue-template.md "## Source repo" "## Pinned factory tag" "## Product-repo issue or PR" "## What happened" "## Expected" "## Actual" "from-product" "secrets, tokens, logs with keys, or private product data"; then
  note PASS "docs/factory-problem-issue-template.md carries the required fields, from-product label, and no-secrets reminder"
else
  note FAIL "docs/factory-problem-issue-template.md carries the required fields, from-product label, and no-secrets reminder"
fi
echo
echo "Results: $pass passed, $fail failed"
test "$pass" -eq 2 -a "$fail" -eq 0
```

Expected:

```
PASS  ADOPTING.md carries the convention, triage rule, #156, and no-secrets reminder
PASS  docs/factory-problem-issue-template.md carries the required fields, from-product label, and no-secrets reminder

Results: 2 passed, 0 failed
```

## Classification

- complexity: simple — two doc edits (one new markdown template, one added section); no code, workflow, or script change.
- risk: normal — documentation and an issue template enhancement; no product/behavior change, no workflow or spend impact, no `risk:high` label. Risk is normal rather than trivial because it introduces a new filing convention and a source-of-truth template, so it warrants the human product gate; it is not high.
- work_type: docs.
- Model routing and reason match the front matter; the harness fills the model fields.

## Cost forecast

Tokens in/cached/out and predicted cost are left for `factory-predict-cost.py` to route. The change is two small doc edits, expected to fit well under the $1 cap and under the $0.15 issue target; no split is planned.

## Manual steps for Michael

Create the `from-product` label on this repository (the worker cannot create GitHub labels), and add the template under `.github/ISSUE_TEMPLATE/` so GitHub's New issue chooser offers it. A markdown copy (`factory-problem.md`) can present the required field headings but cannot enforce them. To actually require those fields, use a YAML issue form (for example `.github/ISSUE_TEMPLATE/factory-problem.yml`) with `validations: required: true` on Source repo, pinned factory tag, product-repo issue or PR, what happened, expected, and actual. The worker must not create anything under `.github/`.

## Dependencies

None blocking. Refs #178 (epic), #156 (pinning and sync PRs are planned; the triage rule references it), and the Perspectiverse pilot sibling / `ADOPTING.md` sibling; none block this change.

## Worker prompt

Read issue #183 and `.factory/FACTORY.md` first. Add a short Feedback intake section to `ADOPTING.md` and create `docs/factory-problem-issue-template.md` as described in this spec. The convention: a factory problem found in a product repo is filed once here with the `from-product` label and a required `Source repo` field; the triage rule states incoming cross-repo issues are reviewed here, fixed in the template, released as a new tag, and picked up by product repos through a sync PR (pinning and sync PRs are planned, see #156); and both files remind filers not to paste secrets, tokens, logs with keys, or private product data. `docs/factory-problem-issue-template.md` is the canonical markdown template with YAML front matter (`name`, `about`, `labels: [from-product]`) and these exact field headings: `## Source repo`, `## Pinned factory tag`, `## Product-repo issue or PR`, `## What happened`, `## Expected`, `## Actual`. Quote any front-matter value that contains a colon in single quotes (for example the `about` line) so the harness does not fail as in #189. A markdown template cannot enforce required fields; that is the YAML issue form in Manual steps. Do not touch `.github/` and do not create the label; do not edit any script, workflow, or owner-only file. Fill the PR template; tick only what you proved.

## Design / approach

Keep the convention the simplest readable option: one reusable label `from-product` plus a required `Source repo` field in the template, rather than a family of `from:<repo>` labels that would need a new label per product repo. Required-field enforcement in GitHub's New issue form needs the YAML issue form in Manual steps; the markdown template only presents the headings. `ADOPTING.md` is the natural home for the convention and triage rule because it already documents how this factory is adopted and consumed; `docs/factory-problem-issue-template.md` is the reusable template the filer uses and the Manual step copies to `.github/ISSUE_TEMPLATE/`. The triage rule ties into the existing planned mechanism (#156): fixed here, released as a tag, picked up via a sync PR.

## Risks, rollback and revert trigger

Risk: the convention is new and filers might skip the `Source repo` field or paste private data; mitigated by making `Source repo` a required field heading in the template and by the explicit no-secrets reminder in both files. Risk: a filer might think the `from-product` label family means per-repo labels; mitigated by documenting the single `from-product` label explicitly. Rollback is a normal docs revert of `ADOPTING.md` and deletion of `docs/factory-problem-issue-template.md` (plus, manually, removal of the copied `.github/ISSUE_TEMPLATE/factory-problem.md` and the label). Revert trigger: if a filed cross-repo issue cannot be traced to its source repo (missing `Source repo`), or if a secret/private detail appears in a filing, or the template no longer carries the required fields, revert and adjust.

## What changes in production on merge

`ADOPTING.md` gains a Feedback intake section so adopters and agents know how a cross-repo factory problem is filed and triaged. `docs/factory-problem-issue-template.md` becomes the canonical template that Michael copies to `.github/ISSUE_TEMPLATE/factory-problem.md` (a manual step), which GitHub then offers from the New issue chooser. No workflow, script, gate, cost, or model-routing behavior changes, and no secrets or env values are printed.

## Success metric (baseline, target, how measured)

Baseline: there is no agreed cross-repo filing convention, so a factory problem found in a product repo has no standard way to be filed once and traced. Target: `ADOPTING.md` documents the convention and triage rule, `docs/factory-problem-issue-template.md` exists with the required fields, `from-product` label, and no-secrets reminder, and the `## Verification` harness block prints `Results: 2 passed, 0 failed`. Measured by the verification harness (which checks both files) and by a post-merge filing: the first real cross-repo issue filed via the template carries the `from-product` label and a `Source repo` field and is traceable.

## Test plan detail (broken case shown blocked)

This is a simple/normal docs change; the detailed broken-case plan is optional and covered by the `## Verification` harness block, which asserts both files contain the required content. A broken case is shown blocked: if `ADOPTING.md` omits the triage rule (#156 mention), or `docs/factory-problem-issue-template.md` omits any required field heading, the `from-product` label, or the no-secrets reminder, the corresponding aggregated check fails and the final line reports a failed count, so the harness cannot report `Results: 2 passed, 0 failed`.

## Security and liability review (`liability-gates.md`)

Docs-only change with no executable code, no new dependency, and no workflow or script edit; no protected spend/security script or owner-only file is touched. The template and the `ADOPTING.md` section both remind filers not to paste secrets, tokens, logs with keys, or private product data, which is the main liability-relevant control this change adds (keeping secrets out of issues). No key, token, or environment value is read, printed, or committed.

## Milestones / split plan (when near the cap)

Not required — simple/normal and expected to fit comfortably in one PR well under the cap.
