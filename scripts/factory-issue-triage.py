#!/usr/bin/env python3
"""Backlog triage helper for the Factory Manager.

Offline:  python3 scripts/factory-issue-triage.py --issues-json PATH [--repo-dir .]
Live:     python3 scripts/factory-issue-triage.py --repo OWNER/REPO [--repo-dir .]

Produces a label hygiene audit, possibly-stale issues (script paths already on
disk), epic rollup, and a Recommendation / Why block for the next issue to
work (#130 formatting).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

_SCRIPT_DIR = Path(__file__).resolve().parent
_backlog_spec = importlib.util.spec_from_file_location(
    "factory_backlog", _SCRIPT_DIR / "factory-backlog.py"
)
_backlog = importlib.util.module_from_spec(_backlog_spec)
assert _backlog_spec.loader is not None
_backlog_spec.loader.exec_module(_backlog)

labels_of = _backlog.labels_of
is_pull_request = _backlog.is_pull_request
normalize_priority = _backlog.normalize_priority
normalize_risk = _backlog.normalize_risk
normalize_status = _backlog.normalize_status
build_issues_index = _backlog.build_issues_index
epic_done_total = _backlog.epic_done_total

PRIORITY_ORDER = _backlog.PRIORITY_ORDER
GH_JSON_FIELDS = _backlog.GH_JSON_FIELDS

RISK_RANK = {
    "low": 0,
    "trivial": 0,
    "medium": 1,
    "normal": 1,
    "high": 2,
    "unlabeled": 3,
}

SCRIPT_PATH_RE = re.compile(
    r"`?(scripts/[A-Za-z0-9_.-]+(?:\.(?:py|sh)|/[A-Za-z0-9_.-]+))`?",
    re.IGNORECASE,
)


def load_issues_json(path: Path) -> list:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, list):
        sys.stderr.write("ERROR: issues JSON must be an array\n")
        sys.exit(1)
    return data


def load_live(repo: str) -> list:
    if shutil.which("gh") is None:
        sys.stderr.write("ERROR: `gh` is not installed (required for --repo).\n")
        sys.exit(1)
    try:
        proc = subprocess.run(
            [
                "gh",
                "issue",
                "list",
                "--repo",
                repo,
                "--state",
                "all",
                "--limit",
                "500",
                "--json",
                ",".join(
                    [
                        "number",
                        "title",
                        "body",
                        "labels",
                        "createdAt",
                        "updatedAt",
                        "url",
                        "state",
                        "subIssuesSummary",
                        "issueDependenciesSummary",
                    ]
                ),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        sys.stderr.write(f"ERROR: could not run `gh`: {exc}\n")
        sys.exit(1)
    if proc.returncode != 0:
        sys.stderr.write(
            "ERROR: `gh issue list` failed:\n" + (proc.stderr or proc.stdout)
        )
        sys.exit(1)
    try:
        return json.loads(proc.stdout)
    except ValueError as exc:
        sys.stderr.write(f"ERROR: invalid JSON from gh: {exc}\n")
        sys.exit(1)


def open_issues(items: list) -> list:
    out = []
    for item in items:
        if not isinstance(item, dict) or is_pull_request(item):
            continue
        state = (item.get("state") or "open").lower()
        if state == "open":
            out.append(item)
    return out


def has_priority_label(names: list) -> bool:
    return any(n.startswith("priority:") for n in names)


def has_risk_label(names: list) -> bool:
    return any(n.startswith("risk:") for n in names)


def label_hygiene(open_items: list, repo: str) -> dict:
    missing = []
    commands = []
    for item in open_items:
        names = labels_of(item)
        if "epic" in names:
            continue
        missing_prio = not has_priority_label(names)
        missing_risk = not has_risk_label(names)
        if not missing_prio and not missing_risk:
            continue
        num = item.get("number")
        entry = {
            "number": num,
            "title": item.get("title", ""),
            "url": item.get("url", ""),
            "missing_priority": missing_prio,
            "missing_risk": missing_risk,
        }
        missing.append(entry)
        cmd_parts = ["gh", "issue", "edit", str(num)]
        if repo:
            cmd_parts.extend(["--repo", repo])
        add = []
        if missing_prio:
            add.append("priority:low")
        if missing_risk:
            add.append("risk:normal")
        cmd_parts.extend(["--add-label", ",".join(add)])
        commands.append(" ".join(cmd_parts))
    return {"issues": missing, "suggested_commands": commands}


def mentioned_script_paths(text: str) -> list:
    if not text:
        return []
    seen = set()
    paths = []
    for match in SCRIPT_PATH_RE.finditer(text):
        path = match.group(1).rstrip(".,;)")
        if path not in seen:
            seen.add(path)
            paths.append(path)
    return paths


def possibly_implemented(open_items: list, repo_dir: Path) -> list:
    hits = []
    for item in open_items:
        text = (item.get("title") or "") + "\n" + (item.get("body") or "")
        for rel in mentioned_script_paths(text):
            on_disk = repo_dir / rel
            if on_disk.is_file():
                hits.append(
                    {
                        "number": item.get("number"),
                        "title": item.get("title", ""),
                        "url": item.get("url", ""),
                        "path": rel,
                    }
                )
    hits.sort(key=lambda h: (h.get("number") or 0, h.get("path") or ""))
    return hits


def is_blocked(item: dict) -> bool:
    dep = item.get("issue_dependencies_summary") or item.get(
        "issueDependenciesSummary"
    )
    if isinstance(dep, dict):
        blocked = dep.get("blocked_by") or dep.get("total_blocked_by") or 0
        try:
            return int(blocked) > 0
        except (TypeError, ValueError):
            return False
    return False


def candidate_issues(open_items: list) -> list:
    candidates = []
    for item in open_items:
        names = labels_of(item)
        status = normalize_status(names)
        if status in ("epic", "owner-action"):
            continue
        if is_blocked(item):
            continue
        if not has_priority_label(names) or not has_risk_label(names):
            continue
        prio = normalize_priority(names)
        risk = normalize_risk(names)
        selected = "factory:selected" in names
        candidates.append(
            {
                "item": item,
                "number": item.get("number"),
                "title": item.get("title", ""),
                "url": item.get("url", ""),
                "priority": prio,
                "risk": risk,
                "selected": selected,
                "risk_rank": RISK_RANK.get(risk, RISK_RANK["unlabeled"]),
                "priority_rank": PRIORITY_ORDER.get(prio, 0),
            }
        )
    candidates.sort(
        key=lambda c: (
            -c["priority_rank"],
            c["risk_rank"],
            0 if c["selected"] else 1,
            c.get("number") or 0,
        )
    )
    return candidates


def recommend(candidates: list) -> dict | None:
    if not candidates:
        return None
    top = candidates[0]
    why_bits = []
    if top["priority"] == "high":
        why_bits.append("labeled priority:high")
    elif top["priority"] == "low":
        why_bits.append("labeled priority:low (no higher-priority ready issues)")
    else:
        why_bits.append("highest-priority ready issue with priority/risk labels")
    why_bits.append(f"risk:{top['risk']} (lower risk preferred)")
    if top["selected"]:
        why_bits.append("carries factory:selected")
    else:
        why_bits.append("not owner-action or epic; not blocked")
    return {
        "number": top["number"],
        "title": top["title"],
        "url": top["url"],
        "priority": top["priority"],
        "risk": top["risk"],
        "recommendation_line": f"Work issue #{top['number']} next ({top['title']}).",
        "why_lines": why_bits,
    }


def epic_rollups(all_items: list) -> list:
    index = build_issues_index(all_items)
    epics = []
    for item in all_items:
        if not isinstance(item, dict) or is_pull_request(item):
            continue
        names = labels_of(item)
        if "epic" not in names:
            continue
        state = (item.get("state") or "open").lower()
        if state != "open":
            continue
        done, total = epic_done_total(item, index, {})
        open_sub = total - done
        epics.append(
            {
                "number": item.get("number"),
                "title": item.get("title", ""),
                "url": item.get("url", ""),
                "done": done,
                "total": total,
                "open_sub_issues": open_sub,
                "closed_sub_issues": done,
            }
        )
    epics.sort(key=lambda e: e.get("number") or 0)
    return epics


def triage(
    all_items: list, repo: str, repo_dir: Path
) -> dict:
    open_items = open_issues(all_items)
    hygiene = label_hygiene(open_items, repo)
    stale = possibly_implemented(open_items, repo_dir)
    candidates = candidate_issues(open_items)
    rec = recommend(candidates)
    epics = epic_rollups(all_items)
    return {
        "open_count": len(open_items),
        "label_hygiene": hygiene,
        "possibly_implemented": stale,
        "candidates": [
            {
                "number": c["number"],
                "title": c["title"],
                "url": c["url"],
                "priority": c["priority"],
                "risk": c["risk"],
                "selected": c["selected"],
            }
            for c in candidates
        ],
        "recommendation": rec,
        "epics": epics,
    }


def render_markdown(report: dict) -> str:
    lines = ["# Factory backlog triage", ""]
    lines.append(f"Open issues: **{report['open_count']}**")
    lines.append("")

    lines.append("## Label hygiene")
    hy = report["label_hygiene"]
    if not hy["issues"]:
        lines.append("All open non-epic issues have `priority:*` and `risk:*` labels.")
    else:
        lines.append(
            f"{len(hy['issues'])} open non-epic issue(s) missing priority and/or risk:"
        )
        for issue in hy["issues"]:
            bits = []
            if issue["missing_priority"]:
                bits.append("priority")
            if issue["missing_risk"]:
                bits.append("risk")
            lines.append(
                f"- #{issue['number']} — {issue['title']} (missing: {', '.join(bits)})"
            )
        if hy["suggested_commands"]:
            lines.append("")
            lines.append("Suggested commands (review labels before running):")
            for cmd in hy["suggested_commands"]:
                lines.append(f"```bash\n{cmd}\n```")

    lines.append("")
    lines.append("## Possibly already implemented")
    stale = report["possibly_implemented"]
    if not stale:
        lines.append("No open issues mention `scripts/…` paths that already exist on disk.")
    else:
        for hit in stale:
            lines.append(
                f"- #{hit['number']} — `{hit['path']}` exists "
                f"({hit['title']})"
            )

    lines.append("")
    lines.append("## Epic rollup")
    if not report["epics"]:
        lines.append("No open epics.")
    else:
        for epic in report["epics"]:
            lines.append(
                f"- Epic #{epic['number']}: {epic['closed_sub_issues']} closed / "
                f"{epic['open_sub_issues']} open sub-issues "
                f"(total {epic['total']}: {epic['done']} done) — {epic['title']}"
            )

    lines.append("")
    lines.append("## Next up")
    rec = report["recommendation"]
    if rec is None:
        lines.append("No ready issue to recommend (label open work or clear blockers).")
    else:
        lines.append(f"**Recommendation:** {rec['recommendation_line']}")
        lines.append("**Why:**")
        for bit in rec["why_lines"]:
            lines.append(f"- {bit}")

    lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--issues-json",
        metavar="PATH",
        help="Offline fixture (array of gh-shaped issue objects).",
    )
    parser.add_argument(
        "--repo",
        metavar="OWNER/REPO",
        help="Live mode: fetch issues with gh issue list. With --issues-json, "
        "sets the slug in suggested gh issue edit commands.",
    )
    parser.add_argument(
        "--repo-dir",
        default=".",
        help="Repo root for on-disk script checks (default: .).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit JSON instead of Markdown.",
    )
    args = parser.parse_args()

    if not args.issues_json and not args.repo:
        parser.error("one of --issues-json or --repo is required")

    repo_slug = args.repo or ""
    if args.issues_json:
        all_items = load_issues_json(Path(args.issues_json))
    else:
        all_items = load_live(args.repo)
        repo_slug = args.repo

    repo_dir = Path(args.repo_dir).resolve()
    report = triage(all_items, repo_slug, repo_dir)

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(render_markdown(report), end="")


if __name__ == "__main__":
    main()