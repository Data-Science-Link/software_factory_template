#!/usr/bin/env bash
# Offline tests for scripts/factory-spec-lint.py
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "PyYAML is required. Install: pip install -r requirements-factory.txt" >&2
  exit 2
fi

fixtures="tests/spec-lint"
passed=0
failed=0

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_rc() {
  local label="$1" expect="$2"
  shift 2
  set +e
  local out
  out="$("$@" 2>&1)"
  local rc=$?
  set -e
  if [ "$expect" = "$rc" ]; then
    echo "PASS  $label"
    passed=$((passed + 1))
  else
    echo "FAIL  $label (expected exit $expect, got $rc)"
    echo "$out" | head -8
    failed=$((failed + 1))
  fi
}

assert_rc "valid spec" 0 python3 scripts/factory-spec-lint.py "$fixtures/pass-valid.md"

assert_rc "missing Bad inputs section" 1 \
  python3 scripts/factory-spec-lint.py "$fixtures/fail-missing-bad-inputs.md"

assert_rc "masked pipe in Verification" 1 \
  python3 scripts/factory-spec-lint.py "$fixtures/fail-masked-pipe.md"

assert_rc "template: forbidden workflow path" 1 \
  python3 scripts/factory-spec-lint.py --mode template "$fixtures/fail-template-workflow.md"

assert_rc "template: protected script path" 1 \
  python3 scripts/factory-spec-lint.py --mode template "$fixtures/fail-template-protected.md"

assert_rc "product: scripts/foo.sh path" 1 \
  python3 scripts/factory-spec-lint.py --mode product "$fixtures/fail-product-scripts.md"

assert_rc "bad front matter enum" 1 \
  python3 scripts/factory-spec-lint.py "$fixtures/fail-bad-enum.md"

assert_rc "unquoted colon in title" 1 \
  python3 scripts/factory-spec-lint.py "$fixtures/fail-unquoted-colon-title.md"

json_out="$tmpdir/json-out.json"
if python3 scripts/factory-spec-lint.py --json "$fixtures/pass-valid.md" >"$json_out"; then
  if python3 - "$json_out" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert "results" in data and "summary" in data
r = data["results"][0]
for key in ("path", "ok", "errors", "warnings"):
    assert key in r, key
assert r["ok"] is True
assert data["summary"]["files"] == 1
PY
  then
    echo "PASS  --json schema"
    passed=$((passed + 1))
  else
    echo "FAIL  --json schema"
    cat "$json_out"
    failed=$((failed + 1))
  fi
else
  echo "FAIL  --json exit code"
  failed=$((failed + 1))
fi
rm -f "$json_out"

echo "Results: ${passed} passed, ${failed} failed"
[ "$failed" -eq 0 ]