#!/usr/bin/env python3
"""Bring the whole KiCad library tree to a consistent, loadable state.

The tool is idempotent: running it twice changes nothing the second time.

What it repairs
---------------
1. ``Footprint`` properties of every symbol
   * Antmicro_* libraries: the authoritative mapping is
     ``Database/component_master.csv``.  The value is set to
     ``Hardware Components Footprints:<footprint>`` when that footprint exists
     on disk.  Placeholder values (``Lib:['X']``) left behind by the upstream
     generator are unwrapped when ``X`` exists, and cleared otherwise so KiCad
     shows "unassigned" instead of a broken link.
   * Personal libraries: broken nicknames are repaired against the footprint
     libraries that really exist (installed fp-lib-table plus the repository
     tables), falling back to a unique footprint-name lookup.  Values that
     cannot be resolved are cleared.  Datasheet URLs stored in the Footprint
     field are removed.
   * Both indentation styles are supported (KiCad 6/7 uses two spaces,
     KiCad 8+ uses tabs) -- the old script only looked at tab-indented files.

2. ``(model ...)`` blocks in footprints
   * Blocks whose path is empty or is not a path at all (``""``, ``"/"``,
     ``"s"``) are deleted -- they are leftovers of a broken exporter and make
     KiCad report 3D-model load errors.
   * When a model with the same name exists in the official 3D library or in
     ``Libraries/3D_Models/Personal`` the block is relinked to it instead,
     including fixing ``.wrl`` -> ``.step`` when only the STEP file ships.

3. Reports: every change is written to a CSV under ``Database/`` together with
   the assets that are still missing (so they can be sourced later).

Usage
-----
    python finalize_library.py                  # dry run, prints a summary
    python finalize_library.py --apply          # rewrite the files
    python finalize_library.py --apply --report Database/finalize-report.csv
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
SYMBOLS = REPO / "Libraries" / "Symbols"
PERSONAL_SYM = SYMBOLS / "Personal"
FOOTPRINTS = REPO / "Libraries" / "Footprints"
MODELS = REPO / "Libraries" / "3D_Models" / "Personal"
TABLES = REPO / "Libraries" / "Tables"
MASTER_CSV = REPO / "Database" / "component_master.csv"
INSTALLED_FP_TABLE = Path(os.environ.get("APPDATA", "")) / "kicad" / "10.0" / "fp-lib-table"
KICAD_FOOTPRINT_DIR = Path(r"C:\Program Files\KiCad\10.0\share\kicad\footprints")
KICAD_3DMODEL_DIR = Path(r"C:\Program Files\KiCad\10.0\share\kicad\3dmodels")

HW_NICK = "Hardware Components Footprints"
MODEL_EXTS = (".step", ".stp", ".wrl")

FP_PROPERTY_RE = re.compile(r'(\(property "Footprint" ")([^"]*)(")')
TOP_PROPERTY_RE = re.compile(r'^([ \t]*)\(symbol "([^"]+)"', re.M)
LIB_ENTRY_RE = re.compile(
    r'\(lib \(name "([^"]*)"\) \(type "([^"]*)"\) \(uri "([^"]*)"'
)
BRACKET_RE = re.compile(r"^[^:]+:\[?'(.*)'\]$")
URL_RE = re.compile(r"^(https?|ftp)://", re.I)

# Path variables -> absolute folder, used to test model paths on disk.
MODEL_ENV = {
    "${KICAD_LIBRARY}": str(MODELS),
    "${KICAD10_3DMODEL_DIR}": str(KICAD_3DMODEL_DIR),
    "${KISYS3DMOD}": str(KICAD_3DMODEL_DIR),
    "${KICAD_ECO_ROOT}": str(REPO),
}

# Explicit, reviewed corrections where no automatic rule can be safe.
# Every entry was verified: pin count of the symbol matches the pad count.
MANUAL_FOOTPRINTS = {
    ("RECOM.kicad_sym", "RAC05-05SK"): "PERSONAL_Recom:RAC05",
    ("E-Switch.kicad_sym", "JS1400"): "PERSONAL_E-Switch:JS1400BVQ",
    (
        "Texas Instruments.kicad_sym",
        "TPS22965",
    ): "Package_SON:Texas_DSG0008A_WSON-8-1EP_2x2mm_P0.5mm_EP0.9x1.6mm_ThermalVias",
}

# Footprints whose 3D path points at a file with a different name although the
# package is identical (verified by package size and body description).
MANUAL_MODELS = {
    "UQFN-32-1EP_5x5mm_P0.5mm_EP3.6x3.6mm":
        "${KICAD_LIBRARY}/3D/Packages/QFN-32-5x5mm_P0.5mm_EP3.6x3.6mm.stp",
}


# --------------------------------------------------------------------------- #
# io helpers (byte-preserving)
# --------------------------------------------------------------------------- #
def read_text(path: Path) -> str:
    with open(path, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def write_text(path: Path, text: str) -> None:
    raw = path.read_bytes()
    had_bom = raw.startswith(b"\xef\xbb\xbf")
    with open(path, "w", encoding="utf-8-sig" if had_bom else "utf-8", newline="") as fh:
        fh.write(text)


def normalize(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.lower())


def model_exists(value: str) -> bool:
    path = value.replace("\\", "/")
    for variable, root in MODEL_ENV.items():
        if variable in path:
            path = path.replace(variable, root.replace("\\", "/"))
    return Path(path).is_file()


# --------------------------------------------------------------------------- #
# s-expression helpers
# --------------------------------------------------------------------------- #
def top_level_symbols(text: str):
    """Yield (start, end, name) for every depth-1 symbol, any indentation."""
    matches = list(TOP_PROPERTY_RE.finditer(text))
    if not matches:
        return
    # Top level is the smallest indentation used by a symbol line in the file.
    depth = min(len(m.group(1).expandtabs(4)) for m in matches)
    starts = [
        m for m in matches if len(m.group(1).expandtabs(4)) == depth
    ]
    bounds = [m.start() for m in starts] + [len(text)]
    for i, match in enumerate(starts):
        yield bounds[i], bounds[i + 1], match.group(2)


def string_mask(text: str) -> bytearray:
    """Mark every character that sits *inside* an s-expression string.

    Handles escaped quotes (``\"``) which a naive quote-count cannot, and which
    do occur inside ``descr`` properties.
    """
    mask = bytearray(len(text))
    in_string = False
    escaped = False
    for index, char in enumerate(text):
        if in_string:
            mask[index] = 1
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                mask[index] = 0
                in_string = False
        elif char == '"':
            mask[index] = 1
            in_string = True
    return mask


def iter_nodes(text: str, token: str):
    """Yield (start, end) of top-level ``(token ...)`` s-expression nodes."""
    needle = "(" + token
    mask = string_mask(text)
    i = 0
    while True:
        i = text.find(needle, i)
        if i < 0:
            return
        # must be a complete token, and not inside a string
        if mask[i]:
            i += 1
            continue
        after = i + len(needle)
        if after < len(text) and text[after] not in ' \t\r\n"(':
            i += 1
            continue
        depth = 0
        in_string = False
        escaped = False
        j = i
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
            return
        yield i, j
        i = j


def block_start_with_whitespace(text: str, start: int, floor: int) -> int:
    """Extend a node start backwards over indentation and its line break."""
    k = start
    while k > floor and text[k - 1] in " \t":
        k -= 1
    if k > floor and text[k - 1] in "\r\n":
        line = text.rfind("\n", floor, k) + 1
        if text[line:k].strip() == "":
            k = line
    return k


# --------------------------------------------------------------------------- #
# library index
# --------------------------------------------------------------------------- #
def read_lib_table(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    out: dict[str, str] = {}
    for nick, typ, uri in LIB_ENTRY_RE.findall(read_text(path)):
        if typ == "Table":
            continue
        out[nick] = uri
    return out


def expand_uri(uri: str) -> Path:
    value = (
        uri.replace("${KICAD_ECO_ROOT}", str(REPO))
        .replace("${KICAD10_FOOTPRINT_DIR}", str(KICAD_FOOTPRINT_DIR))
        .replace("${KICAD_FOOTPRINT_DIR}", str(KICAD_FOOTPRINT_DIR))
        .replace("\\", "/")
    )
    return Path(value)


def build_footprint_index() -> dict[str, set[str]]:
    """nickname -> footprint names, from every table that can be resolved."""
    sources: list[dict[str, str]] = []
    if INSTALLED_FP_TABLE.is_file():
        sources.append(read_lib_table(INSTALLED_FP_TABLE))
    for name in ("fp-lib-table.FULL", "fp-lib-table.CUSTOM_ONLY"):
        sources.append(read_lib_table(TABLES / name))

    libs: dict[str, set[str]] = {}
    for table in sources:
        for nick, uri in table.items():
            directory = expand_uri(uri)
            if not directory.is_dir():
                continue
            libs.setdefault(nick, set()).update(
                f.name[: -len(".kicad_mod")]
                for f in directory.iterdir()
                if f.name.endswith(".kicad_mod")
            )
    return libs


def build_name_index(libs: dict[str, set[str]]):
    exact: dict[str, list[str]] = defaultdict(list)
    normalized: dict[str, list[str]] = defaultdict(list)
    for nick, names in libs.items():
        for name in names:
            exact[name].append(nick)
            normalized[normalize(name)].append(nick)
    return exact, normalized


def build_model_index():
    """normalized stem -> (kind, relative path) for both model roots."""
    official: dict[str, str] = {}
    if KICAD_3DMODEL_DIR.is_dir():
        for path in KICAD_3DMODEL_DIR.rglob("*"):
            if path.suffix.lower() in MODEL_EXTS:
                official.setdefault(normalize(path.stem), f"${{KICAD10_3DMODEL_DIR}}/{path.relative_to(KICAD_3DMODEL_DIR).as_posix()}")
    local: dict[str, str] = {}
    if MODELS.is_dir():
        for path in MODELS.rglob("*"):
            if path.suffix.lower() in MODEL_EXTS:
                local.setdefault(normalize(path.stem), f"${{KICAD_LIBRARY}}/{path.relative_to(MODELS).as_posix()}")
    return official, local


# --------------------------------------------------------------------------- #
# component master
# --------------------------------------------------------------------------- #
def load_master() -> dict[str, str]:
    if not MASTER_CSV.is_file():
        return {}
    with open(MASTER_CSV, encoding="utf-8-sig", newline="") as fh:
        return {row["symbol"]: row["footprint"] for row in csv.DictReader(fh) if row.get("symbol")}


# --------------------------------------------------------------------------- #
# footprint resolution
# --------------------------------------------------------------------------- #
def pick(nicknames: list[str], preferred_prefix: str | None = None) -> str | None:
    """Return the most appropriate nickname, or None when ambiguous."""
    unique = sorted(set(nicknames))
    if not unique:
        return None
    if len(unique) == 1:
        return unique[0]
    if preferred_prefix:
        preferred = [n for n in unique if n.startswith(preferred_prefix)]
        if len(preferred) == 1:
            return preferred[0]
    return None


def resolve_footprint(
    value: str,
    libs: dict[str, set[str]],
    exact: dict[str, list[str]],
    normalized: dict[str, list[str]],
) -> tuple[str, str]:
    """Return (new_value, status).  Status is OK when nothing has to change."""
    text = value.strip()
    if not text:
        return "", "EMPTY"
    if URL_RE.match(text):
        return "", "CLEARED_URL"

    if ":" in text:
        nick, fp = text.split(":", 1)
    else:
        nick, fp = "", text

    if nick and nick in libs and fp in libs[nick]:
        return value, "OK"

    # nickname simply renamed with the PERSONAL_ prefix
    if nick:
        candidate = f"PERSONAL_{nick}"
        if candidate in libs and fp in libs[candidate]:
            return f"{candidate}:{fp}", "RENAMED_NICK"

    # the footprint itself exists somewhere -> point at a personal lib if we can
    if fp:
        target = pick(exact.get(fp, []), preferred_prefix="PERSONAL_")
        if target:
            return f"{target}:{fp}", "RESOLVED_NAME"
        target = pick(normalized.get(normalize(fp), []), preferred_prefix="PERSONAL_")
        if target:
            actual = next(
                name for name in libs[target] if normalize(name) == normalize(fp)
            )
            return f"{target}:{actual}", "RESOLVED_NORMALIZED"

    return "", "CLEARED_UNRESOLVED"


def fix_symbol_libraries(
    libs, exact, normalized, master
) -> tuple[dict[Path, str], list[list[str]], Counter]:
    plans: dict[Path, str] = {}
    report: list[list[str]] = []
    stats: Counter = Counter()

    for path in sorted(SYMBOLS.rglob("*.kicad_sym")):
        text = read_text(path)
        edits: list[tuple[int, int, str]] = []
        is_antmicro = path.parent == SYMBOLS and path.name.startswith("Antmicro_")

        for start, end, name in top_level_symbols(text):
            block = text[start:end]
            match = FP_PROPERTY_RE.search(block)
            if not match:
                continue
            value = match.group(2)
            new_value = value
            status = "OK"

            if is_antmicro:
                mapped = master.get(name, "").strip()
                if "template" in name.lower():
                    # Abstract template symbol: the generator left a concrete
                    # part's footprint behind.  A copy of that part exists in
                    # the derived symbols, so the placeholder is dropped.
                    if value.strip():
                        new_value, status = "", "TEMPLATE_CLEARED"
                elif mapped and mapped in libs.get(HW_NICK, set()):
                    new_value, status = f"{HW_NICK}:{mapped}", "FIXED_DB"
                else:
                    bracket = BRACKET_RE.match(value)
                    inner = bracket.group(1) if bracket else ""
                    if inner and inner in libs.get(HW_NICK, set()):
                        new_value, status = f"{HW_NICK}:{inner}", "UNWRAPPED"
                    elif value.strip():
                        new_value, status = "", "CLEARED_NO_FOOTPRINT"
                        if mapped:
                            status = "CLEARED_DB_FOOTPRINT_ABSENT"
            else:
                if match.group(2).strip():
                    manual = MANUAL_FOOTPRINTS.get((path.name, name))
                    if manual and manual.split(":", 1)[0] in libs and manual.split(":", 1)[1] in libs[manual.split(":", 1)[0]]:
                        new_value, status = manual, "FIXED_MANUAL"
                    else:
                        new_value, status = resolve_footprint(value, libs, exact, normalized)

            stats[status] += 1
            if new_value == value:
                stats[status] -= 1
                stats["unchanged"] += 1
                continue

            offset = match.start(2)
            edits.append((start + offset, start + match.end(2), new_value))
            report.append(
                [
                    str(path.relative_to(REPO)).replace("\\", "/"),
                    name,
                    value,
                    new_value,
                    status,
                ]
            )

        if edits:
            new_text = text
            for s, e, v in sorted(edits, key=lambda item: -item[0]):
                new_text = new_text[:s] + v + new_text[e:]
            plans[path] = new_text

    return plans, report, stats


# --------------------------------------------------------------------------- #
# 3D model repair
# --------------------------------------------------------------------------- #
def repair_models(text: str, source_nick: str, official, local):
    """Return (new_text, changes) where changes is a list of (old, new, status)."""
    changes: list[tuple[str, str, str]] = []
    edits: list[tuple[int, int, str]] = []

    prefer = local if source_nick.startswith("PERSONAL_") else official
    other = official if prefer is local else local

    fp_name = re.search(r'\(footprint "([^"]*)"', text)
    fp_key = normalize(fp_name.group(1)) if fp_name else ""
    manual_model = MANUAL_MODELS.get(fp_name.group(1)) if fp_name else None

    for start, end in iter_nodes(text, "model"):
        node = text[start:end]
        match = re.match(r'\(model "([^"]*)"', node)
        if not match:
            continue
        value = match.group(1)
        stripped = value.strip()
        is_path = "${" in stripped or bool(re.match(r"^[A-Za-z]:[\\/]", stripped))

        if stripped and stripped not in ("/", "\\", "s", ".") and is_path:
            if model_exists(stripped):
                continue
            # A real path whose file is missing: try the reviewed override,
            # then a relink by name.
            key = normalize(Path(stripped.replace("\\", "/")).stem)
            target = manual_model or prefer.get(key) or other.get(key)
            if not target and fp_key:
                target = prefer.get(fp_key) or other.get(fp_key)
            if not target:
                continue  # keep the path; validate_library.py reports it
        elif stripped:
            key = normalize(Path(stripped.replace("\\", "/")).stem)
            target = prefer.get(key) or other.get(key)
            if not target and fp_key:
                target = prefer.get(fp_key) or other.get(fp_key)
        else:
            target = prefer.get(fp_key) or other.get(fp_key) if fp_key else None

        if target:
            # Replace only the string argument; formatting stays byte-identical.
            string_start = start + match.start(1)
            string_end = start + match.end(1)
            edits.append((string_start, string_end, target))
            changes.append((value, target, "RELINKED"))
        else:
            begin = block_start_with_whitespace(text, start, 0)
            edits.append((begin, end, ""))
            changes.append((value, "", "REMOVED"))

    if not edits:
        return text, changes

    new_text = text
    for s, e, v in sorted(edits, key=lambda item: -item[0]):
        new_text = new_text[:s] + v + new_text[e:]
    return new_text, changes


def fix_footprints(official, local):
    plans: dict[Path, str] = {}
    report: list[list[str]] = []
    stats: Counter = Counter()

    for base, _dirs, files in os.walk(FOOTPRINTS):
        if not base.endswith(".pretty"):
            continue
        nickname = Path(base).name[: -len(".pretty")]
        parent = Path(base).parent.name
        if parent == "Personal":
            nickname = f"PERSONAL_{nickname}"
        for name in sorted(files):
            if not name.endswith(".kicad_mod"):
                continue
            path = Path(base) / name
            text = read_text(path)
            if "(model " not in text:
                continue
            new_text, changes = repair_models(text, nickname, official, local)
            if new_text == text:
                continue
            plans[path] = new_text
            for old, new, status in changes:
                stats[status] += 1
                report.append(
                    [
                        str(path.relative_to(REPO)).replace("\\", "/"),
                        "",
                        old,
                        new,
                        status,
                    ]
                )
    return plans, report, stats


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--apply", action="store_true", help="write the changes")
    parser.add_argument(
        "--report",
        default="",
        help="write a CSV report here (default: Database/finalize-report-<stamp>.csv)",
    )
    parser.add_argument(
        "--no-backup", action="store_true", help="do not copy files before rewriting"
    )
    args = parser.parse_args()

    if not SYMBOLS.is_dir():
        print(f"ERROR: symbol folder not found: {SYMBOLS}")
        return 2

    master = load_master()
    libs = build_footprint_index()
    exact, normalized = build_name_index(libs)
    official_models, local_models = build_model_index()

    print(f"symbol files      : {len(list(SYMBOLS.rglob('*.kicad_sym')))}")
    print(f"footprint files   : {len(list(FOOTPRINTS.rglob('*.kicad_mod')))}")
    print(f"footprint libs    : {len(libs)}")
    print(f"master rows       : {len(master)}")
    print(f"official 3D models: {len(official_models)}")
    print(f"local 3D models   : {len(local_models)}")
    print()

    sym_plans, sym_report, sym_stats = fix_symbol_libraries(
        libs, exact, normalized, master
    )
    fp_plans, fp_report, fp_stats = fix_footprints(official_models, local_models)
    plans = dict(sym_plans)
    plans.update(fp_plans)

    print("Footprint properties")
    for key, count in sorted(sym_stats.items()):
        print(f"  {key:<34} {count}")
    print("3D model blocks")
    for key, count in sorted(fp_stats.items()):
        print(f"  {key:<34} {count}")
    print()
    print(f"values changed    : {len(sym_report)}")
    print(f"model blocks fixed: {len(fp_report)}")
    print(f"files to rewrite  : {len(plans)}")

    if sym_report:
        print("\n-- sample footprint changes")
        for row in sym_report[:15]:
            print("   ", " | ".join(row))
    if fp_report:
        print("\n-- sample 3D changes")
        for row in fp_report[:10]:
            print("   ", " | ".join(row))

    report_path = Path(args.report) if args.report else (
        REPO / "Database" / f"finalize-report-{datetime.now():%Y%m%d-%H%M%S}.csv"
    )
    if args.apply:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        with open(report_path, "w", encoding="utf-8-sig", newline="") as fh:
            writer = csv.writer(fh)
            writer.writerow(["file", "symbol", "old_value", "new_value", "status"])
            writer.writerows(sym_report + fp_report)
        print(f"\nreport            : {report_path.relative_to(REPO)}")

    if not args.apply:
        print("\nDRY RUN - nothing written. Re-run with --apply to rewrite files.")
        return 0

    if not args.no_backup:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_root = (
            Path(os.environ.get("LOCALAPPDATA", REPO))
            / "KiCad Library Kien Hoang"
            / "Backups"
            / f"finalize-{stamp}"
        )
        for path in plans:
            try:
                rel = path.relative_to(REPO)
            except ValueError:
                rel = Path(path.name)
            dest = backup_root / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest)
        print(f"backup            : {backup_root}")

    for path, text in plans.items():
        write_text(path, text)

    print(f"rewritten         : {len(plans)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
