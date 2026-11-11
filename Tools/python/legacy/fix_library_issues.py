#!/usr/bin/env python3
"""Fix the remaining defects in the KiCad library after repair_footprints.py.

Three independent passes, all idempotent:

1. Antmicro symbol libraries
   Footprint values that still look like ``Hardware Components Footprints:['X']``
   (left behind because ``repair_footprints.py`` never touches template
   symbols) are unwrapped to ``Hardware Components Footprints:X`` when the
   footprint file really exists.  When X does not exist in any library the
   value is cleared instead of pointing at a footprint that cannot be loaded.

2. Personal symbol libraries
   Every Footprint value is resolved against the *installed* fp-lib-table:
     * already valid                      -> untouched
     * nickname now lives under PERSONAL_ -> nickname corrected
     * footprint name unique in the table -> rewritten to that nickname
     * anything else (unknown nickname, datasheet URL, bare name, missing
       footprint)                         -> cleared so KiCad shows an
                                             unassigned footprint instead of
                                             a broken link.

3. Footprint files
   ``(model ...)`` blocks whose path is empty or not path-like at all
   (``""``, ``"/"``, ``"s"``) are removed.  These come from a broken exporter
   and make KiCad raise a 3D-model load error for the footprint.

Line endings and BOM state are preserved; only the affected bytes change.

Usage
-----
    python fix_library_issues.py            # dry run
    python fix_library_issues.py --apply
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SYMBOLS = REPO / "Libraries" / "Symbols"
PERSONAL = SYMBOLS / "Personal"
FOOTPRINTS = REPO / "Libraries" / "Footprints"
FP_TABLE = Path(os.environ.get("APPDATA", "")) / "kicad" / "10.0" / "fp-lib-table"
KICAD_FOOTPRINT_DIR = Path(r"C:\Program Files\KiCad\10.0\share\kicad\footprints")
HW_LIB = "Hardware Components Footprints"

TOP_SYMBOL_RE = re.compile(r'^\t\(symbol "([^"]+)"', re.M)
FOOTPRINT_RE = re.compile(r'(\(property "Footprint" ")([^"]*)"')
BRACKET_RE = re.compile(r"^[^:]+:\[?'(.*)'\]$")


# --------------------------------------------------------------------------- #
# io helpers
# --------------------------------------------------------------------------- #
def read_text(path: Path) -> str:
    with open(path, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def write_text(path: Path, text: str) -> None:
    had_bom = path.read_bytes().startswith(b"\xef\xbb\xbf")
    with open(path, "w", encoding="utf-8-sig" if had_bom else "utf-8", newline="") as fh:
        fh.write(text)


def split_top_symbols(text: str):
    marks = [(m.start(), m.group(1)) for m in TOP_SYMBOL_RE.finditer(text)]
    bounds = marks + [(len(text), None)]
    for i in range(len(marks)):
        yield bounds[i][0], bounds[i + 1][0], marks[i][1]


# --------------------------------------------------------------------------- #
# library index
# --------------------------------------------------------------------------- #
def registered_libraries() -> dict[str, set[str]]:
    """nickname -> footprint names, resolved from the installed fp-lib-table."""
    table = read_text(FP_TABLE)
    out: dict[str, set[str]] = {}
    for nick, typ, uri in re.findall(
        r'\(lib \(name "([^"]+)"\) \(type "([^"]*)"\) \(uri "([^"]+)"', table
    ):
        if typ == "Table":
            continue
        directory = (
            uri.replace("${KICAD_ECO_ROOT}", str(REPO))
            .replace("${KICAD10_FOOTPRINT_DIR}", str(KICAD_FOOTPRINT_DIR))
            .replace("\\", "/")
        )
        if os.path.isdir(directory):
            out[nick] = {
                f[: -len(".kicad_mod")]
                for f in os.listdir(directory)
                if f.endswith(".kicad_mod")
            }
    return out


def footprints_on_disk() -> set[str]:
    names: set[str] = set()
    for base, _dirs, files in os.walk(FOOTPRINTS):
        if base.endswith(".pretty"):
            names.update(f[: -len(".kicad_mod")] for f in files if f.endswith(".kicad_mod"))
    return names


# --------------------------------------------------------------------------- #
# pass 1 - Antmicro bracket values
# --------------------------------------------------------------------------- #
def plan_brackets(disk: set[str]):
    plans: dict[Path, str] = {}
    report: list[tuple[str, str, str, str]] = []

    for path in sorted(SYMBOLS.glob("Antmicro_*.kicad_sym")):
        text = read_text(path)
        edits: list[tuple[int, int, str]] = []

        for start, end, name in split_top_symbols(text):
            block = text[start:end]
            hits = [m for m in FOOTPRINT_RE.finditer(block)]
            if not hits:
                continue
            vs, ve, current = hits[0].start(2), hits[0].end(2), hits[0].group(2)
            inner = BRACKET_RE.match(current)
            if not inner:
                continue
            candidate = inner.group(1)
            if candidate in disk:
                new_value = f"{HW_LIB}:{candidate}"
                status = "UNWRAPPED"
            else:
                new_value = ""
                status = "CLEARED"
            edits.append((start + vs, start + ve, new_value))
            report.append((path.name, name, current, f"{status} -> {new_value!r}"))

        if edits:
            new_text = text
            for s, e, v in sorted(edits, key=lambda x: -x[0]):
                new_text = new_text[:s] + v + new_text[e:]
            plans[path] = new_text

    return plans, report


# --------------------------------------------------------------------------- #
# pass 2 - personal symbol libraries
# --------------------------------------------------------------------------- #
def resolve(value: str, libs: dict[str, set[str]], index: dict[str, list[str]], registered: set[str]):
    if ":" in value and not value.startswith("http"):
        nick, fp = value.split(":", 1)
    else:
        nick, fp = None, value

    if nick and nick in registered and fp in libs[nick]:
        return value, "OK"

    if nick:
        candidate = f"PERSONAL_{nick}"
        if candidate in registered and fp in libs[candidate]:
            return f"{candidate}:{fp}", "RENAMED"

    matches = index.get(fp, [])
    if len(matches) == 1:
        return f"{matches[0]}:{fp}", "RESOLVED"

    return "", "CLEARED"


def plan_personal(libs: dict[str, set[str]]):
    registered = set(libs)
    index: dict[str, list[str]] = defaultdict(list)
    for nick, names in libs.items():
        for n in names:
            index[n].append(nick)
    for n in index:
        index[n].sort(key=lambda x: (not x.startswith("PERSONAL_"), x))

    plans: dict[Path, str] = {}
    report: list[tuple[str, str, str, str, str]] = []

    for path in sorted(PERSONAL.glob("*.kicad_sym")):
        text = read_text(path)
        edits: list[tuple[int, int, str]] = []

        for start, end, name in split_top_symbols(text):
            block = text[start:end]
            hits = [m for m in FOOTPRINT_RE.finditer(block)]
            if not hits:
                continue
            vs, ve, current = hits[0].start(2), hits[0].end(2), hits[0].group(2)
            if not current.strip():
                continue
            new_value, status = resolve(current, libs, index, registered)
            if status == "OK":
                continue
            edits.append((start + vs, start + ve, new_value))
            report.append((path.name, name, current, new_value, status))

        if edits:
            new_text = text
            for s, e, v in sorted(edits, key=lambda x: -x[0]):
                new_text = new_text[:s] + v + new_text[e:]
            plans[path] = new_text

    return plans, report


# --------------------------------------------------------------------------- #
# pass 3 - broken 3D model blocks in footprints
# --------------------------------------------------------------------------- #
def strip_bad_models(text: str) -> tuple[str, int]:
    """Remove (model ...) blocks whose path is not a usable path."""
    out = []
    cursor = 0
    removed = 0
    i = 0
    while True:
        i = text.find("(model ", i)
        if i < 0:
            break
        # make sure this is a standalone token, not inside a string
        quote_count = text.count('"', 0, i)
        if quote_count % 2 == 1:
            i += 1
            continue
        # find the string argument
        m = re.match(r'\(model "([^"]*)"', text[i:])
        if not m:
            i += 1
            continue
        value = m.group(1).strip()
        if re.match(r"^(\$\{[A-Za-z0-9_]+\}|[A-Za-z]:[\\/])", value) and re.search(
            r"\.[A-Za-z0-9]{2,5}$", value
        ):
            i += 1
            continue
        # walk to the matching close paren
        depth = 0
        j = i
        in_string = False
        escaped = False
        while j < len(text):
            ch = text[j]
            if in_string:
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == '"':
                    in_string = False
            elif ch == '"':
                in_string = True
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    j += 1
                    break
            j += 1
        if depth != 0:
            break
        # also swallow the indentation that preceded the block
        k = i
        while k > cursor and text[k - 1] in " \t":
            k -= 1
        line_start = text.rfind("\n", cursor, k) + 1
        if line_start > cursor and text[line_start:k].strip() == "":
            k = line_start
        elif k > cursor and text[k - 1] in "\r\n":
            pass
        out.append(text[cursor:k])
        cursor = j
        removed += 1
        i = j
    out.append(text[cursor:])
    return "".join(out), removed


def plan_models():
    plans: dict[Path, str] = {}
    removed_total = 0
    files = 0
    for base, _dirs, names in os.walk(FOOTPRINTS):
        if not base.endswith(".pretty"):
            continue
        for name in names:
            if not name.endswith(".kicad_mod"):
                continue
            path = Path(base) / name
            text = read_text(path)
            if "(model " not in text:
                continue
            new_text, removed = strip_bad_models(text)
            if removed:
                plans[path] = new_text
                removed_total += removed
                files += 1
    return plans, removed_total, files


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--apply", action="store_true", help="write the changes")
    args = parser.parse_args()

    if not FP_TABLE.is_file():
        print(f"ERROR: installed fp-lib-table not found: {FP_TABLE}")
        return 2

    disk = footprints_on_disk()
    libs = registered_libraries()

    bracket_plans, bracket_report = plan_brackets(disk)
    personal_plans, personal_report = plan_personal(libs)
    model_plans, model_removed, model_files = plan_models()

    print(f"footprints on disk : {len(disk)}")
    print(f"registered libs    : {len(libs)}")
    print()
    print(f"1) Antmicro brackets : {len(bracket_report)} values in {len(bracket_plans)} files")
    print(f"   {dict(Counter(r[3].split(' ')[0] for r in bracket_report))}")
    print(f"2) Personal refs     : {len(personal_report)} values in {len(personal_plans)} files")
    print(f"   {dict(Counter(r[4] for r in personal_report))}")
    print(f"3) Broken 3D models  : {model_removed} blocks in {model_files} files")

    for title, rows in (
        ("personal changes", personal_report),
        ("antmicro changes", bracket_report),
    ):
        print(f"\n-- {title}")
        for row in rows[:20]:
            print("   ", " | ".join(row))
        if len(rows) > 20:
            print(f"    ... {len(rows) - 20} more")

    if not args.apply:
        print("\nDRY RUN - nothing written. Re-run with --apply to rewrite files.")
        return 0

    merged: dict[Path, str] = {}
    merged.update(bracket_plans)
    merged.update(personal_plans)
    merged.update(model_plans)

    backup = Path(os.environ.get("LOCALAPPDATA", REPO)) / "KiCad Library Kien Hoang" / "Backups"
    from datetime import datetime

    backup_dir = backup / f"links-{datetime.now():%Y%m%d-%H%M%S}"
    for path in merged:
        try:
            rel = path.relative_to(REPO)
        except ValueError:
            rel = Path(path.name)
        dest = backup_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, dest)

    for path, text in merged.items():
        write_text(path, text)

    print(f"\nrewritten          : {len(merged)} files")
    print(f"backup             : {backup_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
