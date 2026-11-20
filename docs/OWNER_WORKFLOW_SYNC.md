# Owner workflow sync checklist

One consolidated paste list for pending `.github/workflows/` edits tracked across issues **#57**, **#148**, **#41**, **#214**, **#74**, **#44**, **#56**, **#161**, and **#178**. Agents must not commit these YAML changes; the **owner** copies the blocks below into the repo default branch.

After each paste (or one combined owner PR), run:

```bash
python3 scripts/factory-audit-workflows.py          # report only, exit 0
python3 scripts/factory-audit-workflows.py --strict # gate: exit 1 until clean
```

Verified action SHAs below are taken from the template’s current workflow files on `main`.

| Action | Pin |
| --- | --- |
| `actions/checkout` | `3d3c42e5aac5ba805825da76410c181273ba90b1` # v7.0.1 |
| `actions/setup-python` | `6d4fd22b20465ccc0f7354476588e8df7c9ca0e0` # v7.1.0 |
| `actions/download-artifact` | `9000827ccba6bdab643e8b6fd33ac0654aef8333` # v8.0.2 |
| `actions/upload-artifact` | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` # v7.0.2 |
| `step-security/harden-runner` | `46b06cea07f9e64621fdf066ba77ac6915163d43` # v2.22.3 |

---

## 1. `pr-check.yml` — consolidated quality gates (#57, #161, #178)

Template `main` quality gates for every PR (same checks as `scripts/factory-owner-pack.py`). In the **`pr-check`** job, after factory Python dependencies are installed, add or replace fragmented single-script steps with:

```yaml
      - name: Run all offline script tests (#57, #161)
        run: bash scripts/test-all.sh

      - name: Doc links and script refs (#178)
        run: python3 scripts/factory-check-docs.py --strict

      - name: Pre-public hygiene (#178)
        run: python3 scripts/factory-prepublic-check.py --strict

      - name: models.yaml schema (#178)
        run: python3 scripts/factory-models-check.py

      - name: Factory site HTML smoke (#178, #56)
        run: python3 scripts/factory-site-smoke.py --build
```

- `bash scripts/test-all.sh` auto-discovers every `scripts/test-*.sh` on `main` (65+ scripts), including `test-examples.sh`, `test-factory-e2e-adopter.sh`, `test-factory-models-check.sh`, `test-factory-check-docs.sh`, `test-factory-prepublic-check.sh`, `test-factory-site-smoke.sh`, and the rest of the offline harness.
- The four Python steps are fast CI guards that mirror owner-pack gates; they exit non-zero on failure (`--strict` on docs and pre-public scans).
- Keep every workflow `uses:` on a **40-character commit SHA** (never floating `@v4` / `@v7` tags). Reuse the pin table at the top of this doc.

Optional cleanup: once `test-all.sh` is green in CI, you may drop redundant one-off steps in **`run-records`** or **`pr-check`** that `test-all.sh` already covers (for example duplicate `test-spec-check.sh` or site fixture shells) if job time matters.

---

## 2. `opencode-spike.yml` and `opencode-fix.yml` — pin Python on agent (#148)

In each file’s **`agent`** job, insert **after** the `harden-runner` step and **before** `actions/checkout`:

```yaml
      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0 # v7.1.0
        with:
          python-version: "3.13"
```

Use `"3.12"` instead if you want strict parity with `pr-check.yml`; either 3.12 or 3.13 satisfies the audit. Goal: harness Verification does not run dbt on the runner’s default Python 3.14.

---

## 3. `approve-oc-runs.yml` — bot-opened `oc/` PRs (#214, #74)

`pull_request_target` alone does not cover PRs opened by `github-actions[bot]`. Extend `on:` (keep the existing `pull_request_target` block):

```yaml
on:
  pull_request_target:
    types: [opened, synchronize, reopened]
  workflow_run:
    workflows: [pr-check, secret-scan]
    types: [requested]
```

Add a second job (or generalize `approve`) that runs on `workflow_run`, reads `github.event.workflow_run`, and approves when the run is `action_required` **and** the head branch starts with `oc/` **and** `head_repository.full_name` equals this repo (never approve fork workflows). Reuse the same `gh api … approve` loop as the existing job.

---

## 4. `secret-scan.yml` — harden-runner (#44)

In the **`gitleaks`** job, before checkout (this job downloads gitleaks via `curl`):

```yaml
      - name: Harden runner (audit egress)
        uses: step-security/harden-runner@46b06cea07f9e64621fdf066ba77ac6915163d43 # v2.22.3
        with:
          egress-policy: audit
          allowed-endpoints: |
            github.com:443
            objects.githubusercontent.com:443
            release-assets.githubusercontent.com:443
```

---

## 5. Independent Critic `review` job (#41) — optional first paste

Scripts landed on `main` (`factory-critic-context.py`, `factory-critic-run.py`). Wire a **`review`** job into `opencode-spike.yml` and `opencode-fix.yml` after **`agent`** succeeds and before **`publish`**, on a fresh runner, read-only tokens, prompt from **default branch**, `DEEPINFRA_API_KEY` only in that job. Sketch (adjust artifact names to match your `upload-artifact` steps):

```yaml
  review:
    needs: agent
    if: success()
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
      issues: read
      pull-requests: read
    env:
      DEEPINFRA_API_KEY: ${{ secrets.DEEPINFRA_API_KEY }}
      OC_ARTIFACT_DIR: /tmp/oc-artifacts
      OC_CRITIC_DIR: /tmp/oc-critic
      OC_CODER_MODEL: ${{ needs.agent.outputs.model_id }}
    steps:
      - name: Harden runner (audit egress)
        uses: step-security/harden-runner@46b06cea07f9e64621fdf066ba77ac6915163d43 # v2.22.3
        with:
          egress-policy: audit
          allowed-endpoints: |
            api.deepinfra.com:443
            github.com:443
            api.github.com:443
            objects.githubusercontent.com:443
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: ${{ github.event.repository.default_branch }}
          persist-credentials: false
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: oc-artifacts-${{ github.run_id }}
          path: ${{ env.OC_ARTIFACT_DIR }}
      - run: python3 scripts/factory-critic-context.py --out-dir "$OC_CRITIC_DIR"
      - run: python3 scripts/factory-critic-run.py --input "$OC_CRITIC_DIR/critic-input.md" --meta "$OC_CRITIC_DIR/critic-meta.txt" --out-dir "$OC_CRITIC_DIR"
      - run: test -s "$OC_CRITIC_DIR/critic-review.md" && test -s "$OC_CRITIC_DIR/critic-run-record.json"
```

Then teach **`publish`** to `needs: [agent, review]` (or post the critic comment from a small publish sub-step). Full cost recording belongs in the same epic as #41; this paste is the workflow shell only.

---

## 6. Order of operations

1. `pr-check.yml` quality gates (`test-all.sh` plus docs, pre-public, models, site smoke; #57, #161, #178).
2. `opencode-*.yml` Python pin (unblocks dbt Verification on hosted runners).
3. `approve-oc-runs.yml` `workflow_run` (unblocks bot PR checks without manual approve).
4. `secret-scan.yml` harden-runner (security baseline #44).
5. Critic `review` job when ready to spend review tokens on every `/oc` build.

---

## 7. Product repos

Replace hard-coded owner login checks in `opencode-*.yml` with this repo’s owner account when pasting (see `docs/SETUP.md`). SHAs and job shape stay the same.