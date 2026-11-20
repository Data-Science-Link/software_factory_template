#!/usr/bin/env python3
"""Offline smoke and HTML/SVG regression checks for the static factory site.

Usage:
    scripts/factory-site-smoke.py <site-dir> [--json] [--strict]
    scripts/factory-site-smoke.py --build [--json] [--strict]

Validates tab nav, visible text, inline SVG, and local references using only
stdlib html.parser and xml.etree.ElementTree.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path
from typing import Iterable
from xml.etree import ElementTree as ET

TAB_LABELS = ("Architecture", "Financials", "Backlog", "dbt")
PRIMARY_PAGES = (
    "index.html",
    "financials.html",
    "backlog.html",
    "dbt.html",
)
PERSONAL_NAMES = ("Michael", "Grok Bot")
VOID_TAGS = frozenset(
    {
        "area",
        "base",
        "br",
        "col",
        "embed",
        "hr",
        "img",
        "input",
        "link",
        "meta",
        "param",
        "source",
        "track",
        "wbr",
    }
)
CORE_STRUCTURAL = frozenset(
    {"html", "head", "body", "header", "main", "footer", "nav"}
)
SHAPE_TAGS = frozenset(
    {"rect", "circle", "ellipse", "line", "polyline", "polygon", "path", "text", "tspan"}
)
BOLD_RE = re.compile(r"\*\*[^*\n]+\*\*")
DOUBLE_ESC_RE = re.compile(r"&amp;(?:#x[0-9a-fA-F]+|apos|quot)", re.IGNORECASE)
SVG_BLOCK_RE = re.compile(r"<svg\b[^>]*>.*?</svg>", re.IGNORECASE | re.DOTALL)
HREF_SRC_RE = re.compile(
    r"""(?:href|src)\s*=\s*["']([^"']+)["']""", re.IGNORECASE
)
MAIN_BLOCK_RE = re.compile(r"<main\b[^>]*>.*?</main>", re.IGNORECASE | re.DOTALL)
SITE_ASSET_RE = re.compile(r"^(?:[a-z0-9._-]+\.(?:html|css)|dbt-docs\.html)$", re.I)


@dataclass
class Finding:
    check: str
    file: str
    message: str

    def as_dict(self):
        return {"check": self.check, "file": self.file, "message": self.message}


@dataclass
class SiteSmokeResult:
    site_dir: str
    findings: list[Finding] = field(default_factory=list)
    checks_run: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return len(self.findings) == 0

    def add(self, check: str, file: str, message: str) -> None:
        self.findings.append(Finding(check, file, message))

    def to_json(self) -> dict:
        return {
            "ok": self.ok,
            "site_dir": self.site_dir,
            "error_count": len(self.findings),
            "checks_run": self.checks_run,
            "errors": [f.as_dict() for f in self.findings],
        }


class VisibleTextCollector(HTMLParser):
    """Collect visible text, skipping script/style."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self._skip = 0
        self.chunks: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() in ("script", "style"):
            self._skip += 1

    def handle_endtag(self, tag):
        if tag.lower() in ("script", "style") and self._skip:
            self._skip -= 1

    def handle_data(self, data):
        if self._skip:
            return
        if data and not data.isspace():
            self.chunks.append(data)

    def text(self) -> str:
        return "\n".join(self.chunks)


class StructureParser(HTMLParser):
    """Track core structural tags for balanced open/close."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack: list[str] = []
        self.errors: list[str] = []

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        if tag in VOID_TAGS:
            return
        self.stack.append(tag)

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag in VOID_TAGS:
            return
        if not self.stack:
            self.errors.append(f"unexpected closing </{tag}>")
            return
        if tag != self.stack[-1]:
            if tag in CORE_STRUCTURAL:
                self.errors.append(
                    f"unclosed <{self.stack[-1]}> before </{tag}>"
                )
            # Pop back to matching tag or clear mismatch for non-core noise.
            while self.stack and self.stack[-1] != tag:
                popped = self.stack.pop()
                if popped in CORE_STRUCTURAL:
                    self.errors.append(f"unclosed <{popped}>")
            if self.stack and self.stack[-1] == tag:
                self.stack.pop()
        else:
            self.stack.pop()

    def finish(self) -> list[str]:
        for tag in reversed(self.stack):
            if tag in CORE_STRUCTURAL:
                self.errors.append(f"unclosed <{tag}>")
        return self.errors


class IdCollector(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids: set[str] = set()

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name.lower() == "id" and value:
                self.ids.add(value)


def repo_root() -> Path:
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
        )
        return Path(out.stdout.strip())
    except (subprocess.CalledProcessError, FileNotFoundError):
        return Path.cwd()


def build_fixture_site() -> Path:
    """Run the offline sample build and copy site/ into a temp directory."""
    root = repo_root()
    build_sh = root / "scripts" / "factory-site-build.sh"
    if not build_sh.is_file():
        raise SystemExit(f"build script not found: {build_sh}")
    subprocess.run(
        ["bash", str(build_sh), "--sample"],
        cwd=root,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    src = root / "site"
    if not src.is_dir():
        raise SystemExit("sample build did not produce site/")
    tmp = Path(tempfile.mkdtemp(prefix="factory-site-smoke-"))
    dest = tmp / "site"
    shutil.copytree(src, dest)
    return dest


def discover_pages(site_dir: Path) -> list[Path]:
    pages: list[Path] = []
    for name in PRIMARY_PAGES:
        path = site_dir / name
        if path.is_file():
            pages.append(path)
    extra: set[str] = set()
    for path in list(pages):
        text = path.read_text(encoding="utf-8")
        for m in HREF_SRC_RE.finditer(text):
            ref = m.group(1)
            if ref.endswith("dbt-docs.html") or ref == "dbt-docs.html":
                extra.add("dbt-docs.html")
    for name in sorted(extra):
        p = site_dir / name
        if p.is_file() and p not in pages:
            pages.append(p)
    return pages


def visible_text(html: str) -> str:
    collector = VisibleTextCollector()
    try:
        collector.feed(html)
        collector.close()
    except Exception:  # pragma: no cover - parser errors reported elsewhere
        return ""
    return collector.text()


def ui_chrome_text(html: str) -> str:
    """Visible text outside <main> (nav, header, footer, title)."""
    stripped = MAIN_BLOCK_RE.sub(" ", html)
    return visible_text(stripped)


def structural_errors(html: str) -> list[str]:
    parser = StructureParser()
    try:
        parser.feed(html)
        parser.close()
    except Exception as exc:
        return [f"html parse error: {exc}"]
    return parser.finish()


def element_ids(html: str) -> set[str]:
    collector = IdCollector()
    try:
        collector.feed(html)
        collector.close()
    except Exception:
        return set()
    return collector.ids


def svg_has_shape(root: ET.Element) -> bool:
    for el in root.iter():
        tag = el.tag.split("}")[-1].lower()
        if tag not in SHAPE_TAGS:
            continue
        if tag == "text" or tag == "tspan":
            if (el.text or "").strip() or any(
                (t or "").strip() for t in el.itertext()
            ):
                return True
        elif tag == "path":
            if (el.attrib.get("d") or "").strip():
                return True
        elif tag in ("rect", "circle", "ellipse", "line"):
            return True
        elif tag in ("polyline", "polygon"):
            if (el.attrib.get("points") or "").strip():
                return True
    return False


def parse_inline_svg(snippet: str) -> tuple[bool, str]:
    """Return (ok, message)."""
    s = snippet.strip()
    if 'xmlns=' not in s[:200]:
        s = re.sub(
            r"<svg\b",
            '<svg xmlns="http://www.w3.org/2000/svg"',
            s,
            count=1,
            flags=re.IGNORECASE,
        )
    try:
        root = ET.fromstring(s)
    except ET.ParseError as exc:
        return False, f"svg xml parse error: {exc}"
    tag = root.tag.split("}")[-1].lower()
    if tag != "svg":
        return False, "svg root element missing"
    if not svg_has_shape(root):
        return False, "svg has no shapes or text"
    return True, ""


def is_site_bundle_ref(ref: str) -> bool:
    """True when href/src must exist inside the built site directory."""
    ref = ref.strip()
    if not ref:
        return False
    if ref.startswith("#"):
        return True
    lowered = ref.lower()
    if lowered.startswith(("http://", "https://", "mailto:", "tel:", "javascript:")):
        return False
    if "/" in ref or ref.startswith("."):
        return False
    return bool(SITE_ASSET_RE.match(ref))


def resolve_ref(site_dir: Path, page: Path, ref: str, ids: set[str]) -> bool:
    ref = ref.strip()
    if ref.startswith("#"):
        anchor = ref[1:]
        return anchor in ids
    path_part, _, frag = ref.partition("#")
    target = (site_dir / path_part).resolve()
    try:
        target.relative_to(site_dir.resolve())
    except ValueError:
        return False
    if not target.is_file():
        return False
    if frag:
        doc = target.read_text(encoding="utf-8")
        return frag in element_ids(doc)
    return True


def check_page(site_dir: Path, page: Path, result: SiteSmokeResult) -> None:
    rel = page.name
    try:
        html = page.read_text(encoding="utf-8")
    except OSError as exc:
        result.add("read_file", rel, str(exc))
        return

    for err in structural_errors(html):
        result.add("html_structure", rel, err)

    text = visible_text(html)
    for label in TAB_LABELS:
        if label not in html:
            result.add("factory_tabs", rel, f"missing tab label {label!r}")

    if BOLD_RE.search(text):
        result.add("markdown_bold_leak", rel, "visible text contains raw **bold**")

    if DOUBLE_ESC_RE.search(text):
        result.add(
            "double_escaped_entity",
            rel,
            "found double-escaped entity (&amp;#x, &amp;apos, or &amp;quot)",
        )

    chrome = ui_chrome_text(html)
    for name in PERSONAL_NAMES:
        if name in chrome:
            result.add(
                "personal_name_leak",
                rel,
                f"UI chrome contains personal name {name!r}",
            )

    ids = element_ids(html)
    for idx, block in enumerate(SVG_BLOCK_RE.finditer(html), start=1):
        ok, msg = parse_inline_svg(block.group(0))
        if not ok:
            result.add("svg_xml", rel, f"inline svg #{idx}: {msg}")

    for m in HREF_SRC_RE.finditer(html):
        ref = m.group(1)
        if not is_site_bundle_ref(ref):
            continue
        if not resolve_ref(site_dir, page, ref, ids):
            result.add("local_reference", rel, f"broken local reference {ref!r}")

    if 'role="tablist"' not in html:
        result.add("aria_tabs", rel, 'nav missing role="tablist"')
    if 'role="tabpanel"' not in html:
        result.add("aria_tabs", rel, "main missing role=\"tabpanel\"")
    if 'role="tab"' not in html:
        result.add("aria_tabs", rel, 'tab links missing role="tab"')
    if "@media print" not in html:
        result.add("print_stylesheet", rel, "missing @media print rules in page CSS")
    if rel == "index.html":
        if 'id="active-factory-config"' not in html:
            result.add("active_factory_config", rel, "missing Active Factory Configuration card")
        if 'id="factory-loop-interactive"' not in html:
            result.add(
                "factory_loop_interactive",
                rel,
                "missing interactive factory loop container",
            )
        if 'id="loop-stage-detail"' not in html:
            result.add(
                "factory_loop_interactive",
                rel,
                "missing loop stage detail panel",
            )
        if "loop-stage-btn" not in html:
            result.add(
                "factory_loop_interactive",
                rel,
                "missing loop stage buttons",
            )


def validate_site(site_dir: Path) -> SiteSmokeResult:
    site_dir = site_dir.resolve()
    result = SiteSmokeResult(site_dir=str(site_dir))
    result.checks_run = [
        "html_structure",
        "factory_tabs",
        "markdown_bold_leak",
        "double_escaped_entity",
        "personal_name_leak",
        "svg_xml",
        "local_reference",
        "aria_tabs",
        "print_stylesheet",
        "active_factory_config",
        "factory_loop_interactive",
    ]
    if not site_dir.is_dir():
        result.add("site_dir", str(site_dir), "not a directory")
        return result
    pages = discover_pages(site_dir)
    if not pages:
        result.add("site_dir", str(site_dir), "no factory HTML pages found")
        return result
    for page in pages:
        check_page(site_dir, page, result)
    return result


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Factory site smoke validator")
    parser.add_argument(
        "site_dir",
        nargs="?",
        help="Directory containing built site HTML",
    )
    parser.add_argument(
        "--build",
        action="store_true",
        help="Run offline sample build into a temp dir, then validate",
    )
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit non-zero on any finding (default: non-zero unless --json)",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    if args.build:
        site_dir = build_fixture_site()
    elif args.site_dir:
        site_dir = Path(args.site_dir)
    else:
        parser.error("site-dir is required unless --build is set")

    result = validate_site(site_dir)

    if args.json:
        print(json.dumps(result.to_json(), indent=2, sort_keys=True))
    else:
        if result.ok:
            print(f"OK  factory site smoke ({result.site_dir})")
        else:
            print(f"FAIL  factory site smoke ({result.site_dir})")
            for f in result.findings:
                print(f"  [{f.check}] {f.file}: {f.message}")

    if result.ok:
        return 0
    return 1 if (args.strict or not args.json) else 1


if __name__ == "__main__":
    sys.exit(main())