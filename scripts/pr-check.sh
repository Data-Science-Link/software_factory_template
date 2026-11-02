#!/usr/bin/env bash
# PR check: holds every PR body to a few factory rules. Script only: no model, no spend.
#
# Input (env vars, or a file path as an argument, so you can run it locally):
#   PR_BODY    PR description            (or: scripts/pr-check.sh body.md [files.txt])
#   PR_FILES   changed paths, one per line
#   PR_AUTHOR  PR author login           (optional)
#   PR_BRANCH  PR head branch            (optional)
#
# Fails when:
#   1. there's no "Closes #N" or "Refs #N" line;
#   2. the PR is agent-written and has no "AI disclosure:" line naming a harness and a model.
#      Agent-written = the body mentions "AI disclosure", or the author ends in [bot],
#      or the branch starts with cursor/. Accepted forms:
#        AI disclosure: harness <name>; model <model ID>
#        or the PR template's "Tools used: <...>" and "Model(s) used: <...>" lines, both filled in;
#   3. the body mentions "Local open-weights" or "DeepInfra" and has no "Cost:" line with a "$"
#      amount or the words "not measured".
#   4. Factory Actions run PR (see below): missing or empty required factory-run block fields.
#
# Factory Actions run PR (rule 4), detected deterministically when either:
#   - the factory-run start HTML marker (added by factory-run-end.sh when filling the block; the empty
#     PR template does not include it) sits alone on its own line. A mention in prose or a code span
#     does not count; or
#   - the AI disclosure line names harness opencode-actions (vision §7 standard PR).
# HTML comments are stripped before rules 1-4 read the body, so unfilled template placeholders
# (e.g. "AI disclosure: harness <!-- ... -->", "Cost: <!-- ... -->") never satisfy a rule.
# Human PRs, Cursor cloud agent PRs without those markers, and legacy agent PRs do not trigger rule 4.
# When triggered, the body must include non-empty: Run ID, Tokens in / cached / out, Predicted cost ($),
# Actual cost ($), Gate, and a spec path `factory/specs/issue-<N>.md` (matches run record fields run_id,
# tokens_in/tokens_cached/tokens_out, predicted_cost_usd, actual_cost_usd, gate, spec_path).
#
# Warns (doesn't fail) when the PR changes .factory/DECISIONS.md, .github/workflows/,
# or this script, so the human looks closer.
set -euo pipefail

if [ $# -ge 1 ]; then PR_BODY="$(cat "$1")"; fi
if [ $# -ge 2 ]; then PR_FILES="$(cat "$2")"; fi
body="${PR_BODY:-}"
files="${PR_FILES:-}"
author="${PR_AUTHOR:-}"
branch="${PR_BRANCH:-}"

# Plain lines: drop HTML comments (template placeholders, even multi-line), **bold** markers,
# and leading list or quote marks.
plain="$(printf '%s\n' "$body" | tr -d '\r' | perl -0pe 's/<!--.*?-->//gs' | sed -E 's/\*\*//g; s/^[[:space:]]*([-*>][[:space:]]+)*//')"

errors=0
fail() { echo "FAIL: $1"; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=PR check::$1"; errors=$((errors + 1)); }
warn() { echo "WARN: $1"; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning title=PR check::$1"; return 0; }
has()  { grep -qiE "$1" <<<"$plain"; }
# Exact line match on the raw body (comments kept), ignoring CR and surrounding whitespace.
has_line() { tr -d '\r' <<<"$body" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -qxF "$1"; }

# 1. Issue link
if ! has '(^|[^[:alnum:]])(closes|refs) #[0-9]+'; then
  fail 'No "Closes #N" or "Refs #N" in the PR body.'
fi

# 2. AI disclosure for agent-written PRs
agent=no
if has 'AI disclosure' || [[ "$author" == *"[bot]" ]] || [[ "$branch" == cursor/* ]]; then agent=yes; fi
if [ "$agent" = yes ]; then
  one_line='^AI disclosure:.*harness[: ]+[^ ;,].*model[: ]+[^ ;,]'
  template='^Tools used[^:]*:[[:space:]]*[^[:space:]<]'
  template_model='^Model\(s\) used[^:]*:[[:space:]]*[^[:space:]<]'
  if ! has "$one_line" && ! { has "$template" && has "$template_model"; }; then
    fail 'Agent-written PR needs "AI disclosure: harness <name>; model <model ID>".'
  fi
fi

# 3. Cost line for Local open-weights runs (and factory runs that mention DeepInfra)
if has 'local open-weights|deepinfra' && ! has '^Cost:.*[$][0-9]' && ! has '^Cost:.*not measured'; then
  fail 'Local open-weights PR needs a "Cost:" line with a $ amount (e.g. "Cost: $0.04 on DeepInfra") or "not measured".'
fi

# 4. Factory Actions run block (opencode-actions harness or factory-run HTML markers)
factory_run=no
if has_line '<!-- factory-run:start -->' || has '^AI disclosure:.*harness[[:space:]]+opencode-actions'; then
  factory_run=yes
fi
if [ "$factory_run" = yes ]; then
  if ! has '^Run ID:[[:space:]]*[^[:space:]]'; then
    fail 'Factory run PR needs a non-empty "Run ID:" line (run record run_id).'
  fi
  if ! has '^Tokens in / cached / out:[[:space:]]*[0-9]'; then
    fail 'Factory run PR needs "Tokens in / cached / out:" with token counts (run record tokens_in, tokens_cached, tokens_out).'
  fi
  if ! has '^Predicted cost:.*[$][0-9]'; then
    fail 'Factory run PR needs "Predicted cost:" with a $ amount (run record predicted_cost_usd).'
  fi
  if ! has '^Actual cost:.*[$][0-9]'; then
    fail 'Factory run PR needs "Actual cost:" with a $ amount (run record actual_cost_usd).'
  fi
  if ! has '^Gate:[[:space:]]*[^[:space:]]'; then
    fail 'Factory run PR needs a non-empty "Gate:" line (run record gate).'
  fi
  if ! has 'factory/specs/issue-[0-9]+\.md'; then
    fail 'Factory run PR needs a spec link to factory/specs/issue-<N>.md (run record spec_path).'
  fi
fi

# Warnings: paths the human should look at closely
while IFS= read -r f; do
  case "$f" in
    .factory/DECISIONS.md) warn "Changes .factory/DECISIONS.md: check the entry matches what was decided." ;;
    .github/workflows/*)   warn "Changes $f: CI changes need a careful human look." ;;
    scripts/pr-check.sh)   warn "Changes the PR check itself: review it before trusting this result." ;;
  esac
done <<<"$files"

if [ "$errors" -gt 0 ]; then
  echo "PR check: $errors problem(s). Edit the PR body to fix them; the check reruns on edit."
  exit 1
fi
echo "PR check: passed."
