#!/usr/bin/env bash
# Plain-markdown token usage from `opencode stats --models` (no TUI boxes, no secrets).
set -euo pipefail

out="${1:-}"

raw=""
if command -v opencode >/dev/null 2>&1; then
  raw="$(opencode stats --models 2>&1)" || true
fi

field() {
  local label=$1
  printf '%s\n' "$raw" | grep -F "│${label}" | head -1 \
    | sed -E 's/^[^│]*│[^│]*[[:space:]]+([^│]+)│.*$/\1/' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

input="$(field Input)"
output="$(field Output)"
cache_read="$(field "Cache Read")"
model_line="$(printf '%s\n' "$raw" | grep -F 'deepinfra/deepseek-ai' | head -1 | sed 's/^[[:space:]]*│[[:space:]]*//;s/[[:space:]]*│.*$//' | sed 's/[[:space:]]*$//')"
model="${model_line:-deepinfra/deepseek-ai/DeepSeek-V4-Flash-0731}"
cost="$(
  printf '%s\n' "$raw" | grep -E '│[[:space:]]*Cost[[:space:]]+\$' \
    | grep -vE '\$0\.00[[:space:]]*\│' | tail -1 \
    | sed -E 's/.*(\$[0-9]+(\.[0-9]+)?).*/\1/' || true
)"

if [ -n "$input" ]; then
  body="## Token usage (opencode stats)

- Model: ${model}
- Input tokens: ${input}
- Output tokens: ${output}
- Cache read: ${cache_read}
- OpenCode-reported cost: ${cost:-not available}
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
