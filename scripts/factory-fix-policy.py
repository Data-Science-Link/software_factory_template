#!/usr/bin/env python3
"""Fix-round circuit breaker for complex /oc builds (#233).

Evaluates issue complexity, prior failed fix rounds (Verification still fail),
and issue spend against ``factory/budget.yml`` targets. Pure transform: no model
calls, no network, no secrets.

For **complex** builds (``complexity: complex``, more than one major spec
section, or issue spend already above the per-issue target), if the **first**
``/oc fix`` round still fails harness Verification, the recommendation is
``stop_and_escalate`` — route to a stronger model, a cloud agent, or the owner
instead of burning a second fix round.

For **simple/standard** builds within budget, the existing two fix-round
allowance is preserved.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write(
        "ERROR: PyYAML is required (pip install -r requirements-factory.txt)\n"
    )
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BUDGET = REPO_ROOT / "factory" / "budget.yml"

SPEC_SECTION_RE = re.compile(r"^##\s+([^\n]+)", re.M)


def load_budget(path: Path | None = None) -> dict[str, float]:
    """Return issue_target_usd and issue_cap_usd from factory/budget.yml."""
    path = path or DEFAULT_BUDGET
    if not path.is_file():
        return {"issue_target_usd": 0.15, "issue_cap_usd": 1.0}
    with path.open(encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    return {
        "issue_target_usd": float(data.get("issue_target_usd", 0.15)),
        "issue_cap_usd": float(data.get("issue_cap_usd", 1.0)),
    }


def count_major_sections(spec_md: str | None) -> int:
    """Count non-trivial ``##`` sections in a spec (exclude boilerplate headings)."""
    if not spec_md:
        return 0
    skip = {
        "outcome",
        "files",
        "verification",
        "worker prompt",
        "classification",
        "scope",
        "broken case",
        "safety",
        "how measured",
        "notes",
    }
    count = 0
    for m in SPEC_SECTION_RE.finditer(spec_md):
        title = m.group(1).strip().lower()
        if title.startswith("---"):
            continue
        if any(title.startswith(s) for s in skip):
            continue
        count += 1
    return count


def is_complex_build(
    complexity: str | None,
    major_sections: int | None,
    issue_spend_usd: float | None,
    issue_target_usd: float,
) -> bool:
    """True when the 1-fix-round-after-verification-fail circuit breaker applies."""
    if isinstance(complexity, str) and complexity.strip().lower() == "complex":
        return True
    if major_sections is not None and major_sections > 1:
        return True
    if issue_spend_usd is not None and issue_spend_usd > issue_target_usd:
        return True
    return False


def evaluate_fix_policy(
    *,
    complexity: str | None = None,
    major_sections: int | None = None,
    issue_spend_usd: float | None = None,
    issue_target_usd: float | None = None,
    issue_cap_usd: float | None = None,
    failed_fix_rounds: int = 0,
    verification_failed_after_last_fix: bool = False,
    proposed_fix_round: int | None = None,
    budget_path: Path | None = None,
) -> dict[str, Any]:
    """Return a sorted-key JSON-serializable policy verdict."""
    budget = load_budget(budget_path)
    target = issue_target_usd if issue_target_usd is not None else budget["issue_target_usd"]
    cap = issue_cap_usd if issue_cap_usd is not None else budget["issue_cap_usd"]

    complex_build = is_complex_build(
        complexity, major_sections, issue_spend_usd, target
    )
    within_budget = issue_spend_usd is None or issue_spend_usd <= target
    max_fix_rounds = 1 if complex_build else 2

    recommendation = "allow_fix_round"
    reasons = []

    if proposed_fix_round is not None and proposed_fix_round > max_fix_rounds:
        recommendation = "stop_and_escalate"
        reasons.append(
            f"proposed fix round {proposed_fix_round} exceeds max {max_fix_rounds} "
            f"for this build class"
        )

    if complex_build:
        if failed_fix_rounds >= 1 and verification_failed_after_last_fix:
            recommendation = "stop_and_escalate"
            reasons.append(
                "complex build: first /oc fix round still failed harness Verification"
            )
        if proposed_fix_round is not None and proposed_fix_round >= 2:
            if failed_fix_rounds >= 1 or verification_failed_after_last_fix:
                recommendation = "stop_and_escalate"
                reasons.append(
                    "complex build: stop after one failed fix round; escalate "
                    "(stronger model, cloud agent, or owner)"
                )
    elif not within_budget and failed_fix_rounds >= 2:
        recommendation = "stop_and_escalate"
        reasons.append("issue spend above target with two failed fix rounds")

    if issue_spend_usd is not None and issue_spend_usd >= cap:
        recommendation = "stop_and_escalate"
        reasons.append("issue at hard cap")

    if recommendation == "allow_fix_round" and not reasons:
        if complex_build:
            reasons.append(
                "complex build: one fix round allowed while Verification has not "
                "failed on a prior fix"
            )
        else:
            reasons.append(
                "simple/standard within budget: up to two fix rounds allowed"
            )

    return {
        "complex_build": complex_build,
        "failed_fix_rounds": int(failed_fix_rounds),
        "issue_cap_usd": round(cap, 4),
        "issue_spend_usd": issue_spend_usd,
        "issue_target_usd": round(target, 4),
        "max_fix_rounds": max_fix_rounds,
        "proposed_fix_round": proposed_fix_round,
        "recommendation": recommendation,
        "reasons": reasons,
        "verification_failed_after_last_fix": bool(
            verification_failed_after_last_fix
        ),
        "within_budget": within_budget,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input",
        help="JSON file with policy fields (see evaluate_fix_policy)",
    )
    parser.add_argument("--complexity", default=None)
    parser.add_argument("--major-sections", type=int, default=None)
    parser.add_argument("--issue-spend-usd", type=float, default=None)
    parser.add_argument("--failed-fix-rounds", type=int, default=0)
    parser.add_argument(
        "--verification-failed-after-last-fix",
        action="store_true",
        default=False,
    )
    parser.add_argument("--proposed-fix-round", type=int, default=None)
    args = parser.parse_args(argv)

    fields: dict[str, Any] = {}
    if args.input:
        with open(args.input, encoding="utf-8") as fh:
            payload = json.load(fh)
        if not isinstance(payload, dict):
            parser.error("--input must be a JSON object")
        fields = payload
    else:
        fields = {
            "complexity": args.complexity,
            "major_sections": args.major_sections,
            "issue_spend_usd": args.issue_spend_usd,
            "failed_fix_rounds": args.failed_fix_rounds,
            "verification_failed_after_last_fix": args.verification_failed_after_last_fix,
            "proposed_fix_round": args.proposed_fix_round,
        }

    result = evaluate_fix_policy(**fields)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())