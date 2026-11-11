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
import shutil
import subprocess
import sys
from pathlib import Path

# Fields gh must return so live mode can compute epic progress.
GH_JSON_FIELDS = "number,title,labels,createdAt,updatedAt,url,subIssuesSummary"

PRIORITY_ORDER = {"high": 2, "low": 1, "none": 0}


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


def normalize_item(item):
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
        summary = item.get("subIssuesSummary")
        if summary is None:
            summary = item.get("sub_issues_summary")
        if isinstance(summary, dict):
            if "done" in summary:
                out["done"] = summary["done"]
            if "total" in summary:
                out["total"] = summary["total"]
    return out


def normalize_items(items):
    out = []
    for item in items:
        if not isinstance(item, dict):
            continue
        if is_pull_request(item):
            continue
        out.append(normalize_item(item))
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
        return json.loads(proc.stdout)
    except ValueError as exc:
        sys.stderr.write(f"ERROR: `gh issue list` returned invalid JSON: {exc}\n")
        sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, help="Output JSON file.")
    parser.add_argument(
        "--from-json",
        default=None,
        help="Read a fixture instead of calling gh (offline, for tests).",
    )
    args = parser.parse_args()

    if args.from_json:
        items = load_fixture(args.from_json)
    else:
        items = load_live()

    normalized = normalize_items(items)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(normalized, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print(f"Wrote {len(normalized)} open issues to {out}")


if __name__ == "__main__":
    main()
