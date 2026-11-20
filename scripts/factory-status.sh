#!/usr/bin/env bash
# Owner helper (#205): one compact digest — open PRs, in-flight /oc runs, unapproved spec drafts.
#
#   bash scripts/factory-status.sh [--repo owner/repo]
#
# Owner-run only (protected). Uses gh only.
set -euo pipefail

repo=''
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) shift; [ $# -ge 1 ] || { echo "usage: factory-status.sh [--repo owner/repo]" >&2; exit 2; }; repo="$1"; shift ;;
    -h|--help) echo "usage: factory-status.sh [--repo owner/repo]" >&2; exit 0 ;;
    *) echo "factory-status: unknown argument $1" >&2; exit 2 ;;
  esac
done

if [ -z "$repo" ]; then
  if ! url="$(git remote get-url origin 2>/dev/null)"; then
    echo "factory-status: could not detect --repo (no origin remote); pass --repo owner/repo" >&2
    exit 2
  fi
  if [[ "$url" =~ github\.com[:/]([^/]+/[^/.]+) ]]; then
    repo="${BASH_REMATCH[1]%.git}"
  else
    echo "factory-status: could not parse owner/repo from origin URL; pass --repo owner/repo" >&2
    exit 2
  fi
fi
repo_args=(--repo "$repo")

pr_list_json="$(gh pr list "${repo_args[@]}" --state open --limit 100 \
  --json number,title,headRefOid,baseRefOid,statusCheckRollup,body 2>/dev/null)" \
  || { echo "factory-status: gh pr list failed" >&2; exit 1; }
[ -n "$pr_list_json" ] || pr_list_json='[]'

STATUS_REPO="$repo" PR_LIST_JSON="$pr_list_json" python3 - <<'PY'
import json, os, subprocess, sys

repo = os.environ["STATUS_REPO"]
prs = json.loads(os.environ.get("PR_LIST_JSON") or "[]")
default_branch = subprocess.check_output(
    ["gh", "repo", "view", repo, "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name"],
    text=True,
).strip()
required = ("pr-check", "run-records", "gitleaks")

def behind(head):
    if not default_branch or not head:
        return "?"
    try:
        n = subprocess.check_output(
            [
                "gh", "api",
                f"repos/{repo}/compare/{default_branch}...{head}",
                "--jq", ".behind_by",
            ],
            text=True,
        ).strip()
        return n
    except subprocess.CalledProcessError:
        return "?"

def check_summary(rollup):
    by = {}
    for c in rollup or []:
        name = c.get("name")
        if not name:
            continue
        if c.get("bucket") == "skipping":
            continue
        st = (c.get("state") or c.get("conclusion") or "").upper()
        if st in ("SKIPPED", "NEUTRAL"):
            continue
        by[name] = c.get("bucket") or st.lower()
    parts = []
    for r in required:
        parts.append(f"{r}:{by.get(r, 'missing')}")
    return " ".join(parts)

def cost_line(body):
    for line in (body or "").splitlines():
        if line.startswith("Cost:"):
            return line.strip()
    return ""

print("=== Open PRs ===")
if not prs:
    print("(none)")
else:
    for p in sorted(prs, key=lambda x: x["number"]):
        head = p.get("headRefOid") or ""
        short = head[:7] if head else "?"
        b = behind(head)
        checks = check_summary(p.get("statusCheckRollup"))
        cost = cost_line(p.get("body") or "")
        title = (p.get("title") or "").replace("\n", " ")
        line = f"#{p['number']} {title} | head {short} | behind {b} | {checks}"
        if cost:
            line += f" | {cost}"
        print(line)

print()
print("=== /oc workflow runs (in flight) ===")
runs_raw = subprocess.check_output(
    [
        "gh", "run", "list", "--repo", repo, "--limit", "80",
        "--json", "workflowName,status,conclusion,displayTitle,headBranch,databaseId",
    ],
    text=True,
)
runs = json.loads(runs_raw)
oc = [
    r for r in runs
    if (r.get("workflowName") or "").startswith("opencode-")
    and (r.get("status") or "") in ("queued", "in_progress", "waiting", "requested", "pending")
]
if not oc:
    print("(none)")
else:
    for r in oc:
        print(
            f"{r.get('workflowName')}: {r.get('displayTitle')} "
            f"[{r.get('headBranch')}] run {r.get('databaseId')} ({r.get('status')})"
        )

print()
print("=== Open issues with unapproved spec draft ===")
issues_raw = subprocess.check_output(
    [
        "gh", "issue", "list", "--repo", repo, "--state", "open", "--label", "factory:selected",
        "--limit", "200", "--json", "number,title",
    ],
    text=True,
)
issues = json.loads(issues_raw)
draft_tag = "<!-- factory-spec-draft v1 -->"
approved_tag = "<!-- factory-spec v1 -->"
draft_issues = []
for it in issues:
    num = it["number"]
    comments = json.loads(
        subprocess.check_output(
            ["gh", "issue", "view", str(num), "--repo", repo, "--json", "comments"],
            text=True,
        )
    ).get("comments", [])
    spec_comments = []
    for c in comments:
        body = (c.get("body") or "").replace("\r\n", "\n")
        first = body.split("\n", 1)[0].strip()
        if first in (draft_tag, approved_tag) or first.startswith(draft_tag):
            spec_comments.append((c.get("createdAt") or "", first, body))
    if not spec_comments:
        continue
    spec_comments.sort(key=lambda x: x[0])
    _when, tag, body = spec_comments[-1]
    is_draft = draft_tag in tag or body.startswith(draft_tag)
    if is_draft and __import__("re").search(r"(?m)^status:\s*draft\s*$", body):
        draft_issues.append((num, it.get("title") or "", _when[:10] if _when else ""))

if not draft_issues:
    print("(none)")
else:
    for num, title, when in sorted(draft_issues):
        print(f"#{num} {title} (draft {when})")
PY