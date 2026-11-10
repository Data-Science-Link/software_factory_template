#!/usr/bin/env bash
# Run metering for /oc agent jobs (#31): the inputs factory-run-end.sh needs, written to
# $OC_RECORD_DIR (default: "$OC_ARTIFACT_DIR-record", a sibling, so the session exports never ride
# along in the oc-artifacts upload; scripts/factory-run-pack.sh scans them before their own upload).
# Called by the agent scripts around `opencode run`, never by the worker.
#
#   opencode-run-meter.sh start            run-clock.json (started_at, base_sha) + key-spend start
#   opencode-run-meter.sh end [dir]        usage/*.json (opencode export --sanitize, run from DIR,
#                                          default: current dir) + key-spend.json
#
# Best effort: it never fails the run (always exits 0) and never prints a key, a key name or an
# env value. Key spend needs DEEPINFRA_API_KEY (already in the agent step) and
# FACTORY_DEEPINFRA_KEY_NAME (the Actions key's name, a repo variable, not a secret); without the
# variable no snapshot is taken and records say cost_check skipped_unavailable.
# The agent scripts call a copy saved before the worker starts, so a worker edit can't change it.
set -uo pipefail

mode="${1:-}"
dir="${2:-.}"
art="${OC_RECORD_DIR:-}"
[ -n "$art" ] || { [ -z "${OC_ARTIFACT_DIR:-}" ] || art="${OC_ARTIFACT_DIR%/}-record"; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cost_sh="${OC_METER_COST_SH:-$here/deepinfra-cost.sh}"
oc="${OPENCODE_BIN:-opencode}"
command -v "$oc" >/dev/null 2>&1 || oc="opencode"

say() { echo "run-meter: $*" >&2; }
[ -n "$art" ] || { say "OC_RECORD_DIR / OC_ARTIFACT_DIR is not set; skipped"; exit 0; }
mkdir -p "$art" 2>/dev/null || { say "cannot create the record dir; skipped"; exit 0; }

# Current key spend as a plain number on stdout, or nothing. deepinfra-cost.sh's stderr (it can
# list key names) is dropped; only "available"/"unavailable" is logged.
key_spend() {
  local v
  [ -n "${DEEPINFRA_API_KEY:-}" ] || return 0
  # Opt-in: only with the repo variable naming the Actions key (tests and local runs never call out).
  [ -n "${FACTORY_DEEPINFRA_KEY_NAME:-}" ] || return 0
  [ -f "$cost_sh" ] || return 0
  v="$(timeout 20 bash "$cost_sh" spend 2>/dev/null)" || return 0
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "$v"
  return 0
}

case "$mode" in
  start)
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    base="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo unknown)"
    python3 - "$art/run-clock.json" "$started" "$base" <<'PY' || say "could not write run-clock.json"
import json, sys
json.dump({"started_at": sys.argv[2], "base_sha": sys.argv[3]}, open(sys.argv[1], "w"), sort_keys=True)
PY
    s="$(key_spend)"
    if [ -n "$s" ]; then printf '%s\n' "$s" >"$art/key-spend-start.txt"; say "key spend at start: available"
    else rm -f "$art/key-spend-start.txt"; say "key spend at start: unavailable"; fi
    ;;
  end)
    # 0. The worker's end time (the record's ended_at; publish time is not run time).
    python3 - "$art/run-clock.json" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY' 2>/dev/null || say "could not update run-clock.json"
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
d["ended_at"] = sys.argv[2]
json.dump(d, open(sys.argv[1], "w"), sort_keys=True)
PY
    # 1. Session exports (D3 from #134). Sessions are per project, so list them from the run's dir.
    mkdir -p "$art/usage"
    ids="$(cd "$dir" && timeout 20 "$oc" session list --format json 2>/dev/null | python3 -c '
import json, re, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for s in data if isinstance(data, list) else []:
    i = s.get("id") if isinstance(s, dict) else None
    if isinstance(i, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,100}", i):
        print(i)
' 2>/dev/null)" || ids=""
    n=0
    for id in $ids; do
      n=$((n + 1))
      out="$art/usage/session-$n.json"
      if ! (cd "$dir" && timeout 30 "$oc" export "$id" --sanitize >"$out" 2>/dev/null) \
        || ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$out" 2>/dev/null; then
        rm -f "$out"; say "session $n: export failed"
      fi
    done
    say "exported $(find "$art/usage" -name 'session-*.json' | wc -l | tr -d ' ') of $n session(s)"
    # 2. Key spend at end, after a short settle so the provider has counted the last calls.
    if [ -f "$art/key-spend-start.txt" ]; then
      sleep "${OC_KEY_SPEND_SETTLE_SECONDS:-10}"
      e="$(key_spend)"
      if [ -n "$e" ]; then
        python3 - "$art/key-spend.json" "$(cat "$art/key-spend-start.txt")" "$e" <<'PY' && say "key spend at end: available"
import json, sys
# "concurrent" is decided later by the record job, which can see other runs on the same key.
json.dump({"start_usd": float(sys.argv[2]), "end_usd": float(sys.argv[3]), "concurrent": False},
          open(sys.argv[1], "w"), sort_keys=True)
PY
      else
        say "key spend at end: unavailable"
      fi
    fi
    ;;
  *)
    say "usage: opencode-run-meter.sh start|end [dir]"
    ;;
esac
exit 0
