#!/usr/bin/env bash
# Test harness for scripts/factory-run-review.py
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

passed=0
failed=0

note() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }

FIX_DIR=tests/factory-run-review
REVIEW=(python3 scripts/factory-run-review.py)

# Byte-identical check: script output must equal the committed expected-*.json.
byte_identical() {
  local run="$1"
  if "${REVIEW[@]}" --input "$FIX_DIR/run-$run.json" > "$tmpdir/out-$run.json" 2>"$tmpdir/err-$run.txt"; then
    if cmp -s "$tmpdir/out-$run.json" "$FIX_DIR/expected-$run.json"; then
      note "run $run byte-identical"
    else
      fail "run $run byte-identical (output differs from expected-$run.json)"
    fi
  else
    fail "run $run byte-identical (script exited non-zero)"
  fi
}

byte_identical 42282682618
byte_identical 42290238204
byte_identical 42297659590

# Live-path parser: drives the same discovery + artifact parsing logic offline
# from a recorded, sanitized fixture (no network, no gh). It must populate model,
# routing rule, cost and scan from the artifact files, and select the build run
# (headBranch main) plus the later opencode-fix run while excluding unrelated
# opencode-spec/build runs.
live_dir="$FIX_DIR/live"
set +e
"${REVIEW[@]}" --live-dir "$live_dir" > "$tmpdir/out-live.json" 2>"$tmpdir/err-live.txt"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "live-path parser (script exited non-zero)"
else
  live_ok=1
  grep -q '"model": "deepseek-ai/DeepSeek-V4-Flash-0731"' "$tmpdir/out-live.json" || live_ok=0
  grep -q '"cost_usd": 0.004' "$tmpdir/out-live.json" || live_ok=0
  grep -q '"scan_result": "pass"' "$tmpdir/out-live.json" || live_ok=0
  grep -q '"workflow": "opencode-spike"' "$tmpdir/out-live.json" || live_ok=0
  grep -q '"workflow": "opencode-fix"' "$tmpdir/out-live.json" || live_ok=0
  grep -q '"workflow": "opencode-spec"' "$tmpdir/out-live.json" && live_ok=0
  grep -q '"scan_result": null' "$tmpdir/out-live.json" && live_ok=0
  if [ "$live_ok" -eq 1 ]; then
    note "live-path parser (model/cost/scan populated)"
  else
    fail "live-path parser (model/cost/scan not populated from artifacts)"
  fi
fi

# No model call, no secret printed: a sentinel in the environment must never
# appear in the script's output or stderr.
secret="sentinel-run-review-secret-98765"
set +e
FACTORY_RUN_REVIEW_SECRET="$secret" "${REVIEW[@]}" --input "$FIX_DIR/run-42282682618.json" > "$tmpdir/out-secret.json" 2>"$tmpdir/err-secret.txt"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "no model call, no secret printed (script exited non-zero)"
elif grep -q "$secret" "$tmpdir/out-secret.json" || grep -q "$secret" "$tmpdir/err-secret.txt"; then
  fail "no model call, no secret printed (sentinel appeared in output)"
else
  note "no model call, no secret printed"
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
