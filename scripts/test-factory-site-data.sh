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

PINNED_AS_OF="2026-11-20"
SAMPLE_RUNS="examples/sample-runs"

# ---- runs-dir: empty directory synthesizes marts without traceback ----
empty_runs="$tmpdir/empty-runs"
mkdir -p "$empty_runs"
empty_out="$tmpdir/empty-marts"
set +e
empty_err="$("$PYTHON" scripts/factory-site-data.py \
  --runs-dir "$empty_runs" \
  --out "$empty_out" \
  --as-of-date "$PINNED_AS_OF" 2>&1)"
empty_rc=$?
set -e
if [ "$empty_rc" -eq 0 ] \
  && ! printf '%s\n' "$empty_err" | grep -q Traceback \
  && [ -f "$empty_out/fct_agent_runs.json" ] \
  && "$PYTHON" - "$empty_out/fct_agent_runs.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8")).get("rows") or []
if rows:
    raise SystemExit("expected empty fct_agent_runs")
PY
then
  echo "PASS  site-data empty runs-dir synthesizes marts"
  passed=$((passed + 1))
else
  echo "FAIL  site-data empty runs-dir (rc=$empty_rc)"
  printf '%s\n' "$empty_err"
  failed=$((failed + 1))
fi

# ---- runs-dir: malformed JSON skipped cleanly (no traceback) ----
mixed_runs="$tmpdir/mixed-runs"
mkdir -p "$mixed_runs"
cp "$SAMPLE_RUNS/gha-100001-1.json" "$mixed_runs/"
printf '{not json' >"$mixed_runs/broken.json"
set +e
mixed_err="$("$PYTHON" scripts/factory-site-data.py \
  --runs-dir "$mixed_runs" \
  --out "$tmpdir/mixed-marts" \
  --as-of-date "$PINNED_AS_OF" 2>&1)"
mixed_rc=$?
set -e
if [ "$mixed_rc" -eq 0 ] \
  && ! printf '%s\n' "$mixed_err" | grep -q Traceback \
  && printf '%s\n' "$mixed_err" | grep -q 'skip broken.json'; then
  echo "PASS  site-data skips malformed run JSON with warning"
  passed=$((passed + 1))
else
  echo "FAIL  site-data malformed run JSON (rc=$mixed_rc)"
  printf '%s\n' "$mixed_err"
  failed=$((failed + 1))
fi

# ---- runs-dir: missing budget.yml uses defaults ----
no_budget_runs="$tmpdir/no-budget-runs"
mkdir -p "$no_budget_runs"
cp "$SAMPLE_RUNS"/*.json "$no_budget_runs/"
set +e
nb_err="$("$PYTHON" scripts/factory-site-data.py \
  --runs-dir "$no_budget_runs" \
  --budget "$tmpdir/does-not-exist.yml" \
  --out "$tmpdir/no-budget-marts" \
  --as-of-date "$PINNED_AS_OF" 2>&1)"
nb_rc=$?
set -e
if [ "$nb_rc" -eq 0 ] \
  && printf '%s\n' "$nb_err" | grep -q 'budget file not found' \
  && "$PYTHON" - "$tmpdir/no-budget-marts/agg_spend_weekly.json" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
rows = payload.get("rows") or []
if not rows:
    raise SystemExit("no weekly rows")
if rows[0].get("budget_usd") != 2.5:
    raise SystemExit(rows[0].get("budget_usd"))
PY
then
  echo "PASS  site-data missing budget.yml falls back to defaults"
  passed=$((passed + 1))
else
  echo "FAIL  site-data missing budget.yml (rc=$nb_rc)"
  printf '%s\n' "$nb_err"
  failed=$((failed + 1))
fi

# ---- runs-dir: non-numeric token/cost fields normalized ----
bad_tokens="$tmpdir/bad-tokens"
mkdir -p "$bad_tokens"
"$PYTHON" - "$bad_tokens/bad-fields.json" <<'PY'
import json, pathlib
path = pathlib.Path(__import__("sys").argv[1])
base = json.loads(pathlib.Path("examples/sample-runs/gha-100001-1.json").read_text())
base["run_id"] = "bad-tokens-1"
base["tokens_in"] = "nope"
base["actual_cost_usd"] = None
base["predicted_cost_usd"] = "0.01"
path.write_text(json.dumps(base) + "\n", encoding="utf-8")
PY
set +e
bt_err="$("$PYTHON" scripts/factory-site-data.py \
  --runs-dir "$bad_tokens" \
  --out "$tmpdir/bad-token-marts" \
  --as-of-date "$PINNED_AS_OF" 2>&1)"
bt_rc=$?
set -e
if [ "$bt_rc" -eq 0 ] \
  && ! printf '%s\n' "$bt_err" | grep -q Traceback \
  && "$PYTHON" - "$tmpdir/bad-token-marts/fct_agent_runs.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8")).get("rows") or []
row = rows[0]
if row.get("tokens_in") != 0:
    raise SystemExit(row.get("tokens_in"))
if row.get("actual_cost_usd") != 0.0:
    raise SystemExit(row.get("actual_cost_usd"))
PY
then
  echo "PASS  site-data normalizes non-numeric token/cost fields"
  passed=$((passed + 1))
else
  echo "FAIL  site-data non-numeric token/cost fields (rc=$bt_rc)"
  printf '%s\n' "$bt_err"
  failed=$((failed + 1))
fi

# ---- runs-dir: byte-identical across two pinned runs ----
rd_out1="$tmpdir/runs-marts-1"
rd_out2="$tmpdir/runs-marts-2"
if "$PYTHON" scripts/factory-site-data.py --runs-dir "$SAMPLE_RUNS" --out "$rd_out1" --as-of-date "$PINNED_AS_OF" >/dev/null \
  && "$PYTHON" scripts/factory-site-data.py --runs-dir "$SAMPLE_RUNS" --out "$rd_out2" --as-of-date "$PINNED_AS_OF" >/dev/null; then
  if diff -r "$rd_out1" "$rd_out2" >/dev/null; then
    echo "PASS  site-data --runs-dir export is byte-identical with pinned as-of"
    passed=$((passed + 1))
  else
    echo "FAIL  site-data --runs-dir export differs across two runs"
    diff -r "$rd_out1" "$rd_out2" || true
    failed=$((failed + 1))
  fi
else
  echo "FAIL  site-data --runs-dir synthesis failed"
  failed=$((failed + 1))
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
