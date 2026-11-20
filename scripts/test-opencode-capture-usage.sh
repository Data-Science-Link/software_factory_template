#!/usr/bin/env bash
# CI-friendly tests for scripts/opencode-capture-usage.sh (redacted stats fixtures).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
capture="$root/scripts/opencode-capture-usage.sh"
fixtures="$root/tests/opencode-capture-usage"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

run_case() {
  local name=$1 fixture=$2
  shift 2
  local out
  out="$tmpdir/case-${name//[^A-Za-z0-9._-]/_}.out"
  OPENCODE_STATS_FIXTURE="$fixture" bash "$capture" "$out"
  for needle in "$@"; do
    if ! grep -Fq "$needle" "$out"; then
      echo "FAIL $name: missing expected line: $needle" >&2
      cat "$out" >&2
      rm -f "$out"
      exit 1
    fi
  done
  rm -f "$out"
  echo "PASS  $name"
}

run_case_no_cost_var() {
  local name=$1 fixture=$2
  local combined
  combined="$tmpdir/combined-${name//[^A-Za-z0-9._-]/_}.out"
  if OPENCODE_STATS_FIXTURE="$fixture" bash "$capture" 2>/dev/null | tee "$combined" | grep -q '^OC_OPENCODE_COST='; then
    echo "FAIL $name: expected no OC_OPENCODE_COST line" >&2
    cat "$combined" >&2
    rm -f "$combined"
    exit 1
  fi
  rm -f "$combined"
  echo "PASS  $name (no OC_OPENCODE_COST)"
}

run_case "normal-run-41406322310" "$fixtures/stats-normal.txt" \
  "Input tokens: 17.3K" \
  "Output tokens: 1.2K" \
  "Cache read: 103.2K" \
  "OpenCode-reported cost: \$0.0028" \
  "Model: deepinfra/deepseek-ai/DeepSeek-V4-Flash-0731"

run_case "qwen-model-row" "$fixtures/stats-qwen.txt" \
  "Model: deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo" \
  "OpenCode-reported cost: \$0.0011"

run_case "no-model-row" "$fixtures/stats-no-model.txt" \
  "Model: unknown (not in stats)" \
  "Input tokens: 1.0K"

run_case "no-cost-row" "$fixtures/stats-no-cost.txt" \
  "OpenCode-reported cost: not measured"
run_case_no_cost_var "no-cost-row" "$fixtures/stats-no-cost.txt"

empty_out="$tmpdir/empty.out"
OPENCODE_STATS_FIXTURE="$fixtures/stats-empty.txt" bash "$capture" "$empty_out" >/dev/null
if grep -q 'Input tokens:' "$empty_out"; then
  echo "FAIL empty: should not report input tokens" >&2
  cat "$empty_out" >&2
  exit 1
fi
if ! grep -Fq 'not available' "$empty_out"; then
  echo "FAIL empty: expected not available message" >&2
  exit 1
fi
rm -f "$empty_out"
echo "PASS  empty-output"

garbled="$tmpdir/stats-garbled.txt"
printf 'not a stats table\n乱码 row\n' >"$garbled"
garbled_out="$tmpdir/garbled.out"
OPENCODE_STATS_FIXTURE="$garbled" bash "$capture" "$garbled_out" >/dev/null
if grep -Fq 'not available' "$garbled_out" && ! grep -q 'Input tokens:' "$garbled_out"; then
  echo "PASS  garbled-fixture-falls-back-to-not-available"
else
  echo "FAIL garbled-fixture" >&2
  cat "$garbled_out" >&2
  exit 1
fi
rm -f "$garbled_out"

unicode_fix="$tmpdir/stats-unicode.txt"
sed 's/DeepSeek-V4-Flash-0731/DeepSeek-V4-Flash-0731-🔥/' "$fixtures/stats-normal.txt" >"$unicode_fix"
run_case "unicode-model-suffix" "$unicode_fix" \
  "Model: deepinfra/deepseek-ai/DeepSeek-V4-Flash-0731-🔥" \
  "OpenCode-reported cost: \$0.0028"

missing_out="$tmpdir/missing-fixture.out"
if OPENCODE_STATS_FIXTURE="$tmpdir/no-such-stats.txt" bash "$capture" "$missing_out" >/dev/null \
  && grep -Fq 'not available' "$missing_out"; then
  echo "PASS  missing-fixture-file"
  rm -f "$missing_out"
else
  echo "FAIL missing-fixture-file" >&2
  exit 1
fi

echo "All opencode capture usage tests passed."
