#!/usr/bin/env python3
"""Read-only validation of the whole library tree.

Checks:
  1. every .kicad_sym / .kicad_mod loads with the real KiCad parser
  2. every symbol Footprint property resolves to an existing footprint
  3. every footprint (model ...) path resolves on disk
  4. library tables: duplicate names, unresolvable URIs, missing targets
  5. duplicate top-level symbol names inside a library

Usage:
    python validate_library.py [--kicad-bin DIR] [--limit N]
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SYMBOLS = REPO / "Libraries" / "Symbols"
FOOTPRINTS = REPO / "Libraries" / "Footprints"
MODELS = REPO / "Libraries" / "3D_Models"
TABLES = REPO / "Libraries" / "Tables"
OFFICIAL = REPO / "Official"

DEFAULT_KICAD = Path(r"C:\Program Files\KiCad\10.0")
KICAD_PREFIX = DEFAULT_KICAD
KICAD_SHARE = KICAD_PREFIX / "share" / "kicad"

TABLE_RE = re.compile(r'\(lib \(name "([^"]*)"\) \(type "([^"]*)"\) \(uri "([^"]*)"')
TOP_SYMBOL_RE = re.compile(r'^\t\(symbol "([^"]+)"', re.M)
FP_PROP_RE = re.compile(r'\(property "Footprint" "([^"]*)"')
MODEL_RE = re.compile(r'\(model "([^"]*)"')

ENV_MAP = {
    "KICAD_ECO_ROOT": str(REPO),
    "KICAD_LIBRARY": str(REPO / "Libraries" / "3D_Models" / "Personal"),
    "KICAD10_SYMBOL_DIR": str(KICAD_SHARE / "symbols"),
    "KICAD10_FOOTPRINT_DIR": str(KICAD_SHARE / "footprints"),
    "KICAD10_3DMODEL_DIR": str(KICAD_SHARE / "3dmodels"),
    "KICAD10_TEMPLATE_DIR": str(KICAD_SHARE / "template"),
    "KISYS3DMOD": str(KICAD_SHARE / "3dmodels"),
    "KIPRJMOD": "",
}


def expand(uri: str) -> str:
    out = uri
    for k, v in ENV_MAP.items():
        out = out.replace("${%s}" % k, v)
    return out.replace("\\", "/")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


# --------------------------------------------------------------------------- #
# 1. parse every library with kicad-cli
# --------------------------------------------------------------------------- #
def parse_symbol_libs(cli: Path, files: list[Path]):
    bad = []
    tmp = Path(tempfile.mkdtemp(prefix="kchk-sym-"))
    for i, p in enumerate(files):
        out = tmp / str(i)
        r = subprocess.run(
            [str(cli), "sym", "export", "svg", str(p), "-o", str(out)],
            capture_output=True, text=True,
        )
        txt = (r.stdout + r.stderr)
        if r.returncode != 0 or "Unable to load" in txt:
            bad.append((p, txt.strip().splitlines()[:3]))
        for f in out.glob("*") if out.is_dir() else []:
            f.unlink()
    return bad


def parse_footprint_libs(cli: Path, files: list[Path]):
    """Validate footprint libraries directory by directory.

    ``kicad-cli fp upgrade`` only accepts a library folder, so each ``.pretty``
    is upgraded into a temporary folder and the number of written footprints is
    compared with the number of source files.  A file that KiCad cannot parse is
    silently dropped by the upgrade, which therefore shows up as a count
    mismatch.
    """
    bad = []
    seen: dict[Path, list[Path]] = {}
    for path in files:
        seen.setdefault(path.parent, []).append(path)

    tmp_root = Path(tempfile.mkdtemp(prefix="kchk-fp-"))
    for index, (directory, members) in enumerate(sorted(seen.items())):
        out = tmp_root / f"lib{index}"
        r = subprocess.run(
            [str(cli), "fp", "upgrade", str(directory), "-o", str(out), "--force"],
            capture_output=True, text=True,
        )
        produced = (
            sorted(p.name for p in out.glob("*.kicad_mod")) if out.is_dir() else []
        )
        expected = sorted(p.name for p in members)
        missing = [name for name in expected if name not in set(produced)]
        if r.returncode != 0 or missing:
            message = (r.stdout + r.stderr).strip().splitlines()[:3]
            for name in missing or ["<whole library>"]:
                bad.append((directory / name, message or ["footprint dropped by upgrade"]))
    return bad


# --------------------------------------------------------------------------- #
# 2. footprint references
# --------------------------------------------------------------------------- #
def load_tables() -> tuple[dict[str, set[str]], dict[str, Path]]:
    """nickname -> footprint names, nickname -> directory (from repo tables)."""
    libs: dict[str, set[str]] = {}
    dirs: dict[str, Path] = {}
    for table_name in ("fp-lib-table.FULL", "fp-lib-table.CUSTOM_ONLY"):
        path = TABLES / table_name
        if not path.is_file():
            continue
        for nick, typ, uri in TABLE_RE.findall(read(path)):
            if typ == "Table":
                continue
            d = Path(expand(uri))
            if d.is_dir():
                libs.setdefault(nick, set()).update(
                    f.name[: -len(".kicad_mod")]
                    for f in d.iterdir()
                    if f.name.endswith(".kicad_mod")
                )
                dirs.setdefault(nick, d)
    return libs, dirs


def check_symbol_footprints(libs, dirs):
    index: dict[str, list[str]] = collections.defaultdict(list)
    for nick, names in libs.items():
        for n in names:
            index[n].append(nick)
    problems = collections.defaultdict(list)
    total = 0
    for p in sorted(SYMBOLS.rglob("*.kicad_sym")):
        text = read(p)
        for m in FP_PROP_RE.finditer(text):
            v = m.group(1)
            if not v.strip():
                continue
            total += 1
            if ":" not in v:
                problems["NO_NICKNAME"].append((p.name, v))
                continue
            nick, fp = v.split(":", 1)
            if any(c in fp for c in "[]'\""):
                problems["BRACKET_OR_QUOTE"].append((p.name, v))
                continue
            if nick not in libs:
                problems["NICK_UNKNOWN"].append((p.name, v))
            elif fp not in libs[nick]:
                problems["FP_MISSING"].append((p.name, v))
    return problems, total


# --------------------------------------------------------------------------- #
# 3. 3D model paths
# --------------------------------------------------------------------------- #
def check_models():
    problems = collections.defaultdict(list)
    total = 0
    for base, _d, files in os.walk(FOOTPRINTS):
        if not base.endswith(".pretty"):
            continue
        for f in files:
            if not f.endswith(".kicad_mod"):
                continue
            p = Path(base) / f
            for m in MODEL_RE.finditer(read(p)):
                total += 1
                v = m.group(1)
                if not v.strip():
                    problems["EMPTY"].append((p.name, v))
                    continue
                if "${" not in v:
                    problems["NO_VAR"].append((p.name, v))
                    continue
                target = Path(expand(v))
                if not target.is_file():
                    problems["NOT_FOUND"].append((str(p.relative_to(REPO)), v))
    return problems, total


# --------------------------------------------------------------------------- #
# 4. library tables
# --------------------------------------------------------------------------- #
def check_table(path: Path, kind: str):
    rows = TABLE_RE.findall(read(path))
    names = [r[0] for r in rows]
    dups = [n for n, c in collections.Counter(names).items() if c > 1]
    missing = []
    for nick, typ, uri in rows:
        if typ == "Table":
            continue
        if "${KIPRJMOD}" in uri:  # project-relative, cannot check here
            continue
        target = Path(expand(uri))
        if not target.exists():
            missing.append((nick, uri))
    return len(rows), dups, missing


# --------------------------------------------------------------------------- #
# 5. duplicates inside symbol libs
# --------------------------------------------------------------------------- #
def check_symbol_dups():
    out = []
    for p in sorted(SYMBOLS.rglob("*.kicad_sym")):
        names = TOP_SYMBOL_RE.findall(read(p))
        d = [n for n, c in collections.Counter(names).items() if c > 1]
        if d:
            out.append((p.name, d))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kicad-bin", default=str(DEFAULT_KICAD / "bin" / "kicad-cli.exe"))
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()
    cli = Path(args.kicad_bin)
    if not cli.is_file():
        print("kicad-cli not found:", cli)
        return 2

    sym_files = sorted(SYMBOLS.rglob("*.kicad_sym"))
    fp_files = sorted(FOOTPRINTS.rglob("*.kicad_mod"))
    if args.limit:
        sym_files = sym_files[: args.limit]
        fp_files = fp_files[: args.limit]

    print(f"symbol libraries : {len(sym_files)}")
    print(f"footprint files  : {len(fp_files)}")

    print("\n[1] parsing symbols with KiCad ...", flush=True)
    bad_sym = parse_symbol_libs(cli, sym_files)
    print(f"    failures: {len(bad_sym)}")
    for p, msg in bad_sym[:20]:
        print("   ", p.relative_to(REPO), msg)

    print("[2] parsing footprints with KiCad ...", flush=True)
    bad_fp = parse_footprint_libs(cli, fp_files)
    print(f"    failures: {len(bad_fp)}")
    for p, msg in bad_fp[:20]:
        print("   ", p.relative_to(REPO), msg)

    print("[3] symbol -> footprint references ...", flush=True)
    libs, dirs = load_tables()
    fp_problems, fp_total = check_symbol_footprints(libs, dirs)
    print(f"    references: {fp_total}")
    for k, v in fp_problems.items():
        print(f"    {k}: {len(v)}")
        for row in v[:8]:
            print("       ", " | ".join(row))

    print("[4] 3D model paths ...", flush=True)
    m_problems, m_total = check_models()
    print(f"    references: {m_total}")
    for k, v in m_problems.items():
        print(f"    {k}: {len(v)}")
        for row in v[:8]:
            print("       ", " | ".join(row))

    print("[5] library tables ...")
    for name, kind in (
        ("sym-lib-table.FULL", "sym"),
        ("sym-lib-table.CUSTOM_ONLY", "sym"),
        ("sym-lib-table.PROJECT_SPECIFIC", "sym"),
        ("fp-lib-table.FULL", "fp"),
        ("fp-lib-table.CUSTOM_ONLY", "fp"),
        ("fp-lib-table.PROJECT_SPECIFIC", "fp"),
    ):
        n, dups, missing = check_table(TABLES / name, kind)
        print(f"    {name:<38} entries={n:<4} dups={len(dups)} missing={len(missing)}")
        for d in dups[:5]:
            print("        dup:", d)
        for nick, uri in missing[:5]:
            print("        missing:", nick, uri)

    print("[6] duplicate symbols inside a library ...")
    dups = check_symbol_dups()
    print(f"    files with duplicates: {len(dups)}")
    for name, d in dups[:20]:
        print("   ", name, d[:5])

    summary = {
        "symbol_parse_failures": len(bad_sym),
        "footprint_parse_failures": len(bad_fp),
        "footprint_refs": fp_total,
        "footprint_ref_problems": {k: len(v) for k, v in fp_problems.items()},
        "model_refs": m_total,
        "model_ref_problems": {k: len(v) for k, v in m_problems.items()},
        "symbol_dup_files": len(dups),
    }
    print("\nSUMMARY", json.dumps(summary, indent=2))
    return 0 if not (bad_sym or bad_fp or fp_problems or m_problems or dups) else 1


if __name__ == "__main__":
    sys.exit(main())
