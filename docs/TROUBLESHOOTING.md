# Troubleshooting

Short **Symptom → Cause → Fix** notes for factory operators. All paths are relative to the repo root unless noted.

Related setup: [SETUP.md](SETUP.md), [CLI.md](CLI.md), [DOCTOR.md](DOCTOR.md), [OWNER_WORKFLOW_SYNC.md](OWNER_WORKFLOW_SYNC.md).

---

## `/oc` PR checks stuck on “Waiting for approval”

**Symptom:** GitHub Actions shows `action_required` / “Waiting for approval” on a new `oc/issue-*` PR; `pr-check` and other jobs never start.

**Cause:** On a **public** repo, first-time contributor workflows need a maintainer to approve each workflow run for a new head commit.

**Fix:**

1. Paste [`.github/workflows/approve-oc-runs.yml`](../.github/workflows/approve-oc-runs.yml) on the default branch (owner-only). It auto-approves held runs for same-repo branches whose names start with `oc/`.
2. Until that workflow exists, approve the held run manually in the Actions tab for the PR head SHA.
3. Fork PRs are never auto-approved; use branches on the main repository.

---

## `pr-check` fails on disclosure, cost, or verification

**Symptom:** `pr-check` fails with messages about **AI disclosure**, **Cost:**, factory-run fields, or **Verification** / harness failure.

**Cause:** [`scripts/pr-check.sh`](../scripts/pr-check.sh) enforces factory PR body rules:

- Agent-written PRs (bot author, `cursor/*` branch, or body mentions “AI disclosure”) need a real line such as `AI disclosure: harness <name>; model <id>` (template placeholders inside HTML comments do not count).
- Bodies mentioning Local open-weights or DeepInfra need `Cost: $…` or `Cost: not measured …`.
- Factory Actions run PRs need the filled factory-run block (Run ID, tokens, predicted/actual cost, Gate, spec path).
- Any harness Verification block or fenced log showing `Result: FAIL` or failed test counts fails the check.

**Fix:**

1. Read the exact `FAIL:` line from the `pr-check` job log.
2. Add or fix the missing line on the PR body (not only in a fenced code block).
3. If Verification failed, re-run the spec’s test commands without masking exit codes (see below) and refresh the Verification section after tests pass.
4. Offline repro: `bash scripts/pr-check.sh /path/to/body.md`.

---

## `opencode-artifact-scan` blocks script or `.factory` edits

**Symptom:** `/oc` patch fails with path policy errors on `scripts/` or `.factory/`, or on a file listed as protected.

**Cause:** [`scripts/opencode-artifact-scan.sh`](../scripts/opencode-artifact-scan.sh) reads [`.factory/mode.yml`](../.factory/mode.yml). In **`product`** mode (or if mode is missing/invalid), workers cannot create or edit anything under `scripts/` or `.factory/`. Files in **`PROTECTED_SCRIPTS`** cannot be edited in any mode.

**Fix:**

1. List protected paths: `bash scripts/opencode-artifact-scan.sh --list-protected`.
2. For template development, ensure `.factory/mode.yml` contains `mode: template` (owner-only file).
3. For product repos, keep `mode: product` and never scope worker changes to protected spend/security scripts—owner pastes those changes.
4. Run `python3 scripts/factory-doctor.py` (see [DOCTOR.md](DOCTOR.md)) for a full scorecard.

---

## Tests “pass” in the PR but actually failed (pipes)

**Symptom:** PR Verification shows green command output, but `pr-check` or run-review still reports failure; or a masked command hid a non-zero exit.

**Cause:** Shell pipelines like `bash scripts/test-foo.sh | head` or `| tail` return the pipe’s last command status, not the test script’s. [`scripts/factory-spec-lint.py`](../scripts/factory-spec-lint.py) flags masked pipes in specs.

**Fix:**

1. Run tests without trailing pipes, or use `set -o pipefail` and check `${PIPESTATUS[0]}`.
2. Prefer `bash scripts/opencode-worker-test.sh <short-name>` for `/oc` workers (allowed allowlist entry).
3. Re-run Verification and paste output where `pr-check` can see a passing harness result.

---

## dbt or site build breaks on Python 3.14

**Symptom:** dbt install/run fails on the Actions runner; doctor warns `python3` is 3.14+.

**Cause:** Default Ubuntu runner Python may be 3.14; many dbt releases do not support it yet in the `/oc` sandbox.

**Fix:**

1. In agent workflows, pin Python **3.12** or **3.13** with `actions/setup-python` **before** checkout (see [OWNER_WORKFLOW_SYNC.md](OWNER_WORKFLOW_SYNC.md)).
2. Locally, install `python3.12` or `python3.13` and point dbt harnesses at it.
3. `python3 scripts/factory-doctor.py` reports compatible interpreters on `PATH`.

---

## Complex build burns fix rounds without progress

**Symptom:** Multiple `/oc fix` rounds on a large spec still show Verification FAIL; run-review cites complex fix-round waste.

**Cause:** Complex builds (high complexity, many spec sections, or issue spend above target) trigger a **one fix-round circuit breaker** in [`scripts/factory-fix-policy.py`](../scripts/factory-fix-policy.py).

**Fix:**

1. Dry-run policy: `python3 scripts/factory-fix-policy.py --issue <N> --repo-dir .`
2. On `stop_and_escalate`, route to a stronger model, a Cursor Cloud Agent, or an owner split of the issue—do not loop another identical fix round.
3. Review spend with `python3 scripts/factory-issue-spend.py` inputs and [`factory-cost-digest.py`](../scripts/factory-cost-digest.py) if needed.

---

## `git push` to `main` rejected

**Symptom:** Pre-push hook or GitHub rejects a direct push to the default branch.

**Cause:** [`scripts/protect-main.sh`](../scripts/protect-main.sh) and [`.github/rulesets/protect-main.json`](../.github/rulesets/protect-main.json) require PRs, block force-push, and require `gitleaks` and `pr-check`.

**Fix:**

1. Push a feature branch and open a PR; merge only when `pr-check`, `run-records`, and `gitleaks` are green on the head commit.
2. Owner verifies ruleset application: `bash scripts/protect-main.sh --verify` (admin token; see doctor `--live`).
3. On GitHub Free private repos, rulesets may not enforce server-side—document the gap and rely on hooks plus merge discipline.

---

## Workflow drift / audit failures

**Symptom:** `factory-audit-workflows.py --strict` exits 1; doctor reports workflow hygiene failures.

**Cause:** Local `.github/workflows/` diverged from template guardrails (unpinned actions, missing `test-all.sh`, missing Python pin, etc.).

**Fix:**

1. Run `python3 scripts/factory-audit-workflows.py` and read each finding.
2. Apply owner paste steps in [OWNER_WORKFLOW_SYNC.md](OWNER_WORKFLOW_SYNC.md).
3. Compare against [reusable-workflows/](reusable-workflows/README.md) when bumping pins.
4. Re-run with `--strict` before merge.

---

## Human merge gate not visible on the PR

**Symptom:** Product approval happened in chat but the PR body has no durable record; merge helper refuses to proceed.

**Cause:** Factory merge policy expects a documented human gate on the PR body.

**Fix:** Owner runs `bash scripts/factory-merge.sh <pr> --approval '<quote>' --when '<time>'` after required checks are green (see merge script usage). Triage comments use **`Recommendation:`** / **`Why:`** for planning, not as a substitute for merge approval.

---

## Doc link check failures

**Symptom:** `pr-check` or CI reports broken Markdown links; `factory-check-docs.py` lists missing anchors or scripts.

**Fix:**

```bash
python3 scripts/factory-check-docs.py
python3 scripts/factory-check-docs.py --strict   # gate
```

Fix relative links and `#heading` anchors; only reference `scripts/*.py|sh` paths that exist in the repo. Template placeholders like `scripts/test-N.sh` are allowed where documented.