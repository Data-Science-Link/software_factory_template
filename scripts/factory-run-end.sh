#!/bin/bash
# Orchestrator for factory run-end: parse usage, build record, validate and write.
set -euo pipefail

# Set defaults for optional environment variables
: "${OC_ENDED_AT:=$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
: "${OC_HEAD_SHA:=$(git rev-parse HEAD)}"

# Check required environment variables
if [ -z "${OC_ARTIFACT_DIR:-}" ]; then
  echo "factory-run-end: OC_ARTIFACT_DIR is required" >&2
  exit 2
fi

if [ -z "${OC_STARTED_AT:-}" ]; then
  echo "factory-run-end: OC_STARTED_AT is required" >&2
  exit 2
fi

if [ -z "${OC_BASE_SHA:-}" ]; then
  echo "factory-run-end: OC_BASE_SHA is required" >&2
  exit 2
fi

if [ -z "${OC_OUTCOME:-}" ]; then
  echo "factory-run-end: OC_OUTCOME is required" >&2
  exit 2
fi

# Validate OC_OUTCOME
case "$OC_OUTCOME" in
  pr_opened|pr_updated|no_changes|failed|cap_exceeded|gate_failed|cancelled) ;;
  *) echo "factory-run-end: OC_OUTCOME must be a valid outcome" >&2; exit 2 ;;
esac

# Validate timestamps
if [[ ! "$OC_STARTED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]]; then
  echo "factory-run-end: OC_STARTED_AT must be UTC ISO 8601 ending in Z" >&2
  exit 2
fi

if [[ ! "$OC_ENDED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]]; then
  echo "factory-run-end: OC_ENDED_AT must be UTC ISO 8601 ending in Z" >&2
  exit 2
fi

# Validate SHAs
if [[ ! "$OC_BASE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "factory-run-end: OC_BASE_SHA must be a 40-character hex SHA" >&2
  exit 2
fi

if [[ ! "$OC_HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "factory-run-end: OC_HEAD_SHA must be a 40-character hex SHA" >&2
  exit 2
fi

# Process usage files if they exist
usage_dir="$OC_ARTIFACT_DIR/usage"
usage_json="$OC_ARTIFACT_DIR/usage.json"

if [[ -d "$usage_dir" ]] && [[ -n "$(ls -A "$usage_dir"/*.json 2>/dev/null)" ]]; then
  # Sort usage files
  mapfile -t usage_files < <(find "$usage_dir" -name "*.json" -type f | sort)
  
  if [[ ${#usage_files[@]} -gt 0 ]]; then
    # Run factory-usage.py on sorted usage files
    if python3 scripts/factory-usage.py "${usage_files[@]}" >"$usage_json.tmp" 2>"$usage_json.err"; then
      mv "$usage_json.tmp" "$usage_json"
      rm -f "$usage_json.err"
    else
      # Remove usage.json on failure
      rm -f "$usage_json.tmp" "$usage_json" "$usage_json.err"
    fi
  fi
fi

# Run factory-run-record.py to build the record
tmp_record=$(mktemp)
if ! python3 scripts/factory-run-record.py --artifact-dir "$OC_ARTIFACT_DIR" >"$tmp_record" 2>"$tmp_record.err"; then
  cat "$tmp_record.err" >&2
  rm -f "$tmp_record" "$tmp_record.err"
  exit 2
fi
rm -f "$tmp_record.err"

# Validate the record
if ! python3 scripts/factory-validate-run.py "$tmp_record" >/dev/null 2>"$tmp_record.validate.err"; then
  cat "$tmp_record.validate.err" >&2
  rm -f "$tmp_record" "$tmp_record.validate.err"
  exit 1
fi
rm -f "$tmp_record.validate.err"

# Move the validated record to the runs directory
run_id=$(jq -r '.run_id' "$tmp_record")
runs_dir="${FACTORY_RUNS_DIR:-factory/runs}"
mkdir -p "$runs_dir"
mv "$tmp_record" "$runs_dir/$run_id.json"

# Print the path to the written record
echo "$runs_dir/$run_id.json"