#!/usr/bin/env python3
"""Job A/B helper for /oc fix: guard the PR and build the fix context (read-only token, stdlib only).

Two modes:
  --check-pr   Guard only. Fetch the PR (or read --from-json) and refuse unless it is an open PR
               in this same repository (never a fork) whose head branch is oc/issue-<N>-<run_id>
               and whose base is the default branch. With --expect-head, also refuse if the head
               SHA moved. Prints key=value facts. Publish (job B) runs this from a pristine copy.
  (default)    Guard, then write to --out-dir (default $OC_ARTIFACT_DIR):
                 fix-context.md   PR facts, changed files, owner review/PR comments since the last
                              push (capped, newest kept), then the linked issue context built
                              by scripts/opencode-build-context.py (issue body + approved spec)
                 fix-meta.txt     pr_number, issue_number, head_ref, head_sha, since, spec id and
                              sha256, sizes
                 spec.md          the exact approved spec, when there is one (#75)
               and, in Actions, head_sha / head_ref / issue_number to $GITHUB_OUTPUT.

Only comments by the repository owner login with author_association OWNER count, created after
the head commit's committer date ("since the last bot push"). Comments starting with /oc are
skipped (the /oc fix text reaches the worker as the instruction instead).
Live mode uses `gh api` (GH_TOKEN from the workflow step). --from-json reads a fixture:
{"pr": {...}, "head_commit_date": "...", "files": [...], "pr_comments": [...],
 "review_comments": [...], "reviews": [...], "issue": {...}, "issue_comments": [...]}
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
BRANCH_RE = re.compile(r"^oc/issue-([1-9][0-9]{0,8})-([0-9]{1,20})$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
END = "=== END PR CONTEXT ==="
ISSUE_END = "=== END ISSUE CONTEXT ==="


def die(msg: str) -> None:
    print(f"build-fix-context: FAIL — {msg}", file=sys.stderr)
    sys.exit(1)


def gh(*args: str) -> str:
    return subprocess.run(["gh", "api", *args], check=True, capture_output=True, text=True).stdout


def gh_list(path: str) -> list:
    out = gh("--paginate", "--jq", ".[]", path)
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def when(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def guard(pr: dict, repo: str, expect_head: str | None) -> dict:
    """Refuse anything but an open same-repo oc/issue-<N>-<run_id> PR into the default branch."""
    if not isinstance(pr, dict) or not pr.get("number"):
        die("no pull request data")
    head, base = pr.get("head") or {}, pr.get("base") or {}
    head_repo, base_repo = head.get("repo") or {}, base.get("repo") or {}
    if pr.get("state") != "open":
        die(f"PR #{pr['number']} is not open")
    if not head_repo or head_repo.get("fork") or head_repo.get("full_name") != repo \
            or base_repo.get("full_name") != repo:
        die("PR head is not a branch of this repository (forks are refused)")
    ref = head.get("ref") or ""
    m = BRANCH_RE.match(ref)
    if not m:
        die(f"head branch {ref!r} does not match oc/issue-<N>-<run_id>")
    default = base_repo.get("default_branch") or "main"
    if base.get("ref") != default:
        die(f"PR base {base.get('ref')!r} is not the default branch {default!r}")
    sha = head.get("sha") or ""
    if not SHA_RE.match(sha):
        die("PR head SHA is missing or malformed")
    if expect_head is not None:
        if not SHA_RE.match(expect_head):
            die("expected head SHA is malformed")
        if sha != expect_head:
            die(f"PR head moved since job A (expected {expect_head[:12]}, now {sha[:12]}); refusing")
    return {"pr_number": str(pr["number"]), "issue_number": m.group(1), "head_ref": ref,
            "head_sha": sha, "base_ref": default}


def clean(s: str | None) -> str:
    return ((s or "").replace("\r\n", "\n").replace(END, "[removed delimiter]")
            .replace(ISSUE_END, "[removed delimiter]").strip())


def clip(s: str, limit: int) -> str:
    b = s.encode("utf-8")
    if len(b) <= limit:
        return s
    keep = max(limit - 60, 0)
    return b[:keep].decode("utf-8", "ignore") + f"\n[truncated {len(b) - keep} bytes]"


def owner_items(data: dict, owner: str, since: datetime | None) -> list[tuple[datetime, str, str]]:
    """(time, label, body) for owner comments/reviews after `since`, oldest first."""
    def counts(c: dict, stamp: str | None) -> bool:
        user = (c.get("user") or {}).get("login")
        body = (c.get("body") or "").strip()
        t = when(stamp)
        return (user == owner and c.get("author_association") == "OWNER" and body
                and not body.startswith("/oc") and t is not None and (since is None or t > since))

    items = []
    for r in data.get("reviews") or []:
        if counts(r, r.get("submitted_at")):
            items.append((when(r["submitted_at"]), f"review {r.get('id')} ({r.get('state', '')}, {r['submitted_at']})", r["body"]))
    for c in data.get("review_comments") or []:
        if counts(c, c.get("created_at")):
            loc = f"{c.get('path', '?')}:{c.get('line') or c.get('original_line') or '?'}"
            items.append((when(c["created_at"]), f"inline comment {c.get('id')} on {loc} ({c['created_at']})", c["body"]))
    for c in data.get("pr_comments") or []:
        if counts(c, c.get("created_at")):
            items.append((when(c["created_at"]), f"PR comment {c.get('id')} ({c['created_at']})", c["body"]))
    items.sort(key=lambda x: x[0])
    return items


def issue_context(args: argparse.Namespace, data: dict, issue: str, tmp: Path) -> tuple[str, str, bytes | None]:
    """Reuse opencode-build-context.py for the linked issue (body + approved spec)."""
    out = tmp / "issue"
    cmd = [sys.executable, str(HERE / "opencode-build-context.py"), "--out-dir", str(out),
           "--max-bytes", str(args.issue_bytes)]
    if args.from_json:
        fx = tmp / "issue-fixture.json"
        fx.write_text(json.dumps({"issue": data["issue"], "comments": data.get("issue_comments") or []}),
                      encoding="utf-8")
        cmd += ["--from-json", str(fx)]
    else:
        cmd += ["--repo", args.repo, "--issue", issue]
    env = {k: v for k, v in os.environ.items() if k != "GITHUB_STEP_SUMMARY"}
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        die("linked issue context failed (see build-context output above)")
    meta = (out / "context-meta.txt").read_text(encoding="utf-8")
    m = re.search(r"^spec_comment_id=(\S+)$", meta, re.M)
    spec = out / "spec.md"
    return ((out / "issue-context.md").read_text(encoding="utf-8"), (m.group(1) if m else "none"),
            spec.read_bytes() if spec.is_file() else None)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    ap.add_argument("--pr", default=os.environ.get("OC_PR_NUMBER"))
    ap.add_argument("--out-dir", default=os.environ.get("OC_ARTIFACT_DIR"))
    ap.add_argument("--from-json", help="fixture file (see module docstring)")
    ap.add_argument("--check-pr", action="store_true", help="guard only; print facts")
    ap.add_argument("--expect-head", help="refuse if the PR head SHA is not this")
    ap.add_argument("--max-bytes", type=int, default=30000, help="cap for the PR section")
    ap.add_argument("--issue-bytes", type=int, default=40000, help="cap for the issue section")
    ap.add_argument("--max-comments", type=int, default=12)
    ap.add_argument("--comment-bytes", type=int, default=4000)
    ap.add_argument("--max-files", type=int, default=100)
    args = ap.parse_args()
    if not args.repo or not re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", args.repo):
        die("need --repo owner/name")
    if not args.from_json and not (args.pr and str(args.pr).isdigit()):
        die("need --pr <digits> or --from-json")
    owner = args.repo.split("/")[0]

    if args.from_json:
        data = json.loads(Path(args.from_json).read_text(encoding="utf-8"))
    else:
        data = {"pr": json.loads(gh(f"repos/{args.repo}/pulls/{args.pr}"))}
    if args.pr and str((data.get("pr") or {}).get("number")) != str(args.pr):
        die("fetched PR number does not match --pr")
    facts = guard(data.get("pr") or {}, args.repo, args.expect_head)
    if args.check_pr:
        for k, v in facts.items():
            print(f"{k}={v}")
        return 0
    if not args.out_dir:
        die("need --out-dir")

    n, sha = facts["pr_number"], facts["head_sha"]
    if not args.from_json:
        data["head_commit_date"] = gh("--jq", ".commit.committer.date", f"repos/{args.repo}/commits/{sha}").strip()
        data["files"] = gh_list(f"repos/{args.repo}/pulls/{n}/files?per_page=100")
        data["reviews"] = gh_list(f"repos/{args.repo}/pulls/{n}/reviews?per_page=100")
        data["review_comments"] = gh_list(f"repos/{args.repo}/pulls/{n}/comments?per_page=100")
        data["pr_comments"] = gh_list(f"repos/{args.repo}/issues/{n}/comments?per_page=100")
    since = when(data.get("head_commit_date"))
    if since is None:
        die("cannot read the head commit date (needed for 'since the last push')")

    pr = data["pr"]
    head = (f"## Pull request #{n}: {clean(pr.get('title'))}\n\n"
            f"Branch {facts['head_ref']} at {sha} (base {facts['base_ref']}); "
            f"linked issue #{facts['issue_number']}. Your working tree is this PR head.\n")
    files = data.get("files") or []
    lines = [f"- {clean(f.get('filename'))} ({f.get('status', '?')}, +{f.get('additions', 0)}/-{f.get('deletions', 0)})"
             for f in files[:args.max_files]]
    more = f"\n- ... {len(files) - args.max_files} more file(s) not shown" if len(files) > args.max_files else ""
    files_block = f"\n### Files changed in this PR ({len(files)})\n\n" + "\n".join(lines) + more + "\n"
    budget = args.max_bytes - len(head.encode()) - 300
    files_block = clip(files_block, max(budget // 3, 500))
    budget -= len(files_block.encode())

    items = owner_items(data, owner, since)[-args.max_comments:]
    shown: list[str] = []
    for _, label, body in reversed(items):  # newest first, so the cap drops the oldest
        item = f"\n- {label}:\n\n{clip(clean(body), args.comment_bytes)}\n"
        if len(item.encode()) > budget:
            break
        shown.insert(0, item)
        budget -= len(item.encode())
    review_block = (f"\n### Owner review comments since the last push ({data['head_commit_date']}): {len(shown)}\n"
                    + ("".join(shown) if shown else "\nNone; work from the /oc fix instruction.\n"))

    with tempfile.TemporaryDirectory() as td:
        issue_ctx, spec_id, spec_bytes = issue_context(args, data, facts["issue_number"], Path(td))

    ctx = f"{head}{files_block}{review_block}\n{END}\n\n{issue_ctx}"
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "fix-context.md").write_text(ctx, encoding="utf-8")
    spec_sha = "none"
    if spec_bytes is not None:  # exact approved spec; agent-fix restores factory/specs/issue-<N>.md from it
        (out / "spec.md").write_bytes(spec_bytes)
        spec_sha = hashlib.sha256(spec_bytes).hexdigest()
    meta = {**facts, "since": data["head_commit_date"], "owner_comments": str(len(shown)),
            "spec_comment_id": spec_id, "spec_sha256": spec_sha, "context_bytes": str(len(ctx.encode()))}
    (out / "fix-meta.txt").write_text("".join(f"{k}={v}\n" for k, v in meta.items()), encoding="utf-8")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as fh:
            for k in ("head_sha", "head_ref", "issue_number"):
                fh.write(f"{k}={facts[k]}\n")
    print(f"build-fix-context: PR #{n} {facts['head_ref']} @ {sha[:12]}; {len(shown)} owner comment(s) "
          f"since {data['head_commit_date']}; spec {spec_id}; {len(ctx.encode())} bytes")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as fh:
            fh.write(f"- Fix context: PR #{n}, {len(shown)} owner comment(s), spec {spec_id}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
