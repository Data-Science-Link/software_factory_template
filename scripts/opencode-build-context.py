#!/usr/bin/env python3
"""Job A helper: fetch issue context for the /oc worker prompt (read-only token, stdlib + spec checker).

Writes to --out-dir (default $OC_ARTIFACT_DIR):
  issue-context.md   issue title/body, latest owner-approved spec, recent owner comments (capped)
  context-meta.txt   spec_comment_id=<id|none>, spec_sha256 and sizes; read by agent-run and publish
  spec.md            only when an approved spec exists: the exact spec (marker line on, LF line
                     ends, one trailing newline). The harness commits it as
                     factory/specs/issue-<N>.md; the worker never copies it by hand (#75).

Only comments with author_association OWNER count. The spec is the latest owner comment that
contains the factory-spec marker and has front matter status: approved; it must pass
factory-spec-check.py or this script exits 1 (fail closed). No spec -> issue body only.
Live mode uses `gh api` (GH_TOKEN from the workflow step). --from-json reads a fixture instead.

--print-spec <comment id>: fetch that one comment again, re-run the same checks (owner, marker,
status approved, factory-spec-check.py, belongs to --issue) and print the canonical spec text to
stdout. Publish uses it to confirm the committed spec file is that exact text. Exit 3 (not 1)
when the token may not read issue comments (HTTP 403), so publish can fall back to
--check-spec-file <path>: re-validate a saved canonical spec (job A's spec.md) and print it.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

MARKER = "<!-- factory-spec v1 -->"
END = "=== END ISSUE CONTEXT ==="
HERE = Path(__file__).resolve().parent


def die(msg: str) -> None:
    print(f"build-context: FAIL — {msg}", file=sys.stderr)
    sys.exit(1)


def gh(*args: str) -> str:
    return subprocess.run(["gh", "api", *args], check=True, capture_output=True, text=True).stdout


def load(args: argparse.Namespace) -> tuple[dict, list]:
    if args.from_json:
        data = json.loads(Path(args.from_json).read_text(encoding="utf-8"))
        return data["issue"], data["comments"]
    repo, n = args.repo, args.issue
    issue = json.loads(gh(f"repos/{repo}/issues/{n}"))
    lines = gh("--paginate", "--jq", ".[]", f"repos/{repo}/issues/{n}/comments?per_page=100")
    return issue, [json.loads(line) for line in lines.splitlines() if line.strip()]


def is_owner(c: dict) -> bool:
    return c.get("author_association") == "OWNER"


def spec_text(body: str) -> str:
    """Spec from the marker on (text before the marker is tolerated and dropped)."""
    return body[body.index(MARKER):]


def canonical_spec(body: str) -> str:
    """Exact spec file text: from the marker on, LF line ends, one trailing newline."""
    return spec_text(body.replace("\r\n", "\n")).rstrip() + "\n"


def says_approved(text: str) -> bool:
    rest = text.replace("\r\n", "\n").split(MARKER, 1)[1].lstrip()
    m = re.match(r"---[ \t]*\n(.*?)\n---[ \t]*(\n|$)", rest, re.S)
    return bool(m and re.search(r"^status:\s*[\"']?approved[\"']?\s*$", m.group(1), re.M))


def check_spec(text: str) -> None:
    mod_spec = importlib.util.spec_from_file_location("spec_check", HERE / "factory-spec-check.py")
    mod = importlib.util.module_from_spec(mod_spec)
    try:
        mod_spec.loader.exec_module(mod)
    except ImportError as exc:
        die(f"cannot validate the approved spec ({exc}); install requirements-factory.txt")
    body = mod.strip_comment_wrapper(text)
    errors = mod.validate_text(body)
    fm, _ = mod.split_front_matter(body)
    if not errors and (not fm or fm.get("status") != "approved"):
        errors.append("front matter status is not approved")
    if errors:
        die("approved spec comment is malformed:\n  " + "\n  ".join(errors))


def clean(s: str | None) -> str:
    return (s or "").replace("\r\n", "\n").replace(END, "[removed delimiter]").strip()


def clip(s: str, limit: int) -> str:
    b = s.encode("utf-8")
    if len(b) <= limit:
        return s
    keep = max(limit - 60, 0)
    return b[:keep].decode("utf-8", "ignore") + f"\n[truncated {len(b) - keep} bytes]"


def print_spec(args: argparse.Namespace) -> int:
    cid = str(args.print_spec)
    if not cid.isdigit():
        die("--print-spec needs a numeric comment id")
    if args.from_json:
        _, comments = load(args)
        found = [c for c in comments if str(c.get("id")) == cid]
        if not found:
            die(f"comment {cid} not in fixture")
        c = found[0]
    else:
        if not (args.repo and args.issue):
            die("--print-spec needs --repo and --issue")
        try:
            c = json.loads(gh(f"repos/{args.repo}/issues/comments/{cid}"))
        except subprocess.CalledProcessError as exc:
            if "HTTP 403" in (exc.stderr or ""):
                # The job token can't read issue comments (no issues: read). Exit 3 so the caller
                # can fall back to --check-spec-file on job A's copy and say so in the PR.
                print(f"opencode-build-context: no permission to read comment {cid} (HTTP 403)", file=sys.stderr)
                return 3
            die(f"cannot fetch spec comment {cid}: {(exc.stderr or '').strip()[:200]}")
        if not str(c.get("issue_url", "")).endswith(f"/issues/{args.issue}"):
            die(f"comment {cid} does not belong to issue #{args.issue}")
    body = c.get("body") or ""
    if not is_owner(c) or MARKER not in body or not says_approved(spec_text(body)):
        die(f"comment {cid} is not an owner-approved spec comment")
    text = canonical_spec(body)
    check_spec(text)
    sys.stdout.write(text)
    return 0


def check_spec_file(path: str) -> int:
    """Fallback for --print-spec: validate a saved canonical spec (job A's spec.md) and print it."""
    try:
        text = Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        die(f"cannot read spec file {path}: {exc}")
    if not text.startswith(MARKER) or not says_approved(text):
        die(f"{path} is not an approved spec (marker on line 1, status approved)")
    if canonical_spec(text) != text:
        die(f"{path} is not in canonical form")
    check_spec(text)
    sys.stdout.write(text)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    ap.add_argument("--issue", default=os.environ.get("OC_ISSUE_NUMBER"))
    ap.add_argument("--out-dir", default=os.environ.get("OC_ARTIFACT_DIR"))
    ap.add_argument("--from-json", help="fixture: {\"issue\": {...}, \"comments\": [...]} (gh API shape)")
    ap.add_argument("--max-bytes", type=int, default=60000)
    ap.add_argument("--max-comments", type=int, default=5)
    ap.add_argument("--comment-bytes", type=int, default=1500)
    ap.add_argument("--print-spec", metavar="COMMENT_ID", help="print the canonical spec of this comment")
    ap.add_argument("--check-spec-file", metavar="PATH", help="validate a saved canonical spec and print it")
    args = ap.parse_args()
    if args.issue and not str(args.issue).isdigit():
        die("issue number must be digits")
    if args.check_spec_file is not None:
        return check_spec_file(args.check_spec_file)
    if args.print_spec is not None:
        return print_spec(args)
    if not args.out_dir or not (args.from_json or (args.repo and args.issue)):
        die("need --out-dir and either --from-json or --repo/--issue")

    issue, comments = load(args)
    owner = [c for c in comments if is_owner(c)]
    specs = [c for c in owner if MARKER in (c.get("body") or "")]
    approved = [c for c in specs if says_approved(spec_text(c["body"]))]
    spec = approved[-1] if approved else None

    parts = [f"## Issue #{issue.get('number', args.issue)}: {clean(issue.get('title'))}\n"]
    spec_block, spec_id, canonical = "", "none", None
    if spec:
        text = spec_text(clean(spec["body"]))
        check_spec(text)
        canonical = canonical_spec(spec["body"])
        check_spec(canonical)
        spec_id = str(spec["id"])
        spec_block = f"\n## Approved spec (owner comment {spec_id})\n\n{text}\n"
    else:
        spec_block = "\n## Approved spec\n\nNo approved spec comment found; work from the issue body and the /oc instruction.\n"

    budget = args.max_bytes - len(parts[0].encode()) - len(spec_block.encode()) - 200
    if budget < 500:
        die(f"approved spec alone exceeds the {args.max_bytes}-byte context cap")
    body = clip(clean(issue.get("body")), budget)
    parts.append(f"\n### Issue body\n\n{body}\n")
    parts.append(spec_block)
    budget -= len(parts[1].encode())

    recent = [c for c in owner if c is not spec and MARKER not in (c.get("body") or "")
              and not (c.get("body") or "").lstrip().startswith("/oc")][-args.max_comments:]
    shown = []
    for c in reversed(recent):  # newest first, so the cap drops the oldest
        item = f"\n- comment {c.get('id')} ({c.get('created_at', '')}):\n\n{clip(clean(c.get('body')), args.comment_bytes)}\n"
        if len(item.encode()) > budget:
            break
        shown.insert(0, item)
        budget -= len(item.encode())
    parts.append(f"\n## Recent owner comments ({len(shown)})\n" + "".join(shown))

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    ctx = "".join(parts)
    (out / "issue-context.md").write_text(ctx, encoding="utf-8")
    spec_sha = "none"
    if canonical is not None:
        (out / "spec.md").write_bytes(canonical.encode("utf-8"))
        spec_sha = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    (out / "context-meta.txt").write_text(
        f"spec_comment_id={spec_id}\nspec_sha256={spec_sha}\ncontext_bytes={len(ctx.encode())}\n"
        f"owner_comments={len(shown)}\n",
        encoding="utf-8")
    msg = f"approved spec comment {spec_id}" if spec else "no approved spec found"
    print(f"build-context: {msg}; {len(ctx.encode())} bytes; {len(shown)} owner comment(s)")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as fh:
            fh.write(f"- Issue context: {msg}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
