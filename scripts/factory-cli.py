#!/usr/bin/env python3
"""Unified zero-dependency entrypoint for factory maintenance scripts.

Usage:
    python3 scripts/factory-cli.py <command> [args...]
    python3 scripts/factory-cli.py list [--json]
    python3 scripts/factory-cli.py help
"""
from __future__ import annotations

import difflib
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

DEFAULT_SCRIPTS_DIR = Path(__file__).resolve().parent

GROUP_ORDER = (
    "Setup & Health",
    "Planning & Specs",
    "Build & Review",
    "Spend & Site",
    "Release & Ops",
)


@dataclass(frozen=True)
class CommandSpec:
    name: str
    group: str
    script: str  # filename under scripts/ (e.g. factory-doctor.py)
    description: str


COMMANDS: tuple[CommandSpec, ...] = (
    CommandSpec(
        "doctor",
        "Setup & Health",
        "factory-doctor.py",
        "Offline-first repo health scorecard for template and product repos.",
    ),
    CommandSpec(
        "init",
        "Setup & Health",
        "factory-init-repo.py",
        "Scaffold a product repo to adopt the Software Factory.",
    ),
    CommandSpec(
        "models-check",
        "Setup & Health",
        "factory-models-check.py",
        "Offline schema, routing, and price sanity check for .factory/models.yaml.",
    ),
    CommandSpec(
        "model-scout",
        "Setup & Health",
        "factory-model-scout.py",
        "Compare DeepInfra catalog prices to models.yaml and propose updates (proposal-only).",
    ),
    CommandSpec(
        "triage",
        "Planning & Specs",
        "factory-issue-triage.py",
        "Backlog triage helper for the Factory Manager.",
    ),
    CommandSpec(
        "spec-lint",
        "Planning & Specs",
        "factory-spec-lint.py",
        "Standalone factory spec quality linter (offline).",
    ),
    CommandSpec(
        "spec-check",
        "Planning & Specs",
        "factory-spec-check.py",
        "Validate a factory spec file or issue-comment body.",
    ),
    CommandSpec(
        "backlog",
        "Planning & Specs",
        "factory-backlog.py",
        "Normalized open-backlog JSON for the factory site.",
    ),
    CommandSpec(
        "decision-log",
        "Planning & Specs",
        "factory-decision-log.py",
        "Validate, list, and append entries in .factory/DECISIONS.md.",
    ),
    CommandSpec(
        "run-review",
        "Build & Review",
        "factory-run-review.py",
        "Deterministic post-merge /oc run-review summary.",
    ),
    CommandSpec(
        "fix-policy",
        "Build & Review",
        "factory-fix-policy.py",
        "Fix-round circuit breaker for complex /oc builds.",
    ),
    CommandSpec(
        "audit-workflows",
        "Build & Review",
        "factory-audit-workflows.py",
        "Offline audit of .github/workflows for factory guardrails.",
    ),
    CommandSpec(
        "check-docs",
        "Build & Review",
        "factory-check-docs.py",
        "Markdown links, heading anchors, and script reference audit.",
    ),
    CommandSpec(
        "critic-context",
        "Build & Review",
        "factory-critic-context.py",
        "Pack PR diff, spec, and harness verification for the Independent Critic reviewer.",
    ),
    CommandSpec(
        "critic-run",
        "Build & Review",
        "factory-critic-run.py",
        "Run the Independent Critic model (or dry-run) on a critic-input bundle.",
    ),
    CommandSpec(
        "test-all",
        "Build & Review",
        "test-all.sh",
        "Run every offline scripts/test-*.sh and print a pass/fail table.",
    ),
    CommandSpec(
        "cost-digest",
        "Spend & Site",
        "factory-cost-digest.py",
        "CFO spend and quality digest from factory run records.",
    ),
    CommandSpec(
        "cost-reconcile",
        "Spend & Site",
        "factory-cost-reconcile.py",
        "Offline cost reconciliation and run-record drift audit vs models.yaml.",
    ),
    CommandSpec(
        "predict-cost",
        "Spend & Site",
        "factory-predict-cost.py",
        "Route a model and predict run cost from a spec + models.yaml.",
    ),
    CommandSpec(
        "routing-report",
        "Spend & Site",
        "factory-routing-report.py",
        "Offline routing quality report from factory run records and models.yaml.",
    ),
    CommandSpec(
        "cache-report",
        "Spend & Site",
        "factory-cache-report.py",
        "DeepInfra prompt-cache hit rates from factory run records.",
    ),
    CommandSpec(
        "site",
        "Spend & Site",
        "factory-site.py",
        "Render the static four-tab factory site from source files.",
    ),
    CommandSpec(
        "site-smoke",
        "Spend & Site",
        "factory-site-smoke.py",
        "Offline smoke and HTML/SVG checks for the static factory site.",
    ),
    CommandSpec(
        "prepublic",
        "Release & Ops",
        "factory-prepublic-check.py",
        "Scan tracked files before making a template/factory repo public.",
    ),
    CommandSpec(
        "release",
        "Release & Ops",
        "factory-release.py",
        "Release-readiness scorecard and changelog draft (read-only).",
    ),
    CommandSpec(
        "branch-cleanup",
        "Release & Ops",
        "factory-branch-cleanup.py",
        "Dry-run branch hygiene report for factory worker branches (oc/, cursor/).",
    ),
    CommandSpec(
        "sync-repos",
        "Release & Ops",
        "factory-sync-repos.py",
        "Open or update sync PRs to bump reusable-workflow pin tags.",
    ),
    CommandSpec(
        "reusable-check",
        "Release & Ops",
        "factory-reusable-check.py",
        "Offline contract check for docs/reusable-workflows templates and callers.",
    ),
    CommandSpec(
        "migrate-adopter",
        "Release & Ops",
        "factory-migrate-adopter.py",
        "Dry-run or apply migration from copied template files to pinned callers.",
    ),
    CommandSpec(
        "owner-pack",
        "Release & Ops",
        "factory-owner-pack.py",
        "Unified owner launch-readiness gate (doctor, docs, workflows, release).",
    ),
)

COMMAND_BY_NAME = {c.name: c for c in COMMANDS}


def display_target(scripts_dir: Path, script: str) -> str:
    if scripts_dir == DEFAULT_SCRIPTS_DIR:
        return f"scripts/{script}"
    return str(scripts_dir / script)


def target_path(scripts_dir: Path, script: str) -> Path:
    return scripts_dir / script


def is_available(scripts_dir: Path, spec: CommandSpec) -> bool:
    path = target_path(scripts_dir, spec.script)
    return path.is_file()


def parse_global_args(argv: Sequence[str]) -> tuple[Path, list[str]]:
    scripts_dir = DEFAULT_SCRIPTS_DIR
    rest: list[str] = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--scripts-dir":
            if i + 1 >= len(argv):
                print("factory-cli: --scripts-dir requires a directory path", file=sys.stderr)
                sys.exit(2)
            scripts_dir = Path(argv[i + 1]).resolve()
            i += 2
            continue
        rest.append(arg)
        i += 1
    return scripts_dir, rest


def print_help(scripts_dir: Path) -> None:
    print(
        "factory-cli — unified entrypoint for factory maintenance scripts\n"
        "\n"
        "Usage:\n"
        "  python3 scripts/factory-cli.py <command> [args...]\n"
        "  python3 scripts/factory-cli.py list [--json]\n"
        "  python3 scripts/factory-cli.py [--help|-h]\n"
        "\n"
        "Global options:\n"
        "  --scripts-dir DIR   Directory containing delegated script files (for tests)\n"
    )
    by_group: dict[str, list[CommandSpec]] = {g: [] for g in GROUP_ORDER}
    for spec in COMMANDS:
        by_group.setdefault(spec.group, []).append(spec)

    print("Commands by lifecycle phase:\n")
    for group in GROUP_ORDER:
        specs = by_group.get(group, [])
        if not specs:
            continue
        print(f"  {group}")
        for spec in specs:
            mark = "yes" if is_available(scripts_dir, spec) else "no"
            target = display_target(scripts_dir, spec.script)
            print(f"    {spec.name:<16} [{mark}] {target}")
            print(f"      {spec.description}")
        print()


def cmd_list(scripts_dir: Path, args: list[str]) -> int:
    if args == ["--help"] or args == ["-h"]:
        print("Usage: factory-cli list [--json]")
        return 0
    if args and args != ["--json"]:
        print(f"factory-cli: unknown option(s) for list: {' '.join(args)}", file=sys.stderr)
        return 2

    rows = []
    for spec in COMMANDS:
        rows.append(
            {
                "name": spec.name,
                "group": spec.group,
                "target": display_target(scripts_dir, spec.script),
                "description": spec.description,
                "available": is_available(scripts_dir, spec),
            }
        )

    if args == ["--json"]:
        print(json.dumps({"commands": rows}, indent=2, sort_keys=True))
    else:
        for row in rows:
            flag = "available" if row["available"] else "missing"
            print(f"{row['name']}\t{row['group']}\t{row['target']}\t[{flag}]\t{row['description']}")
    return 0


def suggest_command(name: str) -> str | None:
    names = [c.name for c in COMMANDS]
    matches = difflib.get_close_matches(name, names, n=3, cutoff=0.6)
    if not matches:
        return None
    if matches[0] == name:
        return matches[0]
    return matches[0]


def delegate(scripts_dir: Path, spec: CommandSpec, args: list[str]) -> int:
    path = target_path(scripts_dir, spec.script)
    if not path.is_file():
        rel = display_target(scripts_dir, spec.script)
        print(
            f"factory-cli: target script not found: {rel}\n"
            "Sync or copy factory scripts into this repo's scripts/ directory, "
            "or run from a full software_factory_template checkout.",
            file=sys.stderr,
        )
        return 127

    if spec.script.endswith(".sh"):
        runner = ["bash", str(path), *args]
    else:
        runner = [sys.executable, str(path), *args]

    env = os.environ.copy()
    # Preserve caller cwd; child scripts resolve repo root from their own path.
    result = subprocess.run(runner, env=env)
    return result.returncode


def main(argv: list[str] | None = None) -> int:
    raw = list(argv if argv is not None else sys.argv[1:])
    scripts_dir, args = parse_global_args(raw)

    if not args or args == ["--help"] or args == ["-h"] or args == ["help"]:
        print_help(scripts_dir)
        return 0

    command, *rest = args

    if command == "list":
        return cmd_list(scripts_dir, rest)

    spec = COMMAND_BY_NAME.get(command)
    if spec is None:
        hint = suggest_command(command)
        msg = f"factory-cli: unknown command {command!r}"
        if hint:
            msg += f" (did you mean {hint!r}?)"
        else:
            msg += f"; known commands: {', '.join(COMMAND_BY_NAME)}"
        print(msg, file=sys.stderr)
        return 2

    return delegate(scripts_dir, spec, rest)


if __name__ == "__main__":
    sys.exit(main())