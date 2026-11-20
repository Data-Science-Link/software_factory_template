#!/usr/bin/env bash
# Owner helper (#205): record a human product gate on the PR body, wait for pr-check, merge safely.
#
#   bash scripts/factory-merge.sh <pr> --approval '<verbatim quote>' --when '<CT time>' \
#        [--update] [--repo owner/repo]
#
# Owner-run only (protected script; never on the agent command allowlist). Uses gh only.
set -euo pipefail

pr='' approval='' when_ct='' do_update=no repo=''
usage() {
  echo "usage: factory-merge.sh <pr> --approval '<quote>' --when '<CT time>' [--update] [--repo owner/repo]" >&2
  exit 2
}
if [ $# -lt 1 ]; then usage; fi
pr="$1"; shift
while [ $# -gt 0 ]; do
  case "$1" in
    --approval) shift; [ $# -ge 1 ] || usage; approval="$1"; shift ;;
    --when) shift; [ $# -ge 1 ] || usage; when_ct="$1"; shift ;;
    --update) do_update=yes; shift ;;
    --repo) shift; [ $# -ge 1 ] || usage; repo="$1"; shift ;;
    -h|--help) usage ;;
    *) echo "factory-merge: unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$pr" in '' | *[!0-9]*) echo "factory-merge: <pr> must be a positive integer" >&2; exit 2 ;; esac
[ -n "$approval" ] || { echo "factory-merge: --approval is required" >&2; exit 2; }
[ -n "$when_ct" ] || { echo "factory-merge: --when is required" >&2; exit 2; }

if [ -z "$repo" ]; then
  if ! url="$(git remote get-url origin 2>/dev/null)"; then
    echo "factory-merge: could not detect --repo (no origin remote); pass --repo owner/repo" >&2
    exit 2
  fi
  if [[ "$url" =~ github\.com[:/]([^/]+/[^/.]+) ]]; then
    repo="${BASH_REMATCH[1]%.git}"
  else
    echo "factory-merge: could not parse owner/repo from origin URL; pass --repo owner/repo" >&2
    exit 2
  fi
fi
repo_args=(--repo "$repo")

REQUIRED=(pr-check run-records gitleaks)

die() { echo "factory-merge: $*" >&2; exit 1; }

check_required_on_head() {
  local json state
  json="$(gh pr checks "$pr" "${repo_args[@]}" --json name,state,bucket 2>/dev/null || true)"
  state="$(REQUIRED_JSON="$json" python3 - <<'PY'
import json, os, sys
required = ["pr-check", "run-records", "gitleaks"]
raw = os.environ.get("REQUIRED_JSON", "[]")
try:
    checks = json.loads(raw or "[]")
except json.JSONDecodeError:
    print("bad-json"); sys.exit(0)
by = {}
for c in checks:
    name = c.get("name")
    if not name:
        continue
    if c.get("bucket") == "skipping" or (c.get("state") or "").upper() in ("SKIPPED", "NEUTRAL"):
        continue
    by[name] = c
missing = [r for r in required if r not in by]
pending = [r for r in required if by.get(r, {}).get("bucket") == "pending" or (by.get(r, {}).get("state") or "").upper() == "PENDING"]
bad = [r for r in required if r in by and not (by[r].get("bucket") == "pass" and (by[r].get("state") or "").upper() == "SUCCESS")]
if missing:
    print("missing:" + ",".join(missing))
elif pending:
    print("pending:" + ",".join(pending))
elif bad:
    print("bad:" + ",".join(bad))
else:
    print("ok")
PY
)"
  case "$state" in
    ok) return 0 ;;
    missing:*) die "required checks missing on head: ${state#missing:}" ;;
    pending:*) die "required checks pending on head: ${state#pending:} (wait and retry)" ;;
    bad:*) die "required checks not green on head: ${state#bad:}" ;;
    bad-json) die "could not read check status from gh pr checks" ;;
    *) die "unexpected check state: $state" ;;
  esac
}

wait_checks_settle() {
  # Wait until GitHub reports every check completed; then caller re-validates required three.
  gh pr checks "$pr" "${repo_args[@]}" --watch >/dev/null 2>&1 || true
}

commits_behind_main() {
  local head_oid main_oid
  head_oid="$(gh pr view "$pr" "${repo_args[@]}" --json headRefOid -q .headRefOid)"
  main_oid="$(gh repo view "${repo_args[@]}" --json defaultBranchRef -q '.defaultBranchRef.target.oid')"
  gh api "repos/${repo}/compare/${head_oid}...${main_oid}" --jq .behind_by 2>/dev/null \
    || python3 - "$head_oid" "$main_oid" <<'PY'
import json, subprocess, sys
head, main = sys.argv[1], sys.argv[2]
raw = subprocess.run(
    ["gh", "api", f"repos/{sys.argv[3] if len(sys.argv)>3 else ''}"],
    capture_output=True, text=True)
PY
}

default_branch="$(gh repo view "${repo_args[@]}" --json defaultBranchRef -q '.defaultBranchRef.name')"

behind_count() {
  local head_oid cmp
  head_oid="$(gh pr view "$pr" "${repo_args[@]}" --json headRefOid -q .headRefOid)"
  cmp="$(gh api "repos/${repo}/compare/${default_branch}...${head_oid}" --jq .behind_by)"
  printf '%s' "$cmp"
}

read_pr_head() {
  gh pr view "$pr" "${repo_args[@]}" --json state,isCrossRepository,mergeable,headRefOid,headRefName \
    -q '[.state, (.isCrossRepository|tostring), (.mergeable|tostring), .headRefOid, .headRefName] | @tsv'
}

info="$(read_pr_head)"
IFS=$'\t' read -r pr_state pr_cross pr_mergeable head head_ref <<<"$info"
[ "$pr_state" = OPEN ] || die "PR #$pr is $pr_state, not open"
[ "$pr_cross" = false ] || die "PR #$pr is from a fork; refusing"
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || die "cannot read head SHA for PR #$pr"

behind="$(behind_count)"
if [ "${behind:-0}" != 0 ]; then
  if [ "$do_update" = yes ]; then
    echo "factory-merge: PR #$pr is $behind commit(s) behind default branch; running gh pr update-branch"
    gh pr update-branch "$pr" "${repo_args[@]}"
    deadline=$((SECONDS + 600))
    while [ "$SECONDS" -lt "$deadline" ]; do
      sleep 3
      behind="$(behind_count)"
      [ "${behind:-0}" = 0 ] && break
    done
    [ "${behind:-0}" = 0 ] || die "PR #$pr still $behind commit(s) behind after update-branch (conflicts?)"
    head="$(gh pr view "$pr" "${repo_args[@]}" --json headRefOid -q .headRefOid)"
    echo "factory-merge: updated head ${head:0:12}; waiting for CI"
    wait_checks_settle
    check_required_on_head
  else
    die "PR #$pr is $behind commit(s) behind the default branch; pass --update or update manually"
  fi
fi

check_required_on_head

body_file="$(mktemp)"
new_body="$(mktemp)"
trap 'rm -f "$body_file" "$new_body"' EXIT
gh pr view "$pr" "${repo_args[@]}" --json body -q .body >"$body_file"

MERGE_APPROVAL="$approval" MERGE_WHEN="$when_ct" python3 - "$body_file" "$new_body" <<'PY'
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
approval = os.environ["MERGE_APPROVAL"]
when_ct = os.environ["MERGE_WHEN"]
lines = open(src, encoding="utf-8").read().splitlines()
out = []
step6 = re.compile(r"^-\s+\[[ xX]\]\s+\*\*6\.\s+Verify\*\*")
step7 = re.compile(r"^-\s+\[[ xX]\]\s+\*\*7\.\s+Product gate\*\*")
human = re.compile(r"^-\s+Human reviewed before merge:")
quote = approval.replace("\\", "\\\\").replace('"', '\\"')
for line in lines:
    if step6.match(line) and "[ ]" in line:
        line = re.sub(r"-\s+\[\s\]", "- [x]", line, count=1)
    elif step7.match(line):
        line = re.sub(r"-\s+\[\s\]", "- [x]", line, count=1)
        if "Approval (" not in line:
            line = f'{line} — Approval ({when_ct} CT): "{approval}"'
    elif human.match(line):
        line = (
            f'- Human reviewed before merge: [x] yes [ ] no — who: product gate ({when_ct} CT): "{approval}"'
        )
    out.append(line)
open(dst, "w", encoding="utf-8").write("\n".join(out) + ("\n" if out else ""))
PY

if ! cmp -s "$body_file" "$new_body"; then
  gh pr edit "$pr" "${repo_args[@]}" --body-file "$new_body"
  echo "factory-merge: updated PR #$pr body (steps 6–7 / Human reviewed when present)"
  echo "factory-merge: waiting for pr-check after body edit"
  wait_checks_settle
  check_required_on_head
else
  echo "factory-merge: PR body already contained the gate fields; skipping edit"
fi

head_now="$(gh pr view "$pr" "${repo_args[@]}" --json headRefOid -q .headRefOid)"
[ "$head_now" = "$head" ] || die "head SHA changed during merge prep (was ${head:0:12}, now ${head_now:0:12}); re-run"

if ! out="$(gh pr merge "$pr" --merge --match-head-commit "$head" "${repo_args[@]}" 2>&1)"; then
  echo "$out" >&2
  die "gh pr merge failed"
fi

merge_sha="$(gh pr view "$pr" "${repo_args[@]}" --json mergeCommit -q '.mergeCommit.oid' 2>/dev/null || true)"
if [ -z "$merge_sha" ] || [ "$merge_sha" = null ]; then
  merge_sha="$(gh pr view "$pr" "${repo_args[@]}" --json commits --jq '.commits[-1].oid' 2>/dev/null || true)"
fi
[ -n "$merge_sha" ] && [ "$merge_sha" != null ] || die "merged but could not read merge commit SHA"

echo "factory-merge: merged PR #$pr ($head_ref @ ${head:0:12})"
echo "merge_commit: $merge_sha"