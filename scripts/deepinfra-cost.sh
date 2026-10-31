#!/usr/bin/env bash
set -euo pipefail

# deepinfra-cost.sh — read DeepInfra spend from the payment/key-limits API.
#
# Usage:
#   deepinfra-cost.sh spend [key-name]
#       Print the current spend for KEY-NAME as a plain number. This is the
#       API reader that scripts/factory-cost.sh uses.
#
#   deepinfra-cost.sh start [key-name]
#       Save the current-month spend for KEY-NAME to .factory-cost-start.
#       .factory-cost-start is gitignored (never committed).
#
#   deepinfra-cost.sh end [key-name]
#       Print the difference between the current spend and the saved start
#       value: "Cost: $X.XXXX on DeepInfra". Also prints caching info if
#       the response includes cached_input tokens.
#
# For factory runs, prefer scripts/factory-cost.sh (keeps the start value
# in an issue comment, so there's no local state file).
#
# Key name: the argument, else FACTORY_DEEPINFRA_KEY_NAME. If neither is set
# and the account has exactly one key, that key is used; with more than one,
# the script stops and lists the names.
#
# Requires DEEPINFRA_API_KEY in the environment, plus curl and jq.
# The key is sent to curl on stdin, so it never shows in the process list
# and is never printed.

GITIGNORE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || echo '.' )"
STATE_FILE="${GITIGNORE_DIR}/.factory-cost-start"

command="${1:-}"
key_name="${2:-${FACTORY_DEEPINFRA_KEY_NAME:-}}"

if [ -z "$command" ]; then
  echo "Usage: $0 <spend|start|end> [key-name]" >&2
  exit 1
fi

if [ -z "${DEEPINFRA_API_KEY:-}" ]; then
  echo "ERROR: DEEPINFRA_API_KEY is not set. Agent: stop here and tell the owner this message; don't look for the key. Owner: see .factory/skills/local-owner-setup.md step 3." >&2
  exit 1
fi

for tool in curl jq awk; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool is required but not installed." >&2
    exit 1
  fi
done

# Fetch spend from DeepInfra payment/key-limits. The auth header is read
# from stdin (-H @-) so the key is not in curl's arguments.
response="$(printf 'Authorization: Bearer %s\n' "$DEEPINFRA_API_KEY" \
  | curl -s -f -H @- "https://api.deepinfra.com/payment/key-limits" 2>/dev/null || true)"

if [ -z "$response" ]; then
  echo "ERROR: No response from DeepInfra API. Check your network and key." >&2
  exit 1
fi

# The response is a flat array of key objects: [ { "name": "...", "spend": ..., ... }, ... ]

# No key name given: use the only key, or stop and list the names.
if [ -z "$key_name" ]; then
  count="$(printf '%s' "$response" | jq -r 'length' 2>/dev/null || echo "")"
  if [ "$count" = "1" ]; then
    key_name="$(printf '%s' "$response" | jq -r '.[0].name // empty' 2>/dev/null || echo "")"
  elif [ -n "$count" ] && [ "$count" -gt 1 ] 2>/dev/null; then
    echo "ERROR: $count DeepInfra keys found, so the script can't pick one. Owner: set FACTORY_DEEPINFRA_KEY_NAME to one of these names:" >&2
    printf '%s' "$response" | jq -r '.[].name | "  " + .' >&2 2>/dev/null || echo "  could not list keys" >&2
    exit 1
  fi
  if [ -z "$key_name" ]; then
    echo "ERROR: No DeepInfra key found in the key-limits response. Owner: check the key on DeepInfra's API keys page." >&2
    exit 1
  fi
fi

# Parse the spend for the key name
spend="$(printf '%s' "$response" | jq -r --arg name "$key_name" \
  'first(.[] | select(.name == $name) | .spend) // empty' 2>/dev/null || echo "")"

if [ -z "$spend" ] || [ "$spend" = "null" ]; then
  echo "ERROR: Key name \"$key_name\" not found in DeepInfra response." >&2
  echo "" >&2
  echo "Available key names:" >&2
  printf '%s' "$response" | jq -r '.[].name' >&2 2>/dev/null || echo "could not list keys" >&2
  exit 1
fi

if ! awk -v s="$spend" 'BEGIN { exit !(s ~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) }'; then
  echo "ERROR: Spend for \"$key_name\" is not a number." >&2
  exit 1
fi

# Caching info: check the response for cached_input fields
cached_input="$(printf '%s' "$response" | jq -r '[.[] | .cached_input // empty] | first // empty' 2>/dev/null || echo "")"

case "$command" in
  spend)
    awk -v s="$spend" 'BEGIN { printf "%.6f\n", s }'
    ;;

  start)
    echo "$spend" > "$STATE_FILE"
    echo "Saved start spend $spend for key \"$key_name\" to $STATE_FILE"
    ;;

  end)
    if [ ! -f "$STATE_FILE" ]; then
      echo "ERROR: No start state found. Run '$0 start' first." >&2
      exit 1
    fi
    start_spend="$(cat "$STATE_FILE")"
    diff="$(awk -v a="$spend" -v b="$start_spend" 'BEGIN { printf "%.6f", a - b }')"

    # Check for month rollover — if end is lower than start the billing
    # period reset and key-limits spend is for the new month only.
    if awk -v d="$diff" 'BEGIN { exit !(d < 0) }'; then
      echo "NOTE: spend went down (month may have rolled over)." >&2
      echo "Cost: see usage page — month rolled over during the run" >&2
      echo "Caching: see usage page" >&2
      exit 0
    fi

    formatted="$(awk -v d="$diff" 'BEGIN { printf "%.4f", d }')"
    echo "Cost: \$$formatted on DeepInfra"

    # /payment/key-limits does not reliably return cached_input across all
    # key types; check the field and fall back to telling the human.
    if [ -n "$cached_input" ] && [ "$cached_input" != "null" ] && [ "$cached_input" != "0" ]; then
      echo "Caching: yes - cached_input tokens: $cached_input"
    else
      echo "Caching: check usage page (cached tokens per model; the API may not expose this field)"
    fi
    ;;

  *)
    echo "Usage: $0 <spend|start|end> [key-name]" >&2
    exit 1
    ;;
esac
