#!/usr/bin/env bash
set -euo pipefail

# factory-cost.sh — DeepInfra cost for one issue, with the start value kept
# in an issue comment (no local state file).
#
# Usage:
#   scripts/factory-cost.sh start <issue> [key-name]
#       Read the key's current spend and post it on the issue as
#       "<!-- factory-cost-start: <spend> -->" plus a readable line.
#   scripts/factory-cost.sh end <issue> [key-name]
#       Find the latest start marker on the issue and print:
#         Cost: $X.XXXX on DeepInfra
#         Caching: ...
#
# Key name: FACTORY_DEEPINFRA_KEY_NAME, or the optional third argument.
# Needs DEEPINFRA_API_KEY (read by scripts/deepinfra-cost.sh), gh, jq, awk.
# The key is never printed. gh must be able to reach its token: in Cursor,
# run this script outside the agent sandbox (the sandbox can't read the
# macOS Keychain).

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reader="$here/deepinfra-cost.sh"

usage() { echo "Usage: $0 <start|end> <issue-number> [key-name]" >&2; exit 1; }
die()   { echo "ERROR: $*" >&2; exit 1; }

command="${1:-}"
issue="${2:-}"
key_name="${3:-${FACTORY_DEEPINFRA_KEY_NAME:-}}"

if [ -z "$command" ] || [ -z "$issue" ]; then usage; fi
case "$command" in start|end) ;; *) usage ;; esac
[[ "$issue" =~ ^[0-9]+$ ]] || die "Issue must be a number, got \"$issue\"."
[ -n "$key_name" ] || die "No key name. Set FACTORY_DEEPINFRA_KEY_NAME in ~/.zshrc or pass it as the third argument."
[ -n "${DEEPINFRA_API_KEY:-}" ] || die "DEEPINFRA_API_KEY is not set. Add it to ~/.zshrc and restart Cursor (see .factory/skills/local-owner-setup.md)."
for tool in gh jq awk; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required but not installed."
done
[ -f "$reader" ] || die "Missing $reader."

# Current spend, as a plain number (errors from the reader go to stderr).
spend="$(bash "$reader" spend "$key_name")" || die "Could not read spend from DeepInfra (see the message above)."

# Print the latest start marker on the issue as "<createdAt> <spend>".
# Reads `gh issue view --json comments` output on stdin. Only comments by
# the repo owner, members or collaborators count, so a stray comment can't
# fake the start value.
latest_marker() {
  jq -r '
    [ .comments[]
      | select((.authorAssociation // "") | test("^(OWNER|MEMBER|COLLABORATOR)$"))
      | select(.body | test("<!-- factory-cost-start: -?[0-9]+(\\.[0-9]+)? -->"))
      | { at: .createdAt,
          spend: ([.body | scan("<!-- factory-cost-start: (-?[0-9]+(?:\\.[0-9]+)?) -->")] | last | .[0]) } ]
    | sort_by(.at) | last // empty
    | "\(.at) \(.spend)"'
}

case "$command" in
  start)
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    body="<!-- factory-cost-start: $spend -->
Factory cost start: DeepInfra spend on the factory key was \$$(awk -v s="$spend" 'BEGIN { printf "%.4f", s }') at $now. \`scripts/factory-cost.sh end $issue\` reads this after the PR is open."
    gh issue comment "$issue" --body "$body" >/dev/null \
      || die "gh could not comment on issue #$issue. If gh says the token is invalid inside Cursor, run this command outside the sandbox (the sandbox can't read the macOS Keychain)."
    echo "Posted cost start on issue #$issue (spend \$$(awk -v s="$spend" 'BEGIN { printf "%.4f", s }'))."
    ;;

  end)
    comments="$(gh issue view "$issue" --json comments)" \
      || die "gh could not read issue #$issue. If gh says the token is invalid inside Cursor, run this command outside the sandbox."
    marker="$(printf '%s' "$comments" | latest_marker)" \
      || die "Could not parse the comments on issue #$issue."
    [ -n "$marker" ] || die "No factory-cost-start marker on issue #$issue. Run '$0 start $issue' before the work starts."
    start_at="${marker%% *}"
    start_spend="${marker#* }"

    # Month rollover: DeepInfra key spend resets each month, so the
    # difference is only exact when start and end fall in the same UTC month.
    if awk -v a="$spend" -v b="$start_spend" 'BEGIN { exit !(a < b) }'; then
      echo "NOTE: spend went down since the start marker ($start_at): the billing month rolled over. Only this month's part is known." >&2
      echo "Cost: at least \$$(awk -v s="$spend" 'BEGIN { printf "%.4f", s }') on DeepInfra (month rolled over; check the usage page for the full amount)"
    elif [ "${start_at:0:7}" != "$(date -u +%Y-%m)" ]; then
      echo "NOTE: the start marker ($start_at) is from an earlier month. If spend reset, this number is wrong." >&2
      echo "Cost: \$$(awk -v a="$spend" -v b="$start_spend" 'BEGIN { printf "%.4f", a - b }') on DeepInfra (month changed during the run; check the usage page)"
    else
      echo "Cost: \$$(awk -v a="$spend" -v b="$start_spend" 'BEGIN { printf "%.4f", a - b }') on DeepInfra"
    fi
    echo "Caching: check the DeepInfra usage page (cached input tokens per model); the key-limits API gives spend only"
    ;;
esac
