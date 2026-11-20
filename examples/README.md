# Golden examples (live-validated)

Copy-paste references for **product** repos adopting the Software Factory. Each file is checked by `bash scripts/test-examples.sh` against the same offline validators CI uses.

| Path | Purpose |
| --- | --- |
| `minimal-product-repo/` | Minimal adopted layout: `mode.yml`, `models.yaml`, `DECISIONS.md`, `AGENTS.md` |
| `sample-spec.md` | Product spec shape (`src/` + `tests/`, not `scripts/`) |
| `sample-pr-body.md` | PR body with issue link, AI disclosure, cost, verification, human review checklist |
| `sample-runs/` | Three synthetic run-record JSON files (build / review / fix) for financial previews |

Run the drift test after editing any golden file: `bash scripts/test-examples.sh`.

## Sample run records (`sample-runs/`)

Schema-valid, repo-agnostic fixtures for adopters who want to exercise cost tooling and a local Factory Site preview **before** real `factory/runs/` data exists. Files use synthetic `example-org/sample-app` URLs and prices from the template `.factory/models.yaml` (`price_table_version: 2026-11-02`).

| File | Scenario | `work_type` | Notes |
| --- | --- | --- | --- |
| `gha-100001-1.json` | Coding (initial build) | `code` | Opens a PR |
| `gha-100002-1.json` | Review | `review` | Independent review harness |
| `gha-100003-1.json` | Fix round | `code` | `outcome: pr_updated` on the same PR |

Install factory Python deps once: `pip install -r requirements-factory.txt`

**Validate every record against the JSON Schema:**

```bash
python3 scripts/factory-validate-run.py examples/sample-runs/*.json
```

**Reconcile logged cost vs. current `models.yaml` prices (expect 0 drift):**

```bash
python3 scripts/factory-cost-reconcile.py --runs-dir examples/sample-runs --strict
```

**Build a CFO-style cost digest for the golden runs:**

```bash
python3 scripts/factory-cost-digest.py \
  --runs-dir examples/sample-runs \
  --models-file .factory/models.yaml \
  --as-of 2026-11-20 \
  --days 30
```

**Render a preview Factory Site (Financials includes Coding vs. Review spend):**

```bash
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/site-data/marts"
cp tests/site-data/sample-marts/*.json "$tmpdir/site-data/marts/"
python3 - examples/sample-runs "$tmpdir/site-data/marts/fct_agent_runs.json" <<'PY'
import json, sys
from pathlib import Path

runs_dir = Path(sys.argv[1])
out = Path(sys.argv[2])
rows = []
for path in sorted(runs_dir.glob("*.json")):
    r = json.loads(path.read_text(encoding="utf-8"))
    started = r["started_at"]
    tin = int(r["tokens_in"])
    tcached = int(r["tokens_cached"])
    actual = float(r["actual_cost_usd"])
    predicted = float(r["predicted_cost_usd"])
    rows.append({
        "run_id": r["run_id"],
        "issue": r["issue"],
        "pr": r["pr"],
        "harness": r["harness"],
        "provider": r["provider"],
        "model_id": str(r["model"]).lower(),
        "complexity": r["complexity"],
        "risk": r["risk"],
        "work_type": r["work_type"],
        "outcome": r["outcome"],
        "gate_passed": bool(r["gate_passed"]),
        "started_at_utc": started,
        "run_date": started[:10],
        "requests": r["requests"],
        "tokens_in": tin,
        "tokens_cached": tcached,
        "tokens_out": r["tokens_out"],
        "tokens_reasoning": r["tokens_reasoning"],
        "predicted_cost_usd": predicted,
        "actual_cost_usd": actual,
        "cost_variance_usd": round(actual - predicted, 6),
        "cache_hit_rate": round(tcached / tin, 6) if tin else 0.0,
        "duration_s": r["duration_s"],
        "actions_minutes": r["actions_minutes"],
    })
out.write_text(json.dumps(rows, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
python3 scripts/factory-site-data.py \
  --source "$tmpdir/site-data/marts" \
  --out "$tmpdir/site-data/marts"
python3 scripts/factory-site.py \
  --repo-root . \
  --data "$tmpdir/site-data" \
  --out "$tmpdir/site" \
  --now "2026-11-20 12:00:00"
cp factory/site/style.css "$tmpdir/site/style.css"
python3 scripts/factory-site-smoke.py "$tmpdir/site"
```