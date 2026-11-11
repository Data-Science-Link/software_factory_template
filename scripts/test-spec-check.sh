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

# Derive the scripts a pass fixture plans to Create (its own ## Files Create:/Add:/New: lines),
# the set that is "new at approval" for that fixture (#145). Only scripts/ paths are candidates.
derive_new_scripts() { # <fixture>
  awk '
    /^##[ \t]+Files[ \t]*$/ { in_files = 1; next }
    /^##[ \t]/ { in_files = 0 }
    in_files && /^[ \t]*-[ \t]+(Create|Add|New):/ {
      line = $0
      while (match(line, /`[^`]*`/)) {
        p = substr(line, RSTART + 1, RLENGTH - 2)
        if (p ~ /^scripts\//) print p
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

# Build a fixture's base-scripts list with its own Create:/Add:/New: scripts removed from it.
derive_fixture_base() { # <fixture> [base-list] -> prints base list path (derived)
  local fixture="$1" base="${2:-$base_scripts}" name new out
  name="$(basename "$fixture")"
  new="$(derive_new_scripts "$fixture")"
  if [ -z "$new" ]; then
    printf '%s\n' "$base"
    return
  fi
  out="$tmp/base-$name.txt"
  printf '%s\n' $new | grep -vxF -f - "$base" >"$out" || true
  printf '%s\n' "$out"
}

for fixture in "$fixtures_dir"/*.md; do
  [ -f "$fixture" ] || continue
  total=$((total + 1))
  name="$(basename "$fixture")"

  set +e
  # Each fixture's own ## Files Create:/Add:/New: scripts are "new at approval" for that fixture
  # and are removed from its base list. Self-maintaining: once a script the fixture's spec planned
  # lands on main, the fixture already names it, so it stays green (#145). Removes only a fixture's
  # own Create:/Add:/New: paths, never Change: paths or paths absent from its own ## Files.
  fixture_base="$(derive_fixture_base "$fixture")"
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

# A new script already on the branch but not on base (a build PR's own new script) still passes.
# A non-protected existing script on the base list may now be listed as a Change. A protected
# spend/security script on the base list (or tracked on HEAD with no list) still fails.
case_rc() { # <name> <want: ok|fail> [fail-needle] <args...>
  local name="$1" want="$2" needle="" out rc
  shift 2
  if [ "$want" = fail ]; then needle="$1"; shift; fi
  total=$((total + 1))
  set +e
  out="$(python3 scripts/factory-spec-check.py "$@" 2>&1)"
  rc=$?
  set -e
  if { [ "$want" = ok ] && [ "$rc" -eq 0 ]; } \
    || { [ "$want" = fail ] && [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -Fq "$needle"; }; then
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
case_rc "base-scripts: non-protected script on base -> allowed" ok --base-scripts "$base_scripts" "$branch_spec"
case_rc "no base-scripts: non-protected script tracked on HEAD -> allowed" ok "$branch_spec"
prot_spec="$tmp/branch-protected-script.md"
sed 's#`scripts/widget-audit.sh`#`scripts/factory-predict-cost.py`#' "$fixtures_dir/pass-files-hyphenated-script.md" \
  | sed 's/Create:/Change:/' >"$prot_spec"
case_rc "base-scripts: protected script on base -> fails" fail "change to a protected spend/security script" --base-scripts "$base_scripts" "$prot_spec"
case_rc "no base-scripts: protected script tracked on HEAD -> fails" fail "change to a protected spend/security script" "$prot_spec"

# Rot test (#145): a regression fixture whose approved spec's Create: scripts already exist on the
# base list (simulating a merge that landed them) must still pass, because the derivation removes
# the fixture's own Create: paths from its base list. This is the exact rot that turned pr-check red.
rot_fixture="$fixtures_dir/pass-regression-issue-30-amended.md"
rot_base="$tmp/rot-base.txt"
cat "$base_scripts" >"$rot_base"
printf '%s\n' scripts/factory-usage.py scripts/factory-run-end.sh scripts/test-run-end.sh >>"$rot_base"
sort -u -o "$rot_base" "$rot_base"
rot_derived="$(derive_fixture_base "$rot_fixture" "$rot_base")"
total=$((total + 1))
set +e
rot_out="$(python3 scripts/factory-spec-check.py --base-scripts "$rot_derived" "$rot_fixture" 2>&1)"
rot_rc=$?
set -e
if [ "$rot_rc" -eq 0 ] && printf '%s\n' "$rot_out" | grep -q "^OK $rot_fixture\$"; then
  echo "PASS  regression rot: fixture passes once its Create: scripts exist on base"
  passed=$((passed + 1))
else
  echo "FAIL  regression rot (expected exit 0, got $rot_rc)"
  echo "$rot_out" | head -5
  failed=$((failed + 1))
fi

echo ""
echo "Results: $passed passed, $failed failed, $total total"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
