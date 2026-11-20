#!/usr/bin/env bash
# Live-validated drift test for examples/ golden files (Refs #178, #182, #38).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
passed=0
failed=0

ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }

require_script() {
  local rel="$1"
  if [ ! -f "$rel" ]; then
    echo "FAIL  missing $rel (merge factory validator PRs before this test can run)"
    exit 1
  fi
}

require_script scripts/factory-spec-lint.py
require_script scripts/factory-decision-log.py
require_script scripts/factory-models-check.py
require_script scripts/factory-prepublic-check.py

if ! "$PYTHON" -c "import yaml" 2>/dev/null; then
  echo "FAIL  PyYAML required (pip install -r requirements-factory.txt)"
  exit 1
fi

set +e
out="$(
  "$PYTHON" scripts/factory-spec-lint.py --mode product --strict examples/sample-spec.md 2>&1
)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'warning:'; then
  ok "factory-spec-lint sample-spec.md (0 errors, 0 warnings)"
else
  bad "factory-spec-lint sample-spec.md (rc=$rc)"
  printf '%s\n' "$out" | head -12
fi

set +e
out="$(
  "$PYTHON" scripts/factory-decision-log.py --file examples/minimal-product-repo/.factory/DECISIONS.md check 2>&1
)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  ok "factory-decision-log DECISIONS.md"
else
  bad "factory-decision-log check (rc=$rc)"
  printf '%s\n' "$out" | head -12
fi

set +e
out="$(
  "$PYTHON" scripts/factory-models-check.py \
    --models-yaml examples/minimal-product-repo/.factory/models.yaml \
    --routing-md /dev/null 2>&1
)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  ok "factory-models-check models.yaml"
else
  bad "factory-models-check models.yaml (rc=$rc)"
  printf '%s\n' "$out" | head -12
fi

body="examples/sample-pr-body.md"
for needle in 'AI disclosure:' 'Cost:' 'Human review & approval'; do
  if grep -Fq "$needle" "$body"; then
    ok "sample-pr-body.md contains $needle"
  else
    bad "sample-pr-body.md missing $needle"
  fi
done

set +e
pr_out="$(
  PR_BRANCH=cursor/examples-showcase-c916 bash scripts/pr-check.sh "$body" 2>&1
)"
pr_rc=$?
set -e
if [ "$pr_rc" -eq 0 ]; then
  ok "pr-check.sh sample-pr-body.md"
else
  bad "pr-check.sh sample-pr-body.md (rc=$pr_rc)"
  printf '%s\n' "$pr_out" | head -8
fi

set +e
scan="$("$PYTHON" scripts/factory-prepublic-check.py . --json 2>&1)"
scan_rc=$?
set -e
if [ "$scan_rc" -ne 0 ]; then
  bad "factory-prepublic-check.py repo scan (rc=$scan_rc)"
  printf '%s\n' "$scan" | head -20
else
  ex_count="$(
    printf '%s' "$scan" | "$PYTHON" -c '
import json, sys
data = json.load(sys.stdin)
paths = [f["path"] for f in data.get("findings", []) if f["path"].startswith("examples/")]
print(len(paths))
if paths:
    print("FINDINGS", *paths, sep="\n", file=sys.stderr)
'
  )"
  if [ "$ex_count" -eq 0 ]; then
    ok "prepublic: no findings under examples/"
  else
    bad "prepublic: findings under examples/ (count=$ex_count)"
  fi
  total="$(
    printf '%s' "$scan" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["finding_count"])'
  )"
  if [ "$total" -eq 0 ]; then
    ok "prepublic: whole repo finding_count=0"
  else
    bad "prepublic: repo finding_count=$total (expected 0)"
  fi
fi

echo ""
echo "Results: ${passed} passed, ${failed} failed"
[ "$failed" -eq 0 ]