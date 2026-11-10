#!/usr/bin/env bash
# Agent job, always (#31): pack the run's metering for the record job. Copies run-start.json,
# spec.md and fix-meta.txt from $OC_ARTIFACT_DIR into the record dir (scripts/opencode-run-meter.sh
# wrote run-clock.json, usage/ and key-spend.json there), then scans everything before upload:
# a session export with a scan hit is dropped (cost then comes from key spend alone), any other
# hit drops the whole pack. Prints ok=yes to $GITHUB_OUTPUT when there is something to upload.
# Never prints file contents. No key or token needed.
set -uo pipefail
say() { echo "run-pack: $*" >&2; }
src="${OC_ARTIFACT_DIR:?OC_ARTIFACT_DIR is required}"
rec="${OC_RECORD_DIR:-${src%/}-record}"
scan="${OC_SCAN_SH:-scripts/opencode-artifact-scan.sh}"
out="${GITHUB_OUTPUT:-/dev/null}"

if [ ! -f "$rec/run-clock.json" ]; then
  say "no run-clock.json (the worker never started); nothing to pack"
  exit 0
fi
for f in run-start.json spec.md fix-meta.txt; do
  [ -f "$src/$f" ] && cp "$src/$f" "$rec/$f"
done
rm -f "$rec/key-spend-start.txt"

for f in "$rec"/usage/*.json; do
  [ -f "$f" ] || continue
  if ! bash "$scan" "$f" >/dev/null 2>&1; then
    rm -f "$f"; say "dropped $(basename "$f"): scan hit (cost falls back to key spend)"
  fi
done
small=()
for f in run-clock.json run-start.json spec.md fix-meta.txt key-spend.json; do
  [ -f "$rec/$f" ] && small+=("$rec/$f")
done
if ! bash "$scan" "${small[@]}" >/dev/null 2>&1; then
  say "scan hit in the record files; not uploading a record"
  exit 0
fi
echo "ok=yes" >>"$out"
say "packed $(find "$rec" -type f | wc -l | tr -d ' ') file(s)"
exit 0
