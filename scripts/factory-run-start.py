#!/usr/bin/env python3
"""Route the run model and check the issue cap before any spend (issues #91, #92).

Thin, deterministic, offline decision layer. Model routing stays in
scripts/factory-predict-cost.py (called as a subprocess). No network; never prints
environment values.

Retry and fallback (#92) are decided here too, never by the spec, the comment or the worker:
the latest trusted #84 failure marker (github-actions[bot]) of the same kind (build or fix)
posted since the owner's previous trigger comment sets the router context:
  - an agent-job failure on DeepSeek with error=tool_or_reasoning_format -> rule 5 (Qwen3-Coder)
  - an agent-job failure on V4 Flash for standard work -> rule 4 (one rerun on V4 Pro)
Anything else routes on the spec alone (rules 1-3). A refusal exits 3 and writes
`refused=<code>` (plus the cap numbers when known) to $GITHUB_OUTPUT for the notify job.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]

SPEC_MARKER = "<!-- factory-spec v1 -->"
RUN_RECORD_MARKER = "<!-- factory-run-record -->"
TRUSTED_AUTHOR = "github-actions[bot]"
MODEL_ID_RE = re.compile(r"^[A-Za-z0-9._/-]+$")

FAILURE_MARKER_RE = re.compile(
    r"<!-- factory-run-failed v1 run=(?P<run>[0-9]+) attempt=(?P<attempt>[0-9]+)"
    r"(?P<fields>(?: [a-z_]+=[A-Za-z0-9._/-]+)*) -->"
)
FLASH = "deepseek-ai/DeepSeek-V4-Flash-0731"
# Router context keys run start owns (#92): stripped from the spec, then set from the markers.
ATTEMPT_KEYS = ("retry", "escalated_from", "error_class", "prior_model_family")
REFUSAL_CODES = frozenset({
    "no_approved_spec", "spec_not_approved", "spec_issue_mismatch", "spec_check_failed",
    "router_failed", "router_guard", "model_not_allowed", "cap_unset", "over_cap",
    "over_target_unapproved",
})

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


_REFUSAL_OUT: list[Path] = []


def refuse(reason: str, code: str, extra: dict[str, str] | None = None) -> int:
    """Exit 3. Writes refused=<code> (+ numeric extras) for the notify job; never a model line."""
    assert code in REFUSAL_CODES
    print(f"run-start: refused: {reason}", file=sys.stderr)
    for out in _REFUSAL_OUT:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(f"refused={code}\n")
            for k, v in (extra or {}).items():
                fh.write(f"{k}={v}\n")
    return 3


def is_trigger(comment: dict[str, Any], kind: str) -> bool:
    """An owner comment that starts a run of this kind (same filters as the workflows)."""
    if comment.get("author_association") != "OWNER":
        return False
    body = comment.get("body")
    if not isinstance(body, str):
        return False
    if kind == "fix":
        return body.startswith("/oc fix")
    return body.startswith("/oc") and not body.startswith("/oc spec")


def parse_failure_marker(comment: dict[str, Any]) -> dict[str, str] | None:
    user = comment.get("user")
    if not isinstance(user, dict) or user.get("login") != TRUSTED_AUTHOR:
        return None
    body = comment.get("body")
    if not isinstance(body, str):
        return None
    first = body.splitlines()[0] if body else ""
    m = FAILURE_MARKER_RE.fullmatch(first.strip())
    if not m:
        return None
    fields = dict(f.split("=", 1) for f in m.group("fields").split())
    fields["run_id"] = f"gha-{m.group('run')}-{m.group('attempt')}"
    return fields


def attempt_context(
    comments: list[Any], kind: str, complexity: Any
) -> tuple[dict[str, Any], str, str]:
    """(router context, route_reason, retry_of) from the previous attempt of this kind."""
    rows = [c for c in comments if isinstance(c, dict)]
    # Stable order: created_at (GitHub ISO-8601 Z strings sort correctly), then input order.
    rows = [r for _, r in sorted(enumerate(rows), key=lambda t: (str(t[1].get("created_at") or ""), t[0]))]
    triggers = [str(r.get("created_at") or "") for r in rows if is_trigger(r, kind)]
    # Markers since the owner's previous trigger: the attempt just before this one (or an
    # earlier attempt of this same run on a re-run). Older failures were already retried.
    since = triggers[-2] if len(triggers) >= 2 else ""
    last: dict[str, str] | None = None
    for r in rows:
        if since and str(r.get("created_at") or "") <= since:
            continue
        f = parse_failure_marker(r)
        if f is None or f.get("kind") != kind:
            continue
        # Only a failed worker counts: a refused run start (model=none), a cancelled run or a
        # publish-job failure says nothing about the model.
        if f.get("job") != "agent" or f.get("result") != "failure":
            continue
        if f.get("model", "none") == "none":
            continue
        # error=none: the worker step never failed (e.g. an install step did); not a model failure.
        if f.get("error") not in ("tool_or_reasoning_format", "other"):
            continue
        last = f
    if last is None:
        return {}, "default", "none"
    model = last["model"]
    if last.get("error") == "tool_or_reasoning_format" and model.startswith("deepseek-ai/"):
        return (
            {"error_class": "tool_or_reasoning_format", "prior_model_family": "deepseek-ai"},
            "fallback_after_tool_error",
            last["run_id"],
        )
    if model == FLASH and complexity == "standard":
        return (
            {"retry": True, "escalated_from": FLASH},
            "retry_after_flash_failure",
            last["run_id"],
        )
    return {}, "default", "none"


def routed_spec_copy(spec_text: str, fm: dict[str, Any], ctx: dict[str, Any], tmp: Path) -> Path:
    """The spec with run start's attempt context in place of any spec-set attempt keys."""
    prefix, rest = split_marker(spec_text)
    _, body = split_front_matter(rest)
    new_fm = {k: v for k, v in fm.items() if k not in ATTEMPT_KEYS}
    new_fm.update(ctx)
    out = tmp / "routed-spec.md"
    out.write_text(
        f"{prefix}---\n{yaml.safe_dump(new_fm, sort_keys=False).rstrip()}\n---{body}",
        encoding="utf-8",
    )
    return out


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
        "--comments-json", type=Path, action="append", default=None,
        help="JSON array of issue or PR comments (GitHub REST shape); repeatable; "
        "a missing file means none",
    )
    parser.add_argument(
        "--kind", choices=("build", "fix"), default="build",
        help="Run kind: build (/oc on an issue) or fix (/oc fix on a PR); picks retry markers",
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

    comments: list[Any] = []
    for cfile in args.comments_json or []:
        if not cfile.is_file():
            continue
        try:
            parsed = json.loads(cfile.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            print(f"invalid comments JSON: {exc}", file=sys.stderr)
            return 2
        if not isinstance(parsed, list):
            print("comments JSON must be an array", file=sys.stderr)
            return 2
        comments.extend(parsed)

    github_output = args.github_output
    if github_output is None:
        env_out = os.environ.get("GITHUB_OUTPUT")
        if env_out:
            github_output = Path(env_out)
    if github_output is not None:
        _REFUSAL_OUT.append(github_output)

    # The context step writes spec.md only for an approved owner spec comment (#75).
    if not args.spec.is_file():
        return refuse("no approved spec for this issue", "no_approved_spec")
    try:
        spec_text = args.spec.read_text(encoding="utf-8")
    except OSError:
        return refuse("cannot read the spec", "no_approved_spec")

    _, rest = split_marker(spec_text)
    fm, _ = split_front_matter(rest)
    if fm is None:
        return refuse("spec has no YAML front matter", "spec_not_approved")
    if fm.get("status") != "approved":
        return refuse(f"spec status is {fm.get('status')!r}, not approved", "spec_not_approved")
    if fm.get("issue") != issue:
        return refuse(
            f"spec issue {fm.get('issue')!r} does not match --issue {issue}", "spec_issue_mismatch"
        )
    if not call_spec_check(args.spec):
        return refuse("spec fails factory-spec-check", "spec_check_failed")

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

    ctx, route_reason, retry_of = attempt_context(comments, args.kind, fm.get("complexity"))
    with tempfile.TemporaryDirectory() as td:
        routed = route_model(routed_spec_copy(spec_text, fm, ctx, Path(td)), args.models)
    # The spec's own prediction (current models.yaml, no retry context) for the over-target gate,
    # so a harness retry/fallback never needs a second approval.
    with tempfile.TemporaryDirectory() as td:
        base = route_model(routed_spec_copy(spec_text, fm, {}, Path(td)), args.models) if ctx else routed
    if routed is None:
        return refuse("model router failed or produced no result", "router_failed")
    model_id = routed.get("model")
    routed_rule = routed.get("routed_rule")
    predicted = routed.get("predicted_cost_usd")
    check_actions = routed.get("check_actions") or []
    if model_id is None or routed_rule is None or predicted is None:
        return refuse(
            "router output is missing model, routed_rule, or predicted_cost_usd", "router_failed"
        )
    if check_actions:
        return refuse(
            "router raised a guard (rule 6 over the cap or rule 8 priority tier)", "router_guard"
        )
    if not is_deepinfra_model(str(model_id), models_data):
        return refuse(
            f"model {model_id!r} is not a deepinfra model in models.yaml", "model_not_allowed"
        )

    # Over-target gate (Michael, 2026-11-07): any risk class. A prediction over
    # budget.issue_target_usd needs his explicit flag in the approved spec.
    target_raw = (models_data.get("budget") or {}).get("issue_target_usd")
    spec_predicted = (base or {}).get("predicted_cost_usd")
    if spec_predicted is None:
        return refuse("router output is missing predicted_cost_usd", "router_failed")
    if target_raw is not None and float(spec_predicted) > float(target_raw) \
            and fm.get("over_target_approved_by") != "michael":
        return refuse(
            f"spec predicted ${float(spec_predicted):.4f} is over the ${float(target_raw):.2f} target and the "
            "approved spec has no over_target_approved_by: michael",
            "over_target_unapproved",
        )

    spend: dict[str, float] = {}
    warned: list[str] = []
    load_runs_dir_spend(args.runs_dir, issue, spend, warned)
    load_comments_spend(comments, issue, spend, warned)
    prior = round(sum(spend.values()), 4)

    budget = models_data.get("budget") or {}
    cap_raw = budget.get("issue_cap_usd")
    if cap_raw is None:
        return refuse("models.yaml budget.issue_cap_usd is not set", "cap_unset")
    cap = float(cap_raw)

    if prior >= cap or (prior + float(predicted)) > cap:
        return refuse(
            f"prior spend ${prior:.4f} plus predicted ${float(predicted):.4f} is at or over "
            f"the ${cap:.2f} issue cap",
            "over_cap",
            {
                "prior_spend_usd": f"{prior:.4f}",
                "predicted_cost_usd": f"{float(predicted):.4f}",
                "cap_usd": f"{cap:.2f}",
            },
        )

    for w in warned:
        print(f"warning: {w}", file=sys.stderr)

    run_id = run_id_from_env()
    lines = [
        f"model=deepinfra/{model_id}",
        f"model_id={model_id}",
        f"routed_rule={routed_rule}",
        f"route_reason={route_reason}",
        f"retry_of={retry_of}",
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
            "route_reason": route_reason,
            "retry_of": retry_of,
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
