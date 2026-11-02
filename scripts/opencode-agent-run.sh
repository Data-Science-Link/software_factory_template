#!/usr/bin/env bash
# Job A helper: run OpenCode headless, emit patch + summary artifacts. No GitHub write token.
set -euo pipefail

: "${OC_INSTRUCTION:?OC_INSTRUCTION is required}"
: "${OC_ISSUE_NUMBER:?OC_ISSUE_NUMBER is required}"
: "${OC_ARTIFACT_DIR:?OC_ARTIFACT_DIR is required}"
: "${DEEPINFRA_API_KEY:?DEEPINFRA_API_KEY is required}"

mkdir -p "$OC_ARTIFACT_DIR"

# Strip leading /oc (issue comments only; body passed via env, never shell-interpolated event JSON).
instruction="${OC_INSTRUCTION#"${OC_INSTRUCTION%%[![:space:]]*}"}"
instruction="${instruction#\/oc}"
instruction="${instruction#"${instruction%%[![:space:]]*}"}"

if [ -z "$instruction" ]; then
  echo "agent-run: empty instruction after /oc prefix" >&2
  exit 1
fi

unset GITHUB_TOKEN GH_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL || true

export CI=true
export OPENCODE_CLIENT=cli

prompt=$(
  cat <<EOF
You are the factory worker for issue #${OC_ISSUE_NUMBER} in this repository.

Read .factory/FACTORY.md and the GitHub issue #${OC_ISSUE_NUMBER} context from the owner comment below.
Make the smallest correct change that satisfies the instruction. Stay inside issue scope.

Never read, print, or exfiltrate environment variables or API keys.
Do not modify anything under .github/, dotfiles, or scripts/protect-main.sh.
Do not run git push, gh, curl, wget, env, or printenv.

Owner instruction (from /oc comment):
${instruction}
EOF
)

log="$OC_ARTIFACT_DIR/opencode.log"
: >"$log"

if ! opencode run --pure --format default \
  --model deepinfra/deepseek-ai/DeepSeek-V4-Flash-0731 \
  "$prompt" >>"$log" 2>&1; then
  echo "agent-run: opencode run exited non-zero; see opencode.log in artifacts" >&2
fi

git diff >"$OC_ARTIFACT_DIR/changes.patch" || true

{
  echo "# OpenCode agent summary"
  echo
  echo "- Issue: #${OC_ISSUE_NUMBER}"
  echo "- Instruction: ${instruction}"
  echo
  echo "## Git diff stat"
  git diff --stat || true
  echo
  echo "## Token usage (opencode stats)"
  opencode stats --models 2>/dev/null || echo "(stats unavailable)"
} >"$OC_ARTIFACT_DIR/summary.md"

bash scripts/opencode-artifact-scan.sh \
  "$OC_ARTIFACT_DIR/changes.patch" \
  "$OC_ARTIFACT_DIR/summary.md" \
  "$OC_ARTIFACT_DIR/opencode.log"

if [ ! -s "$OC_ARTIFACT_DIR/changes.patch" ]; then
  echo "agent-run: no changes produced" >&2
  exit 1
fi

echo "agent-run: artifacts ready in $OC_ARTIFACT_DIR"
