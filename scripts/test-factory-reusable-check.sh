#!/usr/bin/env bash
# Offline tests for scripts/factory-reusable-check.py (Refs #156, #178, #182).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
if ! "$PYTHON" -c "import yaml" 2>/dev/null; then
  echo "FAIL  PyYAML missing; install: pip install -r requirements-factory.txt" >&2
  exit 1
fi

PY=("$PYTHON" scripts/factory-reusable-check.py)
passed=0
failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# ---- live docs: must pass under --strict ----
set +e
out="$("${PY[@]}" --strict --json 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && echo "$out" | "$PYTHON" -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('ok') is True, d.get('summary')
assert d['summary']['fail'] == 0, d['summary']
"; then
  ok "live docs/reusable-workflows pass --strict"
else
  bad "live docs --strict"
  echo "$out" | head -40
fi

# ---- synthetic failure fixtures ----
fail_root="$tmpdir/fail-contract"
mkdir -p "$fail_root/callers"

cat >"$fail_root/reusable-demo.yml" <<'YML'
name: reusable-demo
on:
  workflow_call:
    inputs:
      factory_ref:
        type: string
        required: true
    secrets:
      DEMO_SECRET:
        required: true
permissions:
  contents: read
jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YML

cat >"$fail_root/callers/demo.yml" <<'YML'
name: demo-caller
on:
  workflow_dispatch:
permissions: write-all
jobs:
  call:
    uses: YOUR_ORG/software_factory_template/.github/workflows/reusable-demo.yml@v0.1.0
    secrets:
      WRONG_SECRET: ${{ secrets.DEMO_SECRET }}
    with:
      factory_ref: v0.1.0
      unknown_input: oops
YML

set +e
out="$("${PY[@]}" --dir "$fail_root" --json 2>&1)"
rc=$?
set -e
fail_count="$(echo "$out" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin)['summary']['fail'])")"
if [ "$rc" -eq 1 ] && [ "${fail_count:-0}" -ge 5 ]; then
  ok "fixtures report contract failures ($fail_count fails)"
else
  bad "fixture failures (rc=$rc fail_count=${fail_count:-?})"
  echo "$out"
fi

echo "$out" | "$PYTHON" -c "
import json, sys
codes = {f['check'] for f in json.load(sys.stdin)['findings'] if f['status'] == 'fail'}
need = {'action_pin', 'caller_input', 'caller_permissions', 'caller_secret'}
miss = need - codes
if miss:
    print('missing fail checks:', miss, file=sys.stderr)
    sys.exit(1)
" && ok "fixtures hit expected failure checks" || bad "fixture failure check codes"

# missing paired reusable
missing_root="$tmpdir/missing-reusable"
mkdir -p "$missing_root/callers"
cat >"$missing_root/callers/orphan.yml" <<'YML'
name: orphan
on:
  workflow_dispatch:
permissions: {}
jobs:
  call:
    uses: YOUR_ORG/software_factory_template/.github/workflows/reusable-orphan.yml@v0.1.0
    secrets: inherit
    with:
      factory_ref: v0.1.0
YML

set +e
out="$("${PY[@]}" --dir "$missing_root" --json 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 1 ] && echo "$out" | "$PYTHON" -c "
import json, sys
d = json.load(sys.stdin)
assert any(f['check']=='caller_pair' and f['status']=='fail' for f in d['findings'])
"; then
  ok "missing paired reusable file fails"
else
  bad "missing paired reusable (rc=$rc)"
  echo "$out"
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi