#!/usr/bin/env python3
"""Approve an /oc spec draft (#78): post the approved copy as an owner comment.

Run by Grok Bot (or Michael) from the owner's gh login, never by a workflow:

  factory-approve-spec.py <issue> <draft comment URL or id> --approved-by WHO [--from-file F] [--dry-run]

Approval keeps the existing convention: /oc uses the latest OWNER comment with the spec marker and
`status: approved`. The draft (posted by github-actions, `status: draft`) never counts. This script
takes the draft's spec (or an edited copy with --from-file), sets status approved, approved_by
and approved_at, re-runs the spec checks and the cost prediction, and posts it as a new comment.
WHO is `grok-bot` (trivial or normal risk: Grok Bot reviews and approves) or `michael` (required
for high risk), per factory/specs/README.md (Michael's decision, 2026-11-02). Use `michael` only
after Michael has approved that spec.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DRAFT_TAG = "<!-- factory-spec-draft v1 -->"
BOT_LOGINS = {"github-actions", "github-actions[bot]", "app/github-actions"}


def die(msg: str) -> None:
    print(f"approve-spec: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("issue")
    ap.add_argument("comment", help="draft comment URL (...#issuecomment-<id>) or numeric id")
    ap.add_argument("--approved-by", required=True)
    ap.add_argument("--from-file", help="edited spec to approve instead of the draft text")
    ap.add_argument("--repo", default="")
    ap.add_argument("--dry-run", action="store_true", help="print the approved comment; post nothing")
    a = ap.parse_args()
    if not a.issue.isdigit():
        die("issue must be digits")
    m = re.search(r"(?:issuecomment-)?(\d+)$", a.comment.strip())
    if not m:
        die("comment must be a URL ending in #issuecomment-<id> or a numeric id")
    cid = m.group(1)
    repo = ["--repo", a.repo] if a.repo else []
    raw = subprocess.run(["gh", "issue", "view", a.issue, *repo, "--json", "comments"],
                         capture_output=True, text=True)
    if raw.returncode != 0:
        die(f"gh issue view failed: {raw.stderr.strip()[:200]}")
    found = [c for c in json.loads(raw.stdout).get("comments", [])
             if str(c.get("url", "")).endswith(f"#issuecomment-{cid}")]
    if not found:
        die(f"comment {cid} is not on issue #{a.issue}")
    c = found[0]
    body = (c.get("body") or "").replace("\r\n", "\n")
    if (c.get("author") or {}).get("login") not in BOT_LOGINS or body.split("\n", 1)[0] != DRAFT_TAG:
        die(f"comment {cid} is not an /oc spec draft posted by the workflow")
    text = Path(a.from_file).read_text(encoding="utf-8") if a.from_file else body
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as f:
        f.write(text)
        src = f.name
    r = subprocess.run([sys.executable, str(HERE / "opencode-spec-draft.py"), "approve", src,
                        "--approved-by", a.approved_by, "--issue", a.issue], capture_output=True, text=True)
    Path(src).unlink(missing_ok=True)
    if r.returncode != 0:
        die((r.stderr or "approve failed").strip())
    approved = r.stdout
    if a.dry_run:
        sys.stdout.write(approved)
        return 0
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as f:
        f.write(approved)
        out = f.name
    try:
        p = subprocess.run(["gh", "issue", "comment", a.issue, *repo, "--body-file", out], capture_output=True, text=True)
    finally:
        Path(out).unlink(missing_ok=True)
    if p.returncode != 0:
        die(f"gh issue comment failed: {p.stderr.strip()[:200]}")
    print(f"approve-spec: posted the approved spec: {p.stdout.strip()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
