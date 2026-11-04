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

# --- Case 2: approved high-risk spec -> Pro rule 1 ---
RUN_ARGS=(--spec tests/run-start/spec-approved-high-risk.md --issue 91 \
  --runs-dir "$tmpdir/none2")
run_case "case2 high risk -> Pro rule 1" 0 \
  "model=deepinfra/deepseek-ai/DeepSeek-V4-Pro-0813" "routed_rule=1"

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
  && [ ! -s "$tmpdir/case4-gh.txt" ] \
  && [ ! -s "$tmpdir/case4-out.json" ] \
  && [ ! -s "$tmpdir/case4-stdout.txt" ]; then
  note "case4 draft spec refused, no outputs written"
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

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
