#!/usr/bin/env bash
# Offline tests for scripts/factory-models-check.py (refs #71, #127, #30).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
CHECK=( "$PYTHON" scripts/factory-models-check.py )

if ! "$PYTHON" -c "import yaml" 2>/dev/null; then
  echo "FAIL  PyYAML not installed; run: pip install -r requirements-factory.txt"
  exit 1
fi

passed=0
failed=0
fixtures_dir="tests/models-check"

note() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }

# --- real repo models.yaml passes (warnings allowed; no errors) ---
set +e
out="$(
  "${CHECK[@]}" --models-yaml .factory/models.yaml \
    --routing-md .factory/MODEL_ROUTING.md 2>&1
)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "real .factory/models.yaml (expected exit 0, got $rc)"
  printf '%s\n' "$out" | head -20
else
  note "real .factory/models.yaml -> exit 0"
fi

# --- negative price -> non-zero ---
set +e
out="$(
  "${CHECK[@]}" --models-yaml "$fixtures_dir/negative-price.yaml" \
    --routing-md /dev/null 2>&1
)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "negative-price.yaml (expected non-zero exit)"
elif printf '%s\n' "$out" | grep -qi "negative\|non-negative"; then
  note "negative price -> exit $rc with non-negative error"
else
  fail "negative-price.yaml (exit $rc but missing expected message)"
  printf '%s\n' "$out" | head -10
fi

# --- duplicate model id -> non-zero ---
set +e
out="$(
  "${CHECK[@]}" --models-yaml "$fixtures_dir/duplicate-id.yaml" \
    --routing-md /dev/null 2>&1
)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "duplicate-id.yaml (expected non-zero exit)"
elif printf '%s\n' "$out" | grep -qi "duplicate"; then
  note "duplicate model id -> exit $rc"
else
  fail "duplicate-id.yaml (exit $rc but missing duplicate message)"
  printf '%s\n' "$out" | head -10
fi

# --- dangling routing model reference -> non-zero ---
set +e
out="$(
  "${CHECK[@]}" --models-yaml "$fixtures_dir/dangling-model-ref.yaml" \
    --routing-md /dev/null 2>&1
)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "dangling-model-ref.yaml (expected non-zero exit)"
elif printf '%s\n' "$out" | grep -qi "undefined model"; then
  note "dangling model reference -> exit $rc"
else
  fail "dangling-model-ref.yaml (exit $rc but missing undefined model message)"
  printf '%s\n' "$out" | head -10
fi

# --- --json output parses ---
set +e
json_out="$(
  "${CHECK[@]}" --json \
    --models-yaml "$fixtures_dir/minimal-ok.yaml" \
    --routing-md "$fixtures_dir/routing-md-stub.md" 2>"$fixtures_dir/.json.err"
)"
rc=$?
set -e
rm -f "$fixtures_dir/.json.err"
if [ "$rc" -ne 0 ]; then
  fail "--json minimal-ok.yaml (expected exit 0, got $rc)"
elif printf '%s\n' "$json_out" | "$PYTHON" -c "
import json, sys
d = json.load(sys.stdin)
assert d['status'] in ('ok', 'warn', 'fail')
assert isinstance(d['models_checked'], int) and d['models_checked'] >= 1
assert isinstance(d['errors'], list) and isinstance(d['warnings'], list)
"; then
  note "--json output parses (status, models_checked, errors, warnings)"
else
  fail "--json output did not parse or validate"
  printf '%s\n' "$json_out" | head -5
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# --- missing price_table_version -> non-zero ---
cat >"$tmpdir/no-ptv.yaml" <<'YAML'
models:
  - id: org/No-PTV
    provider: deepinfra
    price_in_per_mtok: 0.1
    price_cached_per_mtok: 0.01
    price_out_per_mtok: 0.2
routing_rules:
  - rule: 3
    when: {}
    model: org/No-PTV
checks: []
token_priors:
  simple:
    tokens_in: 1
    tokens_cached_fraction: 0.5
    tokens_out: 1
budget:
  issue_cap_usd: 1.0
YAML
set +e
out="$("${CHECK[@]}" --models-yaml "$tmpdir/no-ptv.yaml" --routing-md /dev/null 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qi 'price_table_version'; then
  note "missing price_table_version -> exit $rc"
else
  fail "missing price_table_version (rc=$rc)"
  printf '%s\n' "$out" | head -5
fi

# --- non-numeric price string -> non-zero ---
cat >"$tmpdir/nan-price.yaml" <<'YAML'
price_table_version: "2099-01-01"
models:
  - id: org/Nan-Price
    provider: deepinfra
    price_in_per_mtok: not-a-number
    price_cached_per_mtok: 0.01
    price_out_per_mtok: 0.2
routing_rules:
  - rule: 3
    when: {}
    model: org/Nan-Price
checks: []
token_priors:
  simple:
    tokens_in: 1
    tokens_cached_fraction: 0.5
    tokens_out: 1
budget:
  issue_cap_usd: 1.0
YAML
set +e
out="$("${CHECK[@]}" --models-yaml "$tmpdir/nan-price.yaml" --routing-md /dev/null 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qi 'finite number'; then
  note "non-numeric price -> exit $rc"
else
  fail "non-numeric price (rc=$rc)"
  printf '%s\n' "$out" | head -5
fi

# --- invalid UTF-8 YAML path exits cleanly ---
printf '\xff\xfe' >"$tmpdir/bad-utf8.yaml"
set +e
out="$("${CHECK[@]}" --models-yaml "$tmpdir/bad-utf8.yaml" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q Traceback \
  && printf '%s\n' "$out" | grep -qi 'UTF-8'; then
  note "invalid UTF-8 models yaml exits cleanly"
else
  fail "invalid UTF-8 models yaml (rc=$rc)"
  printf '%s\n' "$out"
fi

# --- --json sort_keys determinism ---
"${CHECK[@]}" --json \
  --models-yaml "$fixtures_dir/minimal-ok.yaml" \
  --routing-md "$fixtures_dir/routing-md-stub.md" >"$tmpdir/json-a.json"
"${CHECK[@]}" --json \
  --models-yaml "$fixtures_dir/minimal-ok.yaml" \
  --routing-md "$fixtures_dir/routing-md-stub.md" >"$tmpdir/json-b.json"
if cmp -s "$tmpdir/json-a.json" "$tmpdir/json-b.json"; then
  note "--json output byte-identical across runs"
else
  fail "--json determinism"
fi
if "$PYTHON" - "$tmpdir/json-a.json" <<'PY'
import json, sys
text = open(sys.argv[1], encoding="utf-8").read()
assert text.index('"errors"') < text.index('"status"')
json.loads(text)
PY
then
  note "--json sort_keys key ordering"
else
  fail "--json sort_keys ordering"
fi

printf '\nSummary: %s passed, %s failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
exit 0