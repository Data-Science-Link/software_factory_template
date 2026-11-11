#!/usr/bin/env bash
# Test scripts/factory-collect-runs.py offline against the fixture.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"

if ! "$PYTHON" -c "import jsonschema" 2>/dev/null; then
  echo "ERROR: jsonschema is not installed (required for run-record validation)." >&2
  echo "Install factory requirements in a virtualenv, for example:" >&2
  echo "  python3 -m venv .venv" >&2
  echo "  source .venv/bin/activate" >&2
  echo "  pip install -r requirements-factory.txt" >&2
  echo "  bash scripts/test-factory-collect-runs.sh" >&2
  echo "Or set FACTORY_PYTHON to the venv interpreter." >&2
  exit 1
fi

passed=0
failed=0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() {
  echo "PASS  $1"
  passed=$((passed + 1))
}

fail() {
  echo "FAIL  $1"
  failed=$((failed + 1))
}

out_dir="$tmp/runs"
"$PYTHON" scripts/factory-collect-runs.py \
  --from-json tests/collect-runs/comments.json \
  --out "$out_dir" >"$tmp/summary1.txt"

if [ -f "$out_dir/gha-90000000001-1.json" ]; then
  pass "collector: valid bot record written"
else
  fail "collector: valid bot record written"
fi

if [ ! -f "$out_dir/gha-99999999999-1.json" ]; then
  pass "collector: human-posted record ignored"
else
  fail "collector: human-posted record ignored"
fi

if [ ! -f "$out_dir/gha-88888888888-1.json" ]; then
  pass "collector: no-marker comment ignored"
else
  fail "collector: no-marker comment ignored"
fi

if [ ! -f "$out_dir/gha-77777777777-1.json" ]; then
  pass "collector: invalid JSON block skipped"
else
  fail "collector: invalid JSON block skipped"
fi

if grep -Fq "Most recently updated duplicate: this note should win the dedupe." \
  "$out_dir/gha-90000000001-1.json"; then
  pass "collector: duplicate run_id deduped to newest comment"
else
  fail "collector: duplicate run_id deduped to newest comment"
fi

if "$PYTHON" factory/dbt/runs_to_seeds.py \
  --runs "$out_dir/*.json" \
  --out "$tmp/seeds" >"$tmp/seeds1.txt" 2>&1 \
  && [ -f "$tmp/seeds/agent_runs.csv" ]; then
  pass "collector: runs_to_seeds builds agent_runs.csv from output"
else
  fail "collector: runs_to_seeds builds agent_runs.csv from output"
fi

out_dir2="$tmp/runs2"
"$PYTHON" scripts/factory-collect-runs.py \
  --from-json tests/collect-runs/comments.json \
  --out "$out_dir2" >"$tmp/summary2.txt"
if diff -r "$out_dir" "$out_dir2" >/dev/null; then
  pass "collector: second run byte-identical"
else
  fail "collector: second run byte-identical"
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
