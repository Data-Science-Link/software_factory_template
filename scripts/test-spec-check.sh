#!/usr/bin/env bash
# Test runner for scripts/factory-spec-check.py.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "PyYAML is required. Install factory deps in a venv, then re-run:" >&2
  echo "  python3 -m venv .venv && .venv/bin/pip install -r requirements-factory.txt && .venv/bin/python scripts/factory-spec-check.py ..." >&2
  echo "Or: pip install --user -r requirements-factory.txt  (if your Python allows it)" >&2
  exit 2
fi

read_expect() {
  local fixture="$1"
  head -n 1 "$fixture" | sed -n 's/^# spec-check-expect: //p'
}

passed=0
failed=0
total=0
fixtures_dir="tests/specs"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# "Existing script" in ## Files is judged against the base branch, not HEAD: a build PR adds the
# scripts its own spec names, and CI checks out the PR merge commit. Base = merge base with the PR
# base branch (GITHUB_BASE_REF in CI, main locally), fetched shallow when missing; fall back to HEAD.
base_ref="${GITHUB_BASE_REF:-main}"
base_commit=""
if git rev-parse -q --verify "refs/remotes/origin/$base_ref^{commit}" >/dev/null; then
  base_commit="$(git merge-base HEAD "origin/$base_ref" 2>/dev/null || git rev-parse "origin/$base_ref")"
elif git fetch -q --depth=1 origin "$base_ref" 2>/dev/null; then
  base_commit="$(git merge-base HEAD FETCH_HEAD 2>/dev/null || git rev-parse FETCH_HEAD)"
fi
base_scripts="$tmp/base-scripts.txt"
if [ -n "$base_commit" ]; then
  git ls-tree -r --name-only "$base_commit" -- scripts/ >"$base_scripts"
else
  echo "note: base branch $base_ref not found; judging existing scripts against HEAD" >&2
  git ls-tree -r --name-only HEAD -- scripts/ >"$base_scripts"
fi
[ -s "$base_scripts" ] || { echo "could not list base branch scripts" >&2; exit 2; }

for fixture in "$fixtures_dir"/*.md; do
  [ -f "$fixture" ] || continue
  total=$((total + 1))
  name="$(basename "$fixture")"

  set +e
  # Regression fixtures are checked as of their approval: scripts the spec created (since merged)
  # are named in a "# spec-check-new-scripts: a b" first line and removed from this fixture's base.
  fixture_base="$base_scripts"
  new_scripts="$(head -n 1 "$fixture" | sed -n 's/^# spec-check-new-scripts: //p')"
  if [ -n "$new_scripts" ]; then
    fixture_base="$tmp/base-$name.txt"
    printf '%s\n' $new_scripts | grep -vxF -f - "$base_scripts" >"$fixture_base" || true
  fi
  output="$(python3 scripts/factory-spec-check.py --base-scripts "$fixture_base" "$fixture" 2>&1)"
  rc=$?
  set -e

  case "$name" in
    pass-*)
      if [ "$rc" -eq 0 ] && printf '%s\n' "$output" | grep -q "^OK $fixture\$"; then
        echo "PASS  $name"
        passed=$((passed + 1))
      else
        echo "FAIL  $name (expected exit 0, got $rc)"
        echo "$output" | head -5
        failed=$((failed + 1))
      fi
      ;;
    fail-*)
      expect="$(read_expect "$fixture")"
      if [ -z "$expect" ]; then
        echo "FAIL  $name (missing first-line '# spec-check-expect: ...')"
        failed=$((failed + 1))
        continue
      fi
      if [ "$rc" -eq 0 ]; then
        echo "FAIL  $name (expected non-zero exit, got 0)"
        failed=$((failed + 1))
      elif printf '%s\n' "$output" | grep -Fq "$expect"; then
        echo "PASS  $name"
        passed=$((passed + 1))
      else
        echo "FAIL  $name (expected message containing: $expect)"
        echo "$output" | head -5
        failed=$((failed + 1))
      fi
      ;;
    *)
      echo "SKIP  $name (unknown prefix)"
      total=$((total - 1))
      ;;
  esac
done

# A script already on the branch but not on base (a build PR's own new script) passes; the same
# script on the base list, or with no list (HEAD), is an existing script and fails.
case_rc() { # <name> <want: ok|fail> <args...>
  local name="$1" want="$2" out rc
  shift 2
  total=$((total + 1))
  set +e
  out="$(python3 scripts/factory-spec-check.py "$@" 2>&1)"
  rc=$?
  set -e
  if { [ "$want" = ok ] && [ "$rc" -eq 0 ]; } \
    || { [ "$want" = fail ] && [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -Fq "change to an existing script under scripts/"; }; then
    echo "PASS  $name"
    passed=$((passed + 1))
  else
    echo "FAIL  $name (want $want, got exit $rc)"
    echo "$out" | head -5
    failed=$((failed + 1))
  fi
}
branch_spec="$tmp/branch-new-script.md"
sed 's#`scripts/widget-audit.sh`#`scripts/test-spec-check.sh`#' "$fixtures_dir/pass-files-hyphenated-script.md" >"$branch_spec"
grep -qxF 'scripts/test-spec-check.sh' "$base_scripts" || echo 'scripts/test-spec-check.sh' >>"$base_scripts"
grep -vxF 'scripts/test-spec-check.sh' "$base_scripts" >"$tmp/base-without.txt"
case_rc "base-scripts: script on branch, not on base -> passes" ok --base-scripts "$tmp/base-without.txt" "$branch_spec"
case_rc "base-scripts: script on base -> existing script" fail --base-scripts "$base_scripts" "$branch_spec"
case_rc "no base-scripts: tracked on HEAD -> existing script" fail "$branch_spec"

echo ""
echo "Results: $passed passed, $failed failed, $total total"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
