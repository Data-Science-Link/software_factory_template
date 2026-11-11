#!/usr/bin/env bash
# Offline tests for the /oc worker path policy in scripts/opencode-artifact-scan.sh (issue #63).
# Builds real patches with git in a throwaway repo (git add -A + git diff --cached --binary, as
# opencode-agent-run.sh does), then checks the scan accepts or rejects each one. No network.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scan="$root/scripts/opencode-artifact-scan.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
ok() { echo "PASS  $1"; passed=$((passed + 1)); }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }

g() { git -c user.name=policy-test -c user.email=policy-test@example.invalid "$@"; }

# Fresh base repo with a few tracked files, in $work/repo.
new_repo() {
  rm -rf "$work/repo"
  mkdir -p "$work/repo/scripts" "$work/repo/.factory" "$work/repo/factory/dbt" "$work/repo/docs"
  cd "$work/repo"
  g init -q
  printf '#!/usr/bin/env bash\necho guard\n' >scripts/pr-check.sh
  chmod +x scripts/pr-check.sh
  printf 'print("hi")\n' >scripts/factory-report.py
  printf '__pycache__/\n*.log\n' >.gitignore
  printf 'target/\n' >factory/dbt/.gitignore
  printf '# Factory\n\nRules.\n' >.factory/FACTORY.md
  printf 'models: {}\n' >.factory/models.yaml
  printf '# Security\n' >.factory/actions-security.md
  printf '# Doc\n' >docs/readme.md
  printf '{}\n' >opencode.json
  printf 'dbt-core==1.11.16\n' >requirements-factory.txt
  g add -A
  g commit -qm base
}

# Capture the working tree as a patch the way the agent job does.
capture() { # $1 = renames flag (default -M)
  g add -A
  g diff --cached --binary "${1:--M}" >"$work/changes.patch"
}

expect() { # $1 = pass|fail  $2 = name  [$3 = substring the failure message must contain]
  local rc=0 out
  out="$(bash "$scan" "$work/changes.patch" 2>&1)" || rc=$?
  if [ "$1" = pass ] && [ "$rc" -eq 0 ]; then ok "$2"
  elif [ "$1" = fail ] && [ "$rc" -ne 0 ] && { [ -z "${3:-}" ] || grep -qF -- "$3" <<<"$out"; }; then ok "$2"
  else bad "$2 (want $1, rc=$rc: $out)"; fi
}

# --- scripts/: new files, plus content edits of non-protected existing scripts ---
new_repo; printf '#!/usr/bin/env bash\necho new\n' >scripts/dbt-seed-check.sh; capture
expect pass "scripts/: add a new script (100644)"
new_repo; printf '#!/usr/bin/env bash\necho new\n' >scripts/dbt-seed-check.sh; chmod +x scripts/dbt-seed-check.sh; capture
expect pass "scripts/: add a new executable script (new file mode 100755)"
new_repo; printf 'echo more\n' >>scripts/pr-check.sh; capture
expect fail "scripts/: modify a protected spend/security script" "protected spend/security script"
new_repo; printf 'print(\"more\")\n' >>scripts/factory-report.py; capture
expect pass "scripts/: modify a non-protected existing script"
new_repo; chmod -x scripts/pr-check.sh; capture
expect fail "scripts/: chmod a protected existing script (mode change only)" "chmods an existing script"
new_repo; chmod +x scripts/factory-report.py; capture
expect fail "scripts/: chmod a non-protected existing script still forbidden" "chmods an existing script"
new_repo; rm scripts/pr-check.sh; capture
expect fail "scripts/: delete a protected existing script" "deletes an existing script"
new_repo; rm scripts/factory-report.py; capture
expect fail "scripts/: delete a non-protected existing script still forbidden" "deletes an existing script"
new_repo; g mv scripts/pr-check.sh scripts/pr-check-old.sh; capture
expect fail "scripts/: rename within scripts/" "renames an existing script"
new_repo; g mv scripts/pr-check.sh docs/pr-check.sh; capture
expect fail "scripts/: rename out of scripts/" "renames an existing script"
new_repo; g mv scripts/pr-check.sh docs/pr-check.sh; capture --no-renames
expect fail "scripts/: move out of scripts/ without rename detection (delete + add)" "deletes an existing script"
new_repo; printf 'body\n' >docs/tool-x.sh; g add -A; g commit -qm tool; g mv docs/tool-x.sh scripts/tool-x.sh; capture
expect pass "scripts/: rename into scripts/ from elsewhere counts as new"
new_repo; printf 'body\n' >docs/tool-x.sh; g add -A; g commit -qm tool; g mv docs/tool-x.sh scripts/tool-x.sh; chmod +x scripts/tool-x.sh; capture
expect pass "scripts/: rename into scripts/ plus chmod +x"
new_repo; printf 'body\n' >docs/tool.sh; g add -A; g commit -qm tool; g mv docs/tool.sh scripts/tool.sh; capture
expect fail "scripts/: rename into scripts/ with a module-style name" "hyphenated name"
new_repo; printf 'x = 1\n' >scripts/yaml.py; capture
expect fail "scripts/: new module-style name (scripts/yaml.py could shadow imports)" "hyphenated name"
new_repo; mkdir -p scripts/lib; printf 'x\n' >scripts/lib/new-tool.sh; capture
expect fail "scripts/: new file in a subdirectory" "directly in scripts/"
new_repo; mkdir -p scripts/jsonschema; printf 'x = 1\n' >scripts/jsonschema/__init__.py; capture
expect fail "scripts/: new package directory (shadow import)" "directly in scripts/"
new_repo; ln -s ../.github scripts/link-dir; capture
expect fail "scripts/: new symlink" "symlink"
new_repo; printf '#!/usr/bin/env bash\n' >scripts/new-a.sh; printf 'more\n' >>scripts/factory-report.py; capture
expect pass "scripts/: new file plus an edit to a non-protected existing script in the same patch"
new_repo; printf '#!/usr/bin/env bash\n' >scripts/new-a.sh; printf 'more\n' >>scripts/pr-check.sh; capture
expect fail "scripts/: new file plus an edit to a protected script in the same patch" "protected spend/security script"

# --- .factory/ ---
new_repo; printf '\nMore rules.\n' >>.factory/FACTORY.md; capture
expect pass ".factory/: edit a doc"
new_repo; mkdir -p .factory/skills; printf '# Skill\n' >.factory/skills/new-skill.md; capture
expect pass ".factory/: add a doc"
new_repo; printf 'x: 1\n' >>.factory/models.yaml; capture
expect fail ".factory/models.yaml is owner-only" ".factory/models.yaml"
new_repo; printf 'x\n' >>.factory/actions-security.md; capture
expect fail ".factory/actions-security.md is owner-only" ".factory/actions-security.md"

# --- AGENTS.md: owner-only, root and nested (#97) ---
new_repo; printf 'x\n' >>AGENTS.md; capture
expect fail "AGENTS.md is owner-only" "AGENTS.md"
new_repo; mkdir -p docs; printf '# Rules\n' >docs/AGENTS.md; capture
expect fail "nested AGENTS.md is owner-only" "AGENTS.md"
new_repo; g mv .factory/models.yaml .factory/models-old.yaml; capture
expect fail ".factory/: rename an owner-only file away" "forbidden path: .factory/models.yaml"

# --- .gitignore: add lines only ---
new_repo; printf '.venv-x/\n' >>.gitignore; capture
expect pass ".gitignore: add a line"
new_repo; printf 'target/\nlogs/\n' >factory/dbt/.gitignore; capture
expect pass "nested .gitignore: add a line"
new_repo; printf '*.csv\n' >docs/.gitignore; capture
expect pass "nested .gitignore: new file (additions only)"
new_repo; printf '*.log\n' >.gitignore; capture
expect fail ".gitignore: delete a line" "only added lines"
new_repo; printf '__pycache__/\n*.txt\n' >.gitignore; capture
expect fail ".gitignore: change a line" "only added lines"
new_repo; rm .gitignore; capture
expect fail ".gitignore: delete the file" "only added lines"
new_repo; chmod +x .gitignore; capture
expect fail ".gitignore: mode change" "only added lines"
new_repo; mkdir -p .cursor; printf 'x\n' >.cursor/.gitignore; capture
expect fail ".gitignore inside another dot-dir" "forbidden path"

# --- always forbidden ---
new_repo; mkdir -p .github/workflows; printf 'on: push\n' >.github/workflows/x.yml; capture
expect fail ".github/ stays forbidden" "forbidden path: .github/workflows/x.yml"
new_repo; printf '{"a":1}\n' >opencode.json; capture
expect fail "opencode.json stays forbidden" "forbidden path: opencode.json"
new_repo; printf 'requests==2.32.3\n' >>requirements-factory.txt; capture
expect fail "requirements-factory.txt is owner-only (edit)" "forbidden path: requirements-factory.txt"
new_repo; g rm -q requirements-factory.txt; capture
expect fail "requirements-factory.txt is owner-only (delete)" "forbidden path: requirements-factory.txt"
new_repo; printf 'requests==2.32.3\n' >factory/dbt/requirements-dbt.txt; capture
expect pass "other requirements files outside the root stay allowed"
new_repo; printf 'K=V\n' >.env.example; capture
expect fail "root dotfile stays forbidden" "forbidden path: .env.example"
new_repo; printf 'x\n' >factory/dbt/.env; capture
expect fail "nested dotfile outside .factory/ is forbidden" "forbidden path: factory/dbt/.env"
new_repo; mkdir -p .cursor/rules; printf 'x\n' >.cursor/rules/x.mdc; capture
expect fail "other dot-dir (.cursor/) is forbidden" "forbidden path"
new_repo; printf 'x\n' >gitleaks_1.0.txt; capture
expect fail "gitleaks_* stays forbidden" "forbidden path"
new_repo; printf 'x\n' >'docs/with space.md'; capture
expect pass "plain file name with a space (git does not quote spaces)"
new_repo; printf 'x\n' >"docs/tab$(printf '\t')name.md"; capture
expect fail "quoted path (special characters)" "quoted path"
new_repo; printf '\x00\x01binary' >docs/blob.bin; capture
expect fail "binary file" "binary"

# --- ordinary changes and parser robustness ---
new_repo; printf 'new\n' >factory/dbt/model-a.sql; printf 'more\n' >>docs/readme.md; capture
expect pass "factory/ and docs/ changes pass"
new_repo; printf -- '+++ b/.github/workflows/evil.yml\n--- a/scripts/pr-check.sh\ndiff --git is text here\n' >>docs/readme.md; capture
expect pass "header-looking lines inside a hunk are content, not headers"
new_repo; printf '# Doc\n' >docs/readme.md; printf -- '--- a/scripts/pr-check.sh\n' >docs/readme.md; capture
expect pass "removed or added line that looks like '--- a/scripts/...' is content"
printf 'diff --git a/docs/x.md b/docs/x.md\n--- a/docs/x.md\n+++ b/docs/x.md\n@@ -1 +1 @@\n-a\n+b\n+++ b/.github/workflows/x.yml\n' >"$work/changes.patch"
expect fail "extra line after a hunk ends is rejected" "unexpected line after a hunk"
printf -- '--- a/.github/workflows/x.yml\n+++ b/.github/workflows/x.yml\n@@ -1 +1 @@\n-a\n+b\n' >"$work/changes.patch"
expect fail "traditional (non-git) unified diff is rejected" "must start with a 'diff --git'"
printf 'diff --git a/docs/x.md b/docs/x.md\n--- a/docs/x.md\n+++ b/.github/workflows/x.yml\n' >"$work/changes.patch"
expect fail "header paths that disagree are rejected" "two different paths"
printf 'diff --git a/.factory/../.github/x.yml b/.factory/../.github/x.yml\nnew file mode 100644\n' >"$work/changes.patch"
expect fail "'..' in a path is rejected" "forbidden path"
printf 'diff --git a/docs/x.md b/docs/x.md\n--- a/docs/x.md\n+++ b/docs/x.md\n@@ -1,2 +1,2 @@\n-a\n' >"$work/changes.patch"
expect fail "patch that ends inside a hunk is rejected" "ends inside a hunk"

# --- the prompt carries the same rules ---
cd "$root"
rules="$(bash "$scan" --list-rules)"
if grep -qF 'you may add new hyphenated scripts under scripts/, and you may edit the' <<<"$rules" \
  && grep -qF 'protected spend/security list' <<<"$rules" \
  && grep -qF '.factory/models.yaml' <<<"$rules" && grep -qF 'only ADD lines' <<<"$rules" \
  && grep -qF 'requirements-factory.txt' <<<"$rules"; then
  ok "--list-rules states the scripts/, .factory/ and .gitignore rules"
else bad "--list-rules wording"; fi
missing_prot=""
while IFS= read -r prot; do
  grep -qxF -- "- $prot" <<<"$rules" || missing_prot="$missing_prot $prot"
  grep -qF -- "$prot" "$root/.factory/FACTORY.md" || missing_prot="$missing_prot (FACTORY.md lacks $prot)"
done < <(bash "$scan" --list-protected)
if [ -z "$missing_prot" ]; then ok "--list-rules and FACTORY.md include every --list-protected path"
else bad "--list-protected not mirrored:$missing_prot"; fi
if bash "$scan" --list-protected | grep -qxF 'scripts/opencode-artifact-scan.sh' \
  && bash "$scan" --list-protected | grep -qxF 'scripts/protect-main.sh'; then
  ok "--list-protected includes the path-policy script and protect-main.sh"
else bad "--list-protected missing required entries"; fi
missing=""
while IFS= read -r pat; do
  grep -qxF -- "- $pat" <<<"$rules" || missing="$missing $pat"
done < <(bash "$scan" --list-forbidden)
if [ -z "$missing" ]; then ok "--list-rules includes every --list-forbidden pattern"; else bad "--list-rules lacks:$missing"; fi

# opencode.json must not block what the scan allows (new scripts, #63), but keeps the hard denies.
if python3 - "$root/opencode.json" <<'PY2'
import json, sys
edit = json.load(open(sys.argv[1]))["permission"]["edit"]
bad = [k for k, v in edit.items() if v == "deny" and k in ("scripts/**", "scripts/*", "*")]
need = [k for k in (".github/**", "opencode.json", ".factory/models.yaml", "requirements-factory.txt", "scripts/protect-main.sh") if edit.get(k) != "deny"]
sys.exit(1 if bad or need else 0)
PY2
then ok "opencode.json: new scripts editable (scan judges them); .github, opencode.json, models.yaml, requirements-factory, protect-main.sh denied"
else bad "opencode.json edit rules vs path policy"; fi

# --- fix runs (#102): --base-scripts lists the default branch scripts; PR-added ones are editable ---
# new_pr_repo: base commit = "main"; a second commit (the PR head) adds scripts/pr-added-check.sh.
new_pr_repo() {
  new_repo
  g ls-tree -r --name-only HEAD -- scripts/ >"$work/base-scripts.txt"
  printf '#!/usr/bin/env bash\necho pr\n' >scripts/pr-added-check.sh
  g add -A; g commit -qm pr
}
expect_fix() { # like expect, but scans in fix mode with the base scripts list
  local rc=0 out
  out="$(bash "$scan" --base-scripts "$work/base-scripts.txt" "$work/changes.patch" 2>&1)" || rc=$?
  if [ "$1" = pass ] && [ "$rc" -eq 0 ]; then ok "$2"
  elif [ "$1" = fail ] && [ "$rc" -ne 0 ] && { [ -z "${3:-}" ] || grep -qF -- "$3" <<<"$out"; }; then ok "$2"
  else bad "$2 (want $1, rc=$rc: $out)"; fi
}
new_pr_repo; printf 'echo fixed\n' >>scripts/pr-added-check.sh; capture
expect_fix pass "fix: edit a script the PR added"
expect pass "build (no --base-scripts): edit of a non-protected PR-added script is allowed"
new_pr_repo; chmod +x scripts/pr-added-check.sh; capture
expect_fix pass "fix: chmod +x a script the PR added"
new_pr_repo; printf 'echo more\n' >>scripts/pr-check.sh; capture
expect_fix fail "fix: edit a protected script that exists on main" "protected spend/security script"
new_pr_repo; printf 'print(\"more\")\n' >>scripts/factory-report.py; capture
expect_fix pass "fix: edit a non-protected script that exists on main"
new_pr_repo; chmod -x scripts/pr-check.sh; capture
expect_fix fail "fix: chmod a protected script that exists on main" "chmods an existing script"
new_pr_repo; chmod +x scripts/factory-report.py; capture
expect_fix fail "fix: chmod a non-protected main script still forbidden" "chmods an existing script"
new_pr_repo; g rm -q scripts/pr-check.sh; printf '#!/usr/bin/env bash\necho evil\n' >scripts/pr-check.sh; capture
expect_fix fail "fix: delete + re-add a protected main script (one section)" "existing script"
new_pr_repo; g rm -q scripts/pr-check.sh; capture
expect_fix fail "fix: delete a main script" "deletes an existing script"
new_pr_repo; g rm -q scripts/pr-check.sh; g commit -qm sneaky; printf '#!/usr/bin/env bash\necho evil\n' >scripts/pr-check.sh; capture
expect_fix fail "fix: re-create a main script missing from the PR head" "exists on the default branch"
new_pr_repo; g mv scripts/pr-check.sh scripts/pr-check-old.sh; printf '#!/usr/bin/env bash\necho evil\n' >scripts/pr-check.sh; capture
expect_fix fail "fix: rename a main script away and re-create it" "existing script"
new_pr_repo; g mv scripts/pr-added-check.sh scripts/pr-added-two.sh; capture
expect_fix fail "fix: rename a script the PR added (edit only)" "renames an existing script"
new_pr_repo; g rm -q scripts/pr-added-check.sh; capture
expect_fix fail "fix: delete a script the PR added (edit only)" "deletes an existing script"
new_pr_repo; g mv scripts/pr-added-check.sh scripts/pr-check-x.sh; g rm -q scripts/pr-check.sh; g mv scripts/pr-check-x.sh scripts/pr-check.sh; capture
expect_fix fail "fix: move a PR-added script onto a main script's name" "existing script"
new_pr_repo; printf 'x\n' >opencode.json; capture
expect_fix fail "fix: forbidden paths stay forbidden" "forbidden path"
new_pr_repo; printf '#!/usr/bin/env bash\necho new\n' >scripts/dbt-seed-check.sh; capture
expect_fix pass "fix: add a new script still allowed"
if bash "$scan" --list-rules fix | grep -qF 'Fix runs only'; then ok "--list-rules fix explains the fix-run exception"; else bad "--list-rules fix text"; fi
if ! bash "$scan" --list-rules | grep -qF 'Fix runs only'; then ok "--list-rules (build) unchanged"; else bad "--list-rules build text"; fi
if ! bash "$scan" --base-scripts "$work/missing.txt" "$work/changes.patch" >/dev/null 2>&1; then ok "--base-scripts with a missing file fails closed"; else bad "--base-scripts missing file"; fi

echo "path-policy tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
