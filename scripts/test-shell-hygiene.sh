#!/usr/bin/env bash
# Static hygiene for scripts/: syntax, test strict mode, portable sed, factory Python compile (Refs #38, #178).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

failed=0
passed=0

pass() {
  echo "PASS  $*"
  passed=$((passed + 1))
}

fail() {
  echo "FAIL  $*"
  failed=$((failed + 1))
}

bash_n_fail=0
for sh in scripts/*.sh; do
  [ -f "$sh" ] || continue
  if ! bash -n "$sh" 2>/tmp/shell-hygiene-bash-n.err; then
    fail "bash -n $sh"
    head -5 /tmp/shell-hygiene-bash-n.err >&2 || true
    bash_n_fail=1
  fi
done
rm -f /tmp/shell-hygiene-bash-n.err
[ "$bash_n_fail" -eq 0 ] && pass "bash -n (all scripts/*.sh)"

strict_fail=0
for t in scripts/test-*.sh; do
  [ -f "$t" ] || continue
  if ! grep -qE 'set -e(uo pipefail|o pipefail|-e)' "$t"; then
    fail "$t missing set -e / set -euo pipefail"
    strict_fail=1
  fi
done
[ "$strict_fail" -eq 0 ] && pass "test-*.sh strict mode (set -e)"

if ! python3 - <<'PY'
import pathlib
import re
import sys

pattern = re.compile(r"""sed -i ['"]""")
bad = []
for path in sorted(pathlib.Path("scripts").glob("*.sh")):
    if path.name == "test-shell-hygiene.sh":
        continue
    for i, line in enumerate(path.read_text().splitlines(), 1):
        code = line.split("#", 1)[0]
        if pattern.search(code):
            bad.append(f"{path}:{i}:{line.strip()}")
if bad:
    for row in bad:
        print(row, file=sys.stderr)
    sys.exit(1)
PY
then
  fail "portable sed (non-BSD-safe in-place sed in scripts/*.sh)"
else
  pass "portable sed (no bare sed -i in scripts/*.sh)"
fi

py_fail=0
for py in scripts/factory-*.py; do
  [ -f "$py" ] || continue
  if ! python3 -m py_compile "$py" 2>/tmp/shell-hygiene-py.err; then
    fail "py_compile $py"
    head -3 /tmp/shell-hygiene-py.err >&2 || true
    py_fail=1
  fi
done
rm -f /tmp/shell-hygiene-py.err
[ "$py_fail" -eq 0 ] && pass "py_compile (scripts/factory-*.py)"

echo "Results: ${passed} passed, ${failed} failed"
[ "$failed" -eq 0 ]