#!/usr/bin/env bash
# Offline tests for mart_spend_by_work_type site export and Financials rendering.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
ROOT="$(pwd)"
PINNED_NOW="2026-11-11 12:00:00"
SAMPLE="tests/site-data/sample-marts"

passed=0
failed=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail() {
  echo "FAIL  $1"
  failed=$((failed + 1))
}

pass() {
  echo "PASS  $1"
  passed=$((passed + 1))
}

# ---- build mixed work_type fixture runs ----
fixture_src="$tmpdir/mixed-source"
fixture_out="$tmpdir/mixed-export"
mkdir -p "$fixture_src" "$fixture_out/marts"
cp "$SAMPLE"/*.json "$fixture_src/"

"$PYTHON" - "$fixture_src/fct_agent_runs.json" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
base = json.loads(path.read_text(encoding="utf-8"))
if isinstance(base, list) and base:
    template = dict(base[0])
else:
    template = {
        "run_id": "gha-00000000001-1",
        "issue": 1,
        "pr": None,
        "harness": "cursor-cloud",
        "provider": "cursor",
        "model_id": "composer-2.5",
        "complexity": "simple",
        "risk": "trivial",
        "work_type": "coding",
        "outcome": "pr_opened",
        "gate_passed": True,
        "started_at_utc": "2026-11-10T12:00:00Z",
        "run_date": "2026-11-10",
        "requests": 1,
        "tokens_in": 1000,
        "tokens_cached": 0,
        "tokens_out": 200,
        "tokens_reasoning": 0,
        "predicted_cost_usd": 0.05,
        "actual_cost_usd": 0.05,
        "cost_variance_usd": 0.0,
        "cache_hit_rate": 0.0,
        "duration_s": 60,
        "actions_minutes": 2,
    }

rows = []
specs = [
    ("coding", 0.40, True, 5000, 100, 800),
    ("review", 0.15, True, 2000, 500, 300),
    ("spec", 0.25, False, 8000, 0, 1200),
    ("fix", 0.20, True, 3000, 200, 400),
]
for i, (wt, cost, passed, tin, tcached, tout) in enumerate(specs, start=1):
    row = dict(template)
    row["run_id"] = f"gha-9900000000{i}-1"
    row["work_type"] = wt
    row["actual_cost_usd"] = cost
    row["predicted_cost_usd"] = cost
    row["gate_passed"] = passed
    row["tokens_in"] = tin
    row["tokens_cached"] = tcached
    row["tokens_out"] = tout
    rows.append(row)
path.write_text(json.dumps(rows, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

if "$PYTHON" scripts/factory-site-data.py \
  --source "$fixture_src" \
  --out "$fixture_out/marts" >/dev/null \
  && "$PYTHON" - "$fixture_out/marts/mart_spend_by_work_type.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
rows = data["rows"] if isinstance(data, dict) else data
by = {r["work_type"]: r for r in rows}
need = ("coding", "review", "spec", "fix")
for wt in need:
    if wt not in by:
        raise SystemExit(f"missing work_type {wt}")
coding = float(by["coding"]["total_actual_cost_usd"])
review = float(by["review"]["total_actual_cost_usd"])
if not (coding > review > 0):
    raise SystemExit(f"coding/review costs not separated: {coding} vs {review}")
share = sum(float(r.get("cost_share_pct") or 0) for r in rows)
if abs(share - 100.0) > 0.01:
    raise SystemExit(f"shares sum to {share}, expected ~100")
run_sum = sum(int(r.get("run_count") or 0) for r in rows)
if run_sum != 4:
    raise SystemExit(f"run_count sum {run_sum} != 4")
PY
then
  pass "site-data derives mart_spend_by_work_type with separated review vs coding spend"
else
  fail "site-data derives mart_spend_by_work_type with separated review vs coding spend"
fi

# ---- Financials HTML renders the section ----
data_mixed="$tmpdir/data-mixed"
out_mixed="$tmpdir/out-mixed"
mkdir -p "$data_mixed/marts"
cp "$fixture_out/marts"/*.json "$data_mixed/marts/"
cp "$SAMPLE"/*.json "$data_mixed/marts/"
cp "$fixture_out/marts/mart_spend_by_work_type.json" "$data_mixed/marts/"
cp "$fixture_src/fct_agent_runs.json" "$data_mixed/marts/fct_agent_runs.json"

if "$PYTHON" scripts/factory-site.py \
  --repo-root "$ROOT" \
  --data "$data_mixed" \
  --out "$out_mixed" \
  --now "$PINNED_NOW" >/dev/null \
  && "$PYTHON" - "$out_mixed/financials.html" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
if "Spend by Work Type (Coding vs. Review)" not in html:
    raise SystemExit("section heading missing")
if 'id="spend-by-work-type-table"' not in html:
    raise SystemExit("table id missing")
for wt in ("coding", "review", "spec", "fix"):
    if wt not in html:
        raise SystemExit(f"missing row for {wt}")
if "$0.4000" not in html or "$0.1500" not in html:
    raise SystemExit("expected cost cells missing")
PY
then
  pass "Financials tab renders spend-by-work-type table for mixed fixture"
else
  fail "Financials tab renders spend-by-work-type table for mixed fixture"
fi

# ---- empty runs: export + render without errors ----
empty_src="$tmpdir/empty-source"
empty_out="$tmpdir/empty-export"
empty_data="$tmpdir/empty-data"
empty_site="$tmpdir/empty-site"
mkdir -p "$empty_src" "$empty_out/marts" "$empty_data/marts"
cp "$SAMPLE"/*.json "$empty_src/"
echo '[]' >"$empty_src/fct_agent_runs.json"

if "$PYTHON" scripts/factory-site-data.py \
  --source "$empty_src" \
  --out "$empty_out/marts" >/dev/null \
  && "$PYTHON" - "$empty_out/marts/mart_spend_by_work_type.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
rows = data["rows"] if isinstance(data, dict) else data
if rows:
    raise SystemExit("expected empty mart rows")
PY
then
  pass "empty agent_runs yields empty mart_spend_by_work_type export"
else
  fail "empty agent_runs yields empty mart_spend_by_work_type export"
fi

for f in "$SAMPLE"/*.json; do
  base=$(basename "$f")
  if [ "$base" = "fct_agent_runs.json" ]; then
    cp "$empty_src/fct_agent_runs.json" "$empty_data/marts/"
  else
    cp "$f" "$empty_data/marts/"
  fi
done
cp "$empty_out/marts/mart_spend_by_work_type.json" "$empty_data/marts/"
if "$PYTHON" scripts/factory-site.py \
  --repo-root "$ROOT" \
  --data "$empty_data" \
  --out "$empty_site" \
  --now "$PINNED_NOW" >/dev/null \
  && grep -q "No spend-by-work-type data available" "$empty_site/financials.html"
then
  pass "empty runs show spend-by-work-type empty-state note"
else
  fail "empty runs show spend-by-work-type empty-state note"
fi

# ---- factory-site-smoke build ----
if "$PYTHON" scripts/factory-site-smoke.py --build >/dev/null 2>&1; then
  pass "factory-site-smoke.py --build succeeds"
else
  fail "factory-site-smoke.py --build succeeds"
fi

echo "Results: ${passed} passed, ${failed} failed"
[ "$failed" -eq 0 ]