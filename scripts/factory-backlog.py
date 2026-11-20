#!/usr/bin/env python3
"""Produce the normalized open-backlog JSON for the factory site's Backlog tab.

Usage:
    scripts/factory-backlog.py --out FILE [--from-json FILE]

Live mode (no --from-json) runs `gh issue list` to read the repo's open issues and
is only ever invoked by the deploy job (which sets GITHUB_TOKEN/GH_TOKEN). It is
never called by /oc agents or the verification harness, which run in an empty
environment with no token. --from-json reads a committed fixture for tests and
offline builds, with no gh call and no network.

Output is a JSON array of normalized issue dicts, one per open issue (pull
requests excluded), each carrying: number, title, url, createdAt, updatedAt,
priority (high/low/none), risk (the risk:* label or "unlabeled"), status
(epic > owner-action > factory:selected > open), and for epic issues done/total
from subIssuesSummary when present. Titles are always included (no --titles
switch). Output is deterministic.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Fields gh must return so live mode can compute epic progress.
GH_JSON_FIELDS = (
    "number,title,body,labels,createdAt,updatedAt,url,subIssuesSummary"
)

PRIORITY_ORDER = {"high": 2, "low": 1, "none": 0}

# Issue numbers referenced in text (#123). Task-list lines are included.
_BODY_REF_RE = re.compile(r"(?:^|[\s(\[]|/issues/)#(\d+)\b", re.MULTILINE)


def is_pull_request(item):
    return "is_pull_request" in item or "pull_request" in item


def labels_of(item):
    labels = item.get("labels") or []
    names = []
    for label in labels:
        if isinstance(label, str):
            names.append(label)
        elif isinstance(label, dict):
            name = label.get("name")
            if name:
                names.append(name)
    return names


def normalize_priority(names):
    priority = "none"
    for name in names:
        if name.startswith("priority:"):
            value = name.split(":", 1)[1].strip().lower()
            if value in ("high", "low") and PRIORITY_ORDER[value] > PRIORITY_ORDER[priority]:
                priority = value
    return priority


def normalize_risk(names):
    for name in names:
        if name.startswith("risk:"):
            value = name.split(":", 1)[1].strip().lower()
            if value:
                return value
    return "unlabeled"


def normalize_status(names):
    for status in ("epic", "owner-action", "factory:selected"):
        if status in names:
            return status
    return "open"


def epic_summary(item):
    summary = item.get("subIssuesSummary")
    if summary is None:
        summary = item.get("sub_issues_summary")
    return summary if isinstance(summary, dict) else None


def progress_from_summary(summary):
    """Return (done, total) from subIssuesSummary-shaped dict, or None if absent."""
    if not summary:
        return None
    total = summary.get("total")
    done = summary.get("done")
    if done is None:
        done = summary.get("completed")
    if total is None and done is None:
        return None
    return int(done or 0), int(total or 0)


def summary_needs_fallback(summary, progress):
    """True when GitHub summary is missing or looks like an empty placeholder."""
    if progress is None:
        return True
    _done, total = progress
    if total == 0:
        summary_total = (summary or {}).get("total")
        summary_done = (summary or {}).get("done")
        if summary_done is None and summary:
            summary_done = summary.get("completed")
        if summary_total == 0 or (
            summary_total is None and (summary_done == 0 or summary_done is None)
        ):
            return True
    return False


def parse_body_issue_refs(body):
    """Unique issue numbers from #N references in epic body text, in first-seen order."""
    if not body:
        return []
    seen = set()
    refs = []
    for match in _BODY_REF_RE.finditer(body):
        num = int(match.group(1))
        if num not in seen:
            seen.add(num)
            refs.append(num)
    return refs


def progress_from_sub_issues(sub_issues):
    if not sub_issues:
        return None
    total = 0
    done = 0
    for sub in sub_issues:
        if not isinstance(sub, dict):
            continue
        if is_pull_request(sub):
            continue
        total += 1
        state = (sub.get("state") or "").lower()
        if state == "closed":
            done += 1
    if total == 0:
        return None
    return done, total


def build_issues_index(items):
    index = {}
    for item in items:
        if not isinstance(item, dict):
            continue
        num = item.get("number")
        if num is not None:
            index[int(num)] = item
    return index


def progress_from_body_refs(refs, issues_index, epic_number):
    if not refs:
        return None
    total = 0
    done = 0
    for num in refs:
        if num == epic_number:
            continue
        sub = issues_index.get(num)
        if sub is None or is_pull_request(sub):
            continue
        total += 1
        state = (sub.get("state") or "open").lower()
        if state == "closed":
            done += 1
    if total == 0:
        return None
    return done, total


def epic_done_total(item, issues_index, sub_issues_by_epic):
    """Resolve done/total for one epic-shaped raw issue item."""
    summary = epic_summary(item)
    progress = progress_from_summary(summary)
    epic_number = int(item.get("number") or 0)

    if progress is not None and not summary_needs_fallback(summary, progress):
        return progress

    embedded = item.get("sub_issues")
    if isinstance(embedded, list):
        from_embedded = progress_from_sub_issues(embedded)
        if from_embedded is not None:
            return from_embedded

    fetched = sub_issues_by_epic.get(epic_number)
    if fetched is not None:
        from_api = progress_from_sub_issues(fetched)
        if from_api is not None:
            return from_api

    refs = parse_body_issue_refs(item.get("body") or "")
    from_body = progress_from_body_refs(refs, issues_index, epic_number)
    if from_body is not None:
        return from_body

    if progress is not None:
        return progress
    return 0, 0


def normalize_item(item, issues_index, sub_issues_by_epic):
    names = labels_of(item)
    out = {
        "number": item.get("number"),
        "title": item.get("title", ""),
        "url": item.get("url", ""),
        "createdAt": item.get("createdAt", ""),
        "updatedAt": item.get("updatedAt", ""),
        "priority": normalize_priority(names),
        "risk": normalize_risk(names),
        "status": normalize_status(names),
    }
    if "epic" in names:
        done, total = epic_done_total(item, issues_index, sub_issues_by_epic)
        out["done"] = done
        out["total"] = total
    return out


def normalize_items(items, sub_issues_by_epic=None):
    sub_issues_by_epic = sub_issues_by_epic or {}
    issues_index = build_issues_index(items)
    out = []
    for item in items:
        if not isinstance(item, dict):
            continue
        if is_pull_request(item):
            continue
        out.append(normalize_item(item, issues_index, sub_issues_by_epic))
    out.sort(
        key=lambda i: (
            -PRIORITY_ORDER[i["priority"]],
            i.get("updatedAt") or "",
            i.get("number") or 0,
        )
    )
    return out


def load_fixture(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def repo_slug():
    env_repo = os.environ.get("GITHUB_REPOSITORY", "").strip()
    if env_repo and "/" in env_repo:
        return env_repo
    if shutil.which("gh") is None:
        return ""
    try:
        proc = subprocess.run(
            ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return ""
    if proc.returncode != 0:
        return ""
    return (proc.stdout or "").strip()


def gh_api_json_paginated(endpoint):
    if shutil.which("gh") is None:
        return None
    try:
        proc = subprocess.run(
            ["gh", "api", "--paginate", endpoint],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    # stdout may be concatenated JSON arrays
    raw = (proc.stdout or "").strip()
    if not raw:
        return []
    try:
        data = json.loads(raw)
        if isinstance(data, list):
            return data
    except ValueError:
        pass
    chunks = []
    decoder = json.JSONDecoder()
    idx = 0
    while idx < len(raw):
        while idx < len(raw) and raw[idx] in " \t\n\r":
            idx += 1
        if idx >= len(raw):
            break
        try:
            chunk, end = decoder.raw_decode(raw, idx)
        except ValueError:
            return None
        if isinstance(chunk, list):
            chunks.extend(chunk)
        idx = end
    return chunks


def fetch_sub_issues_for_epic(repo, number):
    endpoint = f"repos/{repo}/issues/{number}/sub_issues?per_page=100"
    return gh_api_json_paginated(endpoint)


def collect_live_sub_issues(items, repo):
    """Fetch sub-issues from the API for epics whose summary is empty."""
    if not repo:
        return {}
    by_epic = {}
    for item in items:
        if not isinstance(item, dict) or is_pull_request(item):
            continue
        if "epic" not in labels_of(item):
            continue
        num = item.get("number")
        if num is None:
            continue
        summary = epic_summary(item)
        progress = progress_from_summary(summary)
        if not summary_needs_fallback(summary, progress):
            continue
        subs = fetch_sub_issues_for_epic(repo, num)
        if subs is not None:
            by_epic[int(num)] = subs
    return by_epic


def load_live():
    if shutil.which("gh") is None:
        sys.stderr.write(
            "ERROR: `gh` is not installed. Live backlog builds need the GitHub CLI.\n"
        )
        sys.exit(1)
    try:
        proc = subprocess.run(
            [
                "gh", "issue", "list",
                "--state", "open",
                "--limit", "500",
                "--json", GH_JSON_FIELDS,
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
            "ERROR: `gh issue list` failed (is it authenticated?):\n"
            + proc.stderr
        )
        sys.exit(1)
    try:
        items = json.loads(proc.stdout)
    except ValueError as exc:
        sys.stderr.write(f"ERROR: `gh issue list` returned invalid JSON: {exc}\n")
        sys.exit(1)
    repo = repo_slug()
    sub_issues_by_epic = collect_live_sub_issues(items, repo)
    return items, sub_issues_by_epic


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, help="Output JSON file.")
    parser.add_argument(
        "--from-json",
        default=None,
        help="Read a fixture instead of calling gh (offline, for tests).",
    )
    args = parser.parse_args()

    sub_issues_by_epic = {}
    if args.from_json:
        items = load_fixture(args.from_json)
    else:
        items, sub_issues_by_epic = load_live()

    normalized = normalize_items(items, sub_issues_by_epic)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(normalized, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print(f"Wrote {len(normalized)} open issues to {out}")


if __name__ == "__main__":
    main()