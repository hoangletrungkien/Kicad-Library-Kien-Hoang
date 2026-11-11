#!/usr/bin/env python3
"""Make ``Database/`` portable: relink asset paths to the repository itself.

The catalog was generated from a sibling checkout
(``D:\\PCB_LIBRARY\\Kicad Lib\\hardware-components-main``), so every
``symbol_file`` / ``footprint_file`` value is an absolute path on the machine
that built it.  That makes the database useless after the repository is moved
or copied to another drive, which is exactly how this library is meant to be
used.

This tool rewrites those columns to repository-relative paths by looking the
asset up in the library that actually ships with the repository:

``symbol_file``
    matched by symbol name; only a unique match is accepted.
``footprint_file``
    matched by file stem inside ``Hardware Components Footprints.pretty``.

Unresolvable values are cleared, and ``component_db_summary.json`` loses its
absolute ``library_root``.  All three stores (CSV, SQLite, JSON) are updated
together so they cannot drift apart.

Usage::

    python relink_database.py            # dry run
    python relink_database.py --apply    # rewrite the stores
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import re
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DATABASE = REPO / "Database"
CSV_PATH = DATABASE / "component_master.csv"
SQLITE_PATH = DATABASE / "component_master.sqlite"
SUMMARY_PATH = DATABASE / "component_db_summary.json"
SYMBOLS = REPO / "Libraries" / "Symbols"
HW_FOOTPRINTS = REPO / "Libraries" / "Footprints" / "Hardware Components Footprints.pretty"

TOP_SYMBOL_RE = re.compile(r'(?m)^[\t ]\(symbol "([^"]+)"')
ABSOLUTE_PATH_RE = re.compile(r'^(?:[A-Za-z]:[\\/]|\\\\)')

CSV_COLUMNS = [
    "manufacturer", "mpn", "display_name", "description", "category",
    "keywords", "reference_prefix", "symbol", "footprint", "pin_count",
    "electrical_types", "datasheet", "blender_model", "gltf_model", "github",
    "public", "source_id", "source_record", "symbol_file", "footprint_file",
    "symbol_present", "footprint_present", "model_present",
    "verification_status", "quality_flags", "notes",
]


def rel(path: Path) -> str:
    return path.relative_to(REPO).as_posix()


def build_indexes() -> tuple[dict[str, list[str]], dict[str, str]]:
    """symbol name -> owning library files, footprint stem -> footprint file.

    Every row in ``component_master.csv`` comes from the Antmicro source set,
    so the ``Antmicro_*`` libraries are searched first.  A name that is not
    there falls back to the whole tree, which keeps Personal libraries from
    making an otherwise unique match ambiguous.
    """
    def scan(paths) -> dict[str, list[str]]:
        found: dict[str, list[str]] = defaultdict(list)
        for path in paths:
            text = path.read_text(encoding="utf-8", errors="replace")
            for name in set(TOP_SYMBOL_RE.findall(text)):
                found[name].append(rel(path))
        return found

    all_files = sorted(SYMBOLS.rglob("*.kicad_sym"))
    antmicro = [p for p in all_files if p.name.startswith("Antmicro_")]
    by_name = scan(antmicro)
    fallback = scan([p for p in all_files if p not in set(antmicro)])
    for name, paths in fallback.items():
        by_name.setdefault(name, paths)

    by_stem = {p.stem: rel(p) for p in HW_FOOTPRINTS.glob("*.kicad_mod")}
    return by_name, by_stem


def resolve(rows, by_name, by_stem) -> tuple[list[dict], dict[str, int]]:
    stats = defaultdict(int)
    for row in rows:
        symbol = (row.get("symbol") or "").strip()
        if symbol:
            candidates = by_name.get(symbol, [])
            if len(candidates) == 1:
                new = candidates[0]
            else:
                new = ""
                stats["symbol_ambiguous" if candidates else "symbol_missing"] += 1
            old = (row.get("symbol_file") or "").strip()
            if new or old:
                if new == "":
                    stats["symbol_cleared"] += 1
                elif new != old.replace("\\", "/"):
                    stats["symbol_relinked"] += 1
                row["symbol_file"] = new

        footprint = (row.get("footprint") or "").strip()
        if footprint:
            new = by_stem.get(footprint, "")
            if not new:
                stats["footprint_missing"] += 1
            old = (row.get("footprint_file") or "").strip()
            if new or old:
                if new == "":
                    stats["footprint_cleared"] += 1
                elif new != old.replace("\\", "/"):
                    stats["footprint_relinked"] += 1
                row["footprint_file"] = new
    return rows, dict(stats)


def write_csv(rows: list[dict]) -> None:
    buffer = io.StringIO()
    # The file has always been UTF-8 with BOM and CRLF; keep it that way so
    # Excel on a Vietnamese Windows still opens it correctly.
    writer = csv.DictWriter(buffer, fieldnames=CSV_COLUMNS, lineterminator="\r\n")
    writer.writeheader()
    for row in rows:
        writer.writerow({key: row.get(key, "") for key in CSV_COLUMNS})
    CSV_PATH.write_text("\ufeff" + buffer.getvalue(), encoding="utf-8", newline="")


def write_sqlite(rows: list[dict]) -> None:
    connection = sqlite3.connect(SQLITE_PATH)
    try:
        with connection:
            connection.execute("DELETE FROM components")
            placeholders = ", ".join("?" for _ in CSV_COLUMNS)
            quoted = ", ".join(f'"{name}"' for name in CSV_COLUMNS)
            payload = [tuple(row.get(name, "") for name in CSV_COLUMNS) for row in rows]
            connection.executemany(
                f"INSERT INTO components ({quoted}) VALUES ({placeholders})", payload
            )
            connection.execute(
                "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                ("library_root", "repository-relative"),
            )
            connection.execute(
                "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                ("row_count", str(len(rows))),
            )
    finally:
        connection.close()


def write_summary(stats: dict[str, int]) -> None:
    data = json.loads(SUMMARY_PATH.read_text(encoding="utf-8"))
    data["library_root"] = "repository-relative"
    data["path_columns"] = "relative to the repository root, forward slashes"
    SUMMARY_PATH.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    rows = list(csv.DictReader(CSV_PATH.open(encoding="utf-8-sig", newline="")))
    if len(rows) != 3573:
        print(f"unexpected row count: {len(rows)}", file=sys.stderr)
        return 2

    by_name, by_stem = build_indexes()
    rows, stats = resolve(rows, by_name, by_stem)

    print(f"rows              : {len(rows)}")
    print(f"symbols indexed   : {len(by_name)}")
    print(f"footprints indexed: {len(by_stem)}")
    for key in sorted(stats):
        print(f"  {key:<20} {stats[key]}")

    remaining = sum(
        1
        for row in rows
        for column in ("symbol_file", "footprint_file")
        if ABSOLUTE_PATH_RE.match((row.get(column) or "").strip())
    )
    print(f"absolute paths left: {remaining}")

    if not args.apply:
        print("\nDRY RUN - nothing written. Re-run with --apply.")
        return 0

    write_csv(rows)
    write_sqlite(rows)
    write_summary(stats)
    print("\nwritten: component_master.csv, component_master.sqlite, component_db_summary.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
