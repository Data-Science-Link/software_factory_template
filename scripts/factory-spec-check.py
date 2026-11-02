#!/usr/bin/env python3
"""Validate a factory spec file or issue-comment body (marker first).

Exit 0 when valid; exit 1 and print one miss per line on stderr when not.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any

import yaml

SPEC_MARKER = "<!-- factory-spec v1 -->"

BASE_HEADINGS = [
    "Outcome",
    "Context",
    "Scope",
    "Out of scope",
    "Files",
    "Acceptance criteria",
    "Verification",
    "Classification",
    "Cost forecast",
    "Manual steps for Michael",
    "Dependencies",
    "Worker prompt",
]

EXTENDED_HEADINGS = [
    ("Design / approach", "always_extended"),
    ("Alternatives considered", "complex_high"),
    ("Risks, rollback and revert trigger", "always_extended"),
    ("What changes in production on merge", "always_extended"),
    ("Success metric", "always_extended"),
    ("Test plan detail", "complex_high"),
    ("Security and liability review", "complex_high"),
    ("Milestones / split plan", "complex_high"),
]

COMPLEXITY = frozenset({"simple", "standard", "complex"})
RISK = frozenset({"trivial", "normal", "high"})
STATUS = frozenset({"draft", "approved", "superseded"})
WORK_TYPE = frozenset({"code", "docs", "spec", "review", "data"})
DRAFTED_BY = frozenset({"grok-bot", "oc-spec-run"})

REQUIRED_FM_KEYS = [
    "spec_version",
    "title",
    "status",
    "complexity",
    "complexity_reason",
    "risk",
    "work_type",
    "model",
    "model_reason",
    "predicted_tokens_in",
    "predicted_tokens_cached",
    "predicted_tokens_out",
    "predicted_cost_usd",
    "budget_cap_usd",
    "price_table_version",
    "approved_by",
    "drafted_by",
]


def load_body(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    return strip_comment_wrapper(text)


def strip_comment_wrapper(text: str) -> str:
    stripped = text.lstrip("\ufeff")
    if stripped.startswith(SPEC_MARKER):
        rest = stripped[len(SPEC_MARKER) :].lstrip("\n")
        return rest
    return stripped


def split_front_matter(text: str) -> tuple[dict[str, Any] | None, str]:
    if not text.startswith("---"):
        return None, text
    parts = text.split("---", 2)
    if len(parts) < 3:
        return None, text
    raw = parts[1]
    body = parts[2]
    try:
        data = yaml.safe_load(raw)
    except yaml.YAMLError as exc:
        return {"__yaml_error__": str(exc)}, body
    if not isinstance(data, dict):
        return None, body
    return data, body


def extract_headings(markdown: str) -> list[str]:
    headings: list[str] = []
    for line in markdown.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            headings.append(m.group(1).strip())
    return headings


def heading_index(headings: list[str], needle: str) -> int | None:
    for i, h in enumerate(headings):
        if needle in h:
            return i
    return None


def check_front_matter(fm: dict[str, Any] | None, errors: list[str]) -> None:
    if fm is None:
        errors.append("missing YAML front matter (must start with ---)")
        return
    if "__yaml_error__" in fm:
        errors.append(f"invalid YAML front matter: {fm['__yaml_error__']}")
        return

    for key in REQUIRED_FM_KEYS:
        if key not in fm:
            errors.append(f"front matter missing field: {key}")

    if "issue" not in fm and "issues" not in fm:
        errors.append("front matter must include issue or issues")

    if fm.get("spec_version") != 1:
        errors.append("front matter spec_version must be 1")

    for field, allowed in (
        ("complexity", COMPLEXITY),
        ("risk", RISK),
        ("status", STATUS),
        ("work_type", WORK_TYPE),
        ("drafted_by", DRAFTED_BY),
    ):
        val = fm.get(field)
        if val is not None and val not in allowed:
            errors.append(
                f"front matter {field} must be one of {sorted(allowed)} (got {val!r})"
            )

    complexity = fm.get("complexity")
    risk = fm.get("risk")
    if str(complexity) in RISK:
        errors.append("complexity must use simple|standard|complex, not risk words")
    if str(risk) in COMPLEXITY:
        errors.append("risk must use trivial|normal|high, not complexity words")


def extended_required(complexity: str | None, risk: str | None) -> set[str]:
    if complexity not in COMPLEXITY or risk not in RISK:
        return set()
    if complexity == "simple" and risk == "trivial":
        return set()
    complex_high = complexity == "complex" or risk == "high"
    standard_normal = complexity == "standard" or risk == "normal"
    if not complex_high and not standard_normal:
        return set()
    need: set[str] = set()
    for label, rule in EXTENDED_HEADINGS:
        if rule == "always_extended":
            need.add(label)
        elif rule == "complex_high" and complex_high:
            need.add(label)
    return need


def check_headings(markdown: str, fm: dict[str, Any] | None, errors: list[str]) -> None:
    headings = extract_headings(markdown)
    if not headings:
        errors.append("no ## headings found in spec body")
        return

    last = -1
    for label in BASE_HEADINGS:
        idx = heading_index(headings, label)
        if idx is None:
            errors.append(f"missing base section heading: {label}")
            continue
        if idx <= last:
            errors.append(f"base section out of order: {label}")
        last = idx

    complexity = fm.get("complexity") if fm else None
    risk = fm.get("risk") if fm else None
    for label in extended_required(complexity, risk):
        if heading_index(headings, label) is None:
            errors.append(f"missing required extended section heading: {label}")


def validate_text(text: str) -> list[str]:
    errors: list[str] = []
    fm, body = split_front_matter(text)
    check_front_matter(fm, errors)
    check_headings(body, fm if fm and "__yaml_error__" not in fm else None, errors)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a factory spec markdown file.")
    parser.add_argument("path", type=Path, help="Spec file or comment body saved as .md")
    args = parser.parse_args()

    if not args.path.is_file():
        print(f"not a file: {args.path}", file=sys.stderr)
        return 1

    errors = validate_text(load_body(args.path))
    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
