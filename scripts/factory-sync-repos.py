#!/usr/bin/env python3
"""Open or update a sync PR in each product repo to bump reusable-workflow pin tags.

Reads a newline-separated repo list (owner/name), updates pins in .github/workflows/
that call Data-Science-Link/software_factory_template reusable workflows, and pushes a branch.

Example:
  python3 scripts/factory-sync-repos.py --repos-file factory/adopters.txt --tag v0.2.0 --dry-run
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

TEMPLATE = "Data-Science-Link/software_factory_template"
USES_RE = re.compile(
    rf"(uses:\s+{re.escape(TEMPLATE)}/\.github/workflows/reusable-[-\w]+\.yml)@v\d+\.\d+\.\d+",
    re.MULTILINE,
)
REF_RE = re.compile(
    r"^(\s*factory_ref:\s*)v\d+\.\d+\.\d+(?=\s*$)", re.MULTILINE
)
SEMVER_RE = re.compile(r"^v?\d+\.\d+\.\d+$")
BRANCH_PREFIX = "factory-sync-"


def normalize_tag(tag: str) -> str:
    """Return a ``vMAJOR.MINOR.PATCH`` tag or raise ValueError."""
    t = tag.strip()
    if not SEMVER_RE.fullmatch(t):
        raise ValueError(
            f"invalid semver tag {tag!r} (expected vMAJOR.MINOR.PATCH, e.g. v0.2.0)"
        )
    return t if t.startswith("v") else f"v{t}"


def run(cmd: list[str], *, check: bool = True, **env) -> subprocess.CompletedProcess[str]:
    merged = {**os.environ, **env}
    return subprocess.run(cmd, check=check, text=True, capture_output=True, env=merged)


def load_workflow_paths(repo: str) -> list[str]:
    r = run(["gh", "api", f"repos/{repo}/contents/.github/workflows"], check=True)
    items = json.loads(r.stdout)
    if isinstance(items, dict):
        items = [items]
    return [it["path"] for it in items if str(it.get("path", "")).endswith(".yml")]


def fetch_file(repo: str, path: str) -> str:
    import base64

    r = run(["gh", "api", f"repos/{repo}/contents/{path}"], check=True)
    data = json.loads(r.stdout)
    return base64.b64decode(data["content"]).decode()


def bump_content(text: str, tag: str) -> tuple[str, bool]:
    semver = normalize_tag(tag)
    new, _ = USES_RE.subn(rf"\1@{semver}", text)
    new, _ = REF_RE.subn(rf"\1{semver}", new)
    if new == text and TEMPLATE in text:
        # Pins may already match @tag while factory_ref lines still lag.
        new2, n3 = REF_RE.subn(rf"\1{semver}", text)
        if n3 and new2 != text:
            return new2, True
    return new, new != text


def default_branch(repo: str) -> str:
    r = run(["gh", "repo", "view", repo, "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name"])
    return r.stdout.strip()


def existing_pr(repo: str, branch: str) -> int | None:
    r = run(
        [
            "gh",
            "pr",
            "list",
            "--repo",
            repo,
            "--head",
            branch,
            "--state",
            "open",
            "--json",
            "number",
            "-q",
            ".[0].number",
        ],
        check=False,
    )
    num = r.stdout.strip()
    if not num or num == "null":
        return None
    return int(num)


def sync_repo(repo: str, tag: str, *, dry_run: bool) -> str:
    branch = f"{BRANCH_PREFIX}{tag.lstrip('v')}"
    paths = load_workflow_paths(repo)
    updates: dict[str, str] = {}
    for path in paths:
        try:
            body = fetch_file(repo, path)
        except subprocess.CalledProcessError:
            continue
        if TEMPLATE not in body or "reusable-" not in body:
            continue
        new, changed = bump_content(body, tag)
        if changed:
            updates[path] = new
    if not updates:
        return f"{repo}: no reusable-workflow pins found; skipped"

    if dry_run:
        return f"{repo}: dry-run would update {len(updates)} file(s) on branch {branch}"

    base = default_branch(repo)
    with tempfile.TemporaryDirectory() as td:
        wd = Path(td)
        run(["gh", "repo", "clone", repo, str(wd), "--", "--depth", "1", "-b", base], check=True)
        for path, content in updates.items():
            dest = wd / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(content)
        run(["git", "-C", str(wd), "checkout", "-b", branch], check=True)
        run(["git", "-C", str(wd), "add", *updates.keys()], check=True)
        run(
            [
                "git",
                "-C",
                str(wd),
                "commit",
                "-m",
                f"chore(factory): bump template reusable workflows to {tag}",
            ],
            check=True,
        )
        run(["git", "-C", str(wd), "push", "-u", "origin", branch, "--force-with-lease"], check=True)

    title = f"chore(factory): bump template workflows to {tag}"
    body = (
        f"Bumps pinned reusable workflows to `{TEMPLATE}` tag `{tag}`.\n\n"
        "Merge to adopt the release; revert this PR to roll back."
    )
    pr = existing_pr(repo, branch)
    if pr:
        run(["gh", "pr", "edit", str(pr), "--repo", repo, "--title", title, "--body", body], check=True)
        return f"{repo}: updated existing PR #{pr}"
    r = run(
        [
            "gh",
            "pr",
            "create",
            "--repo",
            repo,
            "--head",
            branch,
            "--base",
            base,
            "--title",
            title,
            "--body",
            body,
        ],
        check=True,
    )
    return f"{repo}: {r.stdout.strip()}"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repos-file", required=True, help="Newline-separated owner/repo list")
    p.add_argument("--tag", required=True, help="Target semver tag (e.g. v0.2.0)")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()
    try:
        normalize_tag(args.tag)
    except ValueError as exc:
        print(f"factory-sync-repos: {exc}", file=sys.stderr)
        return 2
    repos = [
        line.strip()
        for line in Path(args.repos_file).read_text().splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]
    if not repos:
        print("factory-sync-repos: empty repo list", file=sys.stderr)
        return 2
    status = 0
    for repo in repos:
        try:
            msg = sync_repo(repo, args.tag, dry_run=args.dry_run)
            print(msg)
        except Exception as exc:  # noqa: BLE001 — report per-repo failure
            print(f"{repo}: ERROR {exc}", file=sys.stderr)
            status = 1
    return status


if __name__ == "__main__":
    raise SystemExit(main())