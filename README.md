# Software factory template

A small, copyable way to run a repo where AI agents do most of the building and a human keeps the judgment calls. Everything lives in one folder, `.factory/`, as plain markdown, so it works with any model or chat tool and survives switching either.

## The idea in about 20 seconds

Work arrives as a **GitHub issue**. A **Factory Manager** bot triages it and writes a **handoff block** on the issue: the goal, a full self-contained prompt, the files to read first, the done checks, a size (simple / standard / complex), and the model to use. Hard work gets short product and technical **specs that a human reviews** first. **Agents implement on a PR**, another agent **reviews** it, and the PR is **verified** with CI and evidence (screenshots for UI, real numbers for output changes). The **human owner gives the product gate**, the PR is **merged**, and the manager **monitors** the deploy and scheduled jobs. Whatever went wrong becomes a **lesson written back into the skills and `DECISIONS.md`**, so the next agent doesn't repeat it.

It draws on two talks:

- Zach Lloyd, [Software Engineering Is Becoming Factory Engineering](https://www.youtube.com/watch?v=tUPPVhBBcoM): the loop itself (triage, specs for hard work, build, review, verify, product review, ship, monitor, feed back).
- Nate B Jones, [The AI Bottleneck](https://www.youtube.com/watch?v=2IAYFgAqX6g): keep work multiplayer, keep history out of the chat, humans still answer for what ships, leave work someone else can pick up, let agents see their own results, and drop process that stopped helping.

## Roles

| Role | What they do |
|---|---|
| **Human owner** | Decides. Approves specs for hard work and gives the product gate before normal or high-risk work merges. |
| **Factory Manager** (bot, one per repo) | Runs the loop: triages issues, writes handoff blocks, launches and reviews cloud agents, merges within its authority, watches deploys and scheduled jobs. |
| **Giver** (optional bot) | Keeps the asks ledger, drafts decision entries, and challenges done claims and priorities against what the owner actually asked for. Never builds or merges. |
| **Coordinator / chief of staff** (optional) | Intake: turns a chat ask into a GitHub issue and hands it to the manager. |
| **Builder** | Maintains this template: turns lessons from live repos into method changes here. |

Workers (the cloud agents the manager launches) build, test, and review on a branch; they don't merge.

## Quickstart

Get started with this template in under a minute:

1. [Copy the `.factory/` folder](#how-to-adopt-it-in-a-repo) into your repo root as-is
2. [Fill in `.factory/DOCS.md`](#how-to-adopt-it-in-a-repo) with your repo's specifics
3. [Set `.factory/MODEL_ROUTING.md`](#how-to-adopt-it-in-a-repo) for your plan and models
4. [Open your first issue](#how-to-adopt-it-in-a-repo) to start the factory process
5. Running agents on your own machine? Do the one-time safety setup in [`.factory/skills/local-agent-safety.md`](.factory/skills/local-agent-safety.md) first

For full details, see the complete [How to adopt](#how-to-adopt-it-in-a-repo) section below.

## How to adopt it in a repo

1. Copy the `.factory/` folder into the repo root as-is.
2. Fill in `.factory/DOCS.md` with your repo's real paths (tests, deploy, architecture), the names of the secrets agents can use, your key view, and your headline health numbers.
3. Add repo-specific skills under `.factory/skills/`.
4. Keep `.factory/DECISIONS.md` append-only: add new entries at the bottom, and supersede old ones rather than editing them.
5. Set `.factory/MODEL_ROUTING.md` for your plan and the models you can use.
6. Copy the starters in `.factory/sketches/` into place (`CONTRIBUTING.md`, PR template, CODEOWNERS), and add your own `LICENSE` and `SECURITY.md`.
7. Examples labeled with a source repo (for example "perspectiverse #88" in `DECISIONS.md`) are illustrative, taken from repos where the method was run. Keep them or replace them with your own.

## File map

| File | What it's for |
|---|---|
| `.factory/FACTORY.md` | The playbook: triggers, roles, the eight-step loop, merge authority by risk class, deploy and scheduled-job watching, private-repo notes, and evidence rules learned from live misses. |
| `.factory/DECISIONS.md` | Append-only decision log with an entry template. In this template it holds the method's history; in a project repo it holds that repo's own decisions. |
| `.factory/DOCS.md` | A map to the repo's real docs (pointers, not copies), plus tables for secret names agents can use, the key view, and health numbers. |
| `.factory/MODEL_ROUTING.md` | Which model to pin for each kind of work, cost rules, what to do when usage limits are hit, and the Local open-weights setup. |
| `.factory/skills/factory-loop.md` | Step-by-step for moving one issue through the loop: sync, triage and handoff block, build, review and verify, recording the human gate, merge, and follow-up. |
| `.factory/skills/intake-from-coordinator.md` | For the coordinator: turn a chat ask into an issue, then hand it to the manager. |
| `.factory/skills/giver.md` | For the giver: asks ledger, decision drafts, healthy challenge, and how it behaves in the room. |
| `.factory/skills/liability-gates.md` | Hard stops and always-do rules (secrets, licenses, CI, over-claims, merge authority). Not legal advice. |
| `.factory/skills/local-open-weights-run.md` | For a human running an issue locally on an open-weights model with their own provider key. |
| `.factory/sketches/README.md` | Where each sketch should be copied. |
| `.factory/sketches/CONTRIBUTING.md` | Starter contributing guide: how the repo ships work, AI disclosure, DCO sign-off, high-risk paths. |
| `.factory/sketches/github/pull_request_template.md` | PR template with the Factory loop checklist, risk class, AI disclosure, safety checklist, and Evidence section. |
| `.factory/sketches/github/CODEOWNERS.example` | Starter CODEOWNERS that puts sensitive paths behind the maintainer's review. |

## A note on model routing

Cloud agents use pinned Cursor models from the routing table in `MODEL_ROUTING.md`, never Auto. The **Local open-weights** line in each handoff block is only for local runs on the human's own machine (default model: Qwen3-Coder via DeepInfra, with the human's own key). Cloud agents ignore that line and use the model they were launched with. API keys never go in the repo.

## How changes to the template flow

1. A lesson from a live repo, or a new idea, becomes a PR here first.
2. The owner reviews and approves it.
3. Once merged, the change is copied into each project repo's `.factory/` folder.

`.factory/DECISIONS.md` in this repo is the method's history: why each rule exists and what prompted it. Project repos keep their own separate decision log.
