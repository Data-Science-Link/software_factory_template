#!/usr/bin/env bash
# Validate docs/reusable-workflows/*.yml: YAML shape, workflow_call, pinned action SHAs, callers.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
docs="$root/docs/reusable-workflows"

passed=0
failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }

PYTHON="${FACTORY_PYTHON:-python3}"
if ! "$PYTHON" -c "import yaml" 2>/dev/null; then
  echo "test-reusable-workflows: PyYAML required" >&2
  exit 2
fi

sha_ok() {
  local f="$1"
  local misses
  misses="$(
    F="$f" "$PYTHON" <<'PY'
import re, os
f = os.environ["F"]
lines = open(f).read().splitlines()
while lines and lines[0].startswith('#'):
    lines.pop(0)
text = lines
miss = []
for i, line in enumerate(text, 1):
    if "uses:" not in line:
        continue
    if "software_factory_template/.github/workflows/" in line:
        continue
    m = re.search(r"uses:\s*([^@\s]+)@([^\s#]+)", line)
    if not m:
        continue
    ref = m.group(2)
    if re.fullmatch(r"[0-9a-f]{40}", ref):
        continue
    miss.append(f"line {i}: {m.group(1)}@{ref}")
print("\n".join(miss))
PY
  )"
  if [ -n "$misses" ]; then
    bad "$f unpinned action uses"
    echo "$misses" | sed 's/^/       /'
    return 1
  fi
  ok "$f action SHAs pinned"
  return 0
}

for rf in "$docs"/reusable-*.yml; do
  [ -f "$rf" ] || continue
  name="$(basename "$rf")"
  if ! tail -n +3 "$rf" | grep -q '^on:'; then
    bad "$name missing on:"
    continue
  fi
  if ! tail -n +3 "$rf" | grep -q 'workflow_call:'; then
    bad "$name missing workflow_call"
    continue
  fi
  ok "$name workflow_call"

  if grep -Eqi '(sk-[a-z0-9]{10,}|ghp_[a-zA-Z0-9]{20,}|api[_-]?key\s*[:=]\s*[\"'"'"'][^\"'"'"']+[\"'"'"'])' "$rf"; then
    bad "$name possible hardcoded secret"
  else
    ok "$name no hardcoded secret patterns"
  fi
  sha_ok "$rf" || true
done

mapfile -t pairs < <(
  for c in opencode-spec opencode-run opencode-fix pr-check factory-site; do
    printf '%s\treusable-%s.yml\n' "$c" "$c"
  done
)

for pair in "${pairs[@]}"; do
  caller="${pair%%	*}"
  reusable="${pair##*	}"
  cf="$docs/callers/${caller}.yml"
  [ -f "$cf" ] || { bad "missing caller $caller.yml"; continue; }
  if ! grep -q "software_factory_template/.github/workflows/${reusable}@v" "$cf"; then
    bad "caller $caller does not reference $reusable"
    continue
  fi
  if ! grep -q 'secrets: inherit' "$cf"; then
    bad "caller $caller missing secrets: inherit"
    continue
  fi
  if ! "$PYTHON" -c "import yaml; yaml.safe_load(open('$cf'))" 2>/dev/null; then
    bad "caller $caller invalid YAML"
    continue
  fi
  ok "caller $caller"
done

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]