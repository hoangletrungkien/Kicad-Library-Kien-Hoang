#!/usr/bin/env python3
"""
Repair the Footprint property of every symbol in this KiCad library repository.

Background
----------
The Antmicro "hardware-components" generator (generate_modular_libs.py) wrote
the Footprint property like this::

    (property "Footprint" "Hardware Components Footprints:['Resonator_48MHz_ABM10W']"

because it called ``"Resonator_48MHz_ABM10W".split(":")`` and only unwrapped the
result when ``len(...) == 2``. KiCad splits on ":" and then looks for a footprint
literally named ``['Resonator_48MHz_ABM10W']``, which does not exist.

On top of that, the upstream repository stores a *placeholder* (the symbol name)
in the Footprint property of the per-component symbol files, so simply removing
the brackets still leaves the wrong name. The only authoritative
symbol -> footprint mapping is Database/component_master.csv.

What this script does
---------------------
1. Antmicro_* symbol libraries: rewrite every correct-able Footprint property to
       Hardware Components Footprints:<name from component_master.csv>
   Symbols with no mapping (templates) are left untouched.
2. Libraries/Symbols/Personal/*.kicad_sym: repair nicknames that are not
   registered in fp-lib-table by prefixing "PERSONAL_", but only when that
   registered library actually contains the named footprint.
3. Deduplicates repeated top-level symbols that differ *only* in their
   Footprint property (KiCad keeps just one of them anyway).

Every symbol body is rewritten in place: only the value between the quotes of
the Footprint property changes, so line endings, indentation and the rest of the
file stay byte-identical.

Usage
-----
    python repair_footprints.py            # dry run, writes a report
    python repair_footprints.py --apply    # rewrite the .kicad_sym files
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import shutil
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LIB_DIR = REPO / "Libraries"
SYM_DIR = LIB_DIR / "Symbols"
PERSONAL_SYM_DIR = SYM_DIR / "Personal"
FP_DIR = LIB_DIR / "Footprints"
TABLES = LIB_DIR / "Tables"
MASTER_CSV = REPO / "Database" / "component_master.csv"
REPORT_DIR = REPO / "Database"
HW_LIB = "Hardware Components Footprints"

TOP_SYMBOL_RE = re.compile(r'^\t\(symbol "([^"]+)"', re.M)
FOOTPRINT_RE = re.compile(r'(\(property "Footprint" ")([^"]*)"')
EXTENDS_RE = re.compile(r'\(extends "')


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def read_text(path: Path) -> str:
    """Read without newline translation so CRLF survives the round trip."""
    with open(path, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def write_text(path: Path, text: str) -> None:
    """Write preserving BOM state and line endings (newline='' keeps them as-is)."""
    had_bom = path.read_bytes().startswith(b"\xef\xbb\xbf")
    with open(path, "w", encoding="utf-8-sig" if had_bom else "utf-8", newline="") as fh:
        fh.write(text)


def split_top_symbols(text: str):
    """Yield (start, end, name) for every top-level (symbol ...) block."""
    marks = [(m.start(), m.group(1)) for m in TOP_SYMBOL_RE.finditer(text)]
    bounds = marks + [(len(text), None)]
    for i in range(len(marks)):
        yield bounds[i][0], bounds[i + 1][0], marks[i][1]


def local_offsets(block: str):
    return [(m.start(2), m.end(2), m.group(2)) for m in FOOTPRINT_RE.finditer(block)]


def footprint_names_on_disk() -> tuple[set[str], dict[str, list[str]]]:
    """Return (all names, name -> [library nicknames]) across every .pretty dir."""
    names: set[str] = set()
    by_name: dict[str, list[str]] = defaultdict(list)
    for base, _dirs, files in os.walk(FP_DIR):
        if not base.endswith(".pretty"):
            continue
        nick = os.path.basename(base)[: -len(".pretty")]
        for f in files:
            if f.endswith(".kicad_mod"):
                n = f[: -len(".kicad_mod")]
                names.add(n)
                by_name[n].append(nick)
    return names, by_name


def registered_footprint_libs() -> dict[str, set[str]]:
    """nickname -> set of footprint names, resolved from fp-lib-table.FULL."""
    table = read_text(TABLES / "fp-lib-table.FULL")
    out: dict[str, set[str]] = {}
    for nick, uri in re.findall(r'\(name "([^"]+)"\) \(type "[^"]*"\) \(uri "([^"]+)"', table):
        d = (
            uri.replace("${KICAD_ECO_ROOT}", str(REPO))
            .replace("${KICAD10_FOOTPRINT_DIR}", str(REPO / "Official" / "kicad-footprints"))
            .replace("\\", "/")
        )
        if os.path.isdir(d):
            out[nick] = {f[: -len(".kicad_mod")] for f in os.listdir(d) if f.endswith(".kicad_mod")}
    return out


def load_master_map() -> dict[str, str]:
    """symbol name -> authoritative footprint name from component_master.csv."""
    mapping: dict[str, str] = {}
    conflicts: dict[str, set[str]] = defaultdict(set)
    with open(MASTER_CSV, encoding="utf-8", errors="replace", newline="") as fh:
        for row in csv.DictReader(fh):
            sym = (row.get("symbol") or "").strip()
            fp = (row.get("footprint") or "").strip()
            if sym and fp:
                conflicts[sym].add(fp)
    for sym, fps in conflicts.items():
        if len(fps) == 1:
            mapping[sym] = next(iter(fps))
        # ambiguous symbols are skipped on purpose
    return mapping


def is_template_symbol(name: str) -> bool:
    low = name.lower()
    return "template" in low or name.startswith(".") or low.startswith("tem")


# --------------------------------------------------------------------------- #
# Antmicro repair
# --------------------------------------------------------------------------- #
def plan_antmicro(master: dict[str, str], disk: set[str]):
    """Return per-file rewrite plans plus a report of untouched symbols."""
    plans: dict[Path, str] = {}
    report: list[tuple[str, str, str, str, str]] = []

    for path in sorted(SYM_DIR.glob("Antmicro_*.kicad_sym")):
        text = read_text(path)
        edits: list[tuple[int, int, str]] = []  # absolute offsets in `text`

        for start, end, name in split_top_symbols(text):
            block = text[start:end]
            hits = local_offsets(block)
            if not hits:
                continue
            value_start, value_end, current = hits[0]

            target = master.get(name)
            if target and target in disk:
                new_value = f"{HW_LIB}:{target}"
                if new_value != current:
                    edits.append((start + value_start, start + value_end, new_value))
                    report.append((path.name, name, current, new_value, "FIXED"))
            else:
                if is_template_symbol(name):
                    status = "SKIPPED_TEMPLATE"
                elif target:
                    status = "SKIPPED_FOOTPRINT_FILE_MISSING"
                else:
                    status = "SKIPPED_NO_MAPPING"
                report.append((path.name, name, current, "", status))

        if edits:
            new_text = text
            for s, e, v in sorted(edits, key=lambda x: -x[0]):
                new_text = new_text[:s] + v + new_text[e:]
            plans[path] = new_text

    return plans, report


# --------------------------------------------------------------------------- #
# Personal repair
# --------------------------------------------------------------------------- #
def build_footprint_index(registered: dict[str, set[str]]) -> dict[str, list[str]]:
    """footprint name -> registered nicknames that actually contain it."""
    idx: dict[str, list[str]] = defaultdict(list)
    for nick, names in registered.items():
        for n in names:
            idx[n].append(nick)
    return idx


def resolve_personal(raw: str, registered: dict[str, set[str]], index: dict[str, list[str]]):
    """Pick a registered nickname for a footprint reference.

    Order of preference:
      1. PERSONAL_<original nickname>, when it exists and holds that footprint
      2. the one and only registered library holding the footprint
      3. a unique match, preferring the PERSONAL_ variant when several match
    """
    if ":" in raw:
        nick, fp_name = raw.split(":", 1)
    else:
        nick, fp_name = None, raw
    if nick and nick in registered:
        return raw  # already valid, caller sees resolved == current

    if nick:
        candidate = f"PERSONAL_{nick}"
        if candidate in registered and fp_name in registered[candidate]:
            return f"{candidate}:{fp_name}"

    matches = index.get(fp_name, [])
    if len(matches) == 1:
        return f"{matches[0]}:{fp_name}"
    return None


def plan_personal(registered: dict[str, set[str]], index: dict[str, list[str]]):
    plans: dict[Path, str] = {}
    report: list[tuple[str, str, str, str, str]] = []

    for path in sorted(PERSONAL_SYM_DIR.glob("*.kicad_sym")):
        text = read_text(path)
        edits: list[tuple[int, int, str]] = []

        for start, end, name in split_top_symbols(text):
            block = text[start:end]
            hits = local_offsets(block)
            if not hits:
                continue
            vs, ve, current = hits[0]
            if not current.strip():
                report.append((path.name, name, current, "", "SKIPPED_EMPTY"))
                continue

            resolved = resolve_personal(current, registered, index)
            if resolved is None:
                if ":" in current:
                    report.append((path.name, name, current, "", "SKIPPED_LIBRARY_NOT_FOUND"))
                else:
                    report.append((path.name, name, current, "", "SKIPPED_NO_LIBRARY"))
                continue
            if resolved == current:
                continue

            edits.append((start + vs, start + ve, resolved))
            report.append((path.name, name, current, resolved, "FIXED"))

        if edits:
            new_text = text
            for s, e, v in sorted(edits, key=lambda x: -x[0]):
                new_text = new_text[:s] + v + new_text[e:]
            plans[path] = new_text

    return plans, report


# --------------------------------------------------------------------------- #
# Deduplication of identical-except-Footprint symbols
# --------------------------------------------------------------------------- #
def plan_dedup(plans: dict[Path, str]):
    """Collapse repeated top-level symbols whose only difference is Footprint.

    KiCad loads only one of them anyway; a duplicate that *does* differ in its
    footprint is genuinely ambiguous, so those are reported and left alone.
    """
    new_plans: dict[Path, str] = dict(plans)
    removed: list[tuple[str, str, int]] = []
    ambiguous: list[tuple[str, str, list[str]]] = []

    for path in sorted(SYM_DIR.glob("*.kicad_sym")):
        text = new_plans.get(path) or read_text(path)
        blocks = list(split_top_symbols(text))

        groups: dict[str, list[tuple[int, int, str]]] = defaultdict(list)
        for s, e, name in blocks:
            groups[name].append((s, e, text[s:e]))

        drop: list[tuple[int, int]] = []
        for name, items in groups.items():
            if len(items) < 2:
                continue
            stripped = {re.sub(r'\(property "Footprint" "[^"]*"', "", b) for _s, _e, b in items}
            if len(stripped) != 1:
                good = []
                for _s, _e, b in items:
                    m = FOOTPRINT_RE.search(b)
                    good.append(m.group(2) if m else "")
                ambiguous.append((path.name, name, good))
                continue
            for s, e, _b in items[1:]:
                drop.append((s, e))
            removed.append((path.name, name, len(items) - 1))

        if drop:
            out = []
            cursor = 0
            for s, e in sorted(drop):
                out.append(text[cursor:s])
                cursor = e
            out.append(text[cursor:])
            new_plans[path] = "".join(out)

    return new_plans, removed, ambiguous


# --------------------------------------------------------------------------- #
# verification
# --------------------------------------------------------------------------- #
def verify(disk: set[str]) -> tuple[Counter, list[tuple[str, str, str]]]:
    stats: Counter = Counter()
    bad: list[tuple[str, str, str]] = []
    for path in sorted(SYM_DIR.glob("Antmicro_*.kicad_sym")):
        text = read_text(path)
        for _s, _e, name in split_top_symbols(text):
            block = text[_s:_e]
            m = FOOTPRINT_RE.search(block)
            value = m.group(2) if m else ""
            if re.match(r"^[^:\[\]']+:[^\[\]']+$", value) and value.split(":", 1)[1] in disk:
                stats["OK"] += 1
            elif is_template_symbol(name):
                stats["TEMPLATE"] += 1
            else:
                stats["BROKEN"] += 1
                bad.append((path.name, name, value))
    return stats, bad


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="actually rewrite the .kicad_sym files")
    args = ap.parse_args()

    disk, _by_name = footprint_names_on_disk()
    registered = registered_footprint_libs()
    master = load_master_map()

    print(f"repository         : {REPO}")
    print(f"footprints on disk : {len(disk)}")
    print(f"registered libs    : {len(registered)}")
    print(f"master mappings    : {len(master)}")

    am_plans, am_report = plan_antmicro(master, disk)
    index = build_footprint_index(registered)
    pe_plans, pe_report = plan_personal(registered, index)

    merged: dict[Path, str] = {}
    merged.update(am_plans)
    merged.update(pe_plans)

    merged, dedup_removed, dedup_ambiguous = plan_dedup(merged)

    print(f"\nfiles to rewrite   : {len(merged)}")
    print(f"duplicate blocks   : {sum(n for _f, _s, n in dedup_removed)} removed")
    if dedup_ambiguous:
        print(f"ambiguous dupes    : {len(dedup_ambiguous)} (left untouched)")
        for f, s, v in dedup_ambiguous[:5]:
            print(f"    {f}: {s} -> {v}")

    # report
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    report_path = REPORT_DIR / f"footprint_repair_report-{stamp}.csv"
    with open(report_path, "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh)
        w.writerow(["library_file", "symbol", "old_value", "new_value", "status"])
        w.writerows(am_report)
        w.writerows(pe_report)
    print(f"report             : {report_path}")
    print(f"  antmicro rows    : {len(am_report)} {dict(Counter(r[4] for r in am_report))}")
    print(f"  personal rows    : {len(pe_report)} {dict(Counter(r[4] for r in pe_report))}")

    if not args.apply:
        print("\nDRY RUN - nothing written. Re-run with --apply to rewrite files.")
        return 0

    # backup
    backup_root = Path(os.environ.get("LOCALAPPDATA", REPO)) / "KiCad Library Kien Hoang" / "Backups"
    backup_dir = backup_root / f"symbols-{stamp}"
    backup_dir.mkdir(parents=True, exist_ok=True)
    for path in merged:
        rel = path.relative_to(SYM_DIR)
        dest = backup_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, dest)
    print(f"\nbackup             : {backup_dir}")

    for path, text in merged.items():
        write_text(path, text)
    print(f"rewritten          : {len(merged)} files")

    stats, bad = verify(disk)
    print(f"\nverification       : {dict(stats)}")
    if bad:
        print("  still broken (expected: template symbols only):")
        for f, s, v in bad[:15]:
            print(f"    {f}: {s} -> {v!r}")
        if len(bad) > 15:
            print(f"    ... {len(bad) - 15} more")
    return 0


if __name__ == "__main__":
    sys.exit(main())
