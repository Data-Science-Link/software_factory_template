#!/usr/bin/env python3
"""Exit 0 when MODEL_ID is a deepinfra model listed in models.yaml, else exit 1 (issue #92).

Used by the agent scripts before OpenCode runs, and by publish before it names the model in a
PR body: the model must be exactly what run start routed (scripts/factory-run-start.py), and run
start only routes models listed here. Prints nothing on success; never prints environment values.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
MODEL_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$")


def allowed_ids(models: Path) -> set[str]:
    data = yaml.safe_load(models.read_text(encoding="utf-8"))
    rows = data.get("models", []) if isinstance(data, dict) else []
    return {
        str(r.get("id"))
        for r in rows
        if isinstance(r, dict) and r.get("provider") == "deepinfra" and r.get("id")
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("model_id", help="DeepInfra model id, without the deepinfra/ prefix")
    ap.add_argument("--models", type=Path, default=ROOT / ".factory" / "models.yaml")
    a = ap.parse_args()
    if not MODEL_ID_RE.match(a.model_id):
        print("check-model: model id has an unexpected shape", file=sys.stderr)
        return 1
    try:
        ids = allowed_ids(a.models)
    except (OSError, yaml.YAMLError):
        print(f"check-model: cannot read {a.models}", file=sys.stderr)
        return 1
    if a.model_id not in ids:
        print(f"check-model: {a.model_id} is not a deepinfra model in models.yaml", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
