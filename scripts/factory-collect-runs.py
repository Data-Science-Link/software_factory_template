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
    spec = importlib.util.spec_from_file_location(
        "factory_validate_run", VALIDATOR_PATH
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.load_record, module.validate_record


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
        sys.stderr.write(
            f"ERROR: gh api failed for {url}: {exc.stderr.strip()}\n"
            f"(is gh installed and authenticated with GITHUB_TOKEN?)\n"
        )
        raise
    return json.loads(raw.stdout)


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
    parser.add_argument("--repo", default="Data-Science-Link/software_factory_template")
    args = parser.parse_args()

    load_record, validate_record = load_validator()

    if args.from_json:
        with open(args.from_json, encoding="utf-8") as f:
            comments = json.load(f)
    else:
        comments = fetch_comments(args.repo)

    found = 0
    invalid = []  # (run_id or source, reason)
    dupes = 0
    by_run_id: dict[str, dict] = {}

    for comment in comments:
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
