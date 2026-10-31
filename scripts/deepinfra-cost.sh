#!/usr/bin/env bash
set -euo pipefail

# deepinfra-cost.sh — read DeepInfra spend from the payment/key-limits API.
#
# Usage:
#   deepinfra-cost.sh start <key-name>
#       Save the current-month spend for KEY-NAME to .factory-cost-start.
#       .factory-cost-start is gitignored (never committed).
#
#   deepinfra-cost.sh end <key-name>
#       Print the difference between the current spend and the saved start
#       value: "Cost: $X.XX on DeepInfra". Also prints caching info if
#       the response includes cached_input tokens.
#
# Requires DEEPINFRA_API_KEY in the environment, plus curl and jq.

GITIGNORE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || echo '.' )"
STATE_FILE="${GITIGNORE_DIR}/.factory-cost-start"

command="${1:-}"
key_name="${2:-}"

if [ -z "${DEEPINFRA_API_KEY:-}" ]; then
  echo "ERROR: DEEPINFRA_API_KEY is not set." >&2
  exit 1
fi

if [ -z "$command" ] || [ -z "$key_name" ]; then
  echo "Usage: $0 <start|end> <key-name>" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required but not installed." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed." >&2
  exit 1
fi

if ! command -v bc >/dev/null 2>&1; then
  echo "ERROR: bc is required but not installed." >&2
  exit 1
fi

# Fetch spend from DeepInfra payment/key-limits
response="$(curl -s -f -H "Authorization: Bearer $DEEPINFRA_API_KEY" \
  "https://api.deepinfra.com/payment/key-limits" 2>/dev/null || true)"

if [ -z "$response" ]; then
  echo "ERROR: No response from DeepInfra API. Check your network and key." >&2
  exit 1
fi

# The response is a flat array of key objects: [ { "name": "...", "spend": ..., ... }, ... ]
# Parse the spend for the given key name
spend="$(echo "$response" | jq -r --arg name "$key_name" '.[] | select(.name == $name) | .spend' 2>/dev/null || echo "")"

if [ -z "$spend" ] || [ "$spend" = "null" ]; then
  echo "ERROR: Key name \"$key_name\" not found in DeepInfra response." >&2
  echo "" >&2
  echo "Available key names:" >&2
  echo "$response" | jq -r '.[].name' 2>/dev/null || echo "could not list keys" >&2
  exit 1
fi

# Caching info: check the response for cached_input fields
cached_input="$(echo "$response" | jq -r '[.[] | .cached_input // empty] | first' 2>/dev/null || echo "")"

case "$command" in
  start)
    echo "$spend" > "$STATE_FILE"
    echo "Saved start spend $spend for key \"$key_name\" to $STATE_FILE"
    ;;

  end)
    if [ ! -f "$STATE_FILE" ]; then
      echo "ERROR: No start state found. Run '$0 start $key_name' first." >&2
      exit 1
    fi
    start_spend="$(cat "$STATE_FILE")"
    diff="$(echo "$spend - $start_spend" | bc -l 2>/dev/null || echo "")"
    if [ -z "$diff" ]; then
      echo "ERROR: Failed to compute spend difference." >&2
      exit 1
    fi

    # Check for month rollover — if end is lower than start the billing
    # period reset and key-limits spend is for the new month only.
    rollover="$(echo "$diff < 0" | bc -l 2>/dev/null || echo "")"
    if [ "$rollover" = "1" ]; then
      echo "NOTE: spend went down (month may have rolled over)." >&2
      echo "Cost: see usage page — month rolled over during the run" >&2
      echo "Caching: see usage page" >&2
      exit 0
    fi

    # Format to 4 decimal places for sub-$0.01 precision, strip leading zero
    formatted="$(printf "%.4f" "$diff" | sed 's/^\./0./')"
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
    echo "Usage: $0 <start|end> <key-name>" >&2
    exit 1
    ;;
esac
