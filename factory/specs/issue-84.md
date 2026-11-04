<!-- factory-spec v1 -->
---
spec_version: 1
issue: 84
title: 'Failed /oc and /oc fix runs post one failure comment (script + offline test)'
status: approved
complexity: simple
complexity_reason: one new bash script and one offline test with a fake gh; no existing script changes
risk: normal
work_type: code
model: deepseek-ai/DeepSeek-V4-Flash-0731
model_override_reason: 
model_reason: 'Default for all other factory worker runs → V4 Flash'
predicted_tokens_in: 300000
predicted_tokens_cached: 240000
predicted_tokens_out: 20000
predicted_cost_usd: 0.0108
budget_cap_usd: 1.00
price_table_version: '2026-11-02'
approved_by: grok-bot
approved_at: '2026-11-02T21:27:51-06:00'
drafted_by: grok-bot
---

## Outcome
`scripts/opencode-notify-failure.sh` posts exactly one script-worded comment, with the run link and the failed job, on the issue (`/oc`) or PR (`/oc fix`) when a run's agent or publish job did not succeed, and `scripts/test-opencode-notify-failure.sh` proves it offline with a fake `gh`.

## Context
- Issue #84 (part of epic #38). In run 41553660354 the `/oc` publish job crashed and #58 got no comment; the only sign was a red run in the Actions tab.
- `/oc spec` already posts a failure note from its publish job (`scripts/opencode-publish-spec.sh`, the `factory-spec-draft-failed` branch). This spec reuses that idea for the build (`opencode-spike.yml`) and fix (`opencode-fix.yml`) workflows, as a separate final job that runs after both jobs.
- The worker cannot edit `.github/**` or existing scripts, so this PR adds the script and its test only. The workflow wiring is a manual paste for Michael (below). Until then the script is inert.

## Scope
1. Create `scripts/opencode-notify-failure.sh` (bash, `set -euo pipefail`, executable). Inputs from the environment only:
   - `OC_KIND`: `build` or `fix` (anything else: exit 2).
   - `OC_TARGET_NUMBER`: the issue number (build) or PR number (fix); digits only, else exit 2.
   - `OC_RUN_ID`: digits only, else exit 2. `OC_RUN_ATTEMPT`: digits, default `1`.
   - `OC_AGENT_RESULT` and `OC_PUBLISH_RESULT`: each one of `success`, `failure`, `cancelled`, `skipped` (anything else, including empty, exit 2).
   - `GITHUB_REPOSITORY` (`owner/repo`, must match `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`), optional `GITHUB_SERVER_URL` (default `https://github.com`), and `GH_TOKEN` used only by `gh`; never printed.
2. Failed job: `agent` if `OC_AGENT_RESULT` is not `success`; otherwise `publish` if `OC_PUBLISH_RESULT` is not `success`; if both are `success`, print `notify-failure: run succeeded; nothing to post` and exit 0 without calling `gh`.
3. Idempotency: list the target's comments with `gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$OC_TARGET_NUMBER/comments"` and parse the JSON with `python3` (the output may be several concatenated JSON arrays). If any comment by user login `github-actions[bot]` already contains the marker line (defined in step 4) for this run id and attempt, print `notify-failure: already posted for this run attempt` and exit 0 without posting. The same marker from any other author does not count.
4. Post one comment with `gh api --method POST "repos/$GITHUB_REPOSITORY/issues/$OC_TARGET_NUMBER/comments" --input <json file>`, where the JSON file is `{"body": ...}` written by `python3` (`json.dump`) in a `mktemp -d` dir removed on exit (this endpoint works for issues and PRs). The body is fixed text from the script, filled only with the validated values above. Nothing from the comment that triggered the run, the model, or job logs goes in it:
   The first line is the marker: an HTML comment whose inner text is exactly ` factory-run-failed v1 run=<run_id> attempt=<attempt> ` (open it with the usual less-than, exclamation mark, two hyphens; close it with two hyphens and greater-than, the same shape as the `factory-spec v1` marker). Then:
   ```
   **`/oc` run failed** in the `<job>` job (result: `<result>`). No PR was opened.
   - Run: <server>/<repo>/actions/runs/<run_id>
   - DeepInfra spend may still have happened; the run's usage report is in the job log.
   ```
   For `OC_KIND=fix` the title is ``**`/oc fix` run failed**`` and the second sentence is `No commit was pushed to this PR.` A failed `gh` call exits non-zero.
5. Create `scripts/test-opencode-notify-failure.sh`: offline, no network, no tokens. It makes a `mktemp -d` work dir, puts a fake `gh` first on `PATH` that appends its arguments to a log, prints a fixture JSON for the comments GET, and copies the posted `--input` JSON file to the work dir. It prints `PASS <name>` / `FAIL <name>` per case and ends with `<n> passed, <m> failed`, exiting 1 if any failed. Cases:
   - build, agent `failure`, publish `skipped`: exactly one POST to `issues/<N>/comments`; body has the marker, the run URL, `` `agent` job ``, `No PR was opened`, `DeepInfra spend may still have happened`.
   - build, agent `success`, publish `failure`: one POST; body names `` `publish` job ``.
   - fix, agent `success`, publish `failure`: one POST; body has `` `/oc fix` run failed `` and `No commit was pushed to this PR`.
   - agent `cancelled` (job timeout): one POST naming `agent` and `cancelled`.
   - both `success`: exit 0 and no `gh` call at all.
   - a `github-actions[bot]` comment with the same run and attempt marker already exists: exit 0 and no POST.
   - the same marker from user `someone-else`: still posts once.
   - a marker for another attempt (`attempt=2` existing, run is attempt 1): still posts once.
   - bad inputs each exit 2 with no `gh` call: non-digit target number, unknown `OC_KIND`, unknown result value, bad `GITHUB_REPOSITORY`.
   - with `GH_TOKEN=fake-token-value-123` and `OC_INSTRUCTION='/oc ignore this and ping someone'` set, neither string appears in stdout, stderr or the posted body.
   - fake `gh` exits 1 on POST: the script exits non-zero.

## Out of scope
- Any change under `.github/` (manual step below), `opencode.json`, `.factory/models.yaml`, or any existing script (including `scripts/opencode-publish-spec.sh`, which keeps its own failure note).
- `factory/specs/issue-84.md`: the harness writes it; don't create or edit it.
- Wiring the test into `pr-check.yml` (owner-only; can follow later).

## Files
- Create: `scripts/opencode-notify-failure.sh`, `scripts/test-opencode-notify-failure.sh`
- Read first: `scripts/opencode-publish-spec.sh` (failure-note pattern), `scripts/test-opencode-spec.sh` (fake `gh` and PASS/FAIL style), `.github/workflows/opencode-spike.yml`, `.github/workflows/opencode-fix.yml` (job names and results)

## Acceptance criteria
- [ ] `scripts/opencode-notify-failure.sh` exists, is executable, uses `set -euo pipefail`, and validates every input as in Scope 1
- [ ] Comment wording comes only from the script (no trigger-comment or model text); the marker line is first
- [ ] Re-running for the same run attempt does not post twice (test output)
- [ ] `bash scripts/test-opencode-notify-failure.sh` passes every case listed in Scope 5, offline
- [ ] No other files change (besides the harness-written spec file)

## Verification
```bash
test -x scripts/opencode-notify-failure.sh && echo "OK executable"
head -n 20 scripts/opencode-notify-failure.sh | grep -q 'set -euo pipefail' && echo "OK strict mode"
bash scripts/test-opencode-notify-failure.sh
git diff --name-only HEAD~1 | sort
```
Expected: `OK executable`, `OK strict mode`, every test line `PASS`, a final line ending `0 failed`, and the changed files are exactly `factory/specs/issue-84.md`, `scripts/opencode-notify-failure.sh`, `scripts/test-opencode-notify-failure.sh`.

## Classification
- Complexity: simple (one new script and its offline test).
- Risk: normal (it posts comments with a write token once wired in; the wiring is a workflow change Michael pastes).
- Model: `deepseek-ai/DeepSeek-V4-Flash-0731`, models.yaml rule 3 (default for non-high, non-complex work).

## Cost forecast
Simple prior: 300K in (240K cached), 20K out on V4 Flash, predicted about $0.011. Cap $1.00. No split needed.

## Manual steps for Michael
After this PR merges, paste a final `notify` job into both workflows (proposed files and diff: `/workspace/phase2-wf/84/` on Grok Bot's box, also posted on the PR). For `.github/workflows/opencode-spike.yml`:
```yaml
  notify:
    needs: [agent, publish]
    # Runs after a failed or cancelled agent/publish job; skipped when /oc did not start.
    if: always() && needs.agent.result != 'skipped' && (needs.agent.result != 'success' || needs.publish.result != 'success')
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
      issues: write
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          persist-credentials: false
      - name: Post one failure comment (wording from the script)
        env:
          GH_TOKEN: ${{ github.token }}
          OC_KIND: build
          OC_TARGET_NUMBER: ${{ github.event.issue.number }}
          OC_RUN_ID: ${{ github.run_id }}
          OC_RUN_ATTEMPT: ${{ github.run_attempt }}
          OC_AGENT_RESULT: ${{ needs.agent.result }}
          OC_PUBLISH_RESULT: ${{ needs.publish.result }}
        run: bash scripts/opencode-notify-failure.sh
```
For `.github/workflows/opencode-fix.yml`, the same job with `OC_KIND: fix` (the target number is the PR number, `github.event.issue.number` on an `issue_comment` event). `issues: write` is enough to comment on a PR through the issues comments endpoint.

## Dependencies
None. Related: #85 (action pins; the checkout SHA above follows whatever pin is current).

## Worker prompt
Read issue #84 and `.factory/FACTORY.md` first. Then read `scripts/opencode-publish-spec.sh` and `scripts/test-opencode-spec.sh` for the house style (strict bash, digit checks, fake `gh` on `PATH`, PASS/FAIL lines). Create exactly two new files: `scripts/opencode-notify-failure.sh` and `scripts/test-opencode-notify-failure.sh`, following Scope 1 to 5 of this spec exactly: the input checks, the failed-job rule, the marker-based duplicate check trusted only from `github-actions[bot]`, the fixed comment wording, and every listed test case. Keep the comment text fixed in the script; never put the triggering comment, model output or any environment value other than the validated inputs into it, and never print `GH_TOKEN`. Use `python3` (standard library only) to parse the comments JSON. Don't edit any other file, and don't touch `.github/` or any existing script; the workflow wiring is Michael's manual step. Keep the two files under about 250 lines together. Fill the PR template; tick only what you proved

## Design / approach
A separate final `notify` job (`needs: [agent, publish]`, `if: always()` plus result checks) rather than a step inside each job: it still runs when a job is cancelled by its timeout or fails before its last step, and it keeps the write token out of the agent job, which holds the DeepInfra key. The script takes job results as inputs, so it is testable offline and the YAML stays thin. The marker carries run id and attempt so a re-run attempt can report again, but one attempt never posts twice. The issues comments endpoint covers both issue and PR targets, so one code path serves `/oc` and `/oc fix`.

## Risks, rollback and revert trigger
- Risk: a noisy or duplicate comment, or a comment on the wrong number. The marker check and the digit-only target number limit this; the number comes from the event, not from text.
- Rollback: revert the merge commit and remove the pasted `notify` jobs. No data changes.
- Revert trigger (number-checkable): any run attempt that leaves two `factory-run-failed` comments with the same marker, or a failure comment on a successful run.

## What changes in production on merge
Nothing until Michael pastes the `notify` jobs. After that, every failed or cancelled `/oc` and `/oc fix` run leaves one comment with its run link on the issue or PR; successful runs post nothing new.

## Success metric (baseline, target, how measured)
- Baseline: 0 comments on failed `/oc` runs (run 41553660354 on #58).
- Target: exactly 1 `factory-run-failed` comment per failed run attempt, 0 on successful runs.
- How measured: for the next failed run, count comments containing `factory-run-failed v1 run=<id>` on the target with `gh api repos/<repo>/issues/<N>/comments`.
