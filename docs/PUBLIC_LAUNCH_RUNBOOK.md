# Public launch runbook (~10 minutes)

Repo-agnostic owner checklist to take a **private** factory template from “ready to cut v0.1.0” to **public** with GitHub Pages and a first adopter pilot. Automation stays read-only until you run the owner-only shell steps.

**Time budget:** ~10 minutes if the unified gate is already green and workflow pastes are staged.

---

## 1. Unified automation gate (2 min)

From a clean checkout on the commit you intend to launch:

```bash
python3 scripts/factory-owner-pack.py --version v0.1.0
python3 scripts/factory-owner-pack.py --version v0.1.0 --strict   # fail on warnings
python3 scripts/factory-owner-pack.py --version v0.1.0 --json     # CI / logs
```

Fix anything **FAIL** using the remediation command printed in the scorecard. **WARN** rows are acceptable for a dry run; use `--strict` before you flip visibility.

Optional flags:

```bash
python3 scripts/factory-owner-pack.py --version v0.1.0 --skip-site   # faster; skip site build
python3 scripts/factory-owner-pack.py --version v0.1.0 --out /tmp/owner-pack.md
```

Offline tests: `bash scripts/test-factory-owner-pack.sh`.

### Owner-pack gate table (automation on `main`)

| Gate id | Check | Owner doc pointer |
| --- | --- | --- |
| `doctor` | `factory-doctor.py` repo health | — |
| `prepublic` | `factory-prepublic-check.py` hygiene scan | `docs/OWNER_WORKFLOW_SYNC.md` |
| `models_config` | `factory-models-check.py --json` | `docs/MODEL_SCOUTING.md` |
| `decision_log` | `factory-decision-log.py check --json` | — |
| `check_docs` | `factory-check-docs.py` links + script refs | — |
| `audit_workflows` | `factory-audit-workflows.py` workflow drift | `docs/OWNER_WORKFLOW_SYNC.md` |
| `shell_hygiene` | `test-shell-hygiene.sh` portable shell tests | — |
| `examples_smoke` | `test-examples.sh` golden `examples/` validators | — |
| `reusable_check` | `factory-reusable-check.py` *(skipped if not yet on disk)* | — |
| `site_smoke` | `factory-site-smoke.py --build` HTML smoke | — |
| `release` | `factory-release.py` tag / changelog gate | `docs/CRITIC_REVIEW.md` |

The Markdown scorecard ends with pass / warn / fail / skip counts and links to `docs/OWNER_WORKFLOW_SYNC.md`, `docs/CRITIC_REVIEW.md`, and `docs/MODEL_SCOUTING.md`.

---

## 2. Sync owner workflows (3 min)

Agents do **not** commit workflow bodies. Copy pending blocks from [OWNER_WORKFLOW_SYNC.md](OWNER_WORKFLOW_SYNC.md) into `.github/workflows/` on the default branch (one owner PR or several small pastes).

After each paste:

```bash
python3 scripts/factory-audit-workflows.py
python3 scripts/factory-audit-workflows.py --strict
```

Re-run the owner pack (step 1) when workflow edits land.

---

## 3. Harden repository settings (2 min)

As a repo **admin** (never a factory agent token):

```bash
bash scripts/harden-repo.sh --dry-run
bash scripts/harden-repo.sh
```

Optional: `bash scripts/harden-repo.sh --repo OWNER/REPO` from any clone. Confirm branch protection separately:

```bash
bash scripts/protect-main.sh --verify
```

Baseline reference: [.factory/repo-security-baseline.md](../.factory/repo-security-baseline.md).

---

## 4. Flip visibility & vulnerability reporting (1 min)

In **GitHub → Settings → General**:

1. Change **Danger Zone → Change repository visibility** to **Public** (only after step 1 is green and step 3 is done).
2. Enable **Private vulnerability reporting** (recommended for public repos).

Re-run `python3 scripts/factory-prepublic-check.py --strict` if anything changed in the tree during paste work.

---

## 5. Enable GitHub Pages & verify the Factory Site (1 min)

Public repos only (see [SETUP.md](SETUP.md) § Site hosting):

1. Paste `.github/workflows/factory-site.yml` if not already on `main` (owner paste; high risk).
2. **Settings → Pages → Build and deployment → Source** → **GitHub Actions** (not “Deploy from a branch”).
3. Run the **factory-site** workflow once from the Actions tab.
4. Confirm deploy summary links live HTML, normally `https://<owner>.github.io/<repo>/`.

Local smoke (no Pages required):

```bash
python3 scripts/factory-site-smoke.py --build --strict
```

---

## 6. Tag & publish `v0.1.0` (1 min)

Follow [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md):

```bash
python3 scripts/factory-release.py --version v0.1.0 --strict
```

When green, run the owner commands printed at the bottom of that helper (annotated tag, push tag, `gh release create`, and `python3 scripts/factory-sync-repos.py --tag v0.1.0 --dry-run` when available). See [RELEASING.md](RELEASING.md) for approval gates.

---

## 7. Pilot first adopter repo (optional, same day)

Bootstrap one product repo and pin the new tag:

```bash
python3 scripts/factory-init-repo.py --target /path/to/product-repo --tag v0.1.0
```

Full install checklist: [INIT_REPO.md](INIT_REPO.md) and [SETUP.md](SETUP.md). Broader adoption notes: [ADOPTING.md](../ADOPTING.md).

---

## Quick checklist

| Step | Done when |
| --- | --- |
| Owner pack | `factory-owner-pack.py --version v0.1.0 --strict` → **READY** |
| Workflows | `factory-audit-workflows.py --strict` → exit 0 |
| Harden | `harden-repo.sh` summary rows pass; `protect-main.sh --verify` OK |
| Public | Repo visibility **Public**; private vulnerability reporting on |
| Pages | factory-site workflow deploy succeeded; URL loads |
| Release | Tag `v0.1.0` on GitHub with release notes from `CHANGELOG.md` |
| Pilot | One product repo initialized with `--tag v0.1.0` |