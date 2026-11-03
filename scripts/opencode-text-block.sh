#!/usr/bin/env bash
# Model or command text for a PR body or comment, made safe to paste. Script only.
#
#   opencode-text-block.sh note <opencode.log>
#       Print the worker's labeled note: the LAST "## What I changed and why" section of the log
#       (ANSI stripped, capped at 3000 bytes). Prints nothing when there is no such section.
#   opencode-text-block.sh fence <file> <max-bytes> <empty message>
#       Print the file as one ```text block that nothing inside can close or escape: CR, NUL and
#       ANSI codes removed, ``` turned into ''', @ mentions into (at), HTML comment openers
#       defanged. Longer than <max-bytes>: keep the first quarter and the last three quarters
#       with a "[... N bytes cut ...]" line. Missing or empty file: the empty message, fenced.
set -euo pipefail

strip_ansi() { sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g' | tr -d '\r\000'; }

case "${1:-}" in
  note)
    [ -f "${2:-}" ] || exit 0
    strip_ansi <"$2" | awk '
      /^[[:space:]]*#+[[:space:]]*What I changed and why[[:space:]]*$/ { buf = ""; found = 1; next }
      found { buf = buf $0 "\n" }
      END { printf "%s", buf }' | head -c 3000
    ;;
  fence)
    file="${2:-}"; max="${3:-}"; empty="${4:-"(empty)"}"
    case "$max" in '' | *[!0-9]*) echo "text-block: max-bytes must be digits" >&2; exit 2 ;; esac
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    if [ -f "$file" ]; then strip_ansi <"$file" >"$tmp"; fi
    if ! grep -q '[^[:space:]]' "$tmp" 2>/dev/null; then printf '%s\n' "$empty" >"$tmp"; fi
    size="$(wc -c <"$tmp")"
    echo '```text'
    {
      if [ "$size" -le "$max" ]; then
        cat "$tmp"
      else
        head_n=$((max / 4)); tail_n=$((max - head_n))
        head -c "$head_n" "$tmp"
        printf '\n[... %s bytes cut ...]\n' "$((size - max))"
        tail -c "$tail_n" "$tmp"
      fi
    } | sed -E 's/```/'"'''"'/g; s/@/(at)/g; s/<!--/<! --/g' | awk 1
    echo '```'
    ;;
  *)
    echo "usage: opencode-text-block.sh note <log> | fence <file> <max-bytes> <empty message>" >&2
    exit 2
    ;;
esac
