#!/usr/bin/env python3
"""Sum recorded spend for one issue from factory/runs and trusted run-record comments (#91, #115).

Offline only; no network. Used by factory-run-start.py and opencode-spec-draft.py preflight.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

RUN_RECORD_MARKER = "<!-- factory-run-record -->"
TRUSTED_AUTHOR = "github-actions[bot]"


def extract_json_block(body: str) -> dict[str, Any] | None:
    in_block = False
    buf: list[str] = []
    for line in body.splitlines():
        if line.strip().startswith("```"):
            if in_block:
                try:
                    return json.loads("\n".join(buf))
                except json.JSONDecodeError:
                    return None
            in_block = True
            buf = []
        elif in_block:
            buf.append(line)
    return None


def valid_cost(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        cost = float(value)
    except (TypeError, ValueError):
        return None
    if not cost == cost or cost in (float("inf"), float("-inf")) or cost < 0:
        return None
    return cost


def load_runs_dir_spend(
    runs_dir: Path, issue: int, spend: dict[str, float], warned: list[str]
) -> None:
    if not runs_dir.is_dir():
        return
    for f in sorted(runs_dir.glob("*.json")):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            warned.append(f"skipped unreadable run file {f.name}")
            continue
        if not isinstance(data, dict):
            warned.append(f"skipped malformed run file {f.name}")
            continue
        if data.get("issue") != issue:
            continue
        run_id = data.get("run_id")
        actual = data.get("actual_cost_usd")
        if not run_id or actual is None:
            warned.append(f"skipped run file {f.name} without run_id/actual_cost_usd")
            continue
        cost = valid_cost(actual)
        if cost is None:
            warned.append(f"skipped run file {f.name} with invalid actual_cost_usd")
            continue
        if run_id not in spend:
            spend[run_id] = cost


def load_comments_spend(
    comments: list[Any], issue: int, spend: dict[str, float], warned: list[str]
) -> None:
    for comment in comments:
        if not isinstance(comment, dict):
            continue
        user = comment.get("user")
        login = user.get("login") if isinstance(user, dict) else None
        body = comment.get("body")
        if not isinstance(body, str):
            continue
        lines = body.splitlines()
        first = lines[0].strip() if lines else ""
        if first != RUN_RECORD_MARKER:
            continue
        if login != TRUSTED_AUTHOR:
            warned.append("skipped run record comment from untrusted author")
            continue
        data = extract_json_block(body)
        if data is None:
            warned.append("skipped unparseable run record comment")
            continue
        if data.get("issue") != issue:
            continue
        run_id = data.get("run_id")
        actual = data.get("actual_cost_usd")
        if not run_id or actual is None:
            warned.append("skipped run record comment without run_id/actual_cost_usd")
            continue
        cost = valid_cost(actual)
        if cost is None:
            warned.append("skipped run record comment with invalid actual_cost_usd")
            continue
        if run_id not in spend:
            spend[run_id] = cost


def issue_prior_spend(
    issue: int,
    runs_dir: Path,
    comments: list[Any] | None = None,
) -> tuple[float, list[str]]:
    """Return (prior_spend_usd rounded to 4 decimals, warning lines)."""
    spend: dict[str, float] = {}
    warned: list[str] = []
    load_runs_dir_spend(runs_dir, issue, spend, warned)
    load_comments_spend(comments or [], issue, spend, warned)
    return round(sum(spend.values()), 4), warned