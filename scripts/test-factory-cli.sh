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
    "doctor", "init", "triage", "spec-lint", "spec-check", "backlog",
    "run-review", "fix-policy", "audit-workflows", "check-docs", "test-all",
    "cost-digest", "predict-cost", "site", "site-smoke",
    "prepublic", "release", "sync-repos",
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