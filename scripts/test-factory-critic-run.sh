#!/usr/bin/env bash
# Offline tests for scripts/factory-critic-run.py (#41).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
py="${FACTORY_PYTHON:-python3}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); cat "$work/last.log" 2>/dev/null || true; }

if ! "$py" -c "import jsonschema" 2>/dev/null; then
  echo "FAIL  jsonschema required (pip install -r requirements-factory.txt)" >&2
  exit 1
fi

ctx_out="$work/context"
"$py" scripts/factory-critic-context.py --from-json tests/critic-context/pass.json \
  --out-dir "$ctx_out" >"$work/context.log" 2>&1

MODELS=(
  "deepseek-ai/DeepSeek-V4-Flash-0731"
  "deepseek-ai/DeepSeek-V4-Pro-0813"
  "Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo"
)
for coder in "${MODELS[@]}"; do
  out="$("$py" scripts/factory-critic-run.py --print-model --coder-model "$coder" \
    --input "$ctx_out/critic-input.md" --out-dir "$work/model-$$" 2>"$work/last.log")"
  reviewer="$(printf '%s\n' "$out" | sed -n 's/^reviewer=//p')"
  if [ -n "$reviewer" ] && [ "$reviewer" != "$coder" ]; then
    ok "reviewer != coder for coder=$coder (reviewer=$reviewer)"
  else
  bad "reviewer selection for coder=$coder (got reviewer=$reviewer)"
  fi
done

# Expected reviewer for Flash coder (matches pass-with-steps fixture pattern)
exp_rev="deepseek-ai/DeepSeek-V4-Pro-0813"
got_rev="$("$py" scripts/factory-critic-run.py --print-model --coder-model "${MODELS[0]}" \
  --input "$ctx_out/critic-input.md" --out-dir "$work/x" 2>/dev/null | sed -n 's/^reviewer=//p')"
if [ "$got_rev" = "$exp_rev" ]; then
  ok "Flash coder routes reviewer to Pro"
else
  bad "Flash coder expected Pro reviewer (got $got_rev)"
fi

run_out="$work/dry"
set +e
"$py" scripts/factory-critic-run.py --dry-run \
  --input "$ctx_out/critic-input.md" --meta "$ctx_out/critic-meta.txt" \
  --coder-model "${MODELS[0]}" --out-dir "$run_out" \
  --started-at "2026-11-20T12:00:00Z" --ended-at "2026-11-20T12:00:08Z" \
  >"$work/last.log" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q 'Factory Critic review' "$run_out/critic-review.md" \
  && grep -q '"work_type": "review"' "$run_out/critic-run-record.json" \
  && "$py" scripts/factory-validate-run.py "$run_out/critic-run-record.json" >"$work/val.log" 2>&1; then
  ok "--dry-run writes review + schema-valid record"
else
  bad "--dry-run"; cat "$work/val.log" 2>/dev/null
fi

fixture_out="$work/fixture"
"$py" scripts/factory-critic-run.py \
  --input "$ctx_out/critic-input.md" --meta "$ctx_out/critic-meta.txt" \
  --coder-model "${MODELS[0]}" --out-dir "$fixture_out" \
  --fixture-response tests/critic-run/chat-completion-ok.json \
  --started-at "2026-11-20T12:01:00Z" --ended-at "2026-11-20T12:01:06Z" \
  >"$work/last.log" 2>&1
rec="$fixture_out/critic-run-record.json"
expected="$("$py" - "$rec" <<'PY'
import json, importlib.util, sys
from pathlib import Path
rec = json.loads(Path(sys.argv[1]).read_text())
spec = importlib.util.spec_from_file_location(
    "v", "scripts/factory-validate-run.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
exp = mod.cost_from_usage(
    rec["tokens_in"], rec["tokens_cached"], rec["tokens_out"],
    rec["price_in_per_mtok"], rec["price_cached_per_mtok"], rec["price_out_per_mtok"],
)
print(f"{exp:.6f}")
print(rec["actual_cost_usd"])
PY
)"
exp_cost="$(printf '%s\n' "$expected" | sed -n '1p')"
act_cost="$(printf '%s\n' "$expected" | sed -n '2p')"
cost_ok=0
if "$py" - "$exp_cost" "$act_cost" <<'PY'
import sys
sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) <= 0.0001 else 1)
PY
then cost_ok=1; fi
if [ "$cost_ok" -eq 1 ] && "$py" scripts/factory-validate-run.py "$rec" >/dev/null 2>&1 \
  && grep -q '"step_kind": "review"' "$rec"; then
  ok "fixture usage cost matches price table ($act_cost USD)"
else
  bad "fixture cost/schema (expected=$exp_cost actual=$act_cost)"
fi

set +e
env -u DEEPINFRA_API_KEY "$py" scripts/factory-critic-run.py \
  --input "$ctx_out/critic-input.md" --coder-model "${MODELS[0]}" --out-dir "$work/none" \
  >"$work/last.log" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -qi 'DEEPINFRA_API_KEY' "$work/last.log"; then
  ok "missing DEEPINFRA_API_KEY refused"
else
  bad "missing API key (rc=$rc)"
fi

port="$("$py" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
stub_log="$work/stub.log"
"$py" - "$port" <<'PY' >"$stub_log" 2>&1 &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        return

    def do_POST(self):
        if self.path.endswith("/chat/completions"):
            body = {"error": {"message": "rate limited", "type": "server_error"}}
            raw = json.dumps(body).encode()
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(raw)
        else:
            self.send_response(404)
            self.end_headers()

HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
stub_pid=$!
sleep 0.3
set +e
DEEPINFRA_API_KEY=fake-offline-key "$py" scripts/factory-critic-run.py \
  --input "$ctx_out/critic-input.md" --coder-model "${MODELS[0]}" --out-dir "$work/apierr" \
  --api-base "http://127.0.0.1:${port}/v1/openai" >"$work/last.log" 2>&1
rc=$?
set -e
kill "$stub_pid" 2>/dev/null || true
wait "$stub_pid" 2>/dev/null || true
if [ "$rc" -ne 0 ] && grep -qi 'API HTTP' "$work/last.log" \
  && [ ! -f "$work/apierr/critic-review.md" ]; then
  ok "API error exits non-zero without outputs"
else
  bad "API error handling (rc=$rc)"
fi

sentinel="critic-test-key-sentinel-88"
export DEEPINFRA_API_KEY="$sentinel"
"$py" scripts/factory-critic-run.py --dry-run \
  --input "$ctx_out/critic-input.md" --coder-model "${MODELS[0]}" --out-dir "$work/leak" \
  >"$work/last.log" 2>&1 || true
unset DEEPINFRA_API_KEY || true
if ! grep -rqF "$sentinel" "$work/leak" 2>/dev/null; then
  ok "DEEPINFRA_API_KEY not echoed in critic outputs"
else
  bad "API key leak in outputs"
fi

echo
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]