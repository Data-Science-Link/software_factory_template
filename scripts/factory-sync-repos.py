#!/usr/bin/env python3
"""Open or update a sync PR in each product repo to bump reusable-workflow pin tags.

Reads a newline-separated repo list (owner/name), updates pins in .github/workflows/
that call Data-Science-Link/software_factory_template reusable workflows, and pushes a branch.

Example:
  python3 scripts/factory-sync-repos.py --repos-file factory/adopters.txt --tag v0.2.0 --dry-run
  python3 scripts/factory-sync-repos.py --repos-file factory/adopters.txt --tag v0.2.0 --check --json
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
from typing import Any

TEMPLATE = "Data-Science-Link/software_factory_template"
REPO_SLUG_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
USES_RE = re.compile(
    rf"(uses:\s+{re.escape(TEMPLATE)}/\.github/workflows/reusable-[-\w]+\.yml)@v\d+\.\d+\.\d+",
    re.MULTILINE,
)
REF_RE = re.compile(
    r"^(\s*factory_ref:\s*)v\d+\.\d+\.\d+(?=\s*$)", re.MULTILINE
)
SEMVER_RE = re.compile(r"^v?\d+\.\d+\.\d+$")
BRANCH_PREFIX = "factory-sync-"
ADOPTER_STATUSES = ("up_to_date", "outdated", "missing_pins", "error")


def normalize_tag(tag: str) -> str:
    """Return a ``vMAJOR.MINOR.PATCH`` tag or raise ValueError."""
    t = tag.strip()
    if not SEMVER_RE.fullmatch(t):
        raise ValueError(
            f"invalid semver tag {tag!r} (expected vMAJOR.MINOR.PATCH, e.g. v0.2.0)"
        )
    return t if t.startswith("v") else f"v{t}"


def parse_repos_file(path: Path) -> list[str]:
    """Parse adopters list: skip ``#`` comments and blanks, dedupe, validate slugs."""
    repos: list[str] = []
    seen: set[str] = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if not REPO_SLUG_RE.fullmatch(line) or "/" not in line:
            raise ValueError(
                f"invalid repo slug {line!r} (expected owner/name, e.g. your-org/product)"
            )
        if line not in seen:
            seen.add(line)
            repos.append(line)
    return repos


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


def inspect_repo(repo: str, tag: str) -> dict[str, Any]:
    """Read-only adopter pin audit (no git mutations)."""
    semver = normalize_tag(tag)
    record: dict[str, Any] = {
        "repo": repo,
        "status": "error",
        "target_tag": semver,
        "outdated_files": [],
        "detail": "",
    }
    try:
        paths = load_workflow_paths(repo)
    except subprocess.CalledProcessError as exc:
        record["detail"] = f"cannot list workflows: {exc.stderr.strip() or exc}"
        return record

    found_pins = False
    outdated: list[str] = []
    for path in paths:
        try:
            body = fetch_file(repo, path)
        except subprocess.CalledProcessError:
            continue
        if TEMPLATE not in body or "reusable-" not in body:
            continue
        found_pins = True
        _new, changed = bump_content(body, semver)
        if changed:
            outdated.append(path)

    if not found_pins:
        record["status"] = "missing_pins"
        record["detail"] = "no reusable-workflow caller pins found under .github/workflows/"
    elif outdated:
        record["status"] = "outdated"
        record["outdated_files"] = sorted(outdated)
        record["detail"] = f"{len(outdated)} workflow file(s) lag tag {semver}"
    else:
        record["status"] = "up_to_date"
        record["detail"] = f"all pins match {semver}"
    return record


def summarize_adopters(rows: list[dict[str, Any]]) -> dict[str, int]:
    summary = {s: 0 for s in ADOPTER_STATUSES}
    for row in rows:
        st = row.get("status", "error")
        if st not in summary:
            st = "error"
        summary[st] += 1
    summary["total"] = len(rows)
    return summary


def sync_repo(repo: str, tag: str, *, dry_run: bool) -> str:
    branch = f"{BRANCH_PREFIX}{tag.lstrip('v')}"
    audit = inspect_repo(repo, tag)
    if audit["status"] == "missing_pins":
        return f"{repo}: no reusable-workflow pins found; skipped"
    if audit["status"] == "up_to_date":
        return f"{repo}: already up to date at {normalize_tag(tag)}"
    if audit["status"] == "error":
        return f"{repo}: ERROR {audit.get('detail', 'unknown')}"

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


def emit_json(payload: dict[str, Any]) -> None:
    json.dump(payload, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repos-file", required=True, help="Newline-separated owner/repo list")
    p.add_argument("--tag", required=True, help="Target semver tag (e.g. v0.2.0)")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument(
        "--check",
        action="store_true",
        help="Report adopter pin drift only (no branches, PRs, or file writes)",
    )
    p.add_argument("--json", action="store_true", help="Machine-readable summary on stdout")
    args = p.parse_args()
    try:
        normalize_tag(args.tag)
    except ValueError as exc:
        print(f"factory-sync-repos: {exc}", file=sys.stderr)
        return 2

    repos_path = Path(args.repos_file)
    try:
        repos = parse_repos_file(repos_path)
    except ValueError as exc:
        print(f"factory-sync-repos: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"factory-sync-repos: cannot read {repos_path}: {exc}", file=sys.stderr)
        return 2

    if not repos:
        print("factory-sync-repos: empty repo list", file=sys.stderr)
        return 2

    if args.check:
        adopters = [inspect_repo(repo, args.tag) for repo in repos]
        summary = summarize_adopters(adopters)
        ok = summary.get("error", 0) == 0
        payload = {
            "adopters": adopters,
            "ok": ok,
            "repos": repos,
            "repos_file": str(repos_path.resolve()),
            "summary": summary,
            "tag": normalize_tag(args.tag),
        }
        if args.json:
            emit_json(payload)
        else:
            for row in adopters:
                print(f"{row['repo']}: {row['status']} — {row['detail']}")
            print(
                f"Summary: {summary['up_to_date']} up_to_date, "
                f"{summary['outdated']} outdated, "
                f"{summary['missing_pins']} missing_pins, "
                f"{summary['error']} error"
            )
        return 1 if summary.get("error", 0) else 0

    status = 0
    lines: list[str] = []
    for repo in repos:
        try:
            msg = sync_repo(repo, args.tag, dry_run=args.dry_run)
            lines.append(msg)
            if not args.json:
                print(msg)
        except Exception as exc:  # noqa: BLE001 — report per-repo failure
            err = f"{repo}: ERROR {exc}"
            lines.append(err)
            if not args.json:
                print(err, file=sys.stderr)
            status = 1

    if args.json:
        emit_json(
            {
                "dry_run": bool(args.dry_run),
                "messages": lines,
                "ok": status == 0,
                "repos": repos,
                "tag": normalize_tag(args.tag),
            }
        )
    return status


if __name__ == "__main__":
    raise SystemExit(main())