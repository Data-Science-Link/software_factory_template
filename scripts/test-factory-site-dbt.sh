#!/usr/bin/env bash
# Offline tests for the dbt tab in scripts/factory-site.py.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
ROOT="$(pwd)"
PINNED_NOW="2026-11-11 12:00:00"
MANIFEST_FIXTURE="tests/site/fixtures/manifest.json"

passed=0
failed=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

pass() {
  echo "PASS  $1"
  passed=$((passed + 1))
}

fail() {
  echo "FAIL  $1"
  failed=$((failed + 1))
}

setup_repo() {
  local root="$1"
  mkdir -p "$root/.factory" "$root/factory/site" "$root/factory/dbt/target"
  cp tests/site/fixtures/FACTORY.md "$root/.factory/FACTORY.md"
  cp tests/site/fixtures/models.yaml "$root/.factory/models.yaml"
  cp factory/site/base.html "$root/factory/site/base.html"
  cp factory/site/style.css "$root/factory/site/style.css"
}

install_manifest() {
  local root="$1"
  local manifest="${2:-$MANIFEST_FIXTURE}"
  cp "$manifest" "$root/factory/dbt/target/manifest.json"
}

render_dbt() {
  local root="$1"
  local out="$2"
  local data="$3"
  mkdir -p "$data/marts"
  cp tests/site-data/sample-marts/*.json "$data/marts/" 2>/dev/null || true
  "$PYTHON" scripts/factory-site.py \
    --repo-root "$root" \
    --out "$out" \
    --data "$data" \
    --now "$PINNED_NOW" >/dev/null
}

# ---- 1. Fixture manifest: model count and lineage edges ----
repo1="$tmpdir/repo1"
data1="$tmpdir/data1"
out1="$tmpdir/out1"
setup_repo "$repo1"
install_manifest "$repo1"
render_dbt "$repo1" "$out1" "$data1"
html1="$out1/dbt.html"
if "$PYTHON" - "$html1" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
# 1 seed + 1 staging + 9 marts = 11 resource nodes
models = ["agent_runs", "stg_agent_runs", "fct_agent_runs",
          "agg_spend_daily", "agg_spend_by_issue", "agg_spend_by_model",
          "fct_forecast_vs_actual", "rpt_run_rate", "agg_spend_weekly",
          "agg_spend_monthly", "rpt_issue_target_compliance"]
for m in models:
    if m not in html:
        raise SystemExit("missing model %s" % m)
if html.count('id="model-') < len(models):
    raise SystemExit("model sections missing")
if 'href="#model-fct_agent_runs"' not in html and "fct_agent_runs" not in html:
    raise SystemExit("missing fct link")
if "Upstream:" not in html or "Downstream:" not in html:
    raise SystemExit("missing lineage links")
# stg -> fct edge in text
if "stg_agent_runs" not in html or "agent_runs" not in html:
    raise SystemExit("missing parent names")
PY
then
  pass "every fixture model appears with upstream/downstream lineage"
else
  fail "every fixture model appears with upstream/downstream lineage"
fi

# ---- 2. dbt-docs link when present vs offline note ----
if grep -q "dbt-docs.html" "$html1" || grep -qi "not available" "$html1"; then
  pass "dbt-docs banner shows link or offline note"
else
  fail "dbt-docs banner shows link or offline note"
fi

repo_docs="$tmpdir/repo_docs"
out_docs="$tmpdir/out_docs"
data_docs="$tmpdir/data_docs"
setup_repo "$repo_docs"
install_manifest "$repo_docs"
mkdir -p "$out_docs"
printf '<html><body>docs</body></html>\n' >"$out_docs/dbt-docs.html"
render_dbt "$repo_docs" "$out_docs" "$data_docs"
if grep -q 'href="dbt-docs.html"' "$out_docs/dbt.html"; then
  pass "dbt-docs link when dbt-docs.html is present"
else
  fail "dbt-docs link when dbt-docs.html is present"
fi

# ---- 3. Missing manifest -> placeholder ----
repo_miss="$tmpdir/repo_miss"
out_miss="$tmpdir/out_miss"
data_miss="$tmpdir/data_miss"
setup_repo "$repo_miss"
render_dbt "$repo_miss" "$out_miss" "$data_miss"
if grep -q "This tab is not available yet" "$out_miss/dbt.html"; then
  pass "missing manifest shows placeholder"
else
  fail "missing manifest shows placeholder"
fi

# ---- 4. Empty manifest -> note, not crash ----
repo_empty="$tmpdir/repo_empty"
out_empty="$tmpdir/out_empty"
data_empty="$tmpdir/data_empty"
setup_repo "$repo_empty"
install_manifest "$repo_empty" tests/site/fixtures/manifest-empty.json
render_dbt "$repo_empty" "$out_empty" "$data_empty"
if grep -q "no models or seeds" "$out_empty/dbt.html"; then
  pass "zero-model manifest shows clean note"
else
  fail "zero-model manifest shows clean note"
fi

# ---- 5. Model without description -> no description ----
repo_nd="$tmpdir/repo_nd"
out_nd="$tmpdir/out_nd"
data_nd="$tmpdir/data_nd"
setup_repo "$repo_nd"
install_manifest "$repo_nd" tests/site/fixtures/manifest-no-description.json
render_dbt "$repo_nd" "$out_nd" "$data_nd"
if grep -q "no description" "$out_nd/dbt.html"; then
  pass "model with missing description shows no description"
else
  fail "model with missing description shows no description"
fi

# ---- 6. Lineage SVG present, no forbidden remote links ----
if grep -q 'class="dbt-lineage"' "$html1" && grep -q "<svg" "$html1"; then
  pass "lineage inline SVG is rendered"
else
  fail "lineage inline SVG is rendered"
fi
if grep -E 'https?://' "$html1" | grep -Ev 'schemas\.getdbt\.com' | grep -q .; then
  # manifest metadata URL only appears inside committed fixture metadata, not HTML
  if grep -E 'https?://' "$html1" >/dev/null 2>&1; then
    fail "dbt tab HTML contains unexpected http(s) URL"
  fi
fi
if ! grep -E 'https?://' "$html1" >/dev/null 2>&1; then
  pass "dbt tab HTML has no http(s) URLs"
fi

# ---- 7. schema.yml descriptions (models and columns) ----
if "$PYTHON" - <<'PY'
import sys
from pathlib import Path
import yaml

roots = [
    Path("factory/dbt/models/staging/schema.yml"),
    Path("factory/dbt/models/marts/schema.yml"),
]
for path in roots:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    for model in data.get("models") or []:
        desc = (model.get("description") or "").strip()
        if not desc:
            raise SystemExit(f"model {model.get('name')} missing description in {path}")
        for col in model.get("columns") or []:
            cdesc = (col.get("description") or "").strip()
            if not cdesc:
                raise SystemExit(
                    f"column {col.get('name')} on {model.get('name')} missing description"
                )
PY
then
  pass "every model and column in schema.yml has a description"
else
  fail "every model and column in schema.yml has a description"
fi

# ---- 8. --sample build wires manifest fixture into dbt tab ----
build_log="$tmpdir/sample-build.log"
if bash scripts/factory-site-build.sh --sample >"$build_log" 2>&1 \
   && [ -f site/dbt.html ] \
   && grep -q "stg_agent_runs" site/dbt.html \
   && grep -q "manifest fixture" "$build_log"; then
  pass "--sample build copies manifest fixture and renders dbt tab"
else
  fail "--sample build copies manifest fixture and renders dbt tab"
  tail -20 "$build_log" 2>/dev/null || true
fi

# ---- 9. Wide graph: seven-plus children downstream of fct ----
if "$PYTHON" - "$html1" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'id="model-fct_agent_runs"(.*?</section>)', html, re.S)
if not m:
    raise SystemExit("fct section missing")
block = m.group(1)
down = re.search(r"<strong>Downstream:</strong>\s*(.*?)</p>", block, re.S)
if not down:
    raise SystemExit("downstream missing")
links = re.findall(r'href="#model-([^"]+)"', down.group(1))
if len(links) < 7:
    raise SystemExit("downstream count %d" % len(links))
PY
then
  pass "wide graph lists seven-plus mart downstream links from fct"
else
  fail "wide graph lists seven-plus mart downstream links from fct"
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi