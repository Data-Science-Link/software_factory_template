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

## Live-path parser fixture (`live/`)

The `live/` directory drives the live-path parser offline (no network, no `gh`).
It mirrors exactly what `--pr`/`--issue` mode sees on the live path:

- `pr-head.txt` — the PR's head branch `oc/issue-<N>-<build_run_id>` (what
  `gh pr view ... headRefName` returns).
- `run-list.json` — the unfiltered `gh run list --json ...` output, spanning the
  real workflow names `opencode-spike`, `opencode-spec`, `opencode-fix`.
- `artifacts/<run_id>/` — the run's artifact directory as `gh run download`
  yields it: `run-start.json` (model / routing rule), `spec.md` (`## Files`),
  `opencode-export.json` (session export delegated to `scripts/factory-usage.py`
  for cost/tokens), `scan.json` (artifact-scan result), `evidence.md`, and
  `log.txt`.

The test feeds `live/` to `scripts/factory-run-review.py --live-dir` and asserts
model, cost and scan are populated from the artifacts, and that the run
selection keeps the build run (headBranch `main`), the later `opencode-fix` run
and the `opencode-spec` run for the linked issue (headBranch `main`, title
`OpenCode: spec run for #136` matching the issue) while excluding an unrelated
`opencode-spike` build run. The spec run's tokens and cost are populated from
its own downloaded `opencode-export.json`. All fixture contents are sanitized:
no secrets, keys, tokens or env values.

## Run-record fixture (`records/`)

`records/issue-comments.json` is a sanitized copy of a `#31` issue comment
(`<!-- factory-run-record -->` plus a fenced JSON record). `--live-dir records`
must select run `42752519540` and populate model, cost, tokens and `gate` from
the record alone (no `gh`, no workflow artifacts).

## Fallback fixture (`fallback/`)

`fallback/` is the pre-#31 layout: `gh run list` rows whose `headBranch` is
`main`, a fix run identified by `displayTitle`, and artifacts nested under
`oc-artifacts-<id>/` / `oc-fix-artifacts-<id>/` as `gh run download --dir`
writes them. Cost comes from `usage-metrics.md` (`OpenCode-reported cost: $X`);
scan comes from the `artifact-scan: passed.` log line. Skipped sibling runs and
unrelated builds stay excluded.

## Token-less fixture (`tokenless/`)

`tokenless/` is the broken case: an `opencode-spec` run for the linked issue
with no artifact or `#31` record carrying token data. `--live-dir tokenless`
must still select the run (its title matches `#136`), keep its `tokens` JSON
`null`, and render them as "unavailable" in the markdown rather than fabricating
a value. It has no tool data at all, so `tool_counts` stays `{}` and
`seconds_per_tool_turn` / `longest_gap_seconds` stay JSON `null`; the rendered
line reads `seconds/tool turn: unavailable, longest gap: unavailable` with no
stray `s` suffix (never `unavailables`).

## Real-log/session fixture (`reallog/live/`)

`reallog/live/` is built from a real, redacted OpenCode run (the post-#165
review run `42951547485`) and drives the live-path parser offline. Its contents
contain no keys, tokens, env values or private paths.

- `pr-head.txt` — `oc/issue-166-42951547485`.
- `run-list.json` — the build run `42951547485` (`opencode-spike`, headBranch
  `main`) plus a spec run `42951547486` for `#166` (`opencode-spec`,
  headBranch `main`, title `OpenCode: spec run for #166`).
- `artifacts/42951547485/usage/session-1.json` — a structured session export
  (`info.messages[].parts[]` with `type: "tool"`) the run meter writes, with 34
  read / 10 edit / 9 write / 4 bash / 3 glob / 3 grep tool parts. Each part has
  an increasing `state.time.start` so per-turn timing is non-null.
- `artifacts/42951547485/log.txt` — the real OpenCode log line format (→ Read,
  ✱ Glob, ✗ Bash ... failed, with ANSI codes) including the real
  permission-denial text (`The user has specified a rule which prevents you from
  using this specific tool call`) and its preceding `✗ Bash: ls -la ... failed`
  line, so the denied `ls` appears in `blocked_calls`.
- `artifacts/42951547486/log.txt` — a real-format log line set (→ Read, ✱ Glob,
  ✗ Bash ... failed, with ANSI codes) with no `usage/session-*.json`, proving
  `tool_counts` still populate via the log fallback when no session JSON is
  present.

`--live-dir reallog/live` must report the session JSON's per-tool counts and
non-null `seconds_per_tool_turn` / `longest_gap_seconds` for run `42951547485`,
put the denied `ls` in its `blocked_calls`, and populate the spec run's
`tool_counts` from the log fallback.
