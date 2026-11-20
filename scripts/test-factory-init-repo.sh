#!/usr/bin/env bash
# Offline tests for scripts/factory-init-repo.py
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
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

run_init() {
  set +e
  python3 "$root/scripts/factory-init-repo.py" "$@" >"$work/out" 2>&1
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

assert_file() {
  local label="$1" path="$2"
  if [ -f "$path" ]; then
    ok "$label"
  else
    bad "$label (missing $path)"
  fi
}

yaml_parse_tree() {
  python3 - <<'PY' "$1"
import sys
from pathlib import Path
import yaml

root = Path(sys.argv[1])
errors = []
for path in sorted(root.rglob("*")):
    if not path.is_file():
        continue
    if path.suffix not in (".yml", ".yaml"):
        continue
    try:
        with open(path, encoding="utf-8") as fh:
            yaml.safe_load(fh)
    except Exception as exc:  # pragma: no cover
        errors.append(f"{path.relative_to(root)}: {exc}")
if errors:
    print("\n".join(errors))
    sys.exit(1)
print("ok")
PY
}

# Fresh scaffold
repo="$work/product-a"
run_init --target "$repo" --tag v0.2.0 --repo-name example-product
assert_rc "fresh init" 0
for rel in \
  .factory/mode.yml \
  .factory/models.yaml \
  .factory/DECISIONS.md \
  AGENTS.md \
  docs/specs/.gitkeep \
  .github/pull_request_template.md \
  .github/dependabot.yml \
  .github/workflows/pr-check.yml \
  .github/workflows/secret-scan.yml; do
  assert_file "scaffold $rel" "$repo/$rel"
done

mode="$(python3 -c "import yaml; print(yaml.safe_load(open('$repo/.factory/mode.yml'))['mode'])")"
[ "$mode" = product ] && ok "mode is product" || bad "mode is product (got $mode)"

grep -q "reusable-pr-check.yml@v0.2.0" "$repo/.github/workflows/pr-check.yml" \
  && ok "pr-check pins @v0.2.0" \
  || bad "pr-check pins @v0.2.0"

yaml_parse_tree "$repo" >"$work/yaml" 2>&1 \
  && ok "YAML files parse" \
  || bad "YAML files parse"

# Idempotency: second run skips; user edit preserved
echo "USER_MARKER_KEEP" >>"$repo/AGENTS.md"
before="$(cat "$repo/AGENTS.md")"
run_init --target "$repo" --tag v0.2.0
assert_rc "idempotent re-run" 0
after="$(cat "$repo/AGENTS.md")"
[ "$before" = "$after" ] && ok "preserves user edits" || bad "preserves user edits"
grep -q "Skipped existing" "$work/out" && ok "reports skipped" || bad "reports skipped"

# --force overwrites generated file
echo "mode: product" >"$repo/.factory/mode.yml"
run_init --target "$repo" --force
assert_rc "force re-run" 0
grep -q "Overwritten" "$work/out" && ok "force reports overwritten" || bad "force reports overwritten"

# --dry-run writes nothing new
repo_dry="$work/dry"
mkdir -p "$repo_dry/existing"
echo "stay" >"$repo_dry/existing/note.txt"
count_before="$(find "$repo_dry" -type f | wc -l | tr -d ' ')"
run_init --target "$repo_dry" --dry-run
assert_rc "dry-run" 0
count_after="$(find "$repo_dry" -type f | wc -l | tr -d ' ')"
[ "$count_before" = "$count_after" ] && ok "dry-run writes zero files" || bad "dry-run writes zero files"
grep -q "Dry run" "$work/out" && ok "dry-run summary" || bad "dry-run summary"

# factory-doctor on scaffolded repo (no --strict; optional LICENSE/SECURITY missing)
run_init --target "$work/doctor-target" --tag v0.1.0
set +e
python3 "$root/scripts/factory-doctor.py" --repo-dir "$work/doctor-target" >"$work/out" 2>&1
doc_rc=$?
set -e
[ "$doc_rc" -eq 0 ] && ok "doctor default exit 0" || bad "doctor default exit 0"
grep -q "mode is 'product'" "$work/out" || grep -q "mode is product" "$work/out" \
  && ok "doctor mode pass" || bad "doctor mode pass"
grep -q "models.yaml parses" "$work/out" && ok "doctor models pass" || bad "doctor models pass"
grep -q "missing LICENSE" "$work/out" && ok "doctor notes missing LICENSE" || bad "doctor notes missing LICENSE"
grep -q "missing SECURITY.md" "$work/out" && ok "doctor notes missing SECURITY" || bad "doctor notes missing SECURITY"
set +e
python3 "$root/scripts/factory-doctor.py" --repo-dir "$work/doctor-target" --strict >"$work/out" 2>&1
strict_rc=$?
set -e
[ "$strict_rc" -eq 1 ] && ok "doctor strict exit 1 without LICENSE/SECURITY" \
  || bad "doctor strict exit 1 without LICENSE/SECURITY"

# --no-with-callers
repo_nc="$work/no-callers"
run_init --target "$repo_nc" --no-with-callers
assert_rc "no-callers init" 0
[ ! -d "$repo_nc/.github/workflows" ] && ok "no workflows dir" || bad "no workflows dir"

echo ""
echo "factory-init-repo tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]