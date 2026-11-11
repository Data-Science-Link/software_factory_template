#!/usr/bin/env python3
"""Generate inline SVG charts for the Financials tab with no JS and no chart library."""

import html


def esc(value):
    """Escape text for HTML."""
    return html.escape(str(value), quote=True)


def svg_chart_weekly(weekly_data, weekly_budget_usd):
    """Generate an inline SVG bar chart of weekly spend vs budget."""
    if not weekly_data:
        return '<p>No weekly data available.</p>', '<p>No weekly data available.</p>'

    # Ensure all items are dictionaries
    valid_data = [item for item in weekly_data if isinstance(item, dict)]
    if not valid_data:
        return '<p>No valid weekly data available.</p>', '<p>No valid weekly data available.</p>'

    # Sort by ISO week for consistent order
    try:
        sorted_data = sorted(valid_data, key=lambda x: (x["iso_year"], x["iso_week"]))
    except KeyError as e:
        return f'<p>Error: Missing key {e} in weekly data.</p>', '<p>Error processing weekly data.</p>'
    
    # Extract values
    weeks = [f"{item['iso_year']}-W{item['iso_week']:02d}" for item in sorted_data]
    spend_values = [item["spend_usd"] for item in sorted_data]
    budget_values = [weekly_budget_usd] * len(sorted_data)
    
    # Handle zero or negative values gracefully
    max_spend = max(spend_values) if spend_values else 0
    max_budget = max(budget_values) if budget_values else 0
    chart_max = max(max_spend, max_budget, 0.01)  # Ensure non-zero
    
    # Chart dimensions
    bar_width = 30
    bar_gap = 10
    chart_height = 200
    chart_width = len(weeks) * (bar_width + bar_gap) + bar_gap
    
    # Generate SVG
    svg_parts = [
        f'<svg viewBox="0 0 {chart_width} {chart_height}" '
        f'width="{chart_width}" height="{chart_height}">',
        '<style>',
        '.bar { fill: #4CAF50; }',
        '.bar-over { fill: #F44336; }',
        '.budget-line { stroke: #2196F3; stroke-width: 2; stroke-dasharray: 4 2; }',
        '.axis-label { font-size: 10px; fill: #333; text-anchor: middle; }',
        '.budget-label { font-size: 10px; fill: #2196F3; text-anchor: start; }',
        '</style>'
    ]
    
    # Draw bars
    for i, (spend, budget, week_label) in enumerate(zip(spend_values, budget_values, weeks)):
        x = bar_gap + i * (bar_width + bar_gap)
        bar_height = (spend / chart_max) * (chart_height - 40) if chart_max > 0 else 0
        y = chart_height - 20 - bar_height
        
        # Determine bar color
        bar_class = "bar-over" if spend > budget else "bar"
        
        svg_parts.append(
            f'<rect x="{x}" y="{y}" width="{bar_width}" height="{bar_height}" '
            f'class="{bar_class}" />'
        )
        
        # Week label
        label_y = chart_height - 5
        svg_parts.append(
            f'<text x="{x + bar_width/2}" y="{label_y}" class="axis-label">{esc(week_label)}</text>'
        )
    
    # Draw budget line
    if chart_max > 0:
        budget_y = chart_height - 20 - (weekly_budget_usd / chart_max) * (chart_height - 40)
        svg_parts.append(
            f'<line x1="{bar_gap}" y1="{budget_y}" x2="{chart_width - bar_gap}" y2="{budget_y}" '
            f'class="budget-line" />'
        )
        svg_parts.append(
            f'<text x="{chart_width - bar_gap}" y="{budget_y - 5}" class="budget-label">Budget: ${weekly_budget_usd:.2f}</text>'
        )
    
    svg_parts.append('</svg>')
    
    # Generate table fallback
    table_parts = ['<table><thead><tr><th>Week</th><th>Spend</th><th>Budget</th><th>Status</th></tr></thead><tbody>']
    for spend, budget, week_label in zip(spend_values, budget_values, weeks):
        status = "Over" if spend > budget else "Under"
        table_parts.append(
            f'<tr><td>{esc(week_label)}</td><td>${spend:.4f}</td><td>${budget:.2f}</td><td>{status}</td></tr>'
        )
    table_parts.append('</tbody></table>')
    
    return '\n'.join(svg_parts), '\n'.join(table_parts)


def svg_chart_monthly(monthly_data, monthly_budget_usd):
    """Generate an inline SVG bar chart of monthly spend vs budget."""
    if not monthly_data:
        return '<p>No monthly data available.</p>', '<p>No monthly data available.</p>'

    # Ensure all items are dictionaries
    valid_data = [item for item in monthly_data if isinstance(item, dict)]
    if not valid_data:
        return '<p>No valid monthly data available.</p>', '<p>No valid monthly data available.</p>'

    # Sort by month for consistent order
    try:
        sorted_data = sorted(valid_data, key=lambda x: x["month_start_utc"])
    except KeyError as e:
        return f'<p>Error: Missing key {e} in monthly data.</p>', '<p>Error processing monthly data.</p>'
    
    # Extract values
    months = [item["month_start_utc"][:7] for item in sorted_data]  # YYYY-MM
    spend_values = [item["spend_usd"] for item in sorted_data]
    budget_values = [monthly_budget_usd] * len(sorted_data)
    
    # Handle zero or negative values gracefully
    max_spend = max(spend_values) if spend_values else 0
    max_budget = max(budget_values) if budget_values else 0
    chart_max = max(max_spend, max_budget, 0.01)  # Ensure non-zero
    
    # Chart dimensions
    bar_width = 40
    bar_gap = 15
    chart_height = 200
    chart_width = len(months) * (bar_width + bar_gap) + bar_gap
    
    # Generate SVG
    svg_parts = [
        f'<svg viewBox="0 0 {chart_width} {chart_height}" '
        f'width="{chart_width}" height="{chart_height}">',
        '<style>',
        '.bar { fill: #4CAF50; }',
        '.bar-over { fill: #F44336; }',
        '.budget-line { stroke: #2196F3; stroke-width: 2; stroke-dasharray: 4 2; }',
        '.axis-label { font-size: 10px; fill: #333; text-anchor: middle; }',
        '.budget-label { font-size: 10px; fill: #2196F3; text-anchor: start; }',
        '</style>'
    ]
    
    # Draw bars
    for i, (spend, budget, month_label) in enumerate(zip(spend_values, budget_values, months)):
        x = bar_gap + i * (bar_width + bar_gap)
        bar_height = (spend / chart_max) * (chart_height - 40) if chart_max > 0 else 0
        y = chart_height - 20 - bar_height
        
        # Determine bar color
        bar_class = "bar-over" if spend > budget else "bar"
        
        svg_parts.append(
            f'<rect x="{x}" y="{y}" width="{bar_width}" height="{bar_height}" '
            f'class="{bar_class}" />'
        )
        
        # Month label
        label_y = chart_height - 5
        svg_parts.append(
            f'<text x="{x + bar_width/2}" y="{label_y}" class="axis-label">{esc(month_label)}</text>'
        )
    
    # Draw budget line
    if chart_max > 0:
        budget_y = chart_height - 20 - (monthly_budget_usd / chart_max) * (chart_height - 40)
        svg_parts.append(
            f'<line x1="{bar_gap}" y1="{budget_y}" x2="{chart_width - bar_gap}" y2="{budget_y}" '
            f'class="budget-line" />'
        )
        svg_parts.append(
            f'<text x="{chart_width - bar_gap}" y="{budget_y - 5}" class="budget-label">Budget: ${monthly_budget_usd:.2f}</text>'
        )
    
    svg_parts.append('</svg>')
    
    # Generate table fallback
    table_parts = ['<table><thead><tr><th>Month</th><th>Spend</th><th>Budget</th><th>Status</th></tr></thead><tbody>']
    for spend, budget, month_label in zip(spend_values, budget_values, months):
        status = "Over" if spend > budget else "Under"
        table_parts.append(
            f'<tr><td>{esc(month_label)}</td><td>${spend:.4f}</td><td>${budget:.2f}</td><td>{status}</td></tr>'
        )
    table_parts.append('</tbody></table>')
    
    return '\n'.join(svg_parts), '\n'.join(table_parts)
