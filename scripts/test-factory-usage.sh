#!/usr/bin/env bash
# Test harness for scripts/factory-usage.py
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

passed=0
failed=0

note() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }

PY=(python3 scripts/factory-usage.py)
FIXTURE1=tests/factory-usage/opencode-export-session-1.json
FIXTURE2=tests/factory-usage/opencode-export-session-2.json
EXPECTED_BOTH="{\"models\": [\"deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo\"], \"opencode_cost_usd\": 0.00164, \"requests\": 4, \"sessions\": 2, \"source\": \"opencode-export\", \"tokens_cached\": 8000, \"tokens_in\": 10000, \"tokens_out\": 240, \"tokens_reasoning\": 0}"
EXPECTED_SESSION1="{\"models\": [\"deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo\"], \"opencode_cost_usd\": 0.00058, \"requests\": 2, \"sessions\": 1, \"source\": \"opencode-export\", \"tokens_cached\": 2800, \"tokens_in\": 3500, \"tokens_out\": 90, \"tokens_reasoning\": 0}"

# run_case <name> <expected_rc> <expected_stdout> <args...>
run_case() {
  local name="$1"
  local want_rc="$2"
  local want_stdout="$3"
  shift 3
  set +e
  local out rc
  out="$("${PY[@]}" "$@" 2>"$tmpdir/stderr.txt")"
  rc=$?
  set -e
  if [ "$rc" -ne "$want_rc" ]; then
    fail "$name (expected exit $want_rc, got $rc)"
    return
  fi
  if [ "$want_rc" -eq 0 ]; then
    if [ "$out" != "$want_stdout" ]; then
      fail "$name (expected stdout: $want_stdout, got: $out)"
      return
    fi
  else
    if [ -n "$out" ]; then
      fail "$name (expected empty stdout, got: $out)"
      return
    fi
  fi
  note "$name"
}

# Happy path cases
run_case "both sessions (order 1-2)" 0 "$EXPECTED_BOTH" "$FIXTURE1" "$FIXTURE2"
run_case "both sessions (order 2-1)" 0 "$EXPECTED_BOTH" "$FIXTURE2" "$FIXTURE1"
run_case "session 1 alone" 0 "$EXPECTED_SESSION1" "$FIXTURE1"

# Test env override - set OPENCODE_USAGE_FIXTURE in environment properly
OPENCODE_USAGE_FIXTURE="$FIXTURE1:$FIXTURE2" run_case "OPENCODE_USAGE_FIXTURE matches positional args" 0 "$EXPECTED_BOTH"

# Test cost calculation
tmpdir_copy="$tmpdir/copy"
mkdir -p "$tmpdir_copy"
cp "$FIXTURE1" "$tmpdir_copy/session1.json"
cp "$FIXTURE2" "$tmpdir_copy/session2.json"

# Remove cost from one message in session1
python3 -c '
import json
import sys
data = json.load(open(sys.argv[1]))
for msg in data["messages"]:
    if "info" in msg and msg["info"].get("role") == "assistant":
        if "cost" in msg["info"]:
            del msg["info"]["cost"]
            break
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir_copy/session1.json"

run_case "one message cost removed -> opencode_cost_usd is null" 0 '{"models": ["deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo"], "opencode_cost_usd": null, "requests": 4, "sessions": 2, "source": "opencode-export", "tokens_cached": 8000, "tokens_in": 10000, "tokens_out": 240, "tokens_reasoning": 0}' "$tmpdir_copy/session1.json" "$tmpdir_copy/session2.json"

# Test cost validation function from factory-validate-run.py using importlib
if python3 -c '
import sys
import importlib.util
spec = importlib.util.spec_from_file_location("factory_validate_run", "scripts/factory-validate-run.py")
module = importlib.util.module_from_spec(spec)
sys.modules["factory_validate_run"] = module
spec.loader.exec_module(module)
result = module.cost_from_usage(10000, 8000, 240, 0.30, 0.10, 1.00)
expected = 0.00164
tolerance = 1e-9
if abs(result - expected) >= tolerance:
    print("cost_from_usage: expected", expected, "got", result, file=sys.stderr)
    sys.exit(1)
'; then
  note "cost_from_usage validation"
else
  fail "cost_from_usage validation"
fi

# Error cases - exit 3 with empty stdout
# Duplicate file
run_case "duplicate file" 3 "" "$FIXTURE1" "$FIXTURE1"

# Unparseable JSON
printf '{invalid json}' > "$tmpdir/bad.json"
run_case "unparseable JSON" 3 "" "$tmpdir/bad.json"

# Wrong file type (stats text file)
printf 'some text file\n' > "$tmpdir/stats.txt"
run_case "stats text file" 3 "" "$tmpdir/stats.txt"

# Unknown tokens key
cp "$FIXTURE1" "$tmpdir/bad-tokens.json"
python3 -c '
import json
import sys
data = json.load(open(sys.argv[1]))
data["messages"][1]["info"]["tokens"]["unknown"] = 1
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir/bad-tokens.json"
run_case "unknown tokens key" 3 "" "$tmpdir/bad-tokens.json"

# Missing cache.read
cp "$FIXTURE1" "$tmpdir/no-cache-read.json"
python3 -c '
import json
import sys
data = json.load(open(sys.argv[1]))
del data["messages"][1]["info"]["tokens"]["cache"]["read"]
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir/no-cache-read.json"
run_case "missing cache.read" 3 "" "$tmpdir/no-cache-read.json"

# Assistant message without tokens
cp "$FIXTURE1" "$tmpdir/no-msg-tokens.json"
python3 -c '
import json
import sys
data = json.load(open(sys.argv[1]))
del data["messages"][1]["info"]["tokens"]
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir/no-msg-tokens.json"
run_case "assistant message without tokens" 3 "" "$tmpdir/no-msg-tokens.json"

# Session total mismatch
cp "$FIXTURE1" "$tmpdir/mismatch.json"
python3 -c '
import json
import sys
data = json.load(open(sys.argv[1]))
data["info"]["tokens"]["input"] = 999999
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir/mismatch.json"
run_case "session total mismatch" 3 "" "$tmpdir/mismatch.json"

# No assistant messages
cp "$FIXTURE1" "$tmpdir/no-assistant.json"
python3 -c '
import json
import sys
data = json.load(open(sys.argv[1]))
data["messages"] = [msg for msg in data["messages"] if msg["info"].get("role") != "assistant"]
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir/no-assistant.json"
run_case "no assistant messages" 3 "" "$tmpdir/no-assistant.json"

# Negative token value
cp "$FIXTURE1" "$tmpdir/negative-token.json"
python3 -c '
import json
import sys
data = json.load(open(sys.argv[1]))
data["messages"][1]["info"]["tokens"]["input"] = -1
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir/negative-token.json"
run_case "negative token value" 3 "" "$tmpdir/negative-token.json"

# Boolean token value
cp "$FIXTURE1" "$tmpdir/bool-token.json"
python3 -c '
import json
import sys
data = json.load(open(sys.argv[1]))
data["messages"][1]["info"]["tokens"]["input"] = True
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir/bool-token.json"
run_case "boolean token value" 3 "" "$tmpdir/bool-token.json"

# Additional error cases for review fixes
# Non-UTF-8 file
printf '\xff\xfe' > "$tmpdir/non-utf8.json"
run_case "non-UTF-8 file" 3 "" "$tmpdir/non-utf8.json"

# Top-level JSON is not an object
printf '["not", "an", "object"]' > "$tmpdir/not-object.json"
run_case "top-level JSON is not an object" 3 "" "$tmpdir/not-object.json"

# Messages is not a list
cp "$FIXTURE1" "$tmpdir/messages-not-list.json"
python3 -c '
import json
import sys
data = json.load(open(sys.argv[1]))
data["messages"] = "not a list"
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir/messages-not-list.json"
run_case "messages is not a list" 3 "" "$tmpdir/messages-not-list.json"

# Missing session token keys
cp "$FIXTURE1" "$tmpdir/missing-session-keys.json"
python3 -c '
import json
import sys
data = json.load(open(sys.argv[1]))
del data["info"]["tokens"]["input"]
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir/missing-session-keys.json"
run_case "missing session token key: input" 3 "" "$tmpdir/missing-session-keys.json"

# Missing session cache keys
cp "$FIXTURE1" "$tmpdir/missing-session-cache-keys.json"
python3 -c '
import json
import sys
data = json.load(open(sys.argv[1]))
del data["info"]["tokens"]["cache"]["read"]
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir/missing-session-cache-keys.json"
run_case "missing session cache key: read" 3 "" "$tmpdir/missing-session-cache-keys.json"

# Invalid session token values (bool)
cp "$FIXTURE1" "$tmpdir/invalid-session-token.json"
python3 -c '
import json
import sys
data = json.load(open(sys.argv[1]))
data["info"]["tokens"]["input"] = True
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir/invalid-session-token.json"
run_case "invalid session input value" 3 "" "$tmpdir/invalid-session-token.json"

# Invalid session cache values (bool)
cp "$FIXTURE1" "$tmpdir/invalid-session-cache.json"
python3 -c '
import json
import sys
data = json.load(open(sys.argv[1]))
data["info"]["tokens"]["cache"]["read"] = False
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir/invalid-session-cache.json"
run_case "invalid session cache value" 3 "" "$tmpdir/invalid-session-cache.json"

# Missing message token keys
cp "$FIXTURE1" "$tmpdir/missing-message-keys.json"
python3 -c '
import json
import sys
data = json.load(open(sys.argv[1]))
del data["messages"][1]["info"]["tokens"]["input"]
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir/missing-message-keys.json"
run_case "missing message token key: input" 3 "" "$tmpdir/missing-message-keys.json"

# Usage error cases - exit 2
# No arguments: a direct call (run_case always passes args), with OPENCODE_USAGE_FIXTURE unset
set +e
noargs_out="$(env -u OPENCODE_USAGE_FIXTURE python3 scripts/factory-usage.py 2>"$tmpdir/stderr.txt")"
noargs_rc=$?
set -e
if [ "$noargs_rc" -eq 2 ] && [ -z "$noargs_out" ]; then
  note "no arguments and no OPENCODE_USAGE_FIXTURE"
else
  fail "no arguments and no OPENCODE_USAGE_FIXTURE (expected exit 2 and empty stdout, got $noargs_rc)"
fi
run_case "missing path" 2 "" "/nonexistent/path"

# Test secrets never appear in output
secret="sentinel-secret-value-12345"
FACTORY_TEST_SECRET="$secret" result_secret="$("${PY[@]}" "$FIXTURE1" "$FIXTURE2" 2>"$tmpdir/stderr-secret.txt")"
if echo "$result_secret" | grep -q "$secret" || grep -q "$secret" "$tmpdir/stderr-secret.txt"; then
  fail "sentinel secret appeared in output"
else
  note "no key or token printed: sentinel env value never appears in output"
fi

# ---- determinism: two successful runs match byte-for-byte ----
out_a="$tmpdir/det-a.json"
out_b="$tmpdir/det-b.json"
set +e
"${PY[@]}" "$FIXTURE1" "$FIXTURE2" >"$out_a" 2>"$tmpdir/det.err"
det_rc=$?
set -e
if [ "$det_rc" -eq 0 ]; then
  "${PY[@]}" "$FIXTURE2" "$FIXTURE1" >"$out_b" 2>/dev/null
  if cmp -s "$out_a" "$out_b" && [ "$(tr -d '\n' <"$out_a")" = "$EXPECTED_BOTH" ]; then
    note "stdout is deterministic for the same session set (order-independent)"
  else
    fail "stdout determinism (order-independent totals)"
  fi
else
  fail "determinism setup run (rc=$det_rc)"
fi

# ---- empty messages list ----
cp "$FIXTURE1" "$tmpdir/empty-msgs.json"
python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
data["messages"] = []
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir/empty-msgs.json"
run_case "empty messages list" 3 "" "$tmpdir/empty-msgs.json"

# ---- missing session id ----
cp "$FIXTURE1" "$tmpdir/no-session-id.json"
python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
del data["info"]["id"]
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir/no-session-id.json"
run_case "missing session id" 3 "" "$tmpdir/no-session-id.json"

# ---- empty JSON file ----
printf '' >"$tmpdir/empty-file.json"
run_case "empty JSON file" 3 "" "$tmpdir/empty-file.json"

# ---- top-level JSON null ----
printf 'null' >"$tmpdir/null-root.json"
run_case "top-level JSON null" 3 "" "$tmpdir/null-root.json"

# ---- stderr never contains Traceback on error paths ----
set +e
"${PY[@]}" "$tmpdir/empty-file.json" 2>"$tmpdir/tb-check.err" >/dev/null
set -e
if grep -q Traceback "$tmpdir/tb-check.err"; then
  fail "invalid input must not emit a Python traceback on stderr"
else
  note "error paths emit factory-usage messages without tracebacks"
fi

# ---- missing top-level messages key ----
cp "$FIXTURE1" "$tmpdir/no-messages-key.json"
python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
del data["messages"]
json.dump(data, open(sys.argv[1], "w"), indent=2)
' "$tmpdir/no-messages-key.json"
run_case "missing messages key" 3 "" "$tmpdir/no-messages-key.json"

# ---- invalid session cost types still yield null opencode_cost_usd when aggregated ----
cp "$FIXTURE1" "$tmpdir/bad-cost-type.json"
cp "$FIXTURE2" "$tmpdir/bad-cost-type-2.json"
python3 -c '
import json, sys
for path in sys.argv[1:]:
    data = json.load(open(path))
    for msg in data["messages"]:
        if msg.get("info", {}).get("role") == "assistant":
            msg["info"]["cost"] = "not-a-number"
    json.dump(data, open(path, "w"), indent=2)
' "$tmpdir/bad-cost-type.json" "$tmpdir/bad-cost-type-2.json"
run_case "non-numeric message cost -> opencode_cost_usd null" 0 \
  '{"models": ["deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo"], "opencode_cost_usd": null, "requests": 4, "sessions": 2, "source": "opencode-export", "tokens_cached": 8000, "tokens_in": 10000, "tokens_out": 240, "tokens_reasoning": 0}' \
  "$tmpdir/bad-cost-type.json" "$tmpdir/bad-cost-type-2.json"

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi