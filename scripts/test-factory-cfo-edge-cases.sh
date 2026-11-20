#!/usr/bin/env bash
# Edge-case regression suite for CFO / cost / cache / routing / model-scout scripts (Refs #30, #71, #110).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
if ! "$PYTHON" -c "import yaml" 2>/dev/null; then
  echo "FAIL  factory requirements missing; run: pip install -r requirements-factory.txt" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

passed=0
failed=0
note() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }

no_traceback() {
  local errfile="$1"
  if grep -q Traceback "$errfile" 2>/dev/null; then
    return 1
  fi
  return 0
}

MODELS=".factory/models.yaml"
MODELS_RECON="tests/cost-reconcile/models-fixture.yaml"
AS_OF="2026-11-20"
BASE_RECORD="tests/run-records/pass-pr-opened.json"

DIGEST=( "$PYTHON" scripts/factory-cost-digest.py )
RECON=( "$PYTHON" scripts/factory-cost-reconcile.py )
CACHE=( "$PYTHON" scripts/factory-cache-report.py )
ROUTE=( "$PYTHON" scripts/factory-routing-report.py )
SCOUT=( "$PYTHON" scripts/factory-model-scout.py )

write_run() {
  local dest="$1"
  shift
  "$PYTHON" - "$dest" "$BASE_RECORD" "$@" <<'PY'
import json, pathlib, sys

dest, base, *overrides = sys.argv[1:]
data = json.loads(pathlib.Path(base).read_text(encoding="utf-8"))
for chunk in overrides:
    for pair in chunk.split(","):
        k, v = pair.split("=", 1)
        if v == "null":
            data[k] = None
        elif v == "true":
            data[k] = True
        elif v == "false":
            data[k] = False
        elif v.lstrip("-").isdigit() or (v.startswith("0.") and v[1:].isdigit()):
            data[k] = float(v) if "." in v else int(v)
        else:
            data[k] = v
pathlib.Path(dest).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

# ---- factory-cost-digest.py ----

empty_runs="$tmpdir/digest-empty"
mkdir -p "$empty_runs"
set +e
out="$("${DIGEST[@]}" --runs-dir "$empty_runs" --models-file "$MODELS" \
  --as-of "$AS_OF" --json 2>"$tmpdir/digest-empty.err")"
rc=$?
set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"empty": true' && no_traceback "$tmpdir/digest-empty.err"; then
  note "cost-digest empty runs dir (JSON empty flag)"
else
  fail "cost-digest empty runs dir"
fi

printf '{not-json' >"$tmpdir/digest-bad.json"
mkdir -p "$tmpdir/digest-mixed"
cp "$tmpdir/digest-bad.json" "$tmpdir/digest-mixed/"
write_run "$tmpdir/digest-mixed/code.json" \
  "work_type=code,actual_cost_usd=0,cost_method=not_measured,tokens_cached=0"
write_run "$tmpdir/digest-mixed/review.json" \
  "work_type=review,actual_cost_usd=0.05"
set +e
out="$("${DIGEST[@]}" --runs-dir "$tmpdir/digest-mixed" --models-file "$MODELS" \
  --as-of "$AS_OF" --json 2>"$tmpdir/digest-mixed.err")"
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q 'skip digest-bad.json' "$tmpdir/digest-mixed.err" \
  && no_traceback "$tmpdir/digest-mixed.err"; then
  if printf '%s' "$out" | "$PYTHON" -c '
import json, sys
r = json.load(sys.stdin)
assert r["scorecard"]["run_count"] >= 2
assert r["scorecard"]["total_spend_usd"] >= 0
'; then
    note "cost-digest skips malformed JSON; zero-cost + review runs"
  else
    fail "cost-digest mixed runs JSON sanity"
  fi
else
  fail "cost-digest malformed + mixed runs"
fi

# ---- factory-cost-reconcile.py ----

recon_empty="$tmpdir/recon-empty"
mkdir -p "$recon_empty"
set +e
out="$("${RECON[@]}" --runs-dir "$recon_empty" --models-yaml "$MODELS_RECON" --json 2>"$tmpdir/recon-empty.err")"
rc=$?
set -e
if [ "$rc" -eq 0 ] && "$PYTHON" -c "import json,sys; d=json.loads(sys.stdin.read()); assert d['summary']['total_runs']==0" <<<"$out" \
  && no_traceback "$tmpdir/recon-empty.err"; then
  note "cost-reconcile zero runs in empty dir"
else
  fail "cost-reconcile empty dir"
fi

mkdir -p "$tmpdir/recon-bad"
printf '{bad' >"$tmpdir/recon-bad/x.json"
set +e
"${RECON[@]}" --runs-dir "$tmpdir/recon-bad" --models-yaml "$MODELS_RECON" \
  >"$tmpdir/recon-bad.out" 2>"$tmpdir/recon-bad.err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q 'invalid JSON' "$tmpdir/recon-bad.err" && no_traceback "$tmpdir/recon-bad.err"; then
  note "cost-reconcile malformed run JSON (clean stderr, non-zero)"
else
  fail "cost-reconcile malformed JSON (rc=$rc)"
fi

mkdir -p "$tmpdir/recon-nm"
cp tests/cost-reconcile/run-no-tokens.json "$tmpdir/recon-nm/"
set +e
out="$("${RECON[@]}" --runs-dir "$tmpdir/recon-nm" --models-yaml "$MODELS_RECON" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'NO_TOKEN_USAGE'; then
  note "cost-reconcile not_measured / missing tokens"
else
  fail "cost-reconcile not_measured run"
fi

# ---- factory-cache-report.py ----

cache_empty="$tmpdir/cache-empty"
mkdir -p "$cache_empty"
set +e
out="$("${CACHE[@]}" --runs-dir "$cache_empty" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q 'Run records: 0 file(s)' <<<"$out" && grep -q 'n/a' <<<"$out"; then
  note "cache-report empty runs dir"
else
  fail "cache-report empty runs dir"
fi

cache_mixed="$tmpdir/cache-mixed"
mkdir -p "$cache_mixed"
write_run "$cache_mixed/a.json" "work_type=code,tokens_in=1000,tokens_cached=0"
write_run "$cache_mixed/b.json" "work_type=review,tokens_in=2000,tokens_cached=500"
out="$("${CACHE[@]}" --runs-dir "$cache_mixed" 2>&1)" || true
if grep -q 'code:' <<<"$out" && grep -q 'review:' <<<"$out"; then
  note "cache-report by work_type code + review"
else
  fail "cache-report work_type breakdown"
fi

printf '{bad' >"$cache_mixed/bad.json"
set +e
out="$("${CACHE[@]}" --runs-dir "$cache_mixed" 2>"$tmpdir/cache-mixed.err")"
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q 'skip bad.json' "$tmpdir/cache-mixed.err" && no_traceback "$tmpdir/cache-mixed.err"; then
  note "cache-report skips malformed JSON"
else
  fail "cache-report malformed JSON"
fi

# ---- factory-routing-report.py ----

if ! "$PYTHON" -c "import jsonschema" 2>/dev/null; then
  fail "routing-report skipped (jsonschema not installed)"
else
  route_empty="$tmpdir/route-empty"
  mkdir -p "$route_empty"
  out="$("${ROUTE[@]}" --runs-dir "$route_empty" --models "$MODELS" --markdown 2>"$tmpdir/route-empty.err")"
  if grep -q 'Runs loaded: **0**' <<<"$out" && no_traceback "$tmpdir/route-empty.err"; then
    note "routing-report empty runs dir"
  else
    fail "routing-report empty runs dir"
  fi

  printf '{bad' >"$route_empty/bad.json"
  out="$("${ROUTE[@]}" --runs-dir "$route_empty" --models "$MODELS" --markdown 2>"$tmpdir/route-bad.err")"
  if grep -q 'Skipped files' <<<"$out" && grep -q 'bad.json' <<<"$out" && no_traceback "$tmpdir/route-bad.err"; then
    note "routing-report malformed JSON skipped"
  else
    fail "routing-report malformed JSON"
  fi

  route_edge="$tmpdir/route-edge"
  mkdir -p "$route_edge"
  write_run "$route_edge/r1.json" "work_type=review,tokens_cached=null"
  out="$("${ROUTE[@]}" --runs-dir "$route_edge" --models "$MODELS" --markdown 2>"$tmpdir/route-edge.err")"
  if no_traceback "$tmpdir/route-edge.err" && grep -q 'Skipped files' <<<"$out"; then
    note "routing-report invalid tokens_cached skips without traceback"
  else
    fail "routing-report tokens_cached=null"
  fi
fi

# ---- factory-model-scout.py ----

set +e
"${SCOUT[@]}" --catalog tests/model-scout/catalog-malformed.json \
  >"$tmpdir/scout-mal.out" 2>"$tmpdir/scout-mal.err"
rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'model-scout:' "$tmpdir/scout-mal.err" && no_traceback "$tmpdir/scout-mal.err"; then
  note "model-scout malformed catalog"
else
  fail "model-scout malformed catalog (rc=$rc)"
fi

set +e
out="$("${SCOUT[@]}" --catalog tests/model-scout/catalog-no-change.json --format json 2>"$tmpdir/scout-nc.err")"
rc=$?
set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"status": "no_change"' && no_traceback "$tmpdir/scout-nc.err"; then
  note "model-scout no-change stable exit 0"
else
  fail "model-scout no-change"
fi

printf '\nSummary: %s passed, %s failed\n' "$passed" "$failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi