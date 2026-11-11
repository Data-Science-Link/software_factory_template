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
stray `s` suffix (never `unavailables`). Because `tokenless/` has no
`artifacts/` directory, the review also emits the artifacts-unavailable marker
(`artifacts_unavailable: true` in the JSON, an `- artifacts unavailable` line in
the markdown) instead of silent empties.

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

## False-positive regression fixture (`falsepos/live/`)

`falsepos/live/` is the regression fixture for #188: it reproduces the two
workflow-log lines that made `detect_blocked_calls()` report a `blocked_call`
finding on every live `/oc` run that ran a model, even when no tool call was
actually denied. Its contents contain no secrets, keys, tokens or env values.

- `pr-head.txt` — `oc/issue-188-43052631438`.
- `run-list.json` — a single build run `43052631438` (`opencode-spike`,
  headBranch `main`).
- `artifacts/43052631438/log.txt` — a real GitHub workflow-log style file with:
  - the echoed `OC_INSTRUCTION:` env line, which quotes the permission-denial
    text (`The user has specified a rule which prevents you from using this
    specific tool call`) and uses the words `denied` / `blocked` / `guardrail`,
    exactly as an owner instruction that mentions the denial can appear on
    every step;
  - the StepSecurity harden-runner config line `"denied_endpoints":""` printed
    by the `Pre Harden runner (audit egress)` step;
  - normal agent tool-result lines (`→ Read`, `✱ Glob`, `✗ Bash ...`) with no
    real denial text on or around them.

`--live-dir falsepos/live` must report `blocked_calls: []` and no `blocked_call`
finding for run `43052631438`. This is the broken-case guard: if the bare
`denied` / `blocked` / `guardrail` substring fallback were still active, the
echoed instruction and the `denied_endpoints` line would produce a non-empty
`blocked_calls`, and the test fails loudly.

## Denied-session fixture (`denied/live/`)

`denied/live/` reproduces build run 43069209256 from issue #193 (post-merge
review of PR #190): the worker's `find .../tests/factory-run-review -type f |
sort` bash call was blocked by the deny rule, but the workflow log carries no
agent tool output, so only the downloaded session export can surface the denial.

- `pr-head.txt` — `oc/issue-193-43069209256`.
- `run-list.json` — the build run `43069209256` (`opencode-spike`, headBranch
  `main`).
- `artifacts/43069209256/usage/session-1.json` — a structured session export
  with one `type: "tool"` bash part whose `state.status` is `"error"`, whose
  error text contains the permission-denial text (`The user has specified a rule
  which prevents you from using this specific tool call`), and whose
  `state.input.command` is `find tests/factory-run-review -type f | sort`.
- `artifacts/43069209256/log.txt` — a workflow-style `gh run view --log`
  transcript with no permission-denial text and no agent tool-result line that
  `detect_blocked_calls()` could treat as a denial.

`--live-dir denied/live` must report the blocked `find` command in
`blocked_calls` and a `blocked_call` finding for run `43069209256`. Today's
`log.txt`-only scan cannot produce it; only session-export parsing can pass.

## opencode.log fallback fixture (`denied-log/live/`)

`denied-log/live/` is the session-less fallback (synthetic run 43069209257): no
`usage/session-*.json`. The blocked `find` command appears only in
`artifacts/43069209257/oc-artifacts-43069209257/opencode.log`, in the real
OpenCode agent tool-result format with the permission-denial text. Its `log.txt`
is a workflow-style log with no denial text.

`--live-dir denied-log/live` must report the blocked `find` command in
`blocked_calls` for run `43069209257` from the `opencode.log` fallback.

## Negative-session fixture (`denied-neg/live/`)

`denied-neg/live/` is the broken-case guard for the session trigger: a naive
status-only or text-only trigger would fire, but the real code requires both an
errored `state.status` AND the exact permission-denial text.

- `pr-head.txt` — `oc/issue-193-43069209301`.
- `run-list.json` — build run `43069209301` (`opencode-spike`, headBranch
  `main`) plus fix run `43069209302` (`opencode-fix`, headBranch
  `oc/issue-193-43069209301`).
- `artifacts/43069209301/usage/session-1.json` — a bash tool part whose
  `state.status` is `"completed"` (not an error), even though the part mentions a
  command.
- `artifacts/43069209302/usage/session-1.json` — a bash tool part whose
  `state.status` is `"error"` but whose error text does not contain the
  permission-denial text.

Both runs' `log.txt` files are workflow-style logs with no denial text. Both
must report `blocked_calls: []` and no `blocked_call` finding.

## Artifacts-unavailable fixture (`unavailable/live/`)

`unavailable/live/` has `run-list.json` and `pr-head.txt` only — no
`artifacts/` directory. The review must emit the artifacts-unavailable marker
(`artifacts_unavailable: true` in the JSON, an `- artifacts unavailable` line in
the markdown) rather than silently returning empty `tool_counts` / evidence /
routing. The marker fires only when the artifact directory is missing or the
download fails; an existing artifact directory with no token or tool data is not
treated as artifacts-unavailable.
