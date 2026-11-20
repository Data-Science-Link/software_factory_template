#!/usr/bin/env python3
"""Offline contract check for docs/reusable-workflows reusable templates and callers.

Validates YAML shape, workflow_call contracts, action SHA pins, permissions, and
caller/reusable input-secret alignment (Refs #156, #178, #182).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover
    yaml = None  # type: ignore

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DIR = ROOT / "docs" / "reusable-workflows"

SHA_RE = re.compile(r"^[0-9a-f]{40}$", re.IGNORECASE)
USES_RE = re.compile(r"^\s*(?:-\s*)?uses:\s*['\"]?([^'\"#\s]+)", re.IGNORECASE)
REPOSITORY_LINE_RE = re.compile(
    r"^\s*repository:\s*([A-Za-z0-9][A-Za-z0-9_.${}/-]+)\s*(?:#.*)?$"
)
PERSONAL_ORG_IN_COMMENT_RE = re.compile(
    r"Data-Science-Link/software_factory_template"
)
SECRET_PATTERNS = (
    re.compile(r"sk-[a-z0-9]{10,}", re.IGNORECASE),
    re.compile(r"ghp_[a-zA-Z0-9]{20,}"),
    re.compile(r"""api[_-]?key\s*[:=]\s*['\"][^'\"]+['\"]""", re.IGNORECASE),
)
ALLOWED_REPO_TOKENS = frozenset(
    {
        "{{TEMPLATE_REPO}}",
        "YOUR_ORG/software_factory_template",
        "${{ github.repository }}",
    }
)
BROAD_PERMISSIONS = frozenset(
    {"write-all", "all", "administration", "actions", "attestations"}
)
CALLER_PIN_RE = re.compile(
    r"reusable-[-\w]+\.ya?ml@(v\d+\.\d+\.\d+|[0-9a-f]{40}|\{\{TAG\}\})",
    re.IGNORECASE,
)
LOCAL_REUSABLE_USES_RE = re.compile(
    r"(?:^|/)(reusable-[-\w]+\.ya?ml)@", re.IGNORECASE
)


@dataclass
class Finding:
    check: str
    status: str  # pass | warn | fail
    file: str
    detail: str
    job: str | None = None
    line: int | None = None
    refs: list[str] = field(default_factory=lambda: ["#156", "#178", "#182"])


def normalize_workflow_data(data: dict[str, Any]) -> dict[str, Any]:
    """PyYAML 1.1 treats bare `on:` as boolean True; restore workflow trigger key."""
    if True in data and "on" not in data:
        data = dict(data)
        data["on"] = data.pop(True)
    return data


def load_yaml(path: Path) -> tuple[dict[str, Any], str]:
    text = path.read_text(encoding="utf-8")
    if yaml is None:
        raise RuntimeError("PyYAML is required; install requirements-factory.txt")
    data = yaml.safe_load(text) or {}
    if not isinstance(data, dict):
        data = {}
    data = normalize_workflow_data(data)
    return data, text


def summarize(findings: list[Finding]) -> dict[str, int]:
    out = {"pass": 0, "warn": 0, "fail": 0}
    for f in findings:
        out[f.status] = out.get(f.status, 0) + 1
    out["total"] = len(findings)
    return out


def action_ref_pinned(ref: str) -> bool:
    if "@" not in ref:
        return False
    if ref.strip().startswith("./") or "/.github/workflows/reusable-" in ref:
        return True
    _action, pin = ref.rsplit("@", 1)
    if "/" in pin:
        return False
    return bool(SHA_RE.match(pin))


def permissions_value_broad(value: Any) -> bool:
    if value is None:
        return False
    if isinstance(value, str):
        return value.lower() in BROAD_PERMISSIONS
    if isinstance(value, dict):
        for k, v in value.items():
            if str(k).lower() in BROAD_PERMISSIONS:
                return True
            if permissions_value_broad(v):
                return True
    return False


def strip_comment_lines(text: str) -> str:
    lines = text.splitlines()
    while lines and lines[0].startswith("#"):
        lines.pop(0)
    return "\n".join(lines)


def workflow_call_block(data: dict[str, Any]) -> dict[str, Any]:
    on = data.get("on")
    if not isinstance(on, dict):
        return {}
    wc = on.get("workflow_call")
    return wc if isinstance(wc, dict) else {}


def input_required_without_default(defn: dict[str, Any]) -> bool:
    if not defn.get("required"):
        return False
    return "default" not in defn


def find_jobs_with_reusable_uses(data: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    jobs = data.get("jobs") or {}
    if not isinstance(jobs, dict):
        return []
    out: list[tuple[str, dict[str, Any]]] = []
    for job_id, job in jobs.items():
        if isinstance(job, dict) and "uses" in job:
            out.append((str(job_id), job))
    return out


def check_reusable_file(path: Path, base: Path) -> list[Finding]:
    rel = path.relative_to(base).as_posix()
    findings: list[Finding] = []
    try:
        data, text = load_yaml(path)
    except Exception as exc:  # noqa: BLE001
        return [
            Finding(
                check="yaml_parse",
                status="fail",
                file=rel,
                detail=f"YAML parse error: {exc}",
            )
        ]

    if not workflow_call_block(data):
        findings.append(
            Finding(
                check="workflow_call",
                status="fail",
                file=rel,
                detail="missing on.workflow_call",
            )
        )
    else:
        findings.append(
            Finding(
                check="workflow_call",
                status="pass",
                file=rel,
                detail="defines on.workflow_call",
            )
        )

    if "permissions" not in data:
        findings.append(
            Finding(
                check="reusable_permissions",
                status="fail",
                file=rel,
                detail="reusable workflow missing top-level permissions:",
            )
        )
    elif permissions_value_broad(data.get("permissions")):
        findings.append(
            Finding(
                check="reusable_permissions",
                status="fail",
                file=rel,
                detail=f"overly broad permissions: {data.get('permissions')!r}",
            )
        )
    else:
        findings.append(
            Finding(
                check="reusable_permissions",
                status="pass",
                file=rel,
                detail="explicit scoped top-level permissions",
            )
        )

    body = strip_comment_lines(text)
    for pat in SECRET_PATTERNS:
        if pat.search(body):
            findings.append(
                Finding(
                    check="hardcoded_secret",
                    status="fail",
                    file=rel,
                    detail="possible hardcoded secret pattern in reusable workflow",
                )
            )
            break
    else:
        findings.append(
            Finding(
                check="hardcoded_secret",
                status="pass",
                file=rel,
                detail="no hardcoded secret patterns",
            )
        )

    personal_hits = 0
    for i, line in enumerate(text.splitlines(), start=1):
        m = REPOSITORY_LINE_RE.match(line)
        if m:
            slug = m.group(1).strip("'\"")
            if slug in ALLOWED_REPO_TOKENS or "{{" in slug or slug.startswith("YOUR_"):
                continue
            if "/" in slug and not slug.startswith("actions/"):
                findings.append(
                    Finding(
                        check="personal_repo",
                        status="fail",
                        file=rel,
                        line=i,
                        detail=(
                            f"hardcoded repository {slug!r}; use {{{{TEMPLATE_REPO}}}} "
                            "for template checkouts"
                        ),
                    )
                )
                personal_hits += 1
        if line.startswith("#") and PERSONAL_ORG_IN_COMMENT_RE.search(line):
            findings.append(
                Finding(
                    check="personal_repo",
                    status="fail",
                    file=rel,
                    line=i,
                    detail="comment references a personal template org; use a placeholder",
                )
            )
            personal_hits += 1
    if personal_hits == 0:
        findings.append(
            Finding(
                check="personal_repo",
                status="pass",
                file=rel,
                detail="no hardcoded personal repository names",
            )
        )

    unpinned: list[str] = []
    for i, line in enumerate(text.splitlines(), start=1):
        um = USES_RE.match(line)
        if not um:
            continue
        ref = um.group(1)
        if "/.github/workflows/reusable-" in ref:
            continue
        if not action_ref_pinned(ref):
            unpinned.append(f"line {i}: {ref}")
    if unpinned:
        for detail in unpinned:
            findings.append(
                Finding(
                    check="action_pin",
                    status="fail",
                    file=rel,
                    detail=f"uses {detail} is not pinned to a 40-character commit SHA",
                )
            )
    else:
        findings.append(
            Finding(
                check="action_pin",
                status="pass",
                file=rel,
                detail="every third-party uses: is pinned to a commit SHA",
            )
        )

    return findings


def paired_reusable_name(caller_path: Path) -> str:
    return f"reusable-{caller_path.stem}.yml"


def check_caller_file(
    caller_path: Path,
    reusable_path: Path | None,
    base: Path,
) -> list[Finding]:
    rel = caller_path.relative_to(base).as_posix()
    findings: list[Finding] = []
    expected_reusable = paired_reusable_name(caller_path)

    if reusable_path is None or not reusable_path.is_file():
        findings.append(
            Finding(
                check="caller_pair",
                status="fail",
                file=rel,
                detail=f"missing paired reusable file {expected_reusable}",
            )
        )
        return findings

    try:
        caller_data, _caller_text = load_yaml(caller_path)
        reusable_data, _ = load_yaml(reusable_path)
    except Exception as exc:  # noqa: BLE001
        return [
            Finding(
                check="yaml_parse",
                status="fail",
                file=rel,
                detail=f"YAML parse error: {exc}",
            )
        ]

    if "permissions" not in caller_data:
        findings.append(
            Finding(
                check="caller_permissions",
                status="fail",
                file=rel,
                detail="caller workflow missing top-level permissions:",
            )
        )
    elif permissions_value_broad(caller_data.get("permissions")):
        findings.append(
            Finding(
                check="caller_permissions",
                status="fail",
                file=rel,
                detail=f"caller permissions too broad: {caller_data.get('permissions')!r}",
            )
        )
    else:
        findings.append(
            Finding(
                check="caller_permissions",
                status="pass",
                file=rel,
                detail="caller declares explicit top-level permissions",
            )
        )

    reusable_jobs = find_jobs_with_reusable_uses(caller_data)
    if not reusable_jobs:
        findings.append(
            Finding(
                check="caller_uses",
                status="fail",
                file=rel,
                detail="caller has no job with uses: (reusable workflow call)",
            )
        )
        return findings

    wc = workflow_call_block(reusable_data)
    inputs_def = wc.get("inputs") if isinstance(wc.get("inputs"), dict) else {}
    secrets_def = wc.get("secrets") if isinstance(wc.get("secrets"), dict) else {}

    for job_id, job in reusable_jobs:
        uses = str(job.get("uses", ""))
        m = LOCAL_REUSABLE_USES_RE.search(uses)
        if not m:
            findings.append(
                Finding(
                    check="caller_uses",
                    status="fail",
                    file=rel,
                    job=job_id,
                    detail=f"uses does not reference a reusable-*.yml workflow: {uses!r}",
                )
            )
            continue
        got_name = m.group(1)
        if got_name != expected_reusable:
            findings.append(
                Finding(
                    check="caller_uses",
                    status="fail",
                    file=rel,
                    job=job_id,
                    detail=f"uses references {got_name}, expected {expected_reusable}",
                )
            )
        elif not CALLER_PIN_RE.search(uses):
            findings.append(
                Finding(
                    check="caller_uses",
                    status="fail",
                    file=rel,
                    job=job_id,
                    detail=f"uses line lacks semver tag, SHA, or {{{{TAG}}}} pin: {uses!r}",
                )
            )
        else:
            findings.append(
                Finding(
                    check="caller_uses",
                    status="pass",
                    file=rel,
                    job=job_id,
                    detail=f"uses points at {expected_reusable} with a version pin",
                )
            )

        with_block = job.get("with") if isinstance(job.get("with"), dict) else {}
        input_fails = 0
        for key in with_block:
            if key not in inputs_def:
                findings.append(
                    Finding(
                        check="caller_input",
                        status="fail",
                        file=rel,
                        job=job_id,
                        detail=f"unknown input {key!r} (not in reusable workflow_call.inputs)",
                    )
                )
                input_fails += 1
        for in_name, in_def in inputs_def.items():
            if not isinstance(in_def, dict):
                continue
            if input_required_without_default(in_def) and in_name not in with_block:
                findings.append(
                    Finding(
                        check="caller_input",
                        status="fail",
                        file=rel,
                        job=job_id,
                        detail=f"missing required input {in_name!r}",
                    )
                )
                input_fails += 1
        if input_fails == 0:
            findings.append(
                Finding(
                    check="caller_input",
                    status="pass",
                    file=rel,
                    job=job_id,
                    detail="caller with: inputs match reusable contract",
                )
            )

        secrets_block = job.get("secrets")
        if secrets_block == "inherit":
            findings.append(
                Finding(
                    check="caller_secret",
                    status="pass",
                    file=rel,
                    job=job_id,
                    detail="secrets: inherit satisfies reusable workflow_call.secrets",
                )
            )
            continue
        if not secrets_def:
            findings.append(
                Finding(
                    check="caller_secret",
                    status="pass",
                    file=rel,
                    job=job_id,
                    detail="reusable workflow defines no workflow_call.secrets",
                )
            )
            continue
        if not isinstance(secrets_block, dict):
            findings.append(
                Finding(
                    check="caller_secret",
                    status="fail",
                    file=rel,
                    job=job_id,
                    detail="reusable requires secrets but caller has no secrets: mapping",
                )
            )
            continue
        secret_fails = 0
        for key in secrets_block:
            if key not in secrets_def:
                findings.append(
                    Finding(
                        check="caller_secret",
                        status="fail",
                        file=rel,
                        job=job_id,
                        detail=f"unknown secret {key!r} (not in reusable workflow_call.secrets)",
                    )
                )
                secret_fails += 1
        for sec_name, sec_def in secrets_def.items():
            if not isinstance(sec_def, dict):
                continue
            if sec_def.get("required") and sec_name not in secrets_block:
                findings.append(
                    Finding(
                        check="caller_secret",
                        status="fail",
                        file=rel,
                        job=job_id,
                        detail=f"missing required secret {sec_name!r}",
                    )
                )
                secret_fails += 1
        if secret_fails == 0:
            findings.append(
                Finding(
                    check="caller_secret",
                    status="pass",
                    file=rel,
                    job=job_id,
                    detail="caller secrets match reusable contract",
                )
            )

    return findings


def audit_dir(workflows_dir: Path) -> list[Finding]:
    findings: list[Finding] = []
    if not workflows_dir.is_dir():
        return [
            Finding(
                check="layout",
                status="fail",
                file=str(workflows_dir),
                detail="reusable workflows directory not found",
            )
        ]

    reusable_files = sorted(workflows_dir.glob("reusable-*.yml"))
    callers_dir = workflows_dir / "callers"
    caller_files = (
        sorted(callers_dir.glob("*.yml")) + sorted(callers_dir.glob("*.yaml"))
        if callers_dir.is_dir()
        else []
    )

    if not reusable_files:
        findings.append(
            Finding(
                check="layout",
                status="fail",
                file=str(workflows_dir),
                detail="no reusable-*.yml templates found",
            )
        )

    for path in reusable_files:
        findings.extend(check_reusable_file(path, workflows_dir))

    for caller_path in caller_files:
        reusable_path = workflows_dir / paired_reusable_name(caller_path)
        findings.extend(check_caller_file(caller_path, reusable_path, workflows_dir))

    return findings


def render_table(workflows_dir: Path, findings: list[Finding]) -> str:
    summary = summarize(findings)
    lines = [
        "Reusable workflow contract check",
        f"Directory: {workflows_dir}",
        "",
        f"Summary: {summary['pass']} pass, {summary['warn']} warn, {summary['fail']} fail "
        f"({summary['total']} checks)",
        "",
        "| Status | Check | File | Job | Detail |",
        "| --- | --- | --- | --- | --- |",
    ]
    for f in findings:
        job = f.job or ""
        lines.append(
            f"| {f.status.upper()} | `{f.check}` | `{f.file}` | {job} | {f.detail} |"
        )
    lines.extend(
        [
            "",
            "Re-run: `python3 scripts/factory-reusable-check.py --strict`",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--dir",
        type=Path,
        default=DEFAULT_DIR,
        help="Path to docs/reusable-workflows (default: repo docs tree)",
    )
    ap.add_argument("--json", action="store_true", help="Emit JSON on stdout")
    ap.add_argument(
        "--strict",
        action="store_true",
        help="Exit 1 on fail (and on warn when any warn is present)",
    )
    args = ap.parse_args()

    if yaml is None:
        print(
            "factory-reusable-check: PyYAML missing; install: pip install -r requirements-factory.txt",
            file=sys.stderr,
        )
        return 2

    workflows_dir = args.dir.resolve()
    findings = audit_dir(workflows_dir)
    summary = summarize(findings)
    ok = summary["fail"] == 0 and (summary["warn"] == 0 if args.strict else True)
    payload = {
        "ok": ok,
        "dir": str(workflows_dir),
        "summary": summary,
        "findings": [asdict(f) for f in findings],
    }

    if args.json:
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print(render_table(workflows_dir, findings))

    if summary["fail"] > 0:
        return 1
    if args.strict and summary["warn"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())