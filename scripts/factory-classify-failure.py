#!/usr/bin/env python3
"""Classify a failed agent run for routing the next run (issue #92, models.yaml rule 5).

Reads the run's opencode.log after the worker has exited and prints one line,
`error_class=tool_or_reasoning_format` or `error_class=other`, also appended to
$GITHUB_OUTPUT (or --github-output). The class is carried into the #84 failure marker, and
scripts/factory-run-start.py reads it on the next run: DeepSeek + tool_or_reasoning_format
routes to Qwen3-Coder (rule 5).

Deterministic and offline. The log holds model text too, so a worker could print these
strings itself; the only effect is that the NEXT owner-triggered run uses another model listed
in models.yaml, still under the issue cap.

When ``agent-failure-reason.txt`` sits next to the log (written by opencode-agent-run.sh when
the worker refuses before OpenCode starts, issue #150), its value wins over log heuristics.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

# OpenCode / AI SDK tool-call and reasoning-format failures (#88: SchemaError on `read`).
PATTERNS = [
    re.compile(p, re.IGNORECASE)
    for p in (
        r"SchemaError",
        r"AI_InvalidToolArgumentsError",
        r"AI_NoSuchToolError",
        r"AI_ToolCallRepairError",
        r"InvalidToolInputError",
        r"invalid tool call",
        r"unavailable tool",
        r"tool call validation failed",
        r"reasoning_content",
    )
]
# One stray line is noise; a model that keeps failing its tool calls is the signal.
THRESHOLD = 3
MAX_BYTES = 5_000_000


AGENT_REASON = "agent-failure-reason.txt"
KNOWN_AGENT_REASONS = frozenset({"empty_instruction"})


def classify(text: str) -> str:
    hits = sum(1 for line in text.splitlines() if any(p.search(line) for p in PATTERNS))
    return "tool_or_reasoning_format" if hits >= THRESHOLD else "other"


def agent_reason(log: Path) -> str | None:
    reason = log.parent / AGENT_REASON
    try:
        code = reason.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return code if code in KNOWN_AGENT_REASONS else None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--log", type=Path, required=True)
    ap.add_argument("--github-output", type=Path, default=None)
    a = ap.parse_args()
    text = ""
    try:
        with open(a.log, "rb") as fh:
            text = fh.read(MAX_BYTES).decode("utf-8", errors="replace")
    except OSError:
        text = ""
    pre = agent_reason(a.log)
    klass = pre if pre is not None else classify(text)
    line = f"error_class={klass}"
    print(line)
    out = a.github_output or (Path(os.environ["GITHUB_OUTPUT"]) if os.environ.get("GITHUB_OUTPUT") else None)
    if out is not None:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
