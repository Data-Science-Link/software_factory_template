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

# ---- test 2: build --sample copies style.css into site/ ----
if [ -f site/style.css ]; then
  echo "PASS  build --sample copies style.css into site/"
  passed=$((passed + 1))
else
  echo "FAIL  build --sample did not copy style.css into site/"
  failed=$((failed + 1))
fi

# ---- test 3: architecture lists every routing rule in order with its model ----
root2="$tmpdir/root2"
make_root "$root2" tests/site/fixtures/FACTORY.md tests/site/fixtures/models.yaml
out2="$tmpdir/out2"
if "$PYTHON" scripts/factory-site.py --repo-root "$root2" --out "$out2" --now "2026-11-11 12:00:00" >/dev/null; then
  idx="$out2/index.html"
  ok=1
  grep -q "deepseek-ai/DeepSeek-V4-Pro-0813" "$idx" || ok=0
  grep -q "deepseek-ai/DeepSeek-V4-Flash-0731" "$idx" || ok=0
  # The routing-rules table renders each rule as a <tr><th>N</th>...<td>model</td></tr>
  # row. Verify the rules appear as <th> cells in first-match order (2, 9, 3),
  # each row carrying its model.
  if ! "$PYTHON" - "$idx" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
table = re.search(r"<h2>Routing rules \(first match wins\)</h2>(.*?)</table>", html, re.S)
if not table:
    raise SystemExit("no routing rules table")
rows = re.findall(r"<tr>\s*<th>(\d+)</th>(.*?)</tr>", table.group(1), re.S)
expect = [(2, "deepseek-ai/DeepSeek-V4-Pro-0813"),
          (9, "deepseek-ai/DeepSeek-V4-Flash-0731"),
          (3, "deepseek-ai/DeepSeek-V4-Flash-0731")]
nums = [int(n) for n, _ in rows]
if nums != [e[0] for e in expect]:
    raise SystemExit("rule order mismatch: %r" % nums)
for (n, body), (en, em) in zip(rows, expect):
    if int(n) != en or em not in body:
        raise SystemExit("rule %d missing model %s" % (n, em))
PY
  then
    ok=0
  fi
  if [ "$ok" = 1 ]; then
    echo "PASS  architecture lists every routing rule in order with its model"
    passed=$((passed + 1))
  else
    echo "FAIL  architecture did not list every routing rule in order"
    grep -n '<th>' "$idx" || true
    failed=$((failed + 1))
  fi
else
  echo "FAIL  renderer crashed on fixtures"
  failed=$((failed + 1))
fi

# ---- test 4: malicious string is html.escape-d (no raw <script>) ----
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

# ---- test 5: renamed FACTORY.md heading shows section-not-found note ----
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

# ---- test 6: missing models.yaml key fails softly without FACTORY.md note ----
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

# ---- test 7: second render is byte-identical with pinned build time ----
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

# ---- test 8: financials/backlog/dbt tabs show placeholder when data missing ----
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

# ---- test 9: site HTML has no script src or remote CSS, and only GitHub/dbt links ----
ok8=1
# Fail loudly if a required tool is missing; never pass by default.
for t in grep sed; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "FAIL  required tool '$t' is not installed"
    failed=$((failed + 1))
    exit 1
  fi
done
if grep -n '<script src=' site/*.html; then
  ok8=0
fi
if grep -n '<link[^>]*stylesheet[^>]*https\?://' site/*.html; then
  ok8=0
fi
# Any http(s) link must be to GitHub or dbt docs.
badlinks="$(grep -no 'https\?://[^"'"'"' >]*' site/*.html 2>/dev/null | \
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

# ---- test 10: architecture tab has a loop <svg> and no literal ** markers ----
root9="$tmpdir/root9"
make_root "$root9" tests/site/fixtures/FACTORY.md tests/site/fixtures/models.yaml
out9="$tmpdir/out9"
if "$PYTHON" scripts/factory-site.py --repo-root "$root9" --out "$out9" --now "2026-11-11 12:00:00" >/dev/null; then
  idx9="$out9/index.html"
  ok9=1
  grep -q "<svg" "$idx9" || ok9=0
  if grep -qF "**" "$idx9"; then
    ok9=0
  fi
  if [ "$ok9" = 1 ]; then
    echo "PASS  architecture tab has a loop <svg> and no literal ** markers"
    passed=$((passed + 1))
  else
    echo "FAIL  architecture tab missing <svg> or contains literal ** markers"
    grep -n "<svg\|\*\*" "$idx9" || true
    failed=$((failed + 1))
  fi
else
  echo "FAIL  renderer crashed for architecture svg check"
  failed=$((failed + 1))
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
