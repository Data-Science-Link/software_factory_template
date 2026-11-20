#!/usr/bin/env bash
# Offline tests for scripts/factory-audit-workflows.py
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
if ! "$PYTHON" -c "import yaml" 2>/dev/null; then
  echo "FAIL  PyYAML missing; install: pip install -r requirements-factory.txt" >&2
  exit 1
fi

PY=("$PYTHON" scripts/factory-audit-workflows.py)
FIXTURES="tests/workflow-audit/fixtures"
passed=0
failed=0

ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# ---- fixture: all checks pass ----
pass_dir="$tmpdir/pass-all"
mkdir -p "$pass_dir"
cat >"$pass_dir/pr-check.yml" <<'YML'
name: pr-check
on:
  pull_request:
permissions:
  contents: read
jobs:
  pr-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0 # v7.1.0
        with:
          python-version: "3.12"
      - run: bash scripts/test-shell-hygiene.sh
      - run: bash scripts/test-pr-check.sh
      - run: bash scripts/test-predict-cost.sh
      - run: bash scripts/test-spec-template-drift.sh
      - run: python3 scripts/factory-check-docs.py --strict
      - run: python3 scripts/factory-prepublic-check.py --strict
YML
cat >"$pass_dir/factory-site.yml" <<'YML'
name: factory-site
on:
  push:
    paths:
      - "factory/**"
      - "factory/budget.yml"
permissions: {}
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: step-security/harden-runner@46b06cea07f9e64621fdf066ba77ac6915163d43
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
      - run: bash scripts/factory-site-build.sh
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/deploy-pages@368f82528645a54fb793d4d04e342629a3f51346
YML
cat >"$pass_dir/opencode-spike.yml" <<'YML'
name: opencode-spike
on:
  issue_comment:
permissions: {}
jobs:
  agent:
    runs-on: ubuntu-latest
    steps:
      - uses: step-security/harden-runner@46b06cea07f9e64621fdf066ba77ac6915163d43
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0
        with:
          python-version: "3.13"
      - run: echo DEEPINFRA_API_KEY
  review:
    runs-on: ubuntu-latest
    steps:
      - run: echo review
YML
cat >"$pass_dir/approve-oc-runs.yml" <<'YML'
name: approve-oc-runs
on:
  pull_request_target:
  workflow_run:
    workflows: [pr-check, secret-scan]
    types: [requested]
permissions: {}
jobs:
  approve:
    if: >-
      startsWith(github.event.pull_request.head.ref, 'oc/') &&
      github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    permissions:
      actions: write
    steps:
      - run: echo approve
YML

set +e
out="$("${PY[@]}" --workflows-dir "$pass_dir" --json 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && echo "$out" | "$PYTHON" -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d['summary']['fail']==0 else 1)"; then
  ok "fixture pass-all has zero failures"
else
  bad "fixture pass-all"
  echo "$out"
fi

set +e
out="$("${PY[@]}" --workflows-dir "$pass_dir" --strict --json 2>/dev/null)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  ok "--strict exits 0 when all checks pass"
else
  bad "--strict on pass-all (rc=$rc)"
fi

# ---- fixture: deliberate failures ----
fail_dir="$tmpdir/failures"
mkdir -p "$fail_dir"
cp "$FIXTURES/fail-pr-check.yml" "$fail_dir/pr-check.yml"
cp "$FIXTURES/fail-python.yml" "$fail_dir/opencode-spike.yml"
cp "$FIXTURES/fail-approve.yml" "$fail_dir/approve-oc-runs.yml"
cp "$FIXTURES/fail-pin.yml" "$fail_dir/extra-unpinned.yml"

set +e
out="$("${PY[@]}" --workflows-dir "$fail_dir" --json 2>&1)"
rc=$?
set -e
fail_count="$(echo "$out" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin)['summary']['fail'])")"
if [ "$rc" -eq 0 ] && [ "${fail_count:-0}" -ge 4 ]; then
  ok "fixture failures detected ($fail_count fails, default exit 0)"
else
  bad "fixture failures (rc=$rc fail_count=${fail_count:-?})"
  echo "$out"
fi

set +e
"${PY[@]}" --workflows-dir "$fail_dir" --strict >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  ok "--strict exits 1 on failures"
else
  bad "--strict on failures (expected rc=1, got $rc)"
fi

# ---- real repo workflows: expect known backlog failures, default exit 0 ----
set +e
out="$("${PY[@]}" --json 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  ok "default audit of .github/workflows exits 0"
else
  bad "default audit exit (rc=$rc)"
fi

real_fail="$(echo "$out" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin)['summary']['fail'])")"
if [ "${real_fail:-0}" -ge 3 ]; then
  ok "live workflows report pending owner-paste items ($real_fail fails)"
else
  bad "live workflow fail count too low ($real_fail)"
fi

echo "$out" | "$PYTHON" -c "
import json,sys
d=json.load(sys.stdin)
codes={f['check'] for f in d['findings'] if f['status']=='fail'}
need={
    'pr_check_shell_hygiene',
    'pr_check_pr_check_tests',
    'pr_check_predict_cost',
    'pr_check_spec_template_drift',
    'pr_check_check_docs',
    'pr_check_prepublic',
    'oc_agent_python_pin',
    'approve_oc_workflow_run',
    'critic_review_job',
}
miss=need-codes
if miss:
    sys.exit(1)
" && ok "live audit flags core pending checks" || bad "live audit missing expected fail codes"

# ---- markdown output ----
md="$("${PY[@]}" --markdown 2>&1)"
if echo "$md" | grep -q '^| FAIL |' && echo "$md" | grep -q 'Workflow audit'; then
  ok "markdown report renders"
else
  bad "markdown report"
fi

if echo "$md" | grep -q '^## '; then
  ok "markdown groups findings by category"
else
  bad "markdown category sections"
fi

json1="$tmpdir/json1.json"
json2="$tmpdir/json2.json"
"${PY[@]}" --workflows-dir "$pass_dir" --json >"$json1"
"${PY[@]}" --workflows-dir "$pass_dir" --json >"$json2"
if cmp -s "$json1" "$json2"; then
  ok "--json output is deterministic on pass-all fixture"
else
  bad "--json determinism"
fi

if "$PYTHON" -c "
import json
d=json.load(open('$json1'))
assert 'categories' in d and 'owner_workflow_sync' in d
for f in d['findings']:
    assert 'category' in f
"; then
  ok "--json includes categories and owner_workflow_sync"
else
  bad "--json category schema"
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi