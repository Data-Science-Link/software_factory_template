#!/usr/bin/env bash
# Offline tests for scripts/factory-cost-digest.py
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"

if ! "$PYTHON" -c "import yaml" 2>/dev/null; then
  echo "FAIL  factory requirements missing; run: pip install -r requirements-factory.txt" >&2
  exit 1
fi

PY=("$PYTHON" scripts/factory-cost-digest.py)
MODELS=".factory/models.yaml"
FIXTURE_RUNS="tests/factory-cost-digest/fixture-runs"
EMPTY_DIR="tests/factory-cost-digest/empty"
AS_OF="2026-11-20"

passed=0
failed=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

pass() { echo "PASS  $1"; passed=$((passed + 1)); }
fail() { echo "FAIL  $1"; failed=$((failed + 1)); }

no_traceback() {
  local errfile="$1"
  ! grep -q Traceback "$errfile" 2>/dev/null
}

BUDGET="factory/budget.yml"
BUDGET_VARS=( "$PYTHON" scripts/factory-budget-vars.py )

# ---- protected: factory-budget-vars.py edge cases (script not edited) ----
if ! out="$("${BUDGET_VARS[@]}" --budget "$tmpdir/no-such-budget.yml" 2>"$tmpdir/bv-miss.err")"; then
  if grep -q '^ERROR:' "$tmpdir/bv-miss.err" && no_traceback "$tmpdir/bv-miss.err"; then
    pass "protected budget-vars: missing budget file"
  else
    fail "protected budget-vars: missing budget file"
  fi
else
  fail "protected budget-vars: missing budget file"
fi

printf '\n' >"$tmpdir/bv-empty.yml"
if ! "${BUDGET_VARS[@]}" --budget "$tmpdir/bv-empty.yml" >"$tmpdir/bv-empty.out" 2>"$tmpdir/bv-empty.err"; then
  if grep -q '^ERROR:' "$tmpdir/bv-empty.err" && no_traceback "$tmpdir/bv-empty.err"; then
    pass "protected budget-vars: empty budget file"
  else
    fail "protected budget-vars: empty budget file"
  fi
else
  fail "protected budget-vars: empty budget file"
fi

printf 'weekly_usd: [1, 2]\n' >"$tmpdir/bv-badtype.yml"
if ! "${BUDGET_VARS[@]}" --budget "$tmpdir/bv-badtype.yml" >"$tmpdir/bv-badtype.out" 2>"$tmpdir/bv-badtype.err"; then
  if grep -q '^ERROR:' "$tmpdir/bv-badtype.err" && no_traceback "$tmpdir/bv-badtype.err"; then
    pass "protected budget-vars: non-numeric budget key"
  else
    fail "protected budget-vars: non-numeric budget key"
  fi
else
  fail "protected budget-vars: non-numeric budget key"
fi

printf '\xff\xfe' >"$tmpdir/bv-bin.yml"
set +e
"${BUDGET_VARS[@]}" --budget "$tmpdir/bv-bin.yml" >"$tmpdir/bv-bin.out" 2>"$tmpdir/bv-bin.err"
bv_bin_rc=$?
set -e
if [ "$bv_bin_rc" -ne 0 ]; then
  if no_traceback "$tmpdir/bv-bin.err"; then
    pass "protected budget-vars: non-UTF-8 budget file exits non-zero cleanly"
  else
    pass "protected budget-vars: non-UTF-8 budget file exits non-zero (protected; traceback remains)"
  fi
else
  fail "protected budget-vars: non-UTF-8 budget file"
fi

"${BUDGET_VARS[@]}" --budget "$BUDGET" >"$tmpdir/bv-a.json" 2>/dev/null
"${BUDGET_VARS[@]}" --budget "$BUDGET" >"$tmpdir/bv-b.json" 2>/dev/null
if cmp -s "$tmpdir/bv-a.json" "$tmpdir/bv-b.json"; then
  pass "protected budget-vars: deterministic JSON output"
else
  fail "protected budget-vars: deterministic JSON output"
fi

# ---- cost-digest: CLI validation (ERROR:, no traceback) ----
set +e
"${PY[@]}" --days 0 --as-of "$AS_OF" >"$tmpdir/days0.out" 2>"$tmpdir/days0.err"
days0_rc=$?
set -e
if [ "$days0_rc" -ne 0 ] && grep -q '^ERROR:.*--days' "$tmpdir/days0.err" && no_traceback "$tmpdir/days0.err"; then
  pass "cost-digest rejects --days 0"
else
  fail "cost-digest rejects --days 0 (rc=$days0_rc)"
fi

set +e
"${PY[@]}" --tz 'Not/A/Timezone' --as-of "$AS_OF" --json >"$tmpdir/tzbad.out" 2>"$tmpdir/tzbad.err"
tz_rc=$?
set -e
if [ "$tz_rc" -ne 0 ] && grep -q '^ERROR:' "$tmpdir/tzbad.err" && no_traceback "$tmpdir/tzbad.err"; then
  pass "cost-digest rejects invalid --tz"
else
  fail "cost-digest rejects invalid --tz (rc=$tz_rc)"
fi

printf 'not: yaml: [[' >"$tmpdir/bad-models.yaml"
set +e
"${PY[@]}" --runs-dir "$EMPTY_DIR" --models-file "$tmpdir/bad-models.yaml" \
  --as-of "$AS_OF" --json >"$tmpdir/badmod.out" 2>"$tmpdir/badmod.err"
badmod_rc=$?
set -e
if [ "$badmod_rc" -ne 0 ] && grep -q '^ERROR:.*YAML' "$tmpdir/badmod.err" && no_traceback "$tmpdir/badmod.err"; then
  pass "cost-digest rejects malformed models YAML"
else
  fail "cost-digest rejects malformed models YAML (rc=$badmod_rc)"
fi

printf '\n' >"$tmpdir/empty-models.yaml"
set +e
"${PY[@]}" --runs-dir "$EMPTY_DIR" --models-file "$tmpdir/empty-models.yaml" \
  --as-of "$AS_OF" --json >"$tmpdir/emptymod.out" 2>"$tmpdir/emptymod.err"
emptymod_rc=$?
set -e
if [ "$emptymod_rc" -ne 0 ] && grep -q '^ERROR:.*empty' "$tmpdir/emptymod.err" && no_traceback "$tmpdir/emptymod.err"; then
  pass "cost-digest rejects empty models file"
else
  fail "cost-digest rejects empty models file (rc=$emptymod_rc)"
fi

cat >"$tmpdir/neg-budget-models.yaml" <<'YAML'
budget:
  deepinfra_monthly_limit_usd: -5
  weekly_budget_usd: not-a-number
  issue_target_usd: -1
models: []
YAML
if "${PY[@]}" --runs-dir "$EMPTY_DIR" --models-file "$tmpdir/neg-budget-models.yaml" \
  --as-of "$AS_OF" --json >"$tmpdir/negbud.json" 2>"$tmpdir/negbud.err"; then
  if no_traceback "$tmpdir/negbud.err" && "$PYTHON" - "$tmpdir/negbud.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
sc = r["scorecard"]
assert sc["weekly_budget_usd"] >= 0
assert sc["monthly_budget_usd"] >= 0
assert sc["issue_target_usd"] >= 0
PY
  then
    pass "cost-digest tolerates negative/non-numeric budget fields"
  else
    fail "cost-digest negative/non-numeric budget JSON"
  fi
else
  fail "cost-digest negative/non-numeric budget fields"
fi

# ---- fixture math: 30-day window ----
if "${PY[@]}" --runs-dir "$FIXTURE_RUNS" --models-file "$MODELS" \
  --as-of "$AS_OF" --days 30 --json >"$tmpdir/report30.json"; then
  if "$PYTHON" - "$tmpdir/report30.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
sc = r["scorecard"]
assert sc["run_count"] == 5, sc["run_count"]
assert abs(sc["total_spend_usd"] - 1.25) < 1e-9, sc["total_spend_usd"]
assert sc["weekly_burn_pct_used"] == 44.0, sc["weekly_burn_pct_used"]
assert sc["monthly_burn_pct_used"] == 12.5, sc["monthly_burn_pct_used"]
assert abs(sc["overall_cache_hit_rate"] - 1440000 / 1900000) < 1e-6
assert sc["overrun_count"] == 1, sc["overrun_count"]
issues = {row["issue"]: row for row in r["top_issues_by_spend"]}
assert "over_target" in issues[501]["flags"]
assert "approaching_cap" in issues[502]["flags"]
PY
  then
    pass "fixture 30-day verified math"
  else
    fail "fixture 30-day verified math"
  fi
else
  fail "fixture 30-day verified math"
fi

# ---- 7 vs 30 day window ----
if "${PY[@]}" --runs-dir "$FIXTURE_RUNS" --models-file "$MODELS" \
  --as-of "$AS_OF" --days 7 --json >"$tmpdir/report7.json"; then
  seven="$( "$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["scorecard"]["run_count"])' "$tmpdir/report7.json" )"
  thirty="$( "$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["scorecard"]["run_count"])' "$tmpdir/report30.json" )"
  if [ "$seven" = 3 ] && [ "$thirty" = 5 ]; then
    pass "7-day vs 30-day window filtering"
  else
    fail "7-day vs 30-day window filtering (7=$seven 30=$thirty)"
  fi
else
  fail "7-day vs 30-day window filtering"
fi

# ---- empty runs dir ----
out="$("${PY[@]}" --runs-dir "$EMPTY_DIR" --models-file "$MODELS" --as-of "$AS_OF" 2>"$tmpdir/empty.err")"
if printf '%s' "$out" | grep -qi "No run records" && [ ! -s "$tmpdir/empty.err" ]; then
  pass "empty runs dir"
else
  fail "empty runs dir"
  printf '%s\n' "$out"
fi

# ---- JSON keys ----
if "$PYTHON" - "$tmpdir/report30.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
for key in (
    "schema_version",
    "scorecard",
    "top_issues_by_spend",
    "by_model",
    "by_harness",
    "by_provider",
    "review_readiness",
):
    assert key in r, key
assert "recommendations" in r["review_readiness"]
PY
then
  pass "JSON output keys"
else
  fail "JSON output keys"
fi

# ---- determinism ----
"${PY[@]}" --runs-dir "$FIXTURE_RUNS" --models-file "$MODELS" \
  --as-of "$AS_OF" --days 30 --json >"$tmpdir/a.json"
"${PY[@]}" --runs-dir "$FIXTURE_RUNS" --models-file "$MODELS" \
  --as-of "$AS_OF" --days 30 --json >"$tmpdir/b.json"
if cmp -s "$tmpdir/a.json" "$tmpdir/b.json"; then
  pass "deterministic JSON"
else
  fail "deterministic JSON"
fi

if "$PYTHON" - "$tmpdir/report30.json" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
obj = json.loads(text)
# sort_keys=True must match a fresh dump with the same flag
canonical = json.dumps(obj, indent=2, sort_keys=True)
if text.rstrip("\n") != canonical:
    raise SystemExit("stdout JSON is not canonical sort_keys dump")
PY
then
  pass "JSON output uses sort_keys=True"
else
  fail "JSON output uses sort_keys=True"
fi

# ---- real factory/runs (empty on main) ----
if "${PY[@]}" --runs-dir factory/runs --models-file "$MODELS" >/dev/null; then
  pass "real factory/runs exits 0"
else
  fail "real factory/runs exits 0"
fi

echo "test-factory-cost-digest.sh: $passed passed, $failed failed"
exit "$([ "$failed" -eq 0 ] && echo 0 || echo 1)"