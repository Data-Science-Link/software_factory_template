#!/usr/bin/env bash
# Plain-markdown token usage from `opencode stats --models` (no TUI boxes, no secrets).
set -euo pipefail

out="${1:-}"

raw=""
if [ -n "${OPENCODE_STATS_FIXTURE:-}" ] && [ -f "$OPENCODE_STATS_FIXTURE" ]; then
  raw="$(cat "$OPENCODE_STATS_FIXTURE")"
elif command -v opencode >/dev/null 2>&1; then
  raw="$(opencode stats --models 2>&1)" || true
fi

field() {
  local label=$1 v
  set +o pipefail
  v="$(printf '%s\n' "$raw" | grep -F "│${label}" | head -1 \
    | sed -E 's/^[^│]*│[^│]*[[:space:]]+([^│]+)│.*$/\1/' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  set -o pipefail
  printf '%s' "$v"
}

input="$(field Input)"
output="$(field Output)"
cache_read="$(field "Cache Read")"
set +o pipefail
model_line="$(
  printf '%s\n' "$raw" | grep -E '│[[:space:]]*deepinfra/' | head -1 \
    | sed -E 's/^[[:space:]]*│[[:space:]]*([^│]+).*/\1/' \
    | sed 's/[[:space:]]*$//'
)"
set -o pipefail
if [ -n "$model_line" ]; then
  model="$model_line"
else
  model="unknown (not in stats)"
fi

cost="$(
  printf '%s\n' "$raw" | grep -E '│[[:space:]]*Cost[[:space:]]+\$' \
    | grep -vE '\$0\.00[[:space:]]*\│' | tail -1 \
    | sed -E 's/.*(\$[0-9]+(\.[0-9]+)?).*/\1/' || true
)"
cost_display="${cost:-not measured}"

if [ -n "$input" ]; then
  body="## Token usage (opencode stats)

- Model: ${model}
- Input tokens: ${input}
- Output tokens: ${output}
- Cache read: ${cache_read}
- OpenCode-reported cost: ${cost_display}
- Source: \`opencode stats --models\`"
else
  body="## Token usage (opencode stats)

(not available — \`opencode stats --models\` returned no parseable rows on this runner)"
fi

if [ -n "$out" ]; then
  printf '%s\n' "$body" >"$out"
fi
printf '%s\n' "$body"

if [ -n "$cost" ]; then
  printf 'OC_OPENCODE_COST=%s\n' "$cost"
fi
