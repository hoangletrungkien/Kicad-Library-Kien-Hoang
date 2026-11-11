# Legacy scripts (archived)

These scripts produced the 2026-11 cleanup pass and are kept for reference
only. They are **superseded** and must not be run again: the current library
state already includes their output, and re-running them can point values
back at paths that no longer exist.

| Script | Superseded by | Why it is unsafe now |
|---|---|---|
| `repair_footprints.py` | `../finalize_library.py` | One-shot Antmicro repair; hard-codes the old `${KICAD_LIBRARY}` root and rewrites whole `(model ...)` nodes, which re-indents them. |
| `fix_library_issues.py` | `../finalize_library.py` | Only matches tab-indented top-level symbols, so 11 space-indented libraries are skipped silently. Reads the *installed* `fp-lib-table` from `%APPDATA%`, so results depend on machine state. |
| `_check_3d.py`, `_check_fp_links.py`, `_check_symbols.py`, `_inspect_personal.py`, `_lookup.py` | `../validate_library.py` | Ad-hoc debug snippets with hard-coded `C:\Users\kien\...` paths and no CLI. |

Use instead:

```bash
python Tools/python/validate_library.py     # read-only audit, exit 0 = clean
python Tools/python/finalize_library.py     # dry run of the normalizer
```
