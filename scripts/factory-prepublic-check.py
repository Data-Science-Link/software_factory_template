#!/usr/bin/env python3
"""Scan tracked files before flipping a template/factory repo public.

Offline, read-only. Lists personal/private references, token-like strings, and
missing baseline files (LICENSE, SECURITY.md). Path allowlists skip historical
records and test fixtures by default.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
MAX_BYTES = 2_000_000
BINARY_SNIP = 8000

DEFAULT_ALLOW_PATHS = [
    "LICENSE",
    "LICENSE.*",
    ".factory/DECISIONS.md",
    "CHANGELOG.md",
    "factory/runs/**",
    "tests/**",
    "scripts/test-*.sh",
]

DEFAULT_PRIVATE_REPO_NAMES = ("perspectiverse",)

EMAIL_RE = re.compile(
    r"(?<![A-Za-z0-9_])"
    r"[A-Za-z0-9._%+-]+@"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+"
)

TOKEN_RES = [
    re.compile(p)
    for p in (
        r"ghs_[A-Za-z0-9]{20,}",
        r"ghp_[A-Za-z0-9]{20,}",
        r"github_pat_[A-Za-z0-9_]{20,}",
        r"Bearer[ \t]+[A-Za-z0-9._-]{10,}",
        r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.",
        r"sk-[A-Za-z0-9]{20,}",
        r"AKIA[0-9A-Z]{16}",
    )
]

GH_REPO_RE = re.compile(
    r"https?://github\.com/([^/\s\"')]+)/([^/\s\"')]+)",
    re.I,
)
HOME_PATH_RE = re.compile(
    r"(?:/Users/[A-Za-z][^\s\"']+|/home/(?!runner(?:/|\b)|ubuntu(?:/|\b)|ci(?:/|\b))[A-Za-z][^\s\"']+)"
)
ACTION_VERSION_AT = re.compile(r"\.ya?ml@v\d", re.I)

ALLOW_EMAIL_SUFFIXES = (
    "@users.noreply.github.com",
    "@example.com",
    "@example.invalid",
    "@b.example",
    "@test",
)
ALLOW_EMAIL_LOCALS = (
    "41898282+github-actions[bot]@users.noreply.github.com",
    "oc-verify@invalid",
    "policy-test@example.invalid",
    "test@test",
    "you@example.com",
)


@dataclass
class Finding:
    kind: str
    path: str
    detail: str
    line: int | None = None

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {"kind": self.kind, "path": self.path, "detail": self.detail}
        if self.line is not None:
            out["line"] = self.line
        return out


@dataclass
class Report:
    root: str
    scanned_files: int = 0
    skipped_allowlisted: int = 0
    findings: list[Finding] = field(default_factory=list)


def git_tracked(root: Path) -> list[str]:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(root), "ls-files", "-z"],
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    paths: list[str] = []
    for raw in out.split(b"\0"):
        if not raw:
            continue
        paths.append(raw.decode("utf-8", errors="replace"))
    return paths


def path_allowed(rel: str, patterns: list[str]) -> bool:
    for pat in patterns:
        if pat.endswith("/**"):
            if rel == pat[:-3] or rel.startswith(pat[:-2]):
                return True
        elif fnmatch.fnmatch(rel, pat):
            return True
    return False


def email_allowed(addr: str) -> bool:
    low = addr.lower()
    if low in {e.lower() for e in ALLOW_EMAIL_LOCALS}:
        return True
    if low.endswith("noreply.github.com"):
        return True
    for suffix in ALLOW_EMAIL_SUFFIXES:
        if low.endswith(suffix):
            return True
    return False


def repo_slug_from_remote(url: str) -> str | None:
    url = url.strip()
    for prefix in (
        "git@github.com:",
        "https://github.com/",
        "http://github.com/",
    ):
        if url.startswith(prefix):
            rest = url[len(prefix) :].removesuffix(".git")
            if "/" in rest:
                return rest.lower()
    return None


def github_repo_allowed(
    owner: str, repo: str, self_slug: str | None, private_names: frozenset[str]
) -> bool:
    slug = f"{owner}/{repo}".lower()
    if self_slug and slug == self_slug:
        return True
    if repo.lower() in private_names:
        return False
    if owner.lower() == "data-science-link" and repo.lower() == "software_factory_template":
        return True
    return True


def redact_token(match: str) -> str:
    if len(match) <= 12:
        return "[token]"
    return match[:8] + "…"


def scan_text(
    rel: str,
    text: str,
    self_slug: str | None,
    private_names: frozenset[str],
    findings: list[Finding],
) -> None:
    for lineno, line in enumerate(text.splitlines(), start=1):
        for m in EMAIL_RE.finditer(line):
            addr = m.group(0)
            if ACTION_VERSION_AT.search(line[max(0, m.start() - 24) : m.end() + 4]):
                continue
            if not email_allowed(addr):
                findings.append(
                    Finding("private_email", rel, f"email address ({addr})", lineno)
                )
        for pat in TOKEN_RES:
            tm = pat.search(line)
            if tm:
                findings.append(
                    Finding(
                        "token_pattern",
                        rel,
                        f"token-like string ({redact_token(tm.group(0))})",
                        lineno,
                    )
                )
                break
        for hm in GH_REPO_RE.finditer(line):
            owner, repo = hm.group(1), hm.group(2)
            repo = repo.removesuffix(".git").rstrip(".)]")
            if not github_repo_allowed(owner, repo, self_slug, private_names):
                findings.append(
                    Finding(
                        "private_repo_link",
                        rel,
                        f"github.com/{owner}/{repo}",
                        lineno,
                    )
                )
        for name in private_names:
            slug = f"/{name}"
            if slug in line.lower() and "github.com" in line.lower():
                if not any(
                    f.kind == "private_repo_link" and f.line == lineno for f in findings
                ):
                    findings.append(
                        Finding(
                            "private_repo_link",
                            rel,
                            f"reference to private repo {name}",
                            lineno,
                        )
                    )
        hm_path = HOME_PATH_RE.search(line)
        if hm_path:
            findings.append(
                Finding("home_path", rel, hm_path.group(0), lineno)
            )


def load_config(path: Path | None) -> dict[str, Any]:
    if path is None or not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def merge_allow_paths(base: list[str], extra: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for p in base + extra:
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out


def scan_repo(
    root: Path,
    allow_paths: list[str],
    private_names: frozenset[str],
    self_slug: str | None,
) -> Report:
    report = Report(root=str(root.resolve()))
    tracked = git_tracked(root)
    for rel in tracked:
        if path_allowed(rel, allow_paths):
            report.skipped_allowlisted += 1
            continue
        full = root / rel
        if not full.is_file():
            continue
        try:
            raw = full.read_bytes()
        except OSError:
            continue
        if len(raw) > MAX_BYTES:
            raw = raw[:BINARY_SNIP]
        if b"\0" in raw[:4096]:
            continue
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            continue
        report.scanned_files += 1
        scan_text(rel, text, self_slug, private_names, report.findings)

    for name in ("LICENSE", "SECURITY.md"):
        if not (root / name).is_file():
            report.findings.append(Finding("missing_file", name, f"missing {name} at repo root"))
    return report


def format_markdown(report: Report) -> str:
    lines = [
        "# Pre-public hygiene scan",
        "",
        f"- Root: `{report.root}`",
        f"- Files scanned: {report.scanned_files}",
        f"- Allowlisted (skipped): {report.skipped_allowlisted}",
        f"- Findings: {len(report.findings)}",
        "",
    ]
    if not report.findings:
        lines.append("No findings.")
        return "\n".join(lines) + "\n"
    lines.append("| Kind | Path | Line | Detail |")
    lines.append("| --- | --- | ---: | --- |")
    for f in report.findings:
        ln = str(f.line) if f.line is not None else ""
        lines.append(f"| {f.kind} | `{f.path}` | {ln} | {f.detail} |")
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "root",
        nargs="?",
        type=Path,
        default=ROOT,
        help="Repository root (default: parent of scripts/)",
    )
    ap.add_argument("--json", action="store_true", help="Print JSON report on stdout")
    ap.add_argument(
        "--strict",
        action="store_true",
        help="Exit 1 when any findings are present (default: report only, exit 0)",
    )
    ap.add_argument(
        "--config",
        type=Path,
        default=None,
        help="Optional JSON: allow_paths, private_repo_names, self_repo",
    )
    ap.add_argument(
        "--allow-path",
        action="append",
        default=[],
        dest="allow_paths_extra",
        help="Extra allowlist glob (repeatable)",
    )
    ap.add_argument(
        "--private-repo-name",
        action="append",
        default=[],
        dest="private_names_extra",
    )
    ap.add_argument(
        "--self-repo",
        default=None,
        help="owner/repo slug for this repo (default: parse origin remote)",
    )
    args = ap.parse_args()
    root = args.root.resolve()
    cfg = load_config(args.config)

    allow_paths = merge_allow_paths(
        DEFAULT_ALLOW_PATHS,
        list(cfg.get("allow_paths") or []) + args.allow_paths_extra,
    )
    private_list = list(DEFAULT_PRIVATE_REPO_NAMES) + list(cfg.get("private_repo_names") or [])
    private_list += args.private_names_extra
    private_names = frozenset(n.lower() for n in private_list if n)

    self_slug = args.self_repo or cfg.get("self_repo")
    if not self_slug:
        try:
            url = subprocess.check_output(
                ["git", "-C", str(root), "remote", "get-url", "origin"],
                stderr=subprocess.DEVNULL,
                text=True,
            ).strip()
            self_slug = repo_slug_from_remote(url)
        except (subprocess.CalledProcessError, FileNotFoundError):
            self_slug = None

    report = scan_repo(root, allow_paths, private_names, self_slug)

    if args.json:
        payload = {
            "root": report.root,
            "scanned_files": report.scanned_files,
            "skipped_allowlisted": report.skipped_allowlisted,
            "self_repo": self_slug,
            "finding_count": len(report.findings),
            "findings": [f.to_dict() for f in report.findings],
        }
        print(json.dumps(payload, indent=2))
    else:
        print(format_markdown(report), end="")

    if args.strict and report.findings:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())