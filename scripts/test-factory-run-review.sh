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
# (headBranch main) plus the later opencode-fix run and the opencode-spec run for
# the linked issue (headBranch main, title matching `#136`) while excluding an
# unrelated build run. The spec run's tokens/cost are populated from its
# downloaded artifacts.
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
  grep -q '"workflow": "opencode-spec"' "$tmpdir/out-live.json" || live_ok=0
  grep -q '"run_id": 42291111111' "$tmpdir/out-live.json" || live_ok=0
  grep -q '"cost_usd": 0.0015' "$tmpdir/out-live.json" || live_ok=0
  grep -q '"in": 40000' "$tmpdir/out-live.json" || live_ok=0
  grep -q '"run_id": 42293333333' "$tmpdir/out-live.json" && live_ok=0
  grep -q '"scan_result": null' "$tmpdir/out-live.json" && live_ok=0
  if [ "$live_ok" -eq 1 ]; then
    note "live-path parser (spec run selected, tokens/cost populated from artifacts)"
  else
    fail "live-path parser (spec run selection/tokens/cost not populated from artifacts)"
  fi
fi

# Run-record path: a recorded #31 issue comment is enough to select the run
# and populate model, cost, tokens and gate without calling gh.
records_dir="$FIX_DIR/records"
set +e
"${REVIEW[@]}" --live-dir "$records_dir" > "$tmpdir/out-records.json" 2>"$tmpdir/err-records.txt"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "run-record parser (script exited non-zero)"
else
  rec_ok=1
  grep -q '"run_id": 42752519540' "$tmpdir/out-records.json" || rec_ok=0
  grep -q '"model": "deepseek-ai/DeepSeek-V4-Pro-0813"' "$tmpdir/out-records.json" || rec_ok=0
  grep -q '"cost_usd": 0.088174' "$tmpdir/out-records.json" || rec_ok=0
  grep -q '"workflow": "opencode-spec"' "$tmpdir/out-records.json" || rec_ok=0
  grep -q '"gate_passed": false' "$tmpdir/out-records.json" || rec_ok=0
  grep -q '"in": 192940' "$tmpdir/out-records.json" || rec_ok=0
  if [ "$rec_ok" -eq 1 ]; then
    note "run-record parser (model/cost/gate/tokens from comment)"
  else
    fail "run-record parser (model/cost/gate/tokens not populated from record)"
  fi
fi

# Fallback path: nested `gh run download` layout, cost from usage-metrics.md,
# scan from the artifact-scan log line, fix run matched by displayTitle while
# headBranch is main; skipped sibling runs stay excluded.
fallback_dir="$FIX_DIR/fallback"
set +e
"${REVIEW[@]}" --live-dir "$fallback_dir" > "$tmpdir/out-fallback.json" 2>"$tmpdir/err-fallback.txt"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "fallback parser (script exited non-zero)"
else
  fb_ok=1
  grep -q '"run_id": 42709151046' "$tmpdir/out-fallback.json" || fb_ok=0
  grep -q '"run_id": 42709632565' "$tmpdir/out-fallback.json" || fb_ok=0
  grep -q '"run_id": 42733844876' "$tmpdir/out-fallback.json" && fb_ok=0
  grep -q '"run_id": 42736079295' "$tmpdir/out-fallback.json" && fb_ok=0
  grep -q '"cost_usd": 0.0037' "$tmpdir/out-fallback.json" || fb_ok=0
  grep -q '"cost_usd": 0.0013' "$tmpdir/out-fallback.json" || fb_ok=0
  grep -q 'DeepSeek-V4-Flash-0731' "$tmpdir/out-fallback.json" || fb_ok=0
  grep -q '"scan_result": "pass"' "$tmpdir/out-fallback.json" || fb_ok=0
  grep -q '"routing_rule": 3' "$tmpdir/out-fallback.json" || fb_ok=0
  if [ "$fb_ok" -eq 1 ]; then
    note "fallback parser (nested artifacts, usage-metrics, displayTitle)"
  else
    fail "fallback parser (model/cost/scan/selection not populated)"
  fi
fi

# Token-less broken case: an opencode-spec run for the linked issue with no
# artifact or record carrying tokens is still selected, but its tokens stay
# JSON null and the rendered output says "unavailable" instead of a fabricated
# number.
tokenless_dir="$FIX_DIR/tokenless"
set +e
"${REVIEW[@]}" --live-dir "$tokenless_dir" > "$tmpdir/out-tokenless.json" 2>"$tmpdir/err-tokenless.txt"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "token-less broken case (script exited non-zero)"
else
  tl_ok=1
  grep -q '"run_id": 42295555555' "$tmpdir/out-tokenless.json" || tl_ok=0
  grep -q '"in": null' "$tmpdir/out-tokenless.json" || tl_ok=0
  grep -q '"longest_gap_seconds": null' "$tmpdir/out-tokenless.json" || tl_ok=0
  grep -q 'seconds/tool turn: unavailable, longest gap: unavailable' "$tmpdir/out-tokenless.json" || tl_ok=0
  grep -q 'unavailables' "$tmpdir/out-tokenless.json" && tl_ok=0
  grep -q '"in": 40000' "$tmpdir/out-tokenless.json" && tl_ok=0
  grep -q '"tool_counts": {}' "$tmpdir/out-tokenless.json" || tl_ok=0
  grep -q '"artifacts_unavailable": true' "$tmpdir/out-tokenless.json" || tl_ok=0
  grep -q -- '- artifacts unavailable' "$tmpdir/out-tokenless.json" || tl_ok=0
  if [ "$tl_ok" -eq 1 ]; then
    note "token-less broken case (no tool data, tokens/gap null, rendered unavailable, artifacts-unavailable marker present, no stray suffix)"
  else
    fail "token-less broken case (fabricated or not reported unavailable)"
  fi
fi

# Real-log/session fixture: a live-style run (42951547485) whose artifact
# carries usage/session-1.json with structured tool parts reports non-empty
# tool_counts matching the session JSON's per-tool counts, non-null per-turn
# timing where the part timestamps support it, and the real permission-denied
# `ls` from its log.txt in blocked_calls. A second run (42951547486) with only a
# real-format log.txt (→ Read / ✱ Glob / ✗ Bash ... failed, with ANSI codes) and
# no session JSON still populates tool_counts via the log fallback.
reallog_dir="$FIX_DIR/reallog/live"
set +e
"${REVIEW[@]}" --live-dir "$reallog_dir" > "$tmpdir/out-reallog.json" 2>"$tmpdir/err-reallog.txt"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "real-log/session parser (script exited non-zero)"
else
  # Parse the JSON with python3 and assert exact per-run values, so a count like
  # "edit": 1 can never accidentally match "edit": 10 (grep substring matching).
  if python3 - "$tmpdir/out-reallog.json" <<'PY'
import json, sys
# stdout is the JSON document followed by the rendered markdown review, so parse
# only the first JSON document rather than the whole stream.
raw = open(sys.argv[1]).read()
data, _ = json.JSONDecoder().raw_decode(raw)
runs = {r["run_id"]: r for r in data["runs"]}
# Session-JSON run: counts match the session JSON, per-turn timing non-null,
# and the real permission-denied ls is recorded in blocked_calls.
s = runs[42951547485]
assert s["tool_counts"] == {
    "read": 34, "edit": 10, "write": 9, "bash": 4, "glob": 3, "grep": 3
}, s["tool_counts"]
assert s["seconds_per_tool_turn"] == 2.0, s["seconds_per_tool_turn"]
assert s["longest_gap_seconds"] == 2.0, s["longest_gap_seconds"]
assert any(
    "ls -la tests/factory-run-review/reallog/live" in c for c in s["blocked_calls"]
), s["blocked_calls"]
# Log-fallback run (no session JSON): counts populated from real log lines, and
# with no usable timestamps its per-turn timing stays JSON null (not fabricated).
f = runs[42951547486]
assert f["tool_counts"] == {
    "read": 2, "edit": 1, "write": 1, "bash": 2, "glob": 2, "grep": 1
}, f["tool_counts"]
assert f["seconds_per_tool_turn"] is None, f["seconds_per_tool_turn"]
assert f["longest_gap_seconds"] is None, f["longest_gap_seconds"]
PY
  then
    note "real-log/session parser (session tool counts + timing, denied ls, log fallback)"
  else
    fail "real-log/session parser (tool counts/timing/blocked calls not populated)"
  fi
fi

# False-positive regression: a live-style run (43052631438) whose log.txt echoes
# the OC_INSTRUCTION env line (which quotes the permission-denial text and uses
# the words denied/blocked/guardrail) and a StepSecurity harden-runner
# "denied_endpoints" config line, with no real agent denial, must report
# blocked_calls: [] and no blocked_call finding.
falsepos_dir="$FIX_DIR/falsepos/live"
set +e
"${REVIEW[@]}" --live-dir "$falsepos_dir" > "$tmpdir/out-falsepos.json" 2>"$tmpdir/err-falsepos.txt"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "false-positive regression (script exited non-zero)"
elif python3 - "$tmpdir/out-falsepos.json" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
data, _ = json.JSONDecoder().raw_decode(raw)
runs = {r["run_id"]: r for r in data["runs"]}
r = runs[43052631438]
assert r["blocked_calls"] == [], r["blocked_calls"]
assert not any(f["code"] == "blocked_call" for f in r["findings"]), r["findings"]
PY
then
  note "false-positive regression (echoed OC_INSTRUCTION + harden-runner denied_endpoints produce blocked_calls: [])"
else
  fail "false-positive regression (blocked_calls not empty / blocked_call finding present)"
fi

# Denied session fixture: run 43069209256 whose session export has one errored
# bash tool part carrying the permission-denial text and the `find` command,
# while its log.txt is a workflow-style log with no denial text. Only
# session-export parsing (not the log.txt scan) can surface the denied find.
denied_dir="$FIX_DIR/denied/live"
set +e
"${REVIEW[@]}" --live-dir "$denied_dir" > "$tmpdir/out-denied.json" 2>"$tmpdir/err-denied.txt"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "denied session fixture (script exited non-zero)"
elif python3 - "$tmpdir/out-denied.json" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
data, _ = json.JSONDecoder().raw_decode(raw)
runs = {r["run_id"]: r for r in data["runs"]}
r = runs[43069209256]
assert any(
    "find tests/factory-run-review -type f | sort" in c for c in r["blocked_calls"]
), r["blocked_calls"]
assert any(f["code"] == "blocked_call" for f in r["findings"]), r["findings"]
PY
then
  note "denied session fixture (run 43069209256 lists the blocked find command in blocked_calls; log.txt has no denial)"
else
  fail "denied session fixture (blocked find not reported)"
fi

# opencode.log fallback: session-less run 43069209257 whose blocked find lives
# only in oc-artifacts-43069209257/opencode.log. Its log.txt has no denial text.
denied_log_dir="$FIX_DIR/denied-log/live"
set +e
"${REVIEW[@]}" --live-dir "$denied_log_dir" > "$tmpdir/out-denied-log.json" 2>"$tmpdir/err-denied-log.txt"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "opencode.log fallback (script exited non-zero)"
elif python3 - "$tmpdir/out-denied-log.json" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
data, _ = json.JSONDecoder().raw_decode(raw)
runs = {r["run_id"]: r for r in data["runs"]}
r = runs[43069209257]
assert any(
    "find tests/factory-run-review -type f | sort" in c for c in r["blocked_calls"]
), r["blocked_calls"]
assert any(f["code"] == "blocked_call" for f in r["findings"]), r["findings"]
PY
then
  note "opencode.log fallback (session-less run 43069209257 lists the blocked find command from oc-artifacts-43069209257/opencode.log)"
else
  fail "opencode.log fallback (blocked find not reported)"
fi

# Artifacts-unavailable marker: unavailable/live has no artifacts/ directory, so
# the review must emit the marker instead of silent empties.
unavailable_dir="$FIX_DIR/unavailable/live"
set +e
"${REVIEW[@]}" --live-dir "$unavailable_dir" > "$tmpdir/out-unavailable.json" 2>"$tmpdir/err-unavailable.txt"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "artifacts-unavailable marker (script exited non-zero)"
else
  ua_ok=1
  grep -q '"run_id": 43069209399' "$tmpdir/out-unavailable.json" || ua_ok=0
  grep -q '"artifacts_unavailable": true' "$tmpdir/out-unavailable.json" || ua_ok=0
  grep -q -- '- artifacts unavailable' "$tmpdir/out-unavailable.json" || ua_ok=0
  if [ "$ua_ok" -eq 1 ]; then
    note "artifacts-unavailable marker (unavailable/live, missing artifact dir, emits artifacts unavailable)"
  else
    fail "artifacts-unavailable marker (not emitted for missing artifact dir)"
  fi
fi

# Negative session parts: run 43069209301 (bash tool part with non-error status)
# and run 43069209302 (error without the permission-denial text) both produce
# blocked_calls: [] and no blocked_call finding, even though their log.txt files
# are workflow-style logs with no denial text.
denied_neg_dir="$FIX_DIR/denied-neg/live"
set +e
"${REVIEW[@]}" --live-dir "$denied_neg_dir" > "$tmpdir/out-denied-neg.json" 2>"$tmpdir/err-denied-neg.txt"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "negative session parts (script exited non-zero)"
elif python3 - "$tmpdir/out-denied-neg.json" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
data, _ = json.JSONDecoder().raw_decode(raw)
runs = {r["run_id"]: r for r in data["runs"]}
r1 = runs[43069209301]
r2 = runs[43069209302]
assert r1["blocked_calls"] == [], r1["blocked_calls"]
assert r2["blocked_calls"] == [], r2["blocked_calls"]
assert not any(f["code"] == "blocked_call" for f in r1["findings"]), r1["findings"]
assert not any(f["code"] == "blocked_call" for f in r2["findings"]), r2["findings"]
PY
then
  note "negative session parts (run 43069209301 non-error status and run 43069209302 error without denial text both produce blocked_calls: [])"
else
  fail "negative session parts (blocked_calls not empty / blocked_call finding present)"
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
