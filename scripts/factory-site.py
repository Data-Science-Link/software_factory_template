#!/usr/bin/env python3
"""Render the static four-tab factory site from the factory's own source files.

Usage:
    scripts/factory-site.py --out site --data site-data [--repo-root .] [--now <utc>]

Writes index.html (Architecture), financials.html, backlog.html and dbt.html with a
shared header and tab nav. Uses only stdlib string.Template + PyYAML. All text is
html.escape-d. Optional inline enhancement script (theme, filters, export; no
external assets). Base style lives in factory/site/style.css, linked from
factory/site/base.html.
"""
import argparse
import datetime
import html
import importlib.util
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

FACTORY_LOOP_STAGES = (
    {
        "id": "idea",
        "label": "Idea",
        "description": (
            "Work is captured as a GitHub issue that states the desired outcome "
            "in one sentence."
        ),
        "inputs": "Issue title, body, and optional labels.",
        "outputs": "A tracked issue ready for factory triage.",
        "guardrails": "No secrets in issue text; one clear outcome per issue.",
    },
    {
        "id": "triage",
        "label": "Triage",
        "description": (
            "The Factory Manager classifies risk, complexity, and whether the "
            "issue is selected for a run."
        ),
        "inputs": "Open issue, labels, and backlog priority.",
        "outputs": "Risk class, complexity, and selection decision.",
        "guardrails": "Unselected issues stop; high-risk paths need human gates.",
    },
    {
        "id": "spec",
        "label": "Spec",
        "description": (
            "An approved spec defines scope, files, verification commands, and "
            "predicted cost before any build runs."
        ),
        "inputs": "Selected issue and FACTORY.md conventions.",
        "outputs": "Machine-readable spec with routing hints.",
        "guardrails": "Spec lists allowed paths; forbidden paths block the worker.",
    },
    {
        "id": "human-review",
        "label": "Human Review",
        "description": (
            "A human approves the spec (and merge plan) before standard or "
            "complex work starts."
        ),
        "inputs": "Draft spec and predicted cost.",
        "outputs": "Recorded approval on the issue or PR.",
        "guardrails": "No build on standard/complex work without approval.",
    },
    {
        "id": "build",
        "label": "Build",
        "description": (
            "A worker agent implements the spec on a feature branch and opens "
            "or updates a pull request."
        ),
        "inputs": "Approved spec, default branch, and toolchain registry.",
        "outputs": "PR with diff, verification output, and AI disclosure.",
        "guardrails": "Workers never merge; spend stays under per-issue cap.",
    },
    {
        "id": "verify",
        "label": "Verify",
        "description": (
            "CI and factory scripts run: tests, pr-check, gitleaks, and "
            "run-record gates."
        ),
        "inputs": "Head commit on the PR branch.",
        "outputs": "Green required checks or a fix loop.",
        "guardrails": "No bypass hooks; failing gates block merge.",
    },
    {
        "id": "merge",
        "label": "Merge",
        "description": (
            "Merge authority follows risk class: trivial may auto-merge; "
            "normal and high need a human product gate."
        ),
        "inputs": "Green PR, review comments, and merge authority table.",
        "outputs": "Merged commit on the default branch.",
        "guardrails": "High-risk and workflow changes need explicit human merge.",
    },
    {
        "id": "monitor",
        "label": "Monitor",
        "description": (
            "Spend, run records, and CI health are tracked against weekly and "
            "monthly budgets."
        ),
        "inputs": "Run records, dbt marts, and budget.yml caps.",
        "outputs": "Financials tab metrics and budget warnings.",
        "guardrails": "Warn threshold triggers before hard budget overrun.",
    },
    {
        "id": "feedback",
        "label": "Feedback",
        "description": (
            "Retrospectives update DECISIONS.md, routing, and the backlog for "
            "the next loop."
        ),
        "inputs": "Merged PR, actual cost vs prediction, and review notes.",
        "outputs": "New issues, spec tweaks, and documented decisions.",
        "guardrails": "Decisions stay repo-agnostic in published site copy.",
    },
)


def _page_stem(filename):
    if filename == "index.html":
        return "architecture"
    return filename.replace(".html", "")


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
        stem = _page_stem(filename)
        tab_id = "tab-{}".format(stem)
        panel_id = "panel-{}".format(stem)
        is_active = filename == active
        cls = ' class="active"' if is_active else ""
        selected = "true" if is_active else "false"
        tabindex = "0" if is_active else "-1"
        parts.append(
            '<a href="{}" id="{}" role="tab" aria-selected="{}" '
            'aria-controls="{}" tabindex="{}"{}>{}</a>'.format(
                esc(filename),
                esc(tab_id),
                selected,
                esc(panel_id),
                tabindex,
                cls,
                esc(label),
            )
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


def strip_markdown(text):
    """Remove inline markdown markers (bold `**`, code backticks) from a string."""
    text = re.sub(r"\*\*(.*?)\*\*", r"\1", str(text))
    text = re.sub(r"`([^`]*)`", r"\1", text)
    return text


def repo_agnostic_copy(text):
    """Replace template-repo owner/bot names with role labels for the public site."""
    text = str(text)
    text = re.sub(r"\bMichael's\b", "the owner's", text)
    text = re.sub(r"\bMichael\b", "the owner", text)
    text = re.sub(r"\bGrok Bot\b", "the Factory Manager", text)
    return text


def render_inline_markdown(text, agnostic=False):
    """Render `**bold**` and `code` as HTML; escape everything else."""
    if agnostic:
        text = repo_agnostic_copy(text)
    text = str(text)
    parts = []
    pos = 0
    for m in re.finditer(r"\*\*(.+?)\*\*|`([^`]+)`", text):
        if m.start() > pos:
            parts.append(esc(text[pos:m.start()]))
        if m.group(1) is not None:
            parts.append("<strong>{}</strong>".format(esc(m.group(1))))
        else:
            parts.append("<code>{}</code>".format(esc(m.group(2))))
        pos = m.end()
    if pos < len(text):
        parts.append(esc(text[pos:]))
    return "".join(parts) if parts else esc(text)


def render_table(rows, agnostic=False):
    if not rows:
        return ""
    out = ["<table><thead><tr>"]
    for cell in rows[0]:
        out.append("<th>{}</th>".format(render_inline_markdown(cell, agnostic=agnostic)))
    out.append("</tr></thead><tbody>")
    for row in rows[1:]:
        out.append("<tr>")
        for i, cell in enumerate(row):
            tag = "th" if i == 0 else "td"
            out.append(
                "<{}>{}</{}>".format(
                    tag, render_inline_markdown(cell, agnostic=agnostic), tag
                )
            )
        out.append("</tr>")
    out.append("</tbody></table>")
    return "\n".join(out)


def render_loop_cards(steps):
    out = ['<div class="loop-cards">']
    for num, text in steps:
        body = repo_agnostic_copy(text).strip()
        title = str(num)
        desc = ""
        m = re.match(r"^\d+\.\s*(.*?)\s*(?:—|-)\s*(.*)$", body, re.DOTALL)
        if m:
            title = m.group(1).strip()
            desc = m.group(2).strip()
        else:
            m2 = re.match(r"^\d+\.\s*(.*)$", body, re.DOTALL)
            if m2:
                title = m2.group(1).strip()
        out.append('<div class="loop-card">')
        out.append(
            '<h3 class="loop-card-title">{}</h3>'.format(render_inline_markdown(title))
        )
        if desc:
            out.append(
                '<p class="loop-card-desc">{}</p>'.format(render_inline_markdown(desc))
            )
        out.append("</div>")
    out.append("</div>")
    return "\n".join(out)


def loop_svg():
    """Inline SVG loop diagram for the nine factory stages. Deterministic, offline."""
    stages = [
        "idea",
        "triage",
        "spec",
        "review",
        "build",
        "verify",
        "merge",
        "monitor",
        "feedback",
    ]
    node_w = 96
    node_h = 38
    per_row = 5
    gap = 26
    arrow = 12
    x0 = 6
    y1 = 8
    y2 = 68
    parts = ['<svg class="loop-diagram" viewBox="0 0 {} {}" '
             'role="img" '
             'aria-label="Factory loop diagram">'.format(
                 x0 * 2 + per_row * node_w + (per_row - 1) * (gap + arrow),
                 y2 + node_h + 8,
             )]
    positions = []
    for i, stage in enumerate(stages):
        row = i // per_row
        col = i % per_row
        x = x0 + col * (node_w + gap + arrow)
        y = y1 if row == 0 else y2
        positions.append((x, y))
        parts.append(
            '<rect x="{}" y="{}" width="{}" height="{}" rx="6" '
            'fill="#eef0f4" stroke="#1f2430" stroke-width="1.5"/>'.format(
                x, y, node_w, node_h
            )
        )
        parts.append(
            '<text x="{}" y="{}" text-anchor="middle" font-size="12" '
            'fill="#1f2430">{}</text>'.format(
                x + node_w / 2, y + node_h / 2 + 4, esc(stage)
            )
        )
    for i in range(len(stages) - 1):
        if i % per_row == per_row - 1:
            continue
        x1, y1p = positions[i]
        x2, _y2p = positions[i + 1]
        ax = x1 + node_w + 3
        ay = y1p + node_h / 2
        bx = x2 - 3
        parts.append(
            '<line x1="{}" y1="{}" x2="{}" y2="{}" stroke="#1f2430" '
            'stroke-width="2" marker-end="url(#arrow)"/>'.format(ax, ay, bx - arrow, ay)
        )
    last = positions[per_row - 1]
    first_next = positions[per_row]
    parts.append(
        '<line x1="{}" y1="{}" x2="{}" y2="{}" stroke="#1f2430" '
        'stroke-width="2" marker-end="url(#arrow)"/>'.format(
            last[0] + node_w / 2, last[1] + node_h,
            first_next[0] + node_w / 2, first_next[1],
        )
    )
    defs = (
        '<defs><marker id="arrow" markerWidth="10" markerHeight="10" '
        'refX="9" refY="3" orient="auto" markerUnits="strokeWidth">'
        '<path d="M0,0 L0,6 L9,3 z" fill="#1f2430"/></marker></defs>'
    )
    return "\n".join([defs] + parts + ["</svg>"])


def newcomer_pitch():
    return (
        '<div class="pitch">'
        "<p>Work enters as a GitHub issue, gets triaged into a written spec, and a "
        "low-cost <code>/oc</code> bot build turns it into a pull request for a human "
        "to review and ship. Every run tracks its own cost so you always know what "
        "each change costs.</p>"
        "</div>"
    )


def human_decides_box():
    return (
        '<div class="human-decides">'
        "<h3>What a human decides</h3>"
        "<ul>"
        "<li>Spec approval before hard (standard or complex) work runs.</li>"
        "<li>Merge approval for normal- and high-risk changes.</li>"
        "<li>The budget each run is allowed to spend.</li>"
        "</ul>"
        "</div>"
    )


def depth_links():
    return (
        '<div class="depth-links">'
        "<h3>For depth</h3>"
        "<ul>"
        '<li><a href=".factory/FACTORY.md">.factory/FACTORY.md</a> — the full factory playbook.</li>'
        '<li><a href="ADOPTING.md">ADOPTING.md</a> — how to adopt and use this factory.</li>'
        '<li><a href="docs/SETUP.md">docs/SETUP.md</a> — set up a new repo.</li>'
        "</ul>"
        "</div>"
    )


QUICKSTART_COMMANDS = (
    "bash scripts/install-hooks.sh",
    "python3 scripts/factory-doctor.py",
    "bash scripts/factory-site-build.sh --sample",
)


def render_copyable_codeblock(command, block_id):
    """Architecture quickstart row with a one-click copy control."""
    return (
        '<div class="codeblock-wrap">'
        '<pre class="codeblock"><code id="{}">{}</code></pre>'.format(
            esc(block_id), esc(command)
        )
        + '<button type="button" class="copy-btn" data-copy-source="{}" '
        'aria-label="Copy command to clipboard">Copy</button>'.format(esc(block_id))
        + "</div>"
    )


def architecture_quickstart():
    blocks = []
    for idx, cmd in enumerate(QUICKSTART_COMMANDS):
        blocks.append(render_copyable_codeblock(cmd, "quickstart-cmd-{}".format(idx)))
    return (
        "<h2>Quickstart</h2>"
        '<p class="quickstart-intro">Run these from the repository root after cloning. '
        "They install hooks, verify guardrails, and build the offline sample site.</p>"
        + "".join(blocks)
    )


def _backlog_filter_bar(total):
    pills = (
        ("all", "All"),
        ("high-priority", "High priority"),
        ("high-risk", "High risk"),
        ("unlabeled", "Unlabeled"),
    )
    pill_html = []
    for key, label in pills:
        active = ' is-active' if key == "all" else ""
        pill_html.append(
            '<button type="button" class="filter-pill{}" data-filter="{}" '
            'aria-pressed="{}">{}</button>'.format(
                active,
                esc(key),
                "true" if key == "all" else "false",
                esc(label),
            )
        )
    return (
        '<div class="backlog-filter" id="backlog-filter-bar">'
        '<div class="backlog-filter-row">'
        '<label class="backlog-search-label" for="backlog-search">Search titles</label>'
        '<input type="search" id="backlog-search" class="backlog-search" '
        'placeholder="Filter by title…" autocomplete="off" spellcheck="false">'
        "</div>"
        '<div class="filter-pills" role="group" aria-label="Backlog filters">'
        + "".join(pill_html)
        + "</div>"
        '<p id="backlog-filter-count" class="backlog-filter-count" aria-live="polite">'
        "Showing {} of {}</p>".format(esc(total), esc(total))
        + "</div>"
    )


def _agent_runs_table(rows):
    """Financials agent-runs table with sortable columns and CSV export hook."""
    if not rows:
        return '<p class="note">No agent run records available.</p>'
    valid = [r for r in rows if isinstance(r, dict)]
    if not valid:
        return '<p class="note">No agent run records available.</p>'
    ordered = sorted(
        valid,
        key=lambda r: str(r.get("started_at_utc") or r.get("run_date") or ""),
        reverse=True,
    )
    parts = [
        '<div class="financials-runs-toolbar">',
        '<button type="button" id="financials-export-csv" class="btn-secondary">'
        "Export CSV</button>",
        "</div>",
        '<table id="financials-runs-table" class="sortable-table">',
        "<thead><tr>",
        '<th scope="col" class="sortable" data-sort="date" data-sort-type="date">Date</th>',
        '<th scope="col" class="sortable" data-sort="issue" data-sort-type="number">Issue</th>',
        '<th scope="col" class="sortable" data-sort="model" data-sort-type="text">Model</th>',
        '<th scope="col" class="sortable" data-sort="cost" data-sort-type="number">Cost (USD)</th>',
        "</tr></thead><tbody>",
    ]
    for row in ordered:
        issue = _issue_key(row)
        if issue is None:
            issue = row.get("issue", "")
        model = row.get("model_id") or row.get("model") or ""
        cost = float(row.get("actual_cost_usd", 0) or 0)
        date_raw = row.get("run_date") or str(row.get("started_at_utc") or "")[:10]
        parts.append(
            '<tr data-date="{}" data-issue="{}" data-model="{}" data-cost="{:.6f}">'
            "<td>{}</td><td>#{}</td><td>{}</td><td>${:.4f}</td></tr>".format(
                esc(date_raw),
                esc(issue),
                esc(model),
                cost,
                esc(date_raw),
                esc(issue),
                esc(model),
                cost,
            )
        )
    parts.append("</tbody></table>")
    return "\n".join(parts)


def site_enhancement_css():
    return """<style id="factory-site-enhancements">
:root {
  color-scheme: light dark;
  --fs-bg: #f7f7f9;
  --fs-surface: #ffffff;
  --fs-text: #1a1a1a;
  --fs-muted: #555d6b;
  --fs-border: #cfd4dd;
  --fs-header-bg: #1f2430;
  --fs-header-text: #ffffff;
  --fs-tab-bg: #2c3444;
  --fs-tab-text: #d7dce6;
  --fs-tab-active-bg: #ffffff;
  --fs-tab-active-text: #1f2430;
  --fs-th-bg: #e8ebf1;
  --fs-row-alt: #f0f2f6;
  --fs-pitch-bg: #eef4ff;
  --fs-note-bg: #fff4d6;
  --fs-accent: #3d5afe;
  --fs-accent-soft: #e8edff;
  --fs-shadow: 0 1px 2px rgba(31, 36, 48, 0.08);
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --fs-bg: #12151c;
    --fs-surface: #1a1f2b;
    --fs-text: #e8ebf1;
    --fs-muted: #a8b0bd;
    --fs-border: #343b4a;
    --fs-header-bg: #0d1017;
    --fs-header-text: #f0f2f6;
    --fs-tab-bg: #252b3a;
    --fs-tab-text: #c5ccd8;
    --fs-tab-active-bg: #3d4556;
    --fs-tab-active-text: #ffffff;
    --fs-th-bg: #252b3a;
    --fs-row-alt: #1f2433;
    --fs-pitch-bg: #1c2640;
    --fs-note-bg: #3a3218;
    --fs-accent: #8ea4ff;
    --fs-accent-soft: #2a3558;
    --fs-shadow: 0 1px 2px rgba(0, 0, 0, 0.35);
  }
}
:root[data-theme="dark"] {
  --fs-bg: #12151c;
  --fs-surface: #1a1f2b;
  --fs-text: #e8ebf1;
  --fs-muted: #a8b0bd;
  --fs-border: #343b4a;
  --fs-header-bg: #0d1017;
  --fs-header-text: #f0f2f6;
  --fs-tab-bg: #252b3a;
  --fs-tab-text: #c5ccd8;
  --fs-tab-active-bg: #3d4556;
  --fs-tab-active-text: #ffffff;
  --fs-th-bg: #252b3a;
  --fs-row-alt: #1f2433;
  --fs-pitch-bg: #1c2640;
  --fs-note-bg: #3a3218;
  --fs-accent: #8ea4ff;
  --fs-accent-soft: #2a3558;
  --fs-shadow: 0 1px 2px rgba(0, 0, 0, 0.35);
}
:root[data-theme="light"] {
  color-scheme: light;
}
body {
  background: var(--fs-bg);
  color: var(--fs-text);
}
.site-header {
  background: var(--fs-header-bg);
  color: var(--fs-header-text);
  box-shadow: var(--fs-shadow);
}
.site-header h1 { color: var(--fs-header-text); }
.tabs a {
  background: var(--fs-tab-bg);
  color: var(--fs-tab-text);
}
.tabs a.active {
  background: var(--fs-tab-active-bg);
  color: var(--fs-tab-active-text);
}
.site-footer {
  background: var(--fs-surface);
  color: var(--fs-muted);
  border-color: var(--fs-border);
}
th { background: var(--fs-th-bg); border-color: var(--fs-border); }
td { border-color: var(--fs-border); }
tr:nth-child(even) td { background: var(--fs-row-alt); }
.pitch { background: var(--fs-pitch-bg); border-color: var(--fs-border); }
.note, .placeholder, .loop-card, .card, .human-decides {
  background: var(--fs-surface);
  border-color: var(--fs-border);
  color: var(--fs-text);
}
.site-header-row {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  justify-content: space-between;
  gap: 0.75rem;
  margin-bottom: 0.75rem;
}
.site-header-row h1 { margin: 0; flex: 1 1 12rem; }
#theme-toggle {
  flex: 0 0 auto;
  border: 1px solid rgba(255, 255, 255, 0.25);
  background: rgba(255, 255, 255, 0.08);
  color: var(--fs-header-text);
  border-radius: 999px;
  padding: 0.35rem 0.85rem;
  font-size: 0.85rem;
  cursor: pointer;
}
#theme-toggle:hover { background: rgba(255, 255, 255, 0.16); }
#theme-toggle:focus-visible {
  outline: 2px solid var(--fs-accent);
  outline-offset: 2px;
}
.quickstart-intro { color: var(--fs-muted); margin-top: 0; }
.codeblock-wrap {
  position: relative;
  margin: 0.75rem 0 1rem;
  border: 1px solid var(--fs-border);
  border-radius: 0.35rem;
  background: var(--fs-surface);
  box-shadow: var(--fs-shadow);
}
.codeblock {
  margin: 0;
  padding: 0.75rem 4.5rem 0.75rem 1rem;
  overflow-x: auto;
  font-size: 0.9rem;
}
.codeblock code { background: transparent; padding: 0; }
.copy-btn, .btn-secondary, .filter-pill {
  font: inherit;
  cursor: pointer;
  border-radius: 0.3rem;
  border: 1px solid var(--fs-border);
  background: var(--fs-surface);
  color: var(--fs-text);
}
.copy-btn {
  position: absolute;
  top: 0.5rem;
  right: 0.5rem;
  padding: 0.2rem 0.55rem;
  font-size: 0.75rem;
}
.copy-btn:hover, .btn-secondary:hover, .filter-pill:hover {
  border-color: var(--fs-accent);
}
.copy-btn.is-copied { border-color: #2e7d32; color: #2e7d32; }
.financials-runs-toolbar { margin: 0.5rem 0 0.75rem; }
.btn-secondary {
  padding: 0.4rem 0.85rem;
  font-size: 0.9rem;
  background: var(--fs-accent-soft);
  border-color: var(--fs-accent);
}
.backlog-filter {
  margin: 0.75rem 0 1rem;
  padding: 0.75rem 1rem;
  border: 1px solid var(--fs-border);
  border-radius: 0.35rem;
  background: var(--fs-surface);
  box-shadow: var(--fs-shadow);
}
.backlog-search {
  width: 100%;
  max-width: 24rem;
  padding: 0.45rem 0.6rem;
  border: 1px solid var(--fs-border);
  border-radius: 0.3rem;
  background: var(--fs-bg);
  color: var(--fs-text);
  font: inherit;
}
.backlog-search-label {
  display: block;
  font-size: 0.85rem;
  color: var(--fs-muted);
  margin-bottom: 0.35rem;
}
.filter-pills {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4rem;
  margin: 0.75rem 0 0.35rem;
}
.filter-pill {
  padding: 0.3rem 0.7rem;
  font-size: 0.85rem;
}
.filter-pill.is-active {
  background: var(--fs-accent-soft);
  border-color: var(--fs-accent);
  font-weight: 600;
}
.backlog-filter-count {
  margin: 0.35rem 0 0;
  font-size: 0.85rem;
  color: var(--fs-muted);
}
.sortable-table th.sortable {
  cursor: pointer;
  user-select: none;
}
.sortable-table th.sortable::after {
  content: " \\2195";
  font-size: 0.75rem;
  color: var(--fs-muted);
}
.sortable-table th.sortable[data-sort-dir="asc"]::after { content: " \\2191"; }
.sortable-table th.sortable[data-sort-dir="desc"]::after { content: " \\2193"; }
.dbt-filter {
  margin: 0.75rem 0 1rem;
  padding: 0.75rem 1rem;
  border: 1px solid var(--fs-border);
  border-radius: 0.35rem;
  background: var(--fs-surface);
  box-shadow: var(--fs-shadow);
}
.dbt-search {
  width: 100%;
  max-width: 24rem;
  padding: 0.45rem 0.6rem;
  border: 1px solid var(--fs-border);
  border-radius: 0.3rem;
  background: var(--fs-bg);
  color: var(--fs-text);
  font: inherit;
}
.dbt-filter-toolbar {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
  margin-top: 0.5rem;
}
.dbt-filter-count { font-size: 0.85rem; color: var(--fs-muted); margin: 0.35rem 0 0; }
.dbt-meta-badge {
  display: inline-block;
  font-size: 0.8rem;
  padding: 0.1rem 0.45rem;
  border-radius: 0.25rem;
  border: 1px solid var(--fs-border);
  background: var(--fs-accent-soft);
  color: var(--fs-text);
}
#dbt-models-table tbody tr.is-filtered-out { display: none; }
.dbt-model.is-filtered-out { display: none; }
.dbt-lineage .dbt-lineage-node { cursor: pointer; }
.dbt-lineage.is-muted .dbt-lineage-node,
.dbt-lineage.is-muted .dbt-lineage-edge { opacity: 0.22; }
.dbt-lineage.is-muted .dbt-lineage-node.is-lineage-focus,
.dbt-lineage.is-muted .dbt-lineage-node.is-lineage-related,
.dbt-lineage.is-muted .dbt-lineage-edge.is-lineage-focus { opacity: 1; }
.dbt-lineage-node.is-lineage-focus rect { stroke: var(--fs-accent); stroke-width: 2.2; }
.dbt-lineage-node.is-lineage-related rect { stroke: var(--fs-accent); stroke-width: 1.6; }
.config-summary.card {
  margin: 1rem 0 1.25rem;
  padding: 1rem 1.15rem;
  border-radius: 0.35rem;
  box-shadow: var(--fs-shadow);
}
.config-summary h3 { margin: 0 0 0.75rem; font-size: 1.05rem; }
.config-dl { margin: 0; display: grid; grid-template-columns: 9rem 1fr; gap: 0.45rem 1rem; }
.config-dl dt { margin: 0; font-weight: 600; color: var(--fs-muted); }
.config-dl dd { margin: 0; }
.note-inline { color: var(--fs-muted); font-style: italic; }
.config-tier-list { margin: 0.25rem 0 0; padding-left: 1.25rem; }
.factory-loop-interactive { margin: 0.75rem 0 1.5rem; }
.loop-stage-bar {
  display: flex;
  flex-wrap: wrap;
  gap: 0.35rem;
  margin-bottom: 0.75rem;
}
.loop-stage-btn {
  font: inherit;
  font-size: 0.82rem;
  padding: 0.35rem 0.65rem;
  border-radius: 999px;
  border: 1px solid var(--fs-border);
  background: var(--fs-surface);
  color: var(--fs-text);
  cursor: pointer;
}
.loop-stage-btn:hover { border-color: var(--fs-accent); }
.loop-stage-btn:focus-visible {
  outline: 2px solid var(--fs-accent);
  outline-offset: 2px;
}
.loop-stage-btn.is-active {
  background: var(--fs-accent-soft);
  border-color: var(--fs-accent);
  font-weight: 600;
}
.loop-stage-detail {
  border: 1px solid var(--fs-border);
  border-radius: 0.35rem;
  padding: 0.85rem 1rem;
  background: var(--fs-surface);
  box-shadow: var(--fs-shadow);
  margin-bottom: 0.85rem;
}
.loop-stage-detail h3 { margin: 0 0 0.5rem; font-size: 1.05rem; }
.loop-stage-detail dl { margin: 0.35rem 0 0; }
.loop-stage-detail dt { font-weight: 600; margin-top: 0.35rem; }
.loop-stage-detail dd { margin: 0.15rem 0 0 0; color: var(--fs-text); }
.loop-stage-placeholder { margin: 0; color: var(--fs-muted); }
nav.tabs a[role="tab"]:focus-visible {
  outline: 2px solid var(--fs-accent);
  outline-offset: 2px;
}
@media print {
  #theme-toggle,
  .copy-btn,
  .btn-secondary,
  .backlog-filter,
  .dbt-filter,
  .filter-pills,
  .loop-stage-bar,
  .financials-runs-toolbar { display: none !important; }
  body { background: #fff; color: #000; }
  .site-header {
    background: #fff;
    color: #000;
    box-shadow: none;
    border-bottom: 1px solid #ccc;
  }
  .site-header h1 { color: #000; }
  .tabs a {
    background: #eee;
    color: #000;
    border: 1px solid #bbb;
  }
  .tabs a.active { background: #fff; font-weight: 700; }
  .content { max-width: none; margin: 0; padding: 0.5rem 0; }
  table, .card, .loop-stage-detail, .config-summary {
    break-inside: avoid;
    page-break-inside: avoid;
  }
  a[href]::after { content: none !important; }
}
</style>"""


def theme_toggle_markup():
    return (
        '<button type="button" id="theme-toggle" aria-pressed="false" '
        'title="Toggle light and dark theme">Theme</button>'
    )


def site_enhancement_script():
    return """<script>
(function () {
  var THEME_KEY = "factory-site-theme";
  var root = document.documentElement;
  var themeBtn = document.getElementById("theme-toggle");
  function systemDark() {
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  }
  function isDark(theme) {
    if (theme === "dark") return true;
    if (theme === "light") return false;
    return systemDark();
  }
  function applyTheme(theme) {
    if (theme === "light" || theme === "dark") {
      root.setAttribute("data-theme", theme);
    } else {
      root.removeAttribute("data-theme");
    }
    if (!themeBtn) return;
    var dark = isDark(theme || null);
    themeBtn.setAttribute("aria-pressed", dark ? "true" : "false");
    themeBtn.textContent = dark ? "Light mode" : "Dark mode";
  }
  var saved = null;
  try { saved = localStorage.getItem(THEME_KEY); } catch (e) {}
  if (saved === "light" || saved === "dark") applyTheme(saved);
  else applyTheme(null);
  if (themeBtn) {
    themeBtn.addEventListener("click", function () {
      var current = root.getAttribute("data-theme");
      var dark = isDark(current);
      var next = dark ? "light" : "dark";
      try { localStorage.setItem(THEME_KEY, next); } catch (e) {}
      applyTheme(next);
    });
  }

  document.querySelectorAll(".copy-btn").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var id = btn.getAttribute("data-copy-source");
      var el = id ? document.getElementById(id) : null;
      if (!el) return;
      var text = el.textContent || "";
      function done(ok) {
        if (!ok) return;
        btn.classList.add("is-copied");
        var prev = btn.textContent;
        btn.textContent = "Copied";
        setTimeout(function () {
          btn.textContent = prev;
          btn.classList.remove("is-copied");
        }, 1400);
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () { done(true); }).catch(function () {
          done(fallbackCopy(text));
        });
      } else {
        done(fallbackCopy(text));
      }
    });
  });
  function fallbackCopy(text) {
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "absolute";
    ta.style.left = "-9999px";
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand("copy"); } catch (e) {}
    document.body.removeChild(ta);
    return ok;
  }

  var backlogBar = document.getElementById("backlog-filter-bar");
  if (backlogBar) {
    var searchInput = document.getElementById("backlog-search");
    var countEl = document.getElementById("backlog-filter-count");
    var rows = Array.prototype.slice.call(
      document.querySelectorAll("#backlog-issues-table .backlog-issue-row")
    );
    var activeFilter = "all";
    function rowMatchesFilter(row) {
      var prio = row.getAttribute("data-priority") || "none";
      var risk = row.getAttribute("data-risk") || "unlabeled";
      if (activeFilter === "high-priority") return prio === "high";
      if (activeFilter === "high-risk") return risk === "high";
      if (activeFilter === "unlabeled") {
        return prio === "none" || risk === "unlabeled";
      }
      return true;
    }
    function applyBacklogFilter() {
      var q = (searchInput && searchInput.value || "").trim().toLowerCase();
      var shown = 0;
      rows.forEach(function (row) {
        var blob = (row.getAttribute("data-search") || "").toLowerCase();
        var match = rowMatchesFilter(row) && (!q || blob.indexOf(q) !== -1);
        row.hidden = !match;
        if (match) shown += 1;
      });
      if (countEl) {
        countEl.textContent = "Showing " + shown + " of " + rows.length;
      }
    }
    backlogBar.querySelectorAll(".filter-pill").forEach(function (pill) {
      pill.addEventListener("click", function () {
        activeFilter = pill.getAttribute("data-filter") || "all";
        backlogBar.querySelectorAll(".filter-pill").forEach(function (p) {
          var on = p === pill;
          p.classList.toggle("is-active", on);
          p.setAttribute("aria-pressed", on ? "true" : "false");
        });
        applyBacklogFilter();
      });
    });
    if (searchInput) {
      searchInput.addEventListener("input", applyBacklogFilter);
    }
    applyBacklogFilter();
  }

  var runsTable = document.getElementById("financials-runs-table");
  var exportBtn = document.getElementById("financials-export-csv");
  function csvEscape(value) {
    var s = String(value == null ? "" : value);
    if (/[",\\n\\r]/.test(s)) {
      return '"' + s.replace(/"/g, '""') + '"';
    }
    return s;
  }
  function exportRunsCsv() {
    if (!runsTable) return;
    var header = ["date", "issue", "model", "cost_usd"];
    var lines = [header.join(",")];
    runsTable.querySelectorAll("tbody tr").forEach(function (row) {
      lines.push([
        csvEscape(row.getAttribute("data-date") || ""),
        csvEscape(row.getAttribute("data-issue") || ""),
        csvEscape(row.getAttribute("data-model") || ""),
        csvEscape(row.getAttribute("data-cost") || ""),
      ].join(","));
    });
    var blob = new Blob([lines.join("\\n") + "\\n"], { type: "text/csv;charset=utf-8" });
    var url = URL.createObjectURL(blob);
    var a = document.createElement("a");
    a.href = url;
    a.download = "factory-agent-runs.csv";
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }
  if (exportBtn) {
    exportBtn.addEventListener("click", exportRunsCsv);
  }
  if (runsTable) {
    runsTable.querySelectorAll("th.sortable").forEach(function (th) {
      th.addEventListener("click", function () {
        var key = th.getAttribute("data-sort");
        var type = th.getAttribute("data-sort-type") || "text";
        var tbody = runsTable.querySelector("tbody");
        if (!tbody || !key) return;
        var dir = th.getAttribute("data-sort-dir") === "asc" ? "desc" : "asc";
        runsTable.querySelectorAll("th.sortable").forEach(function (h) {
          h.removeAttribute("data-sort-dir");
        });
        th.setAttribute("data-sort-dir", dir);
        var mult = dir === "asc" ? 1 : -1;
        var trs = Array.prototype.slice.call(tbody.querySelectorAll("tr"));
        trs.sort(function (a, b) {
          var av = a.getAttribute("data-" + key) || "";
          var bv = b.getAttribute("data-" + key) || "";
          if (type === "number") {
            return (parseFloat(av) - parseFloat(bv)) * mult;
          }
          if (type === "date") {
            return String(av).localeCompare(String(bv)) * mult;
          }
          return String(av).localeCompare(String(bv), undefined, { sensitivity: "base" }) * mult;
        });
        trs.forEach(function (tr) { tbody.appendChild(tr); });
      });
    });
  }

  var dbtFilter = document.getElementById("dbt-filter-bar");
  var dbtSvg = document.querySelector("svg.dbt-lineage");
  var dbtGraphEl = document.getElementById("dbt-lineage-graph");
  var dbtClear = document.getElementById("dbt-lineage-clear");
  var dbtSearch = document.getElementById("dbt-model-search");
  var dbtCount = document.getElementById("dbt-filter-count");
  var dbtGraph = null;
  if (dbtGraphEl && dbtGraphEl.textContent) {
    try { dbtGraph = JSON.parse(dbtGraphEl.textContent); } catch (e) {}
  }
  function dbtApplySearch() {
    if (!dbtFilter) return;
    var q = (dbtSearch && dbtSearch.value || "").trim().toLowerCase();
    var rows = dbtFilter.querySelectorAll(".dbt-model-row");
    var sections = document.querySelectorAll(".dbt-model");
    var shown = 0;
    rows.forEach(function (row) {
      var blob = (row.getAttribute("data-search") || "").toLowerCase();
      var match = !q || blob.indexOf(q) !== -1;
      row.classList.toggle("is-filtered-out", !match);
      if (match) shown += 1;
    });
    sections.forEach(function (sec) {
      var blob = (sec.getAttribute("data-search") || "").toLowerCase();
      var match = !q || blob.indexOf(q) !== -1;
      sec.classList.toggle("is-filtered-out", !match);
    });
    if (dbtCount) {
      dbtCount.textContent = "Showing " + shown + " of " + rows.length + " models";
    }
  }
  function dbtClearLineage() {
    if (!dbtSvg) return;
    dbtSvg.classList.remove("is-muted");
    dbtSvg.querySelectorAll(".is-lineage-focus, .is-lineage-related").forEach(function (el) {
      el.classList.remove("is-lineage-focus", "is-lineage-related");
    });
    dbtSvg.querySelectorAll(".dbt-lineage-edge").forEach(function (el) {
      el.classList.remove("is-lineage-focus");
    });
  }
  function dbtHighlightLineage(modelName) {
    if (!dbtSvg || !dbtGraph || !modelName) return;
  dbtClearLineage();
    var meta = (dbtGraph.nodes || {})[modelName];
    if (!meta) return;
    var related = {};
    related[modelName] = true;
    (dbtGraph.upstream[modelName] || []).forEach(function (n) { related[n] = true; });
    (dbtGraph.downstream[modelName] || []).forEach(function (n) { related[n] = true; });
    dbtSvg.classList.add("is-muted");
    dbtSvg.querySelectorAll(".dbt-lineage-node").forEach(function (g) {
      var name = g.getAttribute("data-model") || "";
      if (name === modelName) g.classList.add("is-lineage-focus");
      else if (related[name]) g.classList.add("is-lineage-related");
    });
    dbtSvg.querySelectorAll(".dbt-lineage-edge").forEach(function (line) {
      var from = line.getAttribute("data-from") || "";
      var to = line.getAttribute("data-to") || "";
      if (from === modelName || to === modelName) line.classList.add("is-lineage-focus");
      else if (related[from] && related[to]) line.classList.add("is-lineage-focus");
    });
  }
  if (dbtSearch) dbtSearch.addEventListener("input", dbtApplySearch);
  if (dbtFilter) dbtApplySearch();
  if (dbtSvg && dbtGraph) {
    dbtSvg.querySelectorAll(".dbt-lineage-node").forEach(function (g) {
      g.addEventListener("click", function () {
        dbtHighlightLineage(g.getAttribute("data-model") || "");
      });
    });
  }
  if (dbtClear) {
    dbtClear.addEventListener("click", dbtClearLineage);
  }

  var tabNav = document.querySelector('nav.tabs[role="tablist"]');
  if (tabNav) {
    var headerTabs = Array.prototype.slice.call(
      tabNav.querySelectorAll('a[role="tab"]')
    );
    tabNav.addEventListener("keydown", function (ev) {
      if (ev.key !== "ArrowLeft" && ev.key !== "ArrowRight") return;
      var idx = headerTabs.indexOf(document.activeElement);
      if (idx < 0) return;
      ev.preventDefault();
      var next = ev.key === "ArrowRight" ? idx + 1 : idx - 1;
      if (next < 0) next = headerTabs.length - 1;
      if (next >= headerTabs.length) next = 0;
      headerTabs[next].focus();
    });
  }

  var loopRoot = document.getElementById("factory-loop-interactive");
  if (loopRoot) {
    var dataEl = document.getElementById("loop-stages-data");
    var detail = document.getElementById("loop-stage-detail");
    var stageMap = {};
    if (dataEl && dataEl.textContent) {
      try {
        (JSON.parse(dataEl.textContent) || []).forEach(function (s) {
          if (s && s.id) stageMap[s.id] = s;
        });
      } catch (e) {}
    }
    var loopButtons = Array.prototype.slice.call(
      loopRoot.querySelectorAll(".loop-stage-btn")
    );
    function loopDetailHtml(stage) {
      return (
        "<h3>" + stage.label + "</h3>" +
        "<p>" + stage.description + "</p>" +
        "<dl><dt>Inputs</dt><dd>" + stage.inputs + "</dd>" +
        "<dt>Outputs</dt><dd>" + stage.outputs + "</dd>" +
        "<dt>Guardrails</dt><dd>" + stage.guardrails + "</dd></dl>"
      );
    }
    function selectLoopStage(btn) {
      loopButtons.forEach(function (b) {
        var on = b === btn;
        b.classList.toggle("is-active", on);
        b.setAttribute("aria-selected", on ? "true" : "false");
        b.tabIndex = on ? 0 : -1;
      });
      var sid = btn.getAttribute("data-stage");
      var stage = sid ? stageMap[sid] : null;
      if (stage && detail) {
        detail.innerHTML = loopDetailHtml(stage);
      }
    }
    loopButtons.forEach(function (btn, index) {
      btn.addEventListener("click", function () { selectLoopStage(btn); });
      btn.addEventListener("keydown", function (ev) {
        if (ev.key === "Enter" || ev.key === " ") {
          ev.preventDefault();
          selectLoopStage(btn);
          return;
        }
        if (ev.key !== "ArrowLeft" && ev.key !== "ArrowRight") return;
        ev.preventDefault();
        var next = ev.key === "ArrowRight" ? index + 1 : index - 1;
        if (next < 0) next = loopButtons.length - 1;
        if (next >= loopButtons.length) next = 0;
        loopButtons[next].focus();
        selectLoopStage(loopButtons[next]);
      });
    });
    if (loopButtons.length) selectLoopStage(loopButtons[0]);
  }
})();
</script>"""


def enhance_page_html(html, active_filename="index.html"):
    """Inject shared offline UX (theme, filters, export, copy) into rendered HTML."""
    stem = _page_stem(active_filename)
    panel_id = "panel-{}".format(stem)
    tab_id = "tab-{}".format(stem)
    if "</head>" in html:
        html = html.replace("</head>", site_enhancement_css() + "\n</head>", 1)
    html = html.replace(
        '<nav class="tabs" aria-label="Site tabs">',
        '<nav class="tabs" role="tablist" aria-label="Site tabs">',
        1,
    )
    html = html.replace(
        "<main class=\"content\">",
        '<main class="content" id="{}" role="tabpanel" aria-labelledby="{}" '
        'tabindex="0">'.format(panel_id, tab_id),
        1,
    )
    marker = '<header class="site-header">\n  <h1>'
    if marker in html:
        html = html.replace(
            marker,
            '<header class="site-header">\n  <div class="site-header-row">\n  <h1>',
            1,
        )
        html = html.replace(
            "</h1>\n  <nav class=\"tabs\"",
            "</h1>\n  " + theme_toggle_markup() + '\n  </div>\n  <nav class="tabs"',
            1,
        )
    html = html.replace("</body>", site_enhancement_script() + "\n</body>", 1)
    return html


def _format_when_value(value):
    if isinstance(value, list):
        bits = []
        for item in value:
            if isinstance(item, dict):
                bits.append(
                    ", ".join(
                        "{}={}".format(k, item[k]) for k in sorted(item.keys())
                    )
                )
            else:
                bits.append(str(item))
        return "[{}]".format(" | ".join(bits))
    if isinstance(value, dict):
        return "{{{}}}".format(
            ", ".join("{}={}".format(k, v) for k, v in sorted(value.items()))
        )
    return str(value)


def when_text(when):
    if not when:
        return "(always)"
    if isinstance(when, dict):
        return ", ".join(
            "{}={}".format(k, _format_when_value(v))
            for k, v in sorted(when.items())
        )
    return str(when)


def load_mode(repo_root):
    path = Path(repo_root) / ".factory" / "mode.yml"
    if not path.is_file():
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    except (OSError, yaml.YAMLError):
        return None
    mode = data.get("mode")
    return str(mode) if mode is not None else None


def _json_script_payload(data):
    payload = json.dumps(data, separators=(",", ":"), ensure_ascii=True)
    return payload.replace("</", "<\\/")


def render_active_factory_config(repo_root, models_data):
    """Live summary from mode.yml, models.yaml, and factory/budget.yml when present."""
    parts = [
        "<h2>Active Factory Configuration</h2>",
        '<div id="active-factory-config" class="config-summary card">',
        "<h3>Live configuration</h3>",
        '<dl class="config-dl">',
    ]

    mode_path = Path(repo_root) / ".factory" / "mode.yml"
    if mode_path.is_file():
        mode = load_mode(repo_root)
        parts.append(
            "<dt>Factory mode</dt><dd>{}</dd>".format(
                esc(mode if mode else "(unset in mode.yml)")
            )
        )
    else:
        parts.append(
            '<dt>Factory mode</dt><dd class="note-inline">'
            ".factory/mode.yml not found</dd>"
        )

    models_path = Path(repo_root) / ".factory" / "models.yaml"
    models = models_data.get("models") if models_data else None
    if models_path.is_file() and models:
        tier_lines = []
        for entry in models:
            model_id = entry.get("id", "")
            if not model_id:
                continue
            status = entry.get("status") or "unspecified"
            price_in = entry.get("price_in_per_mtok")
            price_out = entry.get("price_out_per_mtok")
            price_bit = ""
            if price_in is not None and price_out is not None:
                price_bit = " · ${}/{} in/out per Mtok".format(price_in, price_out)
            tier_lines.append("{} ({}){}".format(model_id, status, price_bit))
        if tier_lines:
            parts.append(
                "<dt>Model tiers</dt><dd><ul class=\"config-tier-list\">"
            )
            for line in tier_lines:
                parts.append("<li>{}</li>".format(esc(line)))
            parts.append("</ul></dd>")
        else:
            parts.append(
                '<dt>Model tiers</dt><dd class="note-inline">'
                "models key empty in models.yaml</dd>"
            )
        rules = models_data.get("routing_rules") or []
        if rules:
            parts.append(
                "<dt>Routing rules</dt><dd>{} active rules "
                "(first match wins)</dd>".format(len(rules))
            )
    else:
        parts.append(
            '<dt>Model tiers</dt><dd class="note-inline">'
            ".factory/models.yaml not found or has no models list</dd>"
        )

    budget_path = Path(repo_root) / "factory" / "budget.yml"
    budget = _load_budget(repo_root)
    if budget_path.is_file() and budget:
        weekly = budget.get("weekly_usd")
        monthly = budget.get("monthly_usd")
        weekly_s = (
            format_currency(float(weekly))
            if weekly is not None
            else "not set"
        )
        monthly_s = (
            format_currency(float(monthly))
            if monthly is not None
            else "not set"
        )
        parts.append(
            "<dt>Budget caps</dt><dd>Weekly {} · Monthly {}</dd>".format(
                esc(weekly_s), esc(monthly_s)
            )
        )
    else:
        parts.append(
            '<dt>Budget caps</dt><dd class="note-inline">'
            "factory/budget.yml not found</dd>"
        )

    parts.append("</dl></div>")
    return "\n".join(parts)


def render_interactive_factory_loop():
    """Nine-stage loop strip with inspectable detail panel and inline SVG."""
    parts = [
        '<div id="factory-loop-interactive" class="factory-loop-interactive">',
        '<div class="loop-stage-bar" role="tablist" aria-label="Factory loop stages">',
    ]
    for stage in FACTORY_LOOP_STAGES:
        parts.append(
            '<button type="button" class="loop-stage-btn" role="tab" '
            'id="loop-stage-{}" data-stage="{}" aria-selected="false" '
            'aria-controls="loop-stage-detail" tabindex="-1">{}</button>'.format(
                esc(stage["id"]),
                esc(stage["id"]),
                esc(stage["label"]),
            )
        )
    parts.append("</div>")
    parts.append(
        '<div id="loop-stage-detail" class="loop-stage-detail" role="tabpanel" '
        'aria-live="polite" tabindex="0">'
        '<p class="loop-stage-placeholder">Select a stage to inspect its '
        "description, inputs, outputs, and guardrails.</p></div>"
    )
    parts.append(
        '<script type="application/json" id="loop-stages-data">'
        + _json_script_payload(list(FACTORY_LOOP_STAGES))
        + "</script>"
    )
    parts.append(loop_svg())
    parts.append("</div>")
    return "\n".join(parts)


def architecture_html(repo_root, models_data, factory_md):
    parts = []

    # Live config summary from repo YAML when present.
    parts.append(render_active_factory_config(repo_root, models_data))

    # Newcomer pitch.
    parts.append(newcomer_pitch())

    # Interactive nine-stage loop with inline SVG.
    parts.append("<h2>The loop</h2>")
    parts.append(render_interactive_factory_loop())

    # Loop step cards.
    parts.append("<h2>Loop steps</h2>")
    loop = section_from_markdown(factory_md, "Loop")
    if loop is None:
        parts.append('<p class="note">{}</p>'.format(esc(SECTION_NOT_FOUND + " (Loop)")))
    else:
        steps = numbered_steps(loop)
        if steps:
            parts.append(render_loop_cards(steps))
        else:
            parts.append('<p class="note">{}</p>'.format(esc(SECTION_NOT_FOUND + " (Loop)")))

    # What a human decides.
    parts.append(human_decides_box())

    # Depth links.
    parts.append(depth_links())

    # Offline quickstart commands with copy controls.
    parts.append(architecture_quickstart())

    # Roles table.
    parts.append("<h2>Roles</h2>")
    roles = section_from_markdown(factory_md, "Roles")
    if roles is None:
        parts.append('<p class="note">{}</p>'.format(esc(SECTION_NOT_FOUND + " (Roles)")))
    else:
        rendered = render_table(parse_markdown_table(roles), agnostic=True)
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
        rendered = render_table(parse_markdown_table(merge), agnostic=True)
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
        parts.append(render_table(rows, agnostic=True))

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
        parts.append(render_table(rows, agnostic=True))

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
        parts.append(render_table(rows, agnostic=True))

    return "\n".join(parts)


def placeholder_html(tab_name):
    return (
        "<h2>{}</h2>\n".format(esc(tab_name))
        + '<div class="placeholder"><p>This tab is not available yet. It will be '
        'filled in by a later sub-issue.</p></div>'
    )


def _load_marts(data_dir):
    """Load mart JSON files into a dict of row lists."""
    marts_dir = Path(data_dir) / "marts"
    if not marts_dir.is_dir():
        return None, {}
    if not any(marts_dir.glob("*.json")):
        return marts_dir, {}

    marts = {}
    for mart_file in sorted(marts_dir.glob("*.json")):
        try:
            with open(mart_file, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            marts[mart_file.stem] = []
            continue
        if isinstance(data, list):
            marts[mart_file.stem] = [r for r in data if isinstance(r, dict)]
        elif isinstance(data, dict) and "rows" in data:
            rows = data["rows"]
            marts[mart_file.stem] = (
                [r for r in rows if isinstance(r, dict)]
                if isinstance(rows, list)
                else []
            )
        else:
            marts[mart_file.stem] = []
    return marts_dir, marts


def _load_budget(repo_root):
    budget_path = Path(repo_root) / "factory" / "budget.yml"
    try:
        with open(budget_path, encoding="utf-8") as fh:
            budget_data = yaml.safe_load(fh) or {}
    except (OSError, yaml.YAMLError):
        budget_data = {}
    return budget_data


def _financials_as_of(as_of_utc, rpt_run_rate):
    if as_of_utc:
        try:
            return datetime.datetime.strptime(
                as_of_utc[:19], "%Y-%m-%d %H:%M:%S"
            ).date()
        except ValueError:
            pass
    if rpt_run_rate:
        row = rpt_run_rate[0]
        if isinstance(row, dict):
            as_of = row.get("as_of_date")
            if as_of:
                try:
                    return datetime.date.fromisoformat(str(as_of)[:10])
                except ValueError:
                    pass
    return datetime.date(2026, 11, 11)


def _issue_key(row):
    if not isinstance(row, dict):
        return None
    num = row.get("issue_number")
    if num is None:
        num = row.get("issue")
    return num


def _assert_non_negative_spend(collection, name):
    spend_keys = (
        "spend_usd",
        "mtd_variable_usd",
        "actual_cost_usd",
        "predicted_cost_usd",
        "predicted_usd",
        "actual_usd",
        "total_cost_usd",
        "total_actual_cost_usd",
    )
    for item in collection:
        if not isinstance(item, dict):
            raise ValueError(f"Expected dict in {name}, got {type(item)}: {item}")
        for key in spend_keys:
            if key not in item:
                continue
            value = item[key]
            if isinstance(value, (int, float)) and value < 0:
                raise ValueError(f"Negative value in {name}: {key}={value}")


def _compliance_summary_rows(rpt_issue_target_compliance, issue_target_usd, issue_cap_usd):
    """Return (under_target_pct, over_cap_count) from mart rows or a summary row."""
    if not rpt_issue_target_compliance:
        return None, None
    first = rpt_issue_target_compliance[0]
    if isinstance(first, dict) and "under_target_pct" in first:
        return (
            float(first.get("under_target_pct", 0)),
            int(first.get("over_cap_count", 0)),
        )

    compliance_by_issue = {}
    for row in rpt_issue_target_compliance:
        if not isinstance(row, dict):
            continue
        issue = _issue_key(row)
        if issue is None:
            continue
        compliance_by_issue[issue] = row

    if not compliance_by_issue:
        return None, None

    under_target = sum(
        1 for row in compliance_by_issue.values() if row.get("under_target")
    )
    total = len(compliance_by_issue)
    under_target_pct = (under_target / total * 100.0) if total else 0.0
    over_cap_count = sum(
        1 for row in compliance_by_issue.values() if not row.get("under_cap", True)
    )
    return under_target_pct, over_cap_count


def _prediction_fields(row):
    pred = row.get("predicted_cost_usd")
    if pred is None:
        pred = row.get("predicted_usd")
    actual = row.get("actual_cost_usd")
    if actual is None:
        actual = row.get("actual_usd")
    error_pct = row.get("error_pct")
    if error_pct is not None:
        abs_error = abs(float(error_pct))
    elif pred is not None and actual is not None:
        denom = float(pred) if float(pred) else 1.0
        abs_error = abs(float(actual) - float(pred)) / denom * 100.0
    else:
        abs_error = row.get("absolute_error")
        if abs_error is not None:
            abs_error = abs(float(abs_error))
    return pred, actual, abs_error


def _format_utc_chicago(ts):
    if not ts:
        return "", ""
    try:
        dt = datetime.datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    except ValueError:
        return esc(str(ts)), esc(str(ts))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    utc_s = dt.astimezone(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    try:
        from zoneinfo import ZoneInfo

        chicago = dt.astimezone(ZoneInfo("America/Chicago")).strftime(
            "%Y-%m-%d %H:%M:%S %Z"
        )
    except Exception:
        chicago = utc_s
    return esc(utc_s), esc(chicago)


def _card(class_warn, title, amount_html, detail_html):
    warn_cls = " warn" if class_warn else ""
    return (
        f'<div class="card{warn_cls}">'
        f"<h3>{esc(title)}</h3>"
        f'<p class="amount">{amount_html}</p>'
        f"<p>{detail_html}</p>"
        "</div>"
    )


def _default_duckdb_path(repo_root):
    return Path(repo_root) / "factory" / "dbt" / "target" / "factory.duckdb"


def _duckdb_query_mart(repo_root, table_name):
    """Return mart rows as dicts from DuckDB when the table exists; else None."""
    db_path = _default_duckdb_path(repo_root)
    if not db_path.is_file():
        return None
    try:
        import duckdb
    except ImportError:
        return None

    con = None
    try:
        con = duckdb.connect(str(db_path), read_only=True)
        exists = con.sql(
            "select 1 from information_schema.tables "
            "where table_schema = 'main' and table_name = ? limit 1",
            [table_name],
        ).fetchone()
        if not exists:
            try:
                con.sql(f"select * from {table_name} limit 0")
            except Exception:
                return None
        rel = con.sql(f"select * from {table_name}")
        columns = [d[0] for d in rel.description]
        out = []
        for row in rel.fetchall():
            item = {}
            for col, val in zip(columns, row):
                if isinstance(val, (datetime.date, datetime.datetime)):
                    item[col] = val.isoformat()
                else:
                    item[col] = val
            out.append(item)
        return out
    except Exception:
        return None
    finally:
        if con is not None:
            con.close()


def _mart_rows(marts, repo_root, name):
    """Prefer exported JSON marts; fall back to a live DuckDB read."""
    rows = marts.get(name)
    if rows:
        return rows
    queried = _duckdb_query_mart(repo_root, name)
    return queried if queried is not None else []


def _compute_mart_spend_by_work_type(agent_rows):
    """Derive mart_spend_by_work_type from fct_agent_runs when JSON/DuckDB are absent."""
    path = Path(__file__).with_name("factory-site-data.py")
    spec = importlib.util.spec_from_file_location("factory_site_data", path)
    if spec is None or spec.loader is None:
        return []
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.compute_mart_spend_by_work_type(agent_rows)


def _fmt_fin_currency(value):
    if value is None:
        return "—"
    try:
        return f"${float(value):,.4f}"
    except (TypeError, ValueError):
        return esc(str(value))


def _fmt_fin_pct(value):
    if value is None:
        return "—"
    try:
        return f"{float(value):.1f}%"
    except (TypeError, ValueError):
        return esc(str(value))


def _render_monthly_cfo_table(rows):
    if not rows:
        return '<p class="note">No monthly CFO mart data available.</p>'
    parts = [
        '<table id="monthly-cfo-table">',
        "<thead><tr>",
        "<th>Month</th><th>Distinct issues</th><th>Avg cost / issue</th>",
        "<th>Pass rate</th><th>Budget used</th>",
        "</tr></thead><tbody>",
    ]
    for row in sorted(rows, key=lambda r: str(r.get("month_start", ""))):
        month = str(row.get("month_start", ""))[:10] or "—"
        parts.append(
            "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>".format(
                esc(month),
                esc(row.get("distinct_issues", "—")),
                esc(_fmt_fin_currency(row.get("avg_cost_per_issue_usd"))),
                esc(_fmt_fin_pct(row.get("pass_rate_pct"))),
                esc(_fmt_fin_pct(row.get("budget_used_pct"))),
            )
        )
    parts.append("</tbody></table>")
    return "\n".join(parts)


def _render_model_efficiency_table(rows):
    if not rows:
        return '<p class="note">No model efficiency mart data available.</p>'
    parts = [
        '<table id="model-efficiency-table">',
        "<thead><tr>",
        "<th>Model</th><th>Harness</th><th>Provider</th><th>Runs</th>",
        "<th>Pass rate</th><th>Total cost</th><th>Avg cost</th>",
        "<th>Cost / passed run</th>",
        "</tr></thead><tbody>",
    ]
    sorted_rows = sorted(
        rows,
        key=lambda r: (
            -float(r.get("total_cost_usd") or 0),
            str(r.get("model", "")),
            str(r.get("harness", "")),
        ),
    )
    for row in sorted_rows:
        parts.append(
            "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td>"
            "<td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>".format(
                esc(row.get("model", "—")),
                esc(row.get("harness", "—")),
                esc(row.get("provider", "—")),
                esc(row.get("run_count", "—")),
                esc(_fmt_fin_pct(row.get("pass_rate_pct"))),
                esc(_fmt_fin_currency(row.get("total_cost_usd"))),
                esc(_fmt_fin_currency(row.get("avg_cost_usd"))),
                esc(_fmt_fin_currency(row.get("cost_per_passed_run_usd"))),
            )
        )
    parts.append("</tbody></table>")
    return "\n".join(parts)


def _render_spend_by_work_type_table(rows):
    if not rows:
        return '<p class="note">No spend-by-work-type data available.</p>'
    parts = [
        '<table id="spend-by-work-type-table">',
        "<thead><tr>",
        "<th>Work type</th><th>Runs</th><th>Pass rate</th>",
        "<th>Total cost</th><th>Share of spend</th><th>Avg cost</th>",
        "<th>Tokens (in / cached / out)</th>",
        "</tr></thead><tbody>",
    ]
    sorted_rows = sorted(
        rows,
        key=lambda r: (
            -float(r.get("total_actual_cost_usd") or 0),
            -int(r.get("run_count") or 0),
            str(r.get("work_type", "")),
        ),
    )
    for row in sorted_rows:
        tin = row.get("total_tokens_in")
        tcached = row.get("total_tokens_cached")
        tout = row.get("total_tokens_out")
        tokens_s = "—"
        if tin is not None or tcached is not None or tout is not None:
            tokens_s = "{:,} / {:,} / {:,}".format(
                int(tin or 0),
                int(tcached or 0),
                int(tout or 0),
            )
        parts.append(
            "<tr><td>{}</td><td>{}</td><td>{}</td>"
            "<td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>".format(
                esc(row.get("work_type", "—")),
                esc(row.get("run_count", "—")),
                esc(_fmt_fin_pct(row.get("pass_rate_pct"))),
                esc(_fmt_fin_currency(row.get("total_actual_cost_usd"))),
                esc(_fmt_fin_pct(row.get("cost_share_pct"))),
                esc(_fmt_fin_currency(row.get("avg_cost_usd"))),
                esc(tokens_s),
            )
        )
    parts.append("</tbody></table>")
    return "\n".join(parts)


def financials_html(data_dir, repo_root=".", as_of_utc=None):
    """Generate the Financials tab content from marts data."""
    marts_dir, marts = _load_marts(data_dir)
    if marts_dir is None or not marts:
        return placeholder_html("Financials")

    budget_data = _load_budget(repo_root)
    weekly_budget_usd = float(budget_data.get("weekly_usd", 0) or 0)
    monthly_budget_usd = float(budget_data.get("monthly_usd", 0) or 0)
    issue_target_usd = float(budget_data.get("issue_target_usd", 0.15) or 0.15)
    issue_cap_usd = float(budget_data.get("issue_cap_usd", 1.0) or 1.0)
    warn_pct = float(budget_data.get("warn_pct", 80) or 80)
    fixed_costs_monthly_usd = float(budget_data.get("fixed_costs_monthly_usd", 0) or 0)
    actions_minutes_month = int(budget_data.get("actions_minutes_month", 0) or 0)

    rpt_run_rate = marts.get("rpt_run_rate", [])
    agg_spend_weekly = marts.get("agg_spend_weekly", [])
    agg_spend_monthly = marts.get("agg_spend_monthly", [])
    agg_spend_by_issue = marts.get("agg_spend_by_issue", [])
    rpt_issue_target_compliance = marts.get("rpt_issue_target_compliance", [])
    agg_spend_by_model = marts.get("agg_spend_by_model", [])
    fct_forecast_vs_actual = marts.get("fct_forecast_vs_actual", [])
    fct_agent_runs = marts.get("fct_agent_runs", [])
    mart_model_efficiency = _mart_rows(marts, repo_root, "mart_model_efficiency")
    mart_monthly_cfo = _mart_rows(marts, repo_root, "mart_monthly_cfo")
    mart_spend_by_work_type = _mart_rows(marts, repo_root, "mart_spend_by_work_type")
    if not mart_spend_by_work_type and fct_agent_runs:
        mart_spend_by_work_type = _compute_mart_spend_by_work_type(fct_agent_runs)

    _assert_non_negative_spend(rpt_run_rate, "rpt_run_rate")
    _assert_non_negative_spend(agg_spend_weekly, "agg_spend_weekly")
    _assert_non_negative_spend(agg_spend_monthly, "agg_spend_monthly")
    _assert_non_negative_spend(agg_spend_by_issue, "agg_spend_by_issue")
    for name, collection in (
        ("agg_spend_by_model", agg_spend_by_model),
        ("fct_forecast_vs_actual", fct_forecast_vs_actual),
        ("fct_agent_runs", fct_agent_runs),
        ("rpt_issue_target_compliance", rpt_issue_target_compliance),
    ):
        for item in collection:
            if not isinstance(item, dict):
                raise ValueError(f"Expected dict in {name}, got {type(item)}: {item}")
        _assert_non_negative_spend(collection, name)
    _assert_non_negative_spend(mart_model_efficiency, "mart_model_efficiency")
    _assert_non_negative_spend(
        mart_spend_by_work_type, "mart_spend_by_work_type"
    )
    for row in mart_monthly_cfo:
        if not isinstance(row, dict):
            raise ValueError(
                f"Expected dict in mart_monthly_cfo, got {type(row)}: {row}"
            )

    as_of = _financials_as_of(as_of_utc, rpt_run_rate)
    parts = []

    parts.append('<h2>Headline Cards <small>(source: rpt_run_rate)</small></h2>')
    rate = rpt_run_rate[0] if rpt_run_rate else {}
    week_spend = float(rate.get("trailing_7d_usd_per_day", 0) or 0) * 7
    month_spend = float(rate.get("mtd_variable_usd", 0) or 0)
    week_used = (week_spend / weekly_budget_usd * 100) if weekly_budget_usd > 0 else 0
    month_used = (month_spend / monthly_budget_usd * 100) if monthly_budget_usd > 0 else 0
    week_budget_detail = (
        f"of ${weekly_budget_usd:.2f} budget ({week_used:.1f}%)"
        if weekly_budget_usd > 0
        else "no budget set"
    )
    month_budget_detail = (
        f"of ${monthly_budget_usd:.2f} budget ({month_used:.1f}%)"
        if monthly_budget_usd > 0
        else "no budget set"
    )

    parts.append('<div class="cards">')
    parts.append(_card(week_used >= warn_pct, "This Week", f"${week_spend:.2f}", week_budget_detail))
    parts.append(_card(month_used >= warn_pct, "Month-to-Date", f"${month_spend:.2f}", month_budget_detail))
    proj_var = float(rate.get("projected_month_end_variable_usd", 0) or 0)
    proj_total = float(rate.get("projected_month_end_total_usd", 0) or 0)
    parts.append(
        _card(
            False,
            "Projected Month-End",
            f"${proj_var:.2f}",
            f"total incl. fixed: ${proj_total:.2f}",
        )
    )
    fixed_mtd = float(rate.get("fixed_costs_month_usd", fixed_costs_monthly_usd) or 0)
    parts.append(_card(False, "Fixed Costs", f"${fixed_mtd:.2f}", "monthly fixed costs"))
    total_mtd = float(rate.get("total_mtd_usd", 0) or 0)
    total_budget = monthly_budget_usd + fixed_costs_monthly_usd
    total_detail = (
        f"of ${total_budget:.2f} total budget" if total_budget > 0 else "no budget set"
    )
    parts.append(_card(False, "Total MTD", f"${total_mtd:.2f}", total_detail))
    actions_mtd = int(rate.get("actions_minutes_mtd", 0) or 0)
    actions_pct = float(rate.get("actions_minutes_used_pct", 0) or 0)
    quota = int(rate.get("actions_minutes_quota", actions_minutes_month) or actions_minutes_month)
    parts.append(
        _card(
            actions_pct >= warn_pct,
            "Actions Minutes",
            f"{actions_mtd} min",
            f"of {quota} min ({actions_pct:.1f}%)",
        )
    )
    parts.append("</div>")

    parts.append(
        '<h2>Budget vs Spend <small>(sources: agg_spend_weekly, agg_spend_monthly)</small></h2>'
    )
    factory_site_path = str(Path(__file__).parent.parent / "factory" / "site")
    if factory_site_path not in sys.path:
        sys.path.insert(0, factory_site_path)
    from charts import svg_chart_monthly, svg_chart_weekly

    svg_weekly, table_weekly = svg_chart_weekly(
        agg_spend_weekly, weekly_budget_usd, as_of_date=as_of
    )
    parts.append("<h3>Weekly Spend (Last 12 Weeks)</h3>")
    parts.append(svg_weekly)
    parts.append('<details><summary>Table fallback</summary>')
    parts.append(table_weekly)
    parts.append("</details>")

    svg_monthly, table_monthly = svg_chart_monthly(
        agg_spend_monthly, monthly_budget_usd, as_of_date=as_of
    )
    parts.append("<h3>Monthly Spend (Last 6 Months)</h3>")
    parts.append(svg_monthly)
    parts.append('<details><summary>Table fallback</summary>')
    parts.append(table_monthly)
    parts.append("</details>")

    parts.append(
        '<h2>Monthly CFO summary <small>(source: mart_monthly_cfo)</small></h2>'
    )
    parts.append(_render_monthly_cfo_table(mart_monthly_cfo))

    parts.append(
        '<h2>Spend by Work Type (Coding vs. Review) '
        "<small>(source: mart_spend_by_work_type)</small></h2>"
    )
    parts.append(_render_spend_by_work_type_table(mart_spend_by_work_type))

    parts.append(
        "<h2>Per-Issue Economics <small>(sources: agg_spend_by_issue, rpt_issue_target_compliance)</small></h2>"
    )
    compliance_map = {}
    for row in rpt_issue_target_compliance:
        if not isinstance(row, dict):
            continue
        issue = _issue_key(row)
        if issue is None:
            continue
        compliance_map[issue] = row

    if agg_spend_by_issue:
        top_issues = sorted(
            agg_spend_by_issue, key=lambda x: float(x.get("spend_usd", 0) or 0), reverse=True
        )[:15]
        parts.append("<table>")
        parts.append(
            "<thead><tr><th>Issue</th><th>Runs</th><th>Spend</th>"
            "<th>Under Target</th><th>Under Cap</th><th>Headroom</th></tr></thead><tbody>"
        )
        for issue in top_issues:
            issue_num = _issue_key(issue)
            runs = issue.get("runs", 0)
            spend = float(issue.get("spend_usd", 0) or 0)
            comp = compliance_map.get(issue_num, {})
            if "under_target" in comp:
                under_target = "✓" if comp.get("under_target") else "✗"
            else:
                under_target = "✓" if spend <= issue_target_usd else "✗"
            if "under_cap" in comp:
                under_cap = "✓" if comp.get("under_cap") else "✗"
            else:
                under_cap = "✓" if spend <= issue_cap_usd else "✗"
            headroom = issue.get("cap_headroom_usd")
            if headroom is None:
                headroom = max(0.0, issue_cap_usd - spend)
            else:
                headroom = float(headroom)
            parts.append("<tr>")
            parts.append(f"<td>#{esc(issue_num)}</td>")
            parts.append(f"<td>{esc(runs)}</td>")
            parts.append(f"<td>${spend:.4f}</td>")
            parts.append(f"<td>{under_target}</td>")
            parts.append(f"<td>{under_cap}</td>")
            parts.append(f"<td>${headroom:.4f}</td>")
            parts.append("</tr>")
        parts.append("</tbody></table>")

        under_target_pct, over_cap_count = _compliance_summary_rows(
            rpt_issue_target_compliance, issue_target_usd, issue_cap_usd
        )
        if under_target_pct is not None:
            parts.append("<h3>Compliance Summary</h3>")
            parts.append(
                f"<p>{under_target_pct:.1f}% of issues under target (${issue_target_usd:.2f})</p>"
            )
            parts.append(
                f"<p>{int(over_cap_count)} issues over cap (${issue_cap_usd:.2f})</p>"
            )
    else:
        parts.append("<p>No per-issue data available.</p>")

    parts.append(
        "<h2>By Model and Work Type <small>(sources: agg_spend_by_model, fct_agent_runs)</small></h2>"
    )
    if agg_spend_by_model:
        parts.append("<h3>By model (mart aggregate)</h3>")
        parts.append("<table>")
        parts.append(
            "<thead><tr><th>Model</th><th>Spend</th><th>Runs</th><th>Gate pass rate</th>"
            "</tr></thead><tbody>"
        )
        for row in sorted(agg_spend_by_model, key=lambda r: str(r.get("model_id", ""))):
            model = row.get("model_id") or row.get("model") or "Unknown"
            spend = float(row.get("spend_usd", 0) or 0)
            runs = int(row.get("runs", 0) or 0)
            gate = row.get("gate_pass_rate")
            gate_s = f"{float(gate) * 100:.1f}%" if isinstance(gate, (int, float)) else "—"
            parts.append(
                "<tr><td>{}</td><td>${:.4f}</td><td>{}</td><td>{}</td></tr>".format(
                    esc(model), spend, esc(runs), esc(gate_s)
                )
            )
        parts.append("</tbody></table>")

    work_groups = {}
    for row in fct_agent_runs:
        if not isinstance(row, dict):
            continue
        model = row.get("model_id") or row.get("model") or "Unknown"
        work_type = row.get("work_type") or "unknown"
        spend = float(row.get("actual_cost_usd", 0) or 0)
        key = (model, work_type)
        if key not in work_groups:
            work_groups[key] = {"spend": 0.0, "runs": 0}
        work_groups[key]["spend"] += spend
        work_groups[key]["runs"] += 1

    if work_groups:
        parts.append("<h3>By model and work type (agent runs)</h3>")
        parts.append("<table>")
        parts.append(
            "<thead><tr><th>Model</th><th>Work Type</th><th>Spend</th>"
            "<th>Runs</th><th>Avg Cost/Run</th></tr></thead><tbody>"
        )
        for model, work_type in sorted(work_groups.keys()):
            data = work_groups[(model, work_type)]
            avg = data["spend"] / data["runs"] if data["runs"] else 0.0
            parts.append(
                "<tr><td>{}</td><td>{}</td><td>${:.4f}</td><td>{}</td><td>${:.6f}</td></tr>".format(
                    esc(model),
                    esc(work_type),
                    data["spend"],
                    data["runs"],
                    avg,
                )
            )
        parts.append("</tbody></table>")
    elif not agg_spend_by_model:
        parts.append("<p>No model/work-type data available.</p>")

    parts.append(
        '<h2>Model Efficiency <small>(source: mart_model_efficiency)</small></h2>'
    )
    parts.append(_render_model_efficiency_table(mart_model_efficiency))

    parts.append(
        '<h2>Prediction Accuracy <small>(source: fct_forecast_vs_actual)</small></h2>'
    )
    skipped_count = 0
    valid_rows = []
    error_pcts = []
    if fct_forecast_vs_actual:
        for row in fct_forecast_vs_actual:
            pred, actual, abs_err = _prediction_fields(row)
            if pred is None:
                skipped_count += 1
                continue
            valid_rows.append((row, pred, actual, abs_err))
            if abs_err is not None:
                error_pcts.append(float(abs_err))
        if valid_rows:
            parts.append("<table>")
            parts.append(
                "<thead><tr><th>Grain</th><th>Key</th><th>Predicted</th>"
                "<th>Actual</th><th>|Error %|</th></tr></thead><tbody>"
            )
            for row, pred, actual, abs_err in sorted(
                valid_rows,
                key=lambda t: (str(t[0].get("grain", "")), str(t[0].get("grain_key", t[0].get("issue_number", "")))),
            ):
                grain = row.get("grain") or "issue"
                key = row.get("grain_key") or row.get("issue_number") or "—"
                err_s = f"{float(abs_err):.2f}%" if abs_err is not None else "—"
                parts.append(
                    "<tr><td>{}</td><td>{}</td><td>${:.4f}</td><td>${:.4f}</td><td>{}</td></tr>".format(
                        esc(grain),
                        esc(key),
                        float(pred),
                        float(actual or 0),
                        esc(err_s),
                    )
                )
            parts.append("</tbody></table>")

        if error_pcts:
            sorted_errs = sorted(error_pcts)
            median_error = sorted_errs[len(sorted_errs) // 2]
            worst_error = max(error_pcts)
            parts.append("<h3>Summary</h3>")
            parts.append("<table>")
            parts.append(
                "<thead><tr><th>Median |Error %|</th><th>Worst |Error %|</th>"
                "<th>Recalibrate priors</th></tr></thead><tbody><tr>"
            )
            parts.append(f"<td>{median_error:.2f}%</td>")
            parts.append(f"<td>{worst_error:.2f}%</td>")
            recalibrate = "YES" if median_error > 100.0 else "NO"
            parts.append(f"<td>{recalibrate}</td></tr></tbody></table>")
        if skipped_count:
            parts.append(
                f"<p>Note: {skipped_count} rows with null predictions were excluded from accuracy statistics.</p>"
            )
    else:
        parts.append("<p>No prediction accuracy data available.</p>")

    parts.append('<h2>Agent runs <small>(source: fct_agent_runs)</small></h2>')
    parts.append(_agent_runs_table(fct_agent_runs))

    parts.append('<h2>Data Freshness <small>(source: fct_agent_runs)</small></h2>')
    if fct_agent_runs:
        timestamps = []
        invalid_records = 0
        for row in fct_agent_runs:
            ts = row.get("started_at_utc") or row.get("ended_at_utc") or ""
            if not row.get("run_id") or not ts:
                invalid_records += 1
                continue
            timestamps.append(ts)
        if timestamps:
            latest_run = max(timestamps)
            utc_s, chicago_s = _format_utc_chicago(latest_run)
            parts.append("<table>")
            parts.append(
                "<thead><tr><th>Latest Run Time (UTC)</th><th>Latest Run Time (America/Chicago)</th>"
                "<th>Total Records</th><th>Invalid Records Skipped</th></tr></thead><tbody><tr>"
            )
            parts.append(
                f"<td>{utc_s}</td><td>{chicago_s}</td>"
                f"<td>{len(fct_agent_runs)}</td><td>{invalid_records}</td>"
            )
            parts.append("</tr></tbody></table>")
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


def _issues_missing_priority_or_risk(issues):
    return sum(
        1
        for i in issues
        if i.get("priority") == "none" or i.get("risk") == "unlabeled"
    )


def _unlabeled_notice(issues):
    unlabeled = _issues_missing_priority_or_risk(issues)
    if unlabeled == 0:
        return ""
    return (
        '<div class="backlog-unlabeled note">'
        "<p><strong>Unlabeled issues:</strong> "
        "{} open issue(s) lack <code>priority:*</code> and/or "
        "<code>risk:*</code> GitHub labels. "
        "In the issue sidebar, add labels such as "
        "<code>priority:high</code>, <code>priority:low</code>, "
        "<code>risk:high</code>, <code>risk:medium</code>, or "
        "<code>risk:low</code> so the priority × risk grid reflects triage.</p>"
        "</div>".format(esc(unlabeled))
    )


def _summary_cards(issues):
    open_count = len(issues)
    high = sum(1 for i in issues if i.get("priority") == "high")
    owner_action = sum(1 for i in issues if i.get("status") == "owner-action")
    selected = sum(1 for i in issues if i.get("status") == "factory:selected")
    unlabeled = _issues_missing_priority_or_risk(issues)
    cards = [
        ("Open", open_count),
        ("High priority", high),
        ("Owner-action", owner_action),
        ("Selected", selected),
    ]
    if unlabeled > 0:
        cards.append(("Unlabeled", unlabeled))
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
    out = [_backlog_filter_bar(len(ordered)), '<table id="backlog-issues-table"><thead><tr>']
    for cell in header:
        out.append("<th>{}</th>".format(esc(cell)))
    out.append("</tr></thead><tbody>")
    for i in ordered:
        title = i.get("title", "")
        url = i.get("url", "")
        link = '<a href="{}">{}</a>'.format(esc(url), esc(title)) if url else esc(title)
        status = STATUS_LABELS.get(i.get("status", "open"), i.get("status", "open"))
        prio = i.get("priority", "none")
        risk = i.get("risk", "unlabeled")
        search_bits = [title, str(i.get("number", "")), status, prio, risk]
        search_blob = " ".join(str(x) for x in search_bits if x).lower()
        out.append(
            '<tr class="backlog-issue-row" data-priority="{}" data-risk="{}" '
            'data-search="{}">'.format(esc(prio), esc(risk), esc(search_blob))
        )
        out.append("<th>{}</th>".format(esc(prio)))
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
        _unlabeled_notice(issues),
        "<h2>Open issues by priority and risk</h2>",
        _priority_risk_table(issues),
    ]
    epic = _epic_list(issues)
    if epic:
        out.append(epic)
    out.append("<h2>Open issues</h2>")
    out.append(_issue_table(issues))
    return "\n".join(out)


DBT_LAYERS = ("seed", "staging", "marts")
DBT_LAYER_DEPTH = {"seed": 0, "staging": 1, "marts": 2, "other": 3}


def _dbt_export_module():
    path = Path(__file__).with_name("factory-site-dbt-export.py")
    spec = importlib.util.spec_from_file_location("factory_site_dbt_export", path)
    if spec is None or spec.loader is None:
        return None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _dbt_offline_manifest_roots(repo_root):
    repo = Path(repo_root)
    template_root = Path(__file__).resolve().parent.parent
    if (repo / "factory" / "dbt" / "models").is_dir():
        return [repo]
    if _dbt_manifest_path(repo_root).is_file():
        return [template_root]
    if (repo / "factory" / "dbt" / "target").is_dir():
        return [template_root]
    return [repo]


def _dbt_manifest_for_site(repo_root):
    export = _dbt_export_module()
    offline = None
    if export is not None:
        for root in _dbt_offline_manifest_roots(repo_root):
            candidate = export.build_offline_manifest(root)
            model_count = sum(
                1
                for n in (candidate.get("nodes") or {}).values()
                if isinstance(n, dict) and n.get("resource_type") == "model"
            )
            if model_count:
                offline = candidate
                break
    manifest_path = _dbt_manifest_path(repo_root)
    on_disk = _load_json(manifest_path) if manifest_path.is_file() else None
    if offline is None:
        return on_disk
    if on_disk is None:
        return offline
    return export.merge_manifests(on_disk, offline)


def _dbt_manifest_path(repo_root):
    return Path(repo_root) / "factory" / "dbt" / "target" / "manifest.json"


def _dbt_catalog_path(repo_root):
    return Path(repo_root) / "factory" / "dbt" / "target" / "catalog.json"


def _load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError, TypeError):
        return None


def _dbt_layer(node):
    if node.get("resource_type") == "seed":
        return "seed"
    path = (node.get("original_file_path") or node.get("path") or "").lower()
    fqn = node.get("fqn") or []
    if "staging" in path or (len(fqn) > 1 and fqn[1] == "staging"):
        return "staging"
    if "marts" in path or (len(fqn) > 1 and fqn[1] == "marts"):
        return "marts"
    return "other"


def _dbt_resource_nodes(manifest):
    nodes = manifest.get("nodes") or {}
    out = []
    for node in nodes.values():
        if not isinstance(node, dict):
            continue
        rt = node.get("resource_type")
        if rt in ("model", "seed"):
            out.append(node)
    out.sort(key=lambda n: (DBT_LAYER_DEPTH.get(_dbt_layer(n), 9), n.get("name") or ""))
    return out


def _dbt_unique_by_name(nodes):
    by_name = {}
    for node in nodes:
        name = node.get("name")
        if name:
            by_name[name] = node
    return by_name


def _dbt_description(node):
    text = (node.get("description") or "").strip()
    return text if text else "no description"


def _dbt_materialization(node):
    cfg = node.get("config") or {}
    mat = cfg.get("materialized")
    if mat:
        return str(mat)
    if node.get("resource_type") == "seed":
        return "seed"
    return "view"


def _dbt_column_count(node):
    cols = node.get("columns")
    if isinstance(cols, dict):
        return len(cols)
    return 0


def _dbt_tests_by_model(manifest):
    by_model = {}
    names_by_model = {}
    for node in (manifest.get("nodes") or {}).values():
        if not isinstance(node, dict) or node.get("resource_type") != "test":
            continue
        deps = (node.get("depends_on") or {}).get("nodes") or []
        label = node.get("name") or "test"
        meta = node.get("test_metadata") or {}
        if meta.get("name"):
            label = "{}.{}".format(meta.get("name"), meta.get("column_name") or "")
        for dep in deps:
            by_model[dep] = by_model.get(dep, 0) + 1
            names_by_model.setdefault(dep, []).append(label)
    for dep in names_by_model:
        names_by_model[dep].sort()
    return by_model, names_by_model


def _dbt_lineage_sets(nodes):
    by_id = {n.get("unique_id"): n for n in nodes if n.get("unique_id")}
    ids = set(by_id)
    upstream = {}
    downstream = {}
    for uid, node in by_id.items():
        parents = [
            p for p in (node.get("depends_on") or {}).get("nodes") or []
            if p in ids
        ]
        upstream[uid] = parents
        for p in parents:
            downstream.setdefault(p, []).append(uid)
    for uid in downstream:
        downstream[uid].sort()
    return upstream, downstream, by_id


def _dbt_model_link(name, by_name):
    if name in by_name:
        return '<a href="#model-{}">{}</a>'.format(esc(name), esc(name))
    return esc(name)


def _dbt_docs_banner(out_dir):
    docs = Path(out_dir) / "dbt-docs.html"
    if docs.is_file():
        return (
            '<p><a href="dbt-docs.html">Full interactive lineage</a> '
            "(dbt static docs)</p>"
        )
    return (
        '<p class="note">Full interactive dbt docs are not available in this build '
        "(run a live <code>dbt docs generate --static</code> build to produce "
        "<code>dbt-docs.html</code>).</p>"
    )


def _dbt_badge(value, label):
    return '<span class="dbt-meta-badge" title="{}">{}</span>'.format(
        esc(label), esc(str(value))
    )


def _dbt_model_search_blob(node):
    bits = [
        node.get("name") or "",
        _dbt_layer(node),
        _dbt_materialization(node),
        _dbt_description(node),
    ]
    return " ".join(bits)


def _dbt_filter_toolbar(model_count):
    return "\n".join(
        [
            '<div class="dbt-filter" id="dbt-filter-bar">',
            '<label class="backlog-search-label" for="dbt-model-search">'
            "Filter models</label>",
            '<input type="search" id="dbt-model-search" class="dbt-search" '
            'autocomplete="off" placeholder="Name, layer, or description" />',
            '<div class="dbt-filter-toolbar">',
            '<button type="button" class="btn-secondary" id="dbt-lineage-clear">'
            "Clear lineage highlight</button>",
            "</div>",
            '<p class="dbt-filter-count" id="dbt-filter-count">Showing '
            "{} of {} models</p>".format(model_count, model_count),
            "</div>",
        ]
    )


def _dbt_lineage_graph_json(nodes, upstream, downstream, by_id):
    graph = {"nodes": {}, "upstream": {}, "downstream": {}}
    for node in nodes:
        name = node.get("name") or ""
        if not name:
            continue
        uid = node.get("unique_id") or ""
        graph["nodes"][name] = {"unique_id": uid, "layer": _dbt_layer(node)}
        up = []
        for parent_id in upstream.get(uid) or []:
            parent = by_id.get(parent_id)
            if parent and parent.get("name"):
                up.append(parent["name"])
        down = []
        for child_id in downstream.get(uid) or []:
            child = by_id.get(child_id)
            if child and child.get("name"):
                down.append(child["name"])
        graph["upstream"][name] = sorted(up)
        graph["downstream"][name] = sorted(down)
    payload = json.dumps(graph, sort_keys=True, separators=(",", ":"))
    payload = payload.replace("</", "<\\/")
    return (
        '<script type="application/json" id="dbt-lineage-graph">'
        + payload
        + "</script>"
    )


def _dbt_model_table(nodes, by_name, test_counts):
    if not nodes:
        return '<p class="note">No models found in manifest.</p>'
    parts = [
        '<table id="dbt-models-table"><thead><tr>',
        "<th>Name</th><th>Layer</th><th>Materialization</th>",
        "<th>Description</th><th>Columns</th><th>Tests</th>",
        "</tr></thead><tbody>",
    ]
    for node in nodes:
        uid = node.get("unique_id") or ""
        name = node.get("name") or ""
        col_count = _dbt_column_count(node)
        test_count = test_counts.get(uid, 0)
        parts.append(
            '<tr class="dbt-model-row" data-search="{}">'.format(
                esc(_dbt_model_search_blob(node))
            )
        )
        parts.append(
            '<td><a href="#model-{}">{}</a></td>'.format(esc(name), esc(name))
        )
        parts.append("<td>{}</td>".format(esc(_dbt_layer(node))))
        parts.append("<td>{}</td>".format(esc(_dbt_materialization(node))))
        parts.append("<td>{}</td>".format(esc(_dbt_description(node))))
        parts.append(
            "<td>{}</td>".format(
                _dbt_badge(col_count, "Column count") if col_count else "—"
            )
        )
        parts.append(
            "<td>{}</td>".format(
                _dbt_badge(test_count, "Attached tests") if test_count else "—"
            )
        )
        parts.append("</tr>")
    parts.append("</tbody></table>")
    return "\n".join(parts)


def _dbt_model_details(nodes, by_name, upstream, downstream, test_names):
    by_uid = {n.get("unique_id"): n for n in nodes if n.get("unique_id")}
    parts = ["<h2>Model details</h2>"]
    for node in nodes:
        uid = node.get("unique_id") or ""
        name = node.get("name") or ""
        parts.append(
            '<section class="dbt-model" id="model-{}" data-search="{}">'.format(
                esc(name), esc(_dbt_model_search_blob(node))
            )
        )
        parts.append("<h3>{}</h3>".format(esc(name)))
        parts.append("<p>{}</p>".format(esc(_dbt_description(node))))
        up_links = []
        for parent_id in upstream.get(uid) or []:
            parent = by_uid.get(parent_id)
            if parent and parent.get("name"):
                up_links.append(_dbt_model_link(parent["name"], by_name))
        down_links = []
        for child_id in downstream.get(uid) or []:
            child = by_uid.get(child_id)
            if child and child.get("name"):
                down_links.append(_dbt_model_link(child["name"], by_name))
        parts.append(
            "<p><strong>Upstream:</strong> {}</p>".format(
                ", ".join(up_links) if up_links else "(none)"
            )
        )
        parts.append(
            "<p><strong>Downstream:</strong> {}</p>".format(
                ", ".join(down_links) if down_links else "(none)"
            )
        )
        tests = test_names.get(uid) or []
        if tests:
            parts.append("<p><strong>Data tests:</strong></p><ul>")
            for t in tests:
                parts.append("<li>{}</li>".format(esc(t)))
            parts.append("</ul>")
        else:
            parts.append("<p><strong>Data tests:</strong> (none listed)</p>")
        cols = node.get("columns") or {}
        if isinstance(cols, dict) and cols:
            parts.append(
                "<table><thead><tr><th>Column</th><th>Description</th></tr>"
                "</thead><tbody>"
            )
            for col_name in sorted(cols):
                col = cols[col_name] or {}
                desc = (col.get("description") or "").strip() or "no description"
                parts.append(
                    "<tr><th>{}</th><td>{}</td></tr>".format(
                        esc(col_name), esc(desc)
                    )
                )
            parts.append("</tbody></table>")
        else:
            parts.append('<p class="note">No column metadata in manifest.</p>')
        parts.append("</section>")
    return "\n".join(parts)


def _dbt_lineage_svg(nodes, upstream, by_name):
    layers = {layer: [] for layer in DBT_LAYERS}
    for node in nodes:
        layer = _dbt_layer(node)
        if layer in layers:
            layers[layer].append(node)
        elif layer == "other":
            layers["marts"].append(node)
    for layer in layers:
        layers[layer].sort(key=lambda n: n.get("name") or "")
    col_w = 130
    node_h = 30
    gap_y = 10
    gap_x = 50
    margin = 12
    max_rows = max((len(layers[l]) for l in DBT_LAYERS), default=1)
    height = margin * 2 + max_rows * (node_h + gap_y)
    width = margin * 2 + len(DBT_LAYERS) * col_w + (len(DBT_LAYERS) - 1) * gap_x
    positions = {}
    by_uid = {n.get("unique_id"): n for n in nodes if n.get("unique_id")}
    parts = [
        '<svg class="dbt-lineage" viewBox="0 0 {} {}" role="img" '
        'aria-label="dbt model lineage by layer">'.format(width, height)
    ]
    parts.append(
        '<defs><marker id="dbt-arrow" markerWidth="8" markerHeight="8" '
        'refX="7" refY="3" orient="auto" markerUnits="strokeWidth">'
        '<path d="M0,0 L0,6 L7,3 z" fill="#1f2430"/></marker></defs>'
    )
    for col, layer in enumerate(DBT_LAYERS):
        x = margin + col * (col_w + gap_x)
        parts.append(
            '<text x="{}" y="{}" text-anchor="middle" font-size="11" '
            'font-weight="600" fill="#555d6b">{}</text>'.format(
                x + col_w / 2, margin, esc(layer)
            )
        )
        for row, node in enumerate(layers[layer]):
            y = margin + 16 + row * (node_h + gap_y)
            uid = node.get("unique_id")
            name = node.get("name") or ""
            positions[uid] = (x + col_w / 2, y + node_h / 2, x, y)
            parts.append(
                '<g class="dbt-lineage-node" data-model="{}" tabindex="0" '
                'role="button" aria-label="Highlight lineage for {}">'.format(
                    esc(name), esc(name)
                )
            )
            parts.append(
                '<rect x="{}" y="{}" width="{}" height="{}" rx="5" '
                'fill="#eef0f4" stroke="#1f2430" stroke-width="1.2"/>'.format(
                    x, y, col_w, node_h
                )
            )
            label = name if len(name) <= 16 else name[:14] + "…"
            parts.append(
                '<text x="{}" y="{}" text-anchor="middle" font-size="10" '
                'fill="#1f2430">{}</text>'.format(
                    x + col_w / 2, y + node_h / 2 + 3, esc(label)
                )
            )
            parts.append("</g>")
    for node in nodes:
        uid = node.get("unique_id")
        if uid not in positions:
            continue
        to_name = node.get("name") or ""
        cx, cy, _, _ = positions[uid]
        for parent_id in upstream.get(uid) or []:
            if parent_id not in positions:
                continue
            px, py, _, _ = positions[parent_id]
            _, _, px0, _ = positions[parent_id]
            _, _, nx0, _ = positions[uid]
            x1 = px0 + col_w
            y1 = py
            x2 = nx0
            y2 = cy
            par_node = by_uid.get(parent_id)
            from_name = (par_node.get("name") or "") if par_node else ""
            parts.append(
                '<line class="dbt-lineage-edge" data-from="{}" data-to="{}" '
                'x1="{}" y1="{}" x2="{}" y2="{}" stroke="#1f2430" '
                'stroke-width="1.5" marker-end="url(#dbt-arrow)"/>'.format(
                    esc(from_name), esc(to_name), x1, y1, x2, y2
                )
            )
    parts.append("</svg>")
    return "\n".join(parts)


def dbt_html(repo_root, out_dir):
    manifest = _dbt_manifest_for_site(repo_root)
    if manifest is None:
        return placeholder_html("dbt")

    catalog_path = _dbt_catalog_path(repo_root)
    catalog_note = ""
    if catalog_path.is_file():
        catalog = _load_json(catalog_path)
        if catalog is None:
            catalog_note = '<p class="note">catalog.json was present but could not be parsed.</p>'
    else:
        catalog_note = (
            '<p class="note">No catalog.json (row counts omitted; manifest-only view).</p>'
        )

    nodes = _dbt_resource_nodes(manifest)
    if not nodes:
        return (
            "<h2>dbt</h2>\n"
            + _dbt_docs_banner(out_dir)
            + '<p class="note">Manifest loaded but contains no models or seeds.</p>'
        )

    by_name = _dbt_unique_by_name(nodes)
    test_counts, test_names = _dbt_tests_by_model(manifest)
    upstream, downstream, by_id = _dbt_lineage_sets(nodes)

    parts = [
        "<h2>dbt</h2>",
        _dbt_docs_banner(out_dir),
        "<p>Models and lineage for the factory cost dataset "
        "(manifest plus offline schema/SQL discovery).</p>",
    ]
    if catalog_note:
        parts.append(catalog_note)
    parts.append("<h2>Models</h2>")
    parts.append(_dbt_filter_toolbar(len(nodes)))
    parts.append(_dbt_model_table(nodes, by_name, test_counts))
    parts.append("<h2>Lineage</h2>")
    parts.append(
        '<p class="note">Click a node to highlight upstream and downstream lineage. '
        "Works without JavaScript as a static diagram.</p>"
    )
    parts.append(_dbt_lineage_svg(nodes, upstream, by_name))
    parts.append(_dbt_lineage_graph_json(nodes, upstream, downstream, by_id))
    parts.append(_dbt_model_details(nodes, by_name, upstream, downstream, test_names))
    return "\n".join(parts)


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
        "financials.html": financials_html(args.data, repo_root, now),
        "backlog.html": backlog_html(args.data),
        "dbt.html": dbt_html(repo_root, out_dir),
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
        body = enhance_page_html(body, filename)
        with open(out_dir / filename, "w", encoding="utf-8") as fh:
            fh.write(body)
        written.append(filename)

    print("Wrote {}".format(", ".join(written)))


if __name__ == "__main__":
    main()
