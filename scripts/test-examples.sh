#!/usr/bin/env bash
# Live-validated drift test for examples/ golden files (Refs #178, #182, #38).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

passed=0
failed=0

ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }

require_script() {
  local rel="$1"
  if [ ! -f "$rel" ]; then
    echo "FAIL  missing $rel (merge factory validator PRs before this test can run)"
    exit 1
  fi
}

require_script scripts/factory-spec-lint.py
require_script scripts/factory-decision-log.py
require_script scripts/factory-models-check.py
require_script scripts/factory-prepublic-check.py
require_script scripts/factory-validate-run.py
require_script scripts/factory-cost-reconcile.py
require_script scripts/factory-cost-digest.py
require_script scripts/factory-site.py
require_script scripts/factory-site-data.py
require_script scripts/factory-site-smoke.py

if ! "$PYTHON" -c "import yaml" 2>/dev/null; then
  echo "FAIL  PyYAML required (pip install -r requirements-factory.txt)"
  exit 1
fi

if ! "$PYTHON" -c "import jsonschema" 2>/dev/null; then
  echo "FAIL  jsonschema required (pip install -r requirements-factory.txt)"
  exit 1
fi

SAMPLE_RUNS="examples/sample-runs"
PINNED_NOW="2026-11-20 12:00:00"
DIGEST_AS_OF="2026-11-20"

set +e
out="$(
  "$PYTHON" scripts/factory-spec-lint.py --mode product --strict examples/sample-spec.md 2>&1
)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'warning:'; then
  ok "factory-spec-lint sample-spec.md (0 errors, 0 warnings)"
else
  bad "factory-spec-lint sample-spec.md (rc=$rc)"
  printf '%s\n' "$out" | head -12
fi

set +e
out="$(
  "$PYTHON" scripts/factory-decision-log.py --file examples/minimal-product-repo/.factory/DECISIONS.md check 2>&1
)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  ok "factory-decision-log DECISIONS.md"
else
  bad "factory-decision-log check (rc=$rc)"
  printf '%s\n' "$out" | head -12
fi

set +e
out="$(
  "$PYTHON" scripts/factory-models-check.py \
    --models-yaml examples/minimal-product-repo/.factory/models.yaml \
    --routing-md /dev/null 2>&1
)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  ok "factory-models-check models.yaml"
else
  bad "factory-models-check models.yaml (rc=$rc)"
  printf '%s\n' "$out" | head -12
fi

body="examples/sample-pr-body.md"
for needle in 'AI disclosure:' 'Cost:' 'Human review & approval'; do
  if grep -Fq "$needle" "$body"; then
    ok "sample-pr-body.md contains $needle"
  else
    bad "sample-pr-body.md missing $needle"
  fi
done

set +e
pr_out="$(
  PR_BRANCH=cursor/examples-showcase-c916 bash scripts/pr-check.sh "$body" 2>&1
)"
pr_rc=$?
set -e
if [ "$pr_rc" -eq 0 ]; then
  ok "pr-check.sh sample-pr-body.md"
else
  bad "pr-check.sh sample-pr-body.md (rc=$pr_rc)"
  printf '%s\n' "$pr_out" | head -8
fi

# --- sample-runs: validate, reconcile, digest, site preview ---
run_validate=0
run_validate_fail=0
for jf in "$SAMPLE_RUNS"/*.json; do
  [ -f "$jf" ] || continue
  set +e
  vout="$("$PYTHON" scripts/factory-validate-run.py "$jf" 2>&1)"
  vrc=$?
  set -e
  if [ "$vrc" -eq 0 ]; then
    run_validate=$((run_validate + 1))
  else
    run_validate_fail=$((run_validate_fail + 1))
    bad "factory-validate-run.py $jf (rc=$vrc)"
    printf '%s\n' "$vout" | sed 's/^/       /' | head -8
  fi
done
if [ "$run_validate_fail" -eq 0 ] && [ "$run_validate" -ge 3 ]; then
  ok "factory-validate-run.py all sample-runs ($run_validate files)"
else
  bad "factory-validate-run.py sample-runs (ok=$run_validate fail=$run_validate_fail)"
fi

set +e
rec_out="$(
  "$PYTHON" scripts/factory-cost-reconcile.py --runs-dir "$SAMPLE_RUNS" --strict 2>&1
)"
rec_rc=$?
set -e
if [ "$rec_rc" -eq 0 ] \
  && printf '%s\n' "$rec_out" | grep -q 'matched               3' \
  && printf '%s\n' "$rec_out" | grep -q 'drifted               0'; then
  ok "factory-cost-reconcile.py sample-runs (0 drift)"
else
  bad "factory-cost-reconcile.py sample-runs (rc=$rec_rc)"
  printf '%s\n' "$rec_out" | sed 's/^/       /' | head -16
fi

set +e
digest_out="$(
  "$PYTHON" scripts/factory-cost-digest.py \
    --runs-dir "$SAMPLE_RUNS" \
    --models-file .factory/models.yaml \
    --as-of "$DIGEST_AS_OF" \
    --days 30 2>&1
)"
digest_rc=$?
set -e
if [ "$digest_rc" -eq 0 ] \
  && printf '%s\n' "$digest_out" | grep -q 'Headline scorecard' \
  && printf '%s\n' "$digest_out" | grep -q 'Runs loaded: **3**'; then
  ok "factory-cost-digest.py sample-runs"
else
  bad "factory-cost-digest.py sample-runs (rc=$digest_rc)"
  printf '%s\n' "$digest_out" | sed 's/^/       /' | head -16
fi

site_data="$tmpdir/site-data"
site_out="$tmpdir/site"
mkdir -p "$site_data/marts"
cp tests/site-data/sample-marts/*.json "$site_data/marts/"
"$PYTHON" - "$SAMPLE_RUNS" "$site_data/marts/fct_agent_runs.json" <<'PY'
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
    rows.append(
        {
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
        }
    )
out.write_text(json.dumps(rows, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

"$PYTHON" scripts/factory-site-data.py \
  --source "$site_data/marts" \
  --out "$site_data/marts" >/dev/null

set +e
site_build_out="$(
  "$PYTHON" scripts/factory-site.py \
    --repo-root . \
    --data "$site_data" \
    --out "$site_out" \
    --now "$PINNED_NOW" 2>&1
)"
site_build_rc=$?
set -e
if [ "$site_build_rc" -ne 0 ] || [ ! -f "$site_out/financials.html" ]; then
  bad "factory-site.py preview from sample-runs (rc=$site_build_rc)"
  printf '%s\n' "$site_build_out" | sed 's/^/       /' | head -12
else
  ok "factory-site.py preview from sample-runs"
fi
cp factory/site/style.css "$site_out/style.css"

fin="$site_out/financials.html"
set +e
smoke_out="$("$PYTHON" scripts/factory-site-smoke.py "$site_out" 2>&1)"
smoke_rc=$?
set -e
if [ "$smoke_rc" -eq 0 ] && printf '%s\n' "$smoke_out" | grep -q '^OK'; then
  ok "factory-site-smoke.py preview site"
else
  bad "factory-site-smoke.py preview site (rc=$smoke_rc)"
  printf '%s\n' "$smoke_out" | sed 's/^/       /' | head -12
fi

if [ -f "$fin" ]; then
  set +e
  "$PYTHON" - "$fin" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
if "Spend by Work Type (Coding vs. Review)" not in html:
    raise SystemExit("missing spend-by-work-type heading")
if 'id="spend-by-work-type-table"' not in html:
    raise SystemExit("missing spend-by-work-type table id")
# Table rows use escaped work_type labels from run records.
if ">code<" not in html:
    raise SystemExit("missing code work_type row")
if ">review<" not in html:
    raise SystemExit("missing review work_type row")
PY
  wt_rc=$?
  set -e
  if [ "$wt_rc" -eq 0 ]; then
    ok "Financials renders code and review work types"
  else
    bad "Financials code/review work types (rc=$wt_rc)"
  fi
else
  bad "Financials code/review work types (no financials.html)"
fi

set +e
scan="$("$PYTHON" scripts/factory-prepublic-check.py . --json 2>&1)"
scan_rc=$?
set -e
if [ "$scan_rc" -ne 0 ]; then
  bad "factory-prepublic-check.py repo scan (rc=$scan_rc)"
  printf '%s\n' "$scan" | head -20
else
  ex_count="$(
    printf '%s' "$scan" | "$PYTHON" -c '
import json, sys
data = json.load(sys.stdin)
paths = [f["path"] for f in data.get("findings", []) if f["path"].startswith("examples/")]
print(len(paths))
if paths:
    print("FINDINGS", *paths, sep="\n", file=sys.stderr)
'
  )"
  if [ "$ex_count" -eq 0 ]; then
    ok "prepublic: no findings under examples/"
  else
    bad "prepublic: findings under examples/ (count=$ex_count)"
  fi
  total="$(
    printf '%s' "$scan" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["finding_count"])'
  )"
  if [ "$total" -eq 0 ]; then
    ok "prepublic: whole repo finding_count=0"
  else
    bad "prepublic: repo finding_count=$total (expected 0)"
  fi
fi

echo ""
echo "Results: ${passed} passed, ${failed} failed"
[ "$failed" -eq 0 ]