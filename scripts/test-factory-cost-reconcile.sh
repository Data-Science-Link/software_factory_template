#!/usr/bin/env bash
# Offline tests for scripts/factory-cost-reconcile.py
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
PY=("$PYTHON" scripts/factory-cost-reconcile.py)
MODELS_FIXTURE="tests/cost-reconcile/models-fixture.yaml"
FIXTURE_ROOT="tests/cost-reconcile"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

passed=0
failed=0

note() {
  echo "PASS  $1"
  passed=$((passed + 1))
}

fail() {
  echo "FAIL  $1"
  failed=$((failed + 1))
}

one_run_dir() {
  local name="$1"
  local src="$2"
  local dest="$tmpdir/$name"
  mkdir -p "$dest"
  cp "$src" "$dest/"
  printf '%s' "$dest"
}

run_expect_status() {
  local label="$1"
  local want_rc="$2"
  local want_status="$3"
  local runs_dir="$4"
  set +e
  out="$("${PY[@]}" --runs-dir "$runs_dir" --models-yaml "$MODELS_FIXTURE" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne "$want_rc" ]; then
    fail "$label (expected exit $want_rc, got $rc)"
    printf '%s\n' "$out" | sed 's/^/       /'
    return
  fi
  if ! printf '%s\n' "$out" | grep -q "$want_status"; then
    fail "$label (expected status $want_status in output)"
    printf '%s\n' "$out" | sed 's/^/       /'
    return
  fi
  note "$label"
}

# --- classification fixtures (one run per dir) ---
MATCH_DIR="$(one_run_dir match-only "$FIXTURE_ROOT/run-match.json")"
run_expect_status "match within tolerance" 0 "MATCH" "$MATCH_DIR"
set +e
out="$("${PY[@]}" --runs-dir "$MATCH_DIR" --models-yaml "$MODELS_FIXTURE" --strict 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "match --strict (expected exit 0, got $rc)"
else
  note "match --strict exit 0"
fi

DRIFT_DIR="$(one_run_dir drift-only "$FIXTURE_ROOT/run-drift.json")"
run_expect_status "drift beyond tolerance" 0 "DRIFT" "$DRIFT_DIR"
if out="$("${PY[@]}" --runs-dir "$DRIFT_DIR" --models-yaml "$MODELS_FIXTURE" 2>&1)"; then
  if printf '%s\n' "$out" | grep -qE '\+[0-9.]+'; then
    note "drift reports delta"
  else
    fail "drift reports delta (no delta in output)"
  fi
else
  fail "drift default mode (unexpected failure)"
fi
set +e
out="$("${PY[@]}" --runs-dir "$DRIFT_DIR" --models-yaml "$MODELS_FIXTURE" --strict 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "drift --strict (expected exit 1, got $rc)"
else
  note "drift --strict non-zero exit"
fi

UNPRICED_DIR="$(one_run_dir unpriced-only "$FIXTURE_ROOT/run-unpriced.json")"
run_expect_status "unknown model" 0 "UNPRICED_MODEL" "$UNPRICED_DIR"

NO_TOKENS_DIR="$(one_run_dir no-tokens-only "$FIXTURE_ROOT/run-no-tokens.json")"
run_expect_status "missing token usage" 0 "NO_TOKEN_USAGE" "$NO_TOKENS_DIR"

# --- all fixtures together ---
ALL_DIR="$tmpdir/all-fixtures"
mkdir -p "$ALL_DIR"
cp "$FIXTURE_ROOT"/run-*.json "$ALL_DIR/"
set +e
out="$("${PY[@]}" --runs-dir "$ALL_DIR" --models-yaml "$MODELS_FIXTURE" --json 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "fixture suite --json (exit $rc)"
  printf '%s\n' "$out" | sed 's/^/       /'
else
  if "$PYTHON" -c "import json,sys; d=json.loads(sys.stdin.read()); assert d['summary']['total_runs']==4" <<<"$out"; then
    note "--json output parses"
  else
    fail "--json output parses"
    printf '%s\n' "$out" | head -20 | sed 's/^/       /'
  fi
fi

# --- real factory/runs (README only today) ---
set +e
out="$("${PY[@]}" --runs-dir factory/runs 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "real factory/runs default mode (exit $rc)"
  printf '%s\n' "$out" | sed 's/^/       /'
else
  note "real factory/runs exit 0"
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi