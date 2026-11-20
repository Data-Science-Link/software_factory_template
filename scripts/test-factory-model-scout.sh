#!/usr/bin/env bash
# Offline tests for scripts/factory-model-scout.py (issue #71).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
SCOUT=( "$PYTHON" scripts/factory-model-scout.py )

if ! "$PYTHON" -c "import yaml" 2>/dev/null; then
  echo "FAIL  PyYAML not installed; run: pip install -r requirements-factory.txt"
  exit 1
fi

passed=0
failed=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

note() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }

# --- no change -> exit 0 ---
set +e
out="$( "${SCOUT[@]}" --catalog tests/model-scout/catalog-no-change.json --format json 2>"$tmpdir/no-change.err" )"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "no-change catalog (expected exit 0, got $rc)"
else
  if printf '%s\n' "$out" | grep -Fq '"status": "no_change"'; then
    note "no-change catalog -> exit 0, status no_change"
  else
    fail "no-change catalog (missing status no_change)"
  fi
fi

# --- >15% drop -> proposal exit 2 ---
set +e
out="$( "${SCOUT[@]}" --catalog tests/model-scout/catalog-price-drop.json 2>"$tmpdir/drop.err" )"
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "price-drop catalog (expected exit 2, got $rc)"
elif printf '%s\n' "$out" | grep -Fq "DeepSeek-V4-Flash-0731" && printf '%s\n' "$out" | grep -Fq "price_in_per_mtok"; then
  note "price-drop catalog -> exit 2, markdown proposal"
else
  fail "price-drop catalog (missing expected proposal lines)"
fi

# --- short promo ignored -> exit 0 ---
set +e
out="$( "${SCOUT[@]}" --catalog tests/model-scout/catalog-short-promo.json --format json 2>"$tmpdir/promo.err" )"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "short-promo catalog (expected exit 0, got $rc)"
elif printf '%s\n' "$out" | grep -Fq '"status": "no_change"'; then
  note "short-promo catalog ignored -> exit 0"
else
  fail "short-promo catalog (expected no_change)"
fi

# --- malformed catalog -> exit 1 ---
set +e
"${SCOUT[@]}" --catalog tests/model-scout/catalog-malformed.json >"$tmpdir/mal.out" 2>"$tmpdir/mal.err"
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "malformed catalog (expected exit 1, got $rc)"
elif grep -Fq "model-scout:" "$tmpdir/mal.err"; then
  note "malformed catalog -> exit 1 with ERROR on stderr"
else
  fail "malformed catalog (missing stderr message)"
fi

# --- missing --catalog/--fetch -> exit 1 ---
set +e
"${SCOUT[@]}" >"$tmpdir/nosrc.out" 2>"$tmpdir/nosrc.err"
rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -Fq "model-scout:" "$tmpdir/nosrc.err" && grep -Fq "provide --catalog" "$tmpdir/nosrc.err"; then
  note "missing catalog source -> exit 1"
else
  fail "missing catalog source (expected exit 1)"
fi

cat >"$tmpdir/empty-catalog.json" <<'JSON'
{"models": [], "candidates": []}
JSON
set +e
out="$( "${SCOUT[@]}" --catalog "$tmpdir/empty-catalog.json" --format json 2>"$tmpdir/empty.err" )"
rc=$?
set -e
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -Fq '"status": "no_change"'; then
  note "empty catalog -> exit 0, no_change JSON"
else
  fail "empty catalog (rc=$rc)"
fi

set +e
"${SCOUT[@]}" --catalog tests/model-scout/catalog-no-change.json --format json \
  --checked-at 2026-11-20 >"$tmpdir/j1.out" 2>/dev/null
"${SCOUT[@]}" --catalog tests/model-scout/catalog-no-change.json --format json \
  --checked-at 2026-11-20 >"$tmpdir/j2.out" 2>/dev/null
set -e
if cmp -s "$tmpdir/j1.out" "$tmpdir/j2.out"; then
  note "JSON output deterministic (sort_keys)"
else
  fail "JSON determinism"
fi

cat >"$tmpdir/bad-models.yaml" <<'YAML'
models: "not-a-list"
YAML
set +e
"${SCOUT[@]}" --catalog tests/model-scout/catalog-no-change.json --models "$tmpdir/bad-models.yaml" \
  >"$tmpdir/bm.out" 2>"$tmpdir/bm.err"
rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -Fq "model-scout:" "$tmpdir/bm.err"; then
  note "invalid models.yaml -> exit 1 ERROR"
else
  fail "invalid models.yaml (rc=$rc)"
fi

printf '\nSummary: %s passed, %s failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
exit 0