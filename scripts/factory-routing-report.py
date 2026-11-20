#!/usr/bin/env python3
"""Offline routing review report from factory run records and models.yaml.

Aggregates validated JSON under --runs-dir (default factory/runs/) by model,
phase (spec / build / fix), complexity, and risk. Emits metrics aligned with
factory/dbt/models/marts/fct_agent_runs.sql plus data-backed recommendations.
No network calls.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import statistics
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RUNS = ROOT / "factory" / "runs"
DEFAULT_MODELS = ROOT / ".factory" / "models.yaml"
VALIDATOR_PATH = ROOT / "scripts" / "factory-validate-run.py"

SAMPLE_THRESHOLD = 5
HIGH_FIX_ROUND_RATE = 0.50
LOW_FIRST_PASS_RATE = 0.60

DOCS_CUTOFF_PATTERNS = tuple(
    re.compile(p, re.IGNORECASE)
    for p in (
        r"knowledge cutoff",
        r"training (data|cutoff)",
        r"library version",
        r"version cutoff",
        r"documentation (is )?outdated",
        r"api version mismatch",
        r"not in my training",
    )
)

PRODUCT_REPO_PREFIX = "Data-Science-Link/"


def load_validator():
    spec = importlib.util.spec_from_file_location(
        "factory_validate_run", VALIDATOR_PATH
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.load_record, module.validate_record


def normalize_model_id(model: str) -> str:
    return (model or "").strip().lower()


def parse_utc(value: str) -> datetime:
    if value.endswith("Z"):
        body = value[:-1]
        fmt = "%Y-%m-%dT%H:%M:%S.%f" if "." in body else "%Y-%m-%dT%H:%M:%S"
        return datetime.strptime(body, fmt).replace(tzinfo=timezone.utc)
    raise ValueError(f"not UTC Z timestamp: {value!r}")


def phase_from_record(record: dict[str, Any]) -> str:
    """Map a run record to spec / build / fix (same signals as factory-run-review)."""
    if record.get("work_type") == "spec":
        return "spec"
    if record.get("outcome") == "pr_updated":
        return "fix"
    if record.get("work_type") in ("code", "docs", "data", "review"):
        return "build"
    return "unknown"


def cache_hit_rate(record: dict[str, Any]) -> float | None:
    tokens_in = int(record.get("tokens_in") or 0)
    if tokens_in <= 0:
        return None
    return record.get("tokens_cached", 0) / tokens_in


def docs_cutoff_hit(notes: str) -> bool:
    text = notes or ""
    return any(p.search(text) for p in DOCS_CUTOFF_PATTERNS)


def attach_issue_sequences(records: list[dict[str, Any]]) -> None:
    by_issue: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for rec in records:
        by_issue[int(rec["issue"])].append(rec)
    for issue, rows in by_issue.items():
        rows.sort(
            key=lambda r: (
                parse_utc(r["started_at"]),
                r.get("run_id") or "",
            )
        )
        for seq, row in enumerate(rows, start=1):
            row["_issue_run_seq"] = seq
            row["_first_time_gate_pass"] = bool(seq == 1 and row.get("gate_passed"))


def group_key(record: dict[str, Any]) -> tuple[str, str, str, str]:
    return (
        normalize_model_id(record.get("model", "")),
        phase_from_record(record),
        str(record.get("complexity") or "unknown"),
        str(record.get("risk") or "unknown"),
    )


def summarize_group(rows: list[dict[str, Any]]) -> dict[str, Any]:
    costs = [float(r.get("actual_cost_usd") or 0) for r in rows]
    durations = [int(r.get("duration_s") or 0) for r in rows]
    cache_rates = [x for x in (cache_hit_rate(r) for r in rows) if x is not None]
    first_runs = [r for r in rows if r.get("_issue_run_seq") == 1]
    fix_rounds = [r for r in rows if (r.get("_issue_run_seq") or 0) > 1]

    n = len(rows)
    first_pass = (
        sum(1 for r in first_runs if r.get("gate_passed")) / len(first_runs)
        if first_runs
        else None
    )
    fix_rate = len(fix_rounds) / n if n else None

    return {
        "run_count": n,
        "mean_cost_usd": statistics.mean(costs) if costs else None,
        "median_cost_usd": statistics.median(costs) if costs else None,
        "total_cost_usd": round(sum(costs), 6),
        "mean_duration_s": round(statistics.mean(durations), 2) if durations else None,
        "first_pass_success_rate": round(first_pass, 4) if first_pass is not None else None,
        "fix_round_rate": round(fix_rate, 4) if fix_rate is not None else None,
        "mean_cache_hit_rate": round(statistics.mean(cache_rates), 4) if cache_rates else None,
        "first_runs": len(first_runs),
        "fix_rounds": len(fix_rounds),
    }


def build_recommendations(groups: list[dict[str, Any]], docs_check: dict[str, Any]) -> list[str]:
    recs: list[str] = []
    for g in groups:
        label = (
            f"{g['model_id']} phase={g['phase']} "
            f"complexity={g['complexity']} risk={g['risk']}"
        )
        n = g["metrics"]["run_count"]
        if n < SAMPLE_THRESHOLD:
            recs.append(
                f"{label}: insufficient sample size (n={n} < {SAMPLE_THRESHOLD}); "
                "no routing change suggested."
            )
            continue
        m = g["metrics"]
        if (
            m.get("fix_round_rate") is not None
            and m["fix_round_rate"] >= HIGH_FIX_ROUND_RATE
        ):
            recs.append(
                f"{label}: high fix-round rate "
                f"({m['fix_round_rate']:.0%} over n={n}); review whether "
                f"models.yaml should route this tier to a stronger builder or "
                "split issues before retrying."
            )
        if (
            m.get("first_pass_success_rate") is not None
            and m["first_pass_success_rate"] < LOW_FIRST_PASS_RATE
        ):
            recs.append(
                f"{label}: low first-pass gate pass rate "
                f"({m['first_pass_success_rate']:.0%} on first runs); consider "
                "tightening spec scope or escalating model for this tier."
            )
        if not any(label in r for r in recs):
            recs.append(
                f"{label}: metrics within thresholds on n={n}; no models.yaml "
                "change suggested from this slice alone."
            )

    hits = docs_check.get("cutoff_hits", 0)
    scanned = docs_check.get("product_repo_runs_scanned", 0)
    if scanned < SAMPLE_THRESHOLD:
        recs.append(
            f"Docs lookup: insufficient product-repo sample (n={scanned} < "
            f"{SAMPLE_THRESHOLD}); keep opencode.json mcp: {{}} default-off."
        )
    elif hits == 0:
        recs.append(
            "Docs lookup: no library-version / knowledge-cutoff signals in run "
            "notes; keep read-only docs MCP default-off (mcp: {})."
        )
    else:
        rate = hits / scanned
        recs.append(
            f"Docs lookup: {hits}/{scanned} product-repo runs ({rate:.0%}) mention "
            "library-version or knowledge-cutoff errors in notes; evaluate an "
            "optional read-only docs MCP (oauth: false, default-deny tools) in a "
            "human-reviewed PR — do not auto-enable."
        )
    return recs


def load_models(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    if not isinstance(data, dict):
        raise SystemExit(f"{path}: models.yaml must be a mapping")
    return data


def load_runs(runs_dir: Path, load_record, validate_record) -> tuple[list[dict], list[str]]:
    records: list[dict[str, Any]] = []
    skipped: list[str] = []
    if not runs_dir.is_dir():
        return records, [f"runs directory missing: {runs_dir}"]
    for path in sorted(runs_dir.glob("*.json")):
        try:
            record = load_record(path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            skipped.append(f"{path.name}: {exc}")
            continue
        errors = validate_record(record, path)
        if errors:
            skipped.append(f"{path.name}: " + "; ".join(errors[:3]))
            continue
        records.append(record)
    return records, skipped


def build_report(
    records: list[dict[str, Any]],
    models_path: Path,
    models: dict[str, Any],
    runs_dir: Path,
    skipped: list[str],
    generated_at_utc: str,
) -> dict[str, Any]:
    attach_issue_sequences(records)

    buckets: dict[tuple[str, str, str, str], list[dict[str, Any]]] = defaultdict(list)
    for rec in records:
        buckets[group_key(rec)].append(rec)

    groups: list[dict[str, Any]] = []
    for key in sorted(buckets):
        model_id, phase, complexity, risk = key
        metrics = summarize_group(buckets[key])
        groups.append(
            {
                "model_id": model_id,
                "phase": phase,
                "complexity": complexity,
                "risk": risk,
                "metrics": metrics,
            }
        )

    product_runs = [
        r
        for r in records
        if str(r.get("repo", "")).startswith(PRODUCT_REPO_PREFIX)
        and r.get("work_type") == "code"
    ]
    cutoff_hits = sum(1 for r in product_runs if docs_cutoff_hit(r.get("notes", "")))
    docs_check = {
        "product_repo_runs_scanned": len(product_runs),
        "cutoff_hits": cutoff_hits,
        "patterns": [p.pattern for p in DOCS_CUTOFF_PATTERNS],
    }

    routing_rules = models.get("routing_rules") or []
    recommendations = build_recommendations(groups, docs_check)

    return {
        "schema_version": 1,
        "generated_at_utc": generated_at_utc,
        "runs_dir": str(runs_dir),
        "models_path": str(models_path),
        "sample_threshold": SAMPLE_THRESHOLD,
        "run_count": len(records),
        "skipped_files": skipped,
        "groups": groups,
        "docs_lookup_check": docs_check,
        "routing_rules": [
            {
                "rule": row.get("rule"),
                "model": row.get("model"),
                "description": row.get("description"),
            }
            for row in routing_rules
        ],
        "recommendations": recommendations,
    }


def format_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# Factory routing report",
        "",
        f"- Runs loaded: **{report['run_count']}** from `{report['runs_dir']}`",
        f"- Models: `{report['models_path']}`",
        f"- Sample threshold: **{report['sample_threshold']}** runs per slice",
        "",
    ]
    if report["skipped_files"]:
        lines.append("## Skipped files")
        for item in report["skipped_files"]:
            lines.append(f"- {item}")
        lines.append("")

    lines.append("## Metrics by model / phase / tier")
    lines.append("")
    lines.append(
        "| model | phase | complexity | risk | n | mean $ | median $ | "
        "total $ | mean s | 1st-pass | fix-round | cache |"
    )
    lines.append("|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for g in report["groups"]:
        m = g["metrics"]
        lines.append(
            "| {model} | {phase} | {complexity} | {risk} | {n} | {mean_c} | "
            "{med_c} | {tot_c} | {dur} | {fp} | {fr} | {cache} |".format(
                model=g["model_id"],
                phase=g["phase"],
                complexity=g["complexity"],
                risk=g["risk"],
                n=m["run_count"],
                mean_c=_fmt_money(m.get("mean_cost_usd")),
                med_c=_fmt_money(m.get("median_cost_usd")),
                tot_c=_fmt_money(m.get("total_cost_usd")),
                dur=_fmt_num(m.get("mean_duration_s")),
                fp=_fmt_pct(m.get("first_pass_success_rate")),
                fr=_fmt_pct(m.get("fix_round_rate")),
                cache=_fmt_pct(m.get("mean_cache_hit_rate")),
            )
        )
    lines.append("")
    lines.append("## Recommendations")
    lines.append("")
    for rec in report["recommendations"]:
        lines.append(f"- {rec}")
    lines.append("")
    lines.append("## Docs lookup check (read-only)")
    lines.append("")
    d = report["docs_lookup_check"]
    lines.append(
        f"- Product-repo code runs scanned: **{d['product_repo_runs_scanned']}**"
    )
    lines.append(f"- Knowledge / library-version note hits: **{d['cutoff_hits']}**")
    lines.append("")
    lines.append("## Current routing rules (models.yaml)")
    lines.append("")
    for row in report["routing_rules"]:
        lines.append(
            f"- Rule **{row.get('rule')}** → `{row.get('model')}`: "
            f"{row.get('description') or ''}"
        )
    lines.append("")
    return "\n".join(lines)


def _fmt_money(value: float | None) -> str:
    if value is None:
        return "—"
    return f"{value:.4f}"


def _fmt_num(value: float | None) -> str:
    if value is None:
        return "—"
    return f"{value:.1f}"


def _fmt_pct(value: float | None) -> str:
    if value is None:
        return "—"
    return f"{value:.0%}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--runs-dir",
        type=Path,
        default=DEFAULT_RUNS,
        help="Directory of factory run record JSON files",
    )
    parser.add_argument(
        "--models",
        type=Path,
        default=DEFAULT_MODELS,
        help="Path to .factory/models.yaml",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print JSON report on stdout",
    )
    parser.add_argument(
        "--markdown",
        action="store_true",
        help="Print markdown report on stdout",
    )
    parser.add_argument(
        "--as-of",
        default=None,
        help="Pin generated_at_utc for reproducible output (UTC ...Z)",
    )
    args = parser.parse_args()

    if not args.json and not args.markdown:
        args.markdown = True

    load_record, validate_record = load_validator()
    models = load_models(args.models)
    records, skipped = load_runs(args.runs_dir.resolve(), load_record, validate_record)
    generated_at = args.as_of or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    report = build_report(
        records,
        args.models.resolve(),
        models,
        args.runs_dir.resolve(),
        skipped,
        generated_at,
    )

    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    if args.markdown:
        if args.json:
            print()
        print(format_markdown(report))

    return 0


if __name__ == "__main__":
    sys.exit(main())