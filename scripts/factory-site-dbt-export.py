#!/usr/bin/env python3
"""Export dbt mart tables and offline manifest metadata for the factory site.

Live builds: read DuckDB marts into JSON row files (same shape as site-data fixtures).

Offline / fallback: synthesize manifest.json-shaped metadata from factory/dbt SQL,
schema YAML, and singular SQL tests so the site dbt tab shows the full DAG without
a prior ``dbt compile``.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover — PyYAML is a repo dependency
    yaml = None  # type: ignore

REF_RE = re.compile(r"""\{\{\s*ref\s*\(\s*['"]([\w]+)['"]\s*\)\s*\}\}""")
PACKAGE = "factory"
MANIFEST_SCHEMA = "https://schemas.getdbt.com/dbt/manifest/v12.json"

# Keep in sync with scripts/factory-site-data.py EXPORTED_MODELS + optional CFO marts.
TABLES = (
    "rpt_run_rate",
    "agg_spend_weekly",
    "agg_spend_monthly",
    "agg_spend_by_issue",
    "agg_spend_by_model",
    "fct_forecast_vs_actual",
    "rpt_issue_target_compliance",
    "fct_agent_runs",
    "mart_model_efficiency",
    "mart_monthly_cfo",
    "mart_spend_by_work_type",
)

SCHEMA_FILES = (
    "models/staging/schema.yml",
    "models/marts/schema.yml",
    "models/marts/schema_cfo.yml",
)


def json_value(value):
    if value is None:
        return None
    if isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        return value
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    return str(value)


def row_to_dict(columns, row):
    return {col: json_value(val) for col, val in zip(columns, row)}


def dbt_root(repo_root: Path) -> Path:
    return repo_root / "factory" / "dbt"


def model_uid(name: str) -> str:
    return f"model.{PACKAGE}.{name}"


def seed_uid(name: str) -> str:
    return f"seed.{PACKAGE}.{name}"


def test_uid(slug: str) -> str:
    return f"test.{PACKAGE}.{slug}"


def parse_refs(text: str) -> list[str]:
    seen: list[str] = []
    for match in REF_RE.finditer(text):
        name = match.group(1)
        if name not in seen:
            seen.append(name)
    return seen


def discover_sql_models(root: Path) -> dict[str, Path]:
    models_dir = root / "models"
    out: dict[str, Path] = {}
    if not models_dir.is_dir():
        return out
    for path in sorted(models_dir.rglob("*.sql")):
        out[path.stem] = path
    return out


def load_schema_catalog(root: Path) -> dict[str, dict]:
    if yaml is None:
        return {}
    catalog: dict[str, dict] = {}
    for rel in SCHEMA_FILES:
        path = root / rel
        if not path.is_file():
            continue
        try:
            data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except (OSError, yaml.YAMLError):
            continue
        for entry in data.get("models") or []:
            if not isinstance(entry, dict):
                continue
            name = entry.get("name")
            if not name:
                continue
            columns: dict[str, dict] = {}
            for col in entry.get("columns") or []:
                if not isinstance(col, dict) or not col.get("name"):
                    continue
                cname = str(col["name"])
                columns[cname] = {
                    "name": cname,
                    "description": (col.get("description") or "").strip()
                    or "no description",
                }
            catalog[name] = {
                "description": (entry.get("description") or "").strip(),
                "columns": columns,
                "data_tests": entry.get("data_tests") or [],
                "column_tests": [
                    (col.get("name"), col.get("data_tests") or [])
                    for col in (entry.get("columns") or [])
                    if isinstance(col, dict) and col.get("name")
                ],
            }
    return catalog


def _layer_for_path(rel: str) -> str:
    low = rel.lower()
    if "staging" in low:
        return "staging"
    if "marts" in low:
        return "marts"
    return "other"


def _materialization_for(rel: str, resource_type: str) -> str:
    if resource_type == "seed":
        return "seed"
    if "staging" in rel.lower():
        return "view"
    return "table"


def _flatten_schema_test(test_entry, column_name: str | None = None) -> tuple[str, str | None]:
    if isinstance(test_entry, str):
        return test_entry, column_name
    if not isinstance(test_entry, dict) or not test_entry:
        return "test", column_name
    key = next(iter(test_entry))
    body = test_entry.get(key) or {}
    col = column_name
    if isinstance(body, dict) and body.get("column_name"):
        col = str(body["column_name"])
    return str(key), col


def _schema_test_nodes(
    model_name: str,
    model_id: str,
    catalog_entry: dict,
    seq: dict[str, int],
) -> dict[str, dict]:
    nodes: dict[str, dict] = {}
    tests = list(catalog_entry.get("data_tests") or [])
    for col_name, col_tests in catalog_entry.get("column_tests") or []:
        for t in col_tests:
            tests.append((t, col_name))
    for item in tests:
        if isinstance(item, tuple):
            test_entry, col = item
        else:
            test_entry, col = item, None
        test_name, column_name = _flatten_schema_test(test_entry, col)
        slug = f"{test_name}_{model_name}"
        if column_name:
            slug = f"{test_name}_{model_name}_{column_name}"
        seq[slug] = seq.get(slug, 0)
        suffix = seq[slug]
        uid = test_uid(f"{slug}_{suffix}")
        label = slug.replace("_", " ")
        nodes[uid] = {
            "unique_id": uid,
            "name": slug,
            "package_name": PACKAGE,
            "resource_type": "test",
            "depends_on": {"nodes": [model_id]},
            "test_metadata": {
                "name": test_name,
                "column_name": column_name or "",
            },
            "description": f"Schema test {test_name} on {model_name}.",
        }
    return nodes


def _sql_test_nodes(root: Path, sql_models: dict[str, Path]) -> dict[str, dict]:
    tests_dir = root / "tests"
    nodes: dict[str, dict] = {}
    if not tests_dir.is_dir():
        return nodes
    for idx, path in enumerate(sorted(tests_dir.glob("*.sql"))):
        text = path.read_text(encoding="utf-8", errors="replace")
        refs = parse_refs(text)
        dep_uids = []
        for ref in refs:
            if ref in sql_models:
                dep_uids.append(model_uid(ref))
            elif ref == "agent_runs":
                dep_uids.append(seed_uid("agent_runs"))
        slug = path.stem
        uid = test_uid(f"singular_{slug}_{idx}")
        nodes[uid] = {
            "unique_id": uid,
            "name": slug,
            "package_name": PACKAGE,
            "resource_type": "test",
            "depends_on": {"nodes": dep_uids},
            "test_metadata": {"name": "singular", "column_name": ""},
            "description": f"Singular SQL test {slug}.",
        }
    return nodes


def _seed_node(root: Path) -> dict[str, dict]:
    seed_path = root / "seeds" / "agent_runs.csv"
    columns: dict[str, dict] = {}
    if seed_path.is_file():
        header = seed_path.read_text(encoding="utf-8").splitlines()[:1]
        if header:
            for col in header[0].split(","):
                col = col.strip()
                if col:
                    columns[col] = {
                        "name": col,
                        "description": f"Seed column {col}.",
                    }
    uid = seed_uid("agent_runs")
    return {
        uid: {
            "unique_id": uid,
            "name": "agent_runs",
            "package_name": PACKAGE,
            "resource_type": "seed",
            "description": "Raw agent run records collected from factory runs.",
            "original_file_path": "seeds/agent_runs.csv",
            "path": "agent_runs.csv",
            "fqn": [PACKAGE, "agent_runs"],
            "config": {"materialized": "seed"},
            "depends_on": {"nodes": []},
            "columns": columns,
        }
    }


def build_offline_manifest(repo_root: Path | str = ".") -> dict:
    root = dbt_root(Path(repo_root))
    sql_models = discover_sql_models(root)
    catalog = load_schema_catalog(root)
    nodes: dict[str, dict] = {}
    nodes.update(_seed_node(root))
    test_seq: dict[str, int] = {}

    for name, path in sorted(sql_models.items()):
        rel = path.relative_to(root).as_posix()
        uid = model_uid(name)
        meta = catalog.get(name, {})
        text = path.read_text(encoding="utf-8", errors="replace")
        refs = parse_refs(text)
        parents = []
        for ref in refs:
            if ref == "agent_runs":
                parents.append(seed_uid("agent_runs"))
            elif ref in sql_models:
                parents.append(model_uid(ref))
        layer = _layer_for_path(rel)
        fqn = [PACKAGE, layer, name] if layer != "other" else [PACKAGE, name]
        columns = dict(meta.get("columns") or {})
        nodes[uid] = {
            "unique_id": uid,
            "name": name,
            "package_name": PACKAGE,
            "resource_type": "model",
            "description": (meta.get("description") or "").strip()
            or (f"Mart model {name}." if "marts" in rel else f"Model {name}."),
            "original_file_path": rel if rel.startswith("models/") else f"models/{rel}",
            "path": path.name,
            "fqn": fqn,
            "config": {"materialized": _materialization_for(rel, "model")},
            "depends_on": {"nodes": parents},
            "columns": columns,
        }
        nodes.update(_schema_test_nodes(name, uid, meta, test_seq))

    nodes.update(_sql_test_nodes(root, sql_models))
    return {
        "metadata": {"dbt_schema_version": MANIFEST_SCHEMA},
        "nodes": nodes,
    }


def _node_needs_enrichment(node: dict, offline_node: dict | None) -> bool:
    if not offline_node:
        return False
    cols = node.get("columns") or {}
    off_cols = offline_node.get("columns") or {}
    if len(off_cols) > len(cols):
        return True
    if cols and all(str(k).startswith("col_") for k in cols):
        return True
    if not (node.get("description") or "").strip() and offline_node.get("description"):
        return True
    return False


def merge_manifests(base: dict | None, offline: dict) -> dict:
    """Merge on-disk manifest with offline discovery (adds missing models/tests, enriches stubs)."""
    if not base:
        return offline
    merged = json.loads(json.dumps(base))
    base_nodes = merged.setdefault("nodes", {})
    off_nodes = offline.get("nodes") or {}
    for uid, off_node in off_nodes.items():
        if uid not in base_nodes:
            base_nodes[uid] = off_node
            continue
        existing = base_nodes[uid]
        if existing.get("resource_type") in ("model", "seed") and _node_needs_enrichment(
            existing, off_node
        ):
            patched = dict(existing)
            patched["columns"] = off_node.get("columns") or {}
            if (off_node.get("description") or "").strip():
                patched["description"] = off_node["description"]
            if not (existing.get("depends_on") or {}).get("nodes") and off_node.get(
                "depends_on"
            ):
                patched["depends_on"] = off_node["depends_on"]
            base_nodes[uid] = patched
        if existing.get("resource_type") == "test":
            continue
    for uid, off_node in off_nodes.items():
        if off_node.get("resource_type") == "test" and uid not in base_nodes:
            base_nodes[uid] = off_node
    return merged


def export_table(con, table: str, out_dir: Path) -> int:
    try:
        rel = con.sql(f"select * from {table}")
    except Exception as exc:  # noqa: BLE001 — surface duckdb errors to stderr
        sys.stderr.write(f"ERROR: failed to read mart {table}: {exc}\n")
        raise SystemExit(1) from exc
    columns = [d[0] for d in rel.description]
    rows = [row_to_dict(columns, row) for row in rel.fetchall()]
    out_path = out_dir / f"{table}.json"
    with out_path.open("w", encoding="utf-8") as fh:
        json.dump(rows, fh, indent=2, sort_keys=True)
        fh.write("\n")
    return len(rows)


def write_manifest(path: Path, manifest: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)
        fh.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--db",
        default="factory/dbt/target/factory.duckdb",
        help="Path to the DuckDB database file produced by dbt build.",
    )
    parser.add_argument(
        "--out",
        default="site-data/dbt-marts",
        help="Directory for per-mart JSON row files.",
    )
    parser.add_argument(
        "--repo-root",
        default=".",
        help="Repository root containing factory/dbt (for offline manifest export).",
    )
    parser.add_argument(
        "--manifest-out",
        default="",
        help="Write synthesized manifest JSON to this path (offline DAG metadata).",
    )
    parser.add_argument(
        "--skip-marts",
        action="store_true",
        help="Only run manifest export (skip DuckDB mart reads).",
    )
    args = parser.parse_args()
    repo_root = Path(args.repo_root)

    if args.manifest_out:
        offline = build_offline_manifest(repo_root)
        manifest_path = Path(args.manifest_out)
        on_disk = None
        default_manifest = dbt_root(repo_root) / "target" / "manifest.json"
        if manifest_path == default_manifest and default_manifest.is_file():
            try:
                on_disk = json.loads(default_manifest.read_text(encoding="utf-8"))
            except (OSError, ValueError, TypeError):
                on_disk = None
        manifest = merge_manifests(on_disk, offline) if on_disk else offline
        write_manifest(manifest_path, manifest)
        model_count = sum(
            1
            for n in (manifest.get("nodes") or {}).values()
            if isinstance(n, dict) and n.get("resource_type") in ("model", "seed")
        )
        print(
            f"wrote manifest: {model_count} models/seeds -> {manifest_path}",
            file=sys.stderr,
        )

    if args.skip_marts and not args.manifest_out:
        parser.error("use --manifest-out and/or omit --skip-marts")

    if args.skip_marts:
        return 0

    db_path = Path(args.db)
    if not db_path.is_file():
        sys.stderr.write(f"ERROR: DuckDB database not found: {db_path}\n")
        sys.stderr.write("(run dbt build in factory/dbt before exporting marts)\n")
        return 1 if not args.manifest_out else 0

    try:
        import duckdb
    except ImportError:
        sys.stderr.write(
            "ERROR: duckdb is not installed; pip install -r factory/dbt/requirements-dbt.txt\n"
        )
        return 1 if not args.manifest_out else 0

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    con = duckdb.connect(str(db_path), read_only=True)
    try:
        total = 0
        exported = 0
        for table in TABLES:
            try:
                count = export_table(con, table, out_dir)
            except SystemExit:
                sys.stderr.write(f"SKIP  mart {table}: table missing in DuckDB\n")
                continue
            dest = out_dir / f"{table}.json"
            print(f"exported {table}: {count} rows -> {dest}")
            total += count
            exported += 1
    finally:
        con.close()

    print(f"Exported {exported} marts ({total} rows) to {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())