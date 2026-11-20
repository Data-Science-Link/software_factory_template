#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--list-protected" ]; then
  printf '%s\n' scripts/fixture-protected.sh
  exit 0
fi
echo "fixture scan" >&2
exit 0