#!/usr/bin/env bash
# Offline tests for scripts/factory-owner-pack.py
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
pack="$root/scripts/factory-owner-pack.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); cat "$work/out" 2>/dev/null || true; }

write_stub_all_pass() {
  local repo="$1"
  mkdir -p "$repo/scripts" "$repo/.github/workflows"
  cat >"$repo/scripts/factory-doctor.py" <<'PY'
#!/usr/bin/env python3
import json, sys
json.dump({"summary": {"pass": 1, "warn": 0, "fail": 0, "skip": 0}, "checks": []}, sys.stdout)
PY
  cp "$repo/scripts/factory-doctor.py" "$repo/scripts/factory-prepublic-check.py"
  cat >"$repo/scripts/factory-prepublic-check.py" <<'PY'
#!/usr/bin/env python3
import json, sys
json.dump({"finding_count": 0, "findings": []}, sys.stdout)
PY
  cat >"$repo/scripts/factory-check-docs.py" <<'PY'
#!/usr/bin/env python3
import json, sys
json.dump({"summary": {"errors": 0, "warnings": 0, "broken_links": 0}}, sys.stdout)
PY
  cat >"$repo/scripts/factory-audit-workflows.py" <<'PY'
#!/usr/bin/env python3
import json, sys
json.dump({"summary": {"pass": 1, "fail": 0, "total": 1}}, sys.stdout)
PY
  cat >"$repo/scripts/factory-site-smoke.py" <<'PY'
#!/usr/bin/env python3
import json, sys
json.dump({"ok": True, "error_count": 0, "errors": []}, sys.stdout)
PY
  cat >"$repo/scripts/factory-release.py" <<'PY'
#!/usr/bin/env python3
import json, sys
json.dump({"summary": {"pass": 1, "warn": 0, "fail": 0, "skip": 0}, "checks": []}, sys.stdout)
PY
  cat >"$repo/scripts/factory-models-check.py" <<'PY'
#!/usr/bin/env python3
import json, sys
json.dump({"status": "ok", "models_checked": 1, "errors": [], "warnings": []}, sys.stdout)
PY
  cat >"$repo/scripts/factory-decision-log.py" <<'PY'
#!/usr/bin/env python3
import json, sys
if len(sys.argv) > 1 and sys.argv[1] == "check":
    json.dump({"total": 1, "valid": True, "errors": [], "warnings": []}, sys.stdout)
PY
  cat >"$repo/scripts/test-shell-hygiene.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat >"$repo/scripts/test-examples.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo"/scripts/*.py "$repo"/scripts/*.sh
}

run_pack() {
  set +e
  python3 "$pack" "$@" >"$work/out" 2>"$work/err"
  local rc=$?
  set -e
  printf '%s' "$rc" >"$work/rc"
}

# --- all stubs pass -> READY, exit 0 ---
stub_repo="$work/pass-all"
write_stub_all_pass "$stub_repo"
run_pack --repo-dir "$stub_repo" --version v0.1.0 --json
if [ "$(cat "$work/rc")" -eq 0 ]; then ok "stubbed helpers READY exit 0"; else bad "stubbed helpers exit code"; fi
if python3 -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["verdict"] == "READY", data["verdict"]
assert data["summary"]["fail"] == 0
print("verdict ok")
' "$work/out"
then ok "stubbed helpers verdict READY"
else bad "stubbed helpers verdict"
fi

# --- failing doctor -> BLOCKED, remediation hint ---
fail_repo="$work/fail-doctor"
write_stub_all_pass "$fail_repo"
cat >"$fail_repo/scripts/factory-doctor.py" <<'PY'
#!/usr/bin/env python3
import json, sys
json.dump({"summary": {"pass": 0, "warn": 0, "fail": 1, "skip": 0}, "checks": []}, sys.stdout)
PY
chmod +x "$fail_repo/scripts/factory-doctor.py"
run_pack --repo-dir "$fail_repo" --version v0.1.0 --json
if [ "$(cat "$work/rc")" -ne 0 ]; then ok "failing sub-check non-zero exit"; else bad "failing sub-check should block"; fi
if python3 -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["verdict"] == "BLOCKED"
doc = next(g for g in data["gates"] if g["id"] == "doctor")
assert "factory-doctor.py" in doc["remediation"]
print("blocked ok")
' "$work/out"
then ok "failing sub-check BLOCKED + remediation"
else bad "failing sub-check payload"
fi

# --- missing optional scripts -> SKIP without crash ---
skip_repo="$work/missing-scripts"
write_stub_all_pass "$skip_repo"
rm -f "$skip_repo/scripts/factory-site-smoke.py" "$skip_repo/scripts/factory-release.py"
run_pack --repo-dir "$skip_repo" --json
if [ "$(cat "$work/rc")" -eq 0 ]; then ok "missing helpers exit 0"; else bad "missing helpers crashed"; fi
if python3 -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
site = next(g for g in data["gates"] if g["id"] == "site_smoke")
rel = next(g for g in data["gates"] if g["id"] == "release")
assert site["status"] == "SKIP"
assert rel["status"] == "SKIP"
print("skip ok")
' "$work/out"
then ok "missing helpers report SKIP"
else bad "missing helpers SKIP rows"
fi

# --- --json schema ---
run_pack --repo-dir "$stub_repo" --version v0.1.0 --json
if python3 -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
for key in ("repo_dir", "verdict", "gates", "summary"):
    assert key in data
for key in ("pass", "warn", "fail", "skip"):
    assert key in data["summary"]
for g in data["gates"]:
    for key in ("id", "label", "status", "detail", "remediation"):
        assert key in g
    assert g["status"] in ("PASS", "WARN", "FAIL", "SKIP")
print("json ok")
' "$work/out"
then ok "--json parses cleanly"
else bad "--json schema"
fi

# --- new quality gates present on stub + READY ---
for gate_id in models_config decision_log examples_smoke shell_hygiene; do
  if python3 -c '
import json, sys
gate = sys.argv[2]
data = json.load(open(sys.argv[1], encoding="utf-8"))
row = next(g for g in data["gates"] if g["id"] == gate)
assert row["status"] == "PASS", (gate, row["status"])
print(gate, "ok")
' "$work/out" "$gate_id"
  then ok "stub gate $gate_id PASS in --json"
  else bad "stub gate $gate_id in --json"
  fi
done

run_pack --repo-dir "$stub_repo" --version v0.1.0
if grep -q "Model registry (factory-models-check)" "$work/out" \
  && grep -q "Shell hygiene (test-shell-hygiene)" "$work/out" \
  && grep -q "OWNER_WORKFLOW_SYNC.md" "$work/out"; then
  ok "stub --markdown lists new gates and owner refs"
else
  bad "stub --markdown new gates"
fi

# --- live repo: new gates PASS (integration) ---
if [ -f "$root/.factory/models.yaml" ]; then
  run_pack --repo-dir "$root" --version v0.1.0 --json
  for gate_id in models_config decision_log examples_smoke shell_hygiene; do
    if python3 -c '
import json, sys
gate = sys.argv[2]
data = json.load(open(sys.argv[1], encoding="utf-8"))
row = next(g for g in data["gates"] if g["id"] == gate)
assert row["status"] == "PASS", (gate, row["status"], row.get("detail"))
print("live", gate, row["status"])
' "$work/out" "$gate_id"
    then ok "live gate $gate_id PASS"
    else bad "live gate $gate_id"
    fi
  done
  run_pack --repo-dir "$root" --version v0.1.0
  for needle in \
    "Model registry (factory-models-check)" \
    "Decision log (factory-decision-log)" \
    "Examples smoke (test-examples)" \
    "Shell hygiene (test-shell-hygiene)"; do
    if grep -qF "$needle" "$work/out"; then
      ok "live markdown mentions $needle"
    else
      bad "live markdown missing $needle"
    fi
  done
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]