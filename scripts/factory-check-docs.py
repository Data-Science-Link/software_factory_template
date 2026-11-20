#!/usr/bin/env python3
"""Offline audit: Markdown relative links, heading anchors, and script references."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import unicodedata
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Iterable
from urllib.parse import unquote

MARKDOWN_LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
BACKTICK_SCRIPT = re.compile(r"`(scripts/[A-Za-z0-9_./*-]+\.(?:sh|py))`")

EXCLUDE_PREFIXES = (
    "tests/",
    "factory/runs/",
    "node_modules/",
    ".git/",
)

# Approved specs under factory/specs/ are historical snapshots; script names may be obsolete.
HISTORICAL_SPEC_PREFIX = "factory/specs/"


def is_historical_spec(rel_path: str) -> bool:
    return rel_path.startswith(HISTORICAL_SPEC_PREFIX) and rel_path.endswith(".md")

PLACEHOLDER_SCRIPTS = (
    re.compile(r"^scripts/test-N\.sh$", re.I),
    re.compile(r"^scripts/foo\.sh$", re.I),
)

SKIP_LINK_SCHEMES = ("http:", "https:", "mailto:", "data:", "tel:", "javascript:", "ftp:")


@dataclass
class Finding:
    kind: str  # broken_link | broken_anchor | missing_script
    severity: str  # error | warning
    file: str
    detail: str
    ref: str = ""


@dataclass
class Report:
    repo_dir: str
    files_scanned: int = 0
    links_checked: int = 0
    anchors_checked: int = 0
    script_refs_checked: int = 0
    findings: list[Finding] = field(default_factory=list)

    @property
    def broken_links(self) -> list[Finding]:
        return [f for f in self.findings if f.kind in ("broken_link", "broken_anchor")]

    def to_json(self) -> dict:
        data = asdict(self)
        data["summary"] = {
            "errors": sum(1 for f in self.findings if f.severity == "error"),
            "warnings": sum(1 for f in self.findings if f.severity == "warning"),
            "broken_links": len(self.broken_links),
        }
        return data


def _git_toplevel(repo: Path) -> Path | None:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(repo), "rev-parse", "--show-toplevel"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        return Path(out).resolve()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def list_tracked_markdown(repo: Path) -> list[Path]:
    repo = repo.resolve()
    top = _git_toplevel(repo)
    if top is not None and top == repo:
        try:
            out = subprocess.check_output(
                ["git", "-C", str(repo), "ls-files", "--", "*.md"],
                text=True,
                stderr=subprocess.DEVNULL,
            )
        except (subprocess.CalledProcessError, FileNotFoundError):
            out = ""
        paths: list[Path] = []
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            p = repo / line
            if _excluded(repo, p):
                continue
            if p.is_file():
                paths.append(p)
        if paths:
            return sorted(paths)
    return sorted(
        p for p in repo.rglob("*.md") if p.is_file() and not _excluded(repo, p)
    )


def _excluded(repo: Path, path: Path) -> bool:
    try:
        rel = path.relative_to(repo).as_posix()
    except ValueError:
        return True
    return any(rel == pfx.rstrip("/") or rel.startswith(pfx) for pfx in EXCLUDE_PREFIXES)


def is_external_link(target: str) -> bool:
    t = target.strip()
    if not t:
        return True
    if t.startswith("#"):
        return False
    if t.startswith("//"):
        return True
    lower = t.lower()
    return any(lower.startswith(s) for s in SKIP_LINK_SCHEMES)


def split_link_target(target: str) -> tuple[str | None, str | None]:
    """Return (path_part, anchor) where path_part None means same-file anchor only."""
    t = target.strip()
    if not t:
        return (None, None)
    if t.startswith("#"):
        return (None, unquote(t[1:].split("?", 1)[0]) or None)
    if "#" in t:
        path_part, _, anchor = t.partition("#")
        anchor = unquote(anchor.split("?", 1)[0])
        path_part = path_part.split("?", 1)[0]
        return (path_part or None, anchor or None)
    path_part = t.split("?", 1)[0]
    return (path_part, None)


def resolve_path(repo: Path, source: Path, path_part: str) -> Path:
    path_part = unquote(path_part.strip())
    if path_part.startswith("/"):
        return (repo / path_part.lstrip("/")).resolve()
    base = source.parent
    return (base / path_part).resolve()


def github_slug(text: str) -> str:
    """GitHub-compatible heading anchor slug (heading text only, no duplicates)."""
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = text.strip().lower()
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"[*_`~]", "", text)
    text = re.sub(r"[^\w\s-]", "", text, flags=re.UNICODE)
    text = re.sub(r"\s+", "-", text.strip())
    text = re.sub(r"-+", "-", text)
    return text.strip("-")


def slug_set_for_file(body: str) -> set[str]:
    """All anchor ids reachable in a Markdown file (GitHub duplicate rules)."""
    seen: dict[str, int] = {}
    anchors: set[str] = set()
    for line in body.splitlines():
        m = re.match(r"^(#{1,6})\s+(.+?)\s*$", line)
        if not m:
            continue
        raw = m.group(2).strip()
        raw = re.sub(r"\s+#+\s*$", "", raw)
        slug = github_slug(raw)
        if not slug:
            continue
        count = seen.get(slug, 0)
        if count == 0:
            anchors.add(slug)
        else:
            anchors.add(f"{slug}-{count}")
        seen[slug] = count + 1
    return anchors


def path_exists_as_link(target: Path) -> bool:
    return target.exists()


def is_placeholder_script(ref: str) -> bool:
    if "*" in ref:
        return True
    for pat in PLACEHOLDER_SCRIPTS:
        if pat.match(ref):
            return True
    if re.match(r"^scripts/test-<name>\.sh$", ref, re.I):
        return True
    if re.match(r"^scripts/test-\*\.sh$", ref):
        return True
    return False


def scan_file(
    repo: Path,
    md_path: Path,
    report: Report,
    *,
    check_scripts: bool,
    include_historical_specs: bool,
) -> None:
    rel = md_path.relative_to(repo).as_posix()
    try:
        body = md_path.read_text(encoding="utf-8")
    except OSError as e:
        report.findings.append(
            Finding(
                kind="broken_link",
                severity="error",
                file=rel,
                detail=f"cannot read file: {e}",
                ref="",
            )
        )
        return

    local_anchors = slug_set_for_file(body)

    for match in MARKDOWN_LINK.finditer(body):
        raw_target = match.group(1).strip()
        if is_external_link(raw_target):
            continue
        if raw_target.startswith("<") and raw_target.endswith(">"):
            raw_target = raw_target[1:-1].strip()
        report.links_checked += 1
        path_part, anchor = split_link_target(raw_target)
        if path_part is None:
            if anchor:
                report.anchors_checked += 1
                if anchor not in local_anchors:
                    report.findings.append(
                        Finding(
                            kind="broken_anchor",
                            severity="error",
                            file=rel,
                            detail=f"heading anchor #{anchor} not found in same file",
                            ref=raw_target,
                        )
                    )
            continue

        if not path_part:
            continue

        resolved = resolve_path(repo, md_path, path_part)
        if not path_exists_as_link(resolved):
            report.findings.append(
                Finding(
                    kind="broken_link",
                    severity="error",
                    file=rel,
                    detail=f"target does not exist: {path_part}",
                    ref=raw_target,
                )
            )
            continue

        if anchor and resolved.suffix.lower() == ".md" and resolved.is_file():
            report.anchors_checked += 1
            try:
                target_body = resolved.read_text(encoding="utf-8")
            except OSError:
                report.findings.append(
                    Finding(
                        kind="broken_anchor",
                        severity="error",
                        file=rel,
                        detail=f"cannot read target for anchor: {path_part}",
                        ref=raw_target,
                    )
                )
                continue
            target_anchors = slug_set_for_file(target_body)
            if anchor not in target_anchors:
                report.findings.append(
                    Finding(
                        kind="broken_anchor",
                        severity="error",
                        file=rel,
                        detail=f"heading anchor #{anchor} not found in {path_part}",
                        ref=raw_target,
                    )
                )

    if check_scripts:
        skip_orphan_scripts = is_historical_spec(rel) and not include_historical_specs
        for match in BACKTICK_SCRIPT.finditer(body):
            ref = match.group(1).strip()
            report.script_refs_checked += 1
            if is_placeholder_script(ref):
                continue
            script_path = repo / ref
            if not script_path.is_file():
                if skip_orphan_scripts:
                    continue
                report.findings.append(
                    Finding(
                        kind="missing_script",
                        severity="warning",
                        file=rel,
                        detail=f"referenced script not on disk: {ref}",
                        ref=ref,
                    )
                )


def run_audit(
    repo: Path,
    *,
    check_scripts: bool = True,
    include_historical_specs: bool = False,
) -> Report:
    report = Report(repo_dir=str(repo.resolve()))
    files = list_tracked_markdown(repo)
    report.files_scanned = len(files)
    for md in files:
        scan_file(
            repo,
            md,
            report,
            check_scripts=check_scripts,
            include_historical_specs=include_historical_specs,
        )
    return report


def print_text_report(report: Report) -> None:
    print(f"# Factory docs check\n")
    print(f"Repository: `{report.repo_dir}`")
    print(f"Markdown files scanned: {report.files_scanned}")
    print(f"Relative links checked: {report.links_checked}")
    print(f"Heading anchors checked: {report.anchors_checked}")
    if report.script_refs_checked:
        print(f"Script backtick references checked: {report.script_refs_checked}")
    errors = [f for f in report.findings if f.severity == "error"]
    warnings = [f for f in report.findings if f.severity == "warning"]
    print()
    if not report.findings:
        print("No broken links or missing script references found.")
        return
    if errors:
        print(f"## Errors ({len(errors)})\n")
        for f in errors:
            print(f"- **{f.file}** — {f.detail}" + (f" (`{f.ref}`)" if f.ref else ""))
    if warnings:
        print(f"\n## Warnings ({len(warnings)})\n")
        for f in warnings:
            print(f"- **{f.file}** — {f.detail}" + (f" (`{f.ref}`)" if f.ref else ""))


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-dir",
        type=Path,
        default=Path("."),
        help="Repository root (default: current directory)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print JSON report on stdout",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit 1 on any error, warning, or broken link/anchor finding",
    )
    parser.add_argument(
        "--no-script-refs",
        action="store_true",
        help="Skip backticked scripts/*.sh|py reference checks",
    )
    parser.add_argument(
        "--include-historical-specs",
        action="store_true",
        help=(
            "Also warn on missing script refs in factory/specs/issue-*.md "
            "(historical spec snapshots; default is to skip orphan-script warnings there)"
        ),
    )
    args = parser.parse_args(list(argv) if argv is not None else None)
    repo = args.repo_dir.resolve()
    if not repo.is_dir():
        print(f"error: not a directory: {repo}", file=sys.stderr)
        return 2

    report = run_audit(
        repo,
        check_scripts=not args.no_script_refs,
        include_historical_specs=args.include_historical_specs,
    )

    if args.json:
        print(json.dumps(report.to_json(), indent=2, sort_keys=True))
    else:
        print_text_report(report)

    if args.strict and report.findings:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())