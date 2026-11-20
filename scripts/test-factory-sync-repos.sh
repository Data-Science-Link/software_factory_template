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
FLEET_DEMO='acme-corp/demo-app'
FLEET_OTHER='acme-corp/other-app'
export FAKE_RUN_YML_B64="$(printf '%s' "$RUN_YML" | base64 -w0)"
export FAKE_PR_YML_B64="$(printf '%s' 'name: pr-check' | base64 -w0)"
export FAKE_CLONE_SRC="$work/repo"
printf '%s\n' "$RUN_YML" >"$work/repo/.github/workflows/opencode-run.yml"

repos_file="$work/adopters.txt"
cat >"$repos_file" <<EOF
# fleet adopters
${FLEET_DEMO}

${FLEET_DEMO}
  # duplicate above

${FLEET_OTHER}
EOF

# --- invalid slug rejected (exit 2, no traceback) ---
bad_repos="$work/bad-adopters.txt"
printf 'not-a-valid-slug\n' >"$bad_repos"
set +e
err="$(python3 "$root/scripts/factory-sync-repos.py" --repos-file "$bad_repos" --tag v0.2.0 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -q 'invalid repo slug' <<<"$err" && ! grep -qi 'traceback' <<<"$err"; then
  ok "invalid adopter slug exits 2 without traceback"
else
  bad "invalid adopter slug (rc=$rc)"
  echo "$err"
fi

# --- parse: dedupe preserves one org/demo ---
set +e
out="$(REPOS_FILE="$repos_file" python3 <<PY
import importlib.util
import os
from pathlib import Path
root = ${root@Q}
spec = importlib.util.spec_from_file_location("sync", f"{root}/scripts/factory-sync-repos.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
repos = mod.parse_repos_file(Path(os.environ["REPOS_FILE"]))
assert repos == ["acme-corp/demo-app", "acme-corp/other-app"], repos
print("parse ok")
PY
)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q 'parse ok' <<<"$out"; then
  ok "repos-file comments and duplicates deduped"
else
  bad "repos-file parse"
  echo "$out"
fi

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

# --- --check --json drift report (no mutations) ---
set +e
out="$(python3 "$root/scripts/factory-sync-repos.py" --repos-file "$repos_file" --tag v0.2.0 --check --json 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && echo "$out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['summary']['outdated'] >= 1
assert d['summary']['total'] == 2
assert d['repos'] == ['acme-corp/demo-app', 'acme-corp/other-app']
demo = next(a for a in d['adopters'] if a['repo']=='acme-corp/demo-app')
assert demo['status'] == 'outdated'
"; then
  ok "--check --json reports outdated adopters"
else
  bad "--check --json"
  echo "$out"
fi

out2="$(python3 "$root/scripts/factory-sync-repos.py" --repos-file "$repos_file" --tag v0.2.0 --check --json 2>&1)"
if [ "$out" = "$out2" ]; then
  ok "--check --json is deterministic"
else
  bad "--check --json deterministic"
fi

# --- unit bump in python ---
out="$(
python3 <<PY
import importlib.util
root = ${root@Q}
spec = importlib.util.spec_from_file_location("sync", f"{root}/scripts/factory-sync-repos.py")
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

# --- lifecycle tempdir: init/migrate local repo then --check --json (offline) ---
lifecycle="$work/lifecycle-demo"
mkdir -p "$lifecycle"
TAG_LC="v0.1.0"
ACME_TEMPLATE="acme-corp/software_factory_template"
PYTHON="${FACTORY_PYTHON:-python3}"
if "$PYTHON" "$root/scripts/factory-init-repo.py" \
  --target "$lifecycle" \
  --tag "$TAG_LC" \
  --template-dir "$root" \
  --template-repo "$ACME_TEMPLATE" \
  --owner acme-corp \
  --repo-name demo-app >/dev/null 2>&1 \
  && printf '\n# lifecycle marker\n' >>"$lifecycle/AGENTS.md" \
  && "$PYTHON" "$root/scripts/factory-init-repo.py" \
    --target "$lifecycle" \
    --tag "$TAG_LC" \
    --template-dir "$root" \
    --template-repo "$ACME_TEMPLATE" \
    --owner acme-corp \
    --repo-name demo-app >/dev/null 2>&1 \
  && grep -q 'lifecycle marker' "$lifecycle/AGENTS.md"; then
  ok "init idempotent in lifecycle tempdir"
else
  bad "init idempotent in lifecycle tempdir"
fi
mkdir -p "$lifecycle/scripts"
cp "$root/scripts/pr-check.sh" "$lifecycle/scripts/pr-check.sh"
cp "$root/scripts/test-all.sh" "$lifecycle/scripts/test-all.sh"
printf '\n# migrate custom\n' >>"$lifecycle/scripts/test-all.sh"
if "$PYTHON" "$root/scripts/factory-migrate-adopter.py" \
  --repo-dir "$lifecycle" \
  --tag "$TAG_LC" \
  --template-dir "$root" \
  --template-repo "$ACME_TEMPLATE" \
  --owner acme-corp \
  --apply >/dev/null 2>&1 \
  && "$PYTHON" "$root/scripts/factory-migrate-adopter.py" \
    --repo-dir "$lifecycle" \
    --tag "$TAG_LC" \
    --template-dir "$root" \
    --template-repo "$ACME_TEMPLATE" \
    --owner acme-corp \
    --apply >/dev/null 2>&1 \
  && grep -q 'migrate custom' "$lifecycle/scripts/test-all.sh"; then
  ok "migrate idempotent in lifecycle tempdir"
else
  bad "migrate idempotent in lifecycle tempdir"
fi
mkdir -p "$lifecycle/.github/workflows"
printf '%s\n' "$RUN_YML" >"$lifecycle/.github/workflows/opencode-run.yml"
lc_repos="$work/lifecycle-adopters.txt"
printf '%s\n' "$FLEET_DEMO" >"$lc_repos"
lc_json="$(
  python3 "$root/scripts/factory-sync-repos.py" \
    --repos-file "$lc_repos" \
    --tag v0.2.0 \
    --check \
    --json 2>&1
)"
if echo "$lc_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['summary']['total'] == 1
assert d['adopters'][0]['repo'] == 'acme-corp/demo-app'
"; then
  ok "lifecycle chain ends with --check --json"
else
  bad "lifecycle chain ends with --check --json"
  echo "$lc_json"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]