# /oc run-review fixtures (#136)

These fixtures stand in for the three real `/oc` workflow runs named in issue
#136, sanitized so they contain no secrets, keys, tokens or env values. They are
worker-written, not real exports: each `opencode_export` block is a small,
hand-built OpenCode session export shaped exactly like the pinned OpenCode CLI
produces (the same `info.tokens` / `info.messages` format that
`tests/factory-usage/` documents), and the `tool_events`, `blocked_calls`,
`scan` and `evidence` fields describe the run facts the review script consumes.

## What the three runs stand in for

- `run-42282682618.json` — V4 Pro **timeout**. Slow thinking (~19s per tool
  turn), a `timed_out` conclusion, a 780s wall clock with `timeout: true`, and a
  cost above $0.10. Findings: `run_failed` (high), `cost_overrun` (high),
  `timeout_hit` (low).
- `run-42290238204.json` — artifact-scan **block**. The worker attempted denied
  guardrail commands (`mkdir -p factory/tmp`, `chmod +x scripts/...`) and read a
  file outside the spec's `## Files`; the artifact scan failed. Findings:
  `run_failed` (high), `guardrail_bypass` (high), `blocked_call` (low),
  `out_of_spec_read` (low).
- `run-42297659590.json` — Qwen **stall**. Completed successfully at low cost,
  but with a ~790s gap between tool turns. Findings: `stall` (low),
  `slow_tool_turn` (low).

## Format

Each `run-<id>.json` is the parsed run-facts object the review script reads via
`--input`:

- `run_id`, `workflow`, `status`, `conclusion`, `model`, `routing_rule`,
  `created_at`, `updated_at`, `wall_time_seconds`, `timeout`
- `opencode_export` — a valid OpenCode session export; the script delegates cost
  and token totals to `scripts/factory-usage.py` on a temp copy of this block.
- `spec_files` — the approved spec's `## Files` create-list (the read whitelist).
- `tool_events` — `{tool, ts, input}` records used for tool counts, seconds per
  tool turn, stalls, and out-of-spec reads.
- `blocked_calls` — denied/blocked guardrail commands, by command string.
- `scan` / `evidence` — artifact-scan and harness-evidence results.

## Expected outputs

The `expected-<id>.json` files are the exact `json.dumps(..., indent=2,
sort_keys=True)` output of the review for the matching fixture, one per run.
`scripts/test-factory-run-review.sh` runs the script on each fixture and
compares with `cmp`, proving byte-identical, deterministic output. It also sets
a sentinel environment variable and asserts it never appears in the script's
output, proving the script makes no model calls and reads no key or env value.
