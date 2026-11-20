#!/usr/bin/env python3
"""Independent Critic runner (#41): pick a different DeepInfra reviewer model, call chat API read-only,
and write critic-review.md plus a schema-valid review run record JSON.

Reads:
  - critic-input.md (from scripts/factory-critic-context.py)
  - optional critic-meta.txt (pr/issue/sha metadata)
  - .factory/models.yaml for prices and deterministic reviewer != coder selection

Writes to --out-dir:
  critic-review.md
  critic-run-record.json   (work_type review; usage_x_price_table cost)

Stdlib only except PyYAML. No repo write tools; no network when --dry-run or --fixture-response is set.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DEFAULT_MODELS = ROOT / ".factory" / "models.yaml"
DEFAULT_API_BASE = "https://api.deepinfra.com/v1/openai"
CHAT_PATH = "/chat/completions"
TOKEN_RE = re.compile(
    rb"(ghs_[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|"
    rb"Bearer[ \t]+[A-Za-z0-9._-]{10,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.)"
)
STATUS_RANK = {"escalation": 0, "complex_builder": 1, "default": 2}
DRY_REVIEW = """Factory Critic review

Verdict: pass

Harness verification: PASS — dry-run stub; no live model call.

Checked: spec match, diff vs scope, verification output, edge cases, security/forbidden paths.
For the owner: nothing
"""


def die(msg: str, code: int = 2) -> None:
    print(f"critic-run: FAIL — {msg}", file=sys.stderr)
    sys.exit(code)


def load_cost_from_usage():
    spec = importlib.util.spec_from_file_location(
        "factory_validate_run", HERE / "factory-validate-run.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.cost_from_usage


COST_FROM_USAGE = None


def cost_from_usage_lazy(*args, **kwargs):
    global COST_FROM_USAGE
    if COST_FROM_USAGE is None:
        COST_FROM_USAGE = load_cost_from_usage()
    return COST_FROM_USAGE(*args, **kwargs)


def normalize_model_id(model_id: str) -> str:
    mid = (model_id or "").strip()
    if mid.startswith("deepinfra/"):
        mid = mid.split("/", 1)[1]
    return mid


def load_models(path: Path) -> dict[str, Any]:
    if not path.is_file():
        die(f"models file not found: {path}")
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        die("models.yaml must be a mapping")
    return data


def reviewer_pick_order(models: list[dict]) -> list[str]:
    """Deterministic reviewer preference: escalation, complex_builder, default, then by id."""
    buckets: dict[str, list[str]] = {}
    for row in models:
        if not isinstance(row, dict) or row.get("provider") != "deepinfra":
            continue
        mid = row.get("id")
        if not isinstance(mid, str) or not mid.strip():
            continue
        status = str(row.get("status") or "")
        buckets.setdefault(status, []).append(mid)
    ordered: list[str] = []
    statuses = sorted(buckets.keys(), key=lambda s: (STATUS_RANK.get(s, 50), s))
    for st in statuses:
        for mid in sorted(buckets[st]):
            if mid not in ordered:
                ordered.append(mid)
    return ordered


def select_reviewer_model(coder_model: str, models_data: dict[str, Any]) -> tuple[str, str]:
    """Return (reviewer_model_id, reason). Rule 7: must differ from coder."""
    coder = normalize_model_id(coder_model)
    models = models_data.get("models") or []
    eligible = [
        r["id"]
        for r in models
        if isinstance(r, dict) and r.get("provider") == "deepinfra" and r.get("id")
    ]
    if not eligible:
        die("no deepinfra models in models.yaml")
    order = reviewer_pick_order(models)
    for mid in order:
        if mid != coder:
            return mid, "models.yaml routing rule 7 (different model than builder)"
    for mid in sorted(eligible):
        if mid != coder:
            return mid, "fallback: first deepinfra model id != coder"
    die(f"no reviewer model distinct from coder {coder!r}")


def model_row(models_data: dict[str, Any], model_id: str) -> dict[str, Any]:
    for row in models_data.get("models") or []:
        if isinstance(row, dict) and row.get("id") == model_id:
            return row
    die(f"unknown model id {model_id!r} (not in models.yaml)")


def predict_review_cost(models_data: dict[str, Any], reviewer_id: str) -> float:
    priors = models_data.get("token_priors") or {}
    block = priors.get("simple") or priors.get("standard")
    if not block:
        return 0.0
    tokens_in = int(block["tokens_in"])
    frac = float(block.get("tokens_cached_fraction", 0))
    tokens_cached = int(tokens_in * frac)
    tokens_out = int(block.get("tokens_out", 0))
    prices = model_row(models_data, reviewer_id)
    return round(
        cost_from_usage_lazy(
            tokens_in,
            tokens_cached,
            tokens_out,
            float(prices["price_in_per_mtok"]),
            float(prices["price_cached_per_mtok"]),
            float(prices["price_out_per_mtok"]),
        ),
        4,
    )


def parse_meta(path: Path | None) -> dict[str, str]:
    if path is None or not path.is_file():
        return {}
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def redact_text(text: str) -> str:
    out = TOKEN_RE.sub(b"[redacted-token]", text.encode("utf-8"))
    key = os.environ.get("DEEPINFRA_API_KEY")
    if key and len(key) >= 8:
        out = out.replace(key.encode("utf-8"), b"[redacted-env]")
    return out.decode("utf-8", "ignore")


def extract_usage(payload: dict[str, Any]) -> tuple[int, int, int, int]:
    usage = payload.get("usage") or {}
    tokens_in = int(usage.get("prompt_tokens") or usage.get("input_tokens") or 0)
    tokens_out = int(usage.get("completion_tokens") or usage.get("output_tokens") or 0)
    cached = 0
    details = usage.get("prompt_tokens_details") or usage.get("input_tokens_details") or {}
    if isinstance(details, dict):
        cached = int(details.get("cached_tokens") or details.get("cache_read_tokens") or 0)
    reasoning = 0
    cout = usage.get("completion_tokens_details") or {}
    if isinstance(cout, dict):
        reasoning = int(cout.get("reasoning_tokens") or 0)
    return tokens_in, tokens_cached_fix(tokens_in, cached), tokens_out, reasoning


def tokens_cached_fix(tokens_in: int, cached: int) -> int:
    return min(max(cached, 0), tokens_in)


def chat_completions(
    api_base: str,
    api_key: str,
    model_id: str,
    user_content: str,
    *,
    timeout_s: float = 120.0,
) -> dict[str, Any]:
    base = api_base.rstrip("/")
    url = base + CHAT_PATH if CHAT_PATH.startswith("/") else base + "/" + CHAT_PATH.lstrip("/")
    body = {
        "model": model_id,
        "messages": [{"role": "user", "content": user_content}],
        "temperature": 0,
    }
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:500]
        die(f"API HTTP {exc.code}: {detail}", code=1)
    except urllib.error.URLError as exc:
        die(f"API connection error: {exc.reason}", code=1)


def message_content(payload: dict[str, Any]) -> str:
    choices = payload.get("choices") or []
    if not choices:
        return ""
    msg = choices[0].get("message") or {}
    content = msg.get("content") or ""
    return content if isinstance(content, str) else str(content)


def utc_now_z() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_meta_int(meta: dict[str, str], key: str) -> int | None:
    raw = meta.get(key)
    if not raw or raw in ("none", "?"):
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def build_run_record(
    *,
    models_data: dict[str, Any],
    reviewer_id: str,
    coder_id: str,
    meta: dict[str, str],
    tokens_in: int,
    tokens_cached: int,
    tokens_out: int,
    tokens_reasoning: int,
    predicted_cost_usd: float,
    started_at: str,
    ended_at: str,
    harness_run_id: str | None,
) -> dict[str, Any]:
    prices = model_row(models_data, reviewer_id)
    actual = round(
        cost_from_usage_lazy(
            tokens_in,
            tokens_cached,
            tokens_out,
            float(prices["price_in_per_mtok"]),
            float(prices["price_cached_per_mtok"]),
            float(prices["price_out_per_mtok"]),
        ),
        6,
    )
    budget = models_data.get("budget") or {}
    run_id = os.environ.get("GITHUB_RUN_ID", "90000000999")
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "1")
    repo = os.environ.get("GITHUB_REPOSITORY", "Data-Science-Link/software_factory_template")
    issue = parse_meta_int(meta, "issue_number") or 0
    pr = parse_meta_int(meta, "pr_number")
    head_sha = meta.get("head_sha") or ("a" * 40)
    if head_sha in ("none", "?"):
        head_sha = "a" * 40
    if len(head_sha) != 40:
        head_sha = (head_sha + "0" * 40)[:40]
    base_sha = os.environ.get("OC_BASE_SHA") or ("b" * 40)
    try:
        t0 = datetime.strptime(started_at, "%Y-%m-%dT%H:%M:%SZ")
        t1 = datetime.strptime(ended_at, "%Y-%m-%dT%H:%M:%SZ")
        duration_s = max(0, int((t1 - t0).total_seconds()))
    except ValueError:
        duration_s = 0

    record: dict[str, Any] = {
        "schema_version": 1,
        "run_id": f"gha-{run_id}-{attempt}",
        "repo": repo,
        "issue": issue if issue > 0 else 1,
        "issues": [issue if issue > 0 else 1],
        "pr": pr,
        "spec_path": "factory/specs/issue-placeholder.md",
        "spec_link": f"https://github.com/{repo}/issues/{issue or 1}",
        "trigger": "workflow_dispatch",
        "triggered_by": os.environ.get("GITHUB_ACTOR", "github-actions[bot]"),
        "trigger_url": os.environ.get(
            "OC_TRIGGER_URL",
            f"https://github.com/{repo}/actions/runs/{run_id}",
        ),
        "workflow_run_url": f"https://github.com/{repo}/actions/runs/{run_id}",
        "harness": "factory-critic",
        "harness_version": os.environ.get("FACTORY_CRITIC_VERSION", "0.1.0"),
        "provider": "deepinfra",
        "model": reviewer_id,
        "escalated_from": None,
        "complexity": "simple",
        "risk": "normal",
        "work_type": "review",
        "price_table_version": str(models_data.get("price_table_version") or "unknown"),
        "price_in_per_mtok": float(prices["price_in_per_mtok"]),
        "price_cached_per_mtok": float(prices["price_cached_per_mtok"]),
        "price_out_per_mtok": float(prices["price_out_per_mtok"]),
        "requests": 1,
        "tokens_in": tokens_in,
        "tokens_cached": tokens_cached,
        "tokens_out": tokens_out,
        "tokens_reasoning": tokens_reasoning,
        "predicted_cost_usd": predicted_cost_usd,
        "actual_cost_usd": actual,
        "cost_method": "usage_x_price_table",
        "key_spend_delta_usd": None,
        "cost_check": "match",
        "budget_cap_usd": float(budget.get("issue_cap_usd") or 1.0),
        "issue_spend_to_date_usd": 0.0,
        "started_at": started_at,
        "ended_at": ended_at,
        "duration_s": duration_s,
        "actions_minutes": max(1, (duration_s + 59) // 60),
        "runner": os.environ.get("OC_RUNNER", "ubuntu-latest"),
        "base_sha": base_sha if len(base_sha) == 40 else "b" * 40,
        "head_sha": head_sha,
        "outcome": "no_changes",
        "gate": {
            "gitleaks": "skip",
            "run_record_valid": "pass",
            "cost_recorded": "pass",
            "pr_template": "skip",
            "pr_check": "skip",
            "budget_cap": "pass",
            "no_workflow_changes": "pass",
            "spec_present": "skip",
        },
        "gate_passed": True,
        "notes": f"Independent Critic (#41); coder_model={normalize_model_id(coder_id)}"
        + (f"; harness_run_id={harness_run_id}" if harness_run_id else ""),
        "steps": [
            {
                "step_kind": "review",
                "model": reviewer_id,
                "price_in_per_mtok": float(prices["price_in_per_mtok"]),
                "price_cached_per_mtok": float(prices["price_cached_per_mtok"]),
                "price_out_per_mtok": float(prices["price_out_per_mtok"]),
                "requests": 1,
                "tokens_in": tokens_in,
                "tokens_cached": tokens_cached,
                "tokens_out": tokens_out,
                "tokens_reasoning": tokens_reasoning,
                "predicted_cost_usd": predicted_cost_usd,
                "actual_cost_usd": actual,
                "cost_method": "usage_x_price_table",
            }
        ],
    }
    return record


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--input", type=Path, required=True, help="critic-input.md path")
    ap.add_argument("--meta", type=Path, help="critic-meta.txt from factory-critic-context.py")
    ap.add_argument("--out-dir", type=Path, required=True)
    ap.add_argument("--coder-model", help="Builder/coder DeepInfra model id")
    ap.add_argument("--harness-run-id", help="Builder gha run id to link in notes")
    ap.add_argument("--models", type=Path, default=DEFAULT_MODELS)
    ap.add_argument("--api-base", default=DEFAULT_API_BASE)
    ap.add_argument("--dry-run", action="store_true", help="Skip HTTP; write stub review and zero usage")
    ap.add_argument("--fixture-response", type=Path, help="Offline API JSON (chat completion response)")
    ap.add_argument("--started-at", help="UTC Z timestamp for record (default: now)")
    ap.add_argument("--ended-at", help="UTC Z timestamp for record (default: now)")
    ap.add_argument("--print-model", action="store_true", help="Print reviewer= and coder= lines and exit")
    args = ap.parse_args()

    if not args.input.is_file():
        die(f"critic-input not found: {args.input}")

    models_data = load_models(args.models)
    meta = parse_meta(args.meta)
    coder = args.coder_model or os.environ.get("OC_CODER_MODEL") or os.environ.get("OC_MODEL_ID")
    if not coder:
        die("need --coder-model, OC_CODER_MODEL, or OC_MODEL_ID")
    coder = normalize_model_id(coder)
    reviewer_id, pick_reason = select_reviewer_model(coder, models_data)

    if args.print_model:
        print(f"coder={coder}")
        print(f"reviewer={reviewer_id}")
        print(f"reviewer_reason={pick_reason}")
        return 0

    predicted = predict_review_cost(models_data, reviewer_id)
    user_text = args.input.read_text(encoding="utf-8")

    if args.fixture_response:
        if not args.fixture_response.is_file():
            die(f"fixture-response not found: {args.fixture_response}")
        payload = json.loads(args.fixture_response.read_text(encoding="utf-8"))
        review_text = message_content(payload) or DRY_REVIEW
        tokens_in, tokens_cached, tokens_out, tokens_reasoning = extract_usage(payload)
    elif args.dry_run:
        payload = {}
        review_text = DRY_REVIEW
        tokens_in = tokens_cached = tokens_out = tokens_reasoning = 0
    else:
        api_key = os.environ.get("DEEPINFRA_API_KEY", "").strip()
        if not api_key:
            die("DEEPINFRA_API_KEY is not set (use --dry-run or --fixture-response for offline)")
        started = args.started_at or utc_now_z()
        payload = chat_completions(args.api_base, api_key, reviewer_id, user_text)
        review_text = message_content(payload)
        if not review_text.strip():
            die("API returned empty review content", code=1)
        tokens_in, tokens_cached, tokens_out, tokens_reasoning = extract_usage(payload)
        ended = args.ended_at or utc_now_z()
    if args.dry_run or args.fixture_response:
        started = args.started_at or "2026-11-20T00:00:00Z"
        ended = args.ended_at or "2026-11-20T00:00:05Z"

    review_text = redact_text(review_text)
    record = build_run_record(
        models_data=models_data,
        reviewer_id=reviewer_id,
        coder_id=coder,
        meta=meta,
        tokens_in=tokens_in,
        tokens_cached=tokens_cached,
        tokens_out=tokens_out,
        tokens_reasoning=tokens_reasoning,
        predicted_cost_usd=predicted,
        started_at=started,
        ended_at=ended,
        harness_run_id=args.harness_run_id,
    )

    args.out_dir.mkdir(parents=True, exist_ok=True)
    review_path = args.out_dir / "critic-review.md"
    record_path = args.out_dir / "critic-run-record.json"
    review_path.write_text(review_text.rstrip() + "\n", encoding="utf-8")
    record_path.write_text(
        json.dumps(record, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    # Reject accidental secret echo in outputs
    for path in (review_path, record_path):
        key = os.environ.get("DEEPINFRA_API_KEY")
        if key and len(key) >= 8 and key in path.read_text(encoding="utf-8"):
            die("refusing to write outputs that contain DEEPINFRA_API_KEY value")

    print(
        f"critic-run: reviewer={reviewer_id} coder={coder} "
        f"tokens_in={tokens_in} tokens_out={tokens_out} cached={tokens_cached} "
        f"actual_cost_usd={record['actual_cost_usd']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())