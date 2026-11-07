#!/usr/bin/env python3
"""Validate a factory spec file or issue-comment body (marker first).

Exit 0 when valid; exit 1 and print one miss per line on stderr when not.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
ARTIFACT_SCAN = HERE / "opencode-artifact-scan.sh"

SPEC_MARKER = "<!-- factory-spec v1 -->"
PATH_IN_BACKTICKS = re.compile(r"`([^`]+)`")

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
    "approved_at",
    "drafted_by",
]


def strip_test_directive(text: str) -> str:
    lines = text.splitlines(keepends=True)
    while lines and re.match(r"^#\s*spec-check-expect:", lines[0]):
        lines.pop(0)
    return "".join(lines)


def load_body(path: Path) -> str:
    text = strip_test_directive(path.read_text(encoding="utf-8"))
    return strip_comment_wrapper(text)


def strip_comment_wrapper(text: str) -> str:
    """Drop any comment-body text before the factory-spec marker (#59)."""
    no_bom = text.lstrip("\ufeff")
    idx = no_bom.find(SPEC_MARKER)
    if idx == -1:
        return no_bom
    rest = no_bom[idx + len(SPEC_MARKER) :].lstrip("\n")
    return rest


def split_front_matter(text: str) -> tuple[dict[str, Any] | None, str]:
    body_start = text.lstrip()
    if not body_start.startswith("---"):
        return None, text
    parts = body_start.split("---", 2)
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


def heading_matches_extended(heading: str, prefix: str) -> bool:
    if heading == prefix:
        return True
    return heading.startswith(prefix + " (")


def heading_index_base(headings: list[str], label: str) -> int | None:
    for i, h in enumerate(headings):
        if h == label:
            return i
    return None


def heading_index_extended(headings: list[str], prefix: str) -> int | None:
    for i, h in enumerate(headings):
        if heading_matches_extended(h, prefix):
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

    if fm.get("status") == "approved":
        at = fm.get("approved_at")
        if at is None or (isinstance(at, str) and not at.strip()):
            errors.append("front matter approved_at is required when status is approved")

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
        idx = heading_index_base(headings, label)
        if idx is None:
            errors.append(f"missing base section heading: {label}")
            continue
        if idx <= last:
            errors.append(f"base section out of order: {label}")
        last = idx

    complexity = fm.get("complexity") if fm else None
    risk = fm.get("risk") if fm else None
    for label in sorted(extended_required(complexity, risk)):
        if heading_index_extended(headings, label) is None:
            errors.append(f"missing required extended section heading: {label}")


def raw_front_matter(text: str) -> str | None:
    """The text between the first two --- lines, or None (same split as split_front_matter)."""
    body_start = text.lstrip()
    if not body_start.startswith("---"):
        return None
    parts = body_start.split("---", 2)
    return parts[1] if len(parts) >= 3 else None


def section(markdown: str, heading: str) -> str:
    m = re.search(
        rf"^##[ \t]+{re.escape(heading)}[ \t]*\n(.*?)(?=^##[ \t]|\Z)",
        markdown,
        re.M | re.S,
    )
    return m.group(1) if m else ""


def files_line_intent(line: str) -> str:
    low = line.lower()
    if re.search(r"\b(read\b|read-first)", low) and not re.search(r"\b(create|add|new)\b", low):
        return "read"
    if re.search(r"\b(create|add|new)\b", low):
        return "create"
    if re.search(r"\b(edit|change|modify|update)\b", low):
        return "modify"
    return "read"


def files_section_paths(files_md: str) -> list[tuple[str, str]]:
    paths: list[tuple[str, str]] = []
    for line in files_md.splitlines():
        found = PATH_IN_BACKTICKS.findall(line)
        if not found:
            continue
        intent = files_line_intent(line)
        for raw in found:
            p = raw.strip()
            if not p or "*" in p or "?" in p or "..." in p:
                continue
            paths.append((intent, p))
    return paths


def check_files_paths(body: str, errors: list[str], base_scripts: Path | None = None) -> None:
    """Every ## Files path must be buildable under scripts/opencode-artifact-scan.sh (#131).

    base_scripts: file listing the scripts/ paths on the base branch; "existing script" is judged
    against it, not HEAD, so a build PR that adds its own spec's scripts still passes.
    """
    base_args = ["--base-scripts", str(base_scripts)] if base_scripts else []
    for intent, path in files_section_paths(section(body, "Files")):
        r = subprocess.run(
            ["bash", str(ARTIFACT_SCAN), *base_args, "--check-spec-path", intent, path],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if r.returncode == 0:
            continue
        msg = (r.stderr or r.stdout or "").strip()
        if msg:
            line = msg.splitlines()[-1]
            if line.startswith("spec Files path policy:"):
                errors.append(line)
            else:
                errors.append(f"spec Files path policy: {path} ({line})")
        else:
            errors.append(f"spec Files path policy: blocked path {path!r}")


def check_escaped_quotes(raw: str | None, errors: list[str]) -> None:
    """Reject backslash-escaped quotes in front matter (issue #75).

    A hand copy of a spec comment once turned "..." into \"...\", which broke approved_at while
    YAML still parsed. Front matter never needs \"; use single quotes or plain scalars.
    """
    if raw is None:
        return
    for n, line in enumerate(raw.split("\n")[1:], start=1):
        if '\\"' in line:
            errors.append(
                f"front matter line {n} has an escaped quote (\\\"); copy the spec exactly "
                "and use plain or single-quoted values"
            )


def validate_text(text: str, base_scripts: Path | None = None) -> list[str]:
    errors: list[str] = []
    fm, body = split_front_matter(text)
    check_escaped_quotes(raw_front_matter(text), errors)
    check_front_matter(fm, errors)
    check_headings(body, fm if fm and "__yaml_error__" not in fm else None, errors)
    if not errors:
        check_files_paths(body, errors, base_scripts)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a factory spec markdown file.")
    parser.add_argument("path", type=Path, help="Spec file or comment body saved as .md")
    parser.add_argument(
        "--base-scripts",
        type=Path,
        help="File listing scripts/ paths on the base branch (default: tracked on HEAD)",
    )
    args = parser.parse_args()

    if not args.path.is_file():
        print(f"not a file: {args.path}", file=sys.stderr)
        return 1

    if args.base_scripts is not None and not args.base_scripts.is_file():
        print(f"not a file: {args.base_scripts}", file=sys.stderr)
        return 1

    errors = validate_text(load_body(args.path), args.base_scripts)
    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        return 1
    print(f"OK {args.path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
