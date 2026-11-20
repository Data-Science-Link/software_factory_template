# Owner paste: `factory-selected` workflow (#111)

The Factory Manager token cannot add workflow files. After the scripts in this PR merge, the **owner** creates `.github/workflows/factory-selected.yml` with the contents below (SHA pins match `opencode-spec.yml` / `opencode-spike.yml` on `main` at merge time).

## What it does

1. **`issues: labeled`** with `factory:selected` (owner actor only) runs `scripts/factory-selected-dispatch.py phase-a`, which may post one owner `/oc spec` kick comment (triggers `opencode-spec.yml`).
2. **`workflow_run`** when `opencode-spec` finishes (success) runs `phase-b`, which may auto-approve trivial/normal drafts (`factory-approve-spec.py`) and post one owner `/oc run` kick (triggers `opencode-spike.yml`).
3. **`issue_comment`** when the owner posts an approved spec (high risk) re-runs `phase-b` so the build can start after manual spec approval.

## Prerequisites

- Repo secret **`FACTORY_OWNER_GH_TOKEN`**: a fine-grained or classic PAT belonging to the **owner** GitHub user, with `issues: write` (and `actions: read` if you add run polling later). Dispatch jobs use this token so kick comments are **OWNER** comments and existing `/oc` workflows fire unchanged.
- Optional variable **`FACTORY_OWNER_LOGIN`**: set when the human owner login differs from `github.repository_owner` (org-owned repos).

## Workflow file (paste verbatim; update owner `if:` when not a personal repo)

```yaml
# factory:selected — phone kickoff: label → /oc spec → approve → /oc run (#111).
# Owner-only paste (workflow scope). Logic lives in scripts/factory-selected-dispatch.py.
name: factory-selected

on:
  issues:
    types: [labeled]
  workflow_run:
    workflows: [opencode-spec]
    types: [completed]
  issue_comment:
    types: [created]

permissions: {}

jobs:
  label-kick-spec:
    if: >-
      github.event_name == 'issues' &&
      github.event.action == 'labeled' &&
      github.event.label.name == 'factory:selected' &&
      github.event.sender.login == github.repository_owner
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
      issues: write
    env:
      OC_ISSUE_NUMBER: ${{ github.event.issue.number }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: Fetch issue context (read-only)
        env:
          GH_TOKEN: ${{ github.token }}
        run: python3 scripts/opencode-build-context.py

      - name: Dispatch /oc spec (owner kick comment)
        env:
          GH_TOKEN: ${{ secrets.FACTORY_OWNER_GH_TOKEN }}
          GITHUB_REPOSITORY: ${{ github.repository }}
        run: |
          python3 scripts/factory-selected-dispatch.py phase-a \
            --issue "$OC_ISSUE_NUMBER" \
            --actor "${{ github.event.sender.login }}" \
            --label "${{ github.event.label.name }}" \
            --context "$OC_ARTIFACT_DIR/issue-context.md" \
            --labels "$OC_ARTIFACT_DIR/issue-labels.txt"

  after-spec:
    if: >-
      (github.event_name == 'workflow_run' &&
       github.event.workflow_run.conclusion == 'success' &&
       github.event.workflow_run.event == 'issue_comment') ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request == null &&
       contains(github.event.comment.body, '<!-- factory-spec v1 -->') &&
       github.event.comment.user.login == github.repository_owner &&
       github.event.comment.author_association == 'OWNER')
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
      issues: write
    env:
      OC_ISSUE_NUMBER: ${{ github.event.issue.number || github.event.workflow_run.head_branch }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: Resolve issue number (workflow_run)
        if: github.event_name == 'workflow_run'
        id: issue
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          # Spec runs use displayTitle "opencode-spec: Issue #<N> ..."
          num="$(gh run view "${{ github.event.workflow_run.id }}" --json displayTitle \
            --jq '.displayTitle | capture("Issue #(?<n>[0-9]+)") | .n')"
          echo "number=${num}" >> "$GITHUB_OUTPUT"

      - name: Dispatch /oc run (owner kick comment)
        env:
          GH_TOKEN: ${{ secrets.FACTORY_OWNER_GH_TOKEN }}
          GITHUB_REPOSITORY: ${{ github.repository }}
          OC_ISSUE_NUMBER: ${{ github.event.issue.number || steps.issue.outputs.number }}
        run: |
          python3 scripts/factory-selected-dispatch.py phase-b --issue "$OC_ISSUE_NUMBER"
```

After paste, enable the workflow in the Actions tab and add `FACTORY_OWNER_GH_TOKEN`. Re-run a labeled issue or add the label again to verify one spec kick and one run kick per issue.