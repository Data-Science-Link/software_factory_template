#!/usr/bin/env bash
# Offline tests for scripts/factory-branch-cleanup.py using tests/branch-cleanup/*.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
FIXTURE_DIR="tests/branch-cleanup"
NOW_ISO="2026-11-20T00:00:00Z"

passed=0
failed=0

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

json_out="$tmpdir/report.json"
md_out="$tmpdir/report.md"

if ! "$PYTHON" scripts/factory-branch-cleanup.py \
  --branches-json "$FIXTURE_DIR/branches.json" \
  --prs-json "$FIXTURE_DIR/prs.json" \
  --older-than-days 7 \
  --now "$NOW_ISO" \
  --json >"$json_out"; then
  echo "FAIL  factory-branch-cleanup.py --json did not run"
  exit 1
fi

if ! "$PYTHON" scripts/factory-branch-cleanup.py \
  --branches-json "$FIXTURE_DIR/branches.json" \
  --prs-json "$FIXTURE_DIR/prs.json" \
  --older-than-days 7 \
  --now "$NOW_ISO" >"$md_out"; then
  echo "FAIL  factory-branch-cleanup.py markdown mode did not run"
  exit 1
fi

# ---- test 1: JSON shape and summary counts ----
if "$PYTHON" - "$json_out" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
for key in ("summary", "candidates", "kept"):
    if key not in report:
        raise SystemExit("missing key %r" % key)
s = report["summary"]
if s.get("dry_run") is not True:
    raise SystemExit("dry_run must be true")
want = {"merged_pr": 1, "closed_unmerged_old": 1, "orphan_old": 1, "keep": 7}
for k, v in want.items():
    if s.get(k) != v:
        raise SystemExit("summary %s: got %r want %r" % (k, s.get(k), v))
names = {c["branch"] for c in report["candidates"]}
if names != {
    "oc/issue-50-merged",
    "oc/issue-40-closed-old",
    "cursor/orphan-stale",
}:
    raise SystemExit("candidate branches mismatch: %r" % names)
PY
then
  echo "PASS  JSON summary and candidate branches match fixture expectations"
  passed=$((passed + 1))
else
  echo "FAIL  JSON summary or candidate branches mismatch"
  failed=$((failed + 1))
fi

# ---- test 2: main and open-PR branches are kept, never candidates ----
if "$PYTHON" - "$json_out" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
cand = {c["branch"] for c in report["candidates"]}
kept = {k["branch"]: k for k in report["kept"]}
if "main" in cand:
    raise SystemExit("main must not be a delete candidate")
if "oc/issue-99-open" in cand:
    raise SystemExit("open PR branch must not be a delete candidate")
if kept["main"]["category"] != "keep":
    raise SystemExit("main category")
if kept["oc/issue-99-open"]["reason"] != "open pull request":
    raise SystemExit("open PR reason: %r" % kept["oc/issue-99-open"]["reason"])
PY
then
  echo "PASS  main and open-PR factory branches are kept"
  passed=$((passed + 1))
else
  echo "FAIL  main or open-PR branch incorrectly flagged"
  failed=$((failed + 1))
fi

# ---- test 3: non-factory branch feat/user-work is kept ----
if "$PYTHON" - "$json_out" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
cand = {c["branch"] for c in report["candidates"]}
kept = {k["branch"]: k for k in report["kept"]}
if "feat/user-work" in cand:
    raise SystemExit("non-factory branch flagged")
if kept["feat/user-work"]["reason"] != "non-factory branch prefix":
    raise SystemExit("feat reason")
PY
then
  echo "PASS  non-factory feature branch is never flagged"
  passed=$((passed + 1))
else
  echo "FAIL  non-factory branch incorrectly flagged"
  failed=$((failed + 1))
fi

# ---- test 4: classification reasons for representative rows ----
if "$PYTHON" - "$json_out" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
by = {c["branch"]: c for c in report["candidates"]}
if by["oc/issue-50-merged"]["category"] != "merged_pr":
    raise SystemExit("merged category")
if by["oc/issue-40-closed-old"]["category"] != "closed_unmerged_old":
    raise SystemExit("closed old category")
if by["cursor/orphan-stale"]["category"] != "orphan_old":
    raise SystemExit("orphan category")
kept = {k["branch"]: k for k in report["kept"]}
if kept["cursor/wip-recent"]["category"] != "keep":
    raise SystemExit("recent orphan keep")
PY
then
  echo "PASS  merged_pr, closed_unmerged_old, orphan_old, and recent keep classify correctly"
  passed=$((passed + 1))
else
  echo "FAIL  branch classification mismatch"
  failed=$((failed + 1))
fi

# ---- test 5: markdown mentions dry run and delete commands without executing ----
if grep -q "dry run" "$md_out" && grep -q "git push origin --delete oc/issue-50-merged" "$md_out"; then
  echo "PASS  markdown output is dry-run with copy-paste delete commands"
  passed=$((passed + 1))
else
  echo "FAIL  markdown output missing dry-run or delete command hints"
  failed=$((failed + 1))
fi

# ---- test 6: every candidate has delete_command ----
if "$PYTHON" - "$json_out" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
for c in report["candidates"]:
    cmd = c.get("delete_command") or ""
    if "delete" not in cmd:
        raise SystemExit("missing delete_command for %s" % c["branch"])
PY
then
  echo "PASS  every candidate includes a delete_command"
  passed=$((passed + 1))
else
  echo "FAIL  candidate missing delete_command"
  failed=$((failed + 1))
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
exit 0