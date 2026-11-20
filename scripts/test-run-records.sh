#!/usr/bin/env bash
# Validate run-record fixtures: pass-* must validate; fail-* must fail for a stated reason.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"

if ! "$PYTHON" -c "import jsonschema" 2>/dev/null; then
  echo "ERROR: jsonschema is not installed (required for run-record validation)." >&2
  echo "Install factory requirements in a virtualenv, for example:" >&2
  echo "  python3 -m venv .venv" >&2
  echo "  source .venv/bin/activate    # Windows: .venv\\Scripts\\activate" >&2
  echo "  pip install -r requirements-factory.txt" >&2
  echo "  bash scripts/test-run-records.sh" >&2
  echo "Or set FACTORY_PYTHON to the venv interpreter." >&2
  exit 1
fi

passed=0
failed=0

run_expect_ok() {
  local path=$1
  if "$PYTHON" scripts/factory-validate-run.py "$path" >/dev/null; then
    echo "PASS  $path (valid)"
    passed=$((passed + 1))
  else
    echo "FAIL  $path (expected valid)"
    failed=$((failed + 1))
  fi
}

run_expect_fail() {
  local path=$1
  local expected_substr=$2
  set +e
  out="$("$PYTHON" scripts/factory-validate-run.py "$path" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL  $path (expected rejection containing: $expected_substr)"
    failed=$((failed + 1))
    return
  fi
  error_count="$(printf '%s\n' "$out" | grep -c '^  - ' || true)"
  if [ "$error_count" -ne 1 ]; then
    echo "FAIL  $path (expected exactly one validation error, got $error_count)"
    printf '%s\n' "$out" | sed 's/^/       /'
    failed=$((failed + 1))
    return
  fi
  if printf '%s\n' "$out" | grep -Fq "$expected_substr"; then
    matched="$(printf '%s\n' "$out" | grep -F "$expected_substr" | head -1)"
    echo "PASS  $path (rejected: $expected_substr)"
    echo "       $matched"
    passed=$((passed + 1))
  else
    echo "FAIL  $path (exit $rc but missing expected message: $expected_substr)"
    printf '%s\n' "$out" | sed 's/^/       /'
    failed=$((failed + 1))
  fi
}

for f in tests/run-records/pass-*.json tests/run-records/pass-*.md; do
  [ -f "$f" ] || continue
  run_expect_ok "$f"
done

run_expect_fail tests/run-records/fail-cached-gt-in.json "tokens_cached must be <= tokens_in"
run_expect_fail tests/run-records/fail-local-timestamp.json "started_at must be UTC ISO 8601 ending in Z"
run_expect_fail tests/run-records/fail-cost-mismatch.json "actual_cost_usd must match tokens × record prices"
run_expect_fail tests/run-records/fail-unknown-field.json "Additional properties are not allowed"
run_expect_fail tests/run-records/fail-step-cost-mismatch.json "step prices within"

run_expect_fail_contains() {
  local path=$1
  local expected_substr=$2
  set +e
  out="$("$PYTHON" scripts/factory-validate-run.py "$path" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL  $path (expected rejection containing: $expected_substr)"
    failed=$((failed + 1))
    return
  fi
  if printf '%s\n' "$out" | grep -Fq "$expected_substr"; then
    echo "PASS  $path (rejected: $expected_substr)"
    passed=$((passed + 1))
  else
    echo "FAIL  $path (exit $rc but missing expected message: $expected_substr)"
    printf '%s\n' "$out" | sed 's/^/       /'
    failed=$((failed + 1))
  fi
}

tmpdir_schema="$(mktemp -d)"
trap 'rm -rf "$tmpdir_schema"' EXIT

"$PYTHON" - "$tmpdir_schema" <<'PY'
import json
import sys
from pathlib import Path

out_dir = Path(sys.argv[1])
base = json.loads(Path("tests/run-records/pass-pr-opened.json").read_text(encoding="utf-8"))

bad_wt = dict(base)
bad_wt["work_type"] = "coding"
(out_dir / "bad-work-type.json").write_text(
    json.dumps(bad_wt, indent=2) + "\n", encoding="utf-8"
)

neg = dict(base)
neg["tokens_in"] = -1
(out_dir / "negative-tokens.json").write_text(
    json.dumps(neg, indent=2) + "\n", encoding="utf-8"
)

(out_dir / "malformed.json").write_text('{"schema_version": 1,', encoding="utf-8")
PY

for sample in examples/sample-runs/*.json; do
  [ -f "$sample" ] || continue
  run_expect_ok "$sample"
done

run_expect_fail "$tmpdir_schema/bad-work-type.json" "'coding' is not one of"
run_expect_fail_contains "$tmpdir_schema/negative-tokens.json" "tokens_in: -1 is less than the minimum of 0"

set +e
mal_out="$("$PYTHON" scripts/factory-validate-run.py "$tmpdir_schema/malformed.json" 2>&1)"
mal_rc=$?
set -e
if [ "$mal_rc" -ne 0 ] \
  && printf '%s\n' "$mal_out" | grep -q '^ERROR ' \
  && ! printf '%s\n' "$mal_out" | grep -q '^Traceback'; then
  echo "PASS  $tmpdir_schema/malformed.json (malformed JSON: clean ERROR, no traceback)"
  passed=$((passed + 1))
else
  echo "FAIL  $tmpdir_schema/malformed.json (expected clean ERROR without traceback)"
  printf '%s\n' "$mal_out" | sed 's/^/       /'
  failed=$((failed + 1))
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
