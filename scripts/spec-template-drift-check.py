#!/usr/bin/env python3
"""Check that .factory/templates/spec.md price_table_version matches .factory/models.yaml.

The spec template ships with router-filled fields blanked, so the router fills them from
.factory/models.yaml (the single source of truth). If models.yaml's
price_table_version is bumped without syncing the template, this check fails the build.
"""
import argparse
import sys

import yaml

TEMPLATE = ".factory/templates/spec.md"
MODELS = ".factory/models.yaml"


def front_matter_version(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if not text.startswith("---"):
        return None
    parts = text.split("---", 2)
    if len(parts) < 3:
        return None
    doc = yaml.safe_load(parts[1])
    if not isinstance(doc, dict):
        return None
    return doc.get("price_table_version")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", default=TEMPLATE, help="spec template to check")
    args = parser.parse_args()

    template_version = front_matter_version(args.template)
    with open(MODELS, encoding="utf-8") as fh:
        models = yaml.safe_load(fh)
    models_version = models.get("price_table_version") if isinstance(models, dict) else None

    if template_version is None or models_version is None:
        print(
            "drift: price_table_version missing "
            f"(template={template_version!r}, models={models_version!r})",
            file=sys.stderr,
        )
        return 1

    template_str = str(template_version)
    models_str = str(models_version)

    if template_str == models_str:
        print(f"price_table_version OK: {template_str}")
        return 0

    print(
        f"drift: template price_table_version {template_str!r} != "
        f"models.yaml price_table_version {models_str!r}; sync .factory/templates/spec.md",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
