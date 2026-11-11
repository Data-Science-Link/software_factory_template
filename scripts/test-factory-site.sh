#!/usr/bin/env bash
# Test scripts/factory-site.py and scripts/factory-site-build.sh --sample.
# Renders from committed fixtures under tests/site/fixtures/ and
# tests/site-data/sample-marts/; never invokes scripts/factory-collect-runs.py,
# never runs a live dbt build/dbt run, and makes no network calls.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"

if ! "$PYTHON" -c "import yaml" 2>/dev/null; then
  echo "FAIL  PyYAML not installed; run: pip install -r requirements-factory.txt"
  exit 1
fi

passed=0
failed=0

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Build a temporary repo-root with the site assets and given FACTORY.md/models.yaml.
make_root() {
  local root="$1" fact="$2" models="$3"
  mkdir -p "$root/.factory" "$root/factory/site"
  cp "$fact" "$root/.factory/FACTORY.md"
  cp "$models" "$root/.factory/models.yaml"
  cp factory/site/base.html "$root/factory/site/base.html"
  cp factory/site/style.css "$root/factory/site/style.css"
}

# ---- test 1: build --sample writes the four HTML files offline ----
build_out="$tmpdir/build.log"
if (cd "$(git rev-parse --show-toplevel)" \
    && bash scripts/factory-site-build.sh --sample >"$build_out" 2>&1) \
    && [ -f site/index.html ] \
    && [ -f site/financials.html ] \
    && [ -f site/backlog.html ] \
    && [ -f site/dbt.html ]; then
  if grep -q "SKIP  collect runs" "$build_out"; then
    echo "PASS  site renders the four HTML files offline"
    passed=$((passed + 1))
  else
    echo "FAIL  build --sample did not skip collect runs"
    cat "$build_out"
    failed=$((failed + 1))
  fi
else
  echo "FAIL  build --sample did not write the four HTML files"
  cat "$build_out" 2>/dev/null || true
  failed=$((failed + 1))
fi

# ---- test 2: architecture lists every routing rule in order with its model ----
root2="$tmpdir/root2"
make_root "$root2" tests/site/fixtures/FACTORY.md tests/site/fixtures/models.yaml
out2="$tmpdir/out2"
if "$PYTHON" scripts/factory-site.py --repo-root "$root2" --out "$out2" --now "2026-11-11 12:00:00" >/dev/null; then
  idx="$out2/index.html"
  ok=1
  grep -q "deepseek-ai/DeepSeek-V4-Pro-0813" "$idx" || ok=0
  grep -q "deepseek-ai/DeepSeek-V4-Flash-0731" "$idx" || ok=0
  r2=$(grep -c "rule 2" "$idx" || true)
  r9=$(grep -c "rule 9" "$idx" || true)
  r3=$(grep -c "rule 3" "$idx" || true)
  r2_line=$(grep -n "rule 2" "$idx" | head -n1 | cut -d: -f1 || true)
  r9_line=$(grep -n "rule 9" "$idx" | head -n1 | cut -d: -f1 || true)
  r3_line=$(grep -n "rule 3" "$idx" | head -n1 | cut -d: -f1 || true)
  if [ "$ok" = 1 ] && [ "$r2" -ge 1 ] && [ "$r9" -ge 1 ] && [ "$r3" -ge 1 ] \
     && [ "$r2_line" -lt "$r9_line" ] && [ "$r9_line" -lt "$r3_line" ]; then
    echo "PASS  architecture lists every routing rule in order with its model"
    passed=$((passed + 1))
  else
    echo "FAIL  architecture did not list every routing rule in order"
    grep -n "rule" "$idx" || true
    failed=$((failed + 1))
  fi
else
  echo "FAIL  renderer crashed on fixtures"
  failed=$((failed + 1))
fi

# ---- test 3: malicious string is html.escape-d (no raw <script>) ----
root3="$tmpdir/root3"
make_root "$root3" tests/site/fixtures/malicious.md tests/site/fixtures/models.yaml
out3="$tmpdir/out3"
if "$PYTHON" scripts/factory-site.py --repo-root "$root3" --out "$out3" --now "2026-11-11 12:00:00" >/dev/null; then
  idx3="$out3/index.html"
  if ! grep -qF "<script>alert(1)</script>" "$idx3" \
     && ! grep -qF "<img src=x onerror=alert(1)>" "$idx3" \
     && grep -qF "&lt;script&gt;alert(1)&lt;/script&gt;" "$idx3" \
     && grep -qF "&lt;img src=x onerror=alert(1)&gt;" "$idx3"; then
    echo "PASS  malicious string is html.escape-d (no raw <script>)"
    passed=$((passed + 1))
  else
    echo "FAIL  malicious string was not escaped"
    grep -n "script\|img" "$idx3" || true
    failed=$((failed + 1))
  fi
else
  echo "FAIL  renderer crashed on malicious fixture"
  failed=$((failed + 1))
fi

# ---- test 4: renamed FACTORY.md heading shows section-not-found note ----
root4="$tmpdir/root4"
make_root "$root4" tests/site/fixtures/FACTORY.md tests/site/fixtures/models.yaml
# Rename the "## Loop" heading so the section is no longer found.
sed 's/^## Loop$/## The Loop/' "$root4/.factory/FACTORY.md" >"$tmpdir/renamed.md"
cp "$tmpdir/renamed.md" "$root4/.factory/FACTORY.md"
out4="$tmpdir/out4"
if "$PYTHON" scripts/factory-site.py --repo-root "$root4" --out "$out4" --now "2026-11-11 12:00:00" >/dev/null; then
  if grep -q "section not found in FACTORY.md" "$out4/index.html"; then
    echo "PASS  renamed FACTORY.md heading shows section-not-found note, not a crash"
    passed=$((passed + 1))
  else
    echo "FAIL  renamed FACTORY.md heading did not show section-not-found note"
    grep -n "not found" "$out4/index.html" || true
    failed=$((failed + 1))
  fi
else
  echo "FAIL  renderer crashed on renamed FACTORY.md heading"
  failed=$((failed + 1))
fi

# ---- test 5: missing models.yaml key fails softly without FACTORY.md note ----
root5="$tmpdir/root5"
no_checks_yaml="$tmpdir/no-checks.yaml"
# A models.yaml that omits the `checks` key entirely.
"$PYTHON" - "$no_checks_yaml" <<'PY'
import sys
import yaml
with open("tests/site/fixtures/models.yaml") as f:
    d = yaml.safe_load(f)
d.pop("checks", None)
with open(sys.argv[1], "w") as f:
    yaml.safe_dump(d, f, sort_keys=False)
PY
make_root "$root5" tests/site/fixtures/FACTORY.md "$no_checks_yaml"
out5="$tmpdir/out5"
if "$PYTHON" scripts/factory-site.py --repo-root "$root5" --out "$out5" --now "2026-11-11 12:00:00" >/dev/null; then
  if grep -q "checks not found in models.yaml" "$out5/index.html" \
     && ! grep -q "section not found in FACTORY.md" "$out5/index.html"; then
    echo "PASS  missing models.yaml key fails softly without a FACTORY.md section-not-found note"
    passed=$((passed + 1))
  else
    echo "FAIL  missing models.yaml key did not fail softly without the FACTORY.md note"
    grep -n "not found" "$out5/index.html" || true
    failed=$((failed + 1))
  fi
else
  echo "FAIL  renderer crashed on missing models.yaml key"
  failed=$((failed + 1))
fi

# ---- test 6: second render is byte-identical with pinned build time ----
out6a="$tmpdir/out6a"
out6b="$tmpdir/out6b"
if "$PYTHON" scripts/factory-site.py --repo-root "$root2" --out "$out6a" --now "2026-11-11 12:00:00" >/dev/null \
   && "$PYTHON" scripts/factory-site.py --repo-root "$root2" --out "$out6b" --now "2026-11-11 12:00:00" >/dev/null; then
  if diff -r "$out6a" "$out6b" >/dev/null; then
    echo "PASS  second render is byte-identical with pinned build time"
    passed=$((passed + 1))
  else
    echo "FAIL  second render is not byte-identical with pinned build time"
    diff -r "$out6a" "$out6b" || true
    failed=$((failed + 1))
  fi
else
  echo "FAIL  deterministic render failed to run"
  failed=$((failed + 1))
fi

# ---- test 7: financials/backlog/dbt tabs show placeholder when data missing ----
root7="$tmpdir/root7"
make_root "$root7" tests/site/fixtures/FACTORY.md tests/site/fixtures/models.yaml
out7="$tmpdir/out7"
emptydata="$tmpdir/emptydata"
mkdir -p "$emptydata/marts"
if "$PYTHON" scripts/factory-site.py --repo-root "$root7" --data "$emptydata" --out "$out7" --now "2026-11-11 12:00:00" >/dev/null; then
  ok=1
  for page in financials backlog dbt; do
    grep -q "This tab is not available yet" "$out7/$page.html" || ok=0
  done
  if [ "$ok" = 1 ]; then
    echo "PASS  financials/backlog/dbt tabs show placeholder when data missing"
    passed=$((passed + 1))
  else
    echo "FAIL  placeholder not shown for a missing-data tab"
    failed=$((failed + 1))
  fi
else
  echo "FAIL  placeholder render failed"
  failed=$((failed + 1))
fi

# ---- test 8: site HTML has no script src or remote CSS, and only GitHub/dbt links ----
ok8=1
if rg -n '<script src=' site/*.html; then
  ok8=0
fi
if rg -n '<link[^>]+stylesheet[^>]+https?://' site/*.html; then
  ok8=0
fi
# Any http(s) link must be to GitHub or dbt docs.
badlinks="$(rg -no 'https?://[^"'"'"' >]+' site/*.html | \
  grep -Ev 'github\.com|docs\.getdbt\.com' || true)"
if [ -n "$badlinks" ]; then
  printf '%s\n' "$badlinks"
  ok8=0
fi
if [ "$ok8" = 1 ]; then
  echo "PASS  site HTML has no script src or remote CSS, and only GitHub or dbt-docs http(s) links"
  passed=$((passed + 1))
else
  echo "FAIL  site HTML contains a forbidden script/remote-CSS/non-docs link"
  failed=$((failed + 1))
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
