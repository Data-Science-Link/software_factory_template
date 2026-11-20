#!/usr/bin/env python3
"""Report DeepInfra prompt-cache hit rates from factory run records (#120)."""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path


def cache_hit_rate(tokens_in: int | None, tokens_cached: int | None) -> float | None:
    if tokens_in is None or tokens_cached is None:
        return None
    if tokens_in <= 0:
        return None
    return tokens_cached / tokens_in


def load_run(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"factory-cache-report: skip {path.name}: {exc}", file=sys.stderr)
        return None
    if not isinstance(data, dict):
        print(f"factory-cache-report: skip {path.name}: not an object", file=sys.stderr)
        return None
    return data


def sum_tokens(runs: list[dict], key: str) -> int:
    total = 0
    for r in runs:
        v = r.get(key)
        if isinstance(v, bool):
            continue
        if isinstance(v, int):
            total += v
        elif v is None:
            continue
        else:
            try:
                total += int(v)
            except (TypeError, ValueError):
                pass
    return total


def fmt_rate(rate: float | None) -> str:
    if rate is None:
        return "n/a"
    return f"{rate * 100:.2f}%"


def report(runs_dir: Path) -> int:
    paths = sorted(runs_dir.glob("*.json"))
    runs: list[dict] = []
    for p in paths:
        row = load_run(p)
        if row:
            runs.append(row)

    by_model: dict[str, list[dict]] = defaultdict(list)
    by_work: dict[str, list[dict]] = defaultdict(list)
    for r in runs:
        model = str(r.get("model") or "unknown")
        work = str(r.get("work_type") or "unknown")
        by_model[model].append(r)
        by_work[work].append(r)

    tin = sum_tokens(runs, "tokens_in")
    tcached = sum_tokens(runs, "tokens_cached")
    overall = cache_hit_rate(tin, tcached)

    print(f"Run records: {len(runs)} file(s) in {runs_dir}")
    print(f"Overall cache hit (tokens_cached / tokens_in): {fmt_rate(overall)} ({tcached} / {tin})")
    print()
    print("By model:")
    if not by_model:
        print("  (none)")
    for model in sorted(by_model):
        group = by_model[model]
        gi = sum_tokens(group, "tokens_in")
        gc = sum_tokens(group, "tokens_cached")
        print(f"  {model}: {fmt_rate(cache_hit_rate(gi, gc))} ({gc} / {gi}) n={len(group)}")
    print()
    print("By work_type:")
    if not by_work:
        print("  (none)")
    for work in sorted(by_work):
        group = by_work[work]
        gi = sum_tokens(group, "tokens_in")
        gc = sum_tokens(group, "tokens_cached")
        print(f"  {work}: {fmt_rate(cache_hit_rate(gi, gc))} ({gc} / {gi}) n={len(group)}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--runs-dir",
        type=Path,
        default=Path("factory/runs"),
        help="Directory of factory/runs/<run_id>.json files (default: factory/runs)",
    )
    args = ap.parse_args()
    if not args.runs_dir.is_dir():
        print(f"factory-cache-report: {args.runs_dir} is not a directory", file=sys.stderr)
        return 2
    return report(args.runs_dir)


if __name__ == "__main__":
    sys.exit(main())