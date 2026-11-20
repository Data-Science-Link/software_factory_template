#!/usr/bin/env python3
"""Scaffold a product repo to adopt the Software Factory in one command.

Refs #178, #156, #37. Repo-agnostic, idempotent, offline-safe (no network).
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Callable

import yaml

DEFAULT_TEMPLATE_REPO = "Data-Science-Link/software_factory_template"
DEFAULT_TAG = "v0.1.0"

# Minimal caller stubs when docs/reusable-workflows/callers/ is absent (#156).
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
        "filename": "secret-scan.yml",
        "reusable": "reusable-secret-scan.yml",
        "on_yaml": "on:\n  push:\n  pull_request:\n",
        "job_id": "call-secret-scan",
    },
    {
        "filename": "opencode-spike.yml",
        "reusable": "reusable-opencode-spike.yml",
        "on_yaml": (
            "on:\n"
            "  issue_comment:\n"
            "    types: [created]\n"
        ),
        "job_id": "call-opencode-spike",
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
        "filename": "approve-oc-runs.yml",
        "reusable": "reusable-approve-oc-runs.yml",
        "on_yaml": (
            "on:\n"
            "  pull_request_target:\n"
            "    types: [opened, synchronize, reopened]\n"
        ),
        "job_id": "call-approve-oc-runs",
    },
]


@dataclass
class WriteResult:
    created: list[str] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)
    overwritten: list[str] = field(default_factory=list)
    dry_run: list[str] = field(default_factory=list)


def template_root() -> Path:
    return Path(__file__).resolve().parent.parent


def substitute_caller(text: str, template_repo: str, tag: str) -> str:
    text = text.replace("{{TEMPLATE_REPO}}", template_repo)
    text = text.replace("{{TAG}}", tag)
    text = text.replace("@v0.0.0", f"@{tag}")
    # Replace any pinned tag on reusable workflow paths.
    text = re.sub(
        r"((?:[\w.-]+/){2}\.github/workflows/reusable-[\w.-]+\.yml)@[^\s\"']+",
        rf"\1@{tag}",
        text,
    )
    return text


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
        "",
    ]
    return "\n".join(lines)


def load_caller_stubs(
    template_dir: Path, template_repo: str, tag: str
) -> dict[str, str]:
    callers_dir = template_dir / "docs" / "reusable-workflows" / "callers"
    out: dict[str, str] = {}
    if callers_dir.is_dir():
        for path in sorted(callers_dir.glob("*.yml")) + sorted(callers_dir.glob("*.yaml")):
            out[path.name] = substitute_caller(
                path.read_text(encoding="utf-8"), template_repo, tag
            )
        if out:
            return out
    for spec in CALLER_SPECS:
        out[spec["filename"]] = render_generated_caller(spec, template_repo, tag)
    return out


def mode_yml() -> str:
    return "# owner-only\nmode: product\n"


def models_yml(template_repo: str, tag: str) -> str:
    return (
        "# Product-repo starter. Canonical routing lives in the pinned template tag (#156).\n"
        f"# Defaults: https://github.com/{template_repo}/blob/{tag}/.factory/models.yaml\n"
        "# Owner-only: workers must not edit.\n"
        "\n"
        "models:\n"
        "  - id: deepseek-ai/DeepSeek-V4-Flash-0731\n"
        "    provider: deepinfra\n"
        "    notes: Override here only when this repo diverges from the pinned template.\n"
        "\n"
        "budget:\n"
        "  deepinfra_monthly_limit_usd: 10\n"
        "  issue_cap_usd: 1.00\n"
        "  issue_target_usd: 0.15\n"
        "  # factory/budget.yml (when added): monthly_usd 10, weekly_usd 2.50 (#169 D4)\n"
    )


def decisions_md(repo_name: str, template_repo: str, tag: str) -> str:
    today = date.today().isoformat()
    return (
        "# Decision log\n"
        "\n"
        "Append-only. Newest at the bottom.\n"
        "\n"
        "## Template\n"
        "\n"
        "```\n"
        "### YYYY-MM-DD — Short title\n"
        "- **Decision:** what we chose\n"
        "- **Decided by:** owner (quote or link) / manager (sequencing or technical call)\n"
        "- **Why:** one or two sentences\n"
        "- **Alternatives:** what we rejected (optional)\n"
        "- **Revisit when:** trigger to reconsider (optional)\n"
        "```\n"
        "\n"
        "## Log\n"
        "\n"
        f"### {today} — Adopted Software Factory\n"
        f"- **Decision:** Initialize `{repo_name}` as a factory **product** repo "
        f"(`.factory/mode.yml` → `product`) with workflow callers pinned to "
        f"`{template_repo}@{tag}`.\n"
        "- **Decided by:** owner (adoption bootstrap)\n"
        "- **Why:** Run factory workers on GitHub issues with local config only; "
        "scripts and harness details come from the pinned template release.\n"
        "- **Alternatives:** Full copy-paste of template files until #156 lands "
        "(still valid; this bootstrap prepares the per-repo config and caller stubs).\n"
        "- **Revisit when:** Reusable workflows and sync PRs ship (#156) or the pin tag changes.\n"
    )


def agents_md(repo_name: str) -> str:
    return (
        f"# AGENTS.md\n"
        f"\n"
        f"Standing rules for any AI agent working in **{repo_name}** (OpenCode `/oc` workers, "
        f"Cursor, Codex, local agents). Keep this file short: details live in `.factory/`, "
        f"so read the linked file when your task needs it. Owner-only file: agents never edit "
        f"it (#97).\n"
        f"\n"
        f"## Toolchain registry\n"
        f"\n"
        f"Replace the product rows from `.factory/DOCS.md` (create that doc map after init).\n"
        f"\n"
        f"| Intent | Command | Notes |\n"
        f"|---|---|---|\n"
        f"| Test | `bash scripts/test-<name>.sh` | Match `<name>` to what you changed |\n"
        f"| Spec check | `python3 scripts/factory-spec-check.py <path>` | "
        f"When the pinned tag provides it |\n"
        f"| PR check | `bash scripts/pr-check.sh <body.md> [files.txt]` | "
        f"When the pinned tag provides it |\n"
        f"| Build | `_(set in .factory/DOCS.md)_` | Product build command |\n"
        f"| Test (product) | `_(set in .factory/DOCS.md)_` | Product test command |\n"
        f"| Lint | `_(set in .factory/DOCS.md)_` | — |\n"
        f"| Typecheck | `_(set in .factory/DOCS.md)_` | — |\n"
        f"\n"
        f"## What this repo is\n"
        f"\n"
        f"A **product** repo using the Software Factory template. Work enters only as a GitHub "
        f"issue; humans keep the gates. Start with `.factory/FACTORY.md` on the pinned template "
        f"tag and your local `.factory/DOCS.md`.\n"
        f"\n"
        f"- `.factory/`: mode, models, decisions, and repo-specific doc map.\n"
        f"- `docs/specs/`: optional product spec drafts (factory specs live under `factory/specs/` "
        f"when enabled).\n"
        f"- `.github/workflows/`: thin caller stubs only — owner paste; pin a template release tag.\n"
        f"\n"
        f"## How to work\n"
        f"\n"
        f"1. The issue and its approved spec are the scope. Change only what they ask for.\n"
        f"2. Follow the factory loop on the pinned template: branch, build, self-review, PR with "
        f"`Closes #N` or `Refs #N`.\n"
        f"3. Verify with the toolchain registry and the issue spec.\n"
        f"4. Report honestly: claim a check only when command output proves it.\n"
        f"\n"
        f"## Worker contract\n"
        f"\n"
        f"- Ship on a feature branch through a PR; humans merge after required checks are green.\n"
        f"- Workers do not merge. Treat owner-only paths per the pinned template "
        f"(`AGENTS.md`, `.factory/models.yaml`, `.github/workflows/`, and listed guardrail scripts).\n"
        f"- Never read, print or commit secrets, keys or env vars.\n"
    )


def dependabot_yml() -> str:
    return (
        "# Dependabot for GitHub Actions (caller workflows pin upstream workflows at a tag).\n"
        "version: 2\n"
        "updates:\n"
        "  - package-ecosystem: github-actions\n"
        "    directory: /\n"
        "    schedule:\n"
        "      interval: weekly\n"
        "      day: monday\n"
        "      time: \"09:17\"\n"
        "      timezone: America/Chicago\n"
        "    open-pull-requests-limit: 5\n"
        "    groups:\n"
        "      github-actions:\n"
        "        patterns:\n"
        "          - \"*\"\n"
    )


def gitkeep() -> str:
    return ""


def write_file(
    path: Path,
    content: str,
    *,
    force: bool,
    dry_run: bool,
    result: WriteResult,
    rel: str,
) -> None:
    if path.exists() and not force:
        result.skipped.append(rel)
        return
    if dry_run:
        result.dry_run.append(rel)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    existed = path.exists()
    path.write_text(content, encoding="utf-8")
    if existed:
        result.overwritten.append(rel)
    else:
        result.created.append(rel)


def load_pr_template(template_dir: Path) -> str:
    src = template_dir / ".github" / "pull_request_template.md"
    if src.is_file():
        return src.read_text(encoding="utf-8")
    raise FileNotFoundError(f"missing template PR body: {src}")


def build_artifacts(
    target: Path,
    template_dir: Path,
    repo_name: str,
    template_repo: str,
    tag: str,
    with_callers: bool,
) -> list[tuple[str, Callable[[], str]]]:
    items: list[tuple[str, Callable[[], str]]] = [
        (".factory/mode.yml", mode_yml),
        (".factory/models.yaml", lambda: models_yml(template_repo, tag)),
        (".factory/DECISIONS.md", lambda: decisions_md(repo_name, template_repo, tag)),
        ("AGENTS.md", lambda: agents_md(repo_name)),
        ("docs/specs/.gitkeep", gitkeep),
        (
            ".github/pull_request_template.md",
            lambda: load_pr_template(template_dir),
        ),
        (".github/dependabot.yml", dependabot_yml),
    ]
    if with_callers:
        stubs = load_caller_stubs(template_dir, template_repo, tag)
        for name, body in stubs.items():
            rel = f".github/workflows/{name}"
            items.append((rel, lambda b=body: b))
    return items


def print_summary(
    target: Path,
    repo_name: str,
    template_repo: str,
    tag: str,
    result: WriteResult,
    dry_run: bool,
) -> None:
    print("Factory init summary")
    print(f"  Target: {target.resolve()}")
    print(f"  Repo name: {repo_name}")
    print(f"  Template pin: {template_repo}@{tag}")
    if dry_run:
        print(f"  Dry run — would write {len(result.dry_run)} file(s)")
        for rel in sorted(result.dry_run):
            print(f"    would create/update: {rel}")
        return
    if result.created:
        print(f"  Created ({len(result.created)}):")
        for rel in sorted(result.created):
            print(f"    + {rel}")
    if result.skipped:
        print(f"  Skipped existing ({len(result.skipped)}):")
        for rel in sorted(result.skipped):
            print(f"    = {rel}")
    if result.overwritten:
        print(f"  Overwritten ({len(result.overwritten)}):")
        for rel in sorted(result.overwritten):
            print(f"    ~ {rel}")
    print("")
    print("Owner next steps:")
    print("  1. Add the `DEEPINFRA_API_KEY` Actions secret (and `FACTORY_DEEPINFRA_KEY_NAME` variable).")
    print("  2. As repo admin, run `bash scripts/harden-repo.sh` (branch protection + security baseline).")
    print("  3. Run `python3 scripts/factory-doctor.py --repo-dir", str(target.resolve()) + "`")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--target", type=Path, required=True, help="Product repo root to scaffold")
    ap.add_argument("--tag", default=DEFAULT_TAG, help=f"Template semver tag (default: {DEFAULT_TAG})")
    ap.add_argument(
        "--repo-name",
        default=None,
        help="Logical repo name (default: basename of --target)",
    )
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
    ap.add_argument("--dry-run", action="store_true", help="Print actions only; write nothing")
    ap.add_argument(
        "--force",
        action="store_true",
        help="Overwrite files this tool already would create (never deletes unknown paths)",
    )
    ap.add_argument(
        "--with-callers",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Write .github/workflows caller stubs (default: true)",
    )
    return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        import yaml  # noqa: F401 — required for parity with other factory scripts
    except ImportError:
        print("factory-init-repo: PyYAML required (pip install -r requirements-factory.txt)", file=sys.stderr)
        return 2

    args = parse_args(argv)
    target = args.target.expanduser().resolve()
    template_dir = (args.template_dir or template_root()).resolve()
    if not template_dir.is_dir():
        print(f"factory-init-repo: template dir not found: {template_dir}", file=sys.stderr)
        return 2
    if ".." in args.template_repo or args.template_repo.count("/") != 1:
        print("factory-init-repo: --template-repo must be OWNER/REPO", file=sys.stderr)
        return 2
    if not re.fullmatch(r"v\d+\.\d+\.\d+", args.tag):
        print(
            f"factory-init-repo: --tag should look like semver vX.Y.Z, got {args.tag!r}",
            file=sys.stderr,
        )
        return 2

    repo_name = args.repo_name or target.name
    result = WriteResult()

    try:
        artifacts = build_artifacts(
            target,
            template_dir,
            repo_name,
            args.template_repo,
            args.tag,
            args.with_callers,
        )
    except FileNotFoundError as exc:
        print(f"factory-init-repo: {exc}", file=sys.stderr)
        return 2

    target.mkdir(parents=True, exist_ok=True)

    for rel, content_fn in artifacts:
        path = target / rel
        write_file(
            path,
            content_fn(),
            force=args.force,
            dry_run=args.dry_run,
            result=result,
            rel=rel,
        )

    print_summary(
        target,
        repo_name,
        args.template_repo,
        args.tag,
        result,
        args.dry_run,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())