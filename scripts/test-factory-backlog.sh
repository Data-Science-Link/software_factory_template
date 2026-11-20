#!/usr/bin/env bash
# Test scripts/factory-backlog.py and the Backlog tab rendered by
# scripts/factory-site.py. Runs entirely offline from the committed fixture
# tests/site/fixtures/issues.json; never invokes gh, scripts/factory-collect-runs.py,
# or any network.
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

backlog="$tmpdir/backlog.json"
if ! "$PYTHON" scripts/factory-backlog.py \
  --from-json tests/site/fixtures/issues.json \
  --out "$backlog"; then
  echo "FAIL  factory-backlog.py did not run on the fixture"
  exit 1
fi

# ---- test 1: JSON counts by priority and risk match the hand count ----
if "$PYTHON" - "$backlog" <<'PY'
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8"))
prio = {"high": 0, "low": 0, "none": 0}
risk = {}
for i in items:
    prio[i["priority"]] += 1
    risk[i["risk"]] = risk.get(i["risk"], 0) + 1
if items[0]["number"] == 4 or any(i["number"] == 4 for i in items):
    raise SystemExit("pull request not excluded")
if prio != {"high": 2, "low": 1, "none": 1}:
    raise SystemExit("priority counts mismatch: %r" % prio)
if risk != {"high": 1, "medium": 1, "low": 1, "unlabeled": 1}:
    raise SystemExit("risk counts mismatch: %r" % risk)
PY
then
  echo "PASS  backlog JSON counts by priority and risk match the hand count"
  passed=$((passed + 1))
else
  echo "FAIL  backlog JSON counts by priority and risk do not match the hand count"
  failed=$((failed + 1))
fi

# ---- test 2: every issue output includes a title (no --titles switch) ----
if "$PYTHON" - "$backlog" <<'PY'
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8"))
for i in items:
    if "title" not in i or not i["title"]:
        raise SystemExit("issue %s missing title" % i.get("number"))
if not items:
    raise SystemExit("fixture produced no issues")
PY
then
  echo "PASS  every issue output includes a title (no --titles switch)"
  passed=$((passed + 1))
else
  echo "FAIL  an issue output is missing a title"
  failed=$((failed + 1))
fi

# ---- test 3: pull requests are excluded from the fixture result ----
if ! "$PYTHON" - "$backlog" <<'PY'
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8"))
nums = [i.get("number") for i in items]
if 4 in nums:
    raise SystemExit("pull request #4 not excluded")
if len(nums) != 4:
    raise SystemExit("expected 4 issues after PR exclusion, got %r" % nums)
PY
then
  echo "FAIL  pull requests were not excluded"
  failed=$((failed + 1))
else
  echo "PASS  pull requests are excluded from the fixture result"
  passed=$((passed + 1))
fi

# ---- test 4: an issue with no labels normalizes to priority none / risk unlabeled / status open ----
if "$PYTHON" - "$backlog" <<'PY'
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8"))
nolabel = [i for i in items if i["number"] == 3]
if not nolabel:
    raise SystemExit("no-label issue #3 not found")
i = nolabel[0]
if i["priority"] != "none" or i["risk"] != "unlabeled" or i["status"] != "open":
    raise SystemExit("no-label issue normalized wrong: %r" % i)
PY
then
  echo "PASS  an issue with no labels normalizes to priority none / risk unlabeled / status open"
  passed=$((passed + 1))
else
  echo "FAIL  no-label issue did not normalize correctly"
  failed=$((failed + 1))
fi

# ---- test 5: two priority: labels take the higher one ----
if "$PYTHON" - "$backlog" <<'PY'
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8"))
two = [i for i in items if i["number"] == 2]
if not two:
    raise SystemExit("two-priority issue #2 not found")
if two[0]["priority"] != "high":
    raise SystemExit("issue #2 should take the higher priority (high), got %r" % two[0]["priority"])
PY
then
  echo "PASS  two priority: labels take the higher one"
  passed=$((passed + 1))
else
  echo "FAIL  two priority: labels did not take the higher one"
  failed=$((failed + 1))
fi

# Build the render fixtures into a temp repo-root.
make_root() {
  local root="$1" fact="$2" models="$3"
  mkdir -p "$root/.factory" "$root/factory/site" "$root/site-data"
  cp "$fact" "$root/.factory/FACTORY.md"
  cp "$models" "$root/.factory/models.yaml"
  cp factory/site/base.html "$root/factory/site/base.html"
  cp factory/site/style.css "$root/factory/site/style.css"
}

root="$tmpdir/root"
make_root "$root" tests/site/fixtures/FACTORY.md tests/site/fixtures/models.yaml
cp "$backlog" "$root/site-data/backlog.json"
out="$tmpdir/out"
if ! "$PYTHON" scripts/factory-site.py --repo-root "$root" --data "$root/site-data" \
  --out "$out" --now "2026-11-11 12:00:00" >/dev/null; then
  echo "FAIL  renderer crashed while building the Backlog tab"
  exit 1
fi
page="$out/backlog.html"

# ---- test 6: a title with HTML is html.escape-d (no raw <script>) ----
if ! grep -qF "<script>alert(1)</script>" "$page" \
   && grep -qF "&lt;script&gt;alert(1)&lt;/script&gt;" "$page"; then
  echo "PASS  a title with HTML is html.escape-d in the rendered table (no raw <script>)"
  passed=$((passed + 1))
else
  echo "FAIL  a title with HTML was not escaped in the rendered table"
  grep -n "script\|alert" "$page" || true
  failed=$((failed + 1))
fi

# ---- test 7: the tab renders summary cards, priority x risk table, epic list and sorted table ----
if "$PYTHON" - "$page" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
if "This tab is not available yet" in html:
    raise SystemExit("placeholder shown instead of the Backlog tab")
if 'class="cards"' not in html:
    raise SystemExit("summary cards missing")
if "Risk \\ Priority" not in html:
    raise SystemExit("priority x risk table missing")
if "2 / 5 done" not in html:
    raise SystemExit("epic list with done/total missing")
if 'href="https://github.com/example/factory/issues/1"' not in html:
    raise SystemExit("issue link missing")
if 'href="https://github.com/example/factory/issues/2"' not in html:
    raise SystemExit("issue link missing")
if 'href="https://github.com/example/factory/issues/5"' not in html:
    raise SystemExit("issue link missing")
# Sorted issue table: high priority (1,2) before low (5) before none (3).
tbl = re.search(r'<table id="backlog-issues-table">(.*?)</table>', html, re.S)
if not tbl:
    raise SystemExit("no backlog issues table")
rows = re.findall(r"<tr[^>]*>\s*<th>(high|low|none)</th>", tbl.group(1))
if rows != ["high", "high", "low", "none"]:
    raise SystemExit("issue table not sorted by priority: %r" % rows)
PY
then
  echo "PASS  the Backlog tab renders summary cards, priority x risk table, epic list and sorted issue table with links"
  passed=$((passed + 1))
else
  echo "FAIL  the Backlog tab did not render the expected content"
  failed=$((failed + 1))
fi

# ---- test 8: the render is deterministic with a pinned build time ----
out2="$tmpdir/out2"
if "$PYTHON" scripts/factory-site.py --repo-root "$root" --data "$root/site-data" \
  --out "$out2" --now "2026-11-11 12:00:00" >/dev/null \
  && diff "$out/backlog.html" "$out2/backlog.html" >/dev/null; then
  echo "PASS  the render is deterministic with a pinned build time"
  passed=$((passed + 1))
else
  echo "FAIL  the render is not deterministic with a pinned build time"
  diff "$out/backlog.html" "$out2/backlog.html" || true
  failed=$((failed + 1))
fi

# ---- test 9: an empty issues list renders the tab with zero counts, not the placeholder ----
empty="$tmpdir/empty.json"
printf '[]\n' > "$empty"
root2="$tmpdir/root2"
make_root "$root2" tests/site/fixtures/FACTORY.md tests/site/fixtures/models.yaml
cp "$empty" "$root2/site-data/backlog.json"
out3="$tmpdir/out3"
if "$PYTHON" scripts/factory-site.py --repo-root "$root2" --data "$root2/site-data" \
  --out "$out3" --now "2026-11-11 12:00:00" >/dev/null; then
  page3="$out3/backlog.html"
  if grep -q "This tab is not available yet" "$page3"; then
    echo "FAIL  empty issues list rendered the placeholder instead of the tab"
    failed=$((failed + 1))
  elif grep -q "High priority" "$page3" && grep -q "Open issues" "$page3"; then
    echo "PASS  an empty issues list renders the Backlog tab with zero counts, not the placeholder"
    passed=$((passed + 1))
  else
    echo "FAIL  empty issues list did not render the full Backlog tab"
    failed=$((failed + 1))
  fi
else
  echo "FAIL  renderer crashed on an empty issues list"
  failed=$((failed + 1))
fi

# ---- test 10: unlabeled count and triage note when issues lack priority/risk labels ----
if "$PYTHON" - "$page" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
if "Unlabeled issues:" not in html or "backlog-unlabeled" not in html:
    raise SystemExit("unlabeled notice missing")
if "priority:high" not in html or "risk:low" not in html:
    raise SystemExit("label how-to text missing")
# Fixture issue #3 has no priority/risk labels -> 1 unlabeled.
if not re.search(r'Unlabeled issues:</strong>\s*1 open issue', html):
    raise SystemExit("unlabeled count wrong (expected 1)")
if not re.search(r'card-label">Unlabeled</span><span class="card-value">1</span>', html):
    raise SystemExit("Unlabeled summary card missing or wrong count")
PY
then
  echo "PASS  backlog tab shows unlabeled count and triage note for partly labeled issues"
  passed=$((passed + 1))
else
  echo "FAIL  backlog tab did not render the unlabeled count or triage note"
  failed=$((failed + 1))
fi

# ---- test 11: fully labeled fixture omits the unlabeled notice and card ----
labeled="$tmpdir/labeled.json"
"$PYTHON" - "$labeled" <<'PY'
import json, sys
items = [
    {
        "number": 10,
        "title": "Labeled issue A",
        "url": "https://github.com/example/factory/issues/10",
        "createdAt": "2026-11-01T10:00:00Z",
        "updatedAt": "2026-11-10T09:00:00Z",
        "priority": "high",
        "risk": "high",
        "status": "open",
    },
    {
        "number": 11,
        "title": "Labeled issue B",
        "url": "https://github.com/example/factory/issues/11",
        "createdAt": "2026-11-02T11:00:00Z",
        "updatedAt": "2026-11-11T08:30:00Z",
        "priority": "low",
        "risk": "low",
        "status": "open",
    },
]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(items, fh, indent=2)
    fh.write("\n")
PY
root4="$tmpdir/root-labeled"
make_root "$root4" tests/site/fixtures/FACTORY.md tests/site/fixtures/models.yaml
cp "$labeled" "$root4/site-data/backlog.json"
out4="$tmpdir/out-labeled"
if "$PYTHON" scripts/factory-site.py --repo-root "$root4" --data "$root4/site-data" \
  --out "$out4" --now "2026-11-11 12:00:00" >/dev/null; then
  page4="$out4/backlog.html"
  if grep -q "backlog-unlabeled" "$page4" || grep -q 'card-label">Unlabeled' "$page4"; then
    echo "FAIL  fully labeled backlog still shows an unlabeled notice or card"
    failed=$((failed + 1))
  else
    echo "PASS  fully labeled backlog omits unlabeled notice and summary card"
    passed=$((passed + 1))
  fi
else
  echo "FAIL  renderer crashed on fully labeled backlog fixture"
  failed=$((failed + 1))
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
