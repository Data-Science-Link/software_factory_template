#!/usr/bin/env python3
"""Pack PR diff, approved spec, and harness verification output for the Critic reviewer (#41, #121).

Writes to --out-dir (default $OC_ARTIFACT_DIR or a subdir):
  critic-context.md   capped bundle: PR facts, spec, diff, verification log
  critic-meta.txt     verify_status, sizes, hashes
  critic-input.md     .factory/prompts/critic-review.md + critic-context.md (model-facing)

Inputs (--artifact-dir or paths):
  changes.patch   unified diff (required unless fixture carries diff)
  spec.md         optional approved spec
  evidence.md     harness verification output (scripts/opencode-verify.sh)

Live mode: --repo owner/name --pr N fetches PR metadata; diff from --patch or artifact dir.
Fixture: --from-json (see tests/critic-context/).

Stdlib only. Redacts token-like strings before write; optional scan of outputs via
FACTORY_CRITIC_SCAN (default scripts/opencode-artifact-scan.sh).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
END = "=== END CRITIC CONTEXT ==="
TOKEN_RE = re.compile(
    rb"(ghs_[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|"
    rb"Bearer[ \t]+[A-Za-z0-9._-]{10,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.)"
)
VERIFY_PASS_RE = re.compile(r"Result:\s*PASS", re.I)
VERIFY_FAIL_RE = re.compile(r"Result:\s*FAIL", re.I)
VERIFY_NOT_RUN_RE = re.compile(r"Verification run by the harness:\s*not run", re.I)


def die(msg: str, code: int = 1) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def gh(*args: str) -> str:
    try:
        proc = subprocess.run(
            ["gh", "api", *args],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()[:400]
        die(f"gh api failed: {detail or exc}")
    except FileNotFoundError:
        die("`gh` is not installed (required for live --repo/--pr mode)")
    return proc.stdout


def clean(s: str) -> str:
    return (s or "").replace("\r\n", "\n").replace(END, "[removed delimiter]").strip()


def clip(s: str, limit: int) -> str:
    b = s.encode("utf-8")
    if len(b) <= limit:
        return s
    keep = max(limit - 60, 0)
    return b[:keep].decode("utf-8", "ignore") + f"\n[truncated {len(b) - keep} bytes]"


def redact_text(s: str) -> str:
    """Defang token-like substrings; never echo known env key values."""
    out = TOKEN_RE.sub(b"[redacted-token]", s.encode("utf-8", errors="replace"))
    for key in ("DEEPINFRA_API_KEY", "GH_TOKEN", "GITHUB_TOKEN"):
        val = os.environ.get(key)
        if val and len(val) >= 8:
            out = out.replace(val.encode("utf-8"), b"[redacted-env]")
    return out.decode("utf-8", "ignore")


def verify_status(evidence: str) -> str:
    if VERIFY_NOT_RUN_RE.search(evidence):
        return "not_run"
    if VERIFY_FAIL_RE.search(evidence):
        return "fail"
    if VERIFY_PASS_RE.search(evidence):
        return "pass"
    return "unknown"


def read_file(path: Path | None, label: str) -> str:
    if path is None or not path.is_file():
        return ""
    try:
        raw = path.read_bytes()
    except OSError as exc:
        die(f"cannot read {label} file {path}: {exc}")
    return redact_text(raw.decode("utf-8", errors="replace"))


def scan(paths: list[Path]) -> None:
    scan_sh = os.environ.get("FACTORY_CRITIC_SCAN", str(ROOT / "scripts" / "opencode-artifact-scan.sh"))
    existing = [str(p) for p in paths if p.is_file()]
    if not existing:
        return
    r = subprocess.run(["bash", scan_sh, *existing], capture_output=True, text=True)
    if r.returncode != 0:
        die("artifact scan failed on critic outputs (possible secret)")


def load_fixture_json(path: str) -> dict:
    p = Path(path)
    try:
        raw = p.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        die(f"cannot read --from-json {p}: {exc}")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        die(f"--from-json is not valid JSON: {exc}")
    if not isinstance(data, dict):
        die("--from-json root must be a JSON object")
    return data


def load_inputs(args: argparse.Namespace) -> tuple[dict, str, str, str, str]:
    """Return pr_facts, issue_number, diff, spec, evidence."""
    if args.from_json:
        data = load_fixture_json(args.from_json)
        pr = data.get("pr") or {}
        if pr is not None and not isinstance(pr, dict):
            die("--from-json field 'pr' must be an object when present")
        issue = str(data.get("issue_number") or "")
        diff = redact_text(str(data.get("diff") or ""))
        spec = redact_text(str(data.get("spec") or ""))
        evidence = redact_text(str(data.get("evidence") or ""))
        facts = {
            "pr_number": str(pr.get("number") or data.get("pr_number") or ""),
            "pr_title": clean(str(pr.get("title") or data.get("pr_title") or "")),
            "head_ref": (pr.get("head") or {}).get("ref") or data.get("head_ref") or "",
            "head_sha": (pr.get("head") or {}).get("sha") or data.get("head_sha") or "",
            "base_ref": (pr.get("base") or {}).get("ref") or data.get("base_ref") or "main",
        }
        if args.patch:
            diff = read_file(Path(args.patch), "patch")
        return facts, issue, diff, spec, evidence

    if not args.repo or not re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", args.repo):
        die("need --repo owner/name or --from-json")
    if not (args.pr and str(args.pr).isdigit()):
        die("need --pr <digits> or --from-json")

    try:
        pr = json.loads(gh(f"repos/{args.repo}/pulls/{args.pr}"))
    except json.JSONDecodeError as exc:
        die(f"GitHub PR response was not valid JSON: {exc}")
    if not isinstance(pr, dict):
        die("GitHub PR response must be a JSON object")

    head, base = pr.get("head") or {}, pr.get("base") or {}
    ref = head.get("ref") or ""
    m = re.match(r"^oc/issue-([1-9][0-9]{0,8})-", ref)
    issue = m.group(1) if m else ""
    facts = {
        "pr_number": str(pr.get("number")),
        "pr_title": clean(pr.get("title")),
        "head_ref": ref,
        "head_sha": head.get("sha") or "",
        "base_ref": base.get("ref") or "main",
    }

    art = Path(args.artifact_dir) if args.artifact_dir else None
    patch = Path(args.patch) if args.patch else (art / "changes.patch" if art else None)
    spec_p = Path(args.spec) if args.spec else (art / "spec.md" if art else None)
    ev_p = Path(args.evidence) if args.evidence else (art / "evidence.md" if art else None)

    diff = read_file(patch, "patch")
    if not diff.strip():
        try:
            diff = redact_text(
                subprocess.run(
                    ["gh", "api", f"repos/{args.repo}/pulls/{args.pr}",
                     "-H", "Accept: application/vnd.github.v3.diff"],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout
            )
        except subprocess.CalledProcessError:
            diff = ""
    spec = read_file(spec_p, "spec")
    evidence = read_file(ev_p, "evidence")
    return facts, issue, diff, spec, evidence


def build_bundle(
    facts: dict,
    issue: str,
    diff: str,
    spec: str,
    evidence: str,
    max_bytes: int,
) -> str:
    vstat = verify_status(evidence)
    head = (
        f"# Critic context bundle\n\n"
        f"PR #{facts['pr_number']}: {facts['pr_title']}\n"
        f"Branch {facts['head_ref']} @ {facts['head_sha'][:12] if facts['head_sha'] else '?'} "
        f"(base {facts['base_ref']}); linked issue #{issue or '?'}\n"
        f"Harness verification status (parsed): {vstat}\n\n"
    )
    sections: list[tuple[str, str]] = []
    if spec.strip():
        sections.append(("## Approved spec (harness copy)", spec))
    else:
        sections.append(("## Approved spec", "(none in artifact dir)\n"))
    sections.append(("## Diff (this PR)", diff if diff.strip() else "(empty diff)\n"))
    sections.append(("## Harness verification output", evidence if evidence.strip()
                      else "Verification run by the harness: not run (no evidence.md).\n"))

    body = head
    budget = max_bytes - len(body.encode())
    for title, text in sections:
        block = f"{title}\n\n{clean(text)}\n\n"
        enc = block.encode()
        if len(enc) > budget and budget > 500:
            block = clip(block, max(budget, 500))
        body += block
        budget = max_bytes - len(body.encode())
        if budget < 200:
            body += "\n[truncated remaining sections to stay under byte cap]\n"
            break
    body += f"{END}\n"
    return body


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    ap.add_argument("--pr", default=os.environ.get("OC_PR_NUMBER"))
    ap.add_argument("--artifact-dir", default=os.environ.get("OC_ARTIFACT_DIR"))
    ap.add_argument("--patch", help="unified diff (overrides artifact-dir/changes.patch)")
    ap.add_argument("--spec", help="approved spec path")
    ap.add_argument("--evidence", help="verification evidence path")
    ap.add_argument("--from-json", help="offline fixture")
    ap.add_argument("--out-dir", default=os.environ.get("OC_CRITIC_DIR"))
    ap.add_argument("--prompt", type=Path, default=ROOT / ".factory" / "prompts" / "critic-review.md")
    ap.add_argument("--max-bytes", type=int, default=80000)
    args = ap.parse_args()

    if args.max_bytes < 500:
        die("--max-bytes must be at least 500")

    if args.from_json:
        facts, issue, diff, spec, evidence = load_inputs(args)
    else:
        if not args.out_dir and args.artifact_dir:
            args.out_dir = str(Path(args.artifact_dir) / "critic")
        facts, issue, diff, spec, evidence = load_inputs(args)

    if not args.out_dir:
        die("need --out-dir or OC_CRITIC_DIR / OC_ARTIFACT_DIR")

    prompt_path = args.prompt if args.prompt.is_absolute() else ROOT / args.prompt
    if not prompt_path.is_file():
        die(f"prompt not found: {prompt_path}")
    try:
        prompt_body = prompt_path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        die(f"cannot read prompt {prompt_path}: {exc}")

    ctx = build_bundle(facts, issue, diff, spec, evidence, args.max_bytes)
    out = Path(args.out_dir)
    try:
        out.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        die(f"cannot create --out-dir {out}: {exc}")

    ctx_path = out / "critic-context.md"
    input_path = out / "critic-input.md"
    meta_path = out / "critic-meta.txt"

    ctx_path.write_text(ctx, encoding="utf-8")
    input_path.write_text(
        f"{prompt_body.rstrip()}\n\n---\n\n<critic-context>\n{ctx}</critic-context>\n",
        encoding="utf-8",
    )

    def sha(text: str) -> str:
        return hashlib.sha256(text.encode("utf-8")).hexdigest() if text.strip() else "none"

    meta = {
        "pr_number": facts["pr_number"],
        "issue_number": issue or "none",
        "head_sha": facts.get("head_sha") or "none",
        "verify_status": verify_status(evidence),
        "diff_sha256": sha(diff),
        "spec_sha256": sha(spec),
        "evidence_sha256": sha(evidence),
        "context_bytes": str(len(ctx.encode())),
        "input_bytes": str(input_path.read_bytes().__len__()),
        "prompt_path": str(prompt_path.relative_to(ROOT))
        if str(prompt_path).startswith(str(ROOT) + os.sep) else str(prompt_path),
    }
    meta_path.write_text("".join(f"{k}={v}\n" for k, v in meta.items()), encoding="utf-8")

    scan([ctx_path, input_path, meta_path])
    print(
        f"critic-context: PR #{meta['pr_number']} issue {meta['issue_number']}; "
        f"verify={meta['verify_status']}; {meta['context_bytes']} context bytes"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())