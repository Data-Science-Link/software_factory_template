#!/usr/bin/env bash
# Offline tests for scripts/protect-main.sh (stub gh, no live GitHub).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); cat "$work/out" 2>/dev/null; }

ref_json="$root/.github/rulesets/protect-main.json"

mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_LOG:?}"

api_line() { printf '%s\n' "$*"; }

if [ "$1" = repo ] && [ "$2" = view ]; then
  api_line "${FAKE_REPO:-org/template}"
  exit 0
fi

if [ "$1" = api ]; then
  if [ -n "${FAKE_PLAN_BLOCK:-}" ]; then
    echo "Upgrade to GitHub Pro or make this repository public" >&2
    exit 1
  fi
  case "$*" in
    *"repos/"*"/rulesets/"*)
      if [[ "$*" != *"--method"* ]]; then
        if [ -n "${FAKE_RULESET_DETAIL:-}" ]; then
          api_line "${FAKE_RULESET_DETAIL}"
          exit 0
        fi
        echo "protect-main fake: missing FAKE_RULESET_DETAIL" >&2
        exit 1
      fi
      ;;
    *"repos/"*"/rulesets"*)
      if [[ "$*" == *"--method POST"* ]] || [[ "$*" == *"--method PUT"* ]]; then
        api_line "${FAKE_RULESET_ID:-100}"
        exit 0
      fi
      if [[ "$*" == *'select(.name == "protect-main") | .id'* ]]; then
        api_line "${FAKE_RULESET_ID:-}"
        exit 0
      fi
      if [[ "$*" == *'select(.name == "protect-main")'* ]]; then
        if [ -z "${FAKE_RULESET_ID:-}" ]; then
          exit 0
        fi
        printf '{"id":%s,"name":"protect-main","enforcement":"active"}\n' "${FAKE_RULESET_ID}"
        exit 0
      fi
      ;;
  esac
  exit 0
fi

echo "fake gh: unexpected $*" >&2
exit 1
GH
chmod +x "$work/bin/gh"

compliant_detail() {
  cat "$ref_json" | jq '. + {id: 42, source: "Repository", enforcement: "active"}'
}

run_pm() { # label ... protect-main args
  local label="$1"
  shift
  : >"$work/log"
  set +e
  PATH="$work/bin:$PATH" FAKE_LOG="$work/log" FAKE_REPO=test-org/template \
    bash "$root/scripts/protect-main.sh" "$@" >"$work/out" 2>"$work/err"
  local rc=$?
  set -e
  echo "$rc" >"$work/rc"
  if [ "$rc" -eq 0 ]; then ok "$label"; else bad "$label (rc=$rc)"; fi
}

# --- default payload matches reference JSON (dry-run, no gh) ---
run_pm "dry-run default payload" --dry-run --repo org/case
if diff -u <(jq -S . "$ref_json") <(jq -S . "$work/out") >/dev/null 2>&1; then
  ok "default dry-run JSON matches protect-main.json"
else
  bad "default dry-run JSON matches protect-main.json"
  diff -u <(jq -S . "$ref_json") <(jq -S . "$work/out") || true
fi

if [ ! -s "$work/log" ]; then
  ok "dry-run makes zero gh calls"
else
  bad "dry-run makes zero gh calls (log: $(wc -l <"$work/log") lines)"
  cat "$work/log"
fi

# --- custom --checks ---
run_pm "dry-run custom checks" --dry-run --repo org/case --checks pr-check,pytest
if jq -e '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[] | select(.context=="pytest")' \
  "$work/out" >/dev/null; then
  ok "custom --checks includes pytest"
else
  bad "custom --checks includes pytest"
fi

# --- apply default (uses JSON file) ---
export FAKE_RULESET_ID=7 FAKE_PLAN_BLOCK=
run_pm "apply updates existing ruleset" --repo org/case
grep -q 'ruleset updated on org/case' "$work/out" || bad "apply success message"
grep -qF -- '--method PUT' "$work/log" && ok "PUT when ruleset exists" || bad "PUT when ruleset exists"

unset FAKE_RULESET_ID
run_pm "apply creates ruleset" --repo org/case
grep -q 'ruleset created on org/case' "$work/out" || bad "create success message"
grep -qF -- '--method POST' "$work/log" && ok "POST when no ruleset" || bad "POST when no ruleset"

# --- verify pass ---
export FAKE_RULESET_ID=42 FAKE_RULESET_DETAIL="$(compliant_detail)"
set +e
PATH="$work/bin:$PATH" FAKE_LOG="$work/log" \
  bash "$root/scripts/protect-main.sh" --verify --repo org/case >"$work/out" 2>&1
vrc=$?
set -e
if [ "$vrc" -eq 0 ] && grep -q 'verify: PASS' "$work/out"; then
  ok "verify compliant ruleset"
else
  bad "verify compliant ruleset (rc=$vrc)"
fi

# --- verify fail: bypass actors ---
bypass_json="$(compliant_detail | jq '.bypass_actors = [{"actor_id": 1, "actor_type": "User"}]')"
export FAKE_RULESET_DETAIL="$bypass_json"
set +e
PATH="$work/bin:$PATH" FAKE_LOG="$work/log" \
  bash "$root/scripts/protect-main.sh" --verify --repo org/case >"$work/out" 2>&1
vrc=$?
set -e
if [ "$vrc" -ne 0 ] && grep -q 'bypass_actors' "$work/out"; then
  ok "verify fails on bypass actors"
else
  bad "verify fails on bypass actors (rc=$vrc)"
fi

# --- verify fail: missing required check ---
missing_check_json="$(
  compliant_detail | jq '
    (.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks) =
      [{"context":"gitleaks","integration_id":15368}]
  '
)"
export FAKE_RULESET_DETAIL="$missing_check_json"
set +e
PATH="$work/bin:$PATH" FAKE_LOG="$work/log" \
  bash "$root/scripts/protect-main.sh" --verify --repo org/case >"$work/out" 2>&1
vrc=$?
set -e
if [ "$vrc" -ne 0 ] && grep -q 'checks mismatch' "$work/out"; then
  ok "verify fails on strict check mismatch"
else
  bad "verify fails on strict check mismatch (rc=$vrc)"
fi

# --- --skip ---
run_pm "skip flag" --skip
grep -q 'skipped' "$work/err" && ok "--skip message" || bad "--skip message"

echo
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]