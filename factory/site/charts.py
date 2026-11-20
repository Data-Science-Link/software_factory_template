#!/usr/bin/env python3
"""Generate inline SVG charts for the Financials tab with no JS and no chart library."""

import datetime
import html


def esc(value):
    """Escape text for HTML."""
    return html.escape(str(value), quote=True)


def _parse_as_of(as_of_date):
    if isinstance(as_of_date, datetime.datetime):
        return as_of_date.date()
    if isinstance(as_of_date, datetime.date):
        return as_of_date
    if isinstance(as_of_date, str) and as_of_date.strip():
        try:
            return datetime.date.fromisoformat(as_of_date[:10])
        except ValueError:
            pass
    return datetime.date(2026, 11, 11)


def last_n_iso_weeks(as_of_date, n=12):
    """Return (iso_year, iso_week) for the last n ISO weeks ending at as_of's week."""
    as_of = _parse_as_of(as_of_date)
    y, w, _ = as_of.isocalendar()
    anchor = datetime.datetime.fromisocalendar(y, w, 1).date()
    weeks = []
    d = anchor
    for _ in range(n):
        iso_y, iso_w, _ = d.isocalendar()
        weeks.append((iso_y, iso_w))
        d -= datetime.timedelta(days=7)
    weeks.reverse()
    return weeks


def last_n_months(as_of_date, n=6):
    """Return YYYY-MM strings for the last n calendar months ending at as_of."""
    as_of = _parse_as_of(as_of_date)
    y, m = as_of.year, as_of.month
    months = []
    for _ in range(n):
        months.append(f"{y:04d}-{m:02d}")
        m -= 1
        if m == 0:
            m = 12
            y -= 1
    months.reverse()
    return months


def normalize_weekly_series(weekly_data, as_of_date, n=12):
    """Merge raw weekly mart rows into n ISO weeks (stable order, zero-filled)."""
    spend_by_week = {}
    for item in weekly_data:
        if not isinstance(item, dict):
            continue
        try:
            key = (int(item["iso_year"]), int(item["iso_week"]))
        except (KeyError, TypeError, ValueError):
            continue
        spend = float(item.get("spend_usd", 0) or 0)
        spend_by_week[key] = spend_by_week.get(key, 0.0) + spend

    series = []
    for iso_y, iso_w in last_n_iso_weeks(as_of_date, n):
        label = f"{iso_y}-W{iso_w:02d}"
        spend = spend_by_week.get((iso_y, iso_w), 0.0)
        series.append({"label": label, "spend_usd": spend, "iso_year": iso_y, "iso_week": iso_w})
    return series


def normalize_monthly_series(monthly_data, as_of_date, n=6):
    """Merge raw monthly mart rows into n calendar months (stable order, zero-filled)."""
    spend_by_month = {}
    for item in monthly_data:
        if not isinstance(item, dict):
            continue
        month_start = item.get("month_start_utc") or item.get("month_start") or ""
        if len(month_start) < 7:
            continue
        key = month_start[:7]
        spend = float(item.get("spend_usd", 0) or 0)
        spend_by_month[key] = spend_by_month.get(key, 0.0) + spend

    series = []
    for month_key in last_n_months(as_of_date, n):
        spend = spend_by_month.get(month_key, 0.0)
        series.append({"label": month_key, "spend_usd": spend})
    return series


def _budget_label(budget_usd):
    if budget_usd <= 0:
        return "no budget set"
    return f"Budget: ${budget_usd:.2f}"


def svg_chart_weekly(weekly_data, weekly_budget_usd, as_of_date=None):
    """Generate an inline SVG bar chart of weekly spend vs budget (last 12 ISO weeks)."""
    if as_of_date is None:
        as_of_date = datetime.date(2026, 11, 11)

    series = normalize_weekly_series(weekly_data or [], as_of_date, n=12)
    if not series:
        return '<p>No weekly data available.</p>', '<p>No weekly data available.</p>'

    weeks = [row["label"] for row in series]
    spend_values = [row["spend_usd"] for row in series]
    budget_values = [weekly_budget_usd] * len(series)

    max_spend = max(spend_values) if spend_values else 0
    max_budget = weekly_budget_usd if weekly_budget_usd > 0 else 0
    chart_max = max(max_spend, max_budget, 0.01)

    bar_width = 30
    bar_gap = 10
    chart_height = 200
    chart_width = len(weeks) * (bar_width + bar_gap) + bar_gap

    svg_parts = [
        f'<svg viewBox="0 0 {chart_width} {chart_height}" '
        f'width="{chart_width}" height="{chart_height}">',
        "<style>",
        ".bar { fill: #4CAF50; }",
        ".bar-over { fill: #F44336; }",
        ".budget-line { stroke: #2196F3; stroke-width: 2; stroke-dasharray: 4 2; }",
        ".axis-label { font-size: 10px; fill: #333; text-anchor: middle; }",
        ".budget-label { font-size: 10px; fill: #2196F3; text-anchor: start; }",
        "</style>",
    ]

    for i, (spend, budget, week_label) in enumerate(zip(spend_values, budget_values, weeks)):
        x = bar_gap + i * (bar_width + bar_gap)
        bar_height = (spend / chart_max) * (chart_height - 40)
        y = chart_height - 20 - bar_height
        bar_class = "bar-over" if weekly_budget_usd > 0 and spend > weekly_budget_usd else "bar"
        svg_parts.append(
            f'<rect x="{x}" y="{y}" width="{bar_width}" height="{bar_height}" '
            f'class="{bar_class}" />'
        )
        label_y = chart_height - 5
        svg_parts.append(
            f'<text x="{x + bar_width/2}" y="{label_y}" class="axis-label">{esc(week_label)}</text>'
        )

    if weekly_budget_usd > 0:
        budget_y = chart_height - 20 - (weekly_budget_usd / chart_max) * (chart_height - 40)
        svg_parts.append(
            f'<line x1="{bar_gap}" y1="{budget_y}" x2="{chart_width - bar_gap}" y2="{budget_y}" '
            f'class="budget-line" />'
        )
        svg_parts.append(
            f'<text x="{chart_width - bar_gap}" y="{budget_y - 5}" class="budget-label">'
            f"{esc(_budget_label(weekly_budget_usd))}</text>"
        )

    svg_parts.append("</svg>")

    table_parts = [
        "<table><thead><tr><th>Week</th><th>Spend</th><th>Budget</th><th>Status</th>"
        "</tr></thead><tbody>"
    ]
    budget_cell = "no budget set" if weekly_budget_usd <= 0 else f"${weekly_budget_usd:.2f}"
    for spend, week_label in zip(spend_values, weeks):
        if weekly_budget_usd <= 0:
            status = "—"
        else:
            status = "Over" if spend > weekly_budget_usd else "Under"
        table_parts.append(
            f"<tr><td>{esc(week_label)}</td><td>${spend:.4f}</td>"
            f"<td>{esc(budget_cell)}</td><td>{status}</td></tr>"
        )
    table_parts.append("</tbody></table>")

    return "\n".join(svg_parts), "\n".join(table_parts)


def svg_chart_monthly(monthly_data, monthly_budget_usd, as_of_date=None):
    """Generate an inline SVG bar chart of monthly spend vs budget (last 6 months)."""
    if as_of_date is None:
        as_of_date = datetime.date(2026, 11, 11)

    series = normalize_monthly_series(monthly_data or [], as_of_date, n=6)
    if not series:
        return '<p>No monthly data available.</p>', '<p>No monthly data available.</p>'

    months = [row["label"] for row in series]
    spend_values = [row["spend_usd"] for row in series]
    budget_values = [monthly_budget_usd] * len(series)

    max_spend = max(spend_values) if spend_values else 0
    max_budget = monthly_budget_usd if monthly_budget_usd > 0 else 0
    chart_max = max(max_spend, max_budget, 0.01)

    bar_width = 40
    bar_gap = 15
    chart_height = 200
    chart_width = len(months) * (bar_width + bar_gap) + bar_gap

    svg_parts = [
        f'<svg viewBox="0 0 {chart_width} {chart_height}" '
        f'width="{chart_width}" height="{chart_height}">',
        "<style>",
        ".bar { fill: #4CAF50; }",
        ".bar-over { fill: #F44336; }",
        ".budget-line { stroke: #2196F3; stroke-width: 2; stroke-dasharray: 4 2; }",
        ".axis-label { font-size: 10px; fill: #333; text-anchor: middle; }",
        ".budget-label { font-size: 10px; fill: #2196F3; text-anchor: start; }",
        "</style>",
    ]

    for i, (spend, budget, month_label) in enumerate(zip(spend_values, budget_values, months)):
        x = bar_gap + i * (bar_width + bar_gap)
        bar_height = (spend / chart_max) * (chart_height - 40)
        y = chart_height - 20 - bar_height
        bar_class = "bar-over" if monthly_budget_usd > 0 and spend > monthly_budget_usd else "bar"
        svg_parts.append(
            f'<rect x="{x}" y="{y}" width="{bar_width}" height="{bar_height}" '
            f'class="{bar_class}" />'
        )
        label_y = chart_height - 5
        svg_parts.append(
            f'<text x="{x + bar_width/2}" y="{label_y}" class="axis-label">{esc(month_label)}</text>'
        )

    if monthly_budget_usd > 0:
        budget_y = chart_height - 20 - (monthly_budget_usd / chart_max) * (chart_height - 40)
        svg_parts.append(
            f'<line x1="{bar_gap}" y1="{budget_y}" x2="{chart_width - bar_gap}" y2="{budget_y}" '
            f'class="budget-line" />'
        )
        svg_parts.append(
            f'<text x="{chart_width - bar_gap}" y="{budget_y - 5}" class="budget-label">'
            f"{esc(_budget_label(monthly_budget_usd))}</text>"
        )

    svg_parts.append("</svg>")

    table_parts = [
        "<table><thead><tr><th>Month</th><th>Spend</th><th>Budget</th><th>Status</th>"
        "</tr></thead><tbody>"
    ]
    budget_cell = "no budget set" if monthly_budget_usd <= 0 else f"${monthly_budget_usd:.2f}"
    for spend, month_label in zip(spend_values, months):
        if monthly_budget_usd <= 0:
            status = "—"
        else:
            status = "Over" if spend > monthly_budget_usd else "Under"
        table_parts.append(
            f"<tr><td>{esc(month_label)}</td><td>${spend:.4f}</td>"
            f"<td>{esc(budget_cell)}</td><td>{status}</td></tr>"
        )
    table_parts.append("</tbody></table>")

    return "\n".join(svg_parts), "\n".join(table_parts)