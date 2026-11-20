#!/usr/bin/env python3
"""Release-readiness scorecard and changelog draft helper (read-only by default).

Validates semver, CHANGELOG.md, and git state; composes factory-doctor and
reusable-workflow checks when those scripts exist. Never tags or pushes.
Refs #181, #178, #156.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

SEMVER_TAG_RE = re.compile(r"^v(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)$")
CHANGELOG_HEADING = re.compile(r"^##\s+\[(?P<label>[^\]]+)\]\s*$", re.MULTILINE)
COMMIT_GROUP = (
    ("Added", re.compile(r"^(feat(\([^)]+\))?!?|add)\b", re.I)),
    ("Fixed", re.compile(r"^fix(\([^)]+\))?!?\b", re.I)),
    ("Changed", re.compile(r"^(chore|refactor|style|perf|build|ci)(\([^)]+\))?!?\b", re.I)),
    ("Docs", re.compile(r"^docs(\([^)]+\))?!?\b", re.I)),
)


@dataclass
class Check:
    id: str
    category: str
    status: str  # pass | warn | fail | skip
    detail: str
    extra: dict[str, Any] = field(default_factory=dict)


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parent.parent


def parse_semver_tag(version: str) -> tuple[bool, str | None]:
    m = SEMVER_TAG_RE.match(version.strip())
    if not m:
        return False, None
    return True, f"{m.group('major')}.{m.group('minor')}.{m.group('patch')}"


def run_git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def git_is_repo(repo: Path) -> bool:
    proc = run_git(repo, "rev-parse", "--git-dir")
    return proc.returncode == 0


def git_branch(repo: Path) -> str | None:
    proc = run_git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def git_clean(repo: Path) -> bool:
    proc = run_git(repo, "status", "--porcelain")
    if proc.returncode != 0:
        return False
    return proc.stdout.strip() == ""


def tag_exists(repo: Path, version: str) -> bool:
    proc = run_git(repo, "rev-parse", "-q", "--verify", f"refs/tags/{version}")
    return proc.returncode == 0


def latest_tag(repo: Path) -> str | None:
    proc = run_git(repo, "describe", "--tags", "--abbrev=0")
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def read_changelog(repo: Path) -> str | None:
    path = repo / "CHANGELOG.md"
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return None


def section_body(changelog: str, label: str) -> str | None:
    """Return markdown body under ## [label] until the next ## heading."""
    pattern = re.compile(
        rf"^##\s+\[{re.escape(label)}\]\s*$(.*?)(?=^##\s+\[|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    m = pattern.search(changelog)
    if not m:
        return None
    body = m.group(1).strip()
    return body if body else None


def changelog_has_section(repo: Path, version: str) -> Check:
    bare = version.lstrip("v")
    text = read_changelog(repo)
    if text is None:
        return Check(
            id="changelog_present",
            category="changelog",
            status="fail",
            detail="CHANGELOG.md missing or unreadable",
        )
    for label in (bare, "Unreleased"):
        body = section_body(text, label)
        if body:
            return Check(
                id="changelog_section",
                category="changelog",
                status="pass",
                detail=f"non-empty ## [{label}] section in CHANGELOG.md",
                extra={"section": label},
            )
    return Check(
        id="changelog_section",
        category="changelog",
        status="fail",
        detail=f"CHANGELOG.md needs non-empty ## [{bare}] or ## [Unreleased]",
    )


def check_semver(version: str) -> Check:
    ok, bare = parse_semver_tag(version)
    if ok:
        return Check(
            id="semver_tag",
            category="version",
            status="pass",
            detail=f"version {version!r} matches vMAJOR.MINOR.PATCH",
            extra={"bare": bare},
        )
    return Check(
        id="semver_tag",
        category="version",
        status="fail",
        detail=f"version {version!r} is not vMAJOR.MINOR.PATCH (example: v0.1.0)",
    )


def check_git_state(repo: Path, version: str) -> list[Check]:
    checks: list[Check] = []
    if not git_is_repo(repo):
        checks.append(
            Check(
                id="git_repo",
                category="git",
                status="fail",
                detail=f"{repo} is not a git repository",
            )
        )
        return checks
    checks.append(
        Check(
            id="git_repo",
            category="git",
            status="pass",
            detail="git repository detected",
        )
    )
    branch = git_branch(repo)
    if branch:
        checks.append(
            Check(
                id="git_branch",
                category="git",
                status="pass",
                detail=f"current branch is {branch!r}",
                extra={"branch": branch},
            )
        )
    else:
        checks.append(
            Check(
                id="git_branch",
                category="git",
                status="fail",
                detail="could not determine current branch",
            )
        )
    if git_clean(repo):
        checks.append(
            Check(
                id="git_clean",
                category="git",
                status="pass",
                detail="working tree is clean",
            )
        )
    else:
        checks.append(
            Check(
                id="git_clean",
                category="git",
                status="fail",
                detail="working tree has uncommitted changes",
            )
        )
    if tag_exists(repo, version):
        checks.append(
            Check(
                id="tag_duplicate",
                category="git",
                status="fail",
                detail=f"tag {version!r} already exists locally",
            )
        )
    else:
        checks.append(
            Check(
                id="tag_duplicate",
                category="git",
                status="pass",
                detail=f"tag {version!r} is not present yet",
            )
        )
    return checks


def run_doctor_json(repo: Path) -> dict[str, Any] | None:
    script = repo / "scripts" / "factory-doctor.py"
    if not script.is_file():
        return None
    try:
        proc = subprocess.run(
            [sys.executable, str(script), "--repo-dir", str(repo), "--json"],
            capture_output=True,
            text=True,
            cwd=repo,
            check=False,
        )
        if proc.returncode not in (0, 1):
            return {"error": proc.stderr.strip() or f"exit {proc.returncode}"}
        return json.loads(proc.stdout)
    except (OSError, json.JSONDecodeError) as exc:
        return {"error": str(exc)}


def doctor_to_checks(payload: dict[str, Any] | None) -> list[Check]:
    if payload is None:
        return [
            Check(
                id="factory_doctor",
                category="compose",
                status="skip",
                detail="scripts/factory-doctor.py not present",
            )
        ]
    if "error" in payload:
        return [
            Check(
                id="factory_doctor",
                category="compose",
                status="fail",
                detail=f"factory-doctor --json failed: {payload['error']}",
            )
        ]
    summary = payload.get("summary") or {}
    fails = int(summary.get("fail", 0))
    status = "pass" if fails == 0 else "fail"
    return [
        Check(
            id="factory_doctor",
            category="compose",
            status=status,
            detail=(
                f"factory-doctor: {summary.get('pass', 0)} pass, "
                f"{summary.get('warn', 0)} warn, {fails} fail"
            ),
            extra={"doctor": payload},
        )
    ]


def run_reusable_workflows(repo: Path) -> Check:
    script = repo / "scripts" / "test-reusable-workflows.sh"
    if not script.is_file():
        return Check(
            id="reusable_workflows",
            category="compose",
            status="skip",
            detail="scripts/test-reusable-workflows.sh not present",
        )
    try:
        proc = subprocess.run(
            ["bash", str(script)],
            capture_output=True,
            text=True,
            cwd=repo,
            check=False,
        )
    except OSError as exc:
        return Check(
            id="reusable_workflows",
            category="compose",
            status="fail",
            detail=f"test-reusable-workflows.sh could not run: {exc}",
        )
    tail = (proc.stdout + proc.stderr).strip().splitlines()
    snippet = tail[-1] if tail else f"exit {proc.returncode}"
    if proc.returncode == 0:
        return Check(
            id="reusable_workflows",
            category="compose",
            status="pass",
            detail=f"reusable workflows: {snippet[:240]}",
        )
    return Check(
        id="reusable_workflows",
        category="compose",
        status="fail",
        detail=f"reusable workflows failed (exit {proc.returncode}): {snippet[:240]}",
    )


def bucket_commit(title: str) -> str:
    for name, pattern in COMMIT_GROUP:
        if pattern.search(title.strip()):
            return name
    return "Changed"


def draft_changelog_section(repo: Path, version: str) -> str:
    ok, bare = parse_semver_tag(version)
    label = bare if ok and bare else version.lstrip("v")
    prev = latest_tag(repo)
    if prev and git_is_repo(repo):
        proc = run_git(
            repo,
            "log",
            f"{prev}..HEAD",
            "--pretty=format:%s",
        )
    elif git_is_repo(repo):
        proc = run_git(repo, "log", "--pretty=format:%s")
    else:
        proc = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
    titles = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    groups: dict[str, list[str]] = {}
    for title in titles:
        section = bucket_commit(title)
        groups.setdefault(section, []).append(title)
    lines = [f"## [{label}]", ""]
    order = ["Added", "Fixed", "Changed", "Docs"]
    seen = False
    for section in order:
        items = groups.get(section)
        if not items:
            continue
        seen = True
        lines.append(f"### {section}")
        lines.append("")
        for title in items:
            lines.append(f"- {title}")
        lines.append("")
    if not seen:
        lines.extend(["### Changed", "", "_No commits since previous tag._", ""])
    return "\n".join(lines).rstrip() + "\n"


def release_commands(version: str) -> list[str]:
    bare_notes = f"CHANGELOG section for {version}"
    return [
        f"git tag -a {version} -m \"Release {version}\"",
        f"git push origin {version}",
        f"gh release create {version} --title {version} --notes \"<{bare_notes}>\"",
        f"python3 scripts/factory-sync-repos.py --tag {version} --dry-run",
    ]


def summarize(checks: list[Check]) -> dict[str, int]:
    counts = {"pass": 0, "warn": 0, "fail": 0, "skip": 0}
    for c in checks:
        counts[c.status] = counts.get(c.status, 0) + 1
    return counts


def exit_code(checks: list[Check], strict: bool) -> int:
    if not strict:
        return 0
    return 1 if any(c.status == "fail" for c in checks) else 0


def render_markdown(
    repo: Path,
    version: str,
    checks: list[Check],
    draft: str | None,
    commands: list[str],
) -> str:
    summary = summarize(checks)
    lines = [
        "# Factory release readiness",
        "",
        f"Repo: `{repo.resolve()}`",
        f"Version: `{version}`",
        "",
        f"Summary: {summary['pass']} pass, {summary['warn']} warn, "
        f"{summary['fail']} fail, {summary['skip']} skip",
        "",
        "| Status | Category | Check | Detail |",
        "| --- | --- | --- | --- |",
    ]
    for c in checks:
        lines.append(f"| {c.status.upper()} | {c.category} | `{c.id}` | {c.detail} |")
    lines.extend(["", "## Owner release commands (you run these; this tool does not)", ""])
    for cmd in commands:
        lines.append(f"```bash\n{cmd}\n```")
    if draft:
        lines.extend(["", "## Draft changelog (since previous tag)", "", draft.rstrip(), ""])
    lines.append("")
    return "\n".join(lines)


def build_checks(repo: Path, version: str) -> list[Check]:
    checks: list[Check] = []
    semver = check_semver(version)
    checks.append(semver)
    if semver.status == "pass":
        checks.append(changelog_has_section(repo, version))
        checks.extend(check_git_state(repo, version))
        doctor_payload = run_doctor_json(repo)
        checks.extend(doctor_to_checks(doctor_payload))
        checks.append(run_reusable_workflows(repo))
    return checks


def to_json_payload(
    repo: Path,
    version: str,
    checks: list[Check],
    draft: str | None,
    commands: list[str],
) -> dict[str, Any]:
    ok, bare = parse_semver_tag(version)
    payload: dict[str, Any] = {
        "repo_dir": str(repo.resolve()),
        "version": version,
        "semver_ok": ok,
        "bare_version": bare,
        "summary": summarize(checks),
        "checks": [asdict(c) for c in checks],
        "git": {
            "branch": git_branch(repo) if git_is_repo(repo) else None,
            "clean": git_clean(repo) if git_is_repo(repo) else None,
            "last_tag": latest_tag(repo) if git_is_repo(repo) else None,
            "tag_exists": tag_exists(repo, version) if git_is_repo(repo) else None,
        },
        "release_commands": commands,
    }
    if draft is not None:
        payload["draft_changelog"] = draft
    return payload


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--version", required=True, help="Semver tag to validate (e.g. v0.1.0)")
    ap.add_argument(
        "--repo-dir",
        type=Path,
        default=None,
        help="Repository root (default: parent of scripts/)",
    )
    ap.add_argument(
        "--draft-changelog",
        action="store_true",
        help="Print a Keep a Changelog section from commits since the last tag",
    )
    ap.add_argument("--json", action="store_true", help="Emit JSON scorecard on stdout")
    ap.add_argument("--strict", action="store_true", help="Exit 1 when any check fails")
    args = ap.parse_args()
    repo = (args.repo_dir or repo_root_from_script()).resolve()
    if not repo.is_dir():
        print(f"factory-release: not a directory: {repo}", file=sys.stderr)
        return 2

    version = args.version.strip()
    checks = build_checks(repo, version)
    draft = draft_changelog_section(repo, version) if args.draft_changelog else None
    commands = release_commands(version)
    payload = to_json_payload(repo, version, checks, draft, commands)

    if args.json:
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print(render_markdown(repo, version, checks, draft, commands))

    return exit_code(checks, args.strict)


if __name__ == "__main__":
    sys.exit(main())