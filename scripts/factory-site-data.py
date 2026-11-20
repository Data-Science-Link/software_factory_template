#!/usr/bin/env python3
"""Export the marts the site needs to site-data/marts/<model>.json, deterministically.

Reads one JSON file per exported model from a source directory (a dbt output
directory, or the committed fixtures under tests/site-data/sample-marts/ when dbt
is skipped) and writes them to the output directory sorted deterministically, so
two runs produce byte-identical output. With ``--runs-dir``, synthesizes marts
from run-record JSON offline (no dbt) using budget defaults when ``--budget`` is
missing. Also exports a whitelisted column subset of ``fct_agent_runs`` so no
internal or sensitive columns reach the site.
"""
from __future__ import annotations

import argparse
import calendar
import json
import math
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover
    yaml = None  # type: ignore

# Marts exported to their own JSON file, in a stable order.
EXPORTED_MODELS = (
    "rpt_run_rate",
    "agg_spend_weekly",
    "agg_spend_monthly",
    "agg_spend_by_issue",
    "agg_spend_by_model",
    "fct_forecast_vs_actual",
    "rpt_issue_target_compliance",
)

# Optional CFO marts: exported when present in --source, else derived from fct_agent_runs.
OPTIONAL_DERIVED_MARTS = (
    "mart_spend_by_work_type",
)

DEFAULT_BUDGET = {
    "monthly_usd": 10.0,
    "weekly_usd": 2.5,
    "issue_target_usd": 0.15,
    "issue_cap_usd": 1.0,
    "fixed_costs_monthly_usd": 20.0,
    "actions_minutes_month": 2000,
    "warn_pct": 80,
}

# Whitelisted fct_agent_runs columns for the site export.
AGENT_RUNS_COLUMNS = (
    "run_id",
    "issue",
    "pr",
    "harness",
    "provider",
    "model_id",
    "complexity",
    "risk",
    "work_type",
    "outcome",
    "gate_passed",
    "started_at_utc",
    "run_date",
    "requests",
    "tokens_in",
    "tokens_cached",
    "tokens_out",
    "tokens_reasoning",
    "predicted_cost_usd",
    "actual_cost_usd",
    "cost_variance_usd",
    "cache_hit_rate",
    "duration_s",
    "actions_minutes",
)


def safe_float(value: Any, default: float = 0.0) -> float:
    if isinstance(value, bool) or value is None:
        return default
    if isinstance(value, (int, float)):
        fv = float(value)
        if not math.isfinite(fv):
            return default
        return fv
    try:
        fv = float(value)
    except (TypeError, ValueError):
        return default
    if not math.isfinite(fv):
        return default
    return fv


def safe_int(value: Any, default: int = 0) -> int:
    if isinstance(value, bool) or value is None:
        return default
    if isinstance(value, int):
        return value
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def safe_bool(value: Any, default: bool = False) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        low = value.strip().lower()
        if low in ("true", "1", "yes"):
            return True
        if low in ("false", "0", "no"):
            return False
    return default


def load_json(path: Path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def sort_value(obj):
    """Return a sort key that is stable for arbitrary JSON values."""
    if isinstance(obj, list):
        return [sort_value(x) for x in obj]
    if isinstance(obj, dict):
        return {k: sort_value(v) for k, v in sorted(obj.items())}
    return obj


def normalize_rows(data):
    """Return a deterministic list of dict rows from JSON data."""
    if isinstance(data, list):
        rows = data
    elif isinstance(data, dict) and "rows" in data:
        rows = data["rows"]
    elif isinstance(data, dict):
        rows = [data]
    else:
        return []
    return [sort_value(r) for r in rows]


def whitelist_agent_runs(rows):
    out = []
    for row in rows:
        out.append({k: sort_value(row.get(k)) for k in AGENT_RUNS_COLUMNS if k in row})
    return out


def _normalize_work_type(raw):
    if raw is None:
        return "unknown"
    text = str(raw).strip().lower()
    return text if text else "unknown"


def compute_mart_spend_by_work_type(agent_rows):
    """Mirror mart_spend_by_work_type.sql for site export when dbt JSON is absent."""
    groups = {}
    for row in agent_rows:
        if not isinstance(row, dict):
            continue
        wt = _normalize_work_type(row.get("work_type"))
        bucket = groups.setdefault(
            wt,
            {
                "run_count": 0,
                "pass_count": 0,
                "total_actual_cost_usd": 0.0,
                "total_tokens_in": 0,
                "total_tokens_cached": 0,
                "total_tokens_out": 0,
                "total_actions_minutes": 0,
            },
        )
        bucket["run_count"] += 1
        if row.get("gate_passed"):
            bucket["pass_count"] += 1
        bucket["total_actual_cost_usd"] += safe_float(row.get("actual_cost_usd"))
        bucket["total_tokens_in"] += safe_int(row.get("tokens_in"))
        bucket["total_tokens_cached"] += safe_int(row.get("tokens_cached"))
        bucket["total_tokens_out"] += safe_int(row.get("tokens_out"))
        bucket["total_actions_minutes"] += safe_int(row.get("actions_minutes"))

    spend_total = sum(g["total_actual_cost_usd"] for g in groups.values())
    out = []
    for work_type, g in groups.items():
        run_count = g["run_count"]
        pass_rate_pct = (
            round(g["pass_count"] / run_count * 100.0, 6) if run_count else None
        )
        avg_cost_usd = (
            g["total_actual_cost_usd"] / run_count if run_count else None
        )
        if spend_total > 0:
            cost_share_pct = round(
                g["total_actual_cost_usd"] / spend_total * 100.0, 6
            )
        else:
            cost_share_pct = 0.0
        out.append(
            sort_value(
                {
                    "work_type": work_type,
                    "run_count": run_count,
                    "pass_count": g["pass_count"],
                    "pass_rate_pct": pass_rate_pct,
                    "total_actual_cost_usd": g["total_actual_cost_usd"],
                    "avg_cost_usd": avg_cost_usd,
                    "cost_share_pct": cost_share_pct,
                    "total_tokens_in": g["total_tokens_in"],
                    "total_tokens_cached": g["total_tokens_cached"],
                    "total_tokens_out": g["total_tokens_out"],
                    "total_actions_minutes": g["total_actions_minutes"],
                }
            )
        )

    out.sort(
        key=lambda r: (
            -float(r.get("total_actual_cost_usd") or 0),
            -int(r.get("run_count") or 0),
            str(r.get("work_type", "")),
        )
    )
    return out


def _write_mart_payload(out: Path, model: str, rows) -> None:
    payload = {"model": model, "rows": rows}
    with open(out / f"{model}.json", "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
        fh.write("\n")


def parse_as_of_date(raw: str | None) -> date:
    if raw:
        try:
            return date.fromisoformat(raw[:10])
        except ValueError:
            sys.stderr.write(
                f"WARNING: invalid --as-of-date {raw!r}; using UTC today\n"
            )
    return datetime.now(timezone.utc).date()


def load_budget_soft(path: Path) -> dict[str, float]:
    """Load budget YAML or return defaults with a stderr note (never traceback)."""
    budget = dict(DEFAULT_BUDGET)
    if not path.is_file():
        sys.stderr.write(
            f"WARNING: budget file not found ({path}); using built-in defaults\n"
        )
        return budget
    if yaml is None:
        sys.stderr.write(
            "WARNING: PyYAML not available; using built-in budget defaults\n"
        )
        return budget
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        sys.stderr.write(
            f"WARNING: could not read budget file {path}: {exc}; using defaults\n"
        )
        return budget
    if not isinstance(data, dict):
        sys.stderr.write(
            f"WARNING: budget file must be a mapping; using defaults\n"
        )
        return budget
    for key, default in DEFAULT_BUDGET.items():
        if key in data:
            budget[key] = safe_float(data[key], default)
    return budget


def warn_models_file(path: Path) -> None:
    if not path.is_file():
        sys.stderr.write(
            f"WARNING: models file not found ({path}); continuing without model catalog\n"
        )
        return
    if yaml is None:
        sys.stderr.write(
            f"WARNING: PyYAML not available; skipping models file {path}\n"
        )


def load_runs_dir(runs_dir: Path) -> tuple[list[dict[str, Any]], int]:
    """Load run JSON files; return (records, skipped_count)."""
    if not runs_dir.is_dir():
        sys.stderr.write(
            f"WARNING: runs directory not found ({runs_dir}); treating as empty\n"
        )
        return [], 0
    records: list[dict[str, Any]] = []
    skipped = 0
    for path in sorted(runs_dir.glob("*.json")):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            sys.stderr.write(f"WARNING: skip {path.name}: {exc}\n")
            skipped += 1
            continue
        try:
            data = json.loads(text)
        except json.JSONDecodeError as exc:
            sys.stderr.write(f"WARNING: skip {path.name}: invalid JSON ({exc})\n")
            skipped += 1
            continue
        if not isinstance(data, dict):
            sys.stderr.write(f"WARNING: skip {path.name}: expected JSON object\n")
            skipped += 1
            continue
        records.append(data)
    return records, skipped


def parse_started_at_utc(raw: Any) -> datetime | None:
    if not raw or not isinstance(raw, str):
        return None
    text = raw.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def normalize_run_record(record: dict[str, Any]) -> dict[str, Any] | None:
    run_id = record.get("run_id")
    if not run_id:
        return None
    started = record.get("started_at") or record.get("started_at_utc")
    started_dt = parse_started_at_utc(started)
    if started_dt is None:
        started_utc = str(started) if started else ""
        run_date = started_utc[:10] if started_utc else ""
    else:
        started_utc = started_dt.replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")
        run_date = started_dt.date().isoformat()

    tin = safe_int(record.get("tokens_in"))
    tcached = safe_int(record.get("tokens_cached"))
    predicted = safe_float(record.get("predicted_cost_usd"))
    actual = safe_float(record.get("actual_cost_usd"))
    model_raw = record.get("model_id") or record.get("model") or ""
    model_id = str(model_raw).lower() if model_raw else "unknown"

    row = {
        "run_id": str(run_id),
        "issue": safe_int(record.get("issue")),
        "pr": record.get("pr"),
        "harness": record.get("harness"),
        "provider": record.get("provider"),
        "model_id": model_id,
        "complexity": record.get("complexity"),
        "risk": record.get("risk"),
        "work_type": record.get("work_type"),
        "outcome": record.get("outcome"),
        "gate_passed": safe_bool(record.get("gate_passed")),
        "started_at_utc": started_utc,
        "run_date": run_date,
        "requests": safe_int(record.get("requests")),
        "tokens_in": tin,
        "tokens_cached": tcached,
        "tokens_out": safe_int(record.get("tokens_out")),
        "tokens_reasoning": safe_int(record.get("tokens_reasoning")),
        "predicted_cost_usd": predicted,
        "actual_cost_usd": actual,
        "cost_variance_usd": round(actual - predicted, 6),
        "cache_hit_rate": round(tcached / tin, 6) if tin else 0.0,
        "duration_s": safe_int(record.get("duration_s")),
        "actions_minutes": safe_int(record.get("actions_minutes")),
        "cost_method": record.get("cost_method") or "not_measured",
    }
    return sort_value(row)


def agent_rows_from_runs(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for rec in records:
        norm = normalize_run_record(rec)
        if norm:
            rows.append(norm)
    rows.sort(key=lambda r: (r.get("started_at_utc", ""), r.get("run_id", "")))
    return whitelist_agent_runs(rows)


def week_start_monday(d: date) -> date:
    return d - timedelta(days=d.weekday())


def month_starts(ending: date, count: int) -> list[date]:
    y, m = ending.year, ending.month
    months: list[date] = []
    for _ in range(count):
        months.append(date(y, m, 1))
        m -= 1
        if m == 0:
            m = 12
            y -= 1
    return list(reversed(months))


def iso_week_parts(d: date) -> tuple[int, int]:
    iso = d.isocalendar()
    return iso.year, iso.week


def _median(values: list[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2.0


def build_rpt_run_rate(agent_rows: list[dict], budget: dict[str, float], as_of: date):
    month_start = date(as_of.year, as_of.month, 1)
    days_elapsed = as_of.day
    days_in_month = calendar.monthrange(as_of.year, as_of.month)[1]
    mtd_spend = 0.0
    trailing_7 = 0.0
    trailing_30 = 0.0
    actions_mtd = 0
    d7 = as_of - timedelta(days=7)
    d30 = as_of - timedelta(days=30)
    for row in agent_rows:
        rd = row.get("run_date") or ""
        if not rd:
            continue
        try:
            run_d = date.fromisoformat(rd[:10])
        except ValueError:
            continue
        cost = safe_float(row.get("actual_cost_usd"))
        if month_start <= run_d <= as_of:
            mtd_spend += cost
            actions_mtd += safe_int(row.get("actions_minutes"))
        if d7 < run_d <= as_of:
            trailing_7 += cost
        if d30 < run_d <= as_of:
            trailing_30 += cost
    trailing_7d = trailing_7 / 7.0
    trailing_30d = trailing_30 / 30.0
    monthly_budget = budget["monthly_usd"]
    projected_var = (
        mtd_spend / days_elapsed * days_in_month if days_elapsed else 0.0
    )
    fixed = budget["fixed_costs_monthly_usd"]
    quota = budget["actions_minutes_month"]
    budget_used = mtd_spend / monthly_budget * 100 if monthly_budget else 0.0
    actions_pct = actions_mtd / quota * 100 if quota else 0.0
    return [
        sort_value(
            {
                "as_of_date": as_of.isoformat(),
                "month_start": month_start.isoformat(),
                "days_elapsed": days_elapsed,
                "days_in_month": days_in_month,
                "mtd_variable_usd": round(mtd_spend, 6),
                "trailing_7d_usd_per_day": round(trailing_7d, 6),
                "trailing_30d_usd_per_day": round(trailing_30d, 6),
                "projected_month_end_variable_usd": round(projected_var, 6),
                "fixed_costs_month_usd": fixed,
                "total_mtd_usd": round(mtd_spend + fixed, 6),
                "projected_month_end_total_usd": round(projected_var + fixed, 6),
                "deepinfra_budget_usd": monthly_budget,
                "budget_used_pct": round(budget_used, 6),
                "actions_minutes_mtd": actions_mtd,
                "actions_minutes_quota": quota,
                "actions_minutes_used_pct": round(actions_pct, 6),
            }
        )
    ]


def build_agg_spend_weekly(agent_rows: list[dict], budget: dict[str, float], as_of: date):
    weekly_budget = budget["weekly_usd"]
    start = week_start_monday(date(as_of.year, as_of.month, 1))
    weeks: list[date] = []
    cur = start
    while cur <= as_of:
        weeks.append(cur)
        cur += timedelta(days=7)
    spend_by_week: dict[date, dict[str, Any]] = {}
    for row in agent_rows:
        rd = row.get("run_date") or ""
        try:
            run_d = date.fromisoformat(rd[:10])
        except ValueError:
            continue
        if run_d < start or run_d > as_of:
            continue
        wk = week_start_monday(run_d)
        bucket = spend_by_week.setdefault(
            wk, {"runs": 0, "issues": set(), "spend_usd": 0.0}
        )
        bucket["runs"] += 1
        bucket["issues"].add(row.get("issue"))
        bucket["spend_usd"] += safe_float(row.get("actual_cost_usd"))
    rows = []
    for wk in weeks:
        bucket = spend_by_week.get(wk, {"runs": 0, "issues": set(), "spend_usd": 0.0})
        spend = round(bucket["spend_usd"], 6)
        iso_y, iso_w = iso_week_parts(wk)
        used_pct = spend / weekly_budget * 100 if weekly_budget else 0.0
        rows.append(
            sort_value(
                {
                    "week_start_utc": wk.isoformat(),
                    "week_end_utc": (wk + timedelta(days=6)).isoformat(),
                    "iso_year": iso_y,
                    "iso_week": iso_w,
                    "runs": bucket["runs"],
                    "issues": len(bucket["issues"]),
                    "spend_usd": spend,
                    "budget_usd": weekly_budget,
                    "budget_used_pct": round(used_pct, 6),
                    "over_budget": spend > weekly_budget,
                }
            )
        )
    return rows


def build_agg_spend_monthly(agent_rows: list[dict], budget: dict[str, float], as_of: date):
    monthly_budget = budget["monthly_usd"]
    months = month_starts(date(as_of.year, as_of.month, 1), 3)
    earliest = months[0]
    spend_by_month: dict[date, dict[str, Any]] = {}
    for row in agent_rows:
        rd = row.get("run_date") or ""
        try:
            run_d = date.fromisoformat(rd[:10])
        except ValueError:
            continue
        if run_d < earliest or run_d > as_of:
            continue
        ms = date(run_d.year, run_d.month, 1)
        bucket = spend_by_month.setdefault(
            ms, {"runs": 0, "issues": set(), "spend_usd": 0.0}
        )
        bucket["runs"] += 1
        bucket["issues"].add(row.get("issue"))
        bucket["spend_usd"] += safe_float(row.get("actual_cost_usd"))
    rows = []
    for ms in months:
        bucket = spend_by_month.get(ms, {"runs": 0, "issues": set(), "spend_usd": 0.0})
        spend = round(bucket["spend_usd"], 6)
        used_pct = spend / monthly_budget * 100 if monthly_budget else 0.0
        rows.append(
            sort_value(
                {
                    "month_start_utc": ms.isoformat(),
                    "runs": bucket["runs"],
                    "issues": len(bucket["issues"]),
                    "spend_usd": spend,
                    "budget_usd": monthly_budget,
                    "budget_used_pct": round(used_pct, 6),
                    "over_budget": spend > monthly_budget,
                }
            )
        )
    return rows


def build_agg_spend_by_issue(agent_rows: list[dict], budget: dict[str, float]):
    cap = budget["issue_cap_usd"]
    groups: dict[int, dict[str, Any]] = {}
    for row in agent_rows:
        issue = safe_int(row.get("issue"))
        g = groups.setdefault(
            issue,
            {
                "runs": 0,
                "spend_usd": 0.0,
                "predicted_usd": 0.0,
                "last_outcome": None,
                "last_started": "",
            },
        )
        g["runs"] += 1
        g["spend_usd"] += safe_float(row.get("actual_cost_usd"))
        g["predicted_usd"] += safe_float(row.get("predicted_cost_usd"))
        started = str(row.get("started_at_utc") or "")
        if started >= g["last_started"]:
            g["last_started"] = started
            g["last_outcome"] = row.get("outcome")
    rows = []
    for issue in sorted(groups):
        g = groups[issue]
        spend = round(g["spend_usd"], 6)
        pred = round(g["predicted_usd"], 6)
        rows.append(
            sort_value(
                {
                    "issue": issue,
                    "runs": g["runs"],
                    "spend_usd": spend,
                    "cap_headroom_usd": round(cap - spend, 6),
                    "predicted_usd": pred,
                    "variance_usd": round(spend - pred, 6),
                    "last_outcome": g["last_outcome"],
                    "last_run_at_utc": g["last_started"] or None,
                }
            )
        )
    return rows


def build_agg_spend_by_model(agent_rows: list[dict]):
    groups: dict[str, dict[str, Any]] = {}
    for row in agent_rows:
        mid = str(row.get("model_id") or "unknown")
        g = groups.setdefault(
            mid,
            {
                "runs": 0,
                "tokens_in": 0,
                "tokens_cached": 0,
                "tokens_out": 0,
                "spend_usd": 0.0,
                "passes": 0,
            },
        )
        g["runs"] += 1
        g["tokens_in"] += safe_int(row.get("tokens_in"))
        g["tokens_cached"] += safe_int(row.get("tokens_cached"))
        g["tokens_out"] += safe_int(row.get("tokens_out"))
        g["spend_usd"] += safe_float(row.get("actual_cost_usd"))
        if row.get("gate_passed"):
            g["passes"] += 1
    rows = []
    for mid in sorted(groups):
        g = groups[mid]
        tin = g["tokens_in"]
        cache_rate = g["tokens_cached"] / tin if tin else None
        pass_rate = g["passes"] / g["runs"] if g["runs"] else 0.0
        rows.append(
            sort_value(
                {
                    "model_id": mid,
                    "runs": g["runs"],
                    "tokens_in": tin,
                    "tokens_cached": g["tokens_cached"],
                    "tokens_out": g["tokens_out"],
                    "spend_usd": round(g["spend_usd"], 6),
                    "cache_hit_rate": round(cache_rate, 6) if cache_rate is not None else None,
                    "gate_pass_rate": round(pass_rate, 6),
                }
            )
        )
    return rows


def build_fct_forecast_vs_actual(agent_rows: list[dict]):
    measured = [
        r for r in agent_rows if str(r.get("cost_method") or "") != "not_measured"
    ]

    def aggregate(grain: str, key_fn):
        buckets: dict[str, dict[str, Any]] = {}
        for row in measured:
            key = key_fn(row)
            b = buckets.setdefault(
                str(key),
                {
                    "runs": 0,
                    "predicted_usd": 0.0,
                    "actual_usd": 0.0,
                    "tin": [],
                    "tcached": [],
                    "tout": [],
                },
            )
            b["runs"] += 1
            b["predicted_usd"] += safe_float(row.get("predicted_cost_usd"))
            b["actual_usd"] += safe_float(row.get("actual_cost_usd"))
            b["tin"].append(float(safe_int(row.get("tokens_in"))))
            b["tcached"].append(float(safe_int(row.get("tokens_cached"))))
            b["tout"].append(float(safe_int(row.get("tokens_out"))))
        rows = []
        for key in sorted(buckets):
            b = buckets[key]
            pred = round(b["predicted_usd"], 6)
            actual = round(b["actual_usd"], 6)
            err_pct = (actual - pred) / pred * 100 if pred > 0 else None
            rows.append(
                sort_value(
                    {
                        "grain": grain,
                        "grain_key": key,
                        "runs": b["runs"],
                        "predicted_usd": pred,
                        "actual_usd": actual,
                        "median_tokens_in": _median(b["tin"]),
                        "median_tokens_cached": _median(b["tcached"]),
                        "median_tokens_out": _median(b["tout"]),
                        "error_pct": round(err_pct, 6) if err_pct is not None else None,
                    }
                )
            )
        return rows

    by_issue = aggregate("issue", lambda r: str(safe_int(r.get("issue"))))
    by_complexity = aggregate(
        "complexity", lambda r: str(r.get("complexity") or "unknown")
    )
    return by_issue + by_complexity


def build_rpt_issue_target_compliance(agent_rows: list[dict], budget: dict[str, float]):
    target = budget["issue_target_usd"]
    cap = budget["issue_cap_usd"]
    groups: dict[int, dict[str, Any]] = {}
    for row in agent_rows:
        issue = safe_int(row.get("issue"))
        g = groups.setdefault(issue, {"runs": 0, "spend_usd": 0.0})
        g["runs"] += 1
        g["spend_usd"] += safe_float(row.get("actual_cost_usd"))
    rows = []
    for issue in sorted(groups):
        spend = round(groups[issue]["spend_usd"], 6)
        rows.append(
            sort_value(
                {
                    "issue": issue,
                    "runs": groups[issue]["runs"],
                    "spend_usd": spend,
                    "issue_target_usd": target,
                    "issue_cap_usd": cap,
                    "under_target": spend <= target,
                    "under_cap": spend <= cap,
                }
            )
        )
    if not rows:
        summary_spend = 0.0
        summary_runs = 0
    else:
        summary_spend = round(sum(r["spend_usd"] for r in rows), 6)
        summary_runs = sum(r["runs"] for r in rows)
    rows.append(
        sort_value(
            {
                "issue": None,
                "runs": summary_runs,
                "spend_usd": summary_spend,
                "issue_target_usd": target,
                "issue_cap_usd": cap,
                "under_target": all(r["under_target"] for r in rows) if rows else True,
                "under_cap": all(r["under_cap"] for r in rows) if rows else True,
            }
        )
    )
    return rows


def synthesize_marts_from_runs(
    runs_dir: Path,
    out: Path,
    budget_path: Path,
    models_path: Path | None,
    as_of: date,
) -> int:
    """Build all site marts under ``out`` from run records. Returns skipped file count."""
    budget = load_budget_soft(budget_path)
    if models_path is not None:
        warn_models_file(models_path)
    records, skipped = load_runs_dir(runs_dir)
    agent_rows = agent_rows_from_runs(records)
    out.mkdir(parents=True, exist_ok=True)

    builders = {
        "rpt_run_rate": lambda: build_rpt_run_rate(agent_rows, budget, as_of),
        "agg_spend_weekly": lambda: build_agg_spend_weekly(agent_rows, budget, as_of),
        "agg_spend_monthly": lambda: build_agg_spend_monthly(agent_rows, budget, as_of),
        "agg_spend_by_issue": lambda: build_agg_spend_by_issue(agent_rows, budget),
        "agg_spend_by_model": lambda: build_agg_spend_by_model(agent_rows),
        "fct_forecast_vs_actual": lambda: build_fct_forecast_vs_actual(agent_rows),
        "rpt_issue_target_compliance": lambda: build_rpt_issue_target_compliance(
            agent_rows, budget
        ),
    }
    for model in EXPORTED_MODELS:
        rows = builders[model]()
        rows = [sort_value(r) for r in rows]
        rows.sort(key=lambda r: json.dumps(r, sort_keys=True))
        _write_mart_payload(out, model, rows)

    agent_rows.sort(key=lambda r: json.dumps(r, sort_keys=True))
    _write_mart_payload(out, "fct_agent_runs", agent_rows)

    for model in OPTIONAL_DERIVED_MARTS:
        if model == "mart_spend_by_work_type":
            rows = compute_mart_spend_by_work_type(agent_rows)
        else:
            rows = []
        rows = [sort_value(r) for r in rows]
        rows.sort(key=lambda r: json.dumps(r, sort_keys=True))
        _write_mart_payload(out, model, rows)

    if skipped:
        sys.stderr.write(
            f"WARNING: skipped {skipped} unreadable or malformed run file(s)\n"
        )
    print(
        f"Synthesized {len(EXPORTED_MODELS)} marts from {len(agent_rows)} run(s) in {runs_dir} -> {out}"
    )
    return skipped


def export_from_source(source: Path, out: Path) -> None:
    """Normalize mart JSON from an existing source directory."""
    out.mkdir(parents=True, exist_ok=True)

    for model in EXPORTED_MODELS:
        src = source / f"{model}.json"
        if not src.is_file():
            sys.stderr.write(f"ERROR: missing model file for export: {src}\n")
            sys.exit(1)
        rows = normalize_rows(load_json(src))
        rows.sort(key=lambda r: json.dumps(r, sort_keys=True))
        _write_mart_payload(out, model, rows)

    agent_src = source / "fct_agent_runs.json"
    agent_rows = []
    if agent_src.is_file():
        agent_rows = whitelist_agent_runs(normalize_rows(load_json(agent_src)))
        agent_rows.sort(key=lambda r: json.dumps(r, sort_keys=True))
        _write_mart_payload(out, "fct_agent_runs", agent_rows)

    for model in OPTIONAL_DERIVED_MARTS:
        src = source / f"{model}.json"
        if src.is_file():
            rows = normalize_rows(load_json(src))
        elif model == "mart_spend_by_work_type":
            rows = compute_mart_spend_by_work_type(agent_rows)
        else:
            rows = []
        rows = [sort_value(r) for r in rows]
        rows.sort(key=lambda r: json.dumps(r, sort_keys=True))
        _write_mart_payload(out, model, rows)

    print(f"Exported {len(EXPORTED_MODELS)} marts to {out}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source",
        default="tests/site-data/sample-marts",
        help="Directory containing one JSON file per exported model.",
    )
    parser.add_argument(
        "--out",
        default="site-data/marts",
        help="Output directory for the exported JSON files.",
    )
    parser.add_argument(
        "--runs-dir",
        type=Path,
        default=None,
        help="Synthesize marts from run JSON files (offline; ignores missing dbt export).",
    )
    parser.add_argument(
        "--budget",
        type=Path,
        default=Path("factory/budget.yml"),
        help="Budget YAML for --runs-dir synthesis (defaults when missing).",
    )
    parser.add_argument(
        "--models",
        type=Path,
        default=Path(".factory/models.yaml"),
        help="Optional models catalog path (--runs-dir warns and continues if missing).",
    )
    parser.add_argument(
        "--as-of-date",
        default=None,
        help="Pinned UTC calendar date (YYYY-MM-DD) for deterministic mart windows.",
    )
    args = parser.parse_args()

    out = Path(args.out)
    if args.runs_dir is not None:
        as_of = parse_as_of_date(args.as_of_date)
        synthesize_marts_from_runs(
            args.runs_dir.resolve(),
            out,
            args.budget,
            args.models,
            as_of,
        )
        return

    export_from_source(Path(args.source), out)


if __name__ == "__main__":
    main()