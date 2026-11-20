#!/usr/bin/env bash
# Test scripts/factory-budget-vars.py validation and scripts/factory-site-data.py
# export determinism. Uses committed fixtures under tests/site-data/sample-marts/
# instead of a live dbt build, which crashes in the /oc sandbox on Python 3.14.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"

if ! "$PYTHON" -c "import yaml" 2>/dev/null; then
  echo "FAIL  PyYAML not installed; run: pip install -r requirements-factory.txt"
  exit 1
fi

passed=0
failed=0

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

BUDGET="factory/budget.yml"

# ---- budget-vars: happy path ----
if "$PYTHON" scripts/factory-budget-vars.py --budget "$BUDGET" \
  | "$PYTHON" -c '
import json, sys
d = json.load(sys.stdin)
expected = {
    "deepinfra_monthly_budget_usd": 10,
    "weekly_budget_usd": 2.5,
    "issue_target_usd": 0.15,
    "issue_cap_usd": 1.0,
    "fixed_costs_monthly_usd": 20,
    "actions_minutes_month": 2000,
    "warn_pct": 80,
}
sys.exit(0 if d == expected else 1)
'; then
  echo "PASS  budget-vars reads factory/budget.yml and prints valid dbt vars"
  passed=$((passed + 1))
else
  echo "FAIL  budget-vars did not print the expected dbt vars"
  failed=$((failed + 1))
fi

# ---- budget-vars: reject negative budget ----
neg_budget="$tmpdir/negative.yml"
sed 's/^weekly_usd:.*/weekly_usd: -1/' "$BUDGET" >"$neg_budget"
set +e
neg_out="$("$PYTHON" scripts/factory-budget-vars.py --budget "$neg_budget" 2>&1)"
neg_rc=$?
set -e
if [ "$neg_rc" -ne 0 ] && printf '%s\n' "$neg_out" | grep -q "must be positive"; then
  echo "PASS  budget-vars rejects negative budget"
  passed=$((passed + 1))
else
  echo "FAIL  budget-vars did not reject a negative budget (rc=$neg_rc)"
  printf '%s\n' "$neg_out"
  failed=$((failed + 1))
fi

# ---- budget-vars: reject weekly above monthly ----
over_budget="$tmpdir/over.yml"
sed 's/^weekly_usd:.*/weekly_usd: 15/' "$BUDGET" >"$over_budget"
set +e
over_out="$("$PYTHON" scripts/factory-budget-vars.py --budget "$over_budget" 2>&1)"
over_rc=$?
set -e
if [ "$over_rc" -ne 0 ] && printf '%s\n' "$over_out" | grep -q "cannot exceed the monthly budget"; then
  echo "PASS  budget-vars rejects weekly above monthly"
  passed=$((passed + 1))
else
  echo "FAIL  budget-vars did not reject weekly above monthly (rc=$over_rc)"
  printf '%s\n' "$over_out"
  failed=$((failed + 1))
fi

# ---- site-data export: byte-identical across two runs ----
# The committed fixtures stand in for a dbt build; dbt is never run here.
out1="$tmpdir/export1"
out2="$tmpdir/export2"
if "$PYTHON" scripts/factory-site-data.py --source tests/site-data/sample-marts --out "$out1" >/dev/null \
  && "$PYTHON" scripts/factory-site-data.py --source tests/site-data/sample-marts --out "$out2" >/dev/null; then
  if diff -r "$out1" "$out2" >/dev/null; then
    echo "PASS  site-data export is byte-identical across two runs"
    passed=$((passed + 1))
  else
    echo "FAIL  site-data export differs across two runs"
    diff -r "$out1" "$out2" || true
    failed=$((failed + 1))
  fi
else
  echo "FAIL  site-data export failed to run"
  failed=$((failed + 1))
fi

# ---- backlog epic progress: sub_issues API-shaped fixture ----
epic_out="$tmpdir/epic-sub.json"
if "$PYTHON" scripts/factory-backlog.py \
  --from-json tests/site-data/epic-sub-issues.json \
  --out "$epic_out" >/dev/null \
  && "$PYTHON" - "$epic_out" <<'PY'
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8"))
epic = items[0]
if epic.get("done") != 2 or epic.get("total") != 3:
    raise SystemExit("sub_issues fixture: expected 2/3, got %s/%s" % (
        epic.get("done"), epic.get("total")))
PY
then
  echo "PASS  epic progress from sub_issues fixture is 2/3"
  passed=$((passed + 1))
else
  echo "FAIL  epic progress from sub_issues fixture"
  failed=$((failed + 1))
fi

# ---- backlog epic progress: body #N fallback ----
body_out="$tmpdir/epic-body.json"
if "$PYTHON" scripts/factory-backlog.py \
  --from-json tests/site-data/epic-body-refs.json \
  --out "$body_out" >/dev/null \
  && "$PYTHON" - "$body_out" <<'PY'
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8"))
epic = [i for i in items if i.get("number") == 900][0]
if epic.get("done") != 1 or epic.get("total") != 2:
    raise SystemExit("body refs: expected 1/2, got %s/%s" % (
        epic.get("done"), epic.get("total")))
PY
then
  echo "PASS  epic progress from body #N fallback is 1/2"
  passed=$((passed + 1))
else
  echo "FAIL  epic progress from body #N fallback"
  failed=$((failed + 1))
fi

# ---- backlog epic progress: subIssuesSummary.completed ----
summary_out="$tmpdir/epic-summary.json"
if "$PYTHON" scripts/factory-backlog.py \
  --from-json tests/site-data/epic-summary-completed.json \
  --out "$summary_out" >/dev/null \
  && "$PYTHON" - "$summary_out" <<'PY'
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8"))
epic = items[0]
if epic.get("done") != 3 or epic.get("total") != 7:
    raise SystemExit("completed field: expected 3/7, got %s/%s" % (
        epic.get("done"), epic.get("total")))
PY
then
  echo "PASS  epic progress maps subIssuesSummary.completed to done"
  passed=$((passed + 1))
else
  echo "FAIL  epic progress did not map subIssuesSummary.completed"
  failed=$((failed + 1))
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
