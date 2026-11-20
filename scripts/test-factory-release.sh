#!/usr/bin/env bash
# Offline tests for scripts/factory-release.py (temporary git repos).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
script="$root/scripts/factory-release.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); cat "$work/out" 2>/dev/null | head -20 || true; }

run_release() { # extra args
  set +e
  python3 "$script" "$@" >"$work/out" 2>"$work/err"
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

init_repo() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$dest"
  (
    cd "$dest"
    git init -q
    git config user.email "release@test.invalid"
    git config user.name "Release Test"
    printf '%s\n' "# Changelog" "" "## [Unreleased]" "" "### Added" "" "- Initial work" "" >CHANGELOG.md
    git add CHANGELOG.md
    git commit -q -m "chore: bootstrap changelog"
  )
}

# ---- invalid semver rejected (exit 2, message on stderr) ----
init_repo "$work/semver-repo"
run_release --version bad-ver --repo-dir "$work/semver-repo" --strict
assert_rc "invalid version strict" 2
grep -q "vMAJOR.MINOR.PATCH" "$work/err" || bad "invalid version stderr message"
grep -q "factory-sync-repos.py" "$work/out" && bad "invalid version must not print sync command"

run_release --version bad-ver --repo-dir "$work/semver-repo" --json
assert_rc "invalid version json" 2
python3 - <<'PY' "$work/out" || bad "invalid version json payload"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["semver_ok"] is False
assert data["release_commands"] == []
assert data["summary"]["fail"] == 1
PY
ok "invalid version json payload"

run_release --version v1.2.3 --repo-dir "$work/semver-repo"
assert_rc "valid semver default exit" 0
grep -q "PASS\\|pass" "$work/out" || grep -qi "semver_tag" "$work/out" || bad "valid semver output"

# ---- clean repo + changelog passes strict ----
init_repo "$work/clean"
(
  cd "$work/clean"
  git tag -a v0.0.1 -m "v0.0.1"
  git commit -q --allow-empty -m "feat: second feature"
)
run_release --version v0.1.0 --repo-dir "$work/clean" --strict
assert_rc "clean repo strict" 0

# ---- missing changelog section fails strict ----
init_repo "$work/no-changelog"
(
  cd "$work/no-changelog"
  printf '%s\n' "# Notes" "" "## [0.0.0]" "" "- old" "" >CHANGELOG.md
  git add CHANGELOG.md
  git commit -q -m "chore: wrong changelog sections"
)
run_release --version v0.1.0 --repo-dir "$work/no-changelog" --strict
assert_rc "missing changelog strict" 1
grep -q "changelog_section" "$work/out" || bad "missing changelog mentions changelog_section"

# ---- dry-run lists adopter sync command ----
init_repo "$work/sync-cmd"
run_release --version v0.4.0 --repo-dir "$work/sync-cmd"
assert_rc "sync cmd exit" 0
grep -q "factory-sync-repos.py --repos-file factory/adopters.txt --tag v0.4.0 --dry-run" "$work/out" \
  || bad "dry-run missing adopter sync command"
grep -q "factory-sync-repos.py --repos-file factory/adopters.txt --tag v0.4.0$" "$work/out" \
  || bad "missing adopter sync apply command"

# ---- dirty tree fails strict ----
init_repo "$work/dirty"
echo dirty >>"$work/dirty/CHANGELOG.md"
run_release --version v0.1.0 --repo-dir "$work/dirty" --strict
assert_rc "dirty tree strict" 1
grep -q "git_clean" "$work/out" || bad "dirty tree mentions git_clean"

# ---- duplicate tag fails strict ----
init_repo "$work/dup"
(
  cd "$work/dup"
  git tag -a v0.1.0 -m "v0.1.0"
)
run_release --version v0.1.0 --repo-dir "$work/dup" --strict
assert_rc "duplicate tag strict" 1
grep -q "tag_duplicate" "$work/out" || bad "duplicate tag mentions tag_duplicate"

# ---- draft-changelog extracts commit titles ----
init_repo "$work/draft"
(
  cd "$work/draft"
  git tag -a v0.0.1 -m "v0.0.1"
  git commit -q --allow-empty -m "feat: ship widgets"
  git commit -q --allow-empty -m "fix: patch widgets"
)
run_release --version v0.2.0 --repo-dir "$work/draft" --draft-changelog
assert_rc "draft-changelog exit" 0
grep -q "ship widgets" "$work/out" || bad "draft missing feat title"
grep -q "patch widgets" "$work/out" || bad "draft missing fix title"
grep -q "### Added" "$work/out" || bad "draft missing Added heading"
grep -q "### Fixed" "$work/out" || bad "draft missing Fixed heading"

# ---- JSON schema ----
init_repo "$work/json"
run_release --version v0.3.0 --repo-dir "$work/json" --json --draft-changelog
assert_rc "json exit default" 0
if python3 - <<'PY' "$work/out"; then
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
for key in (
    "repo_dir",
    "version",
    "semver_ok",
    "summary",
    "checks",
    "git",
    "release_commands",
    "draft_changelog",
):
    assert key in data, f"missing {key}"
assert data["version"] == "v0.3.0"
assert data["semver_ok"] is True
for k in ("pass", "warn", "fail", "skip"):
    assert k in data["summary"]
cmds = data["release_commands"]
assert isinstance(cmds, list) and cmds
assert any("factory-sync-repos.py" in c and "factory/adopters.txt" in c for c in cmds)
print("schema ok")
PY
  ok "json schema and keys"
else
  bad "json schema and keys"
fi

# ---- JSON key order stable ----
run_release --version v0.3.1 --repo-dir "$work/json" --json
cp "$work/out" "$work/json-a"
run_release --version v0.3.1 --repo-dir "$work/json" --json
if cmp -s "$work/json-a" "$work/out"; then
  ok "json output deterministic"
else
  bad "json output deterministic"
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi