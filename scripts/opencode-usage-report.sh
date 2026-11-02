#!/usr/bin/env bash
# Write token-usage hints to GITHUB_STEP_SUMMARY (no env dumps). Safe after failed agent runs.
set -euo pipefail

out="${OC_ARTIFACT_DIR:-/tmp/oc-artifacts}/usage-report.txt"
mkdir -p "$(dirname "$out")"
: >"$out"

{
  echo "## OpenCode usage report"
  echo
  echo "### opencode stats --models"
  if command -v opencode >/dev/null 2>&1; then
    opencode stats --models 2>&1 || echo "(opencode stats failed or no sessions yet)"
  else
    echo "(opencode binary not on PATH)"
  fi
  echo
  echo "### Session storage (typical paths)"
  for d in \
    "${XDG_DATA_HOME:-$HOME/.local/share}/opencode" \
    "$HOME/.local/share/opencode" \
    "$HOME/.config/opencode"; do
    if [ -d "$d" ]; then
      echo "- $d (exists)"
      find "$d" -maxdepth 3 -type f 2>/dev/null | head -n 20 || true
    else
      echo "- $d (not present)"
    fi
  done
  echo
  echo "### Commands for phase 2 logging"
  echo '- `opencode stats --models` — token totals'
  echo '- `opencode session list` — session ids'
  echo '- `opencode export <sessionID> --sanitize` — redacted session JSON'
} >>"$out"

bash scripts/opencode-artifact-scan.sh "$out"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$out" >>"$GITHUB_STEP_SUMMARY"
fi

echo "usage-report: wrote $out"
