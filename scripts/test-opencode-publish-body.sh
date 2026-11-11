#!/usr/bin/env bash
# Offline test: the PR body built by opencode-publish-pr.sh passes scripts/pr-check.sh (rule 4),
# with run facts written by scripts/opencode-run-facts.sh. No network, no token: publish stops at
# its GH_TOKEN check, which runs after pr-check.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
unset GH_TOKEN GITHUB_ACTIONS
fails=0
check() { if grep -qF -- "$2" "$1"; then echo "OK    $3"; else echo "FAIL  $3 (missing: $2)"; fails=$((fails + 1)); fi; }

# A throwaway repo whose HEAD holds the scripts under test (publish reads them via git show HEAD:).
make_repo() {
  local dir=$1
  git init -q "$dir"
  mkdir -p "$dir/scripts"
  for s in opencode-publish-pr.sh opencode-artifact-scan.sh opencode-git-push-scoped.sh pr-check.sh opencode-run-facts.sh \
    opencode-text-block.sh opencode-build-context.py factory-spec-check.py factory-check-model.py opencode-stage-spec-files.sh; do
    cp "$root/scripts/$s" "$dir/scripts/$s"
  done
  mkdir -p "$dir/.factory" && cp "$root/.factory/models.yaml" "$dir/.factory/models.yaml"
  echo base >"$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" -c user.name=test -c user.email=test@test commit -q -m base
}

# Patch: one code file, plus the spec when $2 = with-spec.
make_patch() {
  local dir=$1 mode=$2 risk=$3
  git -C "$dir" checkout -q -b scratch
  mkdir -p "$dir/factory/hello" "$dir/factory/specs"
  echo hello >"$dir/factory/hello/hello.md"
  if [ "$mode" = with-spec ]; then
    printf '<!-- factory-spec v1 -->\n---\nspec_version: 1\nissue: 99\nrisk: %s\npredicted_cost_usd: 0.033\n---\n\n## Outcome\nHello.\n' "$risk" \
      >"$dir/factory/specs/issue-99.md"
  fi
  git -C "$dir" add -A
  git -C "$dir" diff --cached >"$dir.artifacts/changes.patch"
  git -C "$dir" reset -q --hard
  git -C "$dir" clean -qfd
  git -C "$dir" checkout -q -
  git -C "$dir" branch -q -D scratch
}

run_publish() {
  local dir=$1
  (
    cd "$dir"
    export OC_ISSUE_NUMBER=99 OC_RUN_ID=12345678901 OC_ARTIFACT_DIR="$dir.artifacts" GITHUB_WORKSPACE="$dir"
    export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=org/repo
    git config user.name test && git config user.email test@test
    # #92: job A's meta names the routed model (Pro here, to prove the body is not hard-coded).
    grep -q '^model_id=' "$OC_ARTIFACT_DIR/context-meta.txt" 2>/dev/null \
      || echo "model_id=${PUB_MODEL-deepseek-ai/DeepSeek-V4-Pro-0813}" >>"$OC_ARTIFACT_DIR/context-meta.txt"
    bash scripts/opencode-publish-pr.sh
  ) >"$dir.out" 2>&1 || true
}

echo "== case 1: spec in patch, normal risk, OpenCode-reported cost =="
r1="$work/r1"; mkdir -p "$r1.artifacts"
make_repo "$r1"; make_patch "$r1" with-spec normal
echo "# OpenCode agent summary" >"$r1.artifacts/summary.md"
# shellcheck disable=SC2016  # literal $ and backticks, as in the real artifact
printf '## Token usage (opencode stats)\n\n- Model: deepinfra/deepseek-ai/DeepSeek-V4-Flash-0731\n- Input tokens: 108.8K\n- Output tokens: 17.9K\n- Cache read: 1.1M\n- OpenCode-reported cost: $0.0257\n- Source: `opencode stats --models`\n' \
  >"$r1.artifacts/usage-metrics.md"
run_publish "$r1"
body="$r1.artifacts/pr-body.md"
check "$r1.out" "PR check: passed." "generated body passes pr-check"
check "$r1.artifacts/pr-body.md" "AI disclosure: harness opencode-actions; model deepseek-ai/DeepSeek-V4-Pro-0813" "#92 AI disclosure names the routed model from job A's meta"
check "$r1.artifacts/pr-body.md" 'OpenCode (DeepInfra `deepseek-ai/DeepSeek-V4-Pro-0813`, routed by run start)' "#92 summary names the routed model"
check "$r1.out" "GH_TOKEN is required" "publish stopped only at the push step"
check "$body" "Run ID: 12345678901" "Run ID from OC_RUN_ID"
check "$body" "Tokens in / cached / out: 108.8K / 1.1M / 17.9K" "tokens from usage-metrics"
check "$body" "Predicted cost: \$0.033 (spec front matter)" "predicted cost from spec"
check "$body" "Actual cost: \$0.0257" "actual cost from usage-metrics"
check "$body" "Gate: risk normal: owner product gate required" "gate from spec risk"
check "$body" "factory/specs/issue-99.md" "spec link"
check "$body" "- [x] normal" "Risk class box ticked from the spec (normal)"
check "$body" "- [ ] **high**" "high box not ticked for a normal spec"
check "$body" "risk class **normal** (spec front matter)" "triage line from the spec"
check "$body" "## What I changed and why" "narrative section present"
check "$body" "(the worker did not write a labeled note)" "missing note stated, not invented"
echo "--- direct pr-check on the body ---"
if bash "$r1/scripts/pr-check.sh" "$body"; then echo "OK    pr-check.sh exit 0"; else echo "FAIL  pr-check.sh"; fails=$((fails + 1)); fi

echo "== case 2: no spec, cost not measured: facts say so and pr-check rejects (no guessing) =="
r2="$work/r2"; mkdir -p "$r2.artifacts"
make_repo "$r2"; make_patch "$r2" no-spec normal
echo "# OpenCode agent summary" >"$r2.artifacts/summary.md"
printf '## Token usage (opencode stats)\n\n- Input tokens: 1.2K\n- Output tokens: 300\n- Cache read: 0\n- OpenCode-reported cost: not measured\n' >"$r2.artifacts/usage-metrics.md"
run_publish "$r2"
body="$r2.artifacts/pr-body.md"
check "$body" "Actual cost: \$0 (not measured)" "unmetered cost uses run-record not_measured form"
check "$body" "Predicted cost: not available" "no invented prediction"
check "$body" "Gate: risk unknown (no spec" "unknown risk gated like high"
check "$body" "- [x] **high**" "unknown risk ticks the high box"
check "$r2.out" "needs a spec link" "pr-check fails without spec"
check "$r2.out" "pr-check failed on generated body" "publish refuses to open the PR"

echo "== case 2b (#92): model_id missing or not in models.yaml -> publish refuses before the PR =="
for m in "" "openai/gpt-5"; do
  rb="$work/r2b-${m//\//_}"; mkdir -p "$rb.artifacts"
  make_repo "$rb"; make_patch "$rb" with-spec normal
  echo "# OpenCode agent summary" >"$rb.artifacts/summary.md"
  PUB_MODEL="$m" run_publish "$rb"
  check "$rb.out" "model_id in context-meta.txt is missing or not a deepinfra model" "publish refuses model_id='${m}'"
  if [ -e "$rb.artifacts/pr-body.md" ]; then echo "FAIL  no PR body for model_id='${m}'"; fails=$((fails + 1)); else echo "OK    no PR body for model_id='${m}'"; fi
done

echo "== case 3: trivial risk gate wording (helper only) =="
r3="$work/r3"; mkdir -p "$r3/factory/specs"
printf -- '---\nrisk: trivial\npredicted_cost_usd: 0.01\n---\n' >"$r3/factory/specs/issue-7.md"
(cd "$r3" && OC_ISSUE_NUMBER=7 OC_RUN_ID=1 OC_ARTIFACT_DIR="$r3" bash "$root/scripts/opencode-run-facts.sh") >"$r3.out"
check "$r3.out" "Gate: risk trivial: manager may merge" "trivial gate"
check "$r3.out" "Predicted cost: \$0.01 (spec front matter)" "predicted cost parsed"

if [ "$fails" -gt 0 ]; then echo "test-opencode-publish-body: $fails failure(s)"; exit 1; fi
echo "test-opencode-publish-body: all passed"
