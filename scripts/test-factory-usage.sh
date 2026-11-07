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

result_null_cost="$("${PY[@]}" "$tmpdir_copy/session1.json" "$tmpdir_copy/session2.json")"
echo "$result_null_cost" | grep -q '"opencode_cost_usd": null' || fail "cost nullification"
note "one message cost removed -> opencode_cost_usd is null"

# Test cost validation function from factory-validate-run.py using importlib
python3 -c '
import sys
import importlib.util
spec = importlib.util.spec_from_file_location("factory_validate_run", "scripts/factory-validate-run.py")
module = importlib.util.module_from_spec(spec)
sys.modules["factory_validate_run"] = module
spec.loader.exec_module(module)
result = module.cost_from_usage(10000, 8000, 240, 0.30, 0.10, 1.00)
expected = 0.00164
tolerance = 1e-9
if abs(result - expected) < tolerance:
    print("PASS  cost_from_usage validation")
else:
    print("FAIL  cost_from_usage validation (expected:", expected, "got:", result, ")")
    sys.exit(1)
' || fail "cost_from_usage validation"

note "cost_from_usage validation"

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
run_case "no arguments and no OPENCODE_USAGE_FIXTURE" 2 "" ""
run_case "missing path" 2 "" "/nonexistent/path"

# Test secrets never appear in output
secret="sentinel-secret-value-12345"
FACTORY_TEST_SECRET="$secret" result_secret="$("${PY[@]}" "$FIXTURE1" "$FIXTURE2" 2>"$tmpdir/stderr-secret.txt")"
if echo "$result_secret" | grep -q "$secret" || grep -q "$secret" "$tmpdir/stderr-secret.txt"; then
  fail "sentinel secret appeared in output"
else
  note "no key or token printed: sentinel env value never appears in output"
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi