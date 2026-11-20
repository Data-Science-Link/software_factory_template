#!/usr/bin/env bash
# Offline tests for scripts/factory-monthly-review.py (stdlib only).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
PY=("$PYTHON" scripts/factory-monthly-review.py)
MODELS=".factory/models.yaml"
BUDGET="factory/budget.yml"
SAMPLE="examples/sample-runs"
AS_OF="2026-11-20"

passed=0
failed=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

pass() { echo "PASS  $1"; passed=$((passed + 1)); }
fail() { echo "FAIL  $1"; failed=$((failed + 1)); }

EMPTY_DIR="$tmpdir/empty"
mkdir -p "$EMPTY_DIR"

# ---- empty runs dir ----
if out="$("${PY[@]}" --runs-dir "$EMPTY_DIR" --as-of "$AS_OF" 2>"$tmpdir/empty.err")" \
  && [ ! -s "$tmpdir/empty.err" ]; then
  if printf '%s' "$out" | grep -q "No run records" \
    && printf '%s' "$out" | grep -q "Investigate"; then
    pass "empty runs dir"
  else
    fail "empty runs dir (content)"
  fi
else
  fail "empty runs dir"
fi

# ---- sample-runs pinned math ----
if ! "${PY[@]}" --runs-dir "$SAMPLE" --budget "$BUDGET" --models "$MODELS" \
  --as-of "$AS_OF" --json >"$tmpdir/sample.json"; then
  fail "sample-runs json"
else
  if "$PYTHON" - "$tmpdir/sample.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
wt = r["work_type_split"]
assert wt["coding"]["total_spend_usd"] == 0.0643, wt["coding"]
assert wt["review"]["total_spend_usd"] == 0.04842, wt["review"]
assert wt["review_spend_vs_coding_spend_ratio"] == round(0.04842 / 0.0643, 6)
vr = r["volume_reliability"]
assert vr["total_runs"] == 3
assert vr["unique_issues"] == 1
assert vr["fix_round_rate"] == round(2 / 3, 6)
assert r["spend_budget"]["total_spend_usd"] == 0.11272
models = {m["model"]: m for m in r["model_efficiency"]}
assert models["deepseek-ai/DeepSeek-V4-Flash-0731"]["cache_hit_rate"] == 0.8
assert models["Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo"]["cache_hit_rate"] == 0.7
levels = {p["level"] for p in r["action_prompts"]}
assert "Tune" in levels
PY
  then
    pass "sample-runs verified math"
  else
    fail "sample-runs verified math"
  fi
fi

# ---- deterministic JSON ----
"${PY[@]}" --runs-dir "$SAMPLE" --as-of "$AS_OF" --json >"$tmpdir/a.json"
"${PY[@]}" --runs-dir "$SAMPLE" --as-of "$AS_OF" --json >"$tmpdir/b.json"
if cmp -s "$tmpdir/a.json" "$tmpdir/b.json"; then
  pass "deterministic JSON"
else
  fail "deterministic JSON"
fi

# ---- malformed JSON skipped ----
BAD_DIR="$tmpdir/bad-runs"
mkdir -p "$BAD_DIR"
cp "$SAMPLE"/*.json "$BAD_DIR/"
printf '{ not json\n' >"$BAD_DIR/broken.json"
if "${PY[@]}" --runs-dir "$BAD_DIR" --as-of "$AS_OF" --json >"$tmpdir/bad.json" 2>"$tmpdir/bad.err" \
  && [ ! -s "$tmpdir/bad.err" ]; then
  skipped="$( "$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["skipped_files"])' "$tmpdir/bad.json" )"
  if [ "$skipped" = 1 ]; then
    pass "malformed JSON skipped"
  else
    fail "malformed JSON skipped (skipped=$skipped)"
  fi
else
  fail "malformed JSON skipped"
fi

# ---- missing budget.yml fallback ----
MISSING_BUDGET="$tmpdir/no-budget.yml"
if "${PY[@]}" --runs-dir "$SAMPLE" --budget "$MISSING_BUDGET" --models "$MODELS" \
  --as-of "$AS_OF" --json >"$tmpdir/nobudget.json" 2>"$tmpdir/nobudget.err"; then
  if [ ! -s "$tmpdir/nobudget.err" ] \
    && "$PYTHON" -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["budget_values"]["issue_target_usd"]==0.15' \
      "$tmpdir/nobudget.json"; then
    pass "missing budget.yml fallback"
  else
    fail "missing budget.yml fallback"
  fi
else
  fail "missing budget.yml fallback"
fi

# ---- over-budget pacing triggers Investigate ----
OB_DIR="$tmpdir/over-budget"
mkdir -p "$OB_DIR"
cp "$SAMPLE/gha-100001-1.json" "$OB_DIR/"
seq=2
while [ "$seq" -le 70 ]; do
  "$PYTHON" - "$OB_DIR/run-${seq}.json" "$seq" <<'PY'
import json, sys
from pathlib import Path

path, seq = Path(sys.argv[1]), int(sys.argv[2])
base = json.loads(Path("examples/sample-runs/gha-100001-1.json").read_text())
base["run_id"] = f"gha-9900{seq:03d}-1"
base["actual_cost_usd"] = 0.12
base["started_at"] = "2026-11-18T12:00:00Z"
base["issue"] = 200 + seq
path.write_text(json.dumps(base, indent=2) + "\n")
PY
  seq=$((seq + 1))
done

if "${PY[@]}" --runs-dir "$OB_DIR" --budget "$BUDGET" --as-of "$AS_OF" --json \
  >"$tmpdir/ob.json" 2>"$tmpdir/ob.err"; then
  if "$PYTHON" - "$tmpdir/ob.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
pct = r["spend_budget"]["monthly_budget_pct_used"]
assert pct is not None and pct >= 80.0, pct
text = " ".join(p["finding"] for p in r["action_prompts"])
assert "Investigate" in {p["level"] for p in r["action_prompts"]}
assert "monthly" in text.lower() or "cap" in text.lower()
PY
  then
    pass "over-budget pacing Investigate"
  else
    fail "over-budget pacing Investigate"
  fi
else
  fail "over-budget pacing Investigate"
fi

# ---- high fix-round rate Tune ----
HF_DIR="$tmpdir/high-fix"
mkdir -p "$HF_DIR"
cp "$SAMPLE/gha-100001-1.json" "$HF_DIR/base.json"
"$PYTHON" - "$HF_DIR" <<'PY'
import json
import sys
from copy import deepcopy
from pathlib import Path

root = Path(sys.argv[1])
base = json.loads((root / "base.json").read_text())
rows = []
for i in range(6):
    row = deepcopy(base)
    row["run_id"] = f"gha-88000{i}-1"
    row["issue"] = 42
    row["started_at"] = f"2026-11-{10+i:02d}T12:00:00Z"
    row["actual_cost_usd"] = 0.01
    rows.append(row)
(root / "fix-heavy.json").write_text(json.dumps(rows[0], indent=2) + "\n")
for i, row in enumerate(rows):
    (root / f"run-{i}.json").write_text(json.dumps(row, indent=2) + "\n")
PY

if "${PY[@]}" --runs-dir "$HF_DIR" --as-of "$AS_OF" --json >"$tmpdir/hf.json"; then
  if "$PYTHON" - "$tmpdir/hf.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
fr = r["volume_reliability"]["fix_round_rate"]
assert fr is not None and fr > 0.20, fr
assert any(p["level"] == "Tune" and "Fix-round" in p["finding"] for p in r["action_prompts"])
PY
  then
    pass "high fix-round rate Tune"
  else
    fail "high fix-round rate Tune"
  fi
else
  fail "high fix-round rate Tune"
fi

echo "test-factory-monthly-review.sh: $passed passed, $failed failed"
exit "$([ "$failed" -eq 0 ] && echo 0 || echo 1)"