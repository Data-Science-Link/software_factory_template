#!/usr/bin/env python3
"""Standalone factory spec quality linter (offline CLI).

Lighter than scripts/factory-spec-check.py: front matter, core sections, verification
safety (#148), path policy pre-check (#69), and complexity/risk sanity warnings.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

import yaml

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
from factory_spec_front_matter import (  # noqa: E402
    duplicate_scalar_keys,
    normalize_front_matter_raw,
    parse_front_matter_raw,
)

ARTIFACT_SCAN = HERE / "opencode-artifact-scan.sh"
SPEC_MARKER = "<!-- factory-spec v1 -->"
PATH_IN_BACKTICKS = re.compile(r"`([^`]+)`")

COMPLEXITY = frozenset({"simple", "standard", "complex"})
RISK = frozenset({"trivial", "normal", "high"})
Mode = Literal["template", "product"]

GOAL_HEADING = "Goal"
CONTEXT_HEADING = "Context"
FILES_HEADING = "Files"
BAD_INPUTS_HEADING = "Bad inputs and edge cases"
VERIFICATION_HEADING = "Verification"

REQUIRED_FM_KEYS = ("issue", "title", "risk", "complexity")

MASK_PIPE_RE = re.compile(
    r"\|\s*(head|tail|sed|grep|awk)\b",
    re.IGNORECASE,
)
PYTEST_DBT_MASK_RE = re.compile(
    r"(?:^|[;&|\s])(pytest\b|dbt\b)[^\n]*(?:\|\||;\s*true\b|\|\s*:\s*$)",
    re.IGNORECASE | re.MULTILINE,
)

SECURITY_PATH_HINTS = re.compile(
    r"(^|/)(\.github/workflows/|requirements-factory\.txt|opencode\.json|"
    r"\.factory/(actions-security|models)\.yaml|factory/budget\.yml)",
    re.IGNORECASE,
)


@dataclass
class LintResult:
    path: str
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors


def strip_marker(text: str) -> str:
    no_bom = text.lstrip("\ufeff")
    idx = no_bom.find(SPEC_MARKER)
    if idx == -1:
        return no_bom
    return no_bom[idx + len(SPEC_MARKER) :].lstrip("\n")


def split_front_matter(text: str) -> tuple[dict[str, Any] | None, str, str | None]:
    """Return (front_matter, body, raw_fm_between_dashes)."""
    body_start = text.lstrip()
    if not body_start.startswith("---"):
        return None, text, None
    parts = body_start.split("---", 2)
    if len(parts) < 3:
        return {"__fm_incomplete__": True}, text, parts[1] if len(parts) > 1 else ""
    raw = parts[1]
    body = parts[2]
    data, err = parse_front_matter_raw(raw)
    if err:
        return {"__yaml_error__": err}, body, raw
    if data is None:
        return None, body, raw
    return data, body, raw


def extract_headings(markdown: str) -> list[str]:
    return [
        m.group(1).strip()
        for line in markdown.splitlines()
        if (m := re.match(r"^##\s+(.+?)\s*$", line))
    ]


def section(markdown: str, heading: str) -> str:
    m = re.search(
        rf"^##[ \t]+{re.escape(heading)}[ \t]*\n(.*?)(?=^##[ \t]|\Z)",
        markdown,
        re.M | re.S,
    )
    return m.group(1) if m else ""


def verification_bash_block(markdown: str) -> str:
    sec = section(markdown, VERIFICATION_HEADING)
    if not sec.strip():
        return ""
    lines = sec.splitlines()
    open_fence = False
    collected: list[str] = []
    for line in lines:
        if not open_fence and re.match(r"^```(bash|sh)\s*$", line):
            open_fence = True
            continue
        if open_fence and re.match(r"^```\s*$", line):
            break
        if open_fence:
            collected.append(line)
    return "\n".join(collected)


def files_line_intent(line: str) -> str:
    low = line.lower()
    if re.search(r"\b(read\b|read-first)", low) and not re.search(
        r"\b(create|add|new)\b", low
    ):
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


def load_protected_scripts() -> frozenset[str]:
    r = subprocess.run(
        ["bash", str(ARTIFACT_SCAN), "--list-protected"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if r.returncode != 0:
        return frozenset()
    return frozenset(line.strip() for line in r.stdout.splitlines() if line.strip())


def resolve_mode(mode_arg: str) -> Mode:
    if mode_arg in ("template", "product"):
        return mode_arg  # type: ignore[return-value]
    mode_file = ROOT / ".factory" / "mode.yml"
    if mode_file.is_file():
        try:
            data = yaml.safe_load(mode_file.read_text(encoding="utf-8"))
        except yaml.YAMLError:
            return "template"
        if isinstance(data, dict):
            m = data.get("mode")
            if m in ("template", "product"):
                return m  # type: ignore[return-value]
    return "template"


def check_front_matter(fm: dict[str, Any] | None, raw_fm: str | None, result: LintResult) -> None:
    if fm is None:
        result.errors.append("missing YAML front matter (must start with ---)")
        return
    if "__fm_incomplete__" in fm:
        result.errors.append("incomplete YAML front matter (missing closing --- delimiter)")
        return
    if "__yaml_error__" in fm:
        result.errors.append(f"invalid YAML front matter: {fm['__yaml_error__']}")
        return

    if raw_fm:
        for key in duplicate_scalar_keys(raw_fm):
            result.errors.append(f"duplicate front matter key: {key}")

    for key in REQUIRED_FM_KEYS:
        if key not in fm and key != "issue":
            result.errors.append(f"front matter missing field: {key}")
    if "issue" not in fm and "issues" not in fm:
        result.errors.append("front matter must include issue or issues")

    for field_name, allowed in (("complexity", COMPLEXITY), ("risk", RISK)):
        val = fm.get(field_name)
        if val is not None and val not in allowed:
            result.errors.append(
                f"front matter {field_name} must be one of {sorted(allowed)} (got {val!r})"
            )

    if raw_fm and "title:" in raw_fm:
        for line in raw_fm.splitlines():
            if line.startswith("title:"):
                val = line.split(":", 1)[1].strip()
                if val and val[0] not in "'\"[{&" and ": " in val:
                    # Normalizer can fix this; still flag so authors quote titles.
                    result.errors.append(
                        "front matter title contains ': ' without quotes; "
                        "quote the title or use factory_spec_front_matter normalization"
                    )
                break

    title = fm.get("title")
    if title is not None and not str(title).strip():
        result.errors.append("front matter title must be non-empty")


def check_sections(body: str, result: LintResult) -> None:
    headings = extract_headings(body)
    if GOAL_HEADING not in headings and CONTEXT_HEADING not in headings:
        result.errors.append(f"missing required section: ## {GOAL_HEADING} or ## {CONTEXT_HEADING}")

    for label in (FILES_HEADING, BAD_INPUTS_HEADING, VERIFICATION_HEADING):
        if label not in headings:
            result.errors.append(f"missing required section heading: {label}")
            continue
        if not re.search(r"\S", section(body, label)):
            result.errors.append(f"{label} section is empty")


def block_has_pipefail(block: str) -> bool:
    return bool(re.search(r"\bpipefail\b", block))


def check_verification_safety(body: str, result: LintResult) -> None:
    block = verification_bash_block(body)
    if not block.strip():
        return
    has_pf = block_has_pipefail(block)
    for n, line in enumerate(block.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if MASK_PIPE_RE.search(line):
            if not has_pf:
                result.errors.append(
                    f"verification masks output with a pipe on line {n} "
                    f"({stripped!r}) without pipefail in the bash block"
                )
            else:
                result.errors.append(
                    f"verification must not pipe test output through "
                    f"head/tail/sed/grep/awk (line {n}: {stripped!r})"
                )
    if PYTEST_DBT_MASK_RE.search(block):
        result.errors.append(
            "verification pytest/dbt command may mask a non-zero exit (|| true, ; true, or similar)"
        )
    if re.search(r"(?:^|[;&|\s])(pytest|dbt)\b", block, re.I) and not has_pf:
        if "|" in block and MASK_PIPE_RE.search(block):
            pass  # already reported
        elif re.search(r"\|\s*grep\b", block, re.I):
            result.errors.append(
                "verification runs pytest/dbt in a pipeline without pipefail in the bash block"
            )


def check_path_policy(
    body: str,
    mode: Mode,
    result: LintResult,
    base_scripts: Path | None,
) -> None:
    base_args = ["--base-scripts", str(base_scripts)] if base_scripts else []
    for intent, path in files_section_paths(section(body, FILES_HEADING)):
        if mode == "product" and path.startswith("scripts/") and intent in (
            "create",
            "modify",
        ):
            result.errors.append(
                f"spec Files path policy (product mode): workers must not list scripts/ "
                f"paths ({path!r}); factory scripts belong in the template repo"
            )
            continue
        r = subprocess.run(
            [
                "bash",
                str(ARTIFACT_SCAN),
                *base_args,
                "--check-spec-path",
                intent,
                path,
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        if r.returncode == 0:
            continue
        msg = (r.stderr or r.stdout or "").strip()
        line = msg.splitlines()[-1] if msg else ""
        if line.startswith("spec Files path policy:"):
            result.errors.append(line)
        else:
            result.errors.append(f"spec Files path policy: {path} ({line or 'blocked'})")


def check_sanity(
    body: str,
    fm: dict[str, Any] | None,
    protected: frozenset[str],
    result: LintResult,
) -> None:
    if fm is None or "__yaml_error__" in fm:
        return
    paths = [p for _, p in files_section_paths(section(body, FILES_HEADING))]
    if fm.get("complexity") == "simple" and len(paths) > 5:
        result.warnings.append(
            f"complexity is simple but ## Files lists {len(paths)} paths (>5)"
        )
    if fm.get("risk") == "trivial":
        for p in paths:
            if p in protected:
                result.warnings.append(
                    f"risk is trivial but ## Files touches protected spend/security script: {p}"
                )
            elif SECURITY_PATH_HINTS.search(p):
                result.warnings.append(
                    f"risk is trivial but ## Files touches a security/spend-sensitive path: {p}"
                )


def lint_text(
    text: str,
    *,
    source: Path | None,
    mode: Mode,
    base_scripts: Path | None,
    protected: frozenset[str],
) -> LintResult:
    result = LintResult(path=str(source or "<text>"))
    fm, body, raw_fm = split_front_matter(strip_marker(text))
    check_front_matter(fm, raw_fm, result)
    fm_ok = (
        fm
        if fm and "__yaml_error__" not in fm and "__fm_incomplete__" not in fm
        else None
    )
    check_sections(body, result)
    if not any(e.startswith("missing required section heading: Verification") for e in result.errors):
        check_verification_safety(body, result)
    if FILES_HEADING in extract_headings(body):
        check_path_policy(body, mode, result, base_scripts)
    check_sanity(body, fm_ok, protected, result)
    return result


def load_file(path: Path) -> tuple[str | None, str | None]:
    try:
        return path.read_text(encoding="utf-8"), None
    except UnicodeDecodeError:
        return None, "spec file is not valid UTF-8 (binary or wrong encoding)"


def emit_human(results: list[LintResult]) -> None:
    for res in results:
        if res.ok and not res.warnings:
            print(f"OK {res.path}")
            continue
        print(f"LINT {res.path}", file=sys.stderr)
        for err in res.errors:
            print(f"  error: {err}", file=sys.stderr)
        for warn in res.warnings:
            print(f"  warning: {warn}", file=sys.stderr)


def emit_json(results: list[LintResult]) -> None:
    payload = {
      "results": [
          {
              "path": r.path,
              "ok": r.ok,
              "errors": r.errors,
              "warnings": r.warnings,
          }
          for r in results
      ],
      "summary": {
          "files": len(results),
          "failed": sum(1 for r in results if not r.ok),
          "warnings": sum(len(r.warnings) for r in results),
      },
    }
    print(json.dumps(payload, indent=2, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser(description="Lint factory spec markdown for quality gates.")
    parser.add_argument("paths", type=Path, nargs="+", help="Spec file(s)")
    parser.add_argument(
        "--mode",
        choices=("template", "product", "auto"),
        default="auto",
        help="template vs product path policy (auto reads .factory/mode.yml)",
    )
    parser.add_argument("--json", action="store_true", help="Print JSON results on stdout")
    parser.add_argument(
        "--strict",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Exit 1 when any file has errors (default: true)",
    )
    parser.add_argument(
        "--base-scripts",
        type=Path,
        help="File listing scripts/ on the base branch (same as factory-spec-check)",
    )
    args = parser.parse_args()

    if not args.paths:
        print("need at least one spec path", file=sys.stderr)
        return 2

    if args.base_scripts is not None and not args.base_scripts.is_file():
        print(f"not a file: {args.base_scripts}", file=sys.stderr)
        return 2

    mode = resolve_mode(args.mode)
    protected = load_protected_scripts()
    results: list[LintResult] = []

    for path in args.paths:
        if not path.is_file():
            results.append(
                LintResult(path=str(path), errors=[f"not a file: {path}"])
            )
            continue
        text, read_err = load_file(path)
        if read_err:
            results.append(LintResult(path=str(path.resolve()), errors=[read_err]))
            continue
        results.append(
            lint_text(
                text,  # type: ignore[arg-type]
                source=path.resolve(),
                mode=mode,
                base_scripts=args.base_scripts,
                protected=protected,
            )
        )

    if args.json:
        emit_json(results)
    else:
        emit_human(results)

    has_errors = any(not r.ok for r in results)
    if has_errors and args.strict:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())