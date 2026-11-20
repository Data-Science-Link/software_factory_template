#!/usr/bin/env python3
"""Shared spec YAML front-matter helpers (#189)."""
from __future__ import annotations

import re
from typing import Any

import yaml

# Unquoted scalar that contains ": " is ambiguous YAML (mapping values are not allowed).
_COLON_SPACE_IN_VALUE = re.compile(r":\s")
_FM_SCALAR_LINE = re.compile(r"^([A-Za-z_][\w-]*):\s*(.*)$")


def normalize_front_matter_raw(raw: str) -> str:
    """Auto-quote unquoted scalar values that contain ': ' so yaml.safe_load succeeds."""
    out: list[str] = []
    for line in raw.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            out.append(line)
            continue
        m = _FM_SCALAR_LINE.match(line)
        if not m:
            out.append(line)
            continue
        key, val = m.group(1), m.group(2)
        stripped = val.strip()
        if not stripped:
            out.append(line)
            continue
        if stripped[0] in "'\"[{&!>|":
            out.append(line)
            continue
        if _COLON_SPACE_IN_VALUE.search(stripped):
            quoted = "'" + stripped.replace("'", "''") + "'"
            out.append(f"{key}: {quoted}")
        else:
            out.append(line)
    return "\n".join(out)


def duplicate_scalar_keys(raw: str) -> list[str]:
    """Root-level scalar keys duplicated in raw YAML front matter (first wins in PyYAML)."""
    seen: set[str] = set()
    dups: list[str] = []
    for line in raw.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = _FM_SCALAR_LINE.match(line)
        if not m:
            continue
        key = m.group(1)
        if key in seen and key not in dups:
            dups.append(key)
        seen.add(key)
    return dups


def parse_front_matter_raw(raw: str) -> tuple[dict[str, Any] | None, str | None]:
    """Parse normalized YAML front matter; returns (mapping, error_message)."""
    try:
        data = yaml.safe_load(normalize_front_matter_raw(raw))
    except yaml.YAMLError as exc:
        return None, str(exc)
    if not isinstance(data, dict):
        return None, "front matter must be a YAML mapping"
    return data, None