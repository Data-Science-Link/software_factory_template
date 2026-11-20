#!/usr/bin/env python3
"""Offline audit of .github/workflows/*.yml for factory owner-paste backlog.

Covers: action SHA pins (#57), pr-check quality gates (#57/#161/#178), Python pin on
/oc agent jobs (#148), approve-oc-runs workflow_run (#214/#74), harden-runner /
permissions (#44), and optional Critic review job presence (#41).

Default mode prints a report and exits 0 so CI can adopt the script before workflows
catch up. Use --strict to exit non-zero when any check fails.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_WORKFLOWS = ROOT / ".github" / "workflows"

SHA_RE = re.compile(r"^[0-9a-f]{40}$", re.IGNORECASE)
USES_RE = re.compile(r"^\s*(?:-\s*)?uses:\s*['\"]?([^'\"#\s]+)", re.IGNORECASE)
PYTHON_VERSION_RE = re.compile(
    r'python-version:\s*["\']?(3\.(12|13))', re.IGNORECASE
)
BROAD_PERMISSIONS = frozenset(
    {"write-all", "all", "administration", "actions", "attestations"}
)

CHECK_CATEGORIES: dict[str, str] = {
    "action_pin": "sha_pinning",
    "workflow_permissions": "permissions",
    "harden_runner": "permissions",
    "pr_check_shell_hygiene": "pr_check_quality_gates",
    "pr_check_pr_check_tests": "pr_check_quality_gates",
    "pr_check_predict_cost": "pr_check_quality_gates",
    "pr_check_spec_template_drift": "pr_check_quality_gates",
    "pr_check_check_docs": "pr_check_quality_gates",
    "pr_check_prepublic": "pr_check_quality_gates",
    "oc_agent_python_pin": "python_pin",
    "approve_oc_workflow_run": "approve_oc_safety",
    "approve_oc_branch_guard": "approve_oc_safety",
    "approve_oc_fork_guard": "approve_oc_safety",
    "factory_site_build": "factory_site",
    "factory_site_budget_paths": "factory_site",
    "factory_site_pages_deploy": "factory_site",
    "factory_selected_optional": "factory_selected",
    "factory_selected_dispatch": "factory_selected",
    "critic_review_job": "critic_review",
    "workflows_present": "other",
}


@dataclass
class Finding:
    check: str
    status: str  # pass | fail
    file: str
    detail: str
    refs: list[str] = field(default_factory=list)
    job: str | None = None
    line: int | None = None


def load_workflow(path: Path) -> tuple[dict[str, Any], str]:
    text = path.read_text(encoding="utf-8")
    data = yaml.safe_load(text) or {}
    if not isinstance(data, dict):
        data = {}
    return data, text


def line_for_token(text: str, token: str) -> int | None:
    for i, line in enumerate(text.splitlines(), start=1):
        if token in line:
            return i
    return None


def action_ref_pinned(ref: str) -> bool:
    if "@" not in ref:
        return False
    _action, pin = ref.rsplit("@", 1)
    if "/" in pin:
        return False
    return bool(SHA_RE.match(pin))


def find_unpinned_uses(text: str, relpath: str) -> list[Finding]:
    out: list[Finding] = []
    for i, line in enumerate(text.splitlines(), start=1):
        m = USES_RE.match(line)
        if not m:
            continue
        ref = m.group(1)
        if not action_ref_pinned(ref):
            out.append(
                Finding(
                    check="action_pin",
                    status="fail",
                    file=relpath,
                    line=i,
                    detail=f"uses {ref!r} is not pinned to a 40-character commit SHA",
                    refs=["#57", "#44"],
                )
            )
    if not out:
        out.append(
            Finding(
                check="action_pin",
                status="pass",
                file=relpath,
                detail="every third-party uses: is pinned to a commit SHA",
                refs=["#57", "#44"],
            )
        )
    return out


def job_text_block(text: str, job_id: str) -> str:
    """Return YAML slice for one job under top-level jobs: (two-space indent)."""
    pattern = rf"(?ms)^  {re.escape(job_id)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)"
    m = re.search(pattern, text)
    return m.group(0) if m else ""


PR_CHECK_JOB_MARKERS: tuple[tuple[str, str, list[str]], ...] = (
    ("pr_check_shell_hygiene", "test-shell-hygiene.sh", ["#57"]),
    ("pr_check_pr_check_tests", "test-pr-check.sh", ["#57"]),
    ("pr_check_predict_cost", "test-predict-cost.sh", ["#57"]),
    ("pr_check_spec_template_drift", "test-spec-template-drift.sh", ["#57", "#161"]),
    ("pr_check_check_docs", "factory-check-docs.py --strict", ["#178"]),
    ("pr_check_prepublic", "factory-prepublic-check.py --strict", ["#178"]),
)


def check_pr_check_quality_gates(path: Path, text: str, relpath: str) -> list[Finding]:
    findings: list[Finding] = []
    if path.name != "pr-check.yml":
        return findings
    block = job_text_block(text, "pr-check")
    for check_id, marker, refs in PR_CHECK_JOB_MARKERS:
        needle = marker.split()[0]  # script name without CLI flags
        if needle in block and (
            " ".join(marker.split()[1:]) == ""
            or all(part in block for part in marker.split()[1:])
        ):
            findings.append(
                Finding(
                    check=check_id,
                    status="pass",
                    file=relpath,
                    job="pr-check",
                    detail=f"pr-check job runs {marker}",
                    refs=refs,
                )
            )
        else:
            script = marker.split()[0]
            findings.append(
                Finding(
                    check=check_id,
                    status="fail",
                    file=relpath,
                    job="pr-check",
                    detail=f"pr-check job does not run scripts/{script}"
                    + (
                        f" ({' '.join(marker.split()[1:])})"
                        if len(marker.split()) > 1
                        else ""
                    ),
                    refs=refs,
                )
            )
    return findings


def agent_job_has_python_pin(block: str) -> bool:
    if "setup-python" not in block:
        return False
    return PYTHON_VERSION_RE.search(block) is not None


def check_opencode_python_pin(path: Path, text: str, relpath: str) -> list[Finding]:
    findings: list[Finding] = []
    if path.name not in ("opencode-spike.yml", "opencode-fix.yml"):
        return findings
    block = job_text_block(text, "agent")
    if agent_job_has_python_pin(block):
        findings.append(
            Finding(
                check="oc_agent_python_pin",
                status="pass",
                file=relpath,
                job="agent",
                detail="agent job pins Python 3.12 or 3.13 via actions/setup-python",
                refs=["#148"],
            )
        )
    else:
        findings.append(
            Finding(
                check="oc_agent_python_pin",
                status="fail",
                file=relpath,
                job="agent",
                detail=(
                    "agent job lacks actions/setup-python with python-version 3.12 or 3.13 "
                    "(runner default may be 3.14; dbt harness specs can fail)"
                ),
                refs=["#148"],
            )
        )
    return findings


def check_approve_oc_workflow_run(
    data: dict[str, Any], text: str, relpath: str
) -> list[Finding]:
    if not relpath.endswith("approve-oc-runs.yml"):
        return []
    findings: list[Finding] = []
    on = data.get("on") or data.get(True) or {}
    has_wr = False
    if isinstance(on, dict):
        wr = on.get("workflow_run")
        if wr:
            has_wr = True
    if has_wr:
        findings.append(
            Finding(
                check="approve_oc_workflow_run",
                status="pass",
                file=relpath,
                detail="workflow_run trigger present for bot-opened oc/ PR held runs",
                refs=["#214", "#74"],
            )
        )
    else:
        findings.append(
            Finding(
                check="approve_oc_workflow_run",
                status="fail",
                file=relpath,
                detail=(
                    "only pull_request_target is configured; missing workflow_run for "
                    "pr-check and secret-scan runs stuck in action_required on bot PRs"
                ),
                refs=["#214", "#74"],
            )
        )
    if "startsWith(github.event.pull_request.head.ref, 'oc/')" in text:
        findings.append(
            Finding(
                check="approve_oc_branch_guard",
                status="pass",
                file=relpath,
                detail="job guards on oc/ branch prefix",
                refs=["#214"],
            )
        )
    else:
        findings.append(
            Finding(
                check="approve_oc_branch_guard",
                status="fail",
                file=relpath,
                detail="missing startsWith oc/ guard on pull_request head ref",
                refs=["#214"],
            )
        )
    if "head.repo.full_name == github.repository" in text:
        findings.append(
            Finding(
                check="approve_oc_fork_guard",
                status="pass",
                file=relpath,
                detail="job refuses fork PR workflows (same-repo guard)",
                refs=["#214", "#74"],
            )
        )
    else:
        findings.append(
            Finding(
                check="approve_oc_fork_guard",
                status="fail",
                file=relpath,
                detail="missing same-repo guard (fork workflows must never be approved)",
                refs=["#214", "#74"],
            )
        )
    return findings


def check_factory_site(path: Path, text: str, relpath: str) -> list[Finding]:
    if path.name != "factory-site.yml":
        return []
    findings: list[Finding] = []
    if "factory-site-build.sh" in text:
        findings.append(
            Finding(
                check="factory_site_build",
                status="pass",
                file=relpath,
                detail="build job runs scripts/factory-site-build.sh",
                refs=["#56"],
            )
        )
    else:
        findings.append(
            Finding(
                check="factory_site_build",
                status="fail",
                file=relpath,
                detail="missing scripts/factory-site-build.sh step",
                refs=["#56"],
            )
        )
    if "factory/budget.yml" in text or "factory/**" in text:
        findings.append(
            Finding(
                check="factory_site_budget_paths",
                status="pass",
                file=relpath,
                detail="push paths cover factory/ budget and site inputs",
                refs=["#56", "#170"],
            )
        )
    else:
        findings.append(
            Finding(
                check="factory_site_budget_paths",
                status="fail",
                file=relpath,
                detail="push paths should include factory/** or factory/budget.yml",
                refs=["#56"],
            )
        )
    if re.search(r"actions/deploy-pages@[0-9a-f]{40}", text, re.IGNORECASE):
        findings.append(
            Finding(
                check="factory_site_pages_deploy",
                status="pass",
                file=relpath,
                detail="deploy job uses SHA-pinned actions/deploy-pages",
                refs=["#56"],
            )
        )
    else:
        findings.append(
            Finding(
                check="factory_site_pages_deploy",
                status="fail",
                file=relpath,
                detail="deploy job missing SHA-pinned actions/deploy-pages",
                refs=["#56"],
            )
        )
    return findings


def check_factory_selected(workflows_dir: Path) -> list[Finding]:
    path = workflows_dir / "factory-selected.yml"
    if not path.is_file():
        return [
            Finding(
                check="factory_selected_optional",
                status="pass",
                file=".github/workflows/",
                detail="factory-selected.yml not present (optional owner paste #111)",
                refs=["#111"],
            )
        ]
    text = path.read_text(encoding="utf-8")
    rel = path.relative_to(ROOT).as_posix()
    findings = [
        Finding(
            check="factory_selected_optional",
            status="pass",
            file=rel,
            detail="factory-selected.yml is present",
            refs=["#111"],
        )
    ]
    if "factory-selected-dispatch.py" in text:
        findings.append(
            Finding(
                check="factory_selected_dispatch",
                status="pass",
                file=rel,
                detail="workflow invokes scripts/factory-selected-dispatch.py",
                refs=["#111"],
            )
        )
    else:
        findings.append(
            Finding(
                check="factory_selected_dispatch",
                status="fail",
                file=rel,
                detail="missing scripts/factory-selected-dispatch.py steps",
                refs=["#111"],
            )
        )
    return findings


def job_steps_text(job: dict[str, Any]) -> str:
    steps = job.get("steps") or []
    parts: list[str] = []
    for step in steps:
        if not isinstance(step, dict):
            continue
        if step.get("uses"):
            parts.append(f"uses: {step['uses']}")
        if step.get("run"):
            parts.append(f"run: {step['run']}")
        if step.get("name"):
            parts.append(step["name"])
    return "\n".join(parts)


def job_needs_harden_runner(job_id: str, job: dict[str, Any]) -> bool:
    blob = job_steps_text(job)
    if re.search(r"DEEPINFRA_API_KEY|api\.deepinfra\.com", blob):
        return True
    if "curl " in blob and job_id != "deploy":
        return True
    if job_id == "agent" and "opencode" in blob.lower():
        return True
    return False


def job_has_harden_runner(job: dict[str, Any]) -> bool:
    for step in job.get("steps") or []:
        if not isinstance(step, dict):
            continue
        uses = step.get("uses") or ""
        if isinstance(uses, str) and "step-security/harden-runner" in uses:
            return True
    return False


def check_harden_runner(data: dict[str, Any], relpath: str) -> list[Finding]:
    findings: list[Finding] = []
    jobs = data.get("jobs") or {}
    if not isinstance(jobs, dict):
        return findings
    any_required = False
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        if not job_needs_harden_runner(job_id, job):
            continue
        any_required = True
        if job_has_harden_runner(job):
            findings.append(
                Finding(
                    check="harden_runner",
                    status="pass",
                    file=relpath,
                    job=job_id,
                    detail="job uses step-security/harden-runner",
                    refs=["#44"],
                )
            )
        else:
            findings.append(
                Finding(
                    check="harden_runner",
                    status="fail",
                    file=relpath,
                    job=job_id,
                    detail="job has external egress but no step-security/harden-runner step",
                    refs=["#44"],
                )
            )
    if not any_required:
        findings.append(
            Finding(
                check="harden_runner",
                status="pass",
                file=relpath,
                detail="no job required harden-runner under current heuristics",
                refs=["#44"],
            )
        )
    return findings


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


def check_permissions(data: dict[str, Any], relpath: str) -> list[Finding]:
    findings: list[Finding] = []
    if "permissions" not in data:
        findings.append(
            Finding(
                check="workflow_permissions",
                status="fail",
                file=relpath,
                detail="workflow missing top-level permissions: block",
                refs=["#44"],
            )
        )
    else:
        top = data["permissions"]
        if permissions_value_broad(top):
            findings.append(
                Finding(
                    check="workflow_permissions",
                    status="fail",
                    file=relpath,
                    detail=f"workflow-level permissions are overly broad: {top!r}",
                    refs=["#44"],
                )
            )
        else:
            findings.append(
                Finding(
                    check="workflow_permissions",
                    status="pass",
                    file=relpath,
                    detail="workflow declares scoped top-level permissions",
                    refs=["#44"],
                )
            )
    return findings


def check_critic_review(workflows_dir: Path, data_files: dict[str, dict[str, Any]]) -> list[Finding]:
    has_file = (workflows_dir / "critic-review.yml").is_file()
    has_review_job = False
    for name, data in data_files.items():
        if not name.startswith("opencode"):
            continue
        jobs = data.get("jobs") or {}
        if isinstance(jobs, dict) and "review" in jobs:
            has_review_job = True
    if has_file or has_review_job:
        detail = "independent Critic review job or critic-review.yml is present"
        if has_review_job and not has_file:
            detail = "review job wired in opencode workflow (optional critic-review.yml not used)"
        return [
            Finding(
                check="critic_review_job",
                status="pass",
                file=".github/workflows/",
                detail=detail,
                refs=["#41"],
            )
        ]
    return [
        Finding(
            check="critic_review_job",
            status="fail",
            file=".github/workflows/",
            detail=(
                "no review job in opencode-spike.yml / opencode-fix.yml and no "
                "critic-review.yml (scripts exist; owner paste still pending — #41)"
            ),
            refs=["#41"],
        )
    ]


def audit_workflows(workflows_dir: Path) -> list[Finding]:
    findings: list[Finding] = []
    yml_files = sorted(workflows_dir.glob("*.yml"))
    if not yml_files:
        findings.append(
            Finding(
                check="workflows_present",
                status="fail",
                file=str(workflows_dir),
                detail="no .yml workflow files found",
                refs=[],
            )
        )
        return findings

    data_files: dict[str, dict[str, Any]] = {}
    for path in yml_files:
        try:
            rel = path.relative_to(ROOT).as_posix()
        except ValueError:
            rel = path.name
        data, text = load_workflow(path)
        data_files[path.name] = data
        findings.extend(find_unpinned_uses(text, rel))
        findings.extend(check_pr_check_quality_gates(path, text, rel))
        findings.extend(check_opencode_python_pin(path, text, rel))
        findings.extend(check_approve_oc_workflow_run(data, text, rel))
        findings.extend(check_harden_runner(data, rel))
        findings.extend(check_permissions(data, rel))
        findings.extend(check_factory_site(path, text, rel))

    findings.extend(check_critic_review(workflows_dir, data_files))
    findings.extend(check_factory_selected(workflows_dir))
    return findings


def summarize(findings: list[Finding]) -> dict[str, int]:
    passed = sum(1 for f in findings if f.status == "pass")
    failed = sum(1 for f in findings if f.status == "fail")
    return {"pass": passed, "fail": failed, "total": len(findings)}


def finding_records(findings: list[Finding]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for f in findings:
        row = asdict(f)
        row["category"] = CHECK_CATEGORIES.get(f.check, "other")
        out.append(row)
    return out


def category_summary(findings: list[Finding]) -> dict[str, dict[str, int]]:
    buckets: dict[str, dict[str, int]] = {}
    for f in findings:
        cat = CHECK_CATEGORIES.get(f.check, "other")
        bucket = buckets.setdefault(cat, {"pass": 0, "fail": 0, "total": 0})
        bucket["total"] += 1
        bucket[f.status] += 1
    return dict(sorted(buckets.items()))


def to_json_payload(workflows_dir: Path, findings: list[Finding]) -> dict[str, Any]:
    return {
        "workflows_dir": str(workflows_dir.resolve()),
        "owner_workflow_sync": "docs/OWNER_WORKFLOW_SYNC.md",
        "summary": summarize(findings),
        "categories": category_summary(findings),
        "findings": finding_records(findings),
    }


def render_markdown(workflows_dir: Path, findings: list[Finding]) -> str:
    summary = summarize(findings)
    lines = [
        "# Workflow audit",
        "",
        f"Directory: `{workflows_dir}`",
        "",
        f"**Summary:** {summary['pass']} passed, {summary['fail']} failed "
        f"({summary['total']} checks)",
        "",
        "Owner paste runbook: `docs/OWNER_WORKFLOW_SYNC.md`.",
        "",
    ]
    by_category: dict[str, list[Finding]] = {}
    for f in findings:
        cat = CHECK_CATEGORIES.get(f.check, "other")
        by_category.setdefault(cat, []).append(f)
    for cat in sorted(by_category.keys()):
        rows = by_category[cat]
        title = cat.replace("_", " ").title()
        lines.extend([f"## {title}", ""])
        lines.extend(
            [
                "| Status | Check | File | Job | Detail |",
                "| --- | --- | --- | --- | --- |",
            ]
        )
        for f in rows:
            job = f.job or ""
            refs = ", ".join(f.refs) if f.refs else ""
            detail = f.detail
            if refs:
                detail = f"{detail} ({refs})"
            status = "PASS" if f.status == "pass" else "FAIL"
            lines.append(
                f"| {status} | `{f.check}` | `{f.file}` | {job} | {detail} |"
            )
        lines.append("")
    lines.extend(
        [
            "Re-run after pasting workflow edits: "
            "`python3 scripts/factory-audit-workflows.py --strict`.",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--workflows-dir",
        type=Path,
        default=DEFAULT_WORKFLOWS,
        help="Path to .github/workflows (default: repo root)",
    )
    ap.add_argument("--json", action="store_true", help="Emit JSON on stdout")
    ap.add_argument(
        "--markdown",
        action="store_true",
        help="Emit Markdown report on stdout (default without --json)",
    )
    ap.add_argument(
        "--strict",
        action="store_true",
        help="Exit 1 if any check failed (default: always exit 0)",
    )
    args = ap.parse_args()
    workflows_dir = args.workflows_dir.resolve()
    if not workflows_dir.is_dir():
        print(f"factory-audit-workflows: not a directory: {workflows_dir}", file=sys.stderr)
        return 2

    findings = audit_workflows(workflows_dir)
    payload = to_json_payload(workflows_dir, findings)

    if args.json:
        json.dump(payload, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        print(render_markdown(workflows_dir, findings))

    failed = payload["summary"]["fail"]
    if args.strict and failed > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())