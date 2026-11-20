#!/usr/bin/env python3
"""One-command offline-first repo health scorecard for factory template/product repos.

Composes existing guardrails (workflow audit, protected-script lists, mode/budget files)
without duplicating their logic. Refs #178, #38.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

import yaml

VALID_MODES = frozenset({"template", "product"})
CORE_ARTIFACTS = (
    "AGENTS.md",
    ".factory/FACTORY.md",
    ".factory/DECISIONS.md",
    "LICENSE",
    "SECURITY.md",
)
BUDGET_KEYS = (
    "deepinfra_monthly_limit_usd",
    "issue_cap_usd",
    "issue_target_usd",
)
PROTECTED_HEADING = "Protected spend/security scripts"


@dataclass
class Check:
    id: str
    category: str
    status: str  # pass | warn | fail | skip
    detail: str
    extra: dict[str, Any] = field(default_factory=dict)


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parent.parent


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return None


def check_factory_mode(repo: Path) -> list[Check]:
    path = repo / ".factory" / "mode.yml"
    if not path.is_file():
        return [
            Check(
                id="mode_present",
                category="factory_mode",
                status="fail",
                detail="missing .factory/mode.yml (product repos fail closed without it)",
            )
        ]
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        return [
            Check(
                id="mode_valid",
                category="factory_mode",
                status="fail",
                detail=f"invalid .factory/mode.yml: {exc}",
            )
        ]
    mode = (data or {}).get("mode") if isinstance(data, dict) else None
    if mode in VALID_MODES:
        return [
            Check(
                id="mode_valid",
                category="factory_mode",
                status="pass",
                detail=f"mode is {mode!r}",
            )
        ]
    return [
        Check(
            id="mode_valid",
            category="factory_mode",
            status="fail",
            detail=f"mode must be template or product, got {mode!r}",
        )
    ]


def check_core_artifacts(repo: Path) -> list[Check]:
    out: list[Check] = []
    for rel in CORE_ARTIFACTS:
        path = repo / rel
        if path.is_file():
            out.append(
                Check(
                    id=f"artifact_{rel.replace('/', '_').replace('.', '_')}",
                    category="core_artifacts",
                    status="pass",
                    detail=f"{rel} present",
                )
            )
        else:
            out.append(
                Check(
                    id=f"artifact_{rel.replace('/', '_').replace('.', '_')}",
                    category="core_artifacts",
                    status="fail",
                    detail=f"missing {rel}",
                )
            )
    return out


def check_models_yaml(repo: Path) -> list[Check]:
    path = repo / ".factory" / "models.yaml"
    if not path.is_file():
        return [
            Check(
                id="models_yaml",
                category="models_yaml",
                status="fail",
                detail="missing .factory/models.yaml",
            )
        ]
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        return [
            Check(
                id="models_yaml_parse",
                category="models_yaml",
                status="fail",
                detail=f"cannot parse models.yaml: {exc}",
            )
        ]
    if not isinstance(data, dict):
        return [
            Check(
                id="models_yaml_shape",
                category="models_yaml",
                status="fail",
                detail="models.yaml root must be a mapping",
            )
        ]
    models = data.get("models")
    if not isinstance(models, list) or not models:
        return [
            Check(
                id="models_yaml_models",
                category="models_yaml",
                status="fail",
                detail="models.yaml must list at least one model under models:",
            )
        ]
    budget = data.get("budget")
    if not isinstance(budget, dict):
        return [
            Check(
                id="models_yaml_budget",
                category="models_yaml",
                status="fail",
                detail="models.yaml missing budget: mapping",
            )
        ]
    problems: list[str] = []
    for key in BUDGET_KEYS:
        val = budget.get(key)
        if val is None:
            problems.append(f"budget.{key} missing")
            continue
        if not isinstance(val, (int, float)) or val <= 0:
            problems.append(f"budget.{key} must be a positive number")
    cap = budget.get("issue_cap_usd")
    if isinstance(cap, (int, float)) and cap > 25:
        problems.append("budget.issue_cap_usd looks unusually high (> 25 USD)")
    monthly = budget.get("deepinfra_monthly_limit_usd")
    if isinstance(monthly, (int, float)) and monthly > 500:
        problems.append("budget.deepinfra_monthly_limit_usd looks unusually high (> 500 USD)")
    if problems:
        return [
            Check(
                id="models_yaml_budget",
                category="models_yaml",
                status="fail",
                detail="; ".join(problems),
            )
        ]
    return [
        Check(
            id="models_yaml",
            category="models_yaml",
            status="pass",
            detail="models.yaml parses with models list and sane budget caps",
        )
    ]


def python_version_tuple() -> tuple[int, int, int]:
    out = subprocess.run(
        [sys.executable, "-c", "import sys; print(sys.version_info.major, sys.version_info.minor, sys.version_info.micro)"],
        check=True,
        capture_output=True,
        text=True,
    )
    parts = out.stdout.strip().split()
    return int(parts[0]), int(parts[1]), int(parts[2])


def check_python_dbt(repo: Path) -> list[Check]:
    _ = repo
    major, minor, _micro = python_version_tuple()
    checks: list[Check] = []
    ver = f"{major}.{minor}"
    if major == 3 and minor >= 14:
        checks.append(
            Check(
                id="python_current",
                category="python_dbt",
                status="warn",
                detail=(
                    f"current python3 is {ver}; 3.14+ breaks many dbt releases "
                    "(pin 3.12 or 3.13 in CI and local venvs)"
                ),
            )
        )
    else:
        checks.append(
            Check(
                id="python_current",
                category="python_dbt",
                status="pass",
                detail=f"current python3 is {ver} (dbt-friendly)",
            )
        )
    compat = []
    for minor_want in (12, 13):
        for name in (f"python3.{minor_want}",):
            if shutil.which(name):
                compat.append(name)
    if compat:
        checks.append(
            Check(
                id="python_compat_bins",
                category="python_dbt",
                status="pass",
                detail=f"dbt-friendly interpreters on PATH: {', '.join(compat)}",
            )
        )
    else:
        checks.append(
            Check(
                id="python_compat_bins",
                category="python_dbt",
                status="warn",
                detail="no python3.12 or python3.13 on PATH (install one for dbt harnesses)",
            )
        )
    return checks


def protected_from_scan(repo: Path) -> list[str] | None:
    scan = repo / "scripts" / "opencode-artifact-scan.sh"
    if not scan.is_file():
        return None
    try:
        out = subprocess.run(
            ["bash", str(scan), "--list-protected"],
            check=True,
            capture_output=True,
            text=True,
            cwd=repo,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    paths: list[str] = []
    for line in out.stdout.splitlines():
        line = line.strip()
        if line.startswith("scripts/"):
            paths.append(line)
    return paths


def protected_from_factory_md(text: str) -> set[str]:
    paths: set[str] = set()
    in_block = False
    for line in text.splitlines():
        if PROTECTED_HEADING in line:
            in_block = True
            continue
        if in_block:
            if line.startswith("**") and PROTECTED_HEADING not in line:
                break
            m = re.match(r"^-\s+`(scripts/[^`]+)`", line.strip())
            if m:
                paths.add(m.group(1))
    return paths


def check_protected_scripts(repo: Path) -> list[Check]:
    listed = protected_from_scan(repo)
    if listed is None:
        return [
            Check(
                id="protected_scan",
                category="protected_scripts",
                status="skip",
                detail="scripts/opencode-artifact-scan.sh missing or --list-protected failed",
            )
        ]
    missing = [p for p in listed if not (repo / p).is_file()]
    checks: list[Check] = []
    if missing:
        checks.append(
            Check(
                id="protected_on_disk",
                category="protected_scripts",
                status="fail",
                detail=f"{len(missing)} protected script(s) missing on disk",
                extra={"missing": missing[:20]},
            )
        )
    else:
        checks.append(
            Check(
                id="protected_on_disk",
                category="protected_scripts",
                status="pass",
                detail=f"all {len(listed)} protected scripts exist on disk",
            )
        )
    factory_md = repo / ".factory" / "FACTORY.md"
    text = read_text(factory_md)
    if text is None:
        checks.append(
            Check(
                id="protected_factory_mirror",
                category="protected_scripts",
                status="warn",
                detail=".factory/FACTORY.md missing; cannot compare mirrored list",
            )
        )
        return checks
    mirrored = protected_from_factory_md(text)
    if not mirrored:
        checks.append(
            Check(
                id="protected_factory_mirror",
                category="protected_scripts",
                status="warn",
                detail="no protected-script bullets found in FACTORY.md",
            )
        )
        return checks
    scan_set = set(listed)
    only_scan = sorted(scan_set - mirrored)
    only_md = sorted(mirrored - scan_set)
    if only_scan or only_md:
        checks.append(
            Check(
                id="protected_factory_mirror",
                category="protected_scripts",
                status="fail",
                detail="PROTECTED_SCRIPTS and FACTORY.md lists differ",
                extra={"only_in_scan": only_scan, "only_in_factory_md": only_md},
            )
        )
    else:
        checks.append(
            Check(
                id="protected_factory_mirror",
                category="protected_scripts",
                status="pass",
                detail="PROTECTED_SCRIPTS matches FACTORY.md mirror",
            )
        )
    return checks


def check_workflow_hygiene(repo: Path) -> list[Check]:
    audit = repo / "scripts" / "factory-audit-workflows.py"
    if not audit.is_file():
        return [
            Check(
                id="workflow_audit",
                category="workflow_hygiene",
                status="skip",
                detail="scripts/factory-audit-workflows.py not present",
            )
        ]
    try:
        proc = subprocess.run(
            [sys.executable, str(audit), "--json"],
            check=True,
            capture_output=True,
            text=True,
            cwd=repo,
        )
        payload = json.loads(proc.stdout)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        return [
            Check(
                id="workflow_audit",
                category="workflow_hygiene",
                status="fail",
                detail=f"factory-audit-workflows.py --json failed: {exc}",
            )
        ]
    summary = payload.get("summary") or {}
    passed = int(summary.get("pass", 0))
    failed = int(summary.get("fail", 0))
    total = int(summary.get("total", 0))
    status = "pass" if failed == 0 else "warn"
    return [
        Check(
            id="workflow_audit",
            category="workflow_hygiene",
            status=status,
            detail=f"workflow audit: {passed} passed, {failed} failed ({total} checks)",
            extra={"summary": summary},
        )
    ]


def protect_main_supports_verify(script: Path) -> bool:
    text = read_text(script)
    if not text:
        return False
    return "--verify" in text


def check_live_protect_main(repo: Path) -> list[Check]:
    if not shutil.which("gh"):
        return [
            Check(
                id="protect_main_live",
                category="live",
                status="skip",
                detail="gh not on PATH",
            )
        ]
    script = repo / "scripts" / "protect-main.sh"
    if not script.is_file():
        return [
            Check(
                id="protect_main_live",
                category="live",
                status="skip",
                detail="scripts/protect-main.sh missing",
            )
        ]
    if not protect_main_supports_verify(script):
        return [
            Check(
                id="protect_main_live",
                category="live",
                status="skip",
                detail="protect-main.sh has no --verify mode yet",
            )
        ]
    try:
        proc = subprocess.run(
            ["bash", str(script), "--verify"],
            cwd=repo,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        return [
            Check(
                id="protect_main_live",
                category="live",
                status="fail",
                detail=f"protect-main.sh --verify could not run: {exc}",
            )
        ]
    tail = (proc.stdout + proc.stderr).strip().splitlines()
    snippet = tail[-1] if tail else f"exit {proc.returncode}"
    if proc.returncode == 0:
        return [
            Check(
                id="protect_main_live",
                category="live",
                status="pass",
                detail=snippet[:300],
            )
        ]
    return [
        Check(
            id="protect_main_live",
            category="live",
            status="fail",
            detail=f"protect-main.sh --verify exit {proc.returncode}: {snippet[:300]}",
        )
    ]


def run_doctor(repo: Path, live: bool) -> list[Check]:
    checks: list[Check] = []
    checks.extend(check_factory_mode(repo))
    checks.extend(check_core_artifacts(repo))
    checks.extend(check_models_yaml(repo))
    checks.extend(check_python_dbt(repo))
    checks.extend(check_protected_scripts(repo))
    checks.extend(check_workflow_hygiene(repo))
    if live:
        checks.extend(check_live_protect_main(repo))
    return checks


def summarize(checks: list[Check]) -> dict[str, int]:
    counts = {"pass": 0, "warn": 0, "fail": 0, "skip": 0}
    for c in checks:
        counts[c.status] = counts.get(c.status, 0) + 1
    return counts


def render_markdown(repo: Path, checks: list[Check]) -> str:
    summary = summarize(checks)
    lines = [
        "# Factory doctor",
        "",
        f"Repo: `{repo.resolve()}`",
        "",
        f"Summary: {summary['pass']} pass, {summary['warn']} warn, "
        f"{summary['fail']} fail, {summary['skip']} skip",
        "",
        "| Status | Category | Check | Detail |",
        "| --- | --- | --- | --- |",
    ]
    for c in checks:
        lines.append(f"| {c.status.upper()} | {c.category} | `{c.id}` | {c.detail} |")
    lines.append("")
    return "\n".join(lines)


def to_json_payload(repo: Path, checks: list[Check]) -> dict[str, Any]:
    return {
        "repo_dir": str(repo.resolve()),
        "summary": summarize(checks),
        "checks": [asdict(c) for c in checks],
    }


def exit_code(checks: list[Check], strict: bool) -> int:
    if not strict:
        return 0
    return 1 if any(c.status == "fail" for c in checks) else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "--repo-dir",
        type=Path,
        default=None,
        help="Repository root to inspect (default: parent of scripts/)",
    )
    ap.add_argument("--json", action="store_true", help="Emit JSON scorecard on stdout")
    ap.add_argument(
        "--strict",
        action="store_true",
        help="Exit 1 when any check fails",
    )
    ap.add_argument(
        "--live",
        action="store_true",
        help="Run online checks (protect-main --verify) when gh is available",
    )
    args = ap.parse_args()
    repo = (args.repo_dir or repo_root_from_script()).resolve()
    if not repo.is_dir():
        print(f"factory-doctor: not a directory: {repo}", file=sys.stderr)
        return 2

    checks = run_doctor(repo, live=args.live)
    payload = to_json_payload(repo, checks)

    if args.json:
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print(render_markdown(repo, checks))

    return exit_code(checks, args.strict)


if __name__ == "__main__":
    sys.exit(main())