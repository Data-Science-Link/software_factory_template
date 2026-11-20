#!/usr/bin/env bash
# Offline tests for scripts/factory-migrate-adopter.py
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); cat "$work/out" 2>/dev/null | head -20; }

run_migrate() {
  set +e
  python3 "$root/scripts/factory-migrate-adopter.py" "$@" >"$work/out" 2>&1
  printf '%s' "$?" >"$work/rc"
  set -e
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

file_count() {
  find "$1" -type f | wc -l | tr -d ' '
}

setup_fixture_repo() {
  local dest="$1"
  mkdir -p "$dest/scripts" "$dest/.github/workflows"
  cp "$root/scripts/pr-check.sh" "$dest/scripts/pr-check.sh"
  cp "$root/scripts/test-all.sh" "$dest/scripts/test-all.sh"
  echo "# local tweak" >>"$dest/scripts/test-all.sh"
  echo '#!/usr/bin/env bash' >"$dest/scripts/build-product.sh"
  echo 'echo ok' >>"$dest/scripts/build-product.sh"
  cat >"$dest/.github/workflows/pr-check.yml" <<'YML'
name: pr-check
on:
  pull_request:
jobs:
  pr-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bash scripts/test-all.sh
YML
}

# --- dry-run leaves repo untouched ---
fixture="$work/adopter-a"
setup_fixture_repo "$fixture"
count_before="$(file_count "$fixture")"
run_migrate --repo-dir "$fixture" --tag v0.9.1 --template-dir "$root"
assert_rc "dry-run default" 0
count_after="$(file_count "$fixture")"
[ "$count_before" = "$count_after" ] && ok "dry-run touches zero files" || bad "dry-run touches zero files"

run_migrate --repo-dir "$fixture" --tag v0.9.1 --template-dir "$root" --json
assert_rc "dry-run json" 0
python3 - <<'PY' "$work/out"
import json, sys
data = json.loads(open(sys.argv[1]).read())
ident = data["identical_scripts"]
custom = data["customized_scripts"]
product = data["product_scripts"]
assert "scripts/pr-check.sh" in ident, ident
assert "scripts/test-all.sh" in custom, custom
assert "scripts/build-product.sh" in product, product
assert any(w["kind"] == "legacy_copied" for w in data["workflow_status"]["legacy"])
PY
ok "json classifies scripts and legacy workflow"

# --- apply writes mode + migration-callers ---
fixture_b="$work/adopter-b"
setup_fixture_repo "$fixture_b"
run_migrate --repo-dir "$fixture_b" --tag v0.9.2 --template-dir "$root" --apply
assert_rc "apply" 0
[ -f "$fixture_b/.factory/mode.yml" ] && ok "apply writes mode.yml" || bad "apply writes mode.yml"
grep -q "^mode: product" "$fixture_b/.factory/mode.yml" && ok "mode is product" || bad "mode is product"
[ -d "$fixture_b/.factory/migration-callers" ] && ok "migration-callers dir" || bad "migration-callers dir"
grep -q "reusable-pr-check.yml@v0.9.2" "$fixture_b/.factory/migration-callers/pr-check.yml" \
  && ok "caller pin tag" || bad "caller pin tag"
if grep -q "Data-Science-Link/software_factory_template" "$fixture_b/.factory/migration-callers/pr-check.yml" \
  && ! grep -q "YOUR_ORG" "$fixture_b/.factory/migration-callers/pr-check.yml"; then
  ok "migration-callers substitute default template-repo"
else
  bad "migration-callers substitute default template-repo"
fi
[ -f "$fixture_b/scripts/build-product.sh" ] && ok "product script preserved" || bad "product script preserved"
[ -f "$fixture_b/scripts/test-all.sh" ] && ok "customized script preserved" || bad "customized script preserved"

# --- apply with --owner and custom --template-repo (zero placeholders) ---
fixture_owner="$work/adopter-owner"
setup_fixture_repo "$fixture_owner"
TEMPLATE_REPO="example-org/software_factory_template"
OWNER_LOGIN="example-migrate-owner"
run_migrate --repo-dir "$fixture_owner" --tag v0.9.4 \
  --template-dir "$root" --template-repo "$TEMPLATE_REPO" \
  --owner "$OWNER_LOGIN" --apply
assert_rc "apply with owner" 0
placeholder_hits="$(grep -R -l -E 'YOUR_ORG|YOUR_OWNER_GITHUB_LOGIN' \
  "$fixture_owner/.factory/migration-callers" 2>/dev/null || true)"
[ -z "$placeholder_hits" ] && ok "owner apply: zero template placeholders" \
  || bad "owner apply: zero template placeholders"
grep -q "$TEMPLATE_REPO" "$fixture_owner/.factory/migration-callers/opencode-spec.yml" \
  && ok "owner apply: custom template-repo in callers" \
  || bad "owner apply: custom template-repo in callers"
grep -q "$OWNER_LOGIN" "$fixture_owner/.factory/migration-callers/opencode-spec.yml" \
  && ok "owner apply: owner login substituted" || bad "owner apply: owner login substituted"
if ! bash "$root/scripts/opencode-artifact-scan.sh" --list-protected | grep -q 'factory-init-repo.py' \
  && ! bash "$root/scripts/opencode-artifact-scan.sh" --list-protected | grep -q 'factory-migrate-adopter.py'; then
  ok "init/migrate not in PROTECTED_SCRIPTS"
else
  bad "init/migrate not in PROTECTED_SCRIPTS"
fi

# --- prune-identical archives only identical ---
fixture_c="$work/adopter-c"
setup_fixture_repo "$fixture_c"
run_migrate --repo-dir "$fixture_c" --tag v0.9.3 --template-dir "$root" --apply --prune-identical
assert_rc "apply prune" 0
[ ! -f "$fixture_c/scripts/pr-check.sh" ] && ok "identical pr-check removed" || bad "identical pr-check removed"
[ -f "$fixture_c/.factory/migration-archive/scripts/pr-check.sh" ] \
  && ok "identical archived" || bad "identical archived"
[ -f "$fixture_c/scripts/test-all.sh" ] && ok "customized after prune" || bad "customized after prune"
[ -f "$fixture_c/scripts/build-product.sh" ] && ok "product after prune" || bad "product after prune"

# --- invalid tag ---
run_migrate --repo-dir "$fixture" --tag not-a-semver --template-dir "$root"
assert_rc "invalid tag" 2

# --- json schema keys ---
run_migrate --repo-dir "$fixture" --tag v1.0.0 --template-dir "$root" --json
python3 - <<'PY' "$work/out"
import json, sys
data = json.loads(open(sys.argv[1]).read())
for key in (
    "identical_scripts",
    "customized_scripts",
    "product_scripts",
    "workflow_status",
    "mode_status",
    "actions",
):
    assert key in data, key
PY
ok "json has required keys"

echo ""
echo "factory-migrate-adopter tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]