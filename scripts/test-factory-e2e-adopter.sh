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
  if grep -q "Data-Science-Link/software_factory_template" "$repo/.github/workflows/pr-check.yml" \
    && ! grep -q "YOUR_ORG" "$repo/.github/workflows/pr-check.yml"; then
    pass "step 2: pr-check substitutes template-repo placeholder"
  else
    fail "step 2: pr-check substitutes template-repo placeholder"
  fi
fi

# ---- Step 2b: init with custom --template-repo and --owner (zero template placeholders) ----
repo_owned="$work/adopter-owned"
mkdir -p "$repo_owned"
TEMPLATE_REPO="acme-corp/software_factory_template"
OWNER_LOGIN="acme-corp"
set +e
owned_out="$("$PYTHON" "$ROOT/scripts/factory-init-repo.py" \
  --target "$repo_owned" \
  --tag "$TAG" \
  --template-dir "$ROOT" \
  --template-repo "$TEMPLATE_REPO" \
  --owner "$OWNER_LOGIN" \
  --repo-name adopter-owned 2>&1)"
owned_rc=$?
set -e
if [ "$owned_rc" -eq 0 ]; then
  pass "step 2b: init with --owner and --template-repo"
else
  fail "step 2b: init with --owner and --template-repo" "$owned_out"
fi
placeholder_hits="$(
  grep -R -l -E 'YOUR_ORG|YOUR_OWNER_GITHUB_LOGIN' "$repo_owned/.github/workflows" 2>/dev/null \
    || true
)"
if [ -z "$placeholder_hits" ]; then
  pass "step 2b: caller workflows have zero template placeholders"
else
  fail "step 2b: caller workflows have zero template placeholders" "$placeholder_hits"
fi
if grep -q "$TEMPLATE_REPO" "$repo_owned/.github/workflows/opencode-run.yml" \
  && grep -q "$OWNER_LOGIN" "$repo_owned/.github/workflows/opencode-run.yml"; then
  pass "step 2b: opencode-run pins template-repo and owner"
else
  fail "step 2b: opencode-run pins template-repo and owner"
fi
template_leaks="$(
  grep -R -l 'Data-Science-Link/software_factory_template' "$repo_owned/.github/workflows" 2>/dev/null \
    || true
)"
if [ -z "$template_leaks" ]; then
  pass "step 2b: generated callers have zero template-owner org leak"
else
  fail "step 2b: generated callers have zero template-owner org leak" "$template_leaks"
fi
if ! "$ROOT/scripts/opencode-artifact-scan.sh" --list-protected | grep -q 'factory-init-repo.py' \
  && ! "$ROOT/scripts/opencode-artifact-scan.sh" --list-protected | grep -q 'factory-migrate-adopter.py'; then
  pass "step 2b: init/migrate scripts not in PROTECTED_SCRIPTS"
else
  fail "step 2b: init/migrate scripts not in PROTECTED_SCRIPTS"
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

# ---- Step 7: init -> migrate -> fleet sync --check --json (acme-corp / demo-app) ----
ACME_TEMPLATE="acme-corp/software_factory_template"
ACME_OWNER="acme-corp"
FLEET_REPO="acme-corp/demo-app"
repo_life="$work/demo-app"
gh_fake="$tmpdir/gh-fake"
mkdir -p "$gh_fake/bin" "$repo_life/src"

if git init -q "$repo_life" \
  && printf '%s\n' '# demo product' >"$repo_life/README.md" \
  && git -C "$repo_life" add README.md \
  && git -C "$repo_life" -c user.email=demo@example.invalid -c user.name=demo commit -q -m "seed"; then
  pass "step 7: temp demo-app git repo"
else
  fail "step 7: temp demo-app git repo"
fi

set +e
life_init="$("$PYTHON" "$ROOT/scripts/factory-init-repo.py" \
  --target "$repo_life" \
  --tag "$TAG" \
  --template-dir "$ROOT" \
  --template-repo "$ACME_TEMPLATE" \
  --owner "$ACME_OWNER" \
  --repo-name demo-app 2>&1)"
life_init_rc=$?
set -e
[ "$life_init_rc" -eq 0 ] && pass "step 7: factory-init-repo.py" || fail "step 7: factory-init-repo.py" "$life_init"

CUSTOM_MARKER="# user-adopter-customization demo-app"
printf '\n%s\n' "$CUSTOM_MARKER" >>"$repo_life/AGENTS.md"
mkdir -p "$repo_life/scripts"
cp "$ROOT/scripts/pr-check.sh" "$repo_life/scripts/pr-check.sh"
cp "$ROOT/scripts/test-all.sh" "$repo_life/scripts/test-all.sh"
printf '\n%s\n' '# local product test tweak' >>"$repo_life/scripts/test-all.sh"
echo '#!/usr/bin/env bash' >"$repo_life/scripts/build-product.sh"
echo 'echo ok' >>"$repo_life/scripts/build-product.sh"

set +e
life_init2="$("$PYTHON" "$ROOT/scripts/factory-init-repo.py" \
  --target "$repo_life" \
  --tag "$TAG" \
  --template-dir "$ROOT" \
  --template-repo "$ACME_TEMPLATE" \
  --owner "$ACME_OWNER" \
  --repo-name demo-app 2>&1)"
life_init2_rc=$?
set -e
if [ "$life_init2_rc" -eq 0 ] && grep -qF "$CUSTOM_MARKER" "$repo_life/AGENTS.md" \
  && grep -qF '# local product test tweak' "$repo_life/scripts/test-all.sh"; then
  pass "step 7: re-init is idempotent (customizations preserved)"
else
  fail "step 7: re-init is idempotent (customizations preserved)" "$life_init2"
fi

life_ph="$(grep -R -l -E 'YOUR_ORG|YOUR_OWNER_GITHUB_LOGIN' "$repo_life/.github/workflows" 2>/dev/null || true)"
life_leak="$(grep -R -l 'Data-Science-Link/software_factory_template' "$repo_life/.github/workflows" 2>/dev/null || true)"
if [ -z "$life_ph" ] && [ -z "$life_leak" ]; then
  pass "step 7: acme-corp callers have zero placeholders and org leaks"
else
  fail "step 7: acme-corp callers have zero placeholders and org leaks" "${life_ph}${life_leak}"
fi

custom_hash_before="$(sha256sum "$repo_life/scripts/test-all.sh" | awk '{print $1}')"
set +e
life_migrate="$("$PYTHON" "$ROOT/scripts/factory-migrate-adopter.py" \
  --repo-dir "$repo_life" \
  --tag "$TAG" \
  --template-dir "$ROOT" \
  --template-repo "$ACME_TEMPLATE" \
  --owner "$ACME_OWNER" \
  --apply 2>&1)"
life_mig_rc=$?
set -e
[ "$life_mig_rc" -eq 0 ] && pass "step 7: factory-migrate-adopter.py --apply" \
  || fail "step 7: factory-migrate-adopter.py --apply" "$life_migrate"

if [ -f "$repo_life/.factory/migration-callers/pr-check.yml" ] \
  && grep -q "$ACME_TEMPLATE" "$repo_life/.factory/migration-callers/pr-check.yml"; then
  pass "step 7: migration-callers pin acme-corp template"
else
  fail "step 7: migration-callers pin acme-corp template"
fi

set +e
life_migrate2="$("$PYTHON" "$ROOT/scripts/factory-migrate-adopter.py" \
  --repo-dir "$repo_life" \
  --tag "$TAG" \
  --template-dir "$ROOT" \
  --template-repo "$ACME_TEMPLATE" \
  --owner "$ACME_OWNER" \
  --apply 2>&1)"
life_mig2_rc=$?
set -e
custom_hash_after="$(sha256sum "$repo_life/scripts/test-all.sh" | awk '{print $1}')"
if [ "$life_mig2_rc" -eq 0 ] && [ "$custom_hash_before" = "$custom_hash_after" ]; then
  pass "step 7: migrate re-apply is idempotent for customized scripts"
else
  fail "step 7: migrate re-apply is idempotent for customized scripts" "$life_migrate2"
fi

# Fleet sync reads pinned reusable callers via gh (offline fake).
SYNC_TEMPLATE_PIN="Data-Science-Link/software_factory_template"
RUN_YML_LIFE="name: opencode-run
jobs:
  x:
    uses: ${SYNC_TEMPLATE_PIN}/.github/workflows/reusable-opencode-run.yml@${TAG}
    with:
      factory_ref: ${TAG}
"
mkdir -p "$repo_life/.github/workflows"
printf '%s\n' "$RUN_YML_LIFE" >"$repo_life/.github/workflows/opencode-run.yml"
printf '%s\n' 'name: pr-check' >"$repo_life/.github/workflows/pr-check.yml"

cat >"$gh_fake/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = api ]; then
  case "$*" in
    *contents/.github/workflows/opencode-run.yml*)
      printf '{"content":"%s"}' "${FAKE_RUN_YML_B64:-}"
      exit 0
      ;;
    *contents/.github/workflows/pr-check.yml*)
      printf '{"content":"%s"}' "${FAKE_PR_YML_B64:-}"
      exit 0
      ;;
    *contents/.github/workflows*)
      printf '%s' '[{"path":".github/workflows/opencode-run.yml"},{"path":".github/workflows/pr-check.yml"}]'
      exit 0
      ;;
  esac
fi
if [ "$1" = repo ] && [ "$2" = view ]; then
  echo main
  exit 0
fi
if [ "$1" = pr ]; then
  exit 0
fi
exit 0
GH
chmod +x "$gh_fake/bin/gh"
export FAKE_RUN_YML_B64="$(printf '%s' "$RUN_YML_LIFE" | base64 -w0)"
export FAKE_PR_YML_B64="$(printf '%s' 'name: pr-check' | base64 -w0)"
life_adopters="$tmpdir/demo-adopters.txt"
printf '%s\n' "$FLEET_REPO" >"$life_adopters"

set +e
sync_out="$(
  PATH="$gh_fake/bin:$PATH" "$PYTHON" "$ROOT/scripts/factory-sync-repos.py" \
    --repos-file "$life_adopters" \
    --tag v0.2.0 \
    --check \
    --json 2>&1
)"
sync_rc=$?
set -e
export FLEET_REPO
if [ "$sync_rc" -eq 0 ] && echo "$sync_out" | "$PYTHON" -c "
import json, os, sys
d = json.load(sys.stdin)
fleet = os.environ['FLEET_REPO']
assert d['repos'] == [fleet]
row = d['adopters'][0]
assert row['repo'] == fleet
assert row['status'] == 'outdated'
assert d['summary']['total'] == 1
"; then
  pass "step 7: factory-sync-repos.py --check --json fleet drift"
else
  fail "step 7: factory-sync-repos.py --check --json fleet drift" "$sync_out"
fi

sync_out2="$(
  PATH="$gh_fake/bin:$PATH" "$PYTHON" "$ROOT/scripts/factory-sync-repos.py" \
    --repos-file "$life_adopters" \
    --tag v0.2.0 \
    --check \
    --json 2>&1
)"
if [ "$sync_out" = "$sync_out2" ]; then
  pass "step 7: fleet sync JSON is deterministic"
else
  fail "step 7: fleet sync JSON is deterministic"
fi

echo "Results: ${passed} passed, ${failed} failed"
[ "$failed" -eq 0 ]