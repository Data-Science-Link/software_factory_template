#!/usr/bin/env python3
"""Validate, list, and append entries in `.factory/DECISIONS.md` (offline, stdlib only)."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path

DEFAULT_FILE = Path(".factory/DECISIONS.md")
LOG_HEADING = "## Log"
HEADING_RE = re.compile(r"^(#{2,3})\s+(\d{4}-\d{2}-\d{2})\s+—\s+(.+?)\s*$")
DATE_OK = re.compile(r"^\d{4}-\d{2}-\d{2}$")
FIELD_RE = re.compile(r"^-\s+\*\*([^*]+):\*\*\s*(.*)$")
STATUS_RE = re.compile(r"^\*\*Status:\*\*\s*(.+)$")


@dataclass
class Decision:
    number: int
    date: str
    title: str
    heading_level: int
    line_no: int
    body: str
    fields: dict[str, str] = field(default_factory=dict)
    status: str | None = None

    @property
    def slug(self) -> str:
        return f"{self.date} — {self.title}"


def read_log_file(path: Path) -> tuple[str | None, str | None]:
    """Return (text, error_message). Missing file yields empty text."""
    if not path.is_file():
        return "", None
    try:
        return path.read_text(encoding="utf-8"), None
    except OSError as exc:
        return None, f"cannot read {path}: {exc}"
    except UnicodeDecodeError:
        return None, f"{path} is not valid UTF-8"


def split_log_section(text: str) -> tuple[str, str]:
    """Return (preamble, log_body). Everything from ## Log onward is the log."""
    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if line.strip() == LOG_HEADING:
            return ("".join(lines[: i + 1]), "".join(lines[i + 1 :]))
    return (text, "")


def parse_decisions(text: str) -> list[Decision]:
    _, log_body = split_log_section(text)
    if not log_body.strip():
        return []

    lines = log_body.splitlines()
    entries: list[Decision] = []
    i = 0
    while i < len(lines):
        m = HEADING_RE.match(lines[i])
        if not m:
            i += 1
            continue
        level = len(m.group(1))
        d = m.group(2)
        title = m.group(3).strip()
        start = i
        i += 1
        body_lines: list[str] = []
        while i < len(lines):
            if HEADING_RE.match(lines[i]):
                break
            body_lines.append(lines[i])
            i += 1
        body = "\n".join(body_lines).strip()
        fields: dict[str, str] = {}
        status: str | None = None
        for bl in body_lines:
            bl_stripped = bl.strip()
            if not bl_stripped:
                continue
            sm = STATUS_RE.match(bl_stripped)
            if sm:
                status = sm.group(1).strip()
                continue
            fm = FIELD_RE.match(bl_stripped)
            if fm:
                key = fm.group(1).strip()
                val = fm.group(2).strip()
                fields[key] = val
                if key == "Status" and not status:
                    status = val
        entries.append(
            Decision(
                number=len(entries) + 1,
                date=d,
                title=title,
                heading_level=level,
                line_no=start + 1,
                body=body,
                fields=fields,
                status=status,
            )
        )
    return entries


def valid_date(d: str) -> bool:
    if not DATE_OK.match(d):
        return False
    try:
        datetime.strptime(d, "%Y-%m-%d").date()
    except ValueError:
        return False
    return True


def check_decisions(entries: list[Decision]) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    seen_slug: dict[str, int] = {}
    seen_title: dict[str, int] = {}

    for entry in entries:
        if not valid_date(entry.date):
            errors.append(
                f"line {entry.line_no}: malformed date {entry.date!r} "
                f"({entry.title!r})"
            )
        slug = entry.slug
        if slug in seen_slug:
            errors.append(
                f"line {entry.line_no}: duplicate decision id {slug!r} "
                f"(first at entry {seen_slug[slug]})"
            )
        else:
            seen_slug[slug] = entry.number

        if entry.title in seen_title:
            errors.append(
                f"line {entry.line_no}: duplicate title {entry.title!r} "
                f"(first at entry {seen_title[entry.title]})"
            )
        else:
            seen_title[entry.title] = entry.number

        decision_text = entry.fields.get("Decision", "").strip()
        if not decision_text:
            errors.append(
                f"line {entry.line_no}: empty or missing Decision body "
                f"({entry.slug!r})"
            )

    return errors, warnings


def format_entry(
    title: str,
    decision: str,
    why: str,
    entry_date: str,
    status: str | None,
) -> str:
    lines = [f"### {entry_date} — {title}"]
    if status:
        lines.append(f"- **Status:** {status}")
    lines.append(f"- **Decision:** {decision}")
    lines.append(f"- **Why:** {why}")
    return "\n".join(lines) + "\n"


def cmd_list(entries: list[Decision], as_json: bool) -> int:
    rows = [
        {
            "id": e.number,
            "number": e.number,
            "date": e.date,
            "title": e.title,
            "status": e.status,
        }
        for e in entries
    ]
    if as_json:
        print(json.dumps(rows, indent=2, sort_keys=True))
        return 0
    if not rows:
        print("(no decisions)")
        return 0
    print("| # | Date | Title | Status |")
    print("|---|------|-------|--------|")
    for r in rows:
        status = r["status"] or ""
        title = r["title"].replace("|", "\\|")
        print(f"| {r['number']} | {r['date']} | {title} | {status} |")
    return 0


def cmd_check(entries: list[Decision], as_json: bool) -> int:
    errors, warnings = check_decisions(entries)
    payload = {
        "total": len(entries),
        "valid": not errors,
        "errors": errors,
        "warnings": warnings,
    }
    if as_json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"total decisions: {len(entries)}")
        for w in warnings:
            print(f"warning: {w}", file=sys.stderr)
        for e in errors:
            print(f"error: {e}", file=sys.stderr)
        if errors:
            print(f"check: {len(errors)} error(s)", file=sys.stderr)
        else:
            print("check: ok")
    return 1 if errors else 0


def cmd_next_id(entries: list[Decision]) -> int:
    print(len(entries) + 1)
    return 0


def cmd_add(
    path: Path,
    title: str,
    decision: str,
    why: str,
    entry_date: str | None,
    status: str | None,
    do_write: bool,
) -> int:
    text, err = read_log_file(path)
    if err:
        print(f"add: {err}", file=sys.stderr)
        return 1
    entries = parse_decisions(text or "")
    when = entry_date or date.today().isoformat()
    if not valid_date(when):
        print(f"add: malformed --date {when!r}", file=sys.stderr)
        return 1
    block = format_entry(title, decision, why, when, status)
    print(block, end="")
    if not do_write:
        return 0
    if LOG_HEADING not in text:
        print(f"add: {path} missing {LOG_HEADING!r}", file=sys.stderr)
        return 1
    suffix = text
    if not suffix.endswith("\n"):
        suffix += "\n"
    if not suffix.endswith("\n\n"):
        suffix += "\n"
    path.write_text(suffix + block, encoding="utf-8")
    return 0


def main() -> int:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--file",
        type=Path,
        default=DEFAULT_FILE,
        help=f"path to decision log (default: {DEFAULT_FILE})",
    )
    common.add_argument(
        "--json",
        action="store_true",
        help="JSON output for list and check",
    )

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--file",
        type=Path,
        default=DEFAULT_FILE,
        help=f"path to decision log (default: {DEFAULT_FILE})",
    )
    ap.add_argument(
        "--json",
        action="store_true",
        help="JSON output for list and check",
    )
    subs = ap.add_subparsers(dest="command", required=True)

    subs.add_parser("list", parents=[common], help="list parsed decisions")
    subs.add_parser("check", parents=[common], help="validate the decision log")
    subs.add_parser("next-id", parents=[common], help="print the next sequential decision number")

    add_p = subs.add_parser(
        "add",
        parents=[common],
        help="format (and optionally append) a new entry",
    )
    add_p.add_argument("--title", required=True)
    add_p.add_argument("--decision", required=True)
    add_p.add_argument("--why", required=True)
    add_p.add_argument("--date", dest="entry_date", metavar="YYYY-MM-DD")
    add_p.add_argument("--status")
    add_p.add_argument(
        "--write",
        action="store_true",
        help="append to --file (default is dry-run)",
    )

    args = ap.parse_args()
    path: Path = args.file
    if args.command == "add" and args.write and not path.is_file():
        print(f"add: file not found: {path}", file=sys.stderr)
        return 1

    text, err = read_log_file(path)
    if err:
        print(f"decision-log: {err}", file=sys.stderr)
        return 1
    entries = parse_decisions(text or "")

    if args.command == "list":
        return cmd_list(entries, args.json)
    if args.command == "check":
        return cmd_check(entries, args.json)
    if args.command == "next-id":
        return cmd_next_id(entries)
    if args.command == "add":
        return cmd_add(
            path,
            args.title,
            args.decision,
            args.why,
            args.entry_date,
            args.status,
            args.write,
        )
    return 1


if __name__ == "__main__":
    sys.exit(main())