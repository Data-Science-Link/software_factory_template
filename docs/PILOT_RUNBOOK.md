# First-adopter pilot runbook

End-to-end checklist to onboard **one real product repository** to a tagged factory release (example: `v0.1.0`). Run this after the template owner cuts the tag and before you widen adoption. Everything here is read-only or owner-gated until you merge.

**Prerequisites:** Reusable workflows are live on the template default branch ([#156](https://github.com/Data-Science-Link/software_factory_template/issues/156)), CI is green on the tag commit, and the template owner approved the release. See [RELEASING.md](RELEASING.md) and [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).

**Time budget:** about half a day for a greenfield product repo; longer when migrating copied scripts.

---

## Step 1 — Preflight (bootstrap or migrate)

From a checkout of `YOUR_ORG/software_factory_template` on the tag you intend to pilot:

### Greenfield product repo

```bash
python3 scripts/factory-init-repo.py \
  --target /path/to/your-app \
  --owner YOUR_GITHUB_LOGIN \
  --template-repo YOUR_ORG/software_factory_template \
  --tag v0.1.0 \
  --force
```

Preview first with `--dry-run`. Use `--no-with-callers` only when you plan to paste workflows manually; the pilot expects thin caller stubs pinned to `--tag`.

### Existing repo (copied scripts / full workflows)

```bash
python3 scripts/factory-migrate-adopter.py \
  --repo-dir /path/to/your-app \
  --tag v0.1.0 \
  --owner YOUR_GITHUB_LOGIN
```

Review the dry-run report, then apply with `--apply`. Paste generated callers from `.factory/migration-callers/` into `.github/workflows/` (owner). Details: [MIGRATING.md](MIGRATING.md), [INIT_REPO.md](INIT_REPO.md).

**Done when:** The product repo has `mode: product` in `.factory/mode.yml`, caller workflows pin `YOUR_ORG/software_factory_template/.../reusable-*.yml@v0.1.0`, and matching `factory_ref: v0.1.0` where required.

---

## Step 2 — GitHub secrets, variables, and repo hardening

As a repository **admin** on `YOUR_ORG/your-app` (never a factory agent token):

| Item | Action |
| --- | --- |
| `DEEPINFRA_API_KEY` | Actions **secret** for workflow runs |
| `FACTORY_DEEPINFRA_KEY_NAME` | Actions **variable** naming the spend-tracked API key |
| Actions permissions | Read and write for workflows that open PRs and push branches |
| Branch protection | `main` protected; required checks include `pr-check` when wired |

```bash
bash scripts/harden-repo.sh --repo YOUR_ORG/your-app --dry-run
bash scripts/harden-repo.sh --repo YOUR_ORG/your-app
bash scripts/protect-main.sh --verify
```

Baseline: [.factory/repo-security-baseline.md](../.factory/repo-security-baseline.md), [SETUP.md](SETUP.md).

**Done when:** Secrets and variables exist, hardening summary is clean, and `protect-main.sh --verify` passes (or documents the one owner fix still needed).

---

## Step 3 — Factory doctor (zero failures)

```bash
python3 scripts/factory-doctor.py --repo-dir /path/to/your-app
python3 scripts/factory-doctor.py --repo-dir /path/to/your-app --strict
```

Add `LICENSE` and `SECURITY.md` before `--strict` if the product repo is public. See [DOCTOR.md](DOCTOR.md).

**Done when:** `factory-doctor.py --strict` exits **0** (warnings allowed unless your policy says otherwise; **no failures**).

---

## Step 4 — One small pilot issue (factory loop)

Pick one **low-risk** issue with a narrow file scope (single script or doc change preferred).

| Phase | Owner action |
| --- | --- |
| Spec | Comment `/oc spec` on the issue (optionally add guidance) |
| Approval | Review the spec PR or draft; approve per your risk class |
| Build | Comment `/oc run` after approval |
| Verify | Confirm required checks on the worker PR: `pr-check`, `run-records`, `gitleaks` |
| Merge | Human review and merge to `main` (workers do not merge) |

The pilot passes only if the issue completes **spec → approval → build → green checks → human merge** on the pinned tag. Triage and setup: [SETUP.md](SETUP.md), [TRIAGE.md](TRIAGE.md).

**Done when:** One merged PR on `main` from a factory worker run, with run record and cost lines present on the PR body.

---

## Step 5 — Cost capture and Factory Site preview

After the pilot merge, confirm spend is recorded and readable:

```bash
python3 scripts/factory-cost-reconcile.py --repo-dir /path/to/your-app
python3 scripts/factory-cost-digest.py --days 7 --json
```

On the **template** repo (if you publish the factory site), confirm the site workflow and HTML smoke:

```bash
python3 scripts/factory-site-smoke.py --build --strict
```

See [COST_DIGEST.md](COST_DIGEST.md). Template site hosting: [SETUP.md](SETUP.md).

**Done when:** Reconcile reports no unexplained drift for the pilot run; digest includes the pilot issue; site smoke passes if you use Pages.

---

## Step 6 — Pass / fail and rollback

### Pass criteria (all required)

- [ ] Product repo pinned to the approved tag (`v0.1.0` or later) on every caller workflow
- [ ] `factory-doctor.py --strict` → 0 failures on the product repo
- [ ] One pilot issue merged through the full factory loop with green required checks
- [ ] Run record JSON exists under `factory/runs/` and PR cost lines are present
- [ ] Owner sign-off to adopt the pin for further issues

### Fail criteria (stop and fix before widening)

- Doctor failures, missing secrets, or branch protection gaps
- Worker PR missing run record, cost lines, or failing `pr-check` / `gitleaks`
- Caller workflows fetch the wrong tag or template repo

### Safe rollback / unpin

1. **Product repo:** Revert the sync or init PR that introduced caller stubs, or set each `uses:` / `factory_ref:` back to the last known-good tag in a single owner PR.
2. **Pause workers:** Disable or do not trigger `/oc run` until the pin is fixed.
3. **Template:** Do not move or delete a published tag; ship a patch tag (`v0.1.1`) if the template itself was wrong.

To preview adopter bumps from the template checkout:

```bash
python3 scripts/factory-sync-repos.py \
  --repos-file factory/adopters.txt \
  --tag v0.1.0 \
  --dry-run
```

---

## Related docs

- [INIT_REPO.md](INIT_REPO.md) — bootstrap flags and files
- [MIGRATING.md](MIGRATING.md) — move off copied scripts
- [PUBLIC_LAUNCH_RUNBOOK.md](PUBLIC_LAUNCH_RUNBOOK.md) — template goes public + first tag
- [RELEASING.md](RELEASING.md) — semver tags and adopter sync

Issues: [#182](https://github.com/Data-Science-Link/software_factory_template/issues/182), [#178](https://github.com/Data-Science-Link/software_factory_template/issues/178), [#156](https://github.com/Data-Science-Link/software_factory_template/issues/156).