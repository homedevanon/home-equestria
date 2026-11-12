#!/usr/bin/env python3
"""Bundled-pack staging folders for tools/modding/test_bundled_smoke_a.gd (W2-BUNDLE-SMOKE-A).

    python3 -I tools/modding/fixtures/smoke_a/make_fixture.py <private root> <out dir>

Reads the staged bundled mods (<private root>/bundled_mods/bundled_mods.json and the packs beside
it), adds the devanon patch packs found in <private root>/bundled_mods/<folder>/ (one .pck whose
mod.json declares "patches"; listed right after their parent, default_on like it) and writes one
folder per smoke case under <out dir>, each with its own bundled_mods.json and symbolic links to
the real packs (nothing is copied, nothing is mounted or run here):
    none                  no bundled mods (the baseline boot)
    <id>                  only that pack of set A, plus its patch packs
    all                   every staged pack and every patch pack, default switches as shipped
Prints SMOKE_FIXTURE <case> <dir> <ids> for each case. Packs are parsed as bytes only
(tools/bundled_mods/pckread.py); the authors' packs are never opened by anything else here.
"""
import hashlib, importlib.util, json, os, sys
from pathlib import Path

NOT_BUNDLED = {"pony_dances_patch"}
SET_A = ["grooming", "flowing_manes", "idle_life", "balloon_boarding", "teleport", "princess_teleport", "pin_the_tail"]


def load_pckread(root):
    spec = importlib.util.spec_from_file_location("pckread", root / "tools/bundled_mods/pckread.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def patch_rows(root, rows, pck):
    """Patch packs staged in bundled_mods/<folder>/ that stage.py has not listed yet."""
    listed = {row["file"] for row in rows}
    found = []
    for folder in sorted((root / "bundled_mods").iterdir()):
        # Built but not bundled (dev: Pony Dances ships as-is); stage.py lists every bundled patch.
        if not folder.is_dir() or folder.name in NOT_BUNDLED:
            continue
        packs = sorted(folder.glob("*.pck"))
        if len(packs) != 1 or packs[0].name in listed:
            continue
        data = packs[0].read_bytes()
        try:
            mods = pck.mods(data)
        except pck.PackError:
            continue
        for mod_id, manifest in mods.items():
            patches = manifest.get("patches") if isinstance(manifest, dict) else None
            if not isinstance(patches, dict) or not patches:
                continue
            found.append({"id": mod_id, "title": str(manifest.get("name", mod_id)), "author": "devanon",
                          "version": str(manifest.get("version", "")), "file": packs[0].name,
                          "sha256": hashlib.sha256(data).hexdigest(), "source_url": "",
                          "patches": {str(k): str(v) for k, v in patches.items()}, "_path": str(packs[0])})
    return found


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__)
    root, out = Path(argv[1]).resolve(), Path(argv[2]).resolve()
    pck = load_pckread(root)
    index = json.loads((root / "bundled_mods/bundled_mods.json").read_text(encoding="utf-8"))
    rows = []
    for row in index["mods"]:
        found = [p for p in (root / "bundled_mods").glob(f"*/{row['file']}") if p.is_file()]
        if len(found) != 1:
            sys.exit(f"smoke fixture: {row['file']} is not staged exactly once")
        rows.append(dict(row, _path=str(found[0])))
    by_id = {row["id"]: row for row in rows}
    for patch in patch_rows(root, rows, pck):
        parent = next(iter(patch["patches"]))
        if parent not in by_id:
            continue
        patch["default_on"] = by_id[parent].get("default_on", True)
        patch["order"] = int(by_id[parent].get("order", 0)) + 1
        rows.append(patch)
    cases = {"none": [], "all": rows}
    for mod_id in SET_A:
        cases[mod_id] = [r for r in rows if r["id"] == mod_id or mod_id in r.get("patches", {})]
    for case, chosen in cases.items():
        folder = out / case
        folder.mkdir(parents=True, exist_ok=True)
        clean = []
        for row in chosen:
            link = folder / row["file"]
            if link.is_symlink() or link.exists():
                # Never deleted (house rule): an out-of-date link needs a fresh <out dir>.
                if os.path.realpath(link) != os.path.realpath(row["_path"]):
                    sys.exit(f"smoke fixture: {link} points elsewhere; use a fresh out dir")
            else:
                os.symlink(row["_path"], link)
            clean.append({k: v for k, v in row.items() if not k.startswith("_")})
        (folder / "bundled_mods.json").write_text(json.dumps({"format": 1, "mods": clean}, indent="\t") + "\n", encoding="utf-8")
        print(f"SMOKE_FIXTURE {case} {folder} {','.join(r['id'] for r in chosen if r.get('default_on', True))}")


if __name__ == "__main__":
    main(sys.argv)
