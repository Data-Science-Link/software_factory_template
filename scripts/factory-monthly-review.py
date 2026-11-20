#!/usr/bin/env python3
"""Deterministic 30-day factory health, spend, quality, and routing review (stdlib only).

Aggregates run records under --runs-dir, budget caps from --budget and --models,
and emits a monthly review packet (Markdown or JSON). Malformed run JSON is skipped
without raising. No network calls.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RUNS = ROOT / "factory" / "runs"
DEFAULT_BUDGET = ROOT / "factory" / "budget.yml"
DEFAULT_MODELS = ROOT / ".factory" / "models.yaml"

FAIL_OUTCOMES = frozenset(
    {"failed", "cap_exceeded", "gate_failed", "cancelled"}
)
MERGED_OUTCOMES = frozenset({"pr_opened", "pr_updated"})
SUCCESS_OUTCOMES = frozenset({"pr_opened", "pr_updated", "no_changes"})

FIX_ROUND_RATE_TUNE = 0.20
REVIEW_VS_CODE_TUNE = 0.30
BUDGET_PACE_INVESTIGATE = 0.80

DEFAULT_BUDGET_VALUES = {
    "monthly_usd": 10.0,
    "weekly_usd": 2.5,
    "issue_target_usd": 0.15,
    "issue_cap_usd": 1.0,
    "warn_pct": 80.0,
}


def _strip_scalar(raw: str) -> str:
    value = raw.strip()
    if (value.startswith('"') and value.endswith('"')) or (
        value.startswith("'") and value.endswith("'")
    ):
        return value[1:-1]
    return value


def _parse_float(raw: str) -> float | None:
    try:
        return float(_strip_scalar(raw))
    except ValueError:
        return None


def load_flat_yaml(path: Path) -> dict[str, float]:
    """Parse a simple top-level key: number YAML file without PyYAML."""
    if not path.is_file():
        return {}
    out: dict[str, float] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if ":" not in stripped:
            continue
        key, rest = stripped.split(":", 1)
        key = key.strip()
        val = _parse_float(rest)
        if val is not None:
            out[key] = val
    return out


def load_models_budget(path: Path) -> dict[str, float]:
    """Read the ``budget:`` block from models.yaml (subset parser)."""
    if not path.is_file():
        return {}
    out: dict[str, float] = {}
    in_budget = False
    budget_indent: int | None = None
    key_map = {
        "deepinfra_monthly_limit_usd": "monthly_usd",
        "deepinfra_monthly_budget_usd": "monthly_usd",
        "monthly_usd": "monthly_usd",
        "weekly_budget_usd": "weekly_usd",
        "weekly_usd": "weekly_usd",
        "issue_target_usd": "issue_target_usd",
        "issue_cap_usd": "issue_cap_usd",
        "warn_pct": "warn_pct",
        "actions_minutes_warn_pct": "warn_pct",
    }
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not in_budget:
            if line.startswith("budget:"):
                in_budget = True
                if line.strip() != "budget:":
                    rest = line.split(":", 1)[1].strip()
                    if rest:
                        pass
                budget_indent = len(line) - len(line.lstrip()) + 2
            continue
        indent = len(line) - len(line.lstrip())
        if budget_indent is not None and indent < budget_indent and line.strip():
            break
        body = line.strip()
        if ":" not in body:
            continue
        raw_key, rest = body.split(":", 1)
        mapped = key_map.get(raw_key.strip())
        if not mapped:
            continue
        val = _parse_float(rest)
        if val is not None:
            out[mapped] = val
    return out


def merge_budget(budget_path: Path, models_path: Path) -> dict[str, float]:
    merged = dict(DEFAULT_BUDGET_VALUES)
    file_vals = load_flat_yaml(budget_path)
    merged.update({k: file_vals[k] for k in file_vals})
    model_vals = load_models_budget(models_path)
    for key, val in model_vals.items():
        if key not in file_vals:
            merged[key] = val
    if "weekly_usd" not in file_vals and "weekly_usd" not in model_vals:
        merged["weekly_usd"] = merged["monthly_usd"] / 4.0
    return merged


def parse_utc_z(value: str) -> datetime | None:
    if not isinstance(value, str) or not value.endswith("Z"):
        return None
    body = value[:-1]
    try:
        if "." in body:
            return datetime.strptime(body, "%Y-%m-%dT%H:%M:%S.%f").replace(
                tzinfo=timezone.utc
            )
        return datetime.strptime(body, "%Y-%m-%dT%H:%M:%S").replace(
            tzinfo=timezone.utc
        )
    except ValueError:
        return None


def parse_as_of(value: str) -> datetime:
    d = date.fromisoformat(value)
    return datetime.combine(d, time(23, 59, 59, 999999), tzinfo=timezone.utc)


def window_bounds(end_utc: datetime, days: int) -> tuple[datetime, datetime]:
    start_date = (end_utc.date() - timedelta(days=days - 1))
    start = datetime.combine(start_date, time.min, tzinfo=timezone.utc)
    return start, end_utc


def calendar_month_bounds(end_utc: datetime) -> tuple[datetime, datetime]:
    d = end_utc.date()
    start = datetime.combine(d.replace(day=1), time.min, tzinfo=timezone.utc)
    return start, end_utc


def safe_float(value: Any, default: float = 0.0) -> float:
    if isinstance(value, bool) or value is None:
        return default
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def safe_int(value: Any, default: int = 0) -> int:
    if isinstance(value, bool) or value is None:
        return default
    if isinstance(value, int):
        return value
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def load_runs(runs_dir: Path) -> tuple[list[dict[str, Any]], int]:
    skipped = 0
    runs: list[dict[str, Any]] = []
    if not runs_dir.is_dir():
        return runs, skipped
    for path in sorted(runs_dir.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            skipped += 1
            continue
        if not isinstance(data, dict):
            skipped += 1
            continue
        data["_source_file"] = path.name
        runs.append(data)
    return runs, skipped


def filter_runs_in_window(
    runs: list[dict[str, Any]], start: datetime, end: datetime
) -> list[dict[str, Any]]:
    selected: list[dict[str, Any]] = []
    for row in runs:
        started = parse_utc_z(str(row.get("started_at") or ""))
        if started is None:
            continue
        if start <= started <= end:
            selected.append(row)
    return selected


def attach_issue_sequences(runs: list[dict[str, Any]]) -> None:
    by_issue: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for rec in runs:
        try:
            by_issue[int(rec.get("issue"))].append(rec)
        except (TypeError, ValueError):
            continue
    for rows in by_issue.values():
        rows.sort(key=lambda r: (parse_utc_z(r["started_at"]) or datetime.min.replace(tzinfo=timezone.utc), r.get("run_id") or ""))
        for seq, row in enumerate(rows, start=1):
            row["_issue_run_seq"] = seq


def sum_spend(runs: list[dict[str, Any]]) -> float:
    return round(sum(safe_float(r.get("actual_cost_usd")) for r in runs), 6)


def cache_hit_rate(runs: list[dict[str, Any]]) -> float | None:
    tin = sum(safe_int(r.get("tokens_in")) for r in runs)
    if tin <= 0:
        return None
    tcached = sum(safe_int(r.get("tokens_cached")) for r in runs)
    return round(tcached / tin, 6)


def pass_rate(runs: list[dict[str, Any]]) -> float | None:
    if not runs:
        return None
    return round(sum(1 for r in runs if r.get("gate_passed") is True) / len(runs), 6)


def merged_rate(runs: list[dict[str, Any]]) -> float | None:
    if not runs:
        return None
    merged = sum(
        1
        for r in runs
        if r.get("gate_passed") is True
        and str(r.get("outcome") or "") in MERGED_OUTCOMES
    )
    return round(merged / len(runs), 6)


def fix_round_rate(runs: list[dict[str, Any]]) -> float | None:
    if not runs:
        return None
    fix_rounds = sum(1 for r in runs if (r.get("_issue_run_seq") or 0) > 1)
    return round(fix_rounds / len(runs), 6)


def failure_breakdown(runs: list[dict[str, Any]]) -> dict[str, int]:
    by_error: dict[str, int] = defaultdict(int)
    by_outcome: dict[str, int] = defaultdict(int)
    for r in runs:
        outcome = str(r.get("outcome") or "unknown")
        failed = (
            not r.get("gate_passed")
            or outcome in FAIL_OUTCOMES
        )
        if not failed and outcome not in FAIL_OUTCOMES:
            continue
        err = r.get("error_class")
        if isinstance(err, str) and err.strip():
            by_error[err.strip()] += 1
        else:
            by_error["unspecified"] += 1
        by_outcome[outcome] += 1
    return {
        "by_error_class": dict(sorted(by_error.items())),
        "by_outcome": dict(sorted(by_outcome.items())),
    }


def issue_spend_rollup(runs: list[dict[str, Any]]) -> dict[int, float]:
    by_issue: dict[int, float] = defaultdict(float)
    for r in runs:
        try:
            issue = int(r.get("issue"))
        except (TypeError, ValueError):
            continue
        by_issue[issue] += safe_float(r.get("actual_cost_usd"))
    return {k: round(v, 6) for k, v in by_issue.items()}


def work_type_split(runs: list[dict[str, Any]], total_spend: float) -> dict[str, Any]:
    coding = [r for r in runs if str(r.get("work_type") or "") == "code"]
    review = [r for r in runs if str(r.get("work_type") or "") == "review"]
    code_spend = sum_spend(coding)
    review_spend = sum_spend(review)

    def slice_stats(rows: list[dict[str, Any]], spend: float) -> dict[str, Any]:
        n = len(rows)
        share = round(100.0 * spend / total_spend, 2) if total_spend > 0 else 0.0
        return {
            "run_count": n,
            "total_spend_usd": spend,
            "cost_share_pct": share,
        }

    review_vs_coding = (
        round(review_spend / code_spend, 6) if code_spend > 0 else None
    )
    return {
        "coding": slice_stats(coding, code_spend),
        "review": slice_stats(review, review_spend),
        "review_spend_vs_coding_spend_ratio": review_vs_coding,
    }


def model_efficiency(runs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for r in runs:
        groups[str(r.get("model") or "unknown")].append(r)
    rows: list[dict[str, Any]] = []
    for model in sorted(groups):
        g = groups[model]
        spend = sum_spend(g)
        rows.append(
            {
                "model": model,
                "run_count": len(g),
                "total_spend_usd": spend,
                "cache_hit_rate": cache_hit_rate(g),
                "pass_rate": pass_rate(g),
            }
        )
    return rows


def build_action_prompts(
    *,
    n_runs: int,
    fix_rate: float | None,
    review_ratio: float | None,
    month_pace_pct: float | None,
    failures: int,
) -> list[dict[str, str]]:
    prompts: list[dict[str, str]] = []

    if n_runs == 0:
        prompts.append(
            {
                "level": "Investigate",
                "finding": "Zero factory runs in the reporting window; confirm run "
                "collection, worker harness, and that started_at timestamps are UTC Z.",
            }
        )
        return prompts

    if month_pace_pct is not None and month_pace_pct >= BUDGET_PACE_INVESTIGATE * 100:
        prompts.append(
            {
                "level": "Investigate",
                "finding": f"Calendar-month spend is {month_pace_pct:.1f}% of the monthly "
                "cap; pause non-urgent kicks or raise the cap in budget config.",
            }
        )
    elif month_pace_pct is not None and month_pace_pct < BUDGET_PACE_INVESTIGATE * 100:
        prompts.append(
            {
                "level": "Keep",
                "finding": f"Budget pacing is healthy at {month_pace_pct:.1f}% of the monthly cap.",
            }
        )

    if fix_rate is not None and fix_rate > FIX_ROUND_RATE_TUNE:
        prompts.append(
            {
                "level": "Tune",
                "finding": f"Fix-round rate is {fix_rate:.0%} (threshold {FIX_ROUND_RATE_TUNE:.0%}); "
                "tighten specs or adjust models.yaml routing before the next cycle.",
            }
        )
    elif fix_rate is not None:
        prompts.append(
            {
                "level": "Keep",
                "finding": f"Fix-round rate {fix_rate:.0%} is within the {FIX_ROUND_RATE_TUNE:.0%} guardrail.",
            }
        )

    if review_ratio is not None and review_ratio > REVIEW_VS_CODE_TUNE:
        prompts.append(
            {
                "level": "Tune",
                "finding": f"Review spend is {review_ratio:.0%} of coding spend (threshold "
                f"{REVIEW_VS_CODE_TUNE:.0%}); check independent review model cost or scope.",
            }
        )
    elif review_ratio is not None:
        prompts.append(
            {
                "level": "Keep",
                "finding": "Review vs coding spend mix is within the configured ratio.",
            }
        )

    if failures:
        prompts.append(
            {
                "level": "Investigate",
                "finding": f"{failures} failing or non-passing run(s) in the window; triage "
                "outcome and error_class breakdown before changing routing.",
            }
        )

    if not prompts:
        prompts.append(
            {
                "level": "Keep",
                "finding": "Volume, spend, and quality signals are within thresholds for this window.",
            }
        )

    order = {"Investigate": 0, "Tune": 1, "Keep": 2}
    prompts.sort(key=lambda p: (order.get(p["level"], 9), p["finding"]))
    return prompts


def build_report(
    *,
    runs_dir: Path,
    budget_path: Path,
    models_path: Path,
    days: int,
    as_of_utc: datetime,
    all_skipped: int,
) -> dict[str, Any]:
    budget = merge_budget(budget_path, models_path)
    window_start, window_end = window_bounds(as_of_utc, days)
    month_start, month_end = calendar_month_bounds(as_of_utc)

    all_runs, _ = load_runs(runs_dir)
    window_runs = filter_runs_in_window(all_runs, window_start, window_end)
    attach_issue_sequences(window_runs)
    month_runs = filter_runs_in_window(all_runs, month_start, month_end)

    total_spend = sum_spend(window_runs)
    month_spend = sum_spend(month_runs)
    month_pace = (
        round(100.0 * month_spend / budget["monthly_usd"], 2)
        if budget["monthly_usd"] > 0
        else None
    )

    issues = issue_spend_rollup(window_runs)
    unique_issues = len(issues)
    over_target = sum(
        1 for spend in issues.values() if spend > budget["issue_target_usd"]
    )
    avg_per_issue = (
        round(total_spend / unique_issues, 6) if unique_issues else None
    )

    failures = sum(
        1
        for r in window_runs
        if not r.get("gate_passed")
        or str(r.get("outcome") or "") in FAIL_OUTCOMES
    )

    wt = work_type_split(window_runs, total_spend)
    fix_rate = fix_round_rate(window_runs)
    prompts = build_action_prompts(
        n_runs=len(window_runs),
        fix_rate=fix_rate,
        review_ratio=wt.get("review_spend_vs_coding_spend_ratio"),
        month_pace_pct=month_pace,
        failures=failures,
    )

    generated_at = as_of_utc.strftime("%Y-%m-%dT%H:%M:%SZ")

    return {
        "action_prompts": prompts,
        "as_of_date": as_of_utc.date().isoformat(),
        "budget_paths": {
            "budget_yml": str(budget_path),
            "models_yaml": str(models_path),
        },
        "budget_values": {
            "issue_cap_usd": budget["issue_cap_usd"],
            "issue_target_usd": budget["issue_target_usd"],
            "monthly_usd": budget["monthly_usd"],
            "weekly_usd": budget["weekly_usd"],
        },
        "failure_breakdown": failure_breakdown(window_runs),
        "generated_at_utc": generated_at,
        "model_efficiency": model_efficiency(window_runs),
        "runs_dir": str(runs_dir),
        "schema_version": 1,
        "skipped_files": all_skipped,
        "spend_budget": {
            "avg_cost_per_issue_usd": avg_per_issue,
            "calendar_month_spend_usd": month_spend,
            "issues_over_target_count": over_target,
            "monthly_budget_pct_used": month_pace,
            "monthly_budget_usd": budget["monthly_usd"],
            "total_spend_usd": total_spend,
        },
        "volume_reliability": {
            "fix_round_rate": fix_round_rate(window_runs),
            "merged_rate": merged_rate(window_runs),
            "pass_rate": pass_rate(window_runs),
            "total_runs": len(window_runs),
            "unique_issues": unique_issues,
        },
        "window_days": days,
        "window_utc": {
            "end": window_end.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "start": window_start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
        "work_type_split": wt,
    }


def _fmt_pct(value: float | None) -> str:
    if value is None:
        return "n/a"
    return f"{value * 100:.2f}%"


def _fmt_money(value: float | None) -> str:
    if value is None:
        return "n/a"
    return f"${value:.4f}"


def format_markdown(report: dict[str, Any]) -> str:
    vr = report["volume_reliability"]
    sb = report["spend_budget"]
    wt = report["work_type_split"]
    lines = [
        "# Factory monthly review",
        "",
        f"- **Window:** {report['window_days']} days ending **{report['as_of_date']}** (UTC)",
        f"- **Runs directory:** `{report['runs_dir']}`",
        f"- **Skipped malformed files:** {report['skipped_files']}",
        "",
    ]
    if vr["total_runs"] == 0:
        lines.extend(
            [
                "No run records in this window.",
                "",
            ]
        )
        for p in report["action_prompts"]:
            lines.append(f"- **{p['level']}:** {p['finding']}")
        lines.append("")
        return "\n".join(lines)

    lines.extend(
        [
            "## Volume & reliability",
            "",
            f"| Metric | Value |",
            f"|---|---|",
            f"| Total runs | {vr['total_runs']} |",
            f"| Unique issues | {vr['unique_issues']} |",
            f"| Pass rate | {_fmt_pct(vr['pass_rate'])} |",
            f"| Merged rate (PR opened/updated, gate pass) | {_fmt_pct(vr['merged_rate'])} |",
            f"| Fix-round rate | {_fmt_pct(vr['fix_round_rate'])} |",
            "",
            "## Spend & budget",
            "",
            f"| Metric | Value |",
            f"|---|---|",
            f"| Total spend (window) | {_fmt_money(sb['total_spend_usd'])} |",
            f"| Calendar-month spend vs cap | {_fmt_money(sb['calendar_month_spend_usd'])} / "
            f"{_fmt_money(sb['monthly_budget_usd'])} "
            f"({sb['monthly_budget_pct_used'] if sb['monthly_budget_pct_used'] is not None else 'n/a'}% used) |",
            f"| Avg cost per issue | {_fmt_money(sb['avg_cost_per_issue_usd'])} |",
            f"| Issues over target ({_fmt_money(report['budget_values']['issue_target_usd'])}) | "
            f"{sb['issues_over_target_count']} |",
            "",
            "## Work type (coding vs review)",
            "",
            f"| Work type | Runs | Spend | Share % |",
            f"|---|---:|---:|---:|",
            f"| code | {wt['coding']['run_count']} | {_fmt_money(wt['coding']['total_spend_usd'])} | "
            f"{wt['coding']['cost_share_pct']:.2f} |",
            f"| review | {wt['review']['run_count']} | {_fmt_money(wt['review']['total_spend_usd'])} | "
            f"{wt['review']['cost_share_pct']:.2f} |",
            "",
            "## Model efficiency",
            "",
            "| Model | Runs | Spend | Cache hit | Pass rate |",
            "|---|---:|---:|---:|---:|",
        ]
    )
    for row in report["model_efficiency"]:
        lines.append(
            f"| {row['model']} | {row['run_count']} | {_fmt_money(row['total_spend_usd'])} | "
            f"{_fmt_pct(row['cache_hit_rate'])} | {_fmt_pct(row['pass_rate'])} |"
        )

    fb = report["failure_breakdown"]
    if fb["by_outcome"] or fb["by_error_class"]:
        lines.extend(["", "## Failure breakdown", ""])
        if fb["by_outcome"]:
            lines.append("**By outcome:**")
            for k, v in fb["by_outcome"].items():
                lines.append(f"- {k}: {v}")
        if fb["by_error_class"]:
            lines.append("")
            lines.append("**By error_class:**")
            for k, v in fb["by_error_class"].items():
                lines.append(f"- {k}: {v}")

    lines.extend(["", "## Action prompts", ""])
    for p in report["action_prompts"]:
        lines.append(f"- **{p['level']}:** {p['finding']}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--runs-dir",
        type=Path,
        default=DEFAULT_RUNS,
        help="Directory of factory run JSON files",
    )
    parser.add_argument(
        "--budget",
        type=Path,
        default=DEFAULT_BUDGET,
        help="Budget YAML (default: factory/budget.yml)",
    )
    parser.add_argument(
        "--models",
        type=Path,
        default=DEFAULT_MODELS,
        help="Models YAML for budget fallback (default: .factory/models.yaml)",
    )
    parser.add_argument("--days", type=int, default=30, help="Window length in days")
    parser.add_argument(
        "--as-of",
        default=None,
        help="Pin window end (YYYY-MM-DD, UTC end of day)",
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON on stdout")
    parser.add_argument("--out", type=Path, default=None, help="Optional output file path")
    args = parser.parse_args()

    if args.days < 1:
        print("factory-monthly-review: --days must be >= 1", file=sys.stderr)
        return 2

    if args.as_of:
        try:
            as_of_utc = parse_as_of(args.as_of)
        except ValueError as exc:
            print(f"factory-monthly-review: invalid --as-of: {exc}", file=sys.stderr)
            return 2
    else:
        today = datetime.now(timezone.utc).date()
        as_of_utc = parse_as_of(today.isoformat())

    runs_dir = args.runs_dir.resolve()
    _, skipped = load_runs(runs_dir)

    report = build_report(
        runs_dir=runs_dir,
        budget_path=args.budget.resolve(),
        models_path=args.models.resolve(),
        days=args.days,
        as_of_utc=as_of_utc,
        all_skipped=skipped,
    )

    payload = json.dumps(report, indent=2, sort_keys=True)
    if args.json:
        text = payload + "\n"
    else:
        text = format_markdown(report)

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
        if not text.endswith("\n"):
            sys.stdout.write("\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())