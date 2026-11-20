#!/usr/bin/env bash
# Test scripts/factory-site-build.sh stage wiring (live vs --sample) without network or dbt.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"

passed=0
failed=0

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

pass() {
  echo "PASS  $1"
  passed=$((passed + 1))
}

fail() {
  echo "FAIL  $1"
  failed=$((failed + 1))
}

# ---- live --dry-run invokes seeds, dbt build, and real export paths ----
dry_log="$tmpdir/live-dry.log"
if bash scripts/factory-site-build.sh --dry-run >"$dry_log" 2>&1; then
  ok=1
  grep -q '^RUN   seeds' "$dry_log" || ok=0
  grep -q 'runs_to_seeds.py' "$dry_log" || ok=0
  grep -qF 'site-data/runs/' "$dry_log" || ok=0
  if grep -q '^RUN   dbt build' "$dry_log"; then
    :
  elif grep -q '^SKIP  dbt build (dbt not installed)' "$dry_log" \
    || grep -q '^SKIP  dbt build (dbt Python package not installed)' "$dry_log"; then
    :
  else
    ok=0
  fi
  grep -q 'factory-site-dbt-export.py' "$dry_log" || ok=0
  grep -qF 'site-data/dbt-marts' "$dry_log" || ok=0
  if grep -q 'sample-marts' "$dry_log"; then
  ok=0
  fi
  if ! grep -q 'SKIP  seeds (script not present: python3)' "$dry_log"; then
    :
  else
    ok=0
  fi
  if [ "$ok" = 1 ]; then
    pass "live --dry-run runs seeds, dbt build, and dbt-marts export (not sample-marts)"
  else
    fail "live --dry-run runs seeds, dbt build, and dbt-marts export (not sample-marts)"
    cat "$dry_log"
  fi
else
  fail "live --dry-run runs seeds, dbt build, and dbt-marts export (not sample-marts)"
  cat "$dry_log" 2>/dev/null || true
fi

# ---- --sample dry-run still uses sample-marts and skips collect/dbt ----
sample_log="$tmpdir/sample-dry.log"
if bash scripts/factory-site-build.sh --sample --dry-run >"$sample_log" 2>&1; then
  ok=1
  grep -q 'SKIP  collect runs' "$sample_log" || ok=0
  grep -q 'SKIP  dbt build' "$sample_log" || ok=0
  grep -q 'tests/site-data/sample-marts' "$sample_log" || ok=0
  if [ "$ok" = 1 ]; then
    pass "--sample --dry-run skips collect/dbt and uses sample-marts"
  else
    fail "--sample --dry-run skips collect/dbt and uses sample-marts"
    cat "$sample_log"
  fi
else
  fail "--sample --dry-run skips collect/dbt and uses sample-marts"
  cat "$sample_log" 2>/dev/null || true
fi

# ---- collect-runs resolves repo from env and git remote ----
if GITHUB_REPOSITORY='acme-corp/widget-factory' "$PYTHON" -c "
from pathlib import Path
import importlib.util
spec = importlib.util.spec_from_file_location(
    'collect', Path('scripts/factory-collect-runs.py'))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert mod.resolve_github_repo(None) == 'acme-corp/widget-factory'
"; then
  pass "collect-runs: GITHUB_REPOSITORY overrides default repo"
else
  fail "collect-runs: GITHUB_REPOSITORY overrides default repo"
fi

if "$PYTHON" -c "
from pathlib import Path
import importlib.util
spec = importlib.util.spec_from_file_location(
    'collect', Path('scripts/factory-collect-runs.py'))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
repo = mod.resolve_github_repo(None)
origin = __import__('subprocess').run(
    ['git', 'remote', 'get-url', 'origin'],
    check=True, capture_output=True, text=True,
).stdout.strip()
import re
match = re.search(r'github\\.com[:/]([^/]+)/([^/]+?)(?:\\.git)?\$', origin)
expected = f'{match.group(1)}/{match.group(2)}' if match else ''
assert repo == expected, (repo, expected)
"; then
  pass "collect-runs: resolves repo from git remote origin"
else
  fail "collect-runs: resolves repo from git remote origin"
fi

# ---- --offline --runs-dir dry-run uses synthesis, no gh / collect ----
offline_log="$tmpdir/offline-dry.log"
if bash scripts/factory-site-build.sh --offline --runs-dir examples/sample-runs --dry-run \
  >"$offline_log" 2>&1; then
  ok=1
  grep -q 'SKIP  collect runs' "$offline_log" || ok=0
  grep -q 'site-data synthesize' "$offline_log" || ok=0
  grep -q 'examples/sample-runs' "$offline_log" || ok=0
  grep -q 'backlog (offline' "$offline_log" || ok=0
  if grep -q 'factory-backlog.py' "$offline_log" && ! grep -q 'gh issue' "$offline_log"; then
    :
  else
    ok=0
  fi
  if [ "$ok" = 1 ]; then
    pass "--offline --runs-dir --dry-run synthesizes marts and skips network"
  else
    fail "--offline --runs-dir --dry-run synthesizes marts and skips network"
    cat "$offline_log"
  fi
else
  fail "--offline --runs-dir --dry-run synthesizes marts and skips network"
  cat "$offline_log" 2>/dev/null || true
fi

# ---- full offline build from sample-runs passes factory-site-smoke.py ----
site_tmp="$tmpdir/offline-site"
rm -rf site site-data
PINNED_NOW="2026-11-20 12:00:00"
if bash scripts/factory-site-build.sh --offline --runs-dir examples/sample-runs \
  --now "$PINNED_NOW" >"$tmpdir/offline-build.log" 2>&1 \
  && [ -f site/index.html ] \
  && smoke_out="$("$PYTHON" scripts/factory-site-smoke.py site 2>&1)" \
  && printf '%s\n' "$smoke_out" | grep -q '^OK'; then
  pass "offline build from examples/sample-runs passes factory-site-smoke.py"
else
  fail "offline build from examples/sample-runs passes factory-site-smoke.py"
  cat "$tmpdir/offline-build.log" 2>/dev/null || true
  printf '%s\n' "${smoke_out:-}" 
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi