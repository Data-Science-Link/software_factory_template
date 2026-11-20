#!/usr/bin/env python3
"""Unified owner launch-readiness gate: compose factory doctor, hygiene, docs, workflows,
site smoke, and optional release checks into one scorecard.

Read-only. Python 3 stdlib only. Refs #178, #184, #185, #56.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
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
    "models_config": "Model registry (factory-models-check)",
    "decision_log": "Decision log (factory-decision-log)",
    "check_docs": "Doc links (factory-check-docs)",
    "audit_workflows": "Workflow drift (factory-audit-workflows)",
    "shell_hygiene": "Shell hygiene (test-shell-hygiene)",
    "examples_smoke": "Examples smoke (test-examples)",
    "reusable_check": "Reusable workflows (factory-reusable-check)",
    "dbt_build": "dbt project build (optional)",
    "site_smoke": "Factory site smoke (factory-site-smoke)",
    "release": "Release readiness (factory-release)",
}

OWNER_WORKFLOW_SYNC_DOC = "docs/OWNER_WORKFLOW_SYNC.md"

DOC_POINTERS = {
    "models_config": "docs/MODEL_SCOUTING.md",
    "audit_workflows": "docs/OWNER_WORKFLOW_SYNC.md",
    "prepublic": "docs/OWNER_WORKFLOW_SYNC.md",
    "release": "docs/CRITIC_REVIEW.md",
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


def run_subprocess(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            cwd=str(cwd) if cwd else None,
            env=env,
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


def remediation_models_config() -> str:
    return "python3 scripts/factory-models-check.py --json  # see docs/MODEL_SCOUTING.md"


def remediation_decision_log() -> str:
    return "python3 scripts/factory-decision-log.py check --json"


def remediation_shell_hygiene() -> str:
    return "bash scripts/test-shell-hygiene.sh"


def remediation_examples_smoke() -> str:
    return "bash scripts/test-examples.sh"


def remediation_reusable_check() -> str:
    return "python3 scripts/factory-reusable-check.py --strict --json"


def remediation_dbt_build(repo: Path) -> str:
    return (
        f"cd {repo / 'factory' / 'dbt'} && "
        'dbt build --profiles-dir . --vars "$(python3 scripts/factory-budget-vars.py)"'
    )


def reusable_pack_enabled(repo: Path) -> bool:
    script = script_path(repo, "factory-reusable-check.py")
    docs = repo / "docs" / "reusable-workflows"
    return script.is_file() and docs.is_dir()


def tail_output(stdout: str, stderr: str, *, limit: int = 400) -> str:
    combined = "\n".join(part for part in (stderr.strip(), stdout.strip()) if part)
    if not combined:
        return ""
    lines = combined.splitlines()
    if len(lines) > 12:
        lines = lines[-12:]
    text = "\n".join(lines)
    return text[:limit]


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


def gate_models_config(repo: Path) -> GateRow:
    gid, label = "models_config", GATE_LABELS["models_config"]
    path = script_path(repo, "factory-models-check.py")
    if not path.is_file():
        return GateRow(gid, label, "SKIP", "factory-models-check.py not present", "")
    cmd = [sys.executable, str(path), "--json"]
    rc, out, err = run_subprocess(cmd, cwd=repo)
    payload = parse_json(out)
    if payload is None:
        detail = tail_output(out, err) or f"exit {rc}, invalid JSON"
        return GateRow(
            gid,
            label,
            "FAIL",
            detail,
            remediation_models_config(),
        )
    status = str(payload.get("status") or "").lower()
    errors = payload.get("errors") or []
    warnings = payload.get("warnings") or []
    if status == "fail" or errors or rc != 0:
        n_err = len(errors) if errors else 1
        return GateRow(
            gid,
            label,
            "FAIL",
            f"{n_err} models.yaml error(s)",
            remediation_models_config(),
        )
    if status == "warn" or warnings:
        return GateRow(
            gid,
            label,
            "WARN",
            f"{len(warnings)} models.yaml warning(s)",
            remediation_models_config(),
        )
    return GateRow(gid, label, "PASS", "models.yaml schema clean", "")


def gate_decision_log(repo: Path) -> GateRow:
    gid, label = "decision_log", GATE_LABELS["decision_log"]
    path = script_path(repo, "factory-decision-log.py")
    if not path.is_file():
        return GateRow(gid, label, "SKIP", "factory-decision-log.py not present", "")
    cmd = [sys.executable, str(path), "check", "--json"]
    rc, out, err = run_subprocess(cmd, cwd=repo)
    payload = parse_json(out)
    if payload is None:
        detail = tail_output(out, err) or f"exit {rc}, invalid JSON"
        return GateRow(
            gid,
            label,
            "FAIL",
            detail,
            remediation_decision_log(),
        )
    errors = payload.get("errors") or []
    warnings = payload.get("warnings") or []
    if not payload.get("valid") or errors or rc != 0:
        return GateRow(
            gid,
            label,
            "FAIL",
            f"{len(errors) or 1} decision log error(s)",
            remediation_decision_log(),
        )
    if warnings:
        return GateRow(
            gid,
            label,
            "WARN",
            f"{len(warnings)} decision log warning(s)",
            remediation_decision_log(),
        )
    total = int(payload.get("total") or 0)
    return GateRow(
        gid,
        label,
        "PASS",
        f"decision log valid ({total} entr{'y' if total == 1 else 'ies'})",
        "",
    )


def gate_bash_script(
    repo: Path,
    *,
    gate_id: str,
    script_name: str,
    pass_detail: str,
    remediation: str,
) -> GateRow:
    label = GATE_LABELS[gate_id]
    path = repo / "scripts" / script_name
    if not path.is_file():
        return GateRow(gate_id, label, "SKIP", f"{script_name} not present", "")
    cmd = ["bash", str(path)]
    rc, out, err = run_subprocess(cmd, cwd=repo)
    if rc == 0:
        return GateRow(gate_id, label, "PASS", pass_detail, "")
    detail = tail_output(out, err) or f"exit {rc}"
    return GateRow(gate_id, label, "FAIL", detail, remediation)


def gate_shell_hygiene(repo: Path) -> GateRow:
    return gate_bash_script(
        repo,
        gate_id="shell_hygiene",
        script_name="test-shell-hygiene.sh",
        pass_detail="shell test hygiene passed",
        remediation=remediation_shell_hygiene(),
    )


def gate_examples_smoke(repo: Path) -> GateRow:
    return gate_bash_script(
        repo,
        gate_id="examples_smoke",
        script_name="test-examples.sh",
        pass_detail="examples/ smoke passed",
        remediation=remediation_examples_smoke(),
    )


def gate_reusable_check(repo: Path) -> GateRow:
    gid, label = "reusable_check", GATE_LABELS["reusable_check"]
    if not reusable_pack_enabled(repo):
        missing: list[str] = []
        if not script_path(repo, "factory-reusable-check.py").is_file():
            missing.append("scripts/factory-reusable-check.py")
        if not (repo / "docs" / "reusable-workflows").is_dir():
            missing.append("docs/reusable-workflows/")
        detail = (
            "reusable workflow pack not enabled"
            if not missing
            else f"missing {', '.join(missing)} (optional gate)"
        )
        return GateRow(gid, label, "SKIP", detail, "")
    path = script_path(repo, "factory-reusable-check.py")
    cmd = [sys.executable, str(path), "--strict", "--json"]
    rc, out, err = run_subprocess(cmd, cwd=repo)
    payload = parse_json(out)
    if payload is None:
        if rc == 0:
            return GateRow(gid, label, "PASS", "reusable workflows check passed", "")
        detail = tail_output(out, err) or f"exit {rc}"
        return GateRow(gid, label, "FAIL", detail, remediation_reusable_check())
    summary = payload.get("summary") or {}
    fails = int(summary.get("fail") or 0)
    warns = int(summary.get("warn") or 0)
    if payload.get("ok") is False or fails > 0 or rc != 0:
        return GateRow(
            gid,
            label,
            "FAIL",
            f"{fails or 1} reusable workflow issue(s)",
            remediation_reusable_check(),
        )
    if warns > 0:
        return GateRow(
            gid,
            label,
            "WARN",
            f"{warns} reusable workflow warning(s)",
            remediation_reusable_check(),
        )
    return GateRow(gid, label, "PASS", "reusable workflows check clean", "")


def gate_dbt_build(repo: Path) -> GateRow:
    gid, label = "dbt_build", GATE_LABELS["dbt_build"]
    dbt_dir = repo / "factory" / "dbt"
    if not dbt_dir.is_dir():
        return GateRow(gid, label, "SKIP", "factory/dbt not present", "")
    if shutil.which("dbt") is None:
        return GateRow(
            gid,
            label,
            "SKIP",
            "dbt not on PATH (pip install -r factory/dbt/requirements-dbt.txt)",
            "",
        )
    rc, _out, _err = run_subprocess(
        [sys.executable, "-c", "import dbt"],
        cwd=repo,
    )
    if rc != 0:
        return GateRow(
            gid,
            label,
            "SKIP",
            "dbt Python package not installed",
            "pip install -r factory/dbt/requirements-dbt.txt",
        )
    budget_vars = script_path(repo, "factory-budget-vars.py")
    if not budget_vars.is_file():
        return GateRow(gid, label, "SKIP", "factory-budget-vars.py not present", "")
    env = dict(os.environ)
    env["DBT_SEND_ANONYMOUS_USAGE_STATS"] = "false"
    seeds_rel = "tests/dbt/budget-math-week-seeds"
    seeds_dir = repo / seeds_rel
    if not seeds_dir.is_dir():
        return GateRow(
            gid,
            label,
            "SKIP",
            f"{seeds_rel} fixtures not present",
            "",
        )
    rc, raw_vars, vars_err = run_subprocess(
        [sys.executable, str(budget_vars)],
        cwd=repo,
    )
    if rc != 0 or not raw_vars.strip():
        detail = tail_output(raw_vars, vars_err) or "factory-budget-vars.py failed"
        return GateRow(gid, label, "FAIL", detail, remediation_dbt_build(repo))
    try:
        vars_obj = json.loads(raw_vars)
        vars_obj["as_of_date"] = "2026-11-20"
        vars_json = json.dumps(vars_obj, sort_keys=True)
    except json.JSONDecodeError:
        return GateRow(
            gid,
            label,
            "FAIL",
            "factory-budget-vars.py did not emit JSON",
            remediation_dbt_build(repo),
        )
    dbt_env = {**env, "FACTORY_SEEDS_DIR": f"../../{seeds_rel}"}
    rc, out, err = run_subprocess(
        ["dbt", "build", "--profiles-dir", ".", "--vars", vars_json],
        cwd=dbt_dir,
        env=dbt_env,
    )
    if rc != 0:
        detail = tail_output(out, err) or f"dbt build exit {rc}"
        return GateRow(gid, label, "FAIL", detail, remediation_dbt_build(repo))
    return GateRow(
        gid,
        label,
        "PASS",
        "dbt build succeeded (budget-math-week seeds)",
        "",
    )


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


def gate_site_smoke(repo: Path, *, skip: bool = False) -> GateRow:
    gid, label = "site_smoke", GATE_LABELS["site_smoke"]
    if skip:
        return GateRow(gid, label, "SKIP", "skipped via --skip-site", "")
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


def run_pack(
    repo: Path, version: str | None, *, skip_site: bool = False
) -> list[GateRow]:
    return [
        gate_doctor(repo),
        gate_prepublic(repo),
        gate_models_config(repo),
        gate_decision_log(repo),
        gate_check_docs(repo),
        gate_audit_workflows(repo),
        gate_shell_hygiene(repo),
        gate_examples_smoke(repo),
        gate_reusable_check(repo),
        gate_dbt_build(repo),
        gate_site_smoke(repo, skip=skip_site),
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
    sync_rel = OWNER_WORKFLOW_SYNC_DOC
    sync_path = (repo / sync_rel).resolve()
    return {
        "repo_dir": str(repo.resolve()),
        "version": version,
        "verdict": verdict,
        "owner_workflow_sync": sync_rel,
        "owner_workflow_sync_path": str(sync_path) if sync_path.is_file() else None,
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
        pointer = DOC_POINTERS.get(r.id)
        if pointer and r.status in ("FAIL", "WARN"):
            remed = f"{remed} · see `{pointer}`" if r.remediation else f"see `{pointer}`"
        lines.append(f"| {r.status} | {r.label} | {r.detail} | {remed} |")
    lines.append("")
    lines.extend(
        [
            "**Owner references:** "
            "`docs/OWNER_WORKFLOW_SYNC.md` (workflow pastes), "
            "`docs/CRITIC_REVIEW.md` (optional critic), "
            "`docs/MODEL_SCOUTING.md` (model registry updates).",
            "",
        ]
    )
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
        "--markdown",
        action="store_true",
        help="Emit Markdown scorecard on stdout (default when --json is omitted)",
    )
    ap.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Write scorecard to this path (Markdown unless --json)",
    )
    ap.add_argument(
        "--skip-site",
        action="store_true",
        help="Skip the factory-site-smoke gate",
    )
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
    rows = run_pack(repo, version, skip_site=args.skip_site)
    verdict = overall_verdict(rows)
    payload = to_json_payload(repo, version, rows, verdict)

    emit_json = bool(args.json)
    emit_markdown = emit_json is False and (args.markdown or True)

    if emit_json:
        report_text = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    elif emit_markdown:
        report_text = render_markdown(repo, version, rows, verdict)
    else:
        report_text = ""

    if args.out is not None:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(report_text, encoding="utf-8")

    if emit_json:
        sys.stdout.write(report_text)
    elif emit_markdown:
        sys.stdout.write(report_text)

    return exit_code(verdict, args.strict)


if __name__ == "__main__":
    sys.exit(main())