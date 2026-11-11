#!/usr/bin/env bash
# Test runner for scripts/factory-predict-cost.py
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "FAIL  PyYAML not installed; run: pip install -r requirements-factory.txt"
  exit 1
fi

PY=(python3 scripts/factory-predict-cost.py)
MODELS_DEFAULT=".factory/models.yaml"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Temp copies of the real .factory/models.yaml with one value changed, so test tables never drift.
# usage: make_models <out> <python statement on d>
make_models() {
  python3 - "$MODELS_DEFAULT" "$1" "$2" <<'PYEOF'
import sys, yaml
src, out, stmt = sys.argv[1], sys.argv[2], sys.argv[3]
d = yaml.safe_load(open(src, encoding="utf-8"))
exec(stmt)
yaml.safe_dump(d, open(out, "w", encoding="utf-8"), sort_keys=False)
PYEOF
}
MODELS_OVER="$tmpdir/models-over-cap.yaml"          # complex priors inflated past the $1.00 cap
make_models "$MODELS_OVER" 'd["token_priors"]["complex"]["tokens_in"] = 8000000'
MODELS_LOW_CAP="$tmpdir/models-low-cap.yaml"        # only budget.issue_cap_usd lowered to 0.15
make_models "$MODELS_LOW_CAP" 'd["budget"]["issue_cap_usd"] = 0.15'
MODELS_TINY_CAP="$tmpdir/models-tiny-cap.yaml"      # only budget.issue_cap_usd lowered to 0.02
make_models "$MODELS_TINY_CAP" 'd["budget"]["issue_cap_usd"] = 0.02'
MODELS_NO_CAP="$tmpdir/models-no-cap.yaml"          # no budget.issue_cap_usd: checks rule 6 is the fallback
make_models "$MODELS_NO_CAP" 'd["token_priors"]["complex"]["tokens_in"] = 8000000; del d["budget"]["issue_cap_usd"]'
passed=0
failed=0

run_pass() {
  local fixture="$1"
  local models="${2:-$MODELS_DEFAULT}"
  local name
  name="$(basename "$fixture")"
  local expect_line
  expect_line="$(grep '^# predict-expect:' "$fixture" | head -1 || true)"

  set +e
  output="$("${PY[@]}" "$fixture" --models "$models" 2>&1)"
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    echo "FAIL  $name (expected exit 0, got $rc)"
    echo "$output" | head -5
    failed=$((failed + 1))
    return
  fi

  if [ -z "$expect_line" ]; then
    echo "FAIL  $name (missing # predict-expect directive)"
    failed=$((failed + 1))
    return
  fi

  local want_model want_cost want_rule
  want_model="$(echo "$expect_line" | sed -n 's/.*model=\([^ ]*\).*/\1/p')"
  want_cost="$(echo "$expect_line" | sed -n 's/.*cost=\([^ ]*\).*/\1/p')"
  want_rule="$(echo "$expect_line" | sed -n 's/.*rule=\([^ ]*\).*/\1/p')"

  if ! echo "$output" | grep -q "model: $want_model"; then
    echo "FAIL  $name (model mismatch, want $want_model)"
    echo "$output" | head -5
    failed=$((failed + 1))
    return
  fi
  if ! echo "$output" | grep -q "predicted_cost_usd: $want_cost"; then
    echo "FAIL  $name (cost mismatch, want $want_cost)"
    echo "$output" | grep predicted_cost || true
    failed=$((failed + 1))
    return
  fi
  if [ -n "$want_rule" ] && ! echo "$output" | grep -q "selected_via_rule: $want_rule"; then
    echo "FAIL  $name (rule mismatch, want $want_rule)"
    echo "$output" | grep selected_via_rule || true
    failed=$((failed + 1))
    return
  fi

  echo "PASS  $name"
  passed=$((passed + 1))
}

run_fail() {
  local fixture="$1"
  local models="${2:-$MODELS_DEFAULT}"
  local want_exit="${3:-1}"
  local want_reason="${4:-}"
  local name
  name="$(basename "$fixture")"

  set +e
  output="$("${PY[@]}" "$fixture" --models "$models" 2>&1)"
  rc=$?
  set -e

  if [ "$rc" -ne "$want_exit" ]; then
    echo "FAIL  $name (expected exit $want_exit, got $rc)"
    echo "$output" | head -5
    failed=$((failed + 1))
    return
  fi

  case "$want_reason" in
    split)
      if ! echo "$output" | grep -qi "split this issue"; then
        echo "FAIL  $name (expected split message)"
        echo "$output" | head -3
        failed=$((failed + 1))
        return
      fi
      ;;
    priority)
      if ! echo "$output" | grep -qi "Priority DeepInfra tier"; then
        echo "FAIL  $name (expected priority tier rejection)"
        echo "$output" | head -3
        failed=$((failed + 1))
        return
      fi
      ;;
  esac

  echo "PASS  $name"
  passed=$((passed + 1))
}

run_pass tests/predict/pass-simple-flash.md
run_pass tests/predict/pass-complex-qwen.md
run_pass tests/predict/pass-high-risk-qwen.md
run_pass tests/predict/pass-work-type-spec.md
run_pass tests/predict/pass-work-type-spec-high-risk.md
run_pass tests/predict/pass-marker-prefixed.md
run_pass tests/predict/pass-write-preserves-formatting.md
# --write keeps the marker line (and any text above it) in place (#60, marker part).
tmpm="$tmpdir/marker.md"
grep -v '^# predict-expect:' tests/predict/pass-marker-prefixed.md >"$tmpm"
"${PY[@]}" "$tmpm" --write >/dev/null 2>&1
if [ "$(sed -n 2p "$tmpm")" = '<!-- factory-spec v1 -->' ] && [ "$(sed -n 3p "$tmpm")" = '---' ] \
  && grep -qx 'model: deepseek-ai/DeepSeek-V4-Flash-0731' "$tmpm" && python3 scripts/factory-predict-cost.py "$tmpm" >/dev/null 2>&1; then
  echo "PASS  pass-marker-prefixed (--write keeps the marker line)"
  passed=$((passed + 1))
else
  echo "FAIL  pass-marker-prefixed (--write lost the marker or broke the file)"
  head -4 "$tmpm"
  failed=$((failed + 1))
fi
run_fail tests/predict/fail-over-cap.md "$MODELS_OVER" 2 split
run_fail tests/predict/fail-priority-tier.md "$MODELS_DEFAULT" 1 priority

# Always route: a pre-filled model without model_override_reason is re-routed.
run_pass tests/predict/pass-prefilled-model-rerouted.md
# Owner override (model + non-empty model_override_reason) is kept; checks and the cap still apply.
run_pass tests/predict/pass-override-kept.md
run_fail tests/predict/fail-override-priority-tier.md "$MODELS_DEFAULT" 1 priority
echo -n "[override, issue_cap_usd=0.02] "
run_fail tests/predict/pass-override-kept.md "$MODELS_TINY_CAP" 2 split

# Split guard reads budget.issue_cap_usd: lowering only the cap makes complex/Qwen3-Coder exit 2.
echo -n "[issue_cap_usd=0.15] "
run_fail tests/predict/pass-complex-qwen.md "$MODELS_LOW_CAP" 2 split
# Fallback: no budget.issue_cap_usd -> checks rule 6 still splits.
echo -n "[no issue_cap_usd, rule 6 fallback] "
run_fail tests/predict/fail-over-cap.md "$MODELS_NO_CAP" 2 split

# --write re-routes a pre-filled model (no override reason) and records model_reason.
tmpw="$tmpdir/rerouted.md"
cp tests/predict/pass-prefilled-model-rerouted.md "$tmpw"
"${PY[@]}" "$tmpw" --write >/dev/null 2>&1
if grep -qx 'model: Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo' "$tmpw" \
  && grep -q '^model_reason: .*High risk or complex work' "$tmpw"; then
  echo "PASS  pass-prefilled-model-rerouted (--write overwrites model + model_reason)"
  passed=$((passed + 1))
else
  echo "FAIL  pass-prefilled-model-rerouted (--write did not overwrite model/model_reason)"
  grep '^model' "$tmpw" || true
  failed=$((failed + 1))
fi

# --write after editing simple -> complex re-routes Flash -> Qwen3-Coder (rule 1, #128).
tmpe="$tmpdir/edited.md"
cp tests/predict/pass-simple-flash.md "$tmpe"
"${PY[@]}" "$tmpe" --write >/dev/null 2>&1
sed -i 's/^complexity: simple$/complexity: complex/' "$tmpe"
"${PY[@]}" "$tmpe" --write >/dev/null 2>&1
if grep -qx 'model: Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo' "$tmpe"; then
  echo "PASS  pass-simple-flash edited to complex (--write re-routes to Qwen3-Coder)"
  passed=$((passed + 1))
else
  echo "FAIL  pass-simple-flash edited to complex (still $(grep '^model:' "$tmpe"))"
  failed=$((failed + 1))
fi

# --write idempotence: copy fixture to temp, write twice, no diff on second run
tmp="$(mktemp)"
cp tests/predict/pass-write-idempotent.md "$tmp"
"${PY[@]}" "$tmp" --write >/dev/null
first_hash="$(sha256sum "$tmp" | awk '{print $1}')"
"${PY[@]}" "$tmp" --write >/dev/null
second_hash="$(sha256sum "$tmp" | awk '{print $1}')"
rm -f "$tmp"

if [ "$first_hash" = "$second_hash" ]; then
  echo "PASS  pass-write-idempotent (--write idempotent)"
  passed=$((passed + 1))
else
  echo "FAIL  pass-write-idempotent (--write changed file on second run)"
  failed=$((failed + 1))
fi

# #60: targeted --write leaves every unowned byte unchanged; a second write is a no-op.
run_write_preserve() {
  local fixture="$1"
  local name
  name="$(basename "$fixture")"
  local before="$tmpdir/${name}.before"
  local after="$tmpdir/${name}.after"
  local jsonf="$tmpdir/${name}.json"
  grep -v "^# predict-expect:" "$fixture" >"$before"
  "${PY[@]}" "$before" --json >"$jsonf" 2>/dev/null
  cp "$before" "$after"
  "${PY[@]}" "$after" --write >/dev/null 2>&1
  if python3 tests/predict/check-write-preserve.py "$before" "$after" "$jsonf"; then
    echo "PASS  $name (--write preserves unowned bytes and already-correct owned lines)"
    passed=$((passed + 1))
  else
    echo "FAIL  $name (--write did not preserve formatting)"
    failed=$((failed + 1))
    return
  fi
  local hash1 hash2
  hash1="$(sha256sum "$after" | awk '{print $1}')"
  "${PY[@]}" "$after" --write >/dev/null 2>&1
  hash2="$(sha256sum "$after" | awk '{print $1}')"
  if [ "$hash1" = "$hash2" ]; then
    echo "PASS  $name (--write idempotent)"
    passed=$((passed + 1))
  else
    echo "FAIL  $name (--write changed file on second run)"
    failed=$((failed + 1))
  fi
}

run_write_preserve tests/predict/pass-write-preserves-formatting.md
run_write_preserve tests/predict/pass-write-already-filled.md

# First --write on an already-correct file must be a byte-for-byte no-op (quoted date stays quoted).
tmp_filled="$tmpdir/already-filled.md"
cp tests/predict/pass-write-already-filled.md "$tmp_filled"
before_hash="$(sha256sum "$tmp_filled" | awk '{print $1}')"
"${PY[@]}" "$tmp_filled" --write >/dev/null 2>&1
after_hash="$(sha256sum "$tmp_filled" | awk '{print $1}')"
if [ "$before_hash" = "$after_hash" ]; then
  echo "PASS  pass-write-already-filled (--write is a no-op when values already match)"
  passed=$((passed + 1))
else
  echo "FAIL  pass-write-already-filled (--write rewrote an already-correct file)"
  failed=$((failed + 1))
fi

# Missing owned keys are inserted; unowned lines stay the same.
tmp_miss="$tmpdir/missing-keys.md"
grep -v -e "^price_table_version:" -e "^model_reason:" tests/predict/pass-write-already-filled.md >"$tmp_miss"
cp "$tmp_miss" "$tmp_miss.before"
"${PY[@]}" "$tmp_miss" --json >"$tmpdir/missing-keys.json" 2>/dev/null
"${PY[@]}" "$tmp_miss" --write >/dev/null 2>&1
if python3 tests/predict/check-write-preserve.py "$tmp_miss.before" "$tmp_miss" "$tmpdir/missing-keys.json" \
  && grep -q "^price_table_version: 2026-11-02$" "$tmp_miss" \
  && grep -q "^model_reason: " "$tmp_miss"; then
  echo "PASS  --write inserts missing owned keys (unquoted date) without touching unowned lines"
  passed=$((passed + 1))
else
  echo "FAIL  --write missing-key insertion"
  failed=$((failed + 1))
fi

echo "---"
echo "predict-cost tests: $passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
