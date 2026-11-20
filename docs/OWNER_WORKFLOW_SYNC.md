# Owner workflow sync — paste runbook

Single-page checklist for pending **owner-only** `.github/workflows/` edits (agents must not commit workflow bodies). Tracked issues: **#56**, **#57**, **#111**, **#148**, **#178**, **#214**, **#74**, **#44**, **#41**.

## Verify after every paste

```bash
python3 scripts/factory-audit-workflows.py          # report only (exit 0)
python3 scripts/factory-audit-workflows.py --strict # gate before declaring done
python3 scripts/factory-owner-pack.py --json        # launch-readiness scorecard
```

`factory-audit-workflows.py` groups findings by category (SHA pins, permissions, `pr-check` gates, Python pin, `approve-oc-runs` safety, factory site, optional `factory-selected`). `factory-owner-pack.py` JSON includes `owner_workflow_sync_path` pointing at this file.

### Action SHA pins (never floating `@v7` tags)

Reuse these 40-character pins everywhere (from template `main` workflows):

| Action | Pin |
| --- | --- |
| `actions/checkout` | `3d3c42e5aac5ba805825da76410c181273ba90b1` # v7.0.1 |
| `actions/setup-python` | `6d4fd22b20465ccc0f7354476588e8df7c9ca0e0` # v7.1.0 |
| `actions/download-artifact` | `9000827ccba6bdab643e8b6fd33ac0654aef8333` # v8.0.2 |
| `actions/upload-artifact` | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` # v7.0.2 |
| `actions/upload-pages-artifact` | `fc324d3547104276b827a68afc52ff2a11cc49c9` # v5.0.0 |
| `actions/deploy-pages` | `368f82528645a54fb793d4d04e342629a3f51346` # v5.0.1 |
| `step-security/harden-runner` | `46b06cea07f9e64621fdf066ba77ac6915163d43` # v2.22.3 |

**Verify:** `python3 scripts/factory-audit-workflows.py --json | grep action_pin` — every workflow file should show `pass` for `action_pin`.

---

## 1. `pr-check.yml` — SHA pins + quality gates (#57, #161, #178)

Keep existing SHA-pinned `uses:` steps. In the **`pr-check`** job, after `pip install -r requirements-factory.txt`, run the same offline gates as `scripts/factory-owner-pack.py`:

```yaml
      - name: Shell script hygiene (#57)
        run: bash scripts/test-shell-hygiene.sh

      - name: PR body rule tests (#57)
        run: bash scripts/test-pr-check.sh

      - name: Cost prediction tests (#57)
        run: bash scripts/test-predict-cost.sh

      - name: Spec template vs models.yaml drift (#57, #161)
        run: bash scripts/test-spec-template-drift.sh

      - name: Doc links and script refs (#178)
        run: python3 scripts/factory-check-docs.py --strict

      - name: Pre-public hygiene (#178)
        run: python3 scripts/factory-prepublic-check.py --strict
```

**Verify:**

```bash
python3 scripts/factory-audit-workflows.py --strict
# pr_check_* rows in category pr_check_quality_gates should all PASS
bash scripts/test-shell-hygiene.sh
bash scripts/test-pr-check.sh
bash scripts/test-predict-cost.sh
bash scripts/test-spec-template-drift.sh
python3 scripts/factory-check-docs.py --strict
python3 scripts/factory-prepublic-check.py --strict
```

Optional: add `bash scripts/test-all.sh` later for full offline discovery; the six steps above are the required owner-sync minimum.

---

## 2. `factory-site.yml` — Pages deploy + budget file (#56, #170)

Template `main` already ships `factory-site.yml` for public repos (GitHub Pages) and artifact-only deploys when the repo is private. Owner responsibilities:

1. **Budget ownership:** keep `factory/budget.yml` as the committed source of truth; `push.paths` must include `factory/**` (covers budget + dbt inputs).
2. **Pages:** enable **Settings → Pages → Source: GitHub Actions** on public repos; `deploy` uses SHA-pinned `actions/deploy-pages`.
3. **Secrets:** no model spend — `GITHUB_TOKEN` only.

**Verify:**

```bash
python3 scripts/factory-audit-workflows.py --json | grep factory_site
bash scripts/test-factory-site.sh
bash scripts/test-factory-site-build.sh
python3 scripts/factory-site-smoke.py --build
```

---

## 3. `factory-selected.yml` — optional auto-dispatch (#111)

Optional workflow for phone kickoff: `factory:selected` label → `/oc spec` → approve → `/oc run`. Full YAML and prerequisites live in **`docs/WORKFLOW_FACTORY_SELECTED.md`** (logic: `scripts/factory-selected-dispatch.py`).

**Verify after paste:**

```bash
python3 scripts/factory-audit-workflows.py --json | grep factory_selected
# factory-selected.yml absent => factory_selected_optional PASS (optional)
```

---

## 4. `approve-oc-runs.yml` — bot `/oc` PR safety (#214, #74)

`pull_request_target` alone does not unblock PRs opened by `github-actions[bot]`. Extend `on:` (keep existing `pull_request_target`):

```yaml
on:
  pull_request_target:
    types: [opened, synchronize, reopened]
  workflow_run:
    workflows: [pr-check, secret-scan]
    types: [requested]
```

Add a **`workflow_run`** job (or generalize `approve`) that inspects `github.event.workflow_run`, approves only when:

- run status is `action_required`,
- head branch starts with `oc/`,
- `head_repository.full_name` equals **this** repo (never fork workflows).

Keep the existing `approve` job guards:

```yaml
    if: >-
      startsWith(github.event.pull_request.head.ref, 'oc/') &&
      github.event.pull_request.head.repo.full_name == github.repository
```

**Verify:**

```bash
python3 scripts/factory-audit-workflows.py --strict
# approve_oc_workflow_run, approve_oc_branch_guard, approve_oc_fork_guard PASS
```

---

## 5. `opencode-spike.yml` / `opencode-fix.yml` — Python 3.12/3.13 (#148)

In each **`agent`** job, after `harden-runner` and before `checkout`:

```yaml
      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0 # v7.1.0
        with:
          python-version: "3.13"
```

Use `"3.12"` for parity with `pr-check.yml`. Either 3.12 or 3.13 satisfies the audit (`oc_agent_python_pin`).

**Verify:** `python3 scripts/factory-audit-workflows.py --json | grep oc_agent_python_pin`

---

## 6. `secret-scan.yml` — harden-runner (#44)

In **`gitleaks`**, before checkout (job downloads gitleaks via `curl`):

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

**Verify:** `python3 scripts/factory-audit-workflows.py --json | grep harden_runner`

---

## 7. Independent Critic `review` job (#41) — optional

Scripts on `main`: `factory-critic-context.py`, `factory-critic-run.py`. Wire a **`review`** job in `opencode-spike.yml` / `opencode-fix.yml` after **`agent`**, fresh runner, read-only tokens, prompt from default branch. Sketch:

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
    steps:
      - uses: step-security/harden-runner@46b06cea07f9e64621fdf066ba77ac6915163d43 # v2.22.3
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
```

See `docs/CRITIC_REVIEW.md` for operator detail.

---

## 8. Recommended paste order

1. **`pr-check.yml`** quality gates (#57, #161, #178) — unblocks PR CI parity with owner-pack.
2. **`opencode-*.yml`** Python pin (#148) — dbt / Verification on hosted runners.
3. **`approve-oc-runs.yml`** `workflow_run` (#214) — bot PRs without manual approve.
4. **`secret-scan.yml`** harden-runner (#44).
5. **`factory-site.yml`** review (usually already present; confirm budget paths + Pages).
6. **`factory-selected.yml`** when ready for label kickoff (#111).
7. Critic **`review`** job when ready to spend review tokens (#41).

---

## 9. Product repos

Replace hard-coded owner login checks in `opencode-*.yml` / `factory-selected.yml` with this repo’s owner account (see `docs/SETUP.md`). SHAs and job shape stay the same. Re-run `factory-audit-workflows.py --strict` after each adoption.