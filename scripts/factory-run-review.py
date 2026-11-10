#!/usr/bin/env python3
"""Deterministic post-merge /oc run-review.

Reads the run facts for a PR's /oc workflow run and produces a key-sorted JSON
summary plus a short markdown summary. Pure transform: no model calls, no random
ids, no wall clock. Cost and token figures are delegated to scripts/factory-usage.py
via subprocess so they never drift from the canonical implementation.

In --pr / --issue mode the run facts are fetched read-only with `gh`. In --input
mode (used by the offline test) the run facts are read from a sanitized fixture
file and only the JSON summary is printed, so it can be compared byte-for-byte
with a committed expected-*.json using cmp.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FACTORY_USAGE = os.path.join(REPO_ROOT, "scripts", "factory-usage.py")

# Thresholds (seconds). Stays stable so identical input gives identical output.
STALL_GAP_SECONDS = 780.0
SLOW_TURN_SECONDS = 30.0
COST_OVERRUN_USD = 0.10

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


def review_run(run):
    """Pure transform from run facts to the review JSON object."""
    usage = run_usage(run.get("opencode_export"))
    tool_counts, gaps, avg_turn, longest_gap = tool_turn_stats(run.get("tool_events"))
    spec_files = run.get("spec_files") or []
    out_spec = out_of_spec_reads(run.get("tool_events"), spec_files)
    cost = usage.get("opencode_cost_usd") if usage else None
    findings = compute_findings(run, cost, out_spec, longest_gap, avg_turn)

    scan = run.get("scan") or {}
    evidence = run.get("evidence") or {}

    return {
        "run_id": run.get("run_id"),
        "workflow": run.get("workflow"),
        "status": run.get("status"),
        "conclusion": run.get("conclusion"),
        "model": run.get("model"),
        "routing_rule": run.get("routing_rule"),
        "wall_time_seconds": run.get("wall_time_seconds"),
        "timeout_hit": bool(run.get("timeout")),
        "cost_usd": cost,
        "tokens": {
            "in": usage.get("tokens_in") if usage else None,
            "cached": usage.get("tokens_cached") if usage else None,
            "out": usage.get("tokens_out") if usage else None,
            "reasoning": usage.get("tokens_reasoning") if usage else None,
        },
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
    lines.append(f"- scan: {review['scan_result']}; evidence: {review['evidence_label']}")
    lines.append("- findings:")
    for f in review["findings"]:
        lines.append(f"  - `{f['code']}` ({f['severity']}): {f['meaning']}")
    lines.append("")
    return "\n".join(lines)


def run_gh(args):
    """Run a read-only gh subprocess; return (returncode, stdout)."""
    try:
        proc = subprocess.run(
            args, capture_output=True, text=True, check=False
        )
        return proc.returncode, proc.stdout
    except (OSError, subprocess.SubprocessError):
        return -1, ""


def resolve_pr_head(pr_number):
    """Return the PR's head branch name, or None on failure."""
    rc, out = run_gh(
        [
            "gh",
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
        return None
    head = out.strip()
    return head or None


def list_oc_runs(head_branch):
    """List /oc workflow runs for a head branch (read-only)."""
    rc, out = run_gh(
        [
            "gh",
            "run",
            "list",
            "--workflow=opencode",
            "--json",
            "databaseId,workflowName,status,conclusion,createdAt,updatedAt,headBranch",
            "--limit",
            "100",
        ]
    )
    if rc != 0:
        return []
    try:
        runs = json.loads(out)
    except json.JSONDecodeError:
        return []
    return [r for r in runs if r.get("headBranch") == head_branch]


def run_log_text(run_id):
    """Fetch a run's job logs read-only; return text or '' on failure."""
    rc, out = run_gh(["gh", "run", "view", str(run_id), "--log"])
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


def parse_tool_events(log_text):
    """Best-effort parse of tool calls from a run log.

    Matches lines of the form `<tool_name> tool call ...` and captures a
    command/path where present. Returns a list of {tool, ts, input}. Unknown
    fields become null; the parse never guesses.
    """
    events = []
    for line in (log_text.splitlines() or []):
        low = line.lower()
        for tool in ("read", "glob", "bash", "edit", "write", "task"):
            if f"{tool} tool" in low and "tool call" in low:
                events.append({"tool": tool, "ts": None, "input": None})
                break
    return events


def detect_blocked_calls(log_text):
    """Collect guardrail command strings that were denied/blocked in the log."""
    blocked = []
    vocab = [
        "mkdir",
        "chmod",
        "git commit",
        "git push",
        "curl",
        "wget",
        "env",
        "printenv",
    ]
    for line in (log_text.splitlines() or []):
        low = line.lower()
        if any(word in low for word in ("denied", "blocked", "guardrail")):
            for word in vocab:
                if word in low:
                    blocked.append(line.strip())
                    break
    return blocked


def fetch_runs(args):
    """Resolve PR/issue to /oc run facts using gh (read-only)."""
    pr_number = args.pr
    if pr_number is None and args.issue is not None and args.repo:
        # Try to find the PR that closes the issue via its timeline; a missing
        # link is a graceful null result, never a crash.
        rc, out = run_gh(
            [
                "gh",
                "api",
                f"repos/{args.repo}/issues/{args.issue}/timeline",
                "--paginate",
                "--jq",
                '[.[] | select(.event == "cross-referenced" and .source.issue.pull_request) | .source.issue.number] | max',
            ]
        )
        if rc == 0 and out.strip() not in ("", "null"):
            pr_number = int(out.strip())
    head_branch = resolve_pr_head(pr_number) if pr_number is not None else None
    if head_branch is None:
        return []
    runs = list_oc_runs(head_branch)
    facts = []
    for run in runs:
        run_id = run.get("databaseId")
        log_text = run_log_text(run_id) if run_id is not None else ""
        facts.append(
            {
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
                "scan": {"result": None, "detail": None},
                "evidence": {"present": None, "label": None},
            }
        )
    return facts


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr", type=int, default=None, help="PR number")
    parser.add_argument("--issue", type=int, default=None, help="issue number")
    parser.add_argument("--repo", default=None, help="owner/name repo for issue lookup")
    parser.add_argument("--input", default=None, help="parsed run-facts JSON file (offline)")
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

    if args.pr is None and args.issue is None:
        parser.error("provide --pr, --issue, or --input")

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
