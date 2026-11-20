#!/usr/bin/env bash
# Offline tests for scripts/factory-spec-lint.py
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "PyYAML is required. Install: pip install -r requirements-factory.txt" >&2
  exit 2
fi

fixtures="tests/spec-lint"
passed=0
failed=0

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_rc() {
  local label="$1" expect="$2"
  shift 2
  set +e
  local out
  out="$("$@" 2>&1)"
  local rc=$?
  set -e
  if [ "$expect" = "$rc" ]; then
    echo "PASS  $label"
    passed=$((passed + 1))
  else
    echo "FAIL  $label (expected exit $expect, got $rc)"
    echo "$out" | head -8
    failed=$((failed + 1))
  fi
}

assert_rc_contains() {
  local label="$1" expect_rc="$2" needle="$3"
  shift 3
  set +e
  local out
  out="$("$@" 2>&1)"
  local rc=$?
  set -e
  if [ "$expect_rc" = "$rc" ] && printf '%s\n' "$out" | grep -Fq "$needle"; then
    echo "PASS  $label"
    passed=$((passed + 1))
  else
    echo "FAIL  $label (expected exit $expect_rc and message containing: $needle)"
    echo "$out" | head -8
    failed=$((failed + 1))
  fi
}

assert_rc "valid spec" 0 python3 scripts/factory-spec-lint.py "$fixtures/pass-valid.md"

assert_rc "unicode title" 0 python3 scripts/factory-spec-lint.py "$fixtures/pass-unicode-title.md"

assert_rc "missing Bad inputs section" 1 \
  python3 scripts/factory-spec-lint.py "$fixtures/fail-missing-bad-inputs.md"

assert_rc "empty Bad inputs section" 1 \
  python3 scripts/factory-spec-lint.py "$fixtures/fail-empty-bad-inputs.md"

assert_rc "masked pipe in Verification (head)" 1 \
  python3 scripts/factory-spec-lint.py "$fixtures/fail-masked-pipe.md"

for pipe_fixture in fail-masked-pipe-tail fail-masked-pipe-grep fail-masked-pipe-sed fail-masked-pipe-awk; do
  assert_rc_contains "masked pipe ($pipe_fixture)" 1 "without pipefail" \
    python3 scripts/factory-spec-lint.py "$fixtures/${pipe_fixture}.md"
done

assert_rc_contains "masked pipe with pipefail still blocked" 1 "head/tail/sed/grep/awk" \
  python3 scripts/factory-spec-lint.py "$fixtures/fail-masked-pipe-with-pipefail.md"

assert_rc "template: forbidden workflow path" 1 \
  python3 scripts/factory-spec-lint.py --mode template "$fixtures/fail-template-workflow.md"

assert_rc "template: protected script path (factory-cost)" 1 \
  python3 scripts/factory-spec-lint.py --mode template "$fixtures/fail-template-protected.md"

for prot in fail-template-protected-issue-spend fail-template-protected-harden-repo \
  fail-template-protected-opencode-worker-test; do
  assert_rc_contains "template: $prot (#248)" 1 "protected spend/security script" \
    python3 scripts/factory-spec-lint.py --mode template "$fixtures/${prot}.md"
done

assert_rc "product: scripts/foo.sh path" 1 \
  python3 scripts/factory-spec-lint.py --mode product "$fixtures/fail-product-scripts.md"

assert_rc "bad front matter enum" 1 \
  python3 scripts/factory-spec-lint.py "$fixtures/fail-bad-enum.md"

assert_rc_contains "unknown risk value" 1 "front matter risk must be one of" \
  python3 scripts/factory-spec-lint.py "$fixtures/fail-unknown-risk.md"

assert_rc "unquoted colon in title" 1 \
  python3 scripts/factory-spec-lint.py "$fixtures/fail-unquoted-colon-title.md"

assert_rc_contains "incomplete front matter delimiter" 1 "missing closing ---" \
  python3 scripts/factory-spec-lint.py "$fixtures/fail-incomplete-front-matter.md"

assert_rc_contains "duplicate front matter keys" 1 "duplicate front matter key: issue" \
  python3 scripts/factory-spec-lint.py "$fixtures/fail-duplicate-fm-keys.md"

missing="$tmpdir/missing-spec.md"
assert_rc_contains "missing spec file" 1 "not a file:" \
  python3 scripts/factory-spec-lint.py "$missing"

: >"$tmpdir/empty.md"
assert_rc "empty spec file" 1 python3 scripts/factory-spec-lint.py "$tmpdir/empty.md"

printf '\x00\xff\xfe' >"$tmpdir/binary.md"
assert_rc_contains "binary spec file (no traceback)" 1 "not valid UTF-8" \
  python3 scripts/factory-spec-lint.py "$tmpdir/binary.md"

json_out="$tmpdir/json-out.json"
if python3 scripts/factory-spec-lint.py --json "$fixtures/pass-valid.md" >"$json_out"; then
  if python3 - "$json_out" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert "results" in data and "summary" in data
r = data["results"][0]
for key in ("path", "ok", "errors", "warnings"):
    assert key in r, key
assert r["ok"] is True
assert data["summary"]["files"] == 1
PY
  then
    echo "PASS  --json schema"
    passed=$((passed + 1))
  else
    echo "FAIL  --json schema"
    cat "$json_out"
    failed=$((failed + 1))
  fi
else
  echo "FAIL  --json exit code"
  failed=$((failed + 1))
fi

json_a="$tmpdir/json-a.json"
json_b="$tmpdir/json-b.json"
python3 scripts/factory-spec-lint.py --json "$fixtures/pass-valid.md" "$fixtures/pass-unicode-title.md" \
  >"$json_a"
python3 scripts/factory-spec-lint.py --json "$fixtures/pass-valid.md" "$fixtures/pass-unicode-title.md" \
  >"$json_b"
if cmp -s "$json_a" "$json_b"; then
  echo "PASS  --json deterministic"
  passed=$((passed + 1))
else
  echo "FAIL  --json deterministic"
  diff -u "$json_a" "$json_b" | head -20 || true
  failed=$((failed + 1))
fi
rm -f "$json_out" "$json_a" "$json_b"

echo "Results: ${passed} passed, ${failed} failed"
[ "$failed" -eq 0 ]