#!/usr/bin/env bash
# Offline tests for scripts/factory-selected-dispatch.py (#111).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

passed=0
failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); cat "$work/last.out" 2>/dev/null || true; }

PY="$root/scripts/factory-selected-dispatch.py"
MODELS="$root/.factory/models.yaml"
RUNS="$work/runs"
mkdir -p "$RUNS"

approved_body="$work/approved.md"
{
  echo '<!-- factory-spec v1 -->'
  sed 's/^issue: 91/issue: 111/' "$root/tests/run-start/spec-approved-simple-normal.md"
  echo '## Bad inputs and edge cases'
  echo 'fixture edges'
} >"$approved_body"

draft_body="$work/draft.md"
cat >"$draft_body" <<'EOF'
<!-- factory-spec-draft v1 -->
---
issue: 111
status: draft
risk: normal
complexity: simple
---
## Outcome
draft
EOF

high_draft="$work/high-draft.md"
cat >"$high_draft" <<'EOF'
<!-- factory-spec-draft v1 -->
---
issue: 111
status: draft
risk: high
complexity: standard
---
## Outcome
high
EOF

mkdir -p "$work/ctx"
printf '## Issue\nfixture\n' >"$work/ctx/issue-context.md"
printf 'factory:selected\n' >"$work/ctx/issue-labels.txt"

issue_json() {
  jq -n '{number: 111, labels: [{name: "factory:selected"}]}' >"$work/issue.json"
}

comments_file() {
  jq -n --argjson c "$1" '{comments: $c}' >"$work/comments.json"
}

mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'GH'
#!/usr/bin/env bash
args=("$@")
sub="${1:-}"; cmd="${2:-}"
case "$sub" in
  api)
    if [[ "${args[*]}" == *".owner.login"* ]]; then
      printf '%s' "${FAKE_OWNER_LOGIN:-owner-user}"
      exit 0
    fi
    echo "fake gh: unexpected api $*" >&2; exit 1 ;;
  issue)
    if [ "$cmd" = comment ]; then
      cp "${args[-1]}" "${FAKE_POSTED_BODY:-/tmp/posted.md}"
      exit 0
    fi ;;
esac
echo "fake gh: unexpected $*" >&2; exit 1
GH
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"
export FAKE_OWNER_LOGIN=owner-user

run_a() {
  local actor="$1" label="$2"
  shift 2
  : >"$work/last.out"
  set +e
  python3 "$PY" phase-a --issue 111 --repo o/r --actor "$actor" --label "$label" \
    --owner-login owner-user \
    --issue-json "$work/issue.json" \
    --comments-json "$work/comments.json" \
    --context "$work/ctx/issue-context.md" \
    --labels "$work/ctx/issue-labels.txt" \
    --runs-dir "$RUNS" --models "$MODELS" \
    "$@" >"$work/last.out" 2>&1
  rc=$?
  set -e
  printf '%s' "$rc"
}

run_b() {
  : >"$work/last.out"
  set +e
  python3 "$PY" phase-b --issue 111 --repo o/r --owner-login owner-user \
    --issue-json "$work/issue.json" \
    --comments-json "$work/comments.json" \
    --runs-dir "$RUNS" --models "$MODELS" \
    "$@" >"$work/last.out" 2>&1
  rc=$?
  set -e
  printf '%s' "$rc"
}

issue_json
comments_file '[]'

# --- non-owner ---
rc="$(run_a not-owner factory:selected)"
if [ "$rc" -eq 0 ] && grep -q 'ignored (actor' "$work/last.out"; then
  ok "label from non-owner does nothing"
else bad "non-owner (rc=$rc)"; fi

# --- owner spec kick ---
export FAKE_POSTED_BODY="$work/post-a.md"
rc="$(run_a owner-user factory:selected)"
if [ "$rc" -eq 0 ] && head -1 "$work/post-a.md" | grep -q '^/oc spec'; then
  ok "owner label starts exactly one spec kick"
else bad "owner spec (rc=$rc)"; fi

kick="$(cat "$work/post-a.md")"
comments_file "$(jq -n --arg b "$kick" '[{id: 1, user: {login: "owner-user"}, author_association: "OWNER", body: $b, created_at: "2026-11-01T00:00:00Z"}]')"
rc="$(run_a owner-user factory:selected)"
if [ "$rc" -eq 0 ] && grep -q 'spec kick already posted' "$work/last.out"; then
  ok "duplicate label does not double-start spec"
else bad "spec idempotency (rc=$rc)"; fi

# --- cap blocks spec ---
comments_file '[]'
jq -n '{issue: 111, run_id: "r1", actual_cost_usd: 0.996}' >"$RUNS/near-cap.json"
rc="$(run_a owner-user factory:selected)"
if [ "$rc" -eq 3 ] && grep -q 'refused: prior' "$work/last.out"; then
  ok "per-issue cap blocks spec dispatch"
else bad "spec cap (rc=$rc)"; fi
rm -f "$RUNS/near-cap.json"

# --- phase-b: approved normal -> run kick ---
comments_file "$(jq -n --rawfile a "$approved_body" '[{id: 2, user: {login: "owner-user"}, author_association: "OWNER", body: $a, created_at: "2026-11-01T02:00:00Z"}]')"
export FAKE_POSTED_BODY="$work/post-b.md"
rc="$(run_b)"
if [ "$rc" -eq 0 ] && head -1 "$work/post-b.md" | grep -q '^/oc run'; then
  ok "approved normal spec posts one /oc run kick"
else bad "run kick (rc=$rc)"; fi

run_kick="$(cat "$work/post-b.md")"
comments_file "$(jq -n --rawfile a "$approved_body" --arg r "$run_kick" \
  '[{id: 2, user: {login: "owner-user"}, author_association: "OWNER", body: $a, created_at: "2026-11-01T02:00:00Z"},
    {id: 3, user: {login: "owner-user"}, author_association: "OWNER", body: $r, created_at: "2026-11-01T03:00:00Z"}]')"
rc="$(run_b)"
if [ "$rc" -eq 0 ] && grep -q 'run kick already posted' "$work/last.out"; then
  ok "duplicate phase-b does not double-start run"
else bad "run idempotency (rc=$rc)"; fi

# --- high risk waits ---
hd="$(cat "$high_draft")"
comments_file "$(jq -n --arg d "$hd" '[{id: 10, user: {login: "github-actions[bot]"}, body: $d, created_at: "2026-11-02T00:00:00Z"}]')"
export FAKE_POSTED_BODY="$work/post-wait.md"
rc="$(run_b)"
if [ "$rc" -eq 0 ] && grep -q 'factory-selected-wait-high' "$work/post-wait.md" && ! grep -q '^/oc run' "$work/post-wait.md"; then
  ok "high-risk draft waits; no build run"
else bad "high risk wait (rc=$rc)"; fi

# --- auto-approve path (dry-run) ---
db="$(cat "$draft_body")"
comments_file "$(jq -n --arg d "$db" '[{id: 20, user: {login: "github-actions[bot]"}, body: $d, created_at: "2026-11-03T00:00:00Z"}]')"
rc="$(run_b --dry-run)"
if [ "$rc" -eq 0 ] && grep -q 'would approve draft' "$work/last.out"; then
  ok "normal draft auto-approve path (dry-run)"
else bad "auto-approve (rc=$rc)"; fi

# --- cap blocks run ---
comments_file "$(jq -n --rawfile a "$approved_body" '[{id: 2, user: {login: "owner-user"}, author_association: "OWNER", body: $a, created_at: "2026-11-01T02:00:00Z"}]')"
jq -n '{issue: 111, run_id: "r2", actual_cost_usd: 0.996}' >"$RUNS/near-cap2.json"
FAKE_POSTED_BODY="$work/post-cap.md"
rc="$(run_b)"
if [ "$rc" -eq 3 ] && grep -q 'refused run start' "$work/last.out"; then
  ok "cap blocks run dispatch"
else bad "run cap (rc=$rc)"; fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]