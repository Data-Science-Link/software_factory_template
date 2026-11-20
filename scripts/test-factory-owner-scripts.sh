#!/usr/bin/env bash
# Offline tests for scripts/factory-merge.sh and scripts/factory-status.sh (#205).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); cat "$work/last.out" 2>/dev/null || true; }

mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_GH_LOG"
args=("$@")
sub="${1:-}"; cmd="${2:-}"
repo_args=()
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[i]}" = --repo ] && [ $((i+1)) -lt ${#args[@]} ]; then
    repo_args=(--repo "${args[i+1]}"); break
  fi
done

jq_field() {
  local want=""
  for ((i=0; i<${#args[@]}; i++)); do
  [ "${args[i]}" = -q ] && want="${args[i+1]}" && break
  done
  case "$want" in
    .body) cat "${FAKE_PR_BODY:-/dev/null}" ;;
    .headRefOid) printf '%s' "$FAKE_HEAD_SHA" ;;
    .headRefName) printf '%s' "$FAKE_HEAD_REF" ;;
    .state) printf '%s' "$FAKE_PR_STATE" ;;
    .mergeCommit.oid) printf '%s' "${FAKE_MERGE_SHA:-}" ;;
    .defaultBranchRef.target.oid) printf '%s' "$FAKE_MAIN_SHA" ;;
    '[.state, (.isCrossRepository|tostring), (.mergeable|tostring), .headRefOid, .headRefName] | @tsv')
      printf '%s\t%s\t%s\t%s\t%s\n' "$FAKE_PR_STATE" "$FAKE_PR_CROSS" "${FAKE_MERGEABLE:-MERGEABLE}" "$FAKE_HEAD_SHA" "$FAKE_HEAD_REF" ;;
    '[.state, (.isCrossRepository|tostring), .headRefName, .headRefOid] | @tsv')
      printf '%s\t%s\t%s\t%s\n' "$FAKE_PR_STATE" "$FAKE_PR_CROSS" "$FAKE_HEAD_REF" "$FAKE_HEAD_SHA" ;;
    *) printf '%s' "$FAKE_HEAD_SHA" ;;
  esac
}

case "$sub" in
  api)
    if printf '%s\n' "$*" | grep -q compare; then
      if [ -f "${FAKE_BEHIND_FILE:-}" ]; then cat "${FAKE_BEHIND_FILE}"; else printf '%s' "${FAKE_BEHIND:-0}"; fi
      exit 0
    fi
    echo "fake gh: unexpected $*" >&2; exit 1 ;;
  repo)
    [ "$cmd" = view ] && { jq_field; exit 0; } ;;
  run)
  case "$cmd" in
      list) cat "${FAKE_RUN_LIST_JSON:-$work/run-list.json}"; exit 0 ;;
    esac ;;
  issue)
    case "$cmd" in
      list) cat "${FAKE_ISSUE_LIST_JSON:-$work/issue-list.json}"; exit 0 ;;
      view)
        if printf '%s\n' "${args[@]}" | grep -q comments; then
          cat "${FAKE_ISSUE_COMMENTS_JSON:-$work/issue-comments.json}"; exit 0
        fi ;;
    esac ;;
  pr)
    case "$cmd" in
      view)
        if printf '%s\n' "${args[@]}" | grep -q -- '-q'; then jq_field; exit 0; fi ;;
      checks)
        if printf '%s\n' "${args[@]}" | grep -q -- '--watch'; then exit 0; fi
        if printf '%s\n' "${args[@]}" | grep -q -- '--json'; then
          cat "${FAKE_CHECKS_JSON:-$work/empty-checks.json}"
          exit "${FAKE_CHECKS_RC:-0}"
        fi ;;
      edit)
        body_file="${args[-1]}"
        cp "$body_file" "${FAKE_PR_BODY:-$work/pr-body.md}"; exit 0 ;;
      merge)
        printf '%s' "${args[@]}" | grep -q match-head-commit || { echo "missing match-head-commit" >&2; exit 1; }
        [ "${FAKE_MERGE_OK:-yes}" = yes ] || { echo "merge blocked" >&2; exit 1; }
        [ "${FAKE_MERGE_HEAD:-$FAKE_HEAD_SHA}" = "$FAKE_HEAD_SHA" ] || { echo "head mismatch" >&2; exit 1; }
        exit 0 ;;
      update-branch)
        printf '0' >"${FAKE_BEHIND_FILE:-/dev/null}"; exit 0 ;;
      list) cat "${FAKE_PR_LIST_JSON:-$work/pr-list.json}"; exit 0 ;;
    esac ;;
esac
echo "fake gh: unexpected $*" >&2; exit 1
GH
chmod +x "$work/bin/gh"

printf '[]\n' >"$work/empty-checks.json"
printf '[]\n' >"$work/pr-list.json"
printf '[]\n' >"$work/run-list.json"
printf '[]\n' >"$work/issue-list.json"
printf '{"comments":[]}\n' >"$work/issue-comments.json"

BEHIND_FILE="$work/behind.txt"
echo 0 >"$BEHIND_FILE"
SHA=0123456789abcdef0123456789abcdef01234567
MAIN=1111111111111111111111111111111111111111
MERGE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

sample_body="$work/sample-pr-body.md"
reset_body() {
  cat >"$sample_body" <<'BODY'
## Factory loop
- [ ] **6. Verify** — required CI green
- [ ] **7. Product gate** — waiting
## AI disclosure
- Human reviewed before merge: [ ] yes [ ] no — who:
Cost: $0.02 on DeepInfra (factory run record)
BODY
}
reset_body

green_checks='[{"name":"pr-check","state":"SUCCESS","bucket":"pass"},{"name":"run-records","state":"SUCCESS","bucket":"pass"},{"name":"gitleaks","state":"SUCCESS","bucket":"pass"}]'

run_merge() {
  : >"$work/last.out"
  : >"${FAKE_GH_LOG:-$work/gh.log}"
  set +e
  PATH="$work/bin:$PATH" \
    FAKE_GH_LOG="$work/gh.log" FAKE_PR_BODY="$sample_body" \
    FAKE_HEAD_SHA="$SHA" FAKE_HEAD_REF="oc/issue-205-999" FAKE_MAIN_SHA="$MAIN" \
    FAKE_PR_STATE="${FAKE_PR_STATE:-OPEN}" FAKE_PR_CROSS="${FAKE_PR_CROSS:-false}" \
    FAKE_CHECKS_JSON="$work/checks.json" FAKE_CHECKS_RC=0 FAKE_MERGE_SHA="$MERGE_SHA" \
    FAKE_BEHIND_FILE="$BEHIND_FILE" FAKE_BEHIND="${FAKE_BEHIND:-0}" FAKE_MERGE_OK="${FAKE_MERGE_OK:-yes}" \
    bash "$root/scripts/factory-merge.sh" "$@" --repo o/r >"$work/last.out" 2>&1
  rc=$?
  set -e
  printf '%s' "$rc"
}

# --- merge: usage and validation ---
rc="$(run_merge)" || true
if [ "$rc" -eq 2 ]; then ok "merge: missing args refused"; else bad "merge: missing args (rc=$rc)"; fi

rc="$(run_merge 1)" || true
if [ "$rc" -eq 2 ]; then ok "merge: missing --approval/--when refused"; else bad "merge: missing approval (rc=$rc)"; fi

FAKE_PR_STATE=MERGED
rc="$(run_merge 9 --approval 'approve #9' --when '2026-11-01 12:00')" || true
FAKE_PR_STATE=OPEN
if [ "$rc" -ne 0 ]; then ok "merge: non-open PR refused"; else bad "merge: merged state should refuse"; fi

FAKE_PR_CROSS=true
rc="$(run_merge 9 --approval 'ok' --when 't')" || true
FAKE_PR_CROSS=false
if [ "$rc" -ne 0 ]; then ok "merge: fork PR refused"; else bad "merge: fork should refuse"; fi

echo "$green_checks" >"$work/checks.json"
reset_body
echo 2 >"$BEHIND_FILE"
rc="$(run_merge 55 --approval 'lgtm' --when '2026-11-01')" || true
echo 0 >"$BEHIND_FILE"
reset_body
if [ "$rc" -ne 0 ]; then ok "merge: behind without --update refused"; else bad "merge: should refuse when behind"; fi

reset_body
echo 3 >"$BEHIND_FILE"
rc="$(run_merge 55 --approval 'lgtm' --when '2026-11-01' --update)" || true
echo 0 >"$BEHIND_FILE"
reset_body
if [ "$rc" -eq 0 ] && grep -q 'merge_commit:' "$work/last.out" && grep -q 'pr update-branch' "$work/gh.log"; then
  ok "merge: --update clears behind and merges"
else bad "merge: --update happy path (rc=$rc)"; fi

echo '[{"name":"pr-check","state":"FAILURE","bucket":"fail"},{"name":"run-records","state":"SUCCESS","bucket":"pass"},{"name":"gitleaks","state":"SUCCESS","bucket":"pass"}]' >"$work/checks.json"
rc="$(run_merge 12 --approval 'go' --when 't')" || true
echo "$green_checks" >"$work/checks.json"
if [ "$rc" -ne 0 ]; then ok "merge: red pr-check refused"; else bad "merge: should refuse red check"; fi

echo '[{"name":"pr-check","state":"PENDING","bucket":"pending"},{"name":"run-records","state":"SUCCESS","bucket":"pass"},{"name":"gitleaks","state":"SUCCESS","bucket":"pass"}]' >"$work/checks.json"
rc="$(run_merge 12 --approval 'go' --when 't')" || true
echo "$green_checks" >"$work/checks.json"
if [ "$rc" -ne 0 ]; then ok "merge: pending pr-check refused"; else bad "merge: should refuse pending"; fi

reset_body
echo "$green_checks" >"$work/checks.json"
rc="$(run_merge 12 --approval 'ship it' --when '2026-11-20 18:00')" || true
if [ "$rc" -eq 0 ] \
  && grep -q 'merge_commit: '"$MERGE_SHA" "$work/last.out" \
  && grep -q 'Human reviewed before merge: \[x\] yes' "$sample_body" \
  && grep -q 'Approval (2026-11-20 18:00 CT): "ship it"' "$sample_body"; then
  ok "merge: happy path records gate and merges"
else bad "merge: happy path (rc=$rc)"; fi

FAKE_MERGE_OK=no
rc="$(run_merge 13 --approval 'x' --when 't')" || true
FAKE_MERGE_OK=yes
if [ "$rc" -ne 0 ]; then ok "merge: gh merge failure surfaces"; else bad "merge: merge failure"; fi

# --- merge/status: --help and argument hygiene (protected scripts; test only) ---
mkdir -p "$work/emptybin"
nogh_path="$work/emptybin"
set +e
bash "$root/scripts/factory-merge.sh" 1 --help >"$work/merge-help.out" 2>&1
mhelp=$?
bash "$root/scripts/factory-status.sh" --help >"$work/status-help.out" 2>&1
shelp=$?
bash "$root/scripts/factory-merge.sh" 9 --approval x --when t --nope >"$work/last.out" 2>&1
mbad=$?
bash "$root/scripts/factory-status.sh" --nope >"$work/last.out" 2>&1
sbad=$?
set -e
if [ "$mhelp" -eq 2 ] && grep -q 'factory-merge.sh' "$work/merge-help.out"; then
  ok "merge: --help prints usage (exit 2)"
else bad "merge: --help (rc=$mhelp)"; fi
if [ "$shelp" -eq 0 ] && grep -q 'factory-status.sh' "$work/status-help.out"; then
  ok "status: --help prints usage (exit 0)"
else bad "status: --help (rc=$shelp)"; fi
if [ "$mbad" -eq 2 ] && grep -q 'unknown argument' "$work/last.out"; then
  ok "merge: unknown flag refused"
else bad "merge: unknown flag (rc=$mbad)"; fi
if [ "$sbad" -eq 2 ] && grep -q 'unknown argument' "$work/last.out"; then
  ok "status: unknown flag refused"
else bad "status: unknown flag (rc=$sbad)"; fi

shell_bash="$(command -v bash)"
run_nogh() {
  env PATH="$nogh_path" "$shell_bash" "$@"
}
set +e
run_nogh "$root/scripts/factory-merge.sh" 1 --approval a --when t --repo o/r >"$work/last.out" 2>&1
ngh_m=$?
run_nogh "$root/scripts/factory-status.sh" --repo o/r >"$work/last.out" 2>&1
ngh_s=$?
run_nogh "$root/scripts/factory-kick-checks.sh" --help >"$work/kick-help.out" 2>&1
khelp=$?
run_nogh "$root/scripts/factory-kick-checks.sh" 1 >"$work/last.out" 2>&1
ngh_k=$?
set -e
if [ "$ngh_m" -ne 0 ] && grep -qi 'gh' "$work/last.out"; then
  ok "merge: missing gh surfaces clean error"
else bad "merge: missing gh (rc=$ngh_m)"; fi
if [ "$ngh_s" -ne 0 ] && grep -qi 'gh' "$work/last.out"; then
  ok "status: missing gh surfaces clean error"
else bad "status: missing gh (rc=$ngh_s)"; fi
if [ "$khelp" -eq 0 ] && grep -q 'factory-kick-checks.sh' "$work/kick-help.out"; then
  ok "kick-checks: --help (no gh required)"
else bad "kick-checks: --help (rc=$khelp)"; fi
if [ "$ngh_k" -eq 2 ] && grep -q 'gh not found' "$work/last.out"; then
  ok "kick-checks: missing gh refused before PR logic"
else bad "kick-checks: missing gh (rc=$ngh_k)"; fi

# --- status smoke ---
printf '[{"number":1,"title":"Test","headRefOid":"%s","baseRefOid":"%s","statusCheckRollup":%s,"body":"Cost: $0.01 on DeepInfra"}]\n' \
  "$SHA" "$MAIN" "$green_checks" >"$work/pr-list.json"
printf '[{"workflowName":"opencode-spike","status":"in_progress","conclusion":"","displayTitle":"run","headBranch":"oc/issue-1-1","databaseId":42}]\n' >"$work/run-list.json"
printf '[{"number":7,"title":"Has draft"}]\n' >"$work/issue-list.json"
cat >"$work/issue-comments.json" <<'JSON'
{"comments":[{"createdAt":"2026-11-01T00:00:00Z","body":"<!-- factory-spec-draft v1 -->\nstatus: draft\n"}]}
JSON
set +e
PATH="$work/bin:$PATH" \
  FAKE_GH_LOG="$work/gh-status.log" FAKE_MAIN_SHA="$MAIN" FAKE_HEAD_SHA="$SHA" FAKE_BEHIND_FILE="$BEHIND_FILE" \
  FAKE_PR_LIST_JSON="$work/pr-list.json" FAKE_RUN_LIST_JSON="$work/run-list.json" \
  FAKE_ISSUE_LIST_JSON="$work/issue-list.json" FAKE_ISSUE_COMMENTS_JSON="$work/issue-comments.json" \
  bash "$root/scripts/factory-status.sh" --repo "o/r" >"$work/status.out" 2>&1
src=$?
set -e
if [ "$src" -eq 0 ] \
  && grep -q '^=== Open PRs ===' "$work/status.out" \
  && grep -q 'behind 0' "$work/status.out" \
  && grep -q 'opencode-spike' "$work/status.out" \
  && grep -q '#7 Has draft' "$work/status.out"; then
  ok "status: compact digest from stubbed gh"
else bad "status smoke (rc=$src)"; fi

echo
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]