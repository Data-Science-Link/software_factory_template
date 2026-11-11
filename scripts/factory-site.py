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
    marts_dir = Path(data_dir) / "marts"
    if marts_dir.is_dir() and any(marts_dir.glob("*.json")):
        return (
            "<h2>Financials</h2>\n"
            '<div class="placeholder"><p>Financials data is present, but the full '
            'tab lands in issue #174.</p></div>'
        )
    return placeholder_html("Financials")


def backlog_html(data_dir):
    backlog = Path(data_dir) / "backlog.json"
    if backlog.is_file():
        try:
            with open(backlog, encoding="utf-8") as fh:
                items = json.load(fh)
        except (ValueError, OSError):
            items = []
        if items:
            out = ["<h2>Backlog</h2>", "<ul>"]
            for item in items:
                title = item.get("title") if isinstance(item, dict) else str(item)
                out.append("<li>{}</li>".format(esc(title)))
            out.append("</ul>")
            return "\n".join(out)
    return placeholder_html("Backlog")


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
