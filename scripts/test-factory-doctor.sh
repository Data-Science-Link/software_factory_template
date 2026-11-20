#!/usr/bin/env bash
# Offline tests for scripts/factory-doctor.py
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
fixtures="$root/tests/factory-doctor"
healthy="$fixtures/healthy"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); cat "$work/out" 2>/dev/null || true; }

need_pyyaml() {
  if ! python3 -c "import yaml" 2>/dev/null; then
    echo "PyYAML is required (pip install -r requirements-factory.txt)" >&2
    exit 2
  fi
}
need_pyyaml

copy_healthy() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -a "$healthy/." "$dest/"
  chmod +x "$dest/scripts/"*.sh
}

run_doctor() { # $@ extra args
  set +e
  python3 "$root/scripts/factory-doctor.py" "$@" >"$work/out" 2>&1
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
  fi
}

assert_json_schema() {
  local label="$1" path="$2"
  if python3 - <<'PY' "$path"; then
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
for key in ("repo_dir", "summary", "checks"):
    assert key in data, f"missing top-level {key}"
for key in ("pass", "warn", "fail", "skip"):
    assert key in data["summary"], f"missing summary.{key}"
checks = data["checks"]
assert isinstance(checks, list) and checks, "checks must be a non-empty list"
for c in checks:
    for key in ("id", "category", "status", "detail"):
        assert key in c, f"check missing {key}"
    assert c["status"] in ("pass", "warn", "fail", "skip")
print("schema ok")
PY
    ok "$label"
  else
    bad "$label"
  fi
}

# Healthy fixture passes in --strict mode
copy_healthy "$work/repo"
run_doctor --repo-dir "$work/repo" --strict
assert_rc "healthy fixture strict" 0
grep -q "Summary:" "$work/out" || bad "healthy fixture prints summary"
grep -q "PASS.*factory_mode" "$work/out" || bad "healthy fixture mode pass"
[ "$(grep -c FAIL "$work/out" || true)" -eq 0 ] && ok "healthy fixture no FAIL rows" || bad "healthy fixture FAIL rows"

# Missing mode.yml
copy_healthy "$work/repo"
rm -f "$work/repo/.factory/mode.yml"
run_doctor --repo-dir "$work/repo" --strict
assert_rc "missing mode.yml strict" 1
grep -q "mode_present" "$work/out" || bad "missing mode check id"

# Invalid mode
copy_healthy "$work/repo"
echo "mode: bogus" >"$work/repo/.factory/mode.yml"
run_doctor --repo-dir "$work/repo" --strict
assert_rc "invalid mode strict" 1

# Broken models.yaml
copy_healthy "$work/repo"
printf '%s\n' "not: [yaml" >"$work/repo/.factory/models.yaml"
run_doctor --repo-dir "$work/repo" --strict
assert_rc "broken models.yaml strict" 1
grep -q "models_yaml" "$work/out" || bad "broken models mentions models_yaml"

# Missing LICENSE / SECURITY.md
copy_healthy "$work/repo"
rm -f "$work/repo/LICENSE" "$work/repo/SECURITY.md"
run_doctor --repo-dir "$work/repo" --strict
assert_rc "missing license/security strict" 1
grep -q "LICENSE" "$work/out" || bad "missing LICENSE detail"
grep -q "SECURITY.md" "$work/out" || bad "missing SECURITY detail"

# --json schema on healthy fixture
copy_healthy "$work/repo"
run_doctor --repo-dir "$work/repo" --json
assert_rc "healthy json exit default" 0
python3 -c "import json; json.load(open('$work/out'))" 2>/dev/null \
  && assert_json_schema "healthy json schema" "$work/out" \
  || bad "healthy json parse"

# Real template repo: structured output (default exit 0)
run_doctor --repo-dir "$root"
assert_rc "template repo default exit" 0
run_doctor --repo-dir "$root" --json
assert_json_schema "template repo json schema" "$work/out"
grep -q '"category": "workflow_hygiene"' "$work/out" || bad "template json includes workflow_hygiene"
grep -q '"category": "protected_scripts"' "$work/out" || bad "template json includes protected_scripts"

echo ""
echo "factory-doctor tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]