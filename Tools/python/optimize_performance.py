#!/usr/bin/env python3
"""KiCad RAM and Performance Optimizer (Python runner).

Optimizations applied:
  1. kicad_advanced:
     - Skip3DModelMemoryCache=1 (Prevents KiCad from permanently caching 3D models in RAM)
     - Skip3DModelFileCache=1
     - Debug overhead disabled (RouterDebugGraphics, BoundingBoxes, ZoneFiller, etc.)
  2. eeschema.json:
     - appearance.footprint_preview = False (Prevents freezing/RAM spikes in symbol chooser)
  3. pcbnew.json:
     - pcb_display.live_3d_refresh = False (Prevents continuous 3D recalculation during layout)
  4. 3d_viewer.json:
     - render.opengl_render_bbox_only_OnMove = True (Smooth 60 FPS 3D orbit/pan)
     - render.raytrace_anti_aliasing = False
     - render.raytrace_procedural_textures = False
  5. kicad_common.json:
     - system.clear_3d_cache_interval = 1 (Daily purge of 3D disk/RAM cache)
  6. fp-lib-table:
     - Disables uncompiled recursive folders if present
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from datetime import datetime
from pathlib import Path


def get_kicad_config_dir(version: str | None = None) -> Path:
    if os.environ.get("KICAD_CONFIG_HOME"):
        base = Path(os.environ["KICAD_CONFIG_HOME"])
    elif os.environ.get("APPDATA"):
        base = Path(os.environ["APPDATA"]) / "kicad"
    else:
        base = Path.home() / ".config" / "kicad"

    if version:
        target = base / version
        if not target.is_dir():
            raise FileNotFoundError(f"KiCad {version} config folder not found at: {target}")
        return target

    # Auto-detect highest available slot
    slots = []
    if base.is_dir():
        for entry in base.iterdir():
            if entry.is_dir() and re.match(r"^\d+\.\d+$", entry.name):
                try:
                    slots.append((tuple(map(int, entry.name.split("."))), entry))
                except ValueError:
                    pass
    if not slots:
        raise FileNotFoundError(f"No KiCad configuration directories found in {base}")

    slots.sort(key=lambda s: s[0], reverse=True)
    return slots[0][1]


def optimize_json(file_path: Path, updates: dict[str, any], dry_run: bool = False) -> bool:
    data = {}
    if file_path.is_file():
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:
            print(f"  [WARN] Failed to read {file_path.name}: {e}")
            return False

    changed = False
    for dot_path, val in updates.items():
        tokens = dot_path.split(".")
        curr = data
        for token in tokens[:-1]:
            if token not in curr or not isinstance(curr[token], dict):
                curr[token] = {}
            curr = curr[token]
        leaf = tokens[-1]
        if curr.get(leaf) != val:
            curr[leaf] = val
            changed = True

    if changed:
        if dry_run:
            print(f"  -> [DRY RUN] Would update {file_path.name}: {list(updates.keys())}")
        else:
            with open(file_path, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
            print(f"  [OK]   Updated {file_path.name}: {list(updates.keys())}")
        return True
    else:
        print(f"         {file_path.name}: already optimized.")
        return False


def optimize_advanced(config_dir: Path, dry_run: bool = False) -> bool:
    adv_file = config_dir / "kicad_advanced"
    flags = {
        "Skip3DModelMemoryCache": "1",
        "Skip3DModelFileCache": "1",
        "MaximumThreads": "4",
        "EnableCacheFriendlyFracture": "1",
        "MaxFileSystemWatchers": "32",
        "ImportSkipComponentBodies": "1",
        "ShowRouterDebugGraphics": "0",
        "DrawBoundingBoxes": "0",
        "ShowEventCounters": "0",
        "DebugZoneFiller": "0",
        "DebugPDFWriter": "0",
        "ShowPcbnewExportNetlist": "0",
        "HotkeysDumper": "0",
    }

    current = {}
    if adv_file.is_file():
        for line in adv_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                current[k.strip()] = v.strip()

    changed = False
    for k, v in flags.items():
        if current.get(k) != v:
            current[k] = v
            changed = True

    if changed or not adv_file.is_file():
        if dry_run:
            print("  -> [DRY RUN] Would update kicad_advanced with memory cache & debug flags.")
        else:
            lines = [f"{k}={v}" for k, v in current.items()]
            adv_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
            print("  [OK]   kicad_advanced: RAM cache skipping enabled, debug flags disabled.")
        return True
    else:
        print("         kicad_advanced: already optimized.")
        return False


def optimize_tables(config_dir: Path, dry_run: bool = False) -> int:
    changes = 0

    # 1. sym-lib-table deduplication
    sym_path = config_dir / "sym-lib-table"
    if sym_path.is_file():
        sym_text = sym_path.read_text(encoding="utf-8")
        has_individual_sym = '(name "4xxx")' in sym_text
        has_active_table_sym = bool(re.search(r'\(lib\s+\(name\s+"KiCad"\)\s+\(type\s+"Table"\)(?:(?!\(disabled\)).)*?\)', sym_text, re.DOTALL))
        if has_individual_sym and has_active_table_sym:
            sym_new = re.sub(r'(\(lib\s+\(name\s+"KiCad"\)\s+\(type\s+"Table"\)[^\)]*)\)', r'\1 (disabled))', sym_text)
            if sym_new != sym_text:
                if dry_run:
                    print("  -> [DRY RUN] Would disable duplicate 'KiCad' Table in sym-lib-table (saves 223 libraries double-loading).")
                else:
                    sym_path.write_text(sym_new, encoding="utf-8")
                    print("  [OK]   sym-lib-table: Disabled duplicate 'KiCad' Table entry (prevents double-loading 223 official symbol libraries).")
                changes += 1

    # 2. fp-lib-table deduplication & check
    fp_path = config_dir / "fp-lib-table"
    if fp_path.is_file():
        fp_text = fp_path.read_text(encoding="utf-8")
        has_individual_fp = '(name "Capacitor_SMD")' in fp_text
        has_active_table_fp = bool(re.search(r'\(lib\s+\(name\s+"KiCad"\)\s+\(type\s+"Table"\)(?:(?!\(disabled\)).)*?\)', fp_text, re.DOTALL))
        if has_individual_fp and has_active_table_fp:
            fp_new = re.sub(r'(\(lib\s+\(name\s+"KiCad"\)\s+\(type\s+"Table"\)[^\)]*)\)', r'\1 (disabled))', fp_text)
            if fp_new != fp_text:
                if dry_run:
                    print("  -> [DRY RUN] Would disable duplicate 'KiCad' Table in fp-lib-table (saves 155 libraries double-loading).")
                else:
                    fp_path.write_text(fp_new, encoding="utf-8")
                    print("  [OK]   fp-lib-table: Disabled duplicate 'KiCad' Table entry (prevents double-loading 155 official footprint libraries).")
                changes += 1
                fp_text = fp_new

        # Check for uncompiled recursive kicad-footprints
        if "hardware-components-main" in fp_text and "kicad-footprints" in fp_text:
            if not re.search(r'\(lib\s+\(name\s+"kicad-footprints"\).*?\(disabled\).*?\)', fp_text, re.DOTALL):
                new_text = re.sub(r'(\(lib\s+\(name\s+"kicad-footprints"\)[^\)]*)\)', r'\1 (disabled))', fp_text)
                if new_text != fp_text:
                    if dry_run:
                        print("  -> [DRY RUN] Would disable uncompiled recursive 'kicad-footprints' library.")
                    else:
                        fp_path.write_text(new_text, encoding="utf-8")
                        print("  [OK]   fp-lib-table: Disabled uncompiled 'kicad-footprints' to prevent startup RAM crash.")
                    changes += 1

    return changes


def main() -> int:
    parser = argparse.ArgumentParser(description="KiCad RAM and Performance Optimizer")
    parser.add_argument("--version", help="KiCad version slot (e.g. 10.0, 9.0, 8.0, 7.0)")
    parser.add_argument("--dry-run", action="store_true", help="Inspect planned changes without writing files")
    args = parser.parse_args()

    print("\n============================================================")
    print("       KiCad RAM & Performance Optimizer (Python)")
    print("============================================================")

    try:
        config_dir = get_kicad_config_dir(args.version)
        print(f"  KiCad Config: {config_dir}")
        print(f"  Mode        : {'DRY RUN' if args.dry_run else 'APPLY'}\n")

        changes = 0
        if optimize_advanced(config_dir, dry_run=args.dry_run):
            changes += 1

        if optimize_json(
            config_dir / "eeschema.json",
            {
                "appearance.footprint_preview": False,
                "system.max_undo_items": 50,
            },
            dry_run=args.dry_run,
        ):
            changes += 1

        if optimize_json(
            config_dir / "pcbnew.json",
            {
                "pcb_display.live_3d_refresh": False,
                "system.max_undo_items": 50,
            },
            dry_run=args.dry_run,
        ):
            changes += 1

        if optimize_json(
            config_dir / "kicad.json",
            {
                "system.max_undo_items": 50,
            },
            dry_run=args.dry_run,
        ):
            changes += 1

        if optimize_json(
            config_dir / "3d_viewer.json",
            {
                "render.opengl_render_bbox_only_OnMove": True,
                "render.opengl_AA_mode": 0,
                "render.opengl_AA_disableOnMove": True,
                "render.raytrace_anti_aliasing": False,
                "render.raytrace_procedural_textures": False,
                "render.raytrace_post_processing": False,
                "render.raytrace_reflections": False,
                "render.raytrace_refractions": False,
                "render.raytrace_shadows": False,
                "render.opengl_copper_thickness": False,
            },
            dry_run=args.dry_run,
        ):
            changes += 1

        if optimize_json(config_dir / "kicad_common.json", {"system.clear_3d_cache_interval": 1}, dry_run=args.dry_run):
            changes += 1

        tbl_changes = optimize_tables(config_dir, dry_run=args.dry_run)
        changes += tbl_changes

        print("\n============================================================")
        print(f"  Completed: {changes} component(s) {'would be' if args.dry_run else ''} updated.")
        print("  Please restart KiCad for all changes to take effect.")
        print("============================================================\n")
        return 0

    except Exception as e:
        print(f"\n  [ERROR] {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
