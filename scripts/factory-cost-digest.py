#!/usr/bin/env python3
"""CFO spend and quality digest from factory run records (offline, stdlib + PyYAML).

Aggregates validated-ish JSON under --runs-dir, budget caps from --models-file,
and emits a headline scorecard plus breakdowns for weekly check-ins and monthly review.
No network calls.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import defaultdict
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write(
        "ERROR: PyYAML required (pip install -r requirements-factory.txt)\n"
    )
    raise SystemExit(1)

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RUNS = ROOT / "factory" / "runs"
DEFAULT_MODELS = ROOT / ".factory" / "models.yaml"

FAIL_OUTCOMES = frozenset(
    {"failed", "cap_exceeded", "gate_failed", "cancelled"}
)
APPROACHING_CAP_FRAC = 0.80


def die(msg: str, code: int = 2) -> None:
    sys.stderr.write(f"ERROR: {msg}\n")
    raise SystemExit(code)


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


def parse_as_of(value: str, tz: ZoneInfo) -> datetime:
    """End of the as-of calendar day in the reporting timezone."""
    d = date.fromisoformat(value)
    local_end = datetime.combine(d, time(23, 59, 59, 999999), tzinfo=tz)
    return local_end


def _budget_field(raw: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        if key not in raw:
            continue
        value = raw[key]
        if value is None:
            continue
        return value
    return None


def _budget_usd(value: Any, default: float) -> float:
    """Parse a budget scalar; negative and non-numeric values fall back to default."""
    if isinstance(value, bool):
        return default
    if value is None:
        return default
    parsed = safe_float(value, default)
    if parsed < 0:
        return default
    return parsed


def load_models(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        die(f"models file is not valid UTF-8: {path}")
    if not text.strip():
        die(f"models file is empty: {path}")
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        die(f"models file is not valid YAML ({path}): {exc}")
    if data is None:
        return {}
    if not isinstance(data, dict):
        die(f"models file root must be a mapping, got {type(data).__name__}: {path}")
    return data


def budget_from_models(models: dict[str, Any]) -> dict[str, float]:
    raw = models.get("budget") or {}
    if not isinstance(raw, dict):
        raw = {}
    monthly = _budget_usd(
        _budget_field(
            raw,
            "deepinfra_monthly_limit_usd",
            "monthly_usd",
            "deepinfra_monthly_budget_usd",
        ),
        0.0,
    )
    weekly_raw = _budget_field(raw, "weekly_budget_usd", "weekly_usd")
    if weekly_raw is None:
        weekly_f = monthly / 4.0 if monthly > 0 else 0.0
    else:
        weekly_f = _budget_usd(weekly_raw, monthly / 4.0 if monthly > 0 else 0.0)
    issue_target = _budget_usd(raw.get("issue_target_usd"), 0.15)
    issue_cap = _budget_usd(raw.get("issue_cap_usd"), 1.0)
    return {
        "monthly_usd": monthly,
        "weekly_usd": weekly_f,
        "issue_target_usd": issue_target,
        "issue_cap_usd": issue_cap,
    }


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


def load_run(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except UnicodeDecodeError as exc:
        print(f"factory-cost-digest: skip {path.name}: {exc}", file=sys.stderr)
        return None
    except (OSError, json.JSONDecodeError) as exc:
        print(f"factory-cost-digest: skip {path.name}: {exc}", file=sys.stderr)
        return None
    if not isinstance(data, dict):
        print(f"factory-cost-digest: skip {path.name}: not an object", file=sys.stderr)
        return None
    return data


def load_runs(runs_dir: Path) -> list[dict[str, Any]]:
    if not runs_dir.is_dir():
        return []
    runs: list[dict[str, Any]] = []
    for path in sorted(runs_dir.glob("*.json")):
        row = load_run(path)
        if row:
            runs.append(row)
    return runs


def in_window(started_utc: datetime, window_start: datetime, window_end: datetime) -> bool:
    return window_start <= started_utc <= window_end


def window_bounds(
    as_of_local: datetime, days: int, tz: ZoneInfo
) -> tuple[datetime, datetime]:
    """Inclusive reporting window in UTC: [start, end]."""
    end_local = as_of_local
    start_local = datetime.combine(
        (as_of_local.date() - timedelta(days=days - 1)),
        time.min,
        tzinfo=tz,
    )
    return start_local.astimezone(timezone.utc), end_local.astimezone(timezone.utc)


def calendar_week_bounds(as_of_local: datetime, tz: ZoneInfo) -> tuple[datetime, datetime]:
    d = as_of_local.date()
    monday = d - timedelta(days=d.weekday())
    start_local = datetime.combine(monday, time.min, tzinfo=tz)
    end_local = datetime.combine(monday + timedelta(days=6), time(23, 59, 59, 999999), tzinfo=tz)
    return start_local.astimezone(timezone.utc), end_local.astimezone(timezone.utc)


def calendar_month_bounds(as_of_local: datetime, tz: ZoneInfo) -> tuple[datetime, datetime]:
    d = as_of_local.date()
    start_local = datetime.combine(d.replace(day=1), time.min, tzinfo=tz)
    if d.month == 12:
        next_month = d.replace(year=d.year + 1, month=1, day=1)
    else:
        next_month = d.replace(month=d.month + 1, day=1)
    end_local = datetime.combine(
        next_month - timedelta(days=1),
        time(23, 59, 59, 999999),
        tzinfo=tz,
    )
    return start_local.astimezone(timezone.utc), end_local.astimezone(timezone.utc)


def filter_runs_by_utc_bounds(
    runs: list[dict[str, Any]], start_utc: datetime, end_utc: datetime
) -> list[dict[str, Any]]:
    selected: list[dict[str, Any]] = []
    for r in runs:
        started = parse_utc_z(str(r.get("started_at") or ""))
        if started is None:
            continue
        if in_window(started, start_utc, end_utc):
            selected.append(r)
    return selected


def sum_spend(runs: list[dict[str, Any]]) -> float:
    return round(sum(safe_float(r.get("actual_cost_usd")) for r in runs), 6)


def cache_hit_rate(runs: list[dict[str, Any]]) -> float | None:
    tin = sum(safe_int(r.get("tokens_in")) for r in runs)
    tcached = sum(safe_int(r.get("tokens_cached")) for r in runs)
    if tin <= 0:
        return None
    return tcached / tin


def pct_used(spend: float, budget: float) -> float | None:
    if budget <= 0:
        return None
    return round(100.0 * spend / budget, 2)


def issue_rollup(runs: list[dict[str, Any]]) -> dict[int, dict[str, Any]]:
    by_issue: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for r in runs:
        issue = r.get("issue")
        if isinstance(issue, int) and issue >= 1:
            by_issue[issue].append(r)
        else:
            try:
                by_issue[int(issue)].append(r)
            except (TypeError, ValueError):
                continue
    out: dict[int, dict[str, Any]] = {}
    for issue, rows in by_issue.items():
        spend = sum_spend(rows)
        max_to_date = max(
            (safe_float(r.get("issue_spend_to_date_usd")) for r in rows),
            default=spend,
        )
        out[issue] = {
            "issue": issue,
            "run_count": len(rows),
            "total_cost_usd": round(spend, 6),
            "max_issue_spend_to_date_usd": round(max_to_date, 6),
            "any_gate_failed": any(not r.get("gate_passed") for r in rows),
        }
    return out


def flag_issue(
    rollup: dict[str, Any], issue_target: float, issue_cap: float
) -> list[str]:
    flags: list[str] = []
    spend = rollup["total_cost_usd"]
    to_date = rollup["max_issue_spend_to_date_usd"]
    ref = max(spend, to_date)
    if ref > issue_target:
        flags.append("over_target")
    if ref >= issue_cap:
        flags.append("over_cap")
    elif ref >= issue_cap * APPROACHING_CAP_FRAC:
        flags.append("approaching_cap")
    return flags


def breakdown(
    runs: list[dict[str, Any]], key: str
) -> list[dict[str, Any]]:
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for r in runs:
        groups[str(r.get(key) or "unknown")].append(r)
    rows: list[dict[str, Any]] = []
    for name in sorted(groups):
        g = groups[name]
        spend = sum_spend(g)
        n = len(g)
        rows.append(
            {
                key: name,
                "run_count": n,
                "total_cost_usd": spend,
                "avg_cost_per_run_usd": round(spend / n, 6) if n else 0.0,
                "cache_hit_rate": (
                    round(cache_hit_rate(g), 6) if cache_hit_rate(g) is not None else None
                ),
            }
        )
    return rows


def build_recommendations(
    scorecard: dict[str, Any],
    top_issues: list[dict[str, Any]],
    runs: list[dict[str, Any]],
    budget: dict[str, float],
) -> list[str]:
    recs: list[str] = []
    week_pct = scorecard.get("weekly_burn_pct_used")
    month_pct = scorecard.get("monthly_burn_pct_used")
    if week_pct is not None and week_pct >= 100:
        recs.append(
            "Weekly DeepInfra burn is at or above the weekly budget; defer non-urgent "
            "/oc runs until the next ISO week or raise the weekly cap in budget config."
        )
    elif week_pct is not None and week_pct >= 80:
        recs.append(
            f"Weekly burn is {week_pct:.1f}% of cap; watch spend before scheduling "
            "additional parallel workers."
        )
    if month_pct is not None and month_pct >= 100:
        recs.append(
            "Month-to-date spend exceeds the monthly DeepInfra cap; split large issues "
            "or pause factory kicks until the next calendar month."
        )

    over_target = [i for i in top_issues if "over_target" in i.get("flags", [])]
    if over_target:
        ids = ", ".join(f"#{i['issue']}" for i in over_target[:5])
        recs.append(
            f"Issues above per-issue target (${budget['issue_target_usd']:.2f}): "
            f"{ids}; review scope, caching, or model routing."
        )

    failures = scorecard.get("failure_count", 0)
    if failures:
        recs.append(
            f"{failures} failed or non-passing run(s) in the window; triage outcomes "
            "and fix-round rate before the monthly factory review."
        )

    pass_rate = scorecard.get("pass_rate")
    if pass_rate is not None and pass_rate < 0.75 and len(runs) >= 3:
        recs.append(
            f"Pass rate {pass_rate:.0%} is below 75% on n={len(runs)}; tighten specs "
            "or escalate model tier per models.yaml routing rules."
        )

    avg_issue = scorecard.get("avg_cost_per_issue_usd")
    if (
        avg_issue is not None
        and avg_issue > budget["issue_target_usd"] * 1.5
        and len(runs) >= 2
    ):
        recs.append(
            f"Average cost per issue (${avg_issue:.4f}) exceeds 1.5× the "
            f"${budget['issue_target_usd']:.2f} target; predict cost before /oc kicks."
        )

    if not recs:
        recs.append(
            "Spend and quality signals are within configured thresholds for this window; "
            "no immediate budget or routing changes suggested."
        )
    return recs


def compute_trend(runs: list[dict[str, Any]], as_of_local: datetime, tz: ZoneInfo) -> str:
    if len(runs) < 2:
        return "insufficient_data"
    this_start, this_end = calendar_month_bounds(as_of_local, tz)
    prev_end = this_start - timedelta(microseconds=1)
    prev_month_last = (as_of_local.date().replace(day=1) - timedelta(days=1))
    prev_start_local = datetime.combine(
        prev_month_last.replace(day=1), time.min, tzinfo=tz
    )
    prev_end_local = datetime.combine(
        prev_month_last, time(23, 59, 59, 999999), tzinfo=tz
    )
    prev_start = prev_start_local.astimezone(timezone.utc)
    prev_end_utc = prev_end_local.astimezone(timezone.utc)

    this_runs = filter_runs_by_utc_bounds(runs, this_start, this_end)
    prev_runs = filter_runs_by_utc_bounds(runs, prev_start, prev_end_utc)
    this_spend = sum_spend(this_runs)
    prev_spend = sum_spend(prev_runs)
    if prev_spend <= 0 and this_spend <= 0:
        return "flat"
    if prev_spend <= 0:
        return "up"
    delta = (this_spend - prev_spend) / prev_spend
    if delta > 0.10:
        return "up"
    if delta < -0.10:
        return "down"
    return "flat"


def build_report(
    all_runs: list[dict[str, Any]],
    models_path: Path,
    models: dict[str, Any],
    runs_dir: Path,
    days: int,
    as_of_local: datetime,
    tz_name: str,
    generated_at_utc: str,
) -> dict[str, Any]:
    budget = budget_from_models(models)
    tz = ZoneInfo(tz_name)
    window_start, window_end = window_bounds(as_of_local, days, tz)
    window_runs = filter_runs_by_utc_bounds(all_runs, window_start, window_end)

    week_start, week_end = calendar_week_bounds(as_of_local, tz)
    month_start, month_end = calendar_month_bounds(as_of_local, tz)
    week_runs = filter_runs_by_utc_bounds(all_runs, week_start, week_end)
    month_runs = filter_runs_by_utc_bounds(all_runs, month_start, month_end)

    total_spend = sum_spend(window_runs)
    week_spend = sum_spend(week_runs)
    month_spend = sum_spend(month_runs)

    passed = sum(1 for r in window_runs if r.get("gate_passed") is True)
    n_window = len(window_runs)
    pass_rate = round(passed / n_window, 4) if n_window else None

    failures = sum(
        1
        for r in window_runs
        if not r.get("gate_passed")
        or str(r.get("outcome") or "") in FAIL_OUTCOMES
    )
    overruns = sum(
        1
        for r in window_runs
        if safe_float(r.get("actual_cost_usd"))
        > budget["issue_target_usd"] * 2
        or str(r.get("outcome") or "") == "cap_exceeded"
    )

    issues = issue_rollup(window_runs)
    issue_spends = [v["total_cost_usd"] for v in issues.values()]
    avg_per_issue = (
        round(statistics.mean(issue_spends), 6) if issue_spends else None
    )

    top_issues: list[dict[str, Any]] = []
    for issue in sorted(issues, key=lambda i: issues[i]["total_cost_usd"], reverse=True):
        row = dict(issues[issue])
        row["flags"] = flag_issue(row, budget["issue_target_usd"], budget["issue_cap_usd"])
        top_issues.append(row)

    scorecard = {
        "run_count": n_window,
        "total_spend_usd": total_spend,
        "weekly_burn_usd": week_spend,
        "weekly_budget_usd": budget["weekly_usd"],
        "weekly_burn_pct_used": pct_used(week_spend, budget["weekly_usd"]),
        "monthly_burn_usd": month_spend,
        "monthly_budget_usd": budget["monthly_usd"],
        "monthly_burn_pct_used": pct_used(month_spend, budget["monthly_usd"]),
        "avg_cost_per_issue_usd": avg_per_issue,
        "issue_target_usd": budget["issue_target_usd"],
        "issue_cap_usd": budget["issue_cap_usd"],
        "pass_rate": pass_rate,
        "failure_count": failures,
        "overrun_count": overruns,
        "overall_cache_hit_rate": (
            round(cache_hit_rate(window_runs), 6)
            if cache_hit_rate(window_runs) is not None
            else None
        ),
    }

    review = {
        "cost_trend": compute_trend(all_runs, as_of_local, tz),
        "failure_count": failures,
        "overrun_count": overruns,
        "recommendations": build_recommendations(
            scorecard, top_issues, window_runs, budget
        ),
    }

    return {
        "schema_version": 1,
        "generated_at_utc": generated_at_utc,
        "runs_dir": str(runs_dir),
        "models_path": str(models_path),
        "timezone": tz_name,
        "as_of_date": as_of_local.date().isoformat(),
        "window_days": days,
        "window_utc": {
            "start": window_start.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "end": window_end.strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
        "scorecard": scorecard,
        "top_issues_by_spend": top_issues,
        "by_model": breakdown(window_runs, "model"),
        "by_harness": breakdown(window_runs, "harness"),
        "by_provider": breakdown(window_runs, "provider"),
        "review_readiness": review,
        "empty": n_window == 0,
    }


def fmt_pct(value: float | None) -> str:
    if value is None:
        return "n/a"
    return f"{value:.1f}%"


def fmt_money(value: float | None) -> str:
    if value is None:
        return "n/a"
    return f"${value:.4f}"


def fmt_rate(value: float | None) -> str:
    if value is None:
        return "n/a"
    return f"{value * 100:.2f}%"


def format_markdown(report: dict[str, Any]) -> str:
    if report.get("empty"):
        lines = [
            "# Factory cost & quality digest",
            "",
            f"No run records in the last **{report['window_days']}** day(s) "
            f"(as of **{report['as_of_date']}**, {report['timezone']}).",
            "",
            f"Runs directory: `{report['runs_dir']}`",
            "",
        ]
        return "\n".join(lines)

    sc = report["scorecard"]
    lines = [
        "# Factory cost & quality digest",
        "",
        f"- Window: **{report['window_days']}** days ending **{report['as_of_date']}** "
        f"({report['timezone']})",
        f"- Runs loaded: **{sc['run_count']}** from `{report['runs_dir']}`",
        f"- Budget source: `{report['models_path']}`",
        "",
        "## Headline scorecard",
        "",
        f"| Metric | Value |",
        f"|---|---|",
        f"| Total spend (window) | {fmt_money(sc['total_spend_usd'])} |",
        f"| Weekly burn vs cap | {fmt_money(sc['weekly_burn_usd'])} / "
        f"{fmt_money(sc['weekly_budget_usd'])} ({fmt_pct(sc['weekly_burn_pct_used'])} used) |",
        f"| Monthly burn vs cap | {fmt_money(sc['monthly_burn_usd'])} / "
        f"{fmt_money(sc['monthly_budget_usd'])} ({fmt_pct(sc['monthly_burn_pct_used'])} used) |",
        f"| Avg cost per issue vs target | {fmt_money(sc['avg_cost_per_issue_usd'])} / "
        f"{fmt_money(sc['issue_target_usd'])} target |",
        f"| Pass rate | {fmt_rate(sc['pass_rate'])} |",
        f"| Cache hit (window) | {fmt_rate(sc['overall_cache_hit_rate'])} |",
        "",
        "## Top issues by spend",
        "",
        "| Issue | Runs | Spend | Flags |",
        "|---|---:|---:|---|",
    ]
    for row in report["top_issues_by_spend"][:15]:
        flags = ", ".join(row.get("flags") or []) or "—"
        lines.append(
            f"| #{row['issue']} | {row['run_count']} | "
            f"{fmt_money(row['total_cost_usd'])} | {flags} |"
        )
    lines.extend(["", "## By model", ""])
    lines.append("| Model | Runs | Total $ | Avg $/run | Cache hit |")
    lines.append("|---|---:|---:|---:|---:|")
    for row in report["by_model"]:
        lines.append(
            f"| {row['model']} | {row['run_count']} | {fmt_money(row['total_cost_usd'])} | "
            f"{fmt_money(row['avg_cost_per_run_usd'])} | {fmt_rate(row['cache_hit_rate'])} |"
        )
    lines.extend(["", "## By harness", ""])
    lines.append("| Harness | Runs | Total $ | Avg $/run | Cache hit |")
    lines.append("|---|---:|---:|---:|---:|")
    for row in report["by_harness"]:
        lines.append(
            f"| {row['harness']} | {row['run_count']} | {fmt_money(row['total_cost_usd'])} | "
            f"{fmt_money(row['avg_cost_per_run_usd'])} | {fmt_rate(row['cache_hit_rate'])} |"
        )
    lines.extend(["", "## By provider", ""])
    lines.append("| Provider | Runs | Total $ | Avg $/run | Cache hit |")
    lines.append("|---|---:|---:|---:|---:|")
    for row in report["by_provider"]:
        lines.append(
            f"| {row['provider']} | {row['run_count']} | {fmt_money(row['total_cost_usd'])} | "
            f"{fmt_money(row['avg_cost_per_run_usd'])} | {fmt_rate(row['cache_hit_rate'])} |"
        )

    rr = report["review_readiness"]
    lines.extend(
        [
            "",
            "## Review readiness",
            "",
            f"- Cost trend (month over month): **{rr['cost_trend']}**",
            f"- Failures / non-pass in window: **{rr['failure_count']}**",
            f"- Cost overruns flagged: **{rr['overrun_count']}**",
            "",
            "### Recommendations",
            "",
        ]
    )
    for rec in rr["recommendations"]:
        lines.append(f"- {rec}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--runs-dir",
        type=Path,
        default=DEFAULT_RUNS,
        help="Directory of factory run JSON files (default: factory/runs)",
    )
    parser.add_argument(
        "--models-file",
        type=Path,
        default=DEFAULT_MODELS,
        help="Path to .factory/models.yaml (default: .factory/models.yaml)",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=30,
        help="Reporting window length in days (default: 30; use 7 for weekly)",
    )
    parser.add_argument(
        "--as-of",
        default=None,
        help="Pin report end date for tests (YYYY-MM-DD in --tz)",
    )
    parser.add_argument(
        "--tz",
        default="America/Chicago",
        help="IANA timezone for calendar week/month bounds (default: America/Chicago)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print JSON report on stdout",
    )
    args = parser.parse_args()

    if args.days < 1:
        die("--days must be >= 1")

    try:
        tz = ZoneInfo(args.tz)
    except Exception as exc:  # noqa: BLE001 — stdlib ZoneInfo
        die(f"invalid --tz: {exc}")

    if args.as_of:
        try:
            as_of_local = parse_as_of(args.as_of, tz)
        except ValueError as exc:
            die(f"invalid --as-of: {exc}")
    else:
        now_local = datetime.now(tz)
        as_of_local = datetime.combine(
            now_local.date(), time(23, 59, 59, 999999), tzinfo=tz
        )

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if args.as_of:
        generated_at = (
            as_of_local.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        )

    try:
        models = load_models(args.models_file.resolve())
        all_runs = load_runs(args.runs_dir.resolve())
        report = build_report(
            all_runs,
            args.models_file.resolve(),
            models,
            args.runs_dir.resolve(),
            args.days,
            as_of_local,
            args.tz,
            generated_at,
        )
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 — last-resort guard for callers
        die(f"unexpected error: {exc}")

    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(format_markdown(report))

    return 0


if __name__ == "__main__":
    sys.exit(main())