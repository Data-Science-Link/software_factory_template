#!/usr/bin/env python3
"""Safe migration helper for product repos moving off copied template files (#156).

Scans a product checkout for copied factory scripts, legacy workflows, and mode.yml,
then emits a dry-run plan or applies local-only changes (caller stubs under
.factory/migration-callers/, never .github/workflows/ unless --write-workflows).

Refs #156, #178, #182. Python 3 stdlib only; offline when --template-dir is local.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

DEFAULT_TEMPLATE_REPO = "Data-Science-Link/software_factory_template"
DEFAULT_TAG = "v0.1.0"
TEMPLATE_REPO_PLACEHOLDER = "YOUR_ORG/software_factory_template"
LEGACY_TEMPLATE_REPO = "Data-Science-Link/software_factory_template"
OWNER_PLACEHOLDER = "YOUR_OWNER_GITHUB_LOGIN"
ARCHIVE_DIR = ".factory/migration-archive/scripts"
CALLERS_DIR = ".factory/migration-callers"
MODE_REL = ".factory/mode.yml"
TAG_RE = re.compile(r"^v\d+\.\d+\.\d+$")
REUSABLE_USES_RE = re.compile(
    r"uses:\s+[\w.-]+/[\w.-]+/\.github/workflows/(reusable-[-\w]+\.yml)@([^\s#'\"]+)",
    re.IGNORECASE,
)
STEPS_RE = re.compile(r"^\s+steps:\s*$", re.MULTILINE)
RUNS_ON_RE = re.compile(r"^\s+runs-on:\s*", re.MULTILINE)

# Minimal caller specs when docs/reusable-workflows/callers/ is absent (parity with init-repo).
CALLER_SPECS: list[dict[str, str]] = [
    {
        "filename": "pr-check.yml",
        "reusable": "reusable-pr-check.yml",
        "on_yaml": (
            "on:\n"
            "  pull_request:\n"
            "    types: [opened, edited, synchronize, reopened]\n"
        ),
        "job_id": "call-pr-check",
    },
    {
        "filename": "opencode-fix.yml",
        "reusable": "reusable-opencode-fix.yml",
        "on_yaml": (
            "on:\n"
            "  issue_comment:\n"
            "    types: [created]\n"
        ),
        "job_id": "call-opencode-fix",
    },
    {
        "filename": "opencode-run.yml",
        "reusable": "reusable-opencode-run.yml",
        "on_yaml": (
            "on:\n"
            "  issue_comment:\n"
            "    types: [created]\n"
        ),
        "job_id": "call-opencode-run",
    },
    {
        "filename": "opencode-spec.yml",
        "reusable": "reusable-opencode-spec.yml",
        "on_yaml": (
            "on:\n"
            "  issue_comment:\n"
            "    types: [created]\n"
        ),
        "job_id": "call-opencode-spec",
    },
    {
        "filename": "factory-site.yml",
        "reusable": "reusable-factory-site.yml",
        "on_yaml": "on:\n  workflow_dispatch:\n",
        "job_id": "call-factory-site",
    },
]


@dataclass
class ScriptRow:
    relpath: str
    classification: str  # identical_to_template | customized_locally | product_only


@dataclass
class Report:
    identical_scripts: list[str] = field(default_factory=list)
    customized_scripts: list[str] = field(default_factory=list)
    product_scripts: list[str] = field(default_factory=list)
    workflow_status: dict[str, Any] = field(default_factory=dict)
    mode_status: dict[str, Any] = field(default_factory=dict)
    actions: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def to_json_dict(self) -> dict[str, Any]:
        return {
            "identical_scripts": self.identical_scripts,
            "customized_scripts": self.customized_scripts,
            "product_scripts": self.product_scripts,
            "workflow_status": self.workflow_status,
            "mode_status": self.mode_status,
            "actions": self.actions,
            "warnings": self.warnings,
        }


def template_root() -> Path:
    return Path(__file__).resolve().parent.parent


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def template_script_index(template_dir: Path) -> dict[str, str]:
    scripts = template_dir / "scripts"
    out: dict[str, str] = {}
    if not scripts.is_dir():
        return out
    for path in sorted(scripts.iterdir()):
        if path.is_file():
            out[path.name] = file_sha256(path)
    return out


def classify_scripts(repo: Path, template_index: dict[str, str]) -> list[ScriptRow]:
    rows: list[ScriptRow] = []
    scripts_dir = repo / "scripts"
    if not scripts_dir.is_dir():
        return rows
    for path in sorted(scripts_dir.iterdir()):
        if not path.is_file():
            continue
        rel = f"scripts/{path.name}"
        if path.name not in template_index:
            rows.append(ScriptRow(rel, "product_only"))
            continue
        if file_sha256(path) == template_index[path.name]:
            rows.append(ScriptRow(rel, "identical_to_template"))
        else:
            rows.append(ScriptRow(rel, "customized_locally"))
    return rows


def read_mode(path: Path) -> tuple[str | None, str]:
    if not path.is_file():
        return None, "missing"
    mode: str | None = None
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if stripped.startswith("mode:"):
            mode = stripped.split(":", 1)[1].strip()
            break
    if mode is None:
        return None, "unreadable"
    if mode == "product":
        return mode, "ok"
    return mode, "not_product"


def mode_yml_content() -> str:
    return "# owner-only\nmode: product\n"


def substitute_caller(
    text: str, template_repo: str, tag: str, owner: str | None = None
) -> str:
    text = text.replace("{{TEMPLATE_REPO}}", template_repo)
    text = text.replace("{{TAG}}", tag)
    text = text.replace(TEMPLATE_REPO_PLACEHOLDER, template_repo)
    text = text.replace(LEGACY_TEMPLATE_REPO, template_repo)
    text = text.replace("@v0.0.0", f"@{tag}")
    if owner:
        text = text.replace(OWNER_PLACEHOLDER, owner)
    text = re.sub(
        r"((?:[\w.-]+/){2}\.github/workflows/reusable-[\w.-]+\.yml)@[^\s\"']+",
        rf"\1@{tag}",
        text,
    )
    text = re.sub(
        r"(factory_ref:\s*)v\d+\.\d+\.\d+",
        rf"\1{tag}",
        text,
    )
    return text


def assert_caller_placeholders_resolved(text: str, *, owner: str) -> None:
    """Raise ValueError when template or owner placeholders survive substitution."""
    leftovers: list[str] = []
    if "YOUR_ORG" in text:
        leftovers.append("YOUR_ORG")
    if OWNER_PLACEHOLDER in text:
        leftovers.append(OWNER_PLACEHOLDER)
    if leftovers:
        raise ValueError(
            "caller workflow still contains template placeholders: "
            + ", ".join(leftovers)
        )


def render_generated_caller(spec: dict[str, str], template_repo: str, tag: str) -> str:
    wf_name = Path(spec["filename"]).stem
    uses = f"{template_repo}/.github/workflows/{spec['reusable']}@{tag}"
    lines = [
        f"# Caller stub: pins factory CI at {template_repo}@{tag}. Owner paste only (#156).",
        f"name: {wf_name}",
        "",
        spec["on_yaml"].rstrip(),
        "",
        "jobs:",
        f"  {spec['job_id']}:",
        f"    uses: {uses}",
        "    secrets: inherit",
        f"    with:",
        f"      factory_ref: {tag}",
        "",
    ]
    return "\n".join(lines)


def load_caller_stubs(
    template_dir: Path,
    template_repo: str,
    tag: str,
    owner: str | None = None,
) -> dict[str, str]:
    callers_dir = template_dir / "docs" / "reusable-workflows" / "callers"
    out: dict[str, str] = {}
    if callers_dir.is_dir():
        for path in sorted(callers_dir.glob("*.yml")) + sorted(callers_dir.glob("*.yaml")):
            body = substitute_caller(
                path.read_text(encoding="utf-8"), template_repo, tag, owner
            )
            if owner:
                assert_caller_placeholders_resolved(body, owner=owner)
            out[path.name] = body
        if out:
            return out
    for spec in CALLER_SPECS:
        out[spec["filename"]] = render_generated_caller(spec, template_repo, tag)
    return out


def classify_workflow(
    path: Path, template_repo: str, tag: str
) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    rel = str(path.relative_to(path.parent.parent.parent))
    matches = list(REUSABLE_USES_RE.finditer(text))
    if matches:
        pins = sorted({m.group(2) for m in matches})
        pin_ok = tag in pins and len(pins) == 1
        return {
            "path": rel,
            "kind": "thin_caller",
            "reusable_refs": [m.group(1) for m in matches],
            "pins": pins,
            "pin_matches_tag": pin_ok,
        }
    if STEPS_RE.search(text) or RUNS_ON_RE.search(text):
        return {"path": rel, "kind": "legacy_copied"}
    if REUSABLE_USES_RE.search(text):
        return {"path": rel, "kind": "thin_caller", "pins": []}
    return {"path": rel, "kind": "unknown"}


def scan_workflows(repo: Path, template_repo: str, tag: str) -> dict[str, Any]:
    wf_dir = repo / ".github" / "workflows"
    legacy: list[dict[str, Any]] = []
    thin: list[dict[str, Any]] = []
    unknown: list[dict[str, Any]] = []
    present_names: set[str] = set()
    if wf_dir.is_dir():
        for path in sorted(wf_dir.glob("*.yml")) + sorted(wf_dir.glob("*.yaml")):
            present_names.add(path.name)
            row = classify_workflow(path, template_repo, tag)
            kind = row.get("kind")
            if kind == "legacy_copied":
                legacy.append(row)
            elif kind == "thin_caller":
                thin.append(row)
            else:
                unknown.append(row)
    return {
        "legacy": legacy,
        "thin_callers": thin,
        "unknown": unknown,
        "present_workflow_names": sorted(present_names),
    }


def missing_callers(
    workflow_scan: dict[str, Any], expected: dict[str, str]
) -> list[str]:
    present = set(workflow_scan.get("present_workflow_names", []))
    thin_names = {Path(r["path"]).name for r in workflow_scan.get("thin_callers", [])}
    have = present & thin_names
    return sorted(name for name in expected if name not in have)


def build_report(
    repo: Path,
    template_dir: Path,
    template_repo: str,
    tag: str,
    owner: str | None = None,
) -> Report:
    template_index = template_script_index(template_dir)
    rows = classify_scripts(repo, template_index)
    report = Report()
    for row in rows:
        if row.classification == "identical_to_template":
            report.identical_scripts.append(row.relpath)
        elif row.classification == "customized_locally":
            report.customized_scripts.append(row.relpath)
        else:
            report.product_scripts.append(row.relpath)

    mode, status = read_mode(repo / MODE_REL)
    report.mode_status = {"status": status, "mode": mode}

    wf = scan_workflows(repo, template_repo, tag)
    stubs = load_caller_stubs(template_dir, template_repo, tag, owner)
    missing = missing_callers(wf, stubs)
    report.workflow_status = {
        **wf,
        "missing_callers": missing,
        "recommended_callers_dir": CALLERS_DIR,
        "pin_tag": tag,
        "template_repo": template_repo,
    }

    if report.customized_scripts:
        report.warnings.append(
            "Customized factory scripts are preserved; review before retiring copies."
        )
    for leg in wf.get("legacy", []):
        report.warnings.append(
            f"Legacy copied workflow {leg['path']} — replace with thin caller pinned to {tag}."
        )
    for thin in wf.get("thin_callers", []):
        if not thin.get("pin_matches_tag", True):
            report.warnings.append(
                f"Thin caller {thin['path']} pins {thin.get('pins')} — bump to {tag}."
            )
    if status != "ok":
        report.warnings.append("Set .factory/mode.yml to mode: product for product repos.")

    return report, stubs


def plan_actions(
    report: Report,
    stubs: dict[str, str],
    *,
    apply: bool,
    force: bool,
    prune_identical: bool,
    write_workflows: bool,
) -> None:
    mode_status = report.mode_status.get("status")
    if mode_status in ("missing", "not_product", "unreadable"):
        action = f"write {MODE_REL} (mode: product)"
        if mode_status == "not_product" and not force:
            action += " (needs --force to overwrite existing mode)"
        report.actions.append(action)

    for name in sorted(stubs):
        report.actions.append(f"write {CALLERS_DIR}/{name}")

    if write_workflows:
        for name in sorted(stubs):
            report.actions.append(f"write .github/workflows/{name} (--write-workflows)")
    else:
        report.actions.append(
            "owner pastes workflows from .factory/migration-callers/ (default; no --write-workflows)"
        )

    if prune_identical and report.identical_scripts:
        dest = ARCHIVE_DIR
        for rel in report.identical_scripts:
            report.actions.append(f"archive {rel} -> {dest}/{Path(rel).name}")
    elif report.identical_scripts:
        report.actions.append(
            f"eligible to archive {len(report.identical_scripts)} identical script(s) with --prune-identical"
        )

    if report.customized_scripts:
        report.actions.append(
            f"preserve {len(report.customized_scripts)} customized script(s) (never auto-deleted)"
        )

    if not apply:
        for i, action in enumerate(report.actions):
            if not action.startswith("[dry-run]"):
                report.actions[i] = f"[dry-run] {action}"


def apply_changes(
    repo: Path,
    report: Report,
    stubs: dict[str, str],
    *,
    force: bool,
    prune_identical: bool,
    write_workflows: bool,
) -> list[str]:
    executed: list[str] = []
    mode_path = repo / MODE_REL
    mode_status = report.mode_status.get("status")
    if mode_status in ("missing", "unreadable") or (
        mode_status == "not_product" and force
    ):
        mode_path.parent.mkdir(parents=True, exist_ok=True)
        mode_path.write_text(mode_yml_content(), encoding="utf-8")
        executed.append(f"wrote {MODE_REL}")
        report.mode_status = {"status": "ok", "mode": "product"}

    callers_root = repo / CALLERS_DIR
    for name, body in sorted(stubs.items()):
        dest = callers_root / name
        if dest.exists() and not force:
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(body, encoding="utf-8")
        executed.append(f"wrote {CALLERS_DIR}/{name}")

    if write_workflows:
        wf_root = repo / ".github" / "workflows"
        wf_root.mkdir(parents=True, exist_ok=True)
        for name, body in sorted(stubs.items()):
            dest = wf_root / name
            if dest.exists() and not force:
                continue
            dest.write_text(body, encoding="utf-8")
            executed.append(f"wrote .github/workflows/{name}")

    if prune_identical:
        archive_root = repo / ARCHIVE_DIR
        archive_root.mkdir(parents=True, exist_ok=True)
        for rel in report.identical_scripts:
            src = repo / rel
            if not src.is_file():
                continue
            dest = archive_root / src.name
            shutil.move(str(src), str(dest))
            executed.append(f"archived {rel} -> {ARCHIVE_DIR}/{src.name}")

    return executed


def print_plan(report: Report, repo: Path, tag: str, template_repo: str) -> None:
    print("Factory adopter migration plan")
    print(f"  Repo: {repo.resolve()}")
    print(f"  Pin: {template_repo}@{tag}")
    print("")

    print(f"Scripts — identical to template ({len(report.identical_scripts)}):")
    for rel in report.identical_scripts:
        print(f"  = {rel}")
    print(f"Scripts — customized locally ({len(report.customized_scripts)}):")
    for rel in report.customized_scripts:
        print(f"  ~ {rel}")
    print(f"Scripts — product-only ({len(report.product_scripts)}):")
    for rel in report.product_scripts:
        print(f"  + {rel}")
    print("")

    wf = report.workflow_status
    print(f"Workflows — legacy copied ({len(wf.get('legacy', []))}):")
    for row in wf.get("legacy", []):
        print(f"  ! {row['path']}")
    print(f"Workflows — thin callers ({len(wf.get('thin_callers', []))}):")
    for row in wf.get("thin_callers", []):
        pin = row.get("pins", [])
        print(f"  @ {row['path']} pins {pin}")
    print(f"Missing thin callers ({len(wf.get('missing_callers', []))}):")
    for name in wf.get("missing_callers", []):
        print(f"  ? .github/workflows/{name}")
    print("")

    mode = report.mode_status
    print(f"Mode: {mode.get('mode')!r} ({mode.get('status')})")
    print("")

    if report.warnings:
        print("Warnings:")
        for w in report.warnings:
            print(f"  - {w}")
        print("")

    print("Planned actions:")
    for action in report.actions:
        print(f"  • {action}")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo-dir", type=Path, required=True, help="Product repo root to scan")
    ap.add_argument("--tag", default=DEFAULT_TAG, help=f"Template semver tag (default: {DEFAULT_TAG})")
    ap.add_argument(
        "--template-repo",
        default=DEFAULT_TEMPLATE_REPO,
        help=f"Template owner/repo (default: {DEFAULT_TEMPLATE_REPO})",
    )
    ap.add_argument(
        "--template-dir",
        type=Path,
        default=None,
        help="Checkout of the factory template (default: parent of this script)",
    )
    ap.add_argument(
        "--apply",
        action="store_true",
        help="Write mode.yml, migration-callers/, and optional archive (default: dry-run)",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="Overwrite migration-callers and mode.yml when not product",
    )
    ap.add_argument(
        "--prune-identical",
        action="store_true",
        help="With --apply, move identical template script copies to migration-archive",
    )
    ap.add_argument(
        "--write-workflows",
        action="store_true",
        help="With --apply, also write .github/workflows/ caller stubs (owner risk)",
    )
    ap.add_argument("--json", action="store_true", help="Emit JSON report on stdout")
    ap.add_argument(
        "--owner",
        default=None,
        help=(
            "GitHub login allowed to trigger /oc workflows; substitutes "
            f"{OWNER_PLACEHOLDER} in caller stubs"
        ),
    )
    return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    repo = args.repo_dir.expanduser().resolve()
    template_dir = (args.template_dir or template_root()).resolve()

    if not repo.is_dir():
        print(f"factory-migrate-adopter: repo dir not found: {repo}", file=sys.stderr)
        return 2
    if not template_dir.is_dir():
        print(f"factory-migrate-adopter: template dir not found: {template_dir}", file=sys.stderr)
        return 2
    if ".." in args.template_repo or args.template_repo.count("/") != 1:
        print("factory-migrate-adopter: --template-repo must be OWNER/REPO", file=sys.stderr)
        return 2
    if not TAG_RE.fullmatch(args.tag):
        print(
            f"factory-migrate-adopter: --tag should look like semver vX.Y.Z, got {args.tag!r}",
            file=sys.stderr,
        )
        return 2
    if args.prune_identical and not args.apply:
        print(
            "factory-migrate-adopter: --prune-identical requires --apply",
            file=sys.stderr,
        )
        return 2
    if args.owner is not None and not re.fullmatch(r"[\w.-]+", args.owner):
        print(
            "factory-migrate-adopter: --owner must be a GitHub username (letters, digits, - .)",
            file=sys.stderr,
        )
        return 2

    report, stubs = build_report(
        repo, template_dir, args.template_repo, args.tag, args.owner
    )
    plan_actions(
        report,
        stubs,
        apply=args.apply,
        force=args.force,
        prune_identical=args.prune_identical,
        write_workflows=args.write_workflows,
    )

    if args.apply:
        executed = apply_changes(
            repo,
            report,
            stubs,
            force=args.force,
            prune_identical=args.prune_identical,
            write_workflows=args.write_workflows,
        )
        for line in executed:
            report.actions.append(f"[applied] {line}")

    if args.json:
        print(json.dumps(report.to_json_dict(), indent=2, sort_keys=True))
    else:
        print_plan(report, repo, args.tag, args.template_repo)

    return 0


if __name__ == "__main__":
    sys.exit(main())