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

# ---- real factory/runs (empty on main) ----
if "${PY[@]}" --runs-dir factory/runs --models-file "$MODELS" >/dev/null; then
  pass "real factory/runs exits 0"
else
  fail "real factory/runs exits 0"
fi

echo "test-factory-cost-digest.sh: $passed passed, $failed failed"
exit "$([ "$failed" -eq 0 ] && echo 0 || echo 1)"