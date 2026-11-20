#!/usr/bin/env bash
# Test scripts/factory-routing-report.py offline fixtures.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"

if ! "$PYTHON" -c "import yaml, jsonschema" 2>/dev/null; then
  echo "FAIL  factory requirements missing; run: pip install -r requirements-factory.txt" >&2
  exit 1
fi

PY=("$PYTHON" scripts/factory-routing-report.py)
MODELS=".factory/models.yaml"
passed=0
failed=0

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

pass() { echo "PASS  $1"; passed=$((passed + 1)); }
fail() { echo "FAIL  $1"; failed=$((failed + 1)); }

# Build fixture dirs from the committed pass-pr-opened record.
gen_run() {
  local out="$1" run_id="$2" issue="$3" started="$4" gate="$5" outcome="$6" notes="$7"
  "$PYTHON" - "$out" "$run_id" "$issue" "$started" "$gate" "$outcome" "$notes" <<'PY'
import json, pathlib, sys
out, run_id, issue, started, gate, outcome, notes = sys.argv[1:8]
base = json.loads(pathlib.Path("tests/run-records/pass-pr-opened.json").read_text())
base["run_id"] = run_id
base["issue"] = int(issue)
base["issues"] = [int(issue)]
from datetime import datetime, timedelta, timezone
st = datetime.strptime(started, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
en = st + timedelta(minutes=10)
base["started_at"] = started
base["ended_at"] = en.strftime("%Y-%m-%dT%H:%M:%SZ")
base["gate_passed"] = gate.lower() == "true"
base["outcome"] = outcome
base["notes"] = notes
pathlib.Path(out).write_text(json.dumps(base, indent=2) + "\n")
PY
}

small_dir="$tmpdir/small-sample"
mkdir -p "$small_dir"
gen_run "$small_dir/gha-92000000001-1.json" "gha-92000000001-1" 201 \
  "2026-11-10T14:00:00Z" true pr_opened "small sample run 1"
gen_run "$small_dir/gha-92000000002-1.json" "gha-92000000002-1" 202 \
  "2026-11-10T15:00:00Z" true pr_opened "small sample run 2"

high_dir="$tmpdir/high-fix-rate"
mkdir -p "$high_dir"
# Two issues, three runs each -> fix_round_rate 4/6 for one model/build/simple/normal slice.
gen_run "$high_dir/gha-93000000001-1.json" "gha-93000000001-1" 301 \
  "2026-11-11T10:00:00Z" true pr_opened "build attempt 1"
gen_run "$high_dir/gha-93000000002-1.json" "gha-93000000002-1" 301 \
  "2026-11-11T11:00:00Z" false failed "build retry"
gen_run "$high_dir/gha-93000000003-1.json" "gha-93000000003-1" 301 \
  "2026-11-11T12:00:00Z" true pr_opened "build retry 2"
gen_run "$high_dir/gha-93000000004-1.json" "gha-93000000004-1" 302 \
  "2026-11-11T10:00:00Z" true pr_opened "other issue build"
gen_run "$high_dir/gha-93000000005-1.json" "gha-93000000005-1" 302 \
  "2026-11-11T11:00:00Z" false failed "other issue retry"
gen_run "$high_dir/gha-93000000006-1.json" "gha-93000000006-1" 302 \
  "2026-11-11T12:00:00Z" true pr_updated "fix round"

# ---- empty runs dir ----
out="$("${PY[@]}" --runs-dir tests/routing-report/empty --models "$MODELS" --markdown 2>"$tmpdir/empty.err")"
if printf '%s' "$out" | grep -q "Runs loaded: **0**" && [ ! -s "$tmpdir/empty.err" ]; then
  pass "empty runs dir"
else
  fail "empty runs dir"
  printf '%s\n' "$out"
fi

# ---- small sample warning ----
out="$("${PY[@]}" --runs-dir "$small_dir" --models "$MODELS" --markdown)"
if printf '%s' "$out" | grep -q "insufficient sample size"; then
  pass "small sample warning"
else
  fail "small sample warning"
fi

# ---- high fix-round rate flagged ----
out="$("${PY[@]}" --runs-dir "$high_dir" --models "$MODELS" --markdown)"
if printf '%s' "$out" | grep -q "high fix-round rate"; then
  pass "high fix-round rate flagged"
else
  fail "high fix-round rate flagged"
fi

# ---- JSON output ----
if "${PY[@]}" --runs-dir "$high_dir" --models "$MODELS" --json \
  | "$PYTHON" -c 'import json,sys; json.load(sys.stdin)'; then
  pass "JSON output parses"
else
  fail "JSON output parses"
fi

# ---- markdown sections ----
out="$("${PY[@]}" --runs-dir "$high_dir" --models "$MODELS" --markdown)"
if printf '%s' "$out" | grep -q "^## Metrics by model" \
  && printf '%s' "$out" | grep -q "^## Recommendations"; then
  pass "markdown report sections"
else
  fail "markdown report sections"
fi

# ---- determinism: two JSON runs match ----
AS_OF="2026-11-20T00:00:00Z"
"${PY[@]}" --runs-dir "$high_dir" --models "$MODELS" --json --as-of "$AS_OF" >"$tmpdir/a.json"
"${PY[@]}" --runs-dir "$high_dir" --models "$MODELS" --json --as-of "$AS_OF" >"$tmpdir/b.json"
if cmp -s "$tmpdir/a.json" "$tmpdir/b.json"; then
  pass "deterministic JSON"
else
  fail "deterministic JSON"
fi

echo "test-factory-routing-report.sh: $passed passed, $failed failed"
exit "$([ "$failed" -eq 0 ] && echo 0 || echo 1)"