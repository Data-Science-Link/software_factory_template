#!/usr/bin/env bash
# Offline end-to-end simulation: fresh product repo adoption journey (Refs #178, #156, #182).
# No network; temp git repo and dirs cleaned via trap.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PYTHON="${FACTORY_PYTHON:-python3}"
TAG="v0.1.0"
FIXTURE_RUNS="$ROOT/tests/factory-cost-digest/fixture-runs"
AS_OF="2026-11-20"

passed=0
failed=0
work=""
tmpdir=""

cleanup() {
  [ -n "$work" ] && rm -rf "$work"
  [ -n "$tmpdir" ] && rm -rf "$tmpdir"
}
trap cleanup EXIT

pass() { echo "PASS  $1"; passed=$((passed + 1)); }
fail() { echo "FAIL  $1"; failed=$((failed + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | head -12; }

if ! "$PYTHON" -c "import yaml" 2>/dev/null; then
  echo "PyYAML is required (pip install -r requirements-factory.txt)" >&2
  exit 2
fi

work="$(mktemp -d)"
tmpdir="$(mktemp -d)"
repo="$work/adopter-product"

# ---- Step 1: empty temp git repo with sample product code ----
if git init -q "$repo" \
  && mkdir -p "$repo/src" \
  && printf '%s\n' '"""Sample product entrypoint."""' 'def main() -> None:' '    print("ok")' 'if __name__ == "__main__":' '    main()' >"$repo/src/app.py" \
  && git -C "$repo" add src/app.py \
  && git -C "$repo" -c user.email=adopter@example.invalid -c user.name=adopter commit -q -m "initial product skeleton"; then
  pass "step 1: temp git repo with src/app.py"
else
  fail "step 1: temp git repo with src/app.py"
fi

# ---- Step 2: factory-init-repo.py ----
set +e
init_out="$("$PYTHON" "$ROOT/scripts/factory-init-repo.py" \
  --target "$repo" \
  --tag "$TAG" \
  --template-dir "$ROOT" \
  --repo-name adopter-product 2>&1)"
init_rc=$?
set -e
if [ "$init_rc" -eq 0 ]; then
  pass "step 2: factory-init-repo.py exit 0"
else
  fail "step 2: factory-init-repo.py exit 0" "$init_out"
fi

init_checks_ok=1
for rel in .factory/mode.yml .factory/DECISIONS.md .factory/models.yaml AGENTS.md; do
  if [ ! -f "$repo/$rel" ]; then
    init_checks_ok=0
    fail "step 2: scaffold missing $rel"
  fi
done
if [ "$init_checks_ok" -eq 1 ]; then
  mode="$("$PYTHON" -c "import yaml; print(yaml.safe_load(open('$repo/.factory/mode.yml'))['mode'])")"
  if [ "$mode" = product ]; then
    pass "step 2: .factory/mode.yml mode product"
  else
    fail "step 2: .factory/mode.yml mode product (got $mode)"
  fi
  if grep -q "Adopted Software Factory" "$repo/.factory/DECISIONS.md"; then
    pass "step 2: .factory/DECISIONS.md adoption entry"
  else
    fail "step 2: .factory/DECISIONS.md adoption entry"
  fi
fi

# ---- Step 3: factory-doctor.py (JSON scorecard, no --strict) ----
doctor_json="$tmpdir/doctor.json"
set +e
"$PYTHON" "$ROOT/scripts/factory-doctor.py" --repo-dir "$repo" --json >"$doctor_json" 2>"$tmpdir/doctor.err"
doctor_rc=$?
set -e
if [ "$doctor_rc" -eq 0 ] && [ ! -s "$tmpdir/doctor.err" ]; then
  pass "step 3: factory-doctor.py clean exit"
else
  fail "step 3: factory-doctor.py clean exit" "$(cat "$tmpdir/doctor.err" 2>/dev/null; cat "$doctor_json" 2>/dev/null)"
fi
if "$PYTHON" - "$doctor_json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
assert data.get("repo_dir")
for key in ("pass", "warn", "fail", "skip"):
    assert key in data.get("summary", {}), key
checks = data.get("checks")
assert isinstance(checks, list) and checks, "checks"
for c in checks:
    assert c.get("status") in ("pass", "warn", "fail", "skip")
print("ok")
PY
then
  pass "step 3: doctor JSON parseable"
else
  fail "step 3: doctor JSON parseable"
fi

# ---- Step 4: factory-spec-lint.py product mode ----
spec_ok="$tmpdir/spec-ok.md"
spec_bad="$tmpdir/spec-bad.md"
cat >"$spec_ok" <<'EOF'
---
issue: 182
title: Update app entrypoint
risk: trivial
complexity: simple
---
## Context
Touch the sample product file after factory adoption.

## Files
- Modify: `src/app.py`

## Bad inputs and edge cases
- Missing src/app.py should fail product tests.

## Verification
```bash
set -euo pipefail
true
```
EOF

cat >"$spec_bad" <<'EOF'
---
issue: 182
title: Forbidden factory script
risk: normal
complexity: standard
---
## Context
Product specs must not create factory scripts locally.

## Files
- Create: `scripts/evil.sh`

## Bad inputs and edge cases
- Rejected by path policy.

## Verification
```bash
true
```
EOF

set +e
"$PYTHON" "$ROOT/scripts/factory-spec-lint.py" --mode product "$spec_ok" >/dev/null 2>&1
lint_ok_rc=$?
"$PYTHON" "$ROOT/scripts/factory-spec-lint.py" --mode product "$spec_bad" >/dev/null 2>&1
lint_bad_rc=$?
set -e
[ "$lint_ok_rc" -eq 0 ] && pass "step 4: spec-lint valid src/app.py" || fail "step 4: spec-lint valid src/app.py"
[ "$lint_bad_rc" -ne 0 ] && pass "step 4: spec-lint forbidden scripts/evil.sh" || fail "step 4: spec-lint forbidden scripts/evil.sh"

# ---- Step 5: factory-cost-digest.py fixture runs ----
digest_json="$tmpdir/digest.json"
set +e
"$PYTHON" "$ROOT/scripts/factory-cost-digest.py" \
  --runs-dir "$FIXTURE_RUNS" \
  --models-file "$repo/.factory/models.yaml" \
  --as-of "$AS_OF" \
  --days 30 \
  --json >"$digest_json" 2>"$tmpdir/digest.err"
digest_rc=$?
set -e
if [ "$digest_rc" -eq 0 ] && [ ! -s "$tmpdir/digest.err" ]; then
  pass "step 5: factory-cost-digest.py exit 0"
else
  fail "step 5: factory-cost-digest.py exit 0" "$(cat "$tmpdir/digest.err")"
fi
if "$PYTHON" - "$digest_json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
sc = r["scorecard"]
assert sc["run_count"] == 5, sc["run_count"]
assert "total_spend_usd" in sc
assert "review_readiness" in r
print("ok")
PY
then
  pass "step 5: cost-digest fixture summary"
else
  fail "step 5: cost-digest fixture summary"
fi

# ---- Step 6: factory-site-smoke.py --build ----
set +e
smoke_out="$("$PYTHON" "$ROOT/scripts/factory-site-smoke.py" --build 2>&1)"
smoke_rc=$?
set -e
if [ "$smoke_rc" -eq 0 ] && echo "$smoke_out" | grep -q "^OK"; then
  pass "step 6: factory-site-smoke.py --build"
else
  fail "step 6: factory-site-smoke.py --build" "$smoke_out"
fi

echo "Results: ${passed} passed, ${failed} failed"
[ "$failed" -eq 0 ]