#!/usr/bin/env python3
"""Assert factory-predict-cost.py --write changed only owned front-matter fields (#60)."""
from __future__ import annotations

import json
import re
import sys
from datetime import date, datetime
from pathlib import Path

import yaml

OWNED = (
    "model",
    "model_reason",
    "predicted_tokens_in",
    "predicted_tokens_cached",
    "predicted_tokens_out",
    "predicted_cost_usd",
    "budget_cap_usd",
    "price_table_version",
)
MARKER = "<!-- factory-spec v1 -->"


def line_core(line: str) -> str:
    return line.lstrip("\ufeff").rstrip("\r\n")


def bounds(lines: list[str]) -> tuple[int, int]:
    search_from = 0
    for i, line in enumerate(lines):
        if MARKER in line:
            search_from = i + 1
            break
    start = None
    for i in range(search_from, len(lines)):
        if line_core(lines[i]).strip() == "---":
            if start is None:
                start = i
            else:
                return start, i
    raise SystemExit("no front matter delimiters")


def split_parts(text: str):
    lines = text.splitlines(keepends=True)
    start, end = bounds(lines)
    prefix = lines[: start + 1]
    suffix = lines[end:]
    unowned: list[str] = []
    owned: dict[str, str] = {}
    i = start + 1
    while i < end:
        line = lines[i]
        matched = None
        for key in OWNED:
            if re.match(rf"^{re.escape(key)}:(\s|$)", line_core(line)):
                matched = key
                break
        if matched is None:
            unowned.append(line)
            i += 1
            continue
        j = i + 1
        while j < end and lines[j][:1] in " \t":
            j += 1
        owned[matched] = "".join(lines[i:j])
        i = j
    return "".join(prefix), unowned, owned, "".join(suffix)


def parse_rhs(block: str):
    _first, _, rest = block.partition(":")
    try:
        loaded = yaml.safe_load("v: " + rest)
    except yaml.YAMLError as exc:
        raise SystemExit(f"cannot parse owned field: {exc}") from exc
    if isinstance(loaded, dict) and "v" in loaded:
        return loaded["v"]
    return loaded


def version_str(value) -> str:
    if value is None:
        return ""
    if isinstance(value, datetime):
        return value.date().isoformat()
    if isinstance(value, date):
        return value.isoformat()
    return str(value).strip()


def matches(key: str, existing, new) -> bool:
    if key == "price_table_version":
        return version_str(existing) == version_str(new)
    if key in ("predicted_cost_usd", "budget_cap_usd"):
        if existing is None or new is None:
            return existing is None and new is None
        try:
            return float(existing) == float(new)
        except (TypeError, ValueError):
            return False
    if key in (
        "predicted_tokens_in",
        "predicted_tokens_cached",
        "predicted_tokens_out",
    ):
        try:
            return int(existing) == int(new)
        except (TypeError, ValueError):
            return False
    return ("" if existing is None else str(existing)) == ("" if new is None else str(new))


def main() -> None:
    before = Path(sys.argv[1]).read_text(encoding="utf-8")
    after = Path(sys.argv[2]).read_text(encoding="utf-8")
    expected = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
    b_prefix, b_unowned, b_owned, b_suffix = split_parts(before)
    a_prefix, a_unowned, a_owned, a_suffix = split_parts(after)
    errors: list[str] = []
    if b_prefix != a_prefix:
        errors.append("prefix (text through opening ---) changed")
    if b_suffix != a_suffix:
        errors.append("suffix (closing --- and body) changed")
    if b_unowned != a_unowned:
        errors.append("unowned front-matter lines changed")
    if "\\u2192" in after:
        errors.append("unicode arrow was escaped as \\u2192")
    for key in OWNED:
        if key not in a_owned:
            errors.append(f"missing owned field {key}")
            continue
        got = parse_rhs(a_owned[key])
        want = expected[key]
        if not matches(key, got, want):
            errors.append(f"{key} is {got!r}, want {want!r}")
        if key in b_owned and matches(key, parse_rhs(b_owned[key]), want):
            if b_owned[key] != a_owned[key]:
                errors.append(f"{key} value was already correct but the line was rewritten")
    if errors:
        print("\n".join(errors))
        sys.exit(1)


if __name__ == "__main__":
    main()
