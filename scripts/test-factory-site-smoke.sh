#!/usr/bin/env bash
# Offline tests for scripts/factory-site-smoke.py
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
SMOKE="scripts/factory-site-smoke.py"
FIXTURES="tests/site-smoke"

passed=0
failed=0

pass() {
  echo "PASS  $1"
  passed=$((passed + 1))
}

fail() {
  echo "FAIL  $1"
  failed=$((failed + 1))
}

require_check() {
  local dir="$1" check="$2"
  set +e
  out="$("$PYTHON" "$SMOKE" "$dir" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    fail "$check should fail for $dir"
    return 1
  fi
  if echo "$out" | grep -q "\[$check\]"; then
    pass "$check detected for broken fixture"
    return 0
  fi
  fail "$check not reported for $dir"
  printf '%s\n' "$out"
  return 1
}

if ! "$PYTHON" -c "import yaml" 2>/dev/null; then
  echo "FAIL  PyYAML not installed (required for --build)"
  exit 1
fi

# ---- 1. end-to-end --build on real fixture site ----
build_out="$("$PYTHON" "$SMOKE" --build 2>&1)" || {
  fail "end-to-end --build passes"
  printf '%s\n' "$build_out"
}
if echo "$build_out" | grep -q "^OK"; then
  pass "end-to-end --build passes"
else
  fail "end-to-end --build passes"
  printf '%s\n' "$build_out"
fi

# ---- 2. --json schema ----
json_out="$("$PYTHON" "$SMOKE" --build --json 2>/dev/null)" || {
  fail "--json output on successful --build"
  printf '%s\n' "$json_out"
}
if "$PYTHON" - "$json_out" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
for key in ("ok", "site_dir", "error_count", "checks_run", "errors"):
    if key not in data:
        raise SystemExit("missing key %s" % key)
if data["ok"] is not True:
    raise SystemExit("expected ok true")
if data["error_count"] != 0:
    raise SystemExit("expected zero errors")
if not isinstance(data["checks_run"], list) or not data["checks_run"]:
    raise SystemExit("checks_run must be non-empty list")
if not isinstance(data["errors"], list):
    raise SystemExit("errors must be a list")
for err in data["errors"]:
    if not all(k in err for k in ("check", "file", "message")):
        raise SystemExit("bad error object")
PY
then
  pass "--json output schema parses cleanly"
else
  fail "--json output schema parses cleanly"
fi

# ---- 3-7. broken HTML fixtures ----
require_check "$FIXTURES/leak-name" "personal_name_leak" || true
require_check "$FIXTURES/raw-bold" "markdown_bold_leak" || true
require_check "$FIXTURES/double-escape" "double_escaped_entity" || true
require_check "$FIXTURES/bad-svg" "svg_xml" || true
require_check "$FIXTURES/broken-href" "local_reference" || true

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi