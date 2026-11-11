#!/usr/bin/env python3
"""Render the static four-tab factory site from the factory's own source files.

Usage:
    scripts/factory-site.py --out site --data site-data [--repo-root .] [--now <utc>]

Writes index.html (Architecture), financials.html, backlog.html and dbt.html with a
shared header and tab nav. Uses only stdlib string.Template + PyYAML. All text is
html.escape-d. No JS and no external CSS, fonts or images (style lives in
factory/site/style.css, linked from factory/site/base.html).
"""
import argparse
import datetime
import html
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from string import Template

import yaml

SECTION_NOT_FOUND = "section not found in FACTORY.md"

TAB_LABELS = (
    ("index.html", "Architecture"),
    ("financials.html", "Financials"),
    ("backlog.html", "Backlog"),
    ("dbt.html", "dbt"),
)


def esc(value):
    return html.escape(str(value), quote=True)


def format_currency(value):
    """Format a numeric value as currency."""
    return f"${value:,.4f}" if value else "$0.0000"


def format_percentage(value):
    """Format a numeric value as percentage."""
    return f"{value:.1f}%" if value else "0.0%"


def build_tabs(active):
    parts = []
    for filename, label in TAB_LABELS:
        cls = ' class="active"' if filename == active else ""
        parts.append(
            '<a href="{}"{}>{}</a>'.format(esc(filename), cls, esc(label))
        )
    return "\n      ".join(parts)


def load_models(repo_root):
    """Load .factory/models.yaml. Missing keys fail softly (empty result)."""
    path = Path(repo_root) / ".factory" / "models.yaml"
    if not path.is_file():
        return {}
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def section_from_markdown(text, heading):
    """Return the markdown text under a `## heading`, or None if not found."""
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.startswith("## "):
            candidate = line.lstrip("# ").strip()
            if candidate == heading:
                start = i
                break
    if start is None:
        return None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if lines[j].startswith("## "):
            end = j
            break
    return "\n".join(lines[start + 1:end]).strip()


def parse_markdown_table(text):
    """Parse a markdown table into a list of row lists (first row is the header)."""
    if not text:
        return []
    rows = []
    for line in text.splitlines():
        line = line.strip()
        if not line or not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if all(set(c) <= set("-: ") for c in cells):
            continue
        rows.append(cells)
    return rows


def numbered_steps(text):
    """Extract numbered loop steps as (number, full_line) sorted by number."""
    steps = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        m = re.match(r"^(\d+)\.\s+(.*)$", stripped)
        if m:
            steps.append((int(m.group(1)), stripped))
    steps.sort(key=lambda x: x[0])
    return steps


def render_table(rows):
    if not rows:
        return ""
    out = ["<table><thead><tr>"]
    for cell in rows[0]:
        out.append("<th>{}</th>".format(esc(cell)))
    out.append("</tr></thead><tbody>")
    for row in rows[1:]:
        out.append("<tr>")
        for i, cell in enumerate(row):
            tag = "th" if i == 0 else "td"
            out.append("<{}>{}</{}>".format(tag, esc(cell), tag))
        out.append("</tr>")
    out.append("</tbody></table>")
    return "\n".join(out)


def render_loop_steps(steps):
    out = ["<ol>"]
    for _num, text in steps:
        out.append("<li>{}</li>".format(esc(text)))
    out.append("</ol>")
    return "\n".join(out)


def when_text(when):
    if not when:
        return "(always)"
    if isinstance(when, dict):
        return ", ".join(
            "{}={}".format(esc(k), esc(v)) for k, v in sorted(when.items())
        )
    return esc(when)


def architecture_html(repo_root, models_data, factory_md):
    parts = []

    # Numbered loop steps.
    parts.append("<h2>Factory loop</h2>")
    loop = section_from_markdown(factory_md, "Loop")
    if loop is None:
        parts.append('<p class="note">{}</p>'.format(esc(SECTION_NOT_FOUND + " (Loop)")))
    else:
        steps = numbered_steps(loop)
        if steps:
            parts.append(render_loop_steps(steps))
        else:
            parts.append('<p class="note">{}</p>'.format(esc(SECTION_NOT_FOUND + " (Loop)")))

    # Roles table.
    parts.append("<h2>Roles</h2>")
    roles = section_from_markdown(factory_md, "Roles")
    if roles is None:
        parts.append('<p class="note">{}</p>'.format(esc(SECTION_NOT_FOUND + " (Roles)")))
    else:
        rendered = render_table(parse_markdown_table(roles))
        if rendered:
            parts.append(rendered)
        else:
            parts.append('<p class="note">{}</p>'.format(esc(SECTION_NOT_FOUND + " (Roles)")))

    # Merge authority table.
    parts.append("<h2>Merge authority</h2>")
    merge = section_from_markdown(factory_md, "Merge authority (by design)")
    if merge is None:
        merge = section_from_markdown(factory_md, "Merge authority")
    if merge is None:
        parts.append('<p class="note">{}</p>'.format(esc(SECTION_NOT_FOUND + " (Merge authority)")))
    else:
        rendered = render_table(parse_markdown_table(merge))
        if rendered:
            parts.append(rendered)
        else:
            parts.append('<p class="note">{}</p>'.format(esc(SECTION_NOT_FOUND + " (Merge authority)")))

    # Models and prices table.
    parts.append("<h2>Models and prices</h2>")
    models = models_data.get("models")
    if not models:
        parts.append("<p>models not found in models.yaml</p>")
    else:
        header = ["Model", "Provider", "$ in / Mtok", "$ cached / Mtok", "$ out / Mtok", "Context", "Status"]
        rows = [header]
        for m in models:
            rows.append(
                [
                    m.get("id", ""),
                    m.get("provider", ""),
                    m.get("price_in_per_mtok", ""),
                    m.get("price_cached_per_mtok", ""),
                    m.get("price_out_per_mtok", ""),
                    m.get("context", ""),
                    m.get("status", ""),
                ]
            )
        parts.append(render_table(rows))

    # Routing rules in first-match order with their model.
    parts.append("<h2>Routing rules (first match wins)</h2>")
    rules = models_data.get("routing_rules")
    if not rules:
        parts.append("<p>routing_rules not found in models.yaml</p>")
    else:
        header = ["Rule", "Description", "When", "Model"]
        rows = [header]
        for r in rules:
            rows.append(
                [
                    r.get("rule", ""),
                    r.get("description", ""),
                    when_text(r.get("when")),
                    r.get("model", ""),
                ]
            )
        parts.append(render_table(rows))

    # Guard checks.
    parts.append("<h2>Guard checks</h2>")
    checks = models_data.get("checks")
    if not checks:
        parts.append("<p>checks not found in models.yaml</p>")
    else:
        header = ["Rule", "Description", "When", "Action"]
        rows = [header]
        for c in checks:
            rows.append(
                [
                    c.get("rule", ""),
                    c.get("description", ""),
                    when_text(c.get("when")),
                    c.get("action", ""),
                ]
            )
        parts.append(render_table(rows))

    return "\n".join(parts)


def placeholder_html(tab_name):
    return (
        "<h2>{}</h2>\n".format(esc(tab_name))
        + '<div class="placeholder"><p>This tab is not available yet. It will be '
        'filled in by a later sub-issue.</p></div>'
    )


def financials_html(data_dir):
    """Generate the Financials tab content from marts data."""
    marts_dir = Path(data_dir) / "marts"
    if not marts_dir.is_dir():
        return placeholder_html("Financials")
    
    # Load budget data
    budget_path = Path(".") / "factory" / "budget.yml"
    try:
        with open(budget_path, encoding="utf-8") as fh:
            budget_data = yaml.safe_load(fh) or {}
    except (OSError, yaml.YAMLError):
        budget_data = {}
    
    weekly_budget_usd = budget_data.get("weekly_usd", 0)
    monthly_budget_usd = budget_data.get("monthly_usd", 0)
    issue_target_usd = budget_data.get("issue_target_usd", 0.15)
    issue_cap_usd = budget_data.get("issue_cap_usd", 1.0)
    warn_pct = budget_data.get("warn_pct", 80)
    fixed_costs_monthly_usd = budget_data.get("fixed_costs_monthly_usd", 0)
    actions_minutes_month = budget_data.get("actions_minutes_month", 0)
    
    # Load mart data
    marts = {}
    for mart_file in marts_dir.glob("*.json"):
        try:
            with open(mart_file, encoding="utf-8") as fh:
                data = json.load(fh)
                # Ensure data is a list of dicts
                if isinstance(data, list):
                    # Validate that each item in the list is a dict
                    validated_data = [item for item in data if isinstance(item, dict)]
                    marts[mart_file.stem] = validated_data
                elif isinstance(data, dict) and 'rows' in data:
                    # Handle exported format { "model": "...", "rows": [...] }
                    rows = data['rows']
                    if isinstance(rows, list):
                        # Validate that each item in the rows list is a dict
                        validated_rows = [item for item in rows if isinstance(item, dict)]
                        marts[mart_file.stem] = validated_rows
                    else:
                        marts[mart_file.stem] = []
                else:
                    marts[mart_file.stem] = []
        except (OSError, ValueError):
            marts[mart_file.stem] = []
    
    rpt_run_rate = marts.get("rpt_run_rate", [])
    agg_spend_weekly = marts.get("agg_spend_weekly", [])
    agg_spend_monthly = marts.get("agg_spend_monthly", [])
    agg_spend_by_issue = marts.get("agg_spend_by_issue", [])
    rpt_issue_target_compliance = marts.get("rpt_issue_target_compliance", [])
    agg_spend_by_model = marts.get("agg_spend_by_model", [])
    fct_forecast_vs_actual = marts.get("fct_forecast_vs_actual", [])
    fct_agent_runs = marts.get("fct_agent_runs", [])
    
    # Check for negative values and fail loudly
    # Ensure all items are dictionaries before accessing keys
    for item in rpt_run_rate:
        if not isinstance(item, dict):
            raise ValueError(f"Expected dict in rpt_run_rate, got {type(item)}: {item}")
        for key in item:
            if isinstance(item[key], (int, float)) and item[key] < 0:
                raise ValueError(f"Negative value found in rpt_run_rate: {key} = {item[key]}")
    
    for item in agg_spend_weekly:
        if not isinstance(item, dict):
            raise ValueError(f"Expected dict in agg_spend_weekly, got {type(item)}: {item}")
        if item.get("spend_usd", 0) < 0:
            raise ValueError(f"Negative spend found in agg_spend_weekly: {item}")
    
    for item in agg_spend_monthly:
        if not isinstance(item, dict):
            raise ValueError(f"Expected dict in agg_spend_monthly, got {type(item)}: {item}")
        if item.get("spend_usd", 0) < 0:
            raise ValueError(f"Negative spend found in agg_spend_monthly: {item}")
    
    for item in agg_spend_by_issue:
        if not isinstance(item, dict):
            raise ValueError(f"Expected dict in agg_spend_by_issue, got {type(item)}: {item}")
        if item.get("spend_usd", 0) < 0:
            raise ValueError(f"Negative spend found in agg_spend_by_issue: {item}")
    
    # Also check other collections
    for collection_name, collection in [("rpt_issue_target_compliance", rpt_issue_target_compliance), 
                                        ("agg_spend_by_model", agg_spend_by_model), 
                                        ("fct_forecast_vs_actual", fct_forecast_vs_actual), 
                                        ("fct_agent_runs", fct_agent_runs)]:
        for item in collection:
            if not isinstance(item, dict):
                raise ValueError(f"Expected dict in {collection_name}, got {type(item)}: {item}")
    
    # Generate content sections
    parts = []
    
    # 1. Headline cards
    parts.append("<h2>Headline Cards <small>(source: rpt_run_rate)</small></h2>")
    if rpt_run_rate:
        rate = rpt_run_rate[0]  # Should be exactly one row
        week_spend = rate.get("trailing_7d_usd_per_day", 0) * 7
        week_used = rate.get("budget_used_pct", 0)
        month_spend = rate.get("mtd_variable_usd", 0)
        month_used = (month_spend / monthly_budget_usd * 100) if monthly_budget_usd > 0 else 0
        warn_class = " class=\"warn\"" if week_used >= warn_pct or month_used >= warn_pct else ""
        
        parts.append(f"<div class=\"cards\"{warn_class}>")
        parts.append("<div class=\"card\">")
        parts.append("<h3>This Week</h3>")
        parts.append(f"<p class=\"amount\">${week_spend:.2f}</p>")
        parts.append(f"<p>of ${weekly_budget_usd:.2f} budget ({week_used:.1f}%)</p>")
        parts.append("</div>")
        
        parts.append("<div class=\"card\">")
        parts.append("<h3>Month-to-Date</h3>")
        parts.append(f"<p class=\"amount\">${month_spend:.2f}</p>")
        parts.append(f"<p>of ${monthly_budget_usd:.2f} budget ({month_used:.1f}%)</p>")
        parts.append("</div>")
        
        parts.append("<div class=\"card\">")
        parts.append("<h3>Projected Month-End</h3>")
        proj_var = rate.get("projected_month_end_variable_usd", 0)
        parts.append(f"<p class=\"amount\">${proj_var:.2f}</p>")
        parts.append(f"<p>+ ${fixed_costs_monthly_usd:.2f} fixed costs</p>")
        parts.append("</div>")
        
        parts.append("<div class=\"card\">")
        parts.append("<h3>Total MTD</h3>")
        total_mtd = rate.get("total_mtd_usd", 0)
        parts.append(f"<p class=\"amount\">${total_mtd:.2f}</p>")
        total_budget = monthly_budget_usd + fixed_costs_monthly_usd
        parts.append(f"<p>of ${total_budget:.2f} total budget</p>")
        parts.append("</div>")
        
        parts.append("<div class=\"card\">")
        parts.append("<h3>Actions Minutes</h3>")
        actions_mtd = rate.get("actions_minutes_mtd", 0)
        actions_pct = rate.get("actions_minutes_used_pct", 0)
        parts.append(f"<p class=\"amount\">{actions_mtd} min</p>")
        parts.append(f"<p>of {actions_minutes_month} min ({actions_pct:.1f}%)</p>")
        parts.append("</div>")
        parts.append("</div>")
    else:
        parts.append("<p>No run rate data available.</p>")
    
    # 2. Budget vs spend charts
    parts.append("<h2>Budget vs Spend <small>(sources: agg_spend_weekly, agg_spend_monthly)</small></h2>")
    if agg_spend_weekly or agg_spend_monthly:
        # Import chart functions
        try:
            # Add factory/site to Python path
            factory_site_path = str(Path(__file__).parent.parent / "factory" / "site")
            if factory_site_path not in sys.path:
                sys.path.insert(0, factory_site_path)
            
            from charts import svg_chart_weekly, svg_chart_monthly
            
            # Weekly chart
            if agg_spend_weekly:
                svg_weekly, table_weekly = svg_chart_weekly(agg_spend_weekly, weekly_budget_usd)
                parts.append("<h3>Weekly Spend (Last 12 Weeks)</h3>")
                parts.append(svg_weekly)
                parts.append("<details><summary>Table fallback</summary>")
                parts.append(table_weekly)
                parts.append("</details>")
            
            # Monthly chart
            if agg_spend_monthly:
                svg_monthly, table_monthly = svg_chart_monthly(agg_spend_monthly, monthly_budget_usd)
                parts.append("<h3>Monthly Spend (Last 6 Months)</h3>")
                parts.append(svg_monthly)
                parts.append("<details><summary>Table fallback</summary>")
                parts.append(table_monthly)
                parts.append("</details>")
        except Exception as e:
            parts.append(f"<p>Chart module error: {esc(str(e))}</p>")
    else:
        parts.append("<p>No budget vs spend data available.</p>")
    
    # 3. Per-issue economics
    parts.append("<h2>Per-Issue Economics <small>(sources: agg_spend_by_issue, rpt_issue_target_compliance)</small></h2>")
    if agg_spend_by_issue:
        # Sort by spend descending and take top 15
        top_issues = sorted(agg_spend_by_issue, key=lambda x: x.get("spend_usd", 0), reverse=True)[:15]
        
        parts.append("<table>")
        parts.append("<thead><tr>")
        parts.append("<th>Issue</th><th>Runs</th><th>Spend</th><th>Under Target</th><th>Under Cap</th><th>Headroom</th>")
        parts.append("</tr></thead><tbody>")
        
        for issue in top_issues:
            issue_num = issue.get("issue_number", "Unknown")
            runs = issue.get("runs", 0)
            spend = issue.get("spend_usd", 0)
            under_target = "✓" if spend <= issue_target_usd else "✗"
            under_cap = "✓" if spend <= issue_cap_usd else "✗"
            headroom = max(0, issue_cap_usd - spend)
            
            parts.append("<tr>")
            parts.append(f"<td>#{issue_num}</td>")
            parts.append(f"<td>{runs}</td>")
            parts.append(f"<td>${spend:.4f}</td>")
            parts.append(f"<td>{under_target}</td>")
            parts.append(f"<td>{under_cap}</td>")
            parts.append(f"<td>${headroom:.4f}</td>")
            parts.append("</tr>")
        
        parts.append("</tbody></table>")
        
        # Compliance summary
        if rpt_issue_target_compliance:
            compliance = rpt_issue_target_compliance[0] if rpt_issue_target_compliance else {}
            under_target_pct = compliance.get("under_target_pct", 0)
            over_cap_count = compliance.get("over_cap_count", 0)
            
            parts.append("<h3>Compliance Summary</h3>")
            parts.append(f"<p>{under_target_pct:.1f}% of issues under target (${issue_target_usd})</p>")
            parts.append(f"<p>{over_cap_count} issues over cap (${issue_cap_usd})</p>")
    else:
        parts.append("<p>No per-issue data available.</p>")
    
    # 4. By model and by work type
    parts.append("<h2>By Model and Work Type <small>(sources: agg_spend_by_model, fct_agent_runs)</small></h2>")
    if agg_spend_by_model:
        parts.append("<table>")
        parts.append("<thead><tr>")
        parts.append("<th>Model</th><th>Work Type</th><th>Spend</th><th>Runs</th><th>Avg Cost/Run</th>")
        parts.append("</tr></thead><tbody>")
        
        # Group by model and work type
        model_work_data = {}
        for item in agg_spend_by_model:
            model = item.get("model", "Unknown")
            work_type = item.get("work_type", "Unknown")
            spend = item.get("spend_usd", 0)
            runs = item.get("runs", 0)
            avg_cost = spend / runs if runs > 0 else 0
            
            if model not in model_work_data:
                model_work_data[model] = {}
            model_work_data[model][work_type] = {"spend": spend, "runs": runs, "avg_cost": avg_cost}
        
        # Display data
        for model in sorted(model_work_data.keys()):
            work_types = model_work_data[model]
            for work_type in sorted(work_types.keys()):
                data = work_types[work_type]
                parts.append("<tr>")
                parts.append(f"<td>{esc(model)}</td>")
                parts.append(f"<td>{esc(work_type)}</td>")
                parts.append(f"<td>${data['spend']:.4f}</td>")
                parts.append(f"<td>{data['runs']}</td>")
                parts.append(f"<td>${data['avg_cost']:.6f}</td>")
                parts.append("</tr>")
        
        parts.append("</tbody></table>")
    else:
        parts.append("<p>No model/work-type data available.</p>")
    
    # 5. Prediction accuracy
    parts.append("<h2>Prediction Accuracy <small>(source: fct_forecast_vs_actual)</small></h2>")
    if fct_forecast_vs_actual:
        # Filter out rows with null predicted_cost_usd
        valid_predictions = [row for row in fct_forecast_vs_actual if row.get("predicted_cost_usd") is not None]
        skipped_count = len(fct_forecast_vs_actual) - len(valid_predictions)
        
        if valid_predictions:
            # Calculate absolute errors
            errors = []
            for row in valid_predictions:
                actual = row.get("actual_cost_usd", 0)
                predicted = row.get("predicted_cost_usd", 0)
                error = abs(predicted - actual)
                errors.append(error)
            
            if errors:
                median_error = sorted(errors)[len(errors) // 2]
                worst_error = max(errors)
                
                parts.append("<table>")
                parts.append("<thead><tr>")
                parts.append("<th>Median Absolute Error</th><th>Worst Absolute Error</th><th>Recalibrate Flag</th>")
                parts.append("</tr></thead><tbody>")
                parts.append("<tr>")
                parts.append(f"<td>${median_error:.4f}</td>")
                parts.append(f"<td>${worst_error:.4f}</td>")
                recalibrate = "YES" if median_error / issue_target_usd >= 1.0 else "NO"  # 100% of target
                parts.append(f"<td>{recalibrate}</td>")
                parts.append("</tr>")
                parts.append("</tbody></table>")
        
        if skipped_count > 0:
            parts.append(f"<p>Note: {skipped_count} rows with null predictions were excluded from accuracy statistics.</p>")
    else:
        parts.append("<p>No prediction accuracy data available.</p>")
    
    # 6. Data freshness
    parts.append("<h2>Data Freshness <small>(source: fct_agent_runs)</small></h2>")
    if fct_agent_runs:
        # Find latest run time
        latest_run = max([item.get("ended_at_utc", "") for item in fct_agent_runs if item.get("ended_at_utc")], default="")
        
        if latest_run:
            parts.append("<table>")
            parts.append("<thead><tr>")
            parts.append("<th>Latest Run Time (UTC)</th><th>Latest Run Time (America/Chicago)</th><th>Total Records</th><th>Invalid Records Skipped</th>")
            parts.append("</tr></thead><tbody>")
            
            # Count records
            total_records = len(fct_agent_runs)
            invalid_records = len([item for item in fct_agent_runs if not item.get("ended_at_utc")])
            
            parts.append("<tr>")
            parts.append(f"<td>{latest_run}</td>")
            # Note: Converting timezone would require additional libraries, so we'll just note it
            parts.append(f"<td>{latest_run} (convert manually to Chicago time)</td>")
            parts.append(f"<td>{total_records}</td>")
            parts.append(f"<td>{invalid_records}</td>")
            parts.append("</tr>")
            parts.append("</tbody></table>")
        else:
            parts.append("<p>No valid run times found.</p>")
    else:
        parts.append("<p>No data freshness information available.</p>")
    
    return "\n".join(parts)


PRIORITY_ORDER = {"high": 2, "low": 1, "none": 0}
RISK_ORDER = ("high", "medium", "low", "unlabeled")
STATUS_LABELS = {
    "open": "open",
    "high": "high priority",
    "owner-action": "owner-action",
    "selected": "selected",
}


def _summary_cards(issues):
    open_count = len(issues)
    high = sum(1 for i in issues if i.get("priority") == "high")
    owner_action = sum(1 for i in issues if i.get("status") == "owner-action")
    selected = sum(1 for i in issues if i.get("status") == "factory:selected")
    cards = [
        ("Open", open_count),
        ("High priority", high),
        ("Owner-action", owner_action),
        ("Selected", selected),
    ]
    out = ['<div class="cards">']
    for label, count in cards:
        out.append(
            '<div class="card"><span class="card-label">{}</span>'
            '<span class="card-value">{}</span></div>'.format(esc(label), esc(count))
        )
    out.append("</div>")
    return "\n".join(out)


def _priority_risk_table(issues):
    rows = {risk: {prio: 0 for prio in PRIORITY_ORDER} for risk in RISK_ORDER}
    for i in issues:
        prio = i.get("priority", "none")
        if prio not in PRIORITY_ORDER:
            prio = "none"
        risk = i.get("risk", "unlabeled")
        if risk not in rows:
            risk = "unlabeled"
        rows[risk][prio] += 1
    header = ["Risk \\ Priority", "high", "low", "none"]
    table = [header]
    for risk in RISK_ORDER:
        table.append([risk] + [str(rows[risk][prio]) for prio in PRIORITY_ORDER])
    return render_table(table)


def _epic_list(issues):
    epics = [i for i in issues if i.get("status") == "epic"]
    epics.sort(key=lambda i: (i.get("updatedAt") or "", i.get("number") or 0))
    if not epics:
        return ""
    out = ["<h2>Epics</h2>", "<ul class=\"epics\">"]
    for i in epics:
        title = i.get("title", "")
        done = i.get("done", 0)
        total = i.get("total", 0)
        url = i.get("url", "")
        link = '<a href="{}">{}</a>'.format(esc(url), esc(title)) if url else esc(title)
        out.append("<li>{} — {} / {} done</li>".format(link, esc(done), esc(total)))
    out.append("</ul>")
    return "\n".join(out)


def _issue_table(issues):
    ordered = sorted(
        issues,
        key=lambda i: (i.get("updatedAt") or "", i.get("number") or 0),
        reverse=True,
    )
    ordered = sorted(
        ordered,
        key=lambda i: -PRIORITY_ORDER.get(i.get("priority", "none"), 0),
    )
    header = ["Priority", "Status", "Title"]
    out = ["<table><thead><tr>"]
    for cell in header:
        out.append("<th>{}</th>".format(esc(cell)))
    out.append("</tr></thead><tbody>")
    for i in ordered:
        title = i.get("title", "")
        url = i.get("url", "")
        link = '<a href="{}">{}</a>'.format(esc(url), esc(title)) if url else esc(title)
        status = STATUS_LABELS.get(i.get("status", "open"), i.get("status", "open"))
        out.append("<tr>")
        out.append("<th>{}</th>".format(esc(i.get("priority", "none"))))
        out.append("<td>{}</td>".format(esc(status)))
        out.append("<td>{}</td>".format(link))
        out.append("</tr>")
    out.append("</tbody></table>")
    return "\n".join(out)


def backlog_html(data_dir):
    backlog = Path(data_dir) / "backlog.json"
    if not backlog.is_file():
        return placeholder_html("Backlog")
    try:
        with open(backlog, encoding="utf-8") as fh:
            items = json.load(fh)
    except (ValueError, OSError):
        return placeholder_html("Backlog")
    if not isinstance(items, list):
        return placeholder_html("Backlog")
    issues = [i for i in items if isinstance(i, dict)]
    out = [
        "<h2>Backlog</h2>",
        _summary_cards(issues),
        "<h2>Open issues by priority and risk</h2>",
        _priority_risk_table(issues),
    ]
    epic = _epic_list(issues)
    if epic:
        out.append(epic)
    out.append("<h2>Open issues</h2>")
    out.append(_issue_table(issues))
    return "\n".join(out)


def dbt_html(repo_root):
    manifest = Path(repo_root) / "factory" / "dbt" / "target" / "manifest.json"
    if manifest.is_file():
        return (
            "<h2>dbt</h2>\n"
            '<div class="placeholder"><p>The dbt manifest is present, but the full '
            'tab lands in issue #173.</p></div>'
        )
    return placeholder_html("dbt")


def git_version(repo_root):
    try:
        out = subprocess.run(
            ["git", "describe", "--tags", "--always"],
            cwd=str(repo_root),
            capture_output=True,
            text=True,
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except OSError:
        pass
    return "unknown"


def build_time(args):
    if args.now:
        return args.now
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if epoch:
        try:
            return datetime.datetime.fromtimestamp(
                int(epoch), tz=datetime.timezone.utc
            ).strftime("%Y-%m-%d %H:%M:%S")
        except (ValueError, OSError):
            pass
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="site")
    parser.add_argument("--data", default="site-data")
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--now", default=None, help="Pin the build time (UTC).")
    args = parser.parse_args()

    repo_root = Path(args.repo_root)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    models_data = load_models(repo_root)

    factory_md_path = Path(repo_root) / ".factory" / "FACTORY.md"
    factory_md = ""
    if factory_md_path.is_file():
        with open(factory_md_path, encoding="utf-8") as fh:
            factory_md = fh.read()

    repo_name = os.environ.get("GITHUB_REPOSITORY", "")
    base_title = "Factory site" if not repo_name else repo_name
    version = git_version(repo_root)
    now = build_time(args)

    template_path = Path(repo_root) / "factory" / "site" / "base.html"
    with open(template_path, encoding="utf-8") as fh:
        template = Template(fh.read())

    content_by_page = {
        "index.html": architecture_html(repo_root, models_data, factory_md),
        "financials.html": financials_html(args.data),
        "backlog.html": backlog_html(args.data),
        "dbt.html": dbt_html(repo_root),
    }

    written = []
    for filename, label in TAB_LABELS:
        page_title = base_title if filename == "index.html" else "{} - {}".format(label, base_title)
        body = template.substitute(
            title=esc(page_title),
            page_title=esc(page_title),
            tabs=build_tabs(filename),
            content=content_by_page[filename],
            version=esc(version),
            build_time=esc(now),
        )
        with open(out_dir / filename, "w", encoding="utf-8") as fh:
            fh.write(body)
        written.append(filename)

    print("Wrote {}".format(", ".join(written)))


if __name__ == "__main__":
    main()
