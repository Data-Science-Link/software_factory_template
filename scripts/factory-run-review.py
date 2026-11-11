#!/usr/bin/env python3
"""Deterministic post-merge /oc run-review.

Reads the run facts for a PR's /oc workflow run and produces a key-sorted JSON
summary plus a short markdown summary. Pure transform: no model calls, no random
ids, no wall clock. Cost and token figures are delegated to scripts/factory-usage.py
via subprocess so they never drift from the canonical implementation.

In --pr / --issue mode the run facts are fetched read-only with `gh`. Live mode
prefers #31 run records (issue comments marked `<!-- factory-run-record -->`,
and `oc-run-record-*` / `oc-record-*` artifacts). Older runs fall back to
workflow artifacts and logs. In --input mode (used by the offline test) the run
facts are read from a sanitized fixture file and only the JSON summary is
printed, so it can be compared byte-for-byte with a committed expected-*.json
using cmp.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FACTORY_USAGE = os.path.join(REPO_ROOT, "scripts", "factory-usage.py")

# The real /oc workflow names. Do not use a --workflow=opencode filter; the
# names are opencode-spike (builds), opencode-spec, and opencode-fix.
WORKFLOW_NAMES = ("opencode-spike", "opencode-spec", "opencode-fix")
FIX_WORKFLOW = "opencode-fix"
SPEC_WORKFLOW = "opencode-spec"
SPIKE_WORKFLOW = "opencode-spike"

# Thresholds (seconds). Stays stable so identical input gives identical output.
STALL_GAP_SECONDS = 780.0
SLOW_TURN_SECONDS = 30.0
COST_OVERRUN_USD = 0.10

RUN_RECORD_MARKER = "<!-- factory-run-record -->"
GHA_RUN_RE = re.compile(r"^gha-(\d+)(?:-(\d+))?$")
USAGE_COST_RE = re.compile(r"OpenCode-reported cost:\s*\$([0-9]+(?:\.[0-9]+)?)", re.I)
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
PERMISSION_DENIED_RE = re.compile(
    r"the user has specified a rule which prevents you from using this specific tool call",
    re.I,
)
# Real OpenCode logs prefix each tool line with a role label (e.g. "assistant ")
# before the arrow/symbol: `assistant → Read <path>`. The lookahead keeps the
# arrow so the line still matches the symbol matchers below.
_ROLE_PREFIX_RE = re.compile(r"^[A-Za-z]+\s+(?=[→✱✗*>\-])")
SCAN_PASS_RE = re.compile(r"artifact-scan:\s*passed", re.I)
SCAN_FAIL_RE = re.compile(r"artifact-scan:\s*FAIL", re.I)

# Always-readable paths that are legitimately opened by a worker regardless of
# the approved spec's `## Files` list (method docs, rules, the review target).
ALWAYS_READABLE = {
    ".factory/FACTORY.md",
    ".factory/DOCS.md",
    "AGENTS.md",
    "opencode.json",
}

# Fixed finding-code catalog. The code meanings are a committed, stable table:
# updating a meaning or a severity is the one place that ever changes output.
FINDING_CODES = {
    "run_failed": {
        "severity": "high",
        "meaning": "the workflow run did not complete successfully",
    },
    "cost_overrun": {
        "severity": "high",
        "meaning": "run wasted more than $0.10",
    },
    "guardrail_bypass": {
        "severity": "high",
        "meaning": "a guardrail was bypassed (artifact-scan failure)",
    },
    "blocked_call": {
        "severity": "low",
        "meaning": "a denied/blocked guardrail command was attempted",
    },
    "out_of_spec_read": {
        "severity": "low",
        "meaning": "a file was read outside the spec's ## Files",
    },
    "stall": {
        "severity": "low",
        "meaning": "long gap between tool turns",
    },
    "slow_tool_turn": {
        "severity": "low",
        "meaning": "average seconds per tool turn above threshold",
    },
    "timeout_hit": {
        "severity": "low",
        "meaning": "run hit the wall-clock timeout",
    },
}

# Optional repo for live `gh` calls (`--repo owner/name`). Unused in --input
# and --live-dir mode, which never call gh.
_GH_REPO = None


def normalize_path(path):
    """Return a comparable, repo-relative path, or None if not usable."""
    if not isinstance(path, str):
        return None
    p = path.strip()
    while p.startswith("./"):
        p = p[2:]
    p = p.lstrip("/")
    if not p or ".." in p:
        return None
    return p


def run_usage(opencode_export):
    """Delegate cost/token computation to scripts/factory-usage.py."""
    if not isinstance(opencode_export, dict):
        return None
    with tempfile.NamedTemporaryFile(
        "w", suffix=".json", delete=False, encoding="utf-8"
    ) as fh:
        json.dump(opencode_export, fh)
        tmp_path = fh.name
    try:
        proc = subprocess.run(
            [sys.executable, FACTORY_USAGE, tmp_path],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            return None
        return json.loads(proc.stdout)
    except (OSError, json.JSONDecodeError):
        return None
    finally:
        os.unlink(tmp_path)


def tool_turn_stats(tool_events):
    """Return (tool_counts, gaps_seconds, avg_turn, longest_gap)."""
    tool_counts = {}
    gaps = []
    prev_ts = None
    for ev in tool_events or []:
        tool = ev.get("tool")
        if not isinstance(tool, str):
            continue
        tool_counts[tool] = tool_counts.get(tool, 0) + 1
        ts = ev.get("ts")
        if isinstance(ts, (int, float)) and prev_ts is not None and ts > prev_ts:
            gaps.append((ts - prev_ts) / 1000.0)
        if isinstance(ts, (int, float)):
            prev_ts = ts
    avg_turn = round(sum(gaps) / len(gaps), 2) if gaps else None
    longest_gap = round(max(gaps), 2) if gaps else None
    return tool_counts, gaps, avg_turn, longest_gap


def out_of_spec_reads(tool_events, spec_files):
    """Sorted unique file paths read that are outside ## Files and always-readable."""
    allowed = set(spec_files or [])
    allowed |= ALWAYS_READABLE
    reads = set()
    for ev in tool_events or []:
        if ev.get("tool") != "read":
            continue
        p = normalize_path(ev.get("input"))
        if p is None:
            continue
        if p not in allowed:
            reads.add(p)
    return sorted(reads)


def compute_findings(run, cost, out_spec, longest_gap, avg_turn):
    """Map run facts to a fixed-catalog list of finding codes."""
    codes = []
    conclusion = run.get("conclusion")
    status = run.get("status")
    if conclusion in ("failure", "timed_out") or (conclusion is None and status != "completed"):
        codes.append("run_failed")
    if cost is not None and cost > COST_OVERRUN_USD:
        codes.append("cost_overrun")
    scan = run.get("scan") or {}
    if scan.get("result") == "fail":
        codes.append("guardrail_bypass")
    if run.get("blocked_calls"):
        codes.append("blocked_call")
    if out_spec:
        codes.append("out_of_spec_read")
    if longest_gap is not None and longest_gap > STALL_GAP_SECONDS:
        codes.append("stall")
    if avg_turn is not None and avg_turn > SLOW_TURN_SECONDS:
        codes.append("slow_tool_turn")
    if run.get("timeout"):
        codes.append("timeout_hit")

    findings = []
    for code in sorted(codes):
        entry = FINDING_CODES[code]
        findings.append(
            {"code": code, "severity": entry["severity"], "meaning": entry["meaning"]}
        )
    return findings


def _tokens_from_run(run, usage):
    """Prefer factory-usage.py totals; otherwise any tokens already on the run."""
    if usage:
        return {
            "in": usage.get("tokens_in"),
            "cached": usage.get("tokens_cached"),
            "out": usage.get("tokens_out"),
            "reasoning": usage.get("tokens_reasoning"),
        }
    tok = run.get("tokens") or {}
    return {
        "in": tok.get("in"),
        "cached": tok.get("cached"),
        "out": tok.get("out"),
        "reasoning": tok.get("reasoning"),
    }


def review_run(run):
    """Pure transform from run facts to the review JSON object."""
    usage = run_usage(run.get("opencode_export"))
    tool_counts, gaps, avg_turn, longest_gap = tool_turn_stats(run.get("tool_events"))
    spec_files = run.get("spec_files") or []
    out_spec = out_of_spec_reads(run.get("tool_events"), spec_files)
    if usage:
        cost = usage.get("opencode_cost_usd")
    else:
        cost = run.get("cost_usd")
    findings = compute_findings(run, cost, out_spec, longest_gap, avg_turn)

    scan = run.get("scan") or {}
    evidence = run.get("evidence") or {}

    out = {
        "run_id": run.get("run_id"),
        "workflow": run.get("workflow"),
        "status": run.get("status"),
        "conclusion": run.get("conclusion"),
        "model": run.get("model"),
        "routing_rule": run.get("routing_rule"),
        "wall_time_seconds": run.get("wall_time_seconds"),
        "timeout_hit": bool(run.get("timeout")),
        "cost_usd": cost,
        "tokens": _tokens_from_run(run, usage),
        "tool_counts": tool_counts,
        "blocked_calls": sorted(run.get("blocked_calls") or []),
        "out_of_spec_reads": out_spec,
        "seconds_per_tool_turn": avg_turn,
        "longest_gap_seconds": longest_gap,
        "scan_result": scan.get("result"),
        "scan_detail": scan.get("detail"),
        "evidence_present": bool(evidence.get("present")),
        "evidence_label": evidence.get("label"),
        "findings": findings,
    }
    # Optional keys from a #31 run record. Omitted on the --input fixtures so
    # those expected-*.json files stay byte-identical.
    if "gate" in run:
        out["gate"] = run.get("gate")
    if "gate_passed" in run:
        out["gate_passed"] = run.get("gate_passed")
    return out


def _fmt_unavailable(value):
    """Render a value for the human-readable output; null becomes 'unavailable'."""
    return "unavailable" if value is None else str(value)


def render_markdown(review):
    """Short markdown rendering of one run's review."""
    lines = []
    lines.append(f"## /oc run review {review['run_id']}")
    lines.append("")
    lines.append(f"- model: `{review['model']}` ({review['routing_rule']})")
    lines.append(f"- conclusion: {review['conclusion']} ({review['status']})")
    lines.append(
        f"- wall time: {review['wall_time_seconds']}s, timeout: "
        f"{'yes' if review['timeout_hit'] else 'no'}"
    )
    lines.append(f"- cost: ${review['cost_usd']}")
    tok = review.get("tokens") or {}
    lines.append(
        "- tokens: in={t}, cached={c}, out={o}, reasoning={r}".format(
            t=_fmt_unavailable(tok.get("in")),
            c=_fmt_unavailable(tok.get("cached")),
            o=_fmt_unavailable(tok.get("out")),
            r=_fmt_unavailable(tok.get("reasoning")),
        )
    )
    lines.append(f"- tool counts: {review['tool_counts']}")
    gap = review["longest_gap_seconds"]
    gap_str = "unavailable" if gap is None else f"{gap}s"
    lines.append(
        "- seconds/tool turn: {t}, longest gap: {g}".format(
            t=_fmt_unavailable(review["seconds_per_tool_turn"]),
            g=gap_str,
        )
    )
    lines.append(f"- scan: {review['scan_result']}; evidence: {review['evidence_label']}")
    if "gate_passed" in review:
        lines.append(f"- gate_passed: {review['gate_passed']}")
    lines.append("- findings:")
    for f in review["findings"]:
        lines.append(f"  - `{f['code']}` ({f['severity']}): {f['meaning']}")
    lines.append("")
    return "\n".join(lines)


def run_gh(args):
    """Run a read-only gh subprocess; return (returncode, stdout).

    The binary is overridable for offline tests that must never hit the
    network; the override value is never printed.
    """
    binary = os.environ.get("FACTORY_RUN_REVIEW_GH", "gh")
    argv = list(args)
    if _GH_REPO and argv and argv[0] != "api":
        argv.extend(["--repo", _GH_REPO])
    try:
        proc = subprocess.run(
            [binary] + argv, capture_output=True, text=True, check=False
        )
        return proc.returncode, proc.stdout
    except (OSError, subprocess.SubprocessError):
        return -1, ""


def infer_repo():
    """Return owner/name from the current checkout, or ''."""
    rc, out = run_gh(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"])
    if rc != 0:
        return ""
    return out.strip()


def resolve_pr(pr_number):
    """Return (headRefName, issue_number or None) for a PR."""
    rc, out = run_gh(
        [
            "pr",
            "view",
            str(pr_number),
            "--json",
            "headRefName",
            "--jq",
            ".headRefName",
        ]
    )
    if rc != 0:
        return None, None
    head = out.strip() or None
    return head, issue_number_from_branch(head) if head else None


def resolve_pr_head(pr_number):
    """Return the PR's head branch name, or None on failure."""
    head, _ = resolve_pr(pr_number)
    return head


def list_workflow_runs():
    """List workflow runs across the /oc workflows (read-only).

    The real workflow names are opencode-spike, opencode-spec, opencode-fix; a
    --workflow=opencode filter matches none of them, so the list is fetched
    unfiltered and filtered by name in code.
    """
    rc, out = run_gh(
        [
            "run",
            "list",
            "--json",
            "databaseId,workflowName,status,conclusion,createdAt,updatedAt,headBranch,displayTitle",
            "--limit",
            "200",
        ]
    )
    if rc != 0:
        return []
    try:
        runs = json.loads(out)
    except json.JSONDecodeError:
        return []
    return [r for r in runs if r.get("workflowName") in WORKFLOW_NAMES]


def build_run_id_from_branch(branch):
    """Return the build run id encoded in a head branch oc/issue-<N>-<id>, else None."""
    if not isinstance(branch, str):
        return None
    m = re.match(r"oc/issue-\d+-(\d+)$", branch)
    return m.group(1) if m else None


def issue_number_from_branch(branch):
    """Return the issue number encoded in a head branch oc/issue-<N>-<id>, else None."""
    if not isinstance(branch, str):
        return None
    m = re.match(r"oc/issue-(\d+)-\d+$", branch)
    return int(m.group(1)) if m else None


def _title_matches_pr(title, pr_head):
    """True when a run displayTitle belongs to this PR's issue or build run.

    Matches on the PR's build run id or its issue number. The issue number is
    matched either as `issue #<N>` or as a bare `#<N>` (some /oc run titles,
    e.g. an `opencode-spec` run, carry `#<N>` without the word "issue"), so a
    spec run whose headBranch is `main` still belongs to the reviewed issue.
    """
    if not isinstance(title, str) or not title:
        return False
    build_id = build_run_id_from_branch(pr_head)
    pr_issue = issue_number_from_branch(pr_head)
    if build_id and build_id in title:
        return True
    if pr_issue and re.search(rf"(?:issue\s*)?#{pr_issue}\b", title, re.I):
        return True
    return False


def select_oc_runs(runs, pr_head):
    """Select the runs that belong to a PR.

    A build is triggered from an issue comment and often has headBranch `main`
    while the PR head is `oc/issue-<N>-<build_run_id>`. So we take the build run
    id from the PR branch name and include that run, plus later opencode-fix
    (and same-issue) runs that belong to the same PR: same branch, same issue
    number in the branch, or displayTitle containing the build run id or
    `issue #<N>`. Skipped sibling workflows are ignored.
    """
    build_id = build_run_id_from_branch(pr_head)
    pr_issue = issue_number_from_branch(pr_head)
    selected = []
    for r in runs or []:
        if r.get("conclusion") == "skipped":
            continue
        run_id = str(r.get("databaseId"))
        branch = r.get("headBranch")
        if build_id and run_id == build_id:
            selected.append(r)
            continue
        if r.get("workflowName") == FIX_WORKFLOW:
            if branch == pr_head:
                selected.append(r)
            elif pr_issue and issue_number_from_branch(branch) == pr_issue:
                selected.append(r)
            elif _title_matches_pr(r.get("displayTitle"), pr_head):
                selected.append(r)
        elif r.get("workflowName") == SPEC_WORKFLOW and _title_matches_pr(
            r.get("displayTitle"), pr_head
        ):
            selected.append(r)
    selected.sort(key=lambda r: str(r.get("databaseId", "")))
    return selected


def run_log_text(run_id):
    """Fetch a run's job logs read-only; return text or '' on failure."""
    rc, out = run_gh(["run", "view", str(run_id), "--log"])
    if rc != 0:
        return ""
    return out


def wall_time_seconds(created_at, updated_at):
    """Deterministic wall-clock seconds between two ISO timestamps, else None."""
    try:
        from datetime import datetime
        from datetime import timezone

        def parse(iso):
            iso = iso.replace("Z", "+00:00")
            return datetime.fromisoformat(iso)

        start = parse(created_at)
        end = parse(updated_at)
        if end.tzinfo is None:
            end = end.replace(tzinfo=timezone.utc)
        if start.tzinfo is None:
            start = start.replace(tzinfo=timezone.utc)
        return int(max(0, (end - start).total_seconds()))
    except (ValueError, TypeError):
        return None


def strip_ansi(text):
    """Remove ANSI escape sequences from a string."""
    if not text:
        return text
    return ANSI_RE.sub("", text)


def strip_role_prefix(text):
    """Remove a leading role label (e.g. `assistant `) from a tool log line.

    Real OpenCode logs print `assistant → Read <path>` (the role label comes
    before the arrow), so the symbol matchers must see the line starting at the
    arrow. Lines without a role prefix are returned unchanged.
    """
    if not text:
        return text
    return _ROLE_PREFIX_RE.sub("", text, count=1)


def _tool_input_str(state):
    """Best-effort string for a tool part's input, for out-of-spec reads."""
    if not isinstance(state, dict):
        return None
    inp = state.get("input")
    if isinstance(inp, str):
        return inp
    if not isinstance(inp, dict):
        return None
    for key in ("file_path", "path", "glob", "pattern", "command"):
        v = inp.get(key)
        if isinstance(v, str):
            return v
    return None


def events_from_session(session):
    """Flatten a session export's tool parts into {tool, ts, input} events.

    The session export (`info.messages[].parts[]` with `type: "tool"`) is the
    same shape the `opencode-export.json` fixture documents. One event is derived
    per tool part with the timestamp from `state.time.start` (milliseconds),
    falling back to the message `info.time.created` when a tool part has no start
    time. A part with no timestamp keeps a null `ts` so per-turn timing stays
    null rather than fabricated.
    """
    events = []
    if not isinstance(session, dict):
        return events
    info = session.get("info") or {}
    messages = session.get("messages")
    if not isinstance(messages, list):
        messages = info.get("messages")
    for msg in messages or []:
        if not isinstance(msg, dict):
            continue
        msg_ts = None
        mtime = (msg.get("info") or {}).get("time") or {}
        created = mtime.get("created")
        if isinstance(created, (int, float)):
            msg_ts = created
        for part in (msg.get("parts") or []):
            if not isinstance(part, dict) or part.get("type") != "tool":
                continue
            tool = part.get("tool")
            if not isinstance(tool, str):
                continue
            state = part.get("state") or {}
            ts = None
            stime = state.get("time") or {}
            if isinstance(stime.get("start"), (int, float)):
                ts = stime.get("start")
            elif msg_ts is not None:
                ts = msg_ts
            events.append(
                {"tool": tool, "ts": ts, "input": _tool_input_str(state)}
            )
    return events


def _match_real_log_line(line):
    """Match one real OpenCode log line into {tool, ts, input}, or None.

    Handles the `→ Read <path>`, `✱ Glob ...` and `✗ <cmd>` forms real OpenCode
    logs print (ANSI codes must already be stripped), plus the legacy synthetic
    `<tool> tool call ...` spelling so older fixtures keep passing. Timestamps
    are not present in plain logs, so `ts` stays null; the parse never guesses.
    """
    s = strip_role_prefix(line.strip())
    low = s.lower()
    for tool in ("read", "glob", "bash", "edit", "write", "task", "grep"):
        if f"{tool} tool" in low and "tool call" in low:
            return {"tool": tool, "ts": None, "input": None}
    if s.startswith(("→", "✱", "✗")):
        rest = s[1:].strip()
    elif s.startswith(("->", "*")):
        rest = s[1:].strip()
    else:
        return None
    m = re.match(r"^([A-Za-z]+)\s*:\s*(.*)$", rest) or re.match(
        r"^([A-Za-z]+)\s+(.*)$", rest
    )
    if not m:
        return None
    tool = m.group(1).lower()
    if tool not in ("read", "glob", "bash", "edit", "write", "task", "grep"):
        return None
    arg = m.group(2).strip()
    return {"tool": tool, "ts": None, "input": arg or None}


def parse_tool_events(log_text):
    """Best-effort parse of tool calls from a run log.

    Strips ANSI escapes first, then matches the real OpenCode line format
    (`→ Read <path>`, `✱ Glob ...`, `✗ <cmd> failed`) and the legacy synthetic
    `<tool> tool call ...` spelling. Returns a list of {tool, ts, input}.
    """
    events = []
    for raw in (log_text.splitlines() or []):
        line = strip_ansi(raw)
        if not line.strip():
            continue
        ev = _match_real_log_line(line)
        if ev is not None:
            events.append(ev)
    return events


def _denied_command(lines, idx):
    """Best-effort command string for a denied call.

    Returns the nearest preceding `✗` (failed/denied) tool line, else the
    nearest `→`/`✱` tool line, else the denial line itself. The returned string
    is a command/path from the log, never a key, token or env value.
    """
    lo = max(0, idx - 6)
    for j in range(lo, idx + 1):
        s = strip_role_prefix(strip_ansi(lines[j]).strip())
        if s.startswith("✗"):
            return s
    for j in range(lo, idx + 1):
        s = strip_role_prefix(strip_ansi(lines[j]).strip())
        if s.startswith(("→", "✱", "->", "*")):
            return s
    return strip_ansi(lines[idx]).strip()


def _is_agent_tool_line(line):
    """True when a log line is an agent tool-result line (`✗`/`→`/`✱`).

    The real OpenCode denial text only counts when it appears on or right
    around an agent tool-result line. The echoed `OC_INSTRUCTION:` env line and
    the StepSecurity harden-runner config JSON (for example `denied_endpoints`)
    are workflow noise, not tool output, so they never anchor a blocked call.
    """
    s = strip_role_prefix(strip_ansi(line)).strip()
    return s.startswith(("✗", "→", "✱", "->", "*"))


def detect_blocked_calls(log_text):
    """Collect guardrail command strings that were denied/blocked in the log.

    A blocked call counts only when the real OpenCode permission-denial marker
    (`The user has specified a rule which prevents you from using this specific
    tool call`) appears on an agent tool-result line or immediately around one.
    The bare `denied` / `blocked` / `guardrail` vocabulary no longer fires on
    the whole workflow log, so an echoed `OC_INSTRUCTION:` env line or the
    StepSecurity harden-runner `denied_endpoints` config line cannot produce a
    false positive. The denied command is captured from the surrounding log.
    """
    lines = (log_text or "").splitlines()
    blocked = []
    seen = set()
    for i, raw in enumerate(lines):
        low = strip_ansi(raw).lower()
        if not PERMISSION_DENIED_RE.search(low):
            continue
        lo = max(0, i - 6)
        if not any(_is_agent_tool_line(lines[j]) for j in range(lo, i + 1)):
            continue
        cmd = _denied_command(lines, i)
        if cmd and cmd not in seen:
            blocked.append(cmd)
            seen.add(cmd)
    return blocked


def _read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()
    except (OSError, UnicodeDecodeError):
        return None


def _read_json(path):
    text = _read_text(path)
    if text is None:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def parse_spec_files(spec_md):
    """Extract the spec's `## Files` create/read-first paths."""
    if not spec_md:
        return []
    paths = []
    in_files = False
    for line in spec_md.splitlines():
        stripped = line.strip()
        if stripped.startswith("## Files"):
            in_files = True
            continue
        if in_files and stripped.startswith("## "):
            break
        if not in_files:
            continue
        low = stripped.lower()
        if low.startswith("- create:") or low.startswith("- read first:"):
            path = stripped.split(":", 1)[1].strip().strip("`").strip()
            p = normalize_path(path)
            if p:
                paths.append(p)
    return sorted(set(paths))


def iter_artifact_roots(artifacts_dir):
    """Yield artifacts_dir and one-level subdirectories (`gh run download` layout)."""
    if not artifacts_dir or not os.path.isdir(artifacts_dir):
        return
    yield artifacts_dir
    try:
        names = sorted(os.listdir(artifacts_dir))
    except OSError:
        return
    for name in names:
        path = os.path.join(artifacts_dir, name)
        if os.path.isdir(path):
            yield path


def parse_usage_metrics_cost(text):
    """Return the OpenCode-reported cost from usage-metrics.md, or None."""
    if not text:
        return None
    m = USAGE_COST_RE.search(text)
    if not m:
        return None
    try:
        return float(m.group(1))
    except ValueError:
        return None


def parse_scan_from_log(log_text):
    """Return {result, detail} from `artifact-scan: passed.` / FAIL log lines."""
    if not log_text:
        return {"result": None, "detail": None}
    result = None
    detail = None
    for line in log_text.splitlines():
        if SCAN_PASS_RE.search(line):
            result, detail = "pass", line.strip()
        elif SCAN_FAIL_RE.search(line):
            result, detail = "fail", line.strip()
    return {"result": result, "detail": detail}


def extract_json_block(body):
    """Return the first fenced JSON object in a comment body, or None."""
    if not isinstance(body, str):
        return None
    in_block = False
    buf = []
    for line in body.splitlines():
        if line.strip().startswith("```"):
            if in_block:
                try:
                    data = json.loads("\n".join(buf))
                except json.JSONDecodeError:
                    return None
                return data if isinstance(data, dict) else None
            in_block = True
            buf = []
        elif in_block:
            buf.append(line)
    return None


def parse_run_record_comment(body):
    """Parse a #31 `<!-- factory-run-record -->` comment body into a record dict."""
    if not isinstance(body, str) or RUN_RECORD_MARKER not in body:
        return None
    return extract_json_block(body)


def numeric_run_id(record):
    """Numeric Actions run id from a record's run_id or workflow_run_url."""
    if not isinstance(record, dict):
        return None
    rid = record.get("run_id")
    if isinstance(rid, int):
        return rid
    if isinstance(rid, str):
        m = GHA_RUN_RE.match(rid.strip())
        if m:
            return int(m.group(1))
        if rid.isdigit():
            return int(rid)
    url = record.get("workflow_run_url") or ""
    m = re.search(r"/actions/runs/(\d+)", str(url))
    if m:
        return int(m.group(1))
    return None


def workflow_from_record(record):
    """Map a run record to an /oc workflow name when the mapping is unambiguous."""
    if not isinstance(record, dict):
        return None
    work_type = record.get("work_type")
    outcome = record.get("outcome")
    if work_type == "spec":
        return SPEC_WORKFLOW
    if outcome == "pr_updated":
        return FIX_WORKFLOW
    if outcome == "pr_opened":
        return SPIKE_WORKFLOW
    return None


def conclusion_from_outcome(outcome):
    """Map a record outcome to a GitHub-like conclusion, or None."""
    if outcome in ("pr_opened", "pr_updated", "no_changes"):
        return "success"
    if outcome in ("failed", "cap_exceeded", "gate_failed"):
        return "failure"
    if outcome == "cancelled":
        return "cancelled"
    return None


def scan_from_gate(gate):
    """Map record gate.gitleaks pass/fail onto the scan field; skip stays null."""
    if not isinstance(gate, dict):
        return {"result": None, "detail": None}
    gitleaks = gate.get("gitleaks")
    if gitleaks == "pass":
        return {"result": "pass", "detail": "gate.gitleaks: pass"}
    if gitleaks == "fail":
        return {"result": "fail", "detail": "gate.gitleaks: fail"}
    return {"result": None, "detail": None}


def facts_from_record(record):
    """Build a run-facts object from a #31 run record. Missing fields stay null."""
    run_id = numeric_run_id(record)
    gate = record.get("gate") if isinstance(record.get("gate"), dict) else None
    tokens = {
        "in": record.get("tokens_in"),
        "cached": record.get("tokens_cached"),
        "out": record.get("tokens_out"),
        "reasoning": record.get("tokens_reasoning"),
    }
    started = record.get("started_at")
    ended = record.get("ended_at")
    wall = record.get("duration_s")
    if wall is None:
        wall = wall_time_seconds(started, ended)
    facts = {
        "run_id": run_id,
        "workflow": workflow_from_record(record),
        "status": "completed" if record.get("outcome") else None,
        "conclusion": conclusion_from_outcome(record.get("outcome")),
        "model": record.get("model"),
        "routing_rule": None,
        "created_at": started,
        "updated_at": ended,
        "wall_time_seconds": wall,
        "timeout": False,
        "opencode_export": None,
        "spec_files": [],
        "tool_events": [],
        "blocked_calls": [],
        "scan": scan_from_gate(gate),
        "evidence": {"present": None, "label": None},
        "cost_usd": record.get("actual_cost_usd"),
        "tokens": tokens,
        "gate": gate,
        "gate_passed": record.get("gate_passed"),
    }
    return facts


def apply_record_to_facts(facts, record):
    """Overlay record fields onto existing facts; the record wins."""
    overlay = facts_from_record(record)
    for key in (
        "model",
        "cost_usd",
        "tokens",
        "gate",
        "gate_passed",
        "workflow",
        "status",
        "conclusion",
        "wall_time_seconds",
        "created_at",
        "updated_at",
    ):
        if overlay.get(key) is not None:
            facts[key] = overlay[key]
    scan = overlay.get("scan") or {}
    if scan.get("result"):
        facts["scan"] = scan
    return facts


def parse_artifacts(artifacts_dir):
    """Populate live run facts from a downloaded artifact directory.

    Degrades gracefully: a missing or malformed file becomes null, never a
    guess. Walks one level of subdirectories because `gh run download --dir`
    writes `oc-artifacts-<id>/`, `oc-fix-artifacts-<id>/`, `oc-record-<id>/`
    and `oc-run-record-<id>-<attempt>/`. A run-record.json is preferred for
    model/cost/gate. Cost/tokens otherwise come from a session export (via
    factory-usage.py) or from usage-metrics.md (`OpenCode-reported cost: $X`).
    """
    facts = {
        "model": None,
        "routing_rule": None,
        "opencode_export": None,
        "spec_files": [],
        "scan": {"result": None, "detail": None},
        "evidence": {"present": None, "label": None},
        "tool_events": [],
    }
    if not artifacts_dir or not os.path.isdir(artifacts_dir):
        return facts

    record = None
    evidence_found = False
    tool_events = []
    for root in iter_artifact_roots(artifacts_dir):
        rec = _read_json(os.path.join(root, "run-record.json"))
        if isinstance(rec, dict) and rec.get("run_id"):
            record = rec

        start = _read_json(os.path.join(root, "run-start.json"))
        if start:
            facts["model"] = start.get("model") or start.get("model_id")
            if start.get("routed_rule") is not None:
                facts["routing_rule"] = start.get("routed_rule")

        spec_md = _read_text(os.path.join(root, "spec.md"))
        if spec_md:
            facts["spec_files"] = parse_spec_files(spec_md)

        scan = _read_json(os.path.join(root, "scan.json"))
        if scan:
            facts["scan"] = {
                "result": scan.get("result"),
                "detail": scan.get("detail"),
            }

        if os.path.isfile(os.path.join(root, "evidence.md")):
            evidence_found = True

        export = _read_json(os.path.join(root, "opencode-export.json"))
        if export is not None:
            facts["opencode_export"] = export

        # Structured session exports (`usage/session-<n>.json`) written by the
        # run meter are the authoritative source of tool events.
        usage_dir = os.path.join(root, "usage")
        if os.path.isdir(usage_dir):
            for name in sorted(os.listdir(usage_dir)):
                if name.startswith("session-") and name.endswith(".json"):
                    session = _read_json(os.path.join(usage_dir, name))
                    if isinstance(session, dict):
                        tool_events.extend(events_from_session(session))

        cost = parse_usage_metrics_cost(_read_text(os.path.join(root, "usage-metrics.md")))
        if cost is None:
            cost = parse_usage_metrics_cost(_read_text(os.path.join(root, "usage-report.txt")))
        if cost is not None and facts.get("cost_usd") is None:
            facts["cost_usd"] = cost

    facts["tool_events"] = tool_events
    if evidence_found:
        facts["evidence"] = {"present": True, "label": "harness-verified"}
    else:
        facts["evidence"] = {"present": False, "label": None}

    if record:
        apply_record_to_facts(facts, record)

    return facts


def base_run_facts(run, log_text):
    """Build the base run-facts object for a workflow run, from gh metadata."""
    run_id = run.get("databaseId")
    scan = parse_scan_from_log(log_text)
    return {
        "run_id": run_id,
        "workflow": run.get("workflowName"),
        "status": run.get("status"),
        "conclusion": run.get("conclusion"),
        "model": None,
        "routing_rule": None,
        "created_at": run.get("createdAt"),
        "updated_at": run.get("updatedAt"),
        "wall_time_seconds": wall_time_seconds(
            run.get("createdAt"), run.get("updatedAt")
        ),
        "timeout": bool(log_text and "timed out" in log_text.lower()),
        "opencode_export": None,
        "spec_files": [],
        "tool_events": parse_tool_events(log_text),
        "blocked_calls": detect_blocked_calls(log_text),
        "scan": scan,
        "evidence": {"present": None, "label": None},
    }


def download_run_artifacts(run_id, dest_dir):
    """Download a run's artifacts read-only into dest_dir; True on success."""
    rc, _ = run_gh(["run", "download", str(run_id), "--dir", dest_dir])
    return rc == 0


def fetch_issue_records(issue_number):
    """Load #31 run records from issue comments (read-only)."""
    if issue_number is None:
        return []
    records = []
    if _GH_REPO:
        rc, out = run_gh(
            [
                "api",
                f"repos/{_GH_REPO}/issues/{issue_number}/comments",
                "--paginate",
            ]
        )
        comments = []
        if rc == 0 and out.strip():
            try:
                comments = json.loads(out)
            except json.JSONDecodeError:
                comments = []
            if not isinstance(comments, list):
                comments = []
    else:
        rc, out = run_gh(
            ["issue", "view", str(issue_number), "--json", "comments"]
        )
        comments = []
        if rc == 0 and out.strip():
            try:
                payload = json.loads(out)
                comments = payload.get("comments") or []
            except json.JSONDecodeError:
                comments = []
    for comment in comments:
        if not isinstance(comment, dict):
            continue
        body = comment.get("body")
        rec = parse_run_record_comment(body)
        if rec is None:
            continue
        if rec.get("issue") not in (None, issue_number) and rec.get("issue") != int(
            issue_number
        ):
            continue
        records.append(rec)
    return records


def _issue_from_pr_or_args(args):
    """Resolve the issue number from --issue, or from the PR head branch."""
    if args.issue is not None:
        return args.issue, args.pr, resolve_pr_head(args.pr) if args.pr else None
    pr_number = args.pr
    head = None
    issue = None
    if pr_number is not None:
        head, issue = resolve_pr(pr_number)
    return issue, pr_number, head


def _pr_from_issue_timeline(issue, repo):
    """Best-effort PR number that references this issue, or None."""
    if issue is None or not repo:
        return None
    rc, out = run_gh(
        [
            "api",
            f"repos/{repo}/issues/{issue}/timeline",
            "--paginate",
            "--jq",
            '[.[] | select(.event == "cross-referenced" and .source.issue.pull_request) | .source.issue.number] | max',
        ]
    )
    if rc == 0 and out.strip() not in ("", "null"):
        try:
            return int(out.strip())
        except ValueError:
            return None
    return None


def enrich_from_artifacts(item, run_id, log_text=""):
    """Fill missing live fields from downloaded artifacts and logs."""
    if log_text:
        scan = parse_scan_from_log(log_text)
        if scan.get("result") and not (item.get("scan") or {}).get("result"):
            item["scan"] = scan
        if not item.get("tool_events"):
            item["tool_events"] = parse_tool_events(log_text)
        if not item.get("blocked_calls"):
            item["blocked_calls"] = detect_blocked_calls(log_text)
        if log_text and "timed out" in log_text.lower():
            item["timeout"] = True
    if run_id is None:
        return item
    with tempfile.TemporaryDirectory(
        prefix="oc-review-", dir=tempfile.gettempdir()
    ) as tmp:
        if download_run_artifacts(run_id, tmp):
            parsed = parse_artifacts(tmp)
            # Record/export/metrics overlay: parsed record fields win; keep
            # already-populated record fields when parse found nothing.
            for key, value in parsed.items():
                if key == "scan":
                    if (value or {}).get("result"):
                        item[key] = value
                    elif not (item.get("scan") or {}).get("result"):
                        item[key] = value
                    continue
                if key == "evidence":
                    if value and value.get("present"):
                        item[key] = value
                    elif item.get("evidence") is None or item.get("evidence") == {
                        "present": None,
                        "label": None,
                    }:
                        item[key] = value
                    continue
                if key == "tool_events":
                    # Session exports are authoritative; override the log
                    # fallback only when they actually contain events.
                    if value:
                        item[key] = value
                    continue
                if value is not None and value != []:
                    if key in ("model", "cost_usd", "tokens", "gate", "gate_passed"):
                        # Keep a record value already set.
                        if item.get(key) in (None, {}, {"in": None, "cached": None, "out": None, "reasoning": None}):
                            item[key] = value
                        elif key not in item:
                            item[key] = value
                    elif item.get(key) in (None, [], {}):
                        item[key] = value
    return item


def fetch_runs(args):
    """Resolve PR/issue to /oc run facts using gh (read-only).

    Prefers #31 run records on the issue; fills any remaining runs (and any
    fields a record does not carry) from workflow artifacts and logs.
    """
    global _GH_REPO
    _GH_REPO = args.repo or infer_repo() or None

    pr_number = args.pr
    issue = args.issue
    if pr_number is None and issue is not None and _GH_REPO:
        pr_number = _pr_from_issue_timeline(issue, _GH_REPO)

    head_branch = None
    if pr_number is not None:
        head_branch, branch_issue = resolve_pr(pr_number)
        if issue is None:
            issue = branch_issue

    facts_by_id = {}

    for rec in fetch_issue_records(issue):
        item = facts_from_record(rec)
        rid = item.get("run_id")
        if rid is None:
            continue
        facts_by_id[int(rid)] = item

    if head_branch:
        for run in select_oc_runs(list_workflow_runs(), head_branch):
            run_id = run.get("databaseId")
            if run_id is None:
                continue
            run_id = int(run_id)
            log_text = run_log_text(run_id)
            if run_id in facts_by_id:
                # Record already selected this run; only fill gaps from logs
                # and artifacts (routing rule, evidence, scan if still empty).
                enrich_from_artifacts(facts_by_id[run_id], run_id, log_text)
                if facts_by_id[run_id].get("workflow") is None:
                    facts_by_id[run_id]["workflow"] = run.get("workflowName")
                continue
            item = base_run_facts(run, log_text)
            enrich_from_artifacts(item, run_id, log_text)
            facts_by_id[run_id] = item

    facts = [facts_by_id[k] for k in sorted(facts_by_id)]
    return facts


def _comments_from_live_dir(live_dir):
    """Load recorded issue comments or raw record JSON from a fixture dir."""
    comments = _read_json(os.path.join(live_dir, "issue-comments.json"))
    if isinstance(comments, list):
        return comments
    path = os.path.join(live_dir, "issue-comment.md")
    text = _read_text(path)
    if text:
        return [{"body": text}]
    rec = _read_json(os.path.join(live_dir, "run-record.json"))
    if isinstance(rec, dict):
        return [{"body": RUN_RECORD_MARKER + "\n\n```json\n" + json.dumps(rec) + "\n```\n"}]
    return []


def fetch_runs_live_dir(live_dir):
    """Exercise the live-path parser offline from a recorded fixture directory.

    The fixture may include #31 issue-comment records (preferred) and/or the
    PR head branch, unfiltered `gh run list` JSON, and artifact subdirectories
    (including the real `gh run download` nested layout).
    """
    facts_by_id = {}
    for comment in _comments_from_live_dir(live_dir):
        body = comment.get("body") if isinstance(comment, dict) else None
        rec = parse_run_record_comment(body)
        if rec is None and isinstance(comment, dict) and comment.get("run_id"):
            rec = comment
        if rec is None:
            continue
        item = facts_from_record(rec)
        if item.get("run_id") is None:
            continue
        facts_by_id[int(item["run_id"])] = item

    pr_head = _read_text(os.path.join(live_dir, "pr-head.txt"))
    runs = _read_json(os.path.join(live_dir, "run-list.json"))
    if pr_head and runs is not None:
        pr_head = pr_head.strip()
        selected = select_oc_runs(runs, pr_head)
        for run in selected:
            run_id = run.get("databaseId")
            if run_id is None:
                continue
            run_id = int(run_id)
            art = os.path.join(live_dir, "artifacts", str(run_id))
            log_text = _read_text(os.path.join(art, "log.txt")) or ""
            # Nested download layout may keep the log next to the files.
            if not log_text:
                for root in iter_artifact_roots(art):
                    log_text = _read_text(os.path.join(root, "log.txt")) or log_text
            if run_id in facts_by_id:
                parsed = parse_artifacts(art) if os.path.isdir(art) else {}
                item = facts_by_id[run_id]
                for key, value in parsed.items():
                    if value is not None and item.get(key) in (None, [], {}):
                        item[key] = value
                scan = parse_scan_from_log(log_text)
                if scan.get("result") and not (item.get("scan") or {}).get("result"):
                    item["scan"] = scan
                continue
            item = base_run_facts(run, log_text)
            if os.path.isdir(art):
                parsed = parse_artifacts(art)
                for key, value in parsed.items():
                    if key == "scan":
                        if (value or {}).get("result"):
                            item[key] = value
                        continue
                    if key == "tool_events":
                        # Session exports are authoritative; only override the
                        # log fallback when they actually contain events.
                        if value:
                            item[key] = value
                        continue
                    if value is not None:
                        item[key] = value
            facts_by_id[run_id] = item

    return [facts_by_id[k] for k in sorted(facts_by_id)]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr", type=int, default=None, help="PR number")
    parser.add_argument("--issue", type=int, default=None, help="issue number")
    parser.add_argument(
        "--repo",
        default=None,
        help="owner/name repo for issue lookup and live gh calls",
    )
    parser.add_argument("--input", default=None, help="parsed run-facts JSON file (offline)")
    parser.add_argument(
        "--live-dir",
        default=None,
        help="recorded fixture dir that drives the live-path parser offline (no gh)",
    )
    parser.add_argument("--output", default=None, help="write JSON to this path instead of stdout")
    args = parser.parse_args(argv)

    if args.input is not None:
        with open(args.input, "r", encoding="utf-8") as fh:
            run = json.load(fh)
        review = review_run(run)
        text = json.dumps(review, indent=2, sort_keys=True)
        if args.output:
            with open(args.output, "w", encoding="utf-8") as fh:
                fh.write(text + "\n")
        else:
            print(text)
        return 0

    if args.live_dir is not None:
        runs = fetch_runs_live_dir(args.live_dir)
        reviews = [review_run(run) for run in runs]
        payload = {"runs": reviews}
        text = json.dumps(payload, indent=2, sort_keys=True)
        if args.output:
            with open(args.output, "w", encoding="utf-8") as fh:
                fh.write(text + "\n")
        else:
            print(text)
            for review in reviews:
                print()
                print(render_markdown(review))
        return 0

    if args.pr is None and args.issue is None:
        parser.error("provide --pr, --issue, --live-dir, or --input")

    args.repo = args.repo or ""
    runs = fetch_runs(args)
    if not runs:
        print(json.dumps({"runs": [], "findings": []}, indent=2, sort_keys=True))
        return 0
    reviews = [review_run(run) for run in runs]
    payload = {"runs": reviews}
    text = json.dumps(payload, indent=2, sort_keys=True)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    else:
        print(text)
        for review in reviews:
            print()
            print(render_markdown(review))
    return 0


if __name__ == "__main__":
    sys.exit(main())
