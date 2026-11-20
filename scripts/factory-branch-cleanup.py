#!/usr/bin/env python3
"""Dry-run branch hygiene report for factory worker branches (oc/, cursor/).

Never deletes branches. Default output is Markdown with copy-paste delete commands.
Offline mode: --branches-json and --prs-json. Live mode: gh api / gh pr list (--repo).
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from fnmatch import fnmatch


def parse_iso8601(value: str | None) -> datetime | None:
    if not value:
        return None
    s = value.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def load_branches_fixture(path: str) -> tuple[str, list[dict]]:
    data = json.loads(open(path, encoding="utf-8").read())
    default = data.get("default_branch") or data.get("defaultBranch") or "main"
    branches = data.get("branches") or data
    if isinstance(branches, dict):
        branches = branches.get("branches", [])
    normalized = []
    for b in branches:
        name = b.get("name")
        if not name:
            continue
        committed = (
            b.get("committed_date")
            or b.get("committedDate")
            or (b.get("commit") or {}).get("committedDate")
            or (b.get("commit") or {}).get("committed_date")
        )
        normalized.append({"name": name, "committed_date": committed})
    return default, normalized


def load_prs_fixture(path: str) -> list[dict]:
    data = json.loads(open(path, encoding="utf-8").read())
    prs = data.get("pull_requests") or data.get("pullRequests") or data
    if isinstance(prs, dict):
        prs = prs.get("pull_requests", [])
    return list(prs)


def gh_json(cmd: list[str]) -> object:
    if not shutil.which("gh"):
        raise SystemExit("gh not found; use --branches-json and --prs-json for offline mode")
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise SystemExit(proc.stderr.strip() or f"gh failed: {' '.join(cmd)}")
    return json.loads(proc.stdout)


def gh_api_json_paginated(endpoint: str) -> list[dict]:
    proc = subprocess.run(
        ["gh", "api", "--paginate", endpoint],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise SystemExit(proc.stderr.strip() or f"gh api paginate failed: {endpoint}")
    raw = (proc.stdout or "").strip()
    if not raw:
        return []
    try:
        data = json.loads(raw)
        if isinstance(data, list):
            return data
    except ValueError:
        pass
    chunks: list[dict] = []
    decoder = json.JSONDecoder()
    idx = 0
    while idx < len(raw):
        while idx < len(raw) and raw[idx] in " \t\n\r":
            idx += 1
        if idx >= len(raw):
            break
        chunk, end = decoder.raw_decode(raw, idx)
        if isinstance(chunk, list):
            chunks.extend(chunk)
        idx = end
    return chunks


def load_live(repo: str) -> tuple[str, list[dict], list[dict]]:
    repo_meta = gh_json(["gh", "api", f"repos/{repo}"])
    default = "main"
    if isinstance(repo_meta, dict):
        default = repo_meta.get("default_branch") or default

    branch_rows = gh_api_json_paginated(f"repos/{repo}/branches?per_page=100")
    branches = []
    for row in branch_rows:
        name = row.get("name")
        if not name:
            continue
        committed = (row.get("commit") or {}).get("committed", {}).get("date")
        if not committed:
            sha = (row.get("commit") or {}).get("sha")
            if sha:
                commit = gh_json(["gh", "api", f"repos/{repo}/commits/{sha}"])
                if isinstance(commit, dict):
                    commit_obj = commit.get("commit") or {}
                    committed = (commit_obj.get("committer") or {}).get("date") or (
                        commit_obj.get("author") or {}
                    ).get("date")
        branches.append({"name": name, "committed_date": committed})

    prs = gh_json(
        [
            "gh",
            "pr",
            "list",
            "--repo",
            repo,
            "--state",
            "all",
            "--limit",
            "500",
            "--json",
            "number,state,headRefName,mergedAt,closedAt,updatedAt",
        ]
    )
    if not isinstance(prs, list):
        prs = []
    return default, branches, prs


PROTECTED_EXACT = frozenset({"main", "master"})


def is_release_or_tag_branch(name: str) -> bool:
    if fnmatch(name, "release/*"):
        return True
    if re.match(r"^v\d", name):
        return True
    return False


def matches_factory_prefix(name: str, prefixes: list[str]) -> bool:
    for p in prefixes:
        if name.startswith(p):
            return True
    return False


def index_prs_by_head(prs: list[dict]) -> dict[str, list[dict]]:
    by_head: dict[str, list[dict]] = {}
    for pr in prs:
        head = pr.get("headRefName") or pr.get("head_ref") or pr.get("head")
        if not head:
            continue
        by_head.setdefault(head, []).append(pr)
    return by_head


def pr_state(pr: dict) -> str:
    return (pr.get("state") or "").upper()


def classify_branch(
    branch: dict,
    *,
    default_branch: str,
    prefixes: list[str],
    older_than_days: int,
    prs_for_head: list[dict],
    now: datetime,
) -> tuple[str, str]:
    name = branch["name"]
    committed_dt = parse_iso8601(branch.get("committed_date"))

    if name in PROTECTED_EXACT or name == default_branch:
        return "keep", "protected default branch"
    if is_release_or_tag_branch(name):
        return "keep", "release or version branch"

    if not matches_factory_prefix(name, prefixes):
        return "keep", "non-factory branch prefix"

    open_prs = [p for p in prs_for_head if pr_state(p) == "OPEN"]
    if open_prs:
        return "keep", "open pull request"

    merged_prs = [p for p in prs_for_head if pr_state(p) == "MERGED" or p.get("mergedAt")]
    if merged_prs:
        return "merged_pr", "pull request merged"

    cutoff = now - timedelta(days=older_than_days)
    is_old = committed_dt is not None and committed_dt < cutoff
    if committed_dt is None:
        is_old = False

    closed_unmerged = [
        p
        for p in prs_for_head
        if pr_state(p) == "CLOSED" and not p.get("mergedAt")
    ]
    if closed_unmerged:
        if is_old:
            return "closed_unmerged_old", "closed PR without merge; last commit stale"
        return "keep", "closed PR without merge; last commit still recent"

    if not prs_for_head:
        if is_old:
            return "orphan_old", "factory branch with no PR; last commit stale"
        return "keep", "factory branch with no PR; last commit still recent"

    return "keep", "unclassified; kept by default"


def delete_command(repo: str | None, branch: str) -> str:
    if repo:
        return (
            f"gh api -X DELETE repos/{repo}/git/refs/heads/{branch}"
        )
    return f"git push origin --delete {branch}"


def build_report(
    default_branch: str,
    branches: list[dict],
    prs: list[dict],
    *,
    prefixes: list[str],
    older_than_days: int,
    repo: str | None,
    now: datetime,
) -> dict:
    by_head = index_prs_by_head(prs)
    candidates: list[dict] = []
    kept: list[dict] = []

    for branch in sorted(branches, key=lambda b: b["name"]):
        prs_for = by_head.get(branch["name"], [])
        category, reason = classify_branch(
            branch,
            default_branch=default_branch,
            prefixes=prefixes,
            older_than_days=older_than_days,
            prs_for_head=prs_for,
            now=now,
        )
        row = {
            "branch": branch["name"],
            "category": category,
            "reason": reason,
            "committed_date": branch.get("committed_date"),
            "pull_requests": [
                {
                    "number": p.get("number"),
                    "state": pr_state(p),
                    "mergedAt": p.get("mergedAt"),
                    "closedAt": p.get("closedAt"),
                }
                for p in prs_for
            ],
        }
        if category in ("merged_pr", "closed_unmerged_old", "orphan_old"):
            row["delete_command"] = delete_command(repo, branch["name"])
            candidates.append(row)
        else:
            kept.append(row)

    summary = {
        "merged_pr": sum(1 for c in candidates if c["category"] == "merged_pr"),
        "closed_unmerged_old": sum(
            1 for c in candidates if c["category"] == "closed_unmerged_old"
        ),
        "orphan_old": sum(1 for c in candidates if c["category"] == "orphan_old"),
        "keep": len(kept),
        "total_branches": len(branches),
        "older_than_days": older_than_days,
        "prefixes": prefixes,
        "default_branch": default_branch,
        "repo": repo,
        "dry_run": True,
    }
    return {"summary": summary, "candidates": candidates, "kept": kept}


def format_markdown(report: dict) -> str:
    s = report["summary"]
    lines = [
        "# Factory branch cleanup (dry run)",
        "",
        "No branches were deleted. Review candidates below before running delete commands.",
        "",
        "## Summary",
        "",
        f"- **merged_pr**: {s['merged_pr']}",
        f"- **closed_unmerged_old**: {s['closed_unmerged_old']}",
        f"- **orphan_old**: {s['orphan_old']}",
        f"- **keep**: {s['keep']}",
        f"- **total_branches**: {s['total_branches']}",
        f"- **older_than_days**: {s['older_than_days']}",
        f"- **prefixes**: {', '.join(s['prefixes'])}",
        "",
    ]
    if not report["candidates"]:
        lines.append("_No stale factory branches to delete._")
        lines.append("")
        return "\n".join(lines)

    by_cat: dict[str, list[dict]] = {}
    for c in report["candidates"]:
        by_cat.setdefault(c["category"], []).append(c)

    for cat in ("merged_pr", "closed_unmerged_old", "orphan_old"):
        items = by_cat.get(cat, [])
        if not items:
            continue
        lines.append(f"## {cat} ({len(items)})")
        lines.append("")
        for c in items:
            lines.append(f"- `{c['branch']}` — {c['reason']}")
            lines.append(f"  ```bash")
            lines.append(f"  {c['delete_command']}")
            lines.append(f"  ```")
        lines.append("")

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--branches-json", help="Fixture path for branches (offline)")
    parser.add_argument("--prs-json", help="Fixture path for pull requests (offline)")
    parser.add_argument("--repo", help="owner/repo for live gh mode and gh delete hints")
    parser.add_argument(
        "--prefixes",
        default="oc/,cursor/",
        help="Comma-separated branch prefixes to treat as factory branches",
    )
    parser.add_argument(
        "--older-than-days",
        type=int,
        default=7,
        help="Age threshold for stale orphan/closed-unmerged branches",
    )
    parser.add_argument("--json", action="store_true", dest="json_out", help="JSON output")
    parser.add_argument(
        "--now",
        help="ISO timestamp for age tests (default: current UTC)",
    )
    args = parser.parse_args()

    prefixes = [p.strip() for p in args.prefixes.split(",") if p.strip()]
    now = parse_iso8601(args.now) or datetime.now(timezone.utc)

    offline = bool(args.branches_json or args.prs_json)
    if offline and not (args.branches_json and args.prs_json):
        parser.error("offline mode requires both --branches-json and --prs-json")
    if not offline and not args.repo:
        parser.error("live mode requires --repo owner/repo (or use offline JSON fixtures)")

    if offline:
        default_branch, branches = load_branches_fixture(args.branches_json)
        prs = load_prs_fixture(args.prs_json)
    else:
        default_branch, branches, prs = load_live(args.repo)

    report = build_report(
        default_branch,
        branches,
        prs,
        prefixes=prefixes,
        older_than_days=args.older_than_days,
        repo=args.repo,
        now=now,
    )

    if args.json_out:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        sys.stdout.write(format_markdown(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())