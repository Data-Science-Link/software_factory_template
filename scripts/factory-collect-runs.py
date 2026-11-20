#!/usr/bin/env python3
"""Collect factory run records from issue comments into site-data/runs/.

The site build gets every real run record (including failed, rejected and
closed runs) from the issue comments where the record job posts them, because
factory/runs/ on main is empty by design.

Live mode (no --from-json) lists issue comments repo-wide with
`gh api --paginate repos/{repo}/issues/comments`; it is only meant for the site
deploy job with GITHUB_TOKEN and never runs inside /oc agents.

Input comments are filtered to those authored by `github-actions[bot]` that
contain `<!-- factory-run-record -->`; the first fenced json block after the
marker is parsed and validated through scripts/factory-validate-run.py. Records
are deduped by run_id (most recently updated comment wins) and written as one
`site-data/runs/<run_id>.json` per record in stable key order.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
VALIDATOR_PATH = REPO_ROOT / "scripts" / "factory-validate-run.py"

MARKER = "<!-- factory-run-record -->"
BOT_AUTHOR = "github-actions[bot]"
JSON_FENCE = re.compile(r"```json\s*\n(.*?)```", re.DOTALL | re.IGNORECASE)


def load_validator():
    try:
        spec = importlib.util.spec_from_file_location(
            "factory_validate_run", VALIDATOR_PATH
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except Exception as exc:
        sys.stderr.write(f"ERROR: cannot load validator {VALIDATOR_PATH}: {exc}\n")
        raise SystemExit(2) from exc
    return module.load_record, module.validate_record


def load_comments_fixture(path: str) -> list[dict]:
    """Load a local JSON array of GitHub issue comment objects (--from-json)."""
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        sys.stderr.write(f"ERROR: cannot read --from-json {path}: {exc}\n")
        raise SystemExit(2) from exc
    except UnicodeDecodeError as exc:
        sys.stderr.write(f"ERROR: --from-json {path} is not valid UTF-8: {exc}\n")
        raise SystemExit(2) from exc
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        sys.stderr.write(
            f"ERROR: --from-json {path} contains invalid JSON: {exc}\n"
        )
        raise SystemExit(2) from exc
    if not isinstance(data, list):
        sys.stderr.write(
            f"ERROR: --from-json {path} must be a JSON array of comment objects\n"
        )
        raise SystemExit(2)
    return data


def resolve_github_repo(cli_repo: str | None) -> str:
    """Return owner/repo from --repo, GITHUB_REPOSITORY, or git remote origin."""
    if cli_repo:
        return cli_repo
    env_repo = os.environ.get("GITHUB_REPOSITORY", "").strip()
    if env_repo:
        return env_repo
    try:
        proc = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        sys.stderr.write(
            "ERROR: cannot detect GitHub repo; pass --repo or set GITHUB_REPOSITORY\n"
        )
        raise SystemExit(2) from exc
    url = proc.stdout.strip()
    match = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$", url)
    if not match:
        sys.stderr.write(f"ERROR: unrecognized origin remote URL: {url}\n")
        raise SystemExit(2)
    return f"{match.group(1)}/{match.group(2)}"


def fetch_comments(repo: str) -> list[dict]:
    """List all issue comments repo-wide using gh (live mode only)."""
    url = f"repos/{repo}/issues/comments"
    try:
        raw = subprocess.run(
            ["gh", "api", "--paginate", url],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or str(exc)).strip()
        sys.stderr.write(
            f"ERROR: gh api failed for {url}: {detail}\n"
            f"(is gh installed and authenticated with GITHUB_TOKEN?)\n"
        )
        raise SystemExit(1) from exc
    try:
        return json.loads(raw.stdout)
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"ERROR: gh api returned invalid JSON for {url}: {exc}\n")
        raise SystemExit(1) from exc


def extract_json_block(body: str) -> str | None:
    """Return the first fenced json block that appears after the marker."""
    marker_index = body.find(MARKER)
    if marker_index < 0:
        return None
    match = JSON_FENCE.search(body, marker_index)
    if not match:
        return None
    return match.group(1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="site-data/runs")
    parser.add_argument("--from-json", default=None, help="Local JSON fixture of comments")
    parser.add_argument(
        "--repo",
        default=None,
        help="GitHub owner/repo (default: GITHUB_REPOSITORY or git remote origin)",
    )
    args = parser.parse_args()

    load_record, validate_record = load_validator()

    if args.from_json:
        comments = load_comments_fixture(args.from_json)
    else:
        repo = resolve_github_repo(args.repo)
        comments = fetch_comments(repo)

    found = 0
    invalid = []  # (run_id or source, reason)
    dupes = 0
    by_run_id: dict[str, dict] = {}

    for comment in comments:
        if not isinstance(comment, dict):
            invalid.append(("(comment)", "comment entry must be a JSON object"))
            continue
        author = comment.get("user", {}).get("login")
        body = comment.get("body") or ""
        if author != BOT_AUTHOR or MARKER not in body:
            continue
        found += 1
        block = extract_json_block(body)
        if block is None:
            invalid.append(("(no fenced json block)", "no ```json block after marker"))
            continue
        try:
            record = json.loads(block)
        except json.JSONDecodeError as exc:
            invalid.append(("(bad json)", f"invalid JSON block: {exc}"))
            continue
        if not isinstance(record, dict):
            invalid.append(("(bad json)", "record JSON block must be an object"))
            continue

        source = comment.get("html_url") or comment.get("id", "(comment)")
        errors = validate_record(record, None)
        if errors:
            invalid.append((record.get("run_id", "(no run_id)"), "; ".join(errors)))
            continue

        run_id = record.get("run_id")
        if not run_id:
            invalid.append(("(no run_id)", "record missing run_id"))
            continue

        updated_at = comment.get("updated_at") or ""
        current = by_run_id.get(run_id)
        if current is None or updated_at >= current.get("updated_at", ""):
            if current is not None:
                dupes += 1
            by_run_id[run_id] = {
                "record": record,
                "updated_at": updated_at,
                "source": source,
            }

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    written = 0
    for run_id, entry in sorted(by_run_id.items()):
        if not re.fullmatch(r"[A-Za-z0-9._-]+", run_id):
            invalid.append((run_id, f"invalid run_id filename {run_id!r}"))
            continue
        out_path = out_dir / f"{run_id}.json"
        with out_path.open("w", encoding="utf-8") as f:
            json.dump(entry["record"], f, sort_keys=True, indent=2)
            f.write("\n")
        written += 1

    dupes_total = dupes
    print(f"records found: {found}")
    print(f"records written: {written}")
    print(f"skipped as invalid: {len(invalid)}")
    for name, reason in invalid:
        print(f"  - {name}: {reason}")
    print(f"duplicates (deduped): {dupes_total}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
