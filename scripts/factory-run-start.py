#!/usr/bin/env python3
"""Route the run model and check the issue cap before any spend (issue #91).

Thin, deterministic, offline decision layer. Model routing stays in
scripts/factory-predict-cost.py (called as a subprocess). No network; never prints
environment values.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]

SPEC_MARKER = "<!-- factory-spec v1 -->"
RUN_RECORD_MARKER = "<!-- factory-run-record -->"
TRUSTED_AUTHOR = "github-actions[bot]"
MODEL_ID_RE = re.compile(r"^[A-Za-z0-9._/-]+$")

DEFAULT_RUNS_DIR = ROOT / "factory" / "runs"
DEFAULT_MODELS = ROOT / ".factory" / "models.yaml"


def split_marker(text: str) -> tuple[str, str]:
    idx = text.find(SPEC_MARKER)
    if idx == -1:
        return "", text
    end = text.find("\n", idx)
    end = len(text) if end == -1 else end + 1
    return text[:end], text[end:]


def split_front_matter(text: str) -> tuple[dict[str, Any] | None, str]:
    body_start = text.lstrip("\ufeff").lstrip()
    if not body_start.startswith("---"):
        return None, text
    parts = body_start.split("---", 2)
    if len(parts) < 3:
        return None, text
    try:
        data = yaml.safe_load(parts[1])
    except yaml.YAMLError:
        return None, parts[2]
    if not isinstance(data, dict):
        return None, parts[2]
    return data, parts[2]


def refuse(reason: str) -> int:
    print(f"run-start: refused: {reason}", file=sys.stderr)
    return 3


def call_spec_check(spec: Path) -> bool:
    script = ROOT / "scripts" / "factory-spec-check.py"
    res = subprocess.run(
        [sys.executable, str(script), str(spec)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return res.returncode == 0


def route_model(spec: Path, models: Path) -> dict[str, Any] | None:
    script = ROOT / "scripts" / "factory-predict-cost.py"
    res = subprocess.run(
        [sys.executable, str(script), "--models", str(models), "--json", str(spec)],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        return None
    try:
        return json.loads(res.stdout)
    except json.JSONDecodeError:
        return None


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
        if run_id not in spend:
            spend[run_id] = float(actual)


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
        if run_id not in spend:
            spend[run_id] = float(actual)


def is_deepinfra_model(model_id: str, models_data: dict[str, Any]) -> bool:
    if not MODEL_ID_RE.match(model_id):
        return False
    for row in models_data.get("models", []):
        if row.get("id") == model_id and row.get("provider") == "deepinfra":
            return True
    return False


def run_id_from_env() -> str:
    run_id = os.environ.get("GITHUB_RUN_ID")
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT")
    if run_id and attempt:
        return f"gha-{run_id}-{attempt}"
    return "gha-local-1"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", type=Path, required=True, help="Approved spec file")
    parser.add_argument("--issue", type=str, required=True, help="Issue number")
    parser.add_argument(
        "--comments-json", type=Path, default=None,
        help="JSON array of issue comments (GitHub REST shape); missing file means none",
    )
    parser.add_argument(
        "--runs-dir", type=Path, default=DEFAULT_RUNS_DIR,
        help="Directory of committed run-record JSON files",
    )
    parser.add_argument("--models", type=Path, default=DEFAULT_MODELS, help="models.yaml")
    parser.add_argument(
        "--github-output", type=Path, default=None,
        help="File to append key=value outputs to (default: $GITHUB_OUTPUT)",
    )
    parser.add_argument(
        "--out", type=Path, default=None,
        help="Write the outputs as a sorted-key JSON object to this file",
    )
    args = parser.parse_args()

    if not args.issue.isdigit():
        print(f"issue must be a positive integer, got {args.issue!r}", file=sys.stderr)
        return 2
    issue = int(args.issue)

    if not args.spec.is_file():
        print(f"spec not found: {args.spec}", file=sys.stderr)
        return 2
    try:
        spec_text = args.spec.read_text(encoding="utf-8")
    except OSError:
        print(f"cannot read spec: {args.spec}", file=sys.stderr)
        return 2

    comments: list[Any] = []
    if args.comments_json is not None and args.comments_json.is_file():
        try:
            parsed = json.loads(args.comments_json.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            print(f"invalid comments JSON: {exc}", file=sys.stderr)
            return 2
        if not isinstance(parsed, list):
            print("comments JSON must be an array", file=sys.stderr)
            return 2
        comments = parsed

    github_output = args.github_output
    if github_output is None:
        env_out = os.environ.get("GITHUB_OUTPUT")
        if env_out:
            github_output = Path(env_out)

    _, rest = split_marker(spec_text)
    fm, _ = split_front_matter(rest)
    if fm is None:
        return refuse("spec has no YAML front matter")
    if fm.get("status") != "approved":
        return refuse(f"spec status is {fm.get('status')!r}, not approved")
    if fm.get("issue") != issue:
        return refuse(f"spec issue {fm.get('issue')!r} does not match --issue {issue}")
    if not call_spec_check(args.spec):
        return refuse("spec fails factory-spec-check")

    if not args.models.is_file():
        print(f"models file not found: {args.models}", file=sys.stderr)
        return 2
    try:
        models_data = yaml.safe_load(args.models.read_text(encoding="utf-8"))
    except (yaml.YAMLError, OSError):
        print(f"cannot read models file: {args.models}", file=sys.stderr)
        return 2
    if not isinstance(models_data, dict):
        print(f"models file must be a YAML mapping: {args.models}", file=sys.stderr)
        return 2

    routed = route_model(args.spec, args.models)
    if routed is None:
        return refuse("model router failed or produced no result")
    model_id = routed.get("model")
    routed_rule = routed.get("routed_rule")
    predicted = routed.get("predicted_cost_usd")
    check_actions = routed.get("check_actions") or []
    if model_id is None or routed_rule is None or predicted is None:
        return refuse("router output is missing model, routed_rule, or predicted_cost_usd")
    if check_actions:
        return refuse("router raised a guard (rule 6 over the cap or rule 8 priority tier)")
    if not is_deepinfra_model(str(model_id), models_data):
        return refuse(f"model {model_id!r} is not a deepinfra model in models.yaml")

    spend: dict[str, float] = {}
    warned: list[str] = []
    load_runs_dir_spend(args.runs_dir, issue, spend, warned)
    load_comments_spend(comments, issue, spend, warned)
    prior = round(sum(spend.values()), 4)

    budget = models_data.get("budget") or {}
    cap_raw = budget.get("issue_cap_usd")
    if cap_raw is None:
        return refuse("models.yaml budget.issue_cap_usd is not set")
    cap = float(cap_raw)

    if prior >= cap or (prior + float(predicted)) > cap:
        return refuse("prior spend plus predicted cost is at or over the issue cap")

    for w in warned:
        print(f"warning: {w}", file=sys.stderr)

    run_id = run_id_from_env()
    lines = [
        f"model=deepinfra/{model_id}",
        f"model_id={model_id}",
        f"routed_rule={routed_rule}",
        f"predicted_cost_usd={float(predicted):.4f}",
        f"prior_spend_usd={prior:.4f}",
        f"cap_usd={cap:.2f}",
        f"run_id={run_id}",
    ]
    for line in lines:
        print(line)

    if github_output is not None:
        with open(github_output, "a", encoding="utf-8") as fh:
            for line in lines:
                fh.write(line + "\n")

    if args.out is not None:
        out_obj = {
            "model": f"deepinfra/{model_id}",
            "model_id": model_id,
            "routed_rule": routed_rule,
            "predicted_cost_usd": round(float(predicted), 4),
            "prior_spend_usd": prior,
            "cap_usd": cap,
            "run_id": run_id,
        }
        args.out.write_text(
            json.dumps(out_obj, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
