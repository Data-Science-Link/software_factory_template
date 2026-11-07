#!/usr/bin/env bash
# Test runner for scripts/factory-run-start.py
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "FAIL  PyYAML not installed; run: pip install -r requirements-factory.txt"
  exit 1
fi

PY=(python3 scripts/factory-run-start.py)
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

passed=0
failed=0

note() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }

# run_case <name> <expected_rc> <expected_grep_1> [<expected_grep_2> ...]
# runs with the env/infra already set up by the caller via the remaining args.
run_case() {
  local name="$1"
  local want_rc="$2"
  shift 2
  local want=("$@")
  set +e
  local out rc
  out="$("${PY[@]}" "${RUN_ARGS[@]}" 2>"$tmpdir/stderr.txt")"
  rc=$?
  set -e
  if [ "$rc" -ne "$want_rc" ]; then
    fail "$name (expected exit $want_rc, got $rc)"
    return
  fi
  local w
  for w in "${want[@]}"; do
    if ! printf '%s\n' "$out" | grep -Fq "$w"; then
      fail "$name (missing stdout line: $w)"
      return
    fi
  done
  note "$name"
}

# --- Case 1: approved simple normal spec, no prior runs ---
RUN_ARGS=(--spec tests/run-start/spec-approved-simple-normal.md --issue 91 \
  --runs-dir "$tmpdir/none1" --github-output "$tmpdir/case1-gh.txt")
run_case "case1 simple normal no prior -> Flash rule 3, prior 0.0000" 0 \
  "model=deepinfra/deepseek-ai/DeepSeek-V4-Flash-0731" \
  "routed_rule=3" "prior_spend_usd=0.0000"

# --- Case 2: approved high-risk spec -> Qwen3-Coder rule 1 (#128) ---
RUN_ARGS=(--spec tests/run-start/spec-approved-high-risk.md --issue 91 \
  --runs-dir "$tmpdir/none2")
run_case "case2 high risk -> Qwen3-Coder rule 1" 0 \
  "model=deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo" "routed_rule=1" "predicted_cost_usd=0.1900"

# --- Case 2b/2c: over the $0.15 target (Michael, 2026-11-07) -> refused without his flag, any risk ---
RUN_ARGS=(--spec tests/run-start/spec-approved-over-target-unflagged.md --issue 91 \
  --runs-dir "$tmpdir/none2b" --github-output "$tmpdir/case2b-gh.txt")
run_case "case2b spec predicted 0.19 over the 0.15 target, no over_target_approved_by -> refused" 3
if grep -qx "refused=over_target_unapproved" "$tmpdir/case2b-gh.txt" && ! grep -q "^model=" "$tmpdir/case2b-gh.txt" \
  && grep -q "over the \$0.15 target" "$tmpdir/stderr.txt"; then
  note "case2c over-target refusal writes refused=over_target_unapproved, no model line"
else fail "case2c over-target refusal output"; cat "$tmpdir/case2b-gh.txt" "$tmpdir/stderr.txt"; fi

# --- Case 3: spec with Qwen model and empty override reason -> re-routed to Flash ---
RUN_ARGS=(--spec tests/run-start/spec-approved-reroute-qwen.md --issue 91 \
  --runs-dir "$tmpdir/none3")
run_case "case3 spec model ignored (no override reason) -> Flash" 0 \
  "model=deepinfra/deepseek-ai/DeepSeek-V4-Flash-0731"

# --- Case 4: draft spec -> exit 3, nothing written to output file ---
: > "$tmpdir/case4-gh.txt"
: > "$tmpdir/case4-out.json"
set +e
"${PY[@]}" --spec tests/run-start/spec-draft.md --issue 91 \
  --runs-dir "$tmpdir/none4" --github-output "$tmpdir/case4-gh.txt" \
  --out "$tmpdir/case4-out.json" >"$tmpdir/case4-stdout.txt" 2>"$tmpdir/case4-stderr.txt"
rc4=$?
set -e
if [ "$rc4" -eq 3 ] \
  && [ "$(cat "$tmpdir/case4-gh.txt")" = "refused=spec_not_approved" ] \
  && [ ! -s "$tmpdir/case4-out.json" ] \
  && [ ! -s "$tmpdir/case4-stdout.txt" ]; then
  note "case4 draft spec refused, only refused=spec_not_approved written (no model line)"
else
  fail "case4 draft spec (exit $rc4; gh=$(wc -c <"$tmpdir/case4-gh.txt") out=$(wc -c <"$tmpdir/case4-out.json") stdout=$(wc -c <"$tmpdir/case4-stdout.txt"))"
fi

# --- Case 5: spec for issue 7 run with --issue 8 -> exit 3 ---
set +e
"${PY[@]}" --spec tests/run-start/spec-issue-7.md --issue 8 \
  --runs-dir "$tmpdir/none5" >/dev/null 2>"$tmpdir/case5-stderr.txt"
rc5=$?
set -e
if [ "$rc5" -eq 3 ] && grep -q "run-start: refused:" "$tmpdir/case5-stderr.txt"; then
  note "case5 wrong issue refused"
else
  fail "case5 wrong issue (exit $rc5)"
fi

# --- Case 6: prior spend from runs-dir (0.40) + trusted comment (0.30) -> 0.7000 ---
mkdir -p "$tmpdir/runs6"
cp tests/run-start/run-a.json "$tmpdir/runs6/"
RUN_ARGS=(--spec tests/run-start/spec-approved-simple-normal.md --issue 91 \
  --runs-dir "$tmpdir/runs6" --comments-json tests/run-start/comments-case6.json)
run_case "case6 runs-dir 0.40 + comment 0.30 -> prior 0.7000" 0 \
  "prior_spend_usd=0.7000"

# --- Case 7: same comment record posted by someone-else -> ignored ---
RUN_ARGS=(--spec tests/run-start/spec-approved-simple-normal.md --issue 91 \
  --runs-dir "$tmpdir/none7" --comments-json tests/run-start/comments-case7.json)
run_case "case7 untrusted comment ignored -> prior 0.0000" 0 \
  "prior_spend_usd=0.0000"

# --- Case 8: same run_id in runs-dir and trusted comment -> counted once ---
mkdir -p "$tmpdir/runs8"
cp tests/run-start/run-dup.json "$tmpdir/runs8/"
RUN_ARGS=(--spec tests/run-start/spec-approved-simple-normal.md --issue 91 \
  --runs-dir "$tmpdir/runs8" --comments-json tests/run-start/comments-case8.json)
run_case "case8 same run_id deduped -> prior 0.4000" 0 \
  "prior_spend_usd=0.4000"

# --- Case 9: prior 0.995 + predicted cost -> exit 3 with refused on stderr ---
mkdir -p "$tmpdir/runs9"
cp tests/run-start/run-995.json "$tmpdir/runs9/"
set +e
"${PY[@]}" --spec tests/run-start/spec-approved-simple-normal.md --issue 91 \
  --runs-dir "$tmpdir/runs9" >/dev/null 2>"$tmpdir/case9-stderr.txt"
rc9=$?
set -e
if [ "$rc9" -eq 3 ] && grep -q "run-start: refused:" "$tmpdir/case9-stderr.txt"; then
  note "case9 over-cap refused before spend"
else
  fail "case9 over-cap (exit $rc9)"
fi

# --- Case 10: models fixture whose token_priors push prediction over $1 -> exit 3 (rule 6) ---
set +e
"${PY[@]}" --spec tests/run-start/spec-approved-simple-normal.md --issue 91 \
  --runs-dir "$tmpdir/none10" --models tests/run-start/models-over-cap.yaml \
  >/dev/null 2>"$tmpdir/case10-stderr.txt"
rc10=$?
set -e
if [ "$rc10" -eq 3 ] && grep -q "run-start: refused:" "$tmpdir/case10-stderr.txt"; then
  note "case10 prediction over cap refused (rule 6)"
else
  fail "case10 prediction over cap (exit $rc10)"
fi

# --- Case 11: byte-identical stdout; GITHUB_RUN_ID/ATTEMPT -> run_id ---
mkdir -p "$tmpdir/runs11"
cp tests/run-start/run-a.json "$tmpdir/runs11/"
a="$("${PY[@]}" --spec tests/run-start/spec-approved-simple-normal.md --issue 91 \
  --runs-dir "$tmpdir/runs11" --comments-json tests/run-start/comments-case6.json 2>/dev/null)"
b="$("${PY[@]}" --spec tests/run-start/spec-approved-simple-normal.md --issue 91 \
  --runs-dir "$tmpdir/runs11" --comments-json tests/run-start/comments-case6.json 2>/dev/null)"
if [ "$a" = "$b" ]; then
  note "case11 byte-identical stdout for identical inputs"
else
  fail "case11 byte-identical stdout (outputs differ)"
fi
c="$(GITHUB_RUN_ID=11 GITHUB_RUN_ATTEMPT=2 "${PY[@]}" \
  --spec tests/run-start/spec-approved-simple-normal.md --issue 91 \
  --runs-dir "$tmpdir/none11" 2>/dev/null)"
if printf '%s\n' "$c" | grep -Fq "run_id=gha-11-2"; then
  note "case11 run_id from env -> gha-11-2"
else
  fail "case11 run_id from env (got: $(printf '%s\n' "$c" | grep run_id || true))"
fi

# --- Case 12: DEEPINFRA_API_KEY value appears in no output or file ---
: > "$tmpdir/case12-gh.txt"
: > "$tmpdir/case12-out.json"
secret="fake-key-run-start-123"
set +e
leak="$(DEEPINFRA_API_KEY="$secret" "${PY[@]}" \
  --spec tests/run-start/spec-approved-simple-normal.md --issue 91 \
  --runs-dir "$tmpdir/none12" --github-output "$tmpdir/case12-gh.txt" \
  --out "$tmpdir/case12-out.json" 2>&1)"
rc12=$?
set -e
if [ "$rc12" -eq 0 ] \
  && printf '%s\n' "$leak" | grep -Fq -- "$secret"; then
  fail "case12 secret leaked to stdout/stderr"
elif [ "$rc12" -ne 0 ]; then
  fail "case12 unexpected exit $rc12"
elif grep -Fq -- "$secret" "$tmpdir/case12-gh.txt" \
  || grep -Fq -- "$secret" "$tmpdir/case12-out.json"; then
  fail "case12 secret leaked to an output file"
else
  note "case12 no environment values in output or files"
fi

# --- Case 13: negative actual_cost_usd next to 0.995 -> still refused (over cap) ---
mkdir -p "$tmpdir/runs13"
cp tests/run-start/run-995.json "$tmpdir/runs13/"
cp tests/run-start/run-negative.json "$tmpdir/runs13/"
set +e
"${PY[@]}" --spec tests/run-start/spec-approved-simple-normal.md --issue 91 \
  --runs-dir "$tmpdir/runs13" >/dev/null 2>"$tmpdir/case13-stderr.txt"
rc13=$?
set -e
if [ "$rc13" -eq 3 ] && grep -q "run-start: refused:" "$tmpdir/case13-stderr.txt"; then
  note "case13 negative cost not trusted, 0.995 still over cap refused"
else
  fail "case13 negative cost over cap (exit $rc13)"
fi

# --- Case 14: non-numeric actual_cost_usd \"abc\" -> skipped, prior 0.0000, warning, exit 0 ---
mkdir -p "$tmpdir/runs14"
cp tests/run-start/run-abc.json "$tmpdir/runs14/"
set +e
"${PY[@]}" --spec tests/run-start/spec-approved-simple-normal.md --issue 91 \
  --runs-dir "$tmpdir/runs14" >"$tmpdir/case14-stdout.txt" 2>"$tmpdir/case14-stderr.txt"
rc14=$?
set -e
if [ "$rc14" -eq 0 ] \
  && grep -Fq "prior_spend_usd=0.0000" "$tmpdir/case14-stdout.txt" \
  && grep -q "warning: skipped run file" "$tmpdir/case14-stderr.txt" \
  && ! grep -q "Traceback" "$tmpdir/case14-stderr.txt"; then
  note "case14 non-numeric cost skipped cleanly, prior 0.0000"
else
  fail "case14 non-numeric cost (exit $rc14)"
fi

# ===== #92: retry / fallback context from trusted #84 failure markers =====
STD=tests/run-start/spec-approved-standard-normal.md
SIMPLE=tests/run-start/spec-approved-simple-normal.md
HIGH=tests/run-start/spec-approved-high-risk.md
C=tests/run-start
FLASH="model=deepinfra/deepseek-ai/DeepSeek-V4-Flash-0731"
PRO="model=deepinfra/deepseek-ai/DeepSeek-V4-Pro-0813"
QWEN="model=deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo"

RUN_ARGS=(--spec "$STD" --issue 91 --runs-dir "$tmpdir/none20")
run_case "case20 standard, no markers -> Flash rule 3, route_reason=default" 0 \
  "$FLASH" "routed_rule=3" "route_reason=default" "retry_of=none"

RUN_ARGS=(--spec "$STD" --issue 91 --runs-dir "$tmpdir/none21" --comments-json "$C/comments-retry-flash.json")
run_case "case21 Flash agent failure since the previous trigger, standard -> Pro rule 4 (one retry)" 0 \
  "$PRO" "routed_rule=4" "route_reason=retry_after_flash_failure" "retry_of=gha-500-1"

RUN_ARGS=(--spec "$SIMPLE" --issue 91 --runs-dir "$tmpdir/none22" --comments-json "$C/comments-retry-flash.json")
run_case "case22 Flash failure on simple work -> stays Flash (rule 4 is standard only)" 0 \
  "$FLASH" "routed_rule=3" "route_reason=default"

RUN_ARGS=(--spec "$HIGH" --issue 91 --runs-dir "$tmpdir/none23" --comments-json "$C/comments-tool-error.json")
run_case "case23 Pro tool/reasoning-format failure -> Qwen3-Coder rule 5" 0 \
  "$QWEN" "routed_rule=5" "route_reason=fallback_after_tool_error" "retry_of=gha-500-1"

# #128 (the #30 case): a high-risk build that failed on V4 Pro with error=other (worker timeout)
# is not a model-format failure, so the next run routes on the spec alone -> Qwen3-Coder rule 1.
RUN_ARGS=(--spec "$HIGH" --issue 91 --runs-dir "$tmpdir/none23b" --comments-json "$C/comments-pro-other-failed.json")
run_case "case23b Pro error=other failure on high risk -> Qwen3-Coder rule 1, default route" 0 \
  "$QWEN" "routed_rule=1" "route_reason=default" "retry_of=none"

RUN_ARGS=(--spec "$STD" --issue 91 --runs-dir "$tmpdir/none24" --comments-json "$C/comments-flash-tool-error.json")
run_case "case24 Flash tool error -> Qwen rule 5 (rule 5 is checked before rule 4)" 0 \
  "$QWEN" "routed_rule=5"

RUN_ARGS=(--spec "$STD" --issue 91 --runs-dir "$tmpdir/none25" --comments-json "$C/comments-untrusted-marker.json")
run_case "case25 failure marker not from github-actions[bot] -> ignored, Flash" 0 \
  "$FLASH" "route_reason=default"

RUN_ARGS=(--spec "$STD" --issue 91 --runs-dir "$tmpdir/none26" --comments-json "$C/comments-stale-marker.json")
run_case "case26 failure before the previous trigger (already retried) -> Flash" 0 \
  "$FLASH" "route_reason=default"

RUN_ARGS=(--spec "$STD" --issue 91 --runs-dir "$tmpdir/none27" --comments-json "$C/comments-rerun.json")
run_case "case27 re-run of the same trigger after a Flash failure -> Pro rule 4" 0 \
  "$PRO" "routed_rule=4"

RUN_ARGS=(--spec "$STD" --issue 91 --runs-dir "$tmpdir/none28" --comments-json "$C/comments-not-a-model-failure.json")
run_case "case28 refused run start, cancelled run, publish failure, error=none -> not model failures, Flash" 0 \
  "$FLASH" "route_reason=default"

RUN_ARGS=(--spec "$STD" --issue 91 --runs-dir "$tmpdir/none29" --comments-json "$C/comments-retry-flash.json" --kind fix)
run_case "case29 fix run ignores build-run markers -> Flash" 0 "$FLASH" "route_reason=default"

RUN_ARGS=(--spec "$STD" --issue 91 --runs-dir "$tmpdir/none30" --comments-json "$C/comments-fix-marker.json" --kind fix)
run_case "case30 fix run after a Flash fix failure -> Pro rule 4" 0 "$PRO" "routed_rule=4"

RUN_ARGS=(--spec "$STD" --issue 91 --runs-dir "$tmpdir/none31" --comments-json "$C/comments-fix-marker.json")
run_case "case31 build run ignores fix-run markers -> Flash" 0 "$FLASH"

RUN_ARGS=(--spec "$STD" --issue 91 --runs-dir "$tmpdir/none32" --comments-json "$C/comments-pro-retry-failed.json")
run_case "case32 the one Pro retry failed too -> no second escalation, back to Flash" 0 \
  "$FLASH" "route_reason=default"

RUN_ARGS=(--spec tests/run-start/spec-approved-spec-retry.md --issue 91 --runs-dir "$tmpdir/none33")
run_case "case33 spec-set retry/escalated_from keys are ignored (run start owns them) -> Flash" 0 \
  "$FLASH" "routed_rule=3"

RUN_ARGS=(--spec "$STD" --issue 91 --runs-dir "$tmpdir/none34" --comments-json "$C/comments-unordered.json")
run_case "case34 comments sorted by created_at before reading markers -> Pro rule 4" 0 "$PRO"

# case35: two comment files (issue + PR) are both read: spend from one, marker from the other.
RUN_ARGS=(--spec "$STD" --issue 91 --runs-dir "$tmpdir/none35" \
  --comments-json "$C/comments-case6.json" --comments-json "$C/comments-fix-marker.json" --kind fix)
run_case "case35 repeatable --comments-json: spend 0.30 + fix marker -> Pro, prior 0.3000" 0 \
  "$PRO" "prior_spend_usd=0.3000"

# case36: missing spec file -> refused=no_approved_spec, exit 3, no model line.
: > "$tmpdir/case36-gh.txt"
set +e
"${PY[@]}" --spec "$tmpdir/does-not-exist.md" --issue 91 --runs-dir "$tmpdir/none36" \
  --github-output "$tmpdir/case36-gh.txt" >/dev/null 2>"$tmpdir/case36-stderr.txt"
rc36=$?
set -e
if [ "$rc36" -eq 3 ] && [ "$(cat "$tmpdir/case36-gh.txt")" = "refused=no_approved_spec" ]; then
  note "case36 no approved spec -> exit 3, refused=no_approved_spec"
else
  fail "case36 no approved spec (exit $rc36; gh=$(cat "$tmpdir/case36-gh.txt"))"
fi

# case37: over the cap -> refused=over_cap with the numbers, no model line.
mkdir -p "$tmpdir/runs37"
cp tests/run-start/run-995.json "$tmpdir/runs37/"
: > "$tmpdir/case37-gh.txt"
set +e
"${PY[@]}" --spec "$SIMPLE" --issue 91 --runs-dir "$tmpdir/runs37" \
  --github-output "$tmpdir/case37-gh.txt" >/dev/null 2>/dev/null
rc37=$?
set -e
if [ "$rc37" -eq 3 ] && grep -qx "refused=over_cap" "$tmpdir/case37-gh.txt" \
  && grep -qx "prior_spend_usd=0.9950" "$tmpdir/case37-gh.txt" \
  && grep -qx "cap_usd=1.00" "$tmpdir/case37-gh.txt" \
  && grep -q '^predicted_cost_usd=[0-9]*\.[0-9]\{4\}$' "$tmpdir/case37-gh.txt" \
  && ! grep -q '^model' "$tmpdir/case37-gh.txt"; then
  note "case37 over cap -> refused=over_cap + prior/predicted/cap, no model output"
else
  fail "case37 over cap outputs (exit $rc37): $(tr '\n' ' ' <"$tmpdir/case37-gh.txt")"
fi

# ===== #92: scripts/factory-run-start.sh (the workflow step) with a fake gh =====
mkdir -p "$tmpdir/bin"
cat >"$tmpdir/bin/gh" <<'GH'
#!/usr/bin/env bash
# Fake gh: logs args; prints one JSON object per line from FAKE_GH_DIR/<number>.jsonl.
echo "$*" >>"${FAKE_GH_LOG:?}"
[ "${1:-}" = api ] && [ "${2:-}" = --paginate ] || { echo "fake gh: unexpected: $*" >&2; exit 1; }
n="$(sed -E 's#^repos/[^/]+/[^/]+/issues/([0-9]+)/comments$#\1#' <<<"$3")"
[ -n "${GH_TOKEN:-}" ] || { echo "fake gh: no token" >&2; exit 1; }
cat "${FAKE_GH_DIR:?}/$n.jsonl" 2>/dev/null || true
GH
chmod +x "$tmpdir/bin/gh"
mkdir -p "$tmpdir/ghd"
python3 -c 'import json,sys; [print(json.dumps(r)) for r in json.load(open(sys.argv[1]))]' "$C/comments-retry-flash.json" >"$tmpdir/ghd/91.jsonl"
python3 -c 'import json,sys; [print(json.dumps(r)) for r in json.load(open(sys.argv[1]))]' "$C/comments-fix-marker.json" >"$tmpdir/ghd/120.jsonl"

wrap() { # name kind art -> rc; output file $tmpdir/<name>.gh
  local name="$1" kind="$2" art="$3" rc=0
  : >"$tmpdir/$name.gh"; : >"$tmpdir/ghlog-$name"
  env PATH="$tmpdir/bin:$PATH" FAKE_GH_LOG="$tmpdir/ghlog-$name" FAKE_GH_DIR="$tmpdir/ghd" \
    GH_TOKEN=fake-gh-token-xyz GITHUB_REPOSITORY=o/r GITHUB_OUTPUT="$tmpdir/$name.gh" \
    OC_KIND="$kind" OC_ARTIFACT_DIR="$art" OC_ISSUE_NUMBER="${W_ISSUE:-91}" OC_PR_NUMBER="${W_PR:-120}" \
    bash scripts/factory-run-start.sh >"$tmpdir/$name.log" 2>&1 || rc=$?
  return "$rc"
}

art40="$tmpdir/art40"; mkdir -p "$art40"; cp "$STD" "$art40/spec.md"
set +e; wrap w40 build "$art40"; rc=$?; set -e
if [ "$rc" -eq 0 ] && grep -qx "model_id=deepseek-ai/DeepSeek-V4-Pro-0813" "$tmpdir/w40.gh" \
  && grep -qx "routed_rule=4" "$tmpdir/w40.gh" && grep -q 'repos/o/r/issues/91/comments' "$tmpdir/ghlog-w40" \
  && [ -s "$art40/run-start.json" ] && ! grep -rq fake-gh-token-xyz "$tmpdir/w40.log" "$tmpdir/w40.gh" "$art40"; then
  note "case40 wrapper (build): issue comments fetched, Flash failure -> Pro rule 4 in GITHUB_OUTPUT; token never printed"
else fail "case40 wrapper build (rc=$rc)"; cat "$tmpdir/w40.log"; fi

art41="$tmpdir/art41"; mkdir -p "$art41"; cp "$STD" "$art41/spec.md"
printf 'pr_number=120\nissue_number=91\nhead_ref=oc/issue-91-1\n' >"$art41/fix-meta.txt"
set +e; wrap w41 fix "$art41"; rc=$?; set -e
if [ "$rc" -eq 0 ] && grep -q 'issues/91/comments' "$tmpdir/ghlog-w41" && grep -q 'issues/120/comments' "$tmpdir/ghlog-w41" \
  && grep -qx "model_id=deepseek-ai/DeepSeek-V4-Pro-0813" "$tmpdir/w41.gh"; then
  note "case41 wrapper (fix): linked issue from fix-meta + PR comments; fix marker on the PR -> Pro"
else fail "case41 wrapper fix (rc=$rc)"; cat "$tmpdir/w41.log"; fi

art42="$tmpdir/art42"; mkdir -p "$art42"
set +e; wrap w42 build "$art42"; rc=$?; set -e
if [ "$rc" -eq 3 ] && grep -qx "refused=no_approved_spec" "$tmpdir/w42.gh" && ! grep -q '^model' "$tmpdir/w42.gh"; then
  note "case42 wrapper: no approved spec -> exit 3, refused=no_approved_spec"
else fail "case42 wrapper no spec (rc=$rc)"; cat "$tmpdir/w42.log"; fi

art43="$tmpdir/art43"; mkdir -p "$art43"; cp "$STD" "$art43/spec.md"
set +e; wrap w43 fix "$art43"; rc=$?; set -e
if [ "$rc" -eq 2 ] && [ ! -s "$tmpdir/ghlog-w43" ]; then
  note "case43 wrapper (fix) without fix-meta.txt -> exit 2 before any gh call"
else fail "case43 wrapper fix no meta (rc=$rc)"; fi

art44="$tmpdir/art44"; mkdir -p "$art44"; cp "$STD" "$art44/spec.md"
set +e; W_ISSUE='91;x' wrap w44 build "$art44"; rc=$?; set -e
if [ "$rc" -eq 2 ] && [ ! -s "$tmpdir/ghlog-w44" ]; then
  note "case44 wrapper: non-digit issue -> exit 2 before any gh call"
else fail "case44 wrapper bad issue (rc=$rc)"; fi

set +e; wrap w45 weird "$art44"; rc=$?; set -e
if [ "$rc" -eq 2 ]; then note "case45 wrapper: unknown OC_KIND -> exit 2"; else fail "case45 unknown kind (rc=$rc)"; fi

# ===== #92: scripts/factory-check-model.py and scripts/factory-classify-failure.py =====
if python3 scripts/factory-check-model.py deepseek-ai/DeepSeek-V4-Pro-0813 \
  && python3 scripts/factory-check-model.py Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo \
  && ! python3 scripts/factory-check-model.py openai/gpt-5 2>/dev/null \
  && ! python3 scripts/factory-check-model.py 'deepinfra/deepseek-ai/DeepSeek-V4-Pro-0813' 2>/dev/null \
  && ! python3 scripts/factory-check-model.py 'x;rm' 2>/dev/null \
  && ! python3 scripts/factory-check-model.py '' 2>/dev/null; then
  note "case50 check-model: listed deepinfra ids pass; unlisted, prefixed, odd shapes refused"
else fail "case50 check-model"; fi

printf 'step\nSchemaError(Missing key filePath)\nSchemaError(Missing key filePath)\nok\nError: SchemaError again\n' >"$tmpdir/log-tool.txt"
printf 'step\nSchemaError once\nsomething else broke\n' >"$tmpdir/log-other.txt"
: >"$tmpdir/cls.gh"
a="$(python3 scripts/factory-classify-failure.py --log "$tmpdir/log-tool.txt" --github-output "$tmpdir/cls.gh")"
b="$(python3 scripts/factory-classify-failure.py --log "$tmpdir/log-other.txt")"
c="$(python3 scripts/factory-classify-failure.py --log "$tmpdir/missing.log")"
if [ "$a" = "error_class=tool_or_reasoning_format" ] && [ "$b" = "error_class=other" ] \
  && [ "$c" = "error_class=other" ] && [ "$(cat "$tmpdir/cls.gh")" = "error_class=tool_or_reasoning_format" ]; then
  note "case51 classify-failure: 3+ tool/schema error lines -> tool_or_reasoning_format; else or no log -> other"
else fail "case51 classify-failure (a=$a b=$b c=$c)"; fi

# ===== #92 round trip: the marker opencode-notify-failure.sh posts is the one run start reads =====
mkdir -p "$tmpdir/nbin"
cat >"$tmpdir/nbin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$2" = --paginate ]; then echo '[]'; exit 0; fi
while [ $# -gt 0 ]; do [ "$1" = --input ] && cp "$2" "${FAKE_POST:?}"; shift; done
GH
chmod +x "$tmpdir/nbin/gh"
env PATH="$tmpdir/nbin:$PATH" FAKE_POST="$tmpdir/post.json" GH_TOKEN=x GITHUB_REPOSITORY=o/r \
  OC_KIND=build OC_TARGET_NUMBER=91 OC_RUN_ID=777 OC_RUN_ATTEMPT=1 OC_AGENT_RESULT=failure OC_PUBLISH_RESULT=skipped \
  OC_MODEL_ID=deepseek-ai/DeepSeek-V4-Flash-0731 OC_ROUTED_RULE=3 OC_ERROR_CLASS=other \
  bash scripts/opencode-notify-failure.sh >/dev/null 2>&1
python3 - "$tmpdir/post.json" "$tmpdir/rt.json" <<'PYRT'
import json, sys
body = json.load(open(sys.argv[1]))["body"]
rows = [
    {"user": {"login": "Data-Science-Link"}, "author_association": "OWNER", "created_at": "2026-11-03T01:00:00Z", "body": "/oc go"},
    {"user": {"login": "github-actions[bot]"}, "author_association": "NONE", "created_at": "2026-11-03T02:00:00Z", "body": body},
    {"user": {"login": "Data-Science-Link"}, "author_association": "OWNER", "created_at": "2026-11-03T03:00:00Z", "body": "/oc again"},
]
json.dump(rows, open(sys.argv[2], "w"))
PYRT
RUN_ARGS=(--spec "$STD" --issue 91 --runs-dir "$tmpdir/none52" --comments-json "$tmpdir/rt.json")
run_case "case52 round trip: notify's real marker for a Flash failure -> next run start routes Pro rule 4" 0 \
  "$PRO" "routed_rule=4" "retry_of=gha-777-1"

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
