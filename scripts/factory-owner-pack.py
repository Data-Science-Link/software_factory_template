#!/usr/bin/env python3
"""Unified owner launch-readiness gate: compose factory doctor, hygiene, docs, workflows,
site smoke, and optional release checks into one scorecard.

Read-only. Python 3 stdlib only. Refs #178, #184, #185, #56.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

SCRIPT_NAMES = (
    ("doctor", "factory-doctor.py"),
    ("prepublic", "factory-prepublic-check.py"),
    ("check_docs", "factory-check-docs.py"),
    ("audit_workflows", "factory-audit-workflows.py"),
    ("site_smoke", "factory-site-smoke.py"),
    ("release", "factory-release.py"),
)

GATE_LABELS = {
    "doctor": "Repo health (factory-doctor)",
    "prepublic": "Public hygiene (factory-prepublic-check)",
    "check_docs": "Doc links (factory-check-docs)",
    "audit_workflows": "Workflow drift (factory-audit-workflows)",
    "site_smoke": "Factory site smoke (factory-site-smoke)",
    "release": "Release readiness (factory-release)",
}


@dataclass
class GateRow:
    id: str
    label: str
    status: str  # PASS | WARN | FAIL | SKIP
    detail: str
    remediation: str = ""


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parent.parent


def script_path(repo: Path, name: str) -> Path:
    return repo / "scripts" / name


def run_subprocess(cmd: list[str], *, cwd: Path | None = None) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            cwd=str(cwd) if cwd else None,
            check=False,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except OSError as exc:
        return 127, "", str(exc)


def parse_json(stdout: str) -> dict[str, Any] | None:
    text = stdout.strip()
    if not text:
        return None
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def remediation_doctor(repo: Path) -> str:
    return f"python3 scripts/factory-doctor.py --repo-dir {repo} --strict"


def remediation_prepublic(repo: Path) -> str:
    return f"python3 scripts/factory-prepublic-check.py {repo} --strict"


def remediation_check_docs(repo: Path) -> str:
    return f"python3 scripts/factory-check-docs.py --repo-dir {repo} --strict"


def remediation_audit(repo: Path) -> str:
    wf = repo / ".github" / "workflows"
    return (
        f"python3 scripts/factory-audit-workflows.py --workflows-dir {wf} --strict"
    )


def remediation_site_smoke() -> str:
    return "python3 scripts/factory-site-smoke.py --build --strict"


def remediation_release(repo: Path, version: str | None) -> str:
    if not version:
        return "Re-run owner pack with --version vX.Y.Z"
    return (
        f"python3 scripts/factory-release.py --version {version} "
        f"--repo-dir {repo} --strict"
    )


def gate_doctor(repo: Path) -> GateRow:
    gid, label = "doctor", GATE_LABELS["doctor"]
    path = script_path(repo, "factory-doctor.py")
    if not path.is_file():
        return GateRow(
            gid,
            label,
            "SKIP",
            "factory-doctor.py not present",
            "",
        )
    cmd = [sys.executable, str(path), "--repo-dir", str(repo), "--json"]
    rc, out, err = run_subprocess(cmd, cwd=repo)
    payload = parse_json(out)
    if payload is None:
        detail = err.strip() or out.strip() or f"exit {rc}, invalid JSON"
        return GateRow(
            gid,
            label,
            "FAIL",
            detail[:500],
            remediation_doctor(repo),
        )
    summary = payload.get("summary") or {}
    fails = int(summary.get("fail") or 0)
    warns = int(summary.get("warn") or 0)
    if fails > 0:
        return GateRow(
            gid,
            label,
            "FAIL",
            f"{fails} failing check(s) in doctor scorecard",
            remediation_doctor(repo),
        )
    if warns > 0:
        return GateRow(
            gid,
            label,
            "WARN",
            f"{warns} warning(s) in doctor scorecard",
            remediation_doctor(repo),
        )
    return GateRow(gid, label, "PASS", "doctor scorecard clean", "")


def gate_prepublic(repo: Path) -> GateRow:
    gid, label = "prepublic", GATE_LABELS["prepublic"]
    path = script_path(repo, "factory-prepublic-check.py")
    if not path.is_file():
        return GateRow(gid, label, "SKIP", "factory-prepublic-check.py not present", "")
    cmd = [sys.executable, str(path), str(repo), "--json"]
    rc, out, err = run_subprocess(cmd, cwd=repo)
    payload = parse_json(out)
    if payload is None:
        detail = err.strip() or out.strip() or f"exit {rc}, invalid JSON"
        return GateRow(
            gid,
            label,
            "FAIL",
            detail[:500],
            remediation_prepublic(repo),
        )
    count = int(payload.get("finding_count") or 0)
    if count > 0:
        return GateRow(
            gid,
            label,
            "FAIL",
            f"{count} hygiene finding(s) before going public",
            remediation_prepublic(repo),
        )
    return GateRow(gid, label, "PASS", "no pre-public findings", "")


def gate_check_docs(repo: Path) -> GateRow:
    gid, label = "check_docs", GATE_LABELS["check_docs"]
    path = script_path(repo, "factory-check-docs.py")
    if not path.is_file():
        return GateRow(gid, label, "SKIP", "factory-check-docs.py not present", "")
    cmd = [sys.executable, str(path), "--repo-dir", str(repo), "--json"]
    rc, out, err = run_subprocess(cmd, cwd=repo)
    payload = parse_json(out)
    if payload is None:
        detail = err.strip() or out.strip() or f"exit {rc}, invalid JSON"
        return GateRow(
            gid,
            label,
            "FAIL",
            detail[:500],
            remediation_check_docs(repo),
        )
    summary = payload.get("summary") or {}
    errors = int(summary.get("errors") or 0)
    warnings = int(summary.get("warnings") or 0)
    broken = int(summary.get("broken_links") or 0)
    if errors > 0 or broken > 0:
        return GateRow(
            gid,
            label,
            "FAIL",
            f"{errors} doc error(s), {broken} broken link(s)/anchor(s)",
            remediation_check_docs(repo),
        )
    if warnings > 0:
        return GateRow(
            gid,
            label,
            "WARN",
            f"{warnings} doc warning(s) (e.g. missing script refs)",
            remediation_check_docs(repo),
        )
    return GateRow(gid, label, "PASS", "documentation links clean", "")


def gate_audit_workflows(repo: Path) -> GateRow:
    gid, label = "audit_workflows", GATE_LABELS["audit_workflows"]
    path = script_path(repo, "factory-audit-workflows.py")
    if not path.is_file():
        return GateRow(gid, label, "SKIP", "factory-audit-workflows.py not present", "")
    wf = repo / ".github" / "workflows"
    cmd = [
        sys.executable,
        str(path),
        "--workflows-dir",
        str(wf),
        "--json",
    ]
    rc, out, err = run_subprocess(cmd, cwd=repo)
    payload = parse_json(out)
    if payload is None:
        detail = err.strip() or out.strip() or f"exit {rc}, invalid JSON"
        return GateRow(
            gid,
            label,
            "FAIL",
            detail[:500],
            remediation_audit(repo),
        )
    summary = payload.get("summary") or {}
    fails = int(summary.get("fail") or 0)
    if fails > 0:
        return GateRow(
            gid,
            label,
            "FAIL",
            f"{fails} workflow audit failure(s)",
            remediation_audit(repo),
        )
    return GateRow(gid, label, "PASS", "workflow audit clean", "")


def gate_site_smoke(repo: Path) -> GateRow:
    gid, label = "site_smoke", GATE_LABELS["site_smoke"]
    path = script_path(repo, "factory-site-smoke.py")
    if not path.is_file():
        return GateRow(gid, label, "SKIP", "factory-site-smoke.py not present", "")
    cmd = [sys.executable, str(path), "--build", "--json"]
    rc, out, err = run_subprocess(cmd, cwd=repo)
    payload = parse_json(out)
    if payload is None:
        detail = err.strip() or out.strip() or f"exit {rc}, invalid JSON"
        return GateRow(
            gid,
            label,
            "FAIL",
            detail[:500],
            remediation_site_smoke(),
        )
    if payload.get("ok") is True:
        return GateRow(gid, label, "PASS", "site smoke passed", "")
    errors = int(payload.get("error_count") or len(payload.get("errors") or []))
    return GateRow(
        gid,
        label,
        "FAIL",
        f"site smoke: {errors} finding(s)",
        remediation_site_smoke(),
    )


def gate_release(repo: Path, version: str | None) -> GateRow:
    gid, label = "release", GATE_LABELS["release"]
    if not version:
        return GateRow(
            gid,
            label,
            "SKIP",
            "no --version (release gate not run)",
            "python3 scripts/factory-owner-pack.py --version vX.Y.Z",
        )
    path = script_path(repo, "factory-release.py")
    if not path.is_file():
        return GateRow(gid, label, "SKIP", "factory-release.py not present", "")
    cmd = [
        sys.executable,
        str(path),
        "--version",
        version,
        "--repo-dir",
        str(repo),
        "--json",
    ]
    rc, out, err = run_subprocess(cmd, cwd=repo)
    payload = parse_json(out)
    if payload is None:
        detail = err.strip() or out.strip() or f"exit {rc}, invalid JSON"
        return GateRow(
            gid,
            label,
            "FAIL",
            detail[:500],
            remediation_release(repo, version),
        )
    summary = payload.get("summary") or {}
    fails = int(summary.get("fail") or 0)
    warns = int(summary.get("warn") or 0)
    if fails > 0:
        return GateRow(
            gid,
            label,
            "FAIL",
            f"{fails} release check(s) failed for {version}",
            remediation_release(repo, version),
        )
    if warns > 0:
        return GateRow(
            gid,
            label,
            "WARN",
            f"{warns} release warning(s) for {version}",
            remediation_release(repo, version),
        )
    return GateRow(gid, label, "PASS", f"release scorecard clean for {version}", "")


def run_pack(repo: Path, version: str | None) -> list[GateRow]:
    return [
        gate_doctor(repo),
        gate_prepublic(repo),
        gate_check_docs(repo),
        gate_audit_workflows(repo),
        gate_site_smoke(repo),
        gate_release(repo, version),
    ]


def overall_verdict(rows: list[GateRow]) -> str:
    statuses = {r.status for r in rows}
    if "FAIL" in statuses:
        return "BLOCKED"
    if "WARN" in statuses:
        return "WARN"
    return "READY"


def exit_code(verdict: str, strict: bool) -> int:
    if verdict == "BLOCKED":
        return 1
    if verdict == "WARN" and strict:
        return 1
    return 0


def to_json_payload(
    repo: Path, version: str | None, rows: list[GateRow], verdict: str
) -> dict[str, Any]:
    return {
        "repo_dir": str(repo.resolve()),
        "version": version,
        "verdict": verdict,
        "gates": [asdict(r) for r in rows],
        "summary": {
            "pass": sum(1 for r in rows if r.status == "PASS"),
            "warn": sum(1 for r in rows if r.status == "WARN"),
            "fail": sum(1 for r in rows if r.status == "FAIL"),
            "skip": sum(1 for r in rows if r.status == "SKIP"),
        },
    }


def render_markdown(
    repo: Path, version: str | None, rows: list[GateRow], verdict: str
) -> str:
    payload = to_json_payload(repo, version, rows, verdict)
    s = payload["summary"]
    lines = [
        "# Factory owner pack",
        "",
        f"Repo: `{payload['repo_dir']}`",
        f"Version: `{version}`" if version else "Version: *(not requested)*",
        "",
        f"**Overall: {verdict}** "
        f"({s['pass']} pass, {s['warn']} warn, {s['fail']} fail, {s['skip']} skip)",
        "",
        "| Status | Gate | Detail | Remediation |",
        "| --- | --- | --- | --- |",
    ]
    for r in rows:
        remed = f"`{r.remediation}`" if r.remediation else "—"
        lines.append(f"| {r.status} | {r.label} | {r.detail} | {remed} |")
    lines.append("")
    if verdict == "READY":
        lines.append("Launch automation checks passed; continue with owner steps in "
                     "`docs/PUBLIC_LAUNCH_RUNBOOK.md`.")
    elif verdict == "WARN":
        lines.append("Warnings present — review remediation commands before going public "
                     "(or re-run with `--strict` to fail the gate).")
    else:
        lines.append("Blocked — fix failing gates using the remediation commands above.")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "--repo-dir",
        type=Path,
        default=None,
        help="Repository root (default: parent of scripts/)",
    )
    ap.add_argument(
        "--version",
        default=None,
        help="Semver tag for factory-release gate (e.g. v0.1.0)",
    )
    ap.add_argument("--json", action="store_true", help="Emit JSON scorecard on stdout")
    ap.add_argument(
        "--strict",
        action="store_true",
        help="Exit non-zero on WARN as well as BLOCKED",
    )
    args = ap.parse_args()
    repo = (args.repo_dir or repo_root_from_script()).resolve()
    if not repo.is_dir():
        print(f"factory-owner-pack: not a directory: {repo}", file=sys.stderr)
        return 2

    version = args.version.strip() if args.version else None
    rows = run_pack(repo, version)
    verdict = overall_verdict(rows)
    payload = to_json_payload(repo, version, rows, verdict)

    if args.json:
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print(render_markdown(repo, version, rows, verdict))

    return exit_code(verdict, args.strict)


if __name__ == "__main__":
    sys.exit(main())