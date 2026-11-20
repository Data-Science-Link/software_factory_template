#!/usr/bin/env bash
# Offline tests for scripts/factory-cli.py
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
cli="$root/scripts/factory-cli.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }

run_cli() {
  set +e
  python3 "$cli" "$@" >"$work/out" 2>"$work/err"
  local rc=$?
  set -e
  printf '%s' "$rc" >"$work/rc"
}

assert_rc() {
  local label="$1" expect="$2"
  local got
  got="$(cat "$work/rc")"
  if [ "$got" -eq "$expect" ]; then
    ok "$label (exit $expect)"
  else
    bad "$label (expected exit $expect, got $got)"
    cat "$work/out" "$work/err" 2>/dev/null || true
  fi
}

# --help succeeds
run_cli --help
assert_rc "top-level --help" 0
if grep -q "Setup & Health" "$work/out"; then
  ok "--help shows lifecycle groups"
else
  bad "--help shows lifecycle groups"
fi

# list --json: all wired commands available on main
run_cli list --json
assert_rc "list --json" 0
if python3 - "$work/out" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
cmds = data["commands"]
names = {c["name"] for c in cmds}
expected = {
    "doctor", "init", "models-check", "model-scout", "triage", "spec-lint", "spec-check",
    "backlog", "decision-log", "run-review", "fix-policy", "audit-workflows", "check-docs",
    "critic-context", "critic-run", "test-all", "cost-digest", "cost-reconcile", "predict-cost",
    "routing-report", "cache-report", "monthly-review", "site", "site-smoke", "prepublic", "branch-cleanup",
    "release", "sync-repos", "reusable-check", "migrate-adopter", "owner-pack",
}
missing = expected - names
assert not missing, f"missing commands in list: {missing}"
for c in cmds:
    if c["name"] in expected:
        assert c["available"], f"{c['name']} should be available"
print("ok")
PY
then
  ok "list --json reports all commands available"
else
  bad "list --json reports all commands available"
fi

# Pass-through: check-docs --help
run_cli check-docs --help
assert_rc "check-docs --help" 0
if grep -qi "usage" "$work/out"; then
  ok "check-docs --help shows usage"
else
  bad "check-docs --help shows usage"
fi

# Pass-through: fix-policy --help
run_cli fix-policy --help
assert_rc "fix-policy --help" 0
if grep -qi "usage" "$work/out"; then
  ok "fix-policy --help shows usage"
else
  bad "fix-policy --help shows usage"
fi

# Pass-through: release --help
run_cli release --help
assert_rc "release --help" 0
if grep -qi "usage" "$work/out"; then
  ok "release --help shows usage"
else
  bad "release --help shows usage"
fi

# Pass-through: owner-pack --help
run_cli owner-pack --help
assert_rc "owner-pack --help" 0
if grep -qi "usage" "$work/out"; then
  ok "owner-pack --help shows usage"
else
  bad "owner-pack --help shows usage"
fi

# Pass-through: migrate-adopter --help
run_cli migrate-adopter --help
assert_rc "migrate-adopter --help" 0
if grep -qi "usage" "$work/out"; then
  ok "migrate-adopter --help shows usage"
else
  bad "migrate-adopter --help shows usage"
fi

# Pass-through: cost-reconcile --help
run_cli cost-reconcile --help
assert_rc "cost-reconcile --help" 0
if grep -qi "usage" "$work/out"; then
  ok "cost-reconcile --help shows usage"
else
  bad "cost-reconcile --help shows usage"
fi

# Pass-through: models-check --help
run_cli models-check --help
assert_rc "models-check --help" 0
if grep -qi "usage" "$work/out"; then
  ok "models-check --help shows usage"
else
  bad "models-check --help shows usage"
fi

# Pass-through: decision-log --help
run_cli decision-log --help
assert_rc "decision-log --help" 0
if grep -qi "usage" "$work/out"; then
  ok "decision-log --help shows usage"
else
  bad "decision-log --help shows usage"
fi

# Pass-through: branch-cleanup --help
run_cli branch-cleanup --help
assert_rc "branch-cleanup --help" 0
if grep -qi "usage" "$work/out"; then
  ok "branch-cleanup --help shows usage"
else
  bad "branch-cleanup --help shows usage"
fi

# Pass-through: reusable-check --help
run_cli reusable-check --help
assert_rc "reusable-check --help" 0
if grep -qi "usage" "$work/out"; then
  ok "reusable-check --help shows usage"
else
  bad "reusable-check --help shows usage"
fi

# Pass-through: critic-context --help
run_cli critic-context --help
assert_rc "critic-context --help" 0
if grep -qi "usage" "$work/out"; then
  ok "critic-context --help shows usage"
else
  bad "critic-context --help shows usage"
fi

# Pass-through: routing-report --help
run_cli routing-report --help
assert_rc "routing-report --help" 0
if grep -qi "usage" "$work/out"; then
  ok "routing-report --help shows usage"
else
  bad "routing-report --help shows usage"
fi

# Pass-through: model-scout --help
run_cli model-scout --help
assert_rc "model-scout --help" 0

# Pass-through: monthly-review --help
run_cli monthly-review --help
assert_rc "monthly-review --help" 0
if grep -qi "usage" "$work/out"; then
  ok "monthly-review --help shows usage"
else
  bad "monthly-review --help shows usage"
fi
if grep -qi "usage" "$work/out"; then
  ok "model-scout --help shows usage"
else
  bad "model-scout --help shows usage"
fi

# Unknown subcommand suggests close match
run_cli doctr
assert_rc "unknown doctr" 2
if grep -q "did you mean 'doctor'" "$work/err"; then
  ok "unknown command suggests doctor"
else
  bad "unknown command suggests doctor"
  cat "$work/err" || true
fi

# Missing scripts via empty --scripts-dir
empty="$work/empty-scripts"
mkdir -p "$empty"
run_cli --scripts-dir "$empty" doctor
assert_rc "missing target script" 127
if grep -q "target script not found" "$work/err"; then
  ok "missing script actionable message"
else
  bad "missing script actionable message"
  cat "$work/err" || true
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi