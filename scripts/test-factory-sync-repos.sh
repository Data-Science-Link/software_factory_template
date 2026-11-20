#!/usr/bin/env bash
# Offline tests for scripts/factory-sync-repos.py with a fake gh CLI.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); cat "$work/out" 2>/dev/null | head -5; }

mkdir -p "$work/bin" "$work/repo/.github/workflows"
cat >"$work/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
log="${FAKE_GH_LOG:-/dev/null}"
printf '%s\n' "$*" >>"$log"

if [ "$1" = api ]; then
  case "$*" in
    *contents/.github/workflows/opencode-run.yml*)
      printf '{"content":"%s"}' "${FAKE_RUN_YML_B64:-}"
      exit 0
      ;;
    *contents/.github/workflows/pr-check.yml*)
      printf '{"content":"%s"}' "${FAKE_PR_YML_B64:-}"
      exit 0
      ;;
    *contents/.github/workflows*)
      printf '%s' '[{"path":".github/workflows/opencode-run.yml"},{"path":".github/workflows/pr-check.yml"}]'
      exit 0
      ;;
  esac
fi

if [ "$1" = repo ] && [ "$2" = view ]; then
  echo main
  exit 0
fi

if [ "$1" = pr ] && [ "$2" = list ]; then
  exit 0
fi

if [ "$1" = repo ] && [ "$2" = clone ]; then
  dest="$4"
  mkdir -p "$dest/.git"
  cp -a "${FAKE_CLONE_SRC:?}"/* "$dest/" 2>/dev/null || true
  exit 0
fi

if [ "$1" = pr ] && [ "$2" = create ]; then
  echo "https://github.com/org/demo/pull/9"
  exit 0
fi

if [ "$1" = api ] && [[ "$*" == *contents* ]]; then
  :
fi

# git passthrough from clone dir handled by real git
exit 0
GH
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"

RUN_YML='name: opencode-run
jobs:
  x:
    uses: Data-Science-Link/software_factory_template/.github/workflows/reusable-opencode-run.yml@v0.1.0
    with:
      factory_ref: v0.1.0
'
export FAKE_RUN_YML_B64="$(printf '%s' "$RUN_YML" | base64 -w0)"
export FAKE_PR_YML_B64="$(printf '%s' 'name: pr-check' | base64 -w0)"
export FAKE_CLONE_SRC="$work/repo"
printf '%s\n' "$RUN_YML" >"$work/repo/.github/workflows/opencode-run.yml"

repos_file="$work/adopters.txt"
printf '%s\n' 'org/demo' >"$repos_file"

# --- bump via dry-run ---
set +e
out="$(python3 "$root/scripts/factory-sync-repos.py" --repos-file "$repos_file" --tag v0.2.0 --dry-run 2>&1)"
rc=$?
set -e
printf '%s' "$out" >"$work/out"
if [ "$rc" -eq 0 ] && grep -qE 'would update [1-9][0-9]* file' <<<"$out"; then
  ok "dry-run detects workflow bump"
else
  bad "dry-run (rc=$rc)"
  echo "$out" >>"$work/out"
fi

# --- unit bump in python ---
out="$(
python3 <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location("sync", "scripts/factory-sync-repos.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
text = """uses: Data-Science-Link/software_factory_template/.github/workflows/reusable-pr-check.yml@v0.1.0
    with:
      factory_ref: v0.1.0
"""
new, ch = mod.bump_content(text, "v0.2.0")
assert ch and "@v0.2.0" in new and "factory_ref: v0.2.0" in new
print("bump ok")
PY
)"
if grep -q 'bump ok' <<<"$out"; then
  ok "bump_content"
else
  bad "bump_content"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]