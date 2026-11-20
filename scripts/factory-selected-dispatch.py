#!/usr/bin/env python3
"""Dispatch `factory:selected` issues: kick `/oc spec` and routed `/oc` runs (#111).

Thin-workflow helper: owner-only checks, idempotency markers, per-issue cap gates, and
`gh issue comment` posts that start with `/oc spec` or `/oc run` so the existing
`opencode-spec.yml` and `opencode-spike.yml` paths trigger unchanged.

Subcommands (run from the owner's gh login or a workflow step that holds an owner token):

  phase-a   Label added: verify actor and `factory:selected`, refuse when over cap,
            post at most one `/oc spec` kick comment on the issue.
  phase-b   After a spec draft or approval: auto-approve trivial/normal drafts via
            `factory-approve-spec.py`, wait on high risk without owner approval,
            post at most one `/oc run` kick when an approved spec passes run-start checks.

Offline tests pass `--issue-json`, `--comments-json`, and `--runs-dir`; live mode uses `gh`.
Exit 0 on intentional no-ops (non-owner, already kicked, waiting on owner). Exit 3 when
the per-issue cap blocks the next step (`refused=over_cap` on --github-output).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

SELECTED_LABEL = "factory:selected"
SPEC_KICK = "<!-- factory-selected-spec-kick v1 -->"
RUN_KICK = "<!-- factory-selected-run-kick v1 -->"
WAIT_HIGH = "<!-- factory-selected-wait-high v1 -->"

DRAFT_TAG = "<!-- factory-spec-draft v1 -->"
APPROVED_MARKER = "<!-- factory-spec v1 -->"
BOT_LOGINS = frozenset({"github-actions", "github-actions[bot]", "app/github-actions"})
GROK_APPROVES = frozenset({"trivial", "normal"})
DEFAULT_RUNS = ROOT / "factory" / "runs"
DEFAULT_MODELS = ROOT / ".factory" / "models.yaml"


def die(msg: str, code: int = 1) -> None:
    print(f"selected-dispatch: {msg}", file=sys.stderr)
    sys.exit(code)


def load_run_start():
    spec = importlib.util.spec_from_file_location("factory_run_start", HERE / "factory-run-start.py")
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def load_issue_spend():
    spec = importlib.util.spec_from_file_location("factory_issue_spend", HERE / "factory-issue-spend.py")
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def gh_json(args: list[str]) -> Any:
    p = subprocess.run(["gh"] + args, capture_output=True, text=True)
    if p.returncode != 0:
        die(f"gh failed: {(p.stderr or p.stdout).strip()[:300]}", 1)
    return json.loads(p.stdout)


def repo_owner_login(repo: str) -> str:
    override = (os.environ.get("FACTORY_OWNER_LOGIN") or "").strip()
    if override:
        return override
    p = subprocess.run(
        ["gh", "api", f"repos/{repo}", "--jq", ".owner.login"],
        capture_output=True,
        text=True,
    )
    if p.returncode != 0:
        die(f"could not resolve repo owner: {p.stderr.strip()[:200]}")
    login = (p.stdout or "").strip().strip('"')
    if not login:
        die("could not resolve repo owner login")
    return login


def load_issue(repo: str, issue: str, issue_json: Path | None) -> dict[str, Any]:
    if issue_json is not None:
        return json.loads(issue_json.read_text(encoding="utf-8"))
    return gh_json(["api", f"repos/{repo}/issues/{issue}"])


def load_comments(repo: str, issue: str, comments_json: Path | None) -> list[dict[str, Any]]:
    if comments_json is not None:
        raw = json.loads(comments_json.read_text(encoding="utf-8"))
        if isinstance(raw, dict) and "comments" in raw:
            return list(raw["comments"])
        if isinstance(raw, list):
            return raw
        die("comments JSON must be a list or {comments: [...]}")
    p = subprocess.run(
        [
            "gh",
            "api",
            "--paginate",
            f"repos/{repo}/issues/{issue}/comments",
            "--jq",
            ".[]",
        ],
        capture_output=True,
        text=True,
    )
    if p.returncode != 0:
        die(f"could not list comments: {p.stderr.strip()[:200]}")
    return [json.loads(line) for line in p.stdout.splitlines() if line.strip()]


def issue_has_label(issue: dict[str, Any], name: str) -> bool:
    labels = issue.get("labels") or []
    return any((lb.get("name") if isinstance(lb, dict) else lb) == name for lb in labels)


def comment_login(c: dict[str, Any]) -> str:
    user = c.get("user") or {}
    return str(user.get("login") or "")


def comment_body(c: dict[str, Any]) -> str:
    return (c.get("body") or "").replace("\r\n", "\n")


def is_owner_comment(c: dict[str, Any]) -> bool:
    return c.get("author_association") == "OWNER"


def prior_spend_usd(issue: int, comments: list[dict[str, Any]], runs_dir: Path) -> float:
    spend_mod = load_issue_spend()
    spend: dict[str, float] = {}
    warned: list[str] = []
    spend_mod.load_runs_dir_spend(runs_dir, issue, spend, warned)
    spend_mod.load_comments_spend(comments, issue, spend, warned)
    return round(sum(spend.values()), 4)


def write_output(path: Path | None, pairs: dict[str, str]) -> None:
    if path is None:
        return
    with open(path, "a", encoding="utf-8") as fh:
        for k, v in pairs.items():
            fh.write(f"{k}={v}\n")


def spec_preflight_usd(
    issue: int, context: Path | None, labels: Path | None, guidance: str, models: Path
) -> float:
    args = [
        sys.executable,
        str(HERE / "opencode-spec-draft.py"),
        "--models",
        str(models),
        "preflight",
        "--issue",
        str(issue),
        "--guidance",
        guidance,
    ]
    if context is not None and context.is_file():
        args.extend(["--context", str(context)])
    if labels is not None and labels.is_file():
        args.extend(["--labels", str(labels)])
    p = subprocess.run(args, capture_output=True, text=True)
    predicted: float | None = None
    for line in (p.stdout or "").splitlines():
        if line.startswith("predicted_spec_run_usd="):
            predicted = float(line.split("=", 1)[1])
    if predicted is None:
        die((p.stderr or p.stdout or "preflight failed").strip())
    return predicted


def cap_usd(models: Path) -> float:
    import yaml

    data = yaml.safe_load(models.read_text(encoding="utf-8"))
    raw = (data.get("budget") or {}).get("issue_cap_usd")
    if raw is None:
        die("models.yaml budget.issue_cap_usd is not set")
    return float(raw)


def kick_present(comments: list[dict[str, Any]], marker: str) -> bool:
    return any(marker in comment_body(c) for c in comments)


def latest_draft(comments: list[dict[str, Any]]) -> dict[str, Any] | None:
    rows = []
    for c in comments:
        body = comment_body(c)
        if comment_login(c) not in BOT_LOGINS:
            continue
        if not body.startswith(DRAFT_TAG):
            continue
        rows.append(c)
    if not rows:
        return None
    rows.sort(key=lambda c: str(c.get("created_at") or ""))
    return rows[-1]


def latest_approved_spec(comments: list[dict[str, Any]]) -> tuple[dict[str, Any] | None, str | None]:
    frs = load_run_start()
    rows = []
    for c in comments:
        if not is_owner_comment(c):
            continue
        body = comment_body(c)
        if APPROVED_MARKER not in body:
            continue
        _, rest = frs.split_marker(body)
        fm, _ = frs.split_front_matter(rest)
        if fm and fm.get("status") == "approved":
            rows.append(c)
    if not rows:
        return None, None
    rows.sort(key=lambda c: str(c.get("created_at") or ""))
    c = rows[-1]
    return c, comment_body(c)


def parse_risk_from_draft(body: str) -> str:
    m = re.search(
        r"^---[ \t]*\n(.*?)\n---",
        body.replace("\r\n", "\n").split(DRAFT_TAG, 1)[-1].lstrip(),
        re.S,
    )
    if not m:
        return "high"
    hit = re.search(r"^risk:\s*(\S+)", m.group(1), re.M)
    return (hit.group(1) if hit else "high").strip().lower()


def post_comment(issue: str, repo: list[str], body: str, dry_run: bool) -> None:
    if dry_run:
        print(body)
        return
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as f:
        f.write(body)
        path = f.name
    try:
        p = subprocess.run(
            ["gh", "issue", "comment", issue, *repo, "--body-file", path],
            capture_output=True,
            text=True,
        )
    finally:
        Path(path).unlink(missing_ok=True)
    if p.returncode != 0:
        die(f"gh issue comment failed: {p.stderr.strip()[:200]}")


def cmd_phase_a(args: argparse.Namespace) -> int:
    if args.label != SELECTED_LABEL:
        print(f"selected-dispatch: ignored (label {args.label!r} is not {SELECTED_LABEL})")
        write_output(args.github_output, {"action": "noop", "reason": "wrong_label"})
        return 0

    owner = repo_owner_login(args.repo)
    if args.actor != owner:
        print(f"selected-dispatch: ignored (actor {args.actor!r} is not repo owner {owner!r})")
        write_output(args.github_output, {"action": "noop", "reason": "non_owner"})
        return 0

    issue = load_issue(args.repo, args.issue, args.issue_json)
    if not issue_has_label(issue, SELECTED_LABEL):
        print(f"selected-dispatch: ignored (issue #{args.issue} no longer has {SELECTED_LABEL})")
        write_output(args.github_output, {"action": "noop", "reason": "label_missing"})
        return 0

    comments = load_comments(args.repo, args.issue, args.comments_json)
    if kick_present(comments, SPEC_KICK):
        print(f"selected-dispatch: noop (spec kick already posted on #{args.issue})")
        write_output(args.github_output, {"action": "noop", "reason": "spec_already_kicked"})
        return 0

    prior = prior_spend_usd(int(args.issue), comments, args.runs_dir)
    predicted = spec_preflight_usd(
        int(args.issue), args.context, args.labels, args.guidance, args.models
    )
    cap = cap_usd(args.models)
    if prior >= cap or (prior + predicted) > cap:
        print(
            f"selected-dispatch: refused: prior ${prior:.4f} plus predicted spec ${predicted:.4f} "
            f"is at or over the ${cap:.2f} issue cap",
            file=sys.stderr,
        )
        write_output(
            args.github_output,
            {
                "refused": "over_cap",
                "prior_spend_usd": f"{prior:.4f}",
                "predicted_cost_usd": f"{predicted:.4f}",
                "cap_usd": f"{cap:.2f}",
            },
        )
        return 3

    body = f"/oc spec\n{SPEC_KICK}\n"
    repo_args = ["--repo", args.repo] if args.repo else []
    post_comment(args.issue, repo_args, body, args.dry_run)
    if not args.dry_run:
        print(f"selected-dispatch: posted /oc spec kick on issue #{args.issue}")
    write_output(args.github_output, {"action": "posted_spec", "issue": args.issue})
    return 0


def approve_draft(
    issue: str, draft: dict[str, Any], repo: list[str], approved_by: str, dry_run: bool
) -> bool:
    cid = str(draft.get("id") or "")
    url = str(draft.get("html_url") or draft.get("url") or "")
    ref = url if url else cid
    if not ref:
        die("draft comment has no id or url")
    if dry_run:
        print(f"selected-dispatch: would approve draft {ref} as {approved_by}")
        return True
    p = subprocess.run(
        [
            sys.executable,
            str(HERE / "factory-approve-spec.py"),
            issue,
            ref,
            "--approved-by",
            approved_by,
            *repo,
        ],
        capture_output=True,
        text=True,
    )
    if p.returncode != 0:
        die((p.stderr or p.stdout or "approve-spec failed").strip())
    print(p.stdout.strip())
    return True


def run_start_allows(spec_text: str, issue: str, comments: list[dict[str, Any]], runs_dir: Path) -> tuple[bool, str]:
    frs = load_run_start()
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as f:
        f.write(spec_text)
        spec_path = Path(f.name)
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as cf:
        json.dump(comments, cf)
        cpath = Path(cf.name)
    try:
        p = subprocess.run(
            [
                sys.executable,
                str(HERE / "factory-run-start.py"),
                "--spec",
                str(spec_path),
                "--issue",
                issue,
                "--runs-dir",
                str(runs_dir),
                "--comments-json",
                str(cpath),
            ],
            capture_output=True,
            text=True,
        )
    finally:
        spec_path.unlink(missing_ok=True)
        cpath.unlink(missing_ok=True)
    if p.returncode == 0:
        return True, ""
    err = (p.stderr or p.stdout or "run-start refused").strip()
    code = "refused"
    for line in p.stderr.splitlines():
        if line.startswith("run-start: refused:"):
            err = line.split(":", 1)[1].strip()
        if "refused=" in line:
            pass
    return False, err or code


def cmd_phase_b(args: argparse.Namespace) -> int:
    issue_data = load_issue(args.repo, args.issue, args.issue_json)
    if not issue_has_label(issue_data, SELECTED_LABEL):
        print(f"selected-dispatch: ignored (issue #{args.issue} lacks {SELECTED_LABEL})")
        write_output(args.github_output, {"action": "noop", "reason": "not_selected"})
        return 0

    comments = load_comments(args.repo, args.issue, args.comments_json)
    repo_args = ["--repo", args.repo] if args.repo else []

    if kick_present(comments, RUN_KICK):
        print(f"selected-dispatch: noop (run kick already posted on #{args.issue})")
        write_output(args.github_output, {"action": "noop", "reason": "run_already_kicked"})
        return 0

    draft = latest_draft(comments)
    approved_c, approved_body = latest_approved_spec(comments)

    if approved_c is None and draft is None:
        print(f"selected-dispatch: noop (no spec draft or approval on #{args.issue})")
        write_output(args.github_output, {"action": "noop", "reason": "no_spec"})
        return 0

    if approved_c is None and draft is not None:
        risk = parse_risk_from_draft(comment_body(draft))
        if risk not in GROK_APPROVES:
            if kick_present(comments, WAIT_HIGH):
                print(f"selected-dispatch: waiting (high-risk draft; owner approval still needed)")
                write_output(args.github_output, {"action": "wait", "reason": "high_risk_spec"})
                return 0
            body = (
                f"{WAIT_HIGH}\n"
                "**`factory:selected`:** spec draft is **high risk**. "
                "The Factory Manager will not auto-approve; the owner must approve with "
                "`scripts/factory-approve-spec.py … --approved-by michael` before the build runs."
            )
            post_comment(args.issue, repo_args, body, args.dry_run)
            write_output(args.github_output, {"action": "wait", "reason": "high_risk_spec"})
            return 0
        approve_draft(args.issue, draft, repo_args, "grok-bot", args.dry_run)
        if args.dry_run:
            approved_body = comment_body(draft)
        else:
            comments = load_comments(args.repo, args.issue, args.comments_json)
            _approved_c, approved_body = latest_approved_spec(comments)
            if approved_body is None:
                die("approved spec missing after auto-approve")

    if approved_body is None:
        die("no approved spec to run")

    ok, why = run_start_allows(approved_body, args.issue, comments, args.runs_dir)
    if not ok:
        print(f"selected-dispatch: refused run start: {why}", file=sys.stderr)
        if "cap" in why.lower() or "over_cap" in why:
            write_output(args.github_output, {"refused": "over_cap", "detail": why[:200]})
            return 3
        write_output(args.github_output, {"action": "refused", "reason": why[:200]})
        return 0

    body = f"/oc run\n{RUN_KICK}\n"
    post_comment(args.issue, repo_args, body, args.dry_run)
    if not args.dry_run:
        print(f"selected-dispatch: posted /oc run kick on issue #{args.issue}")
    write_output(args.github_output, {"action": "posted_run", "issue": args.issue})
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add_common(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("--issue", required=True)
        sp.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
        sp.add_argument("--issue-json", type=Path, help="fixture issue object")
        sp.add_argument("--comments-json", type=Path, help="fixture comments list or {comments}")
        sp.add_argument("--runs-dir", type=Path, default=DEFAULT_RUNS)
        sp.add_argument("--models", type=Path, default=DEFAULT_MODELS)
        sp.add_argument("--dry-run", action="store_true")
        sp.add_argument("--github-output", type=Path, default=None)
        sp.add_argument("--owner-login", default="", help="override repo owner login (tests)")

    pa = sub.add_parser("phase-a", help="label added: kick /oc spec")
    add_common(pa)
    pa.add_argument("--actor", required=True, help="login that added the label")
    pa.add_argument("--label", required=True)
    pa.add_argument("--context", type=Path, help="issue-context.md for preflight")
    pa.add_argument("--labels", type=Path, help="issue-labels.txt for preflight")
    pa.add_argument("--guidance", default="", help="/oc spec guidance tail")

    pb = sub.add_parser("phase-b", help="after spec: approve if allowed and kick /oc run")
    add_common(pb)

    a = ap.parse_args()
    if not a.issue.isdigit():
        die("issue must be digits")
    if not a.repo:
        die("--repo or GITHUB_REPOSITORY is required")
    if getattr(a, "owner_login", None):
        os.environ["FACTORY_OWNER_LOGIN"] = a.owner_login

    if a.cmd == "phase-a":
        return cmd_phase_a(a)
    return cmd_phase_b(a)


if __name__ == "__main__":
    sys.exit(main())