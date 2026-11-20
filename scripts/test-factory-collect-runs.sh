#!/usr/bin/env bash
# Test scripts/factory-collect-runs.py offline against the fixture.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"

if ! "$PYTHON" -c "import jsonschema" 2>/dev/null; then
  echo "ERROR: jsonschema is not installed (required for run-record validation)." >&2
  echo "Install factory requirements in a virtualenv, for example:" >&2
  echo "  python3 -m venv .venv" >&2
  echo "  source .venv/bin/activate" >&2
  echo "  pip install -r requirements-factory.txt" >&2
  echo "  bash scripts/test-factory-collect-runs.sh" >&2
  echo "Or set FACTORY_PYTHON to the venv interpreter." >&2
  exit 1
fi

passed=0
failed=0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() {
  echo "PASS  $1"
  passed=$((passed + 1))
}

fail() {
  echo "FAIL  $1"
  failed=$((failed + 1))
}

out_dir="$tmp/runs"
"$PYTHON" scripts/factory-collect-runs.py \
  --from-json tests/collect-runs/comments.json \
  --out "$out_dir" >"$tmp/summary1.txt"

if [ -f "$out_dir/gha-90000000001-1.json" ]; then
  pass "collector: valid bot record written"
else
  fail "collector: valid bot record written"
fi

if [ ! -f "$out_dir/gha-99999999999-1.json" ]; then
  pass "collector: human-posted record ignored"
else
  fail "collector: human-posted record ignored"
fi

if [ ! -f "$out_dir/gha-88888888888-1.json" ]; then
  pass "collector: no-marker comment ignored"
else
  fail "collector: no-marker comment ignored"
fi

if [ ! -f "$out_dir/gha-77777777777-1.json" ]; then
  pass "collector: invalid JSON block skipped"
else
  fail "collector: invalid JSON block skipped"
fi

if grep -Fq "Most recently updated duplicate: this note should win the dedupe." \
  "$out_dir/gha-90000000001-1.json"; then
  pass "collector: duplicate run_id deduped to newest comment"
else
  fail "collector: duplicate run_id deduped to newest comment"
fi

if "$PYTHON" factory/dbt/runs_to_seeds.py \
  --runs "$out_dir/*.json" \
  --out "$tmp/seeds" >"$tmp/seeds1.txt" 2>&1 \
  && [ -f "$tmp/seeds/agent_runs.csv" ]; then
  pass "collector: runs_to_seeds builds agent_runs.csv from output"
else
  fail "collector: runs_to_seeds builds agent_runs.csv from output"
fi

out_dir2="$tmp/runs2"
"$PYTHON" scripts/factory-collect-runs.py \
  --from-json tests/collect-runs/comments.json \
  --out "$out_dir2" >"$tmp/summary2.txt"
if diff -r "$out_dir" "$out_dir2" >/dev/null; then
  pass "collector: second run byte-identical"
else
  fail "collector: second run byte-identical"
fi

expect_collect_fail() {
  local label=$1
  shift
  set +e
  err="$("$PYTHON" scripts/factory-collect-runs.py "$@" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] \
    && printf '%s\n' "$err" | grep -q '^ERROR:' \
    && ! printf '%s\n' "$err" | grep -q '^Traceback'; then
    pass "collector: $label (exit $rc, ERROR on stderr, no traceback)"
  else
    fail "collector: $label (expected clean ERROR exit, rc=$rc)"
    printf '%s\n' "$err" | sed 's/^/       /'
  fi
}

expect_collect_fail "missing --from-json file" \
  --from-json "$tmp/does-not-exist.json" --out "$tmp/missing-out"

printf '[not valid json\n' >"$tmp/broken-comments.json"
expect_collect_fail "malformed --from-json" \
  --from-json "$tmp/broken-comments.json" --out "$tmp/broken-out"

printf '\xff\xfe{\n' >"$tmp/binary-comments.json"
expect_collect_fail "non-UTF-8 --from-json" \
  --from-json "$tmp/binary-comments.json" --out "$tmp/binary-out"

printf '{"run_id": "gha-1-1"}\n' >"$tmp/not-array.json"
expect_collect_fail "--from-json not a JSON array" \
  --from-json "$tmp/not-array.json" --out "$tmp/not-array-out"

"$PYTHON" - "$tmp" <<'PY'
import json
import sys
from pathlib import Path

tmpdir = Path(sys.argv[1])
base = json.loads(Path("tests/run-records/pass-pr-opened.json").read_text(encoding="utf-8"))
base["run_id"] = "gha-66666666666-1"
base["work_type"] = "coding"
body = (
    "<!-- factory-run-record -->\n"
    "Invalid work_type in bot comment.\n\n"
    f"```json\n{json.dumps(base, indent=2)}\n```"
)
comments = [
    {
        "id": 9001,
        "html_url": "https://github.com/example-org/sample-app/issues/1#issuecomment-9001",
        "user": {"login": "github-actions[bot]"},
        "body": body,
        "updated_at": "2026-11-07T00:00:00Z",
    }
]
path = tmpdir / "bad-work-type-comments.json"
path.write_text(json.dumps(comments, indent=2) + "\n", encoding="utf-8")
PY

out_bad_wt="$tmp/runs-bad-wt"
"$PYTHON" scripts/factory-collect-runs.py \
  --from-json "$tmp/bad-work-type-comments.json" \
  --out "$out_bad_wt" >"$tmp/bad-wt-summary.txt"

if [ ! -f "$out_bad_wt/gha-66666666666-1.json" ] \
  && grep -Fq "work_type" "$tmp/bad-wt-summary.txt"; then
  pass "collector: bad work_type in comment skipped"
else
  fail "collector: bad work_type in comment skipped"
fi

"$PYTHON" - "$tmp" <<'PY'
import json
import sys
from pathlib import Path

tmpdir = Path(sys.argv[1])
base = json.loads(Path("tests/run-records/pass-pr-opened.json").read_text(encoding="utf-8"))
base["run_id"] = "gha-55555555555-1"
base["tokens_in"] = -1
body = (
    "<!-- factory-run-record -->\n"
    "Negative tokens in bot comment.\n\n"
    f"```json\n{json.dumps(base, indent=2)}\n```"
)
comments = [
    {
        "id": 9002,
        "html_url": "https://github.com/example-org/sample-app/issues/1#issuecomment-9002",
        "user": {"login": "github-actions[bot]"},
        "body": body,
        "updated_at": "2026-11-07T00:00:00Z",
    }
]
path = tmpdir / "negative-tokens-comments.json"
path.write_text(json.dumps(comments, indent=2) + "\n", encoding="utf-8")
PY

out_neg="$tmp/runs-neg"
"$PYTHON" scripts/factory-collect-runs.py \
  --from-json "$tmp/negative-tokens-comments.json" \
  --out "$out_neg" >"$tmp/neg-summary.txt"

if [ ! -f "$out_neg/gha-55555555555-1.json" ] \
  && grep -Fq "tokens_in" "$tmp/neg-summary.txt"; then
  pass "collector: negative tokens_in in comment skipped"
else
  fail "collector: negative tokens_in in comment skipped"
fi

if GITHUB_REPOSITORY='acme-corp/widget-factory' "$PYTHON" -c "
from pathlib import Path
import importlib.util
spec = importlib.util.spec_from_file_location(
    'collect', Path('scripts/factory-collect-runs.py'))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert mod.resolve_github_repo(None) == 'acme-corp/widget-factory'
assert mod.resolve_github_repo('override/org-repo') == 'override/org-repo'
"; then
  pass "collector: resolve_github_repo uses env and --repo override"
else
  fail "collector: resolve_github_repo uses env and --repo override"
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
