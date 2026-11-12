#!/usr/bin/env python3
"""Makes the exported-script fixtures for tools/modding/test_exported_extends.gd.

An exported game keeps its scripts as binary tokens (x.gdc behind x.gd.remap); only Godot's
exporter writes those. This prepares a tiny project from the *.gd.txt sources in exported/,
which the same Godot 4.5 exports as a pack, then copies the .gdc files out of that pack:

    python3 make_exported_fixtures.py prepare <empty scratch dir>
    godot --headless --xr-mode off --path <scratch dir> --export-pack Linux <scratch dir>/out.pck
    python3 make_exported_fixtures.py collect <scratch dir>/out.pck

The .gdc files land in exported/ as *.gdc.bin (exported/ has a .gdignore, so the editor never
treats them as scripts). Binary tokens are tied to the engine's tokenizer version: regenerate
them when the game moves to another Godot version.
"""
import pathlib
import shutil
import struct
import sys

HERE = pathlib.Path(__file__).resolve().parent / "exported"
## Source text in exported/ -> its res:// path in the tiny project (and in the test's pack).
SCRIPTS = {
    "game_base.gd.txt": "tools/modding/fixtures/loader/exported/game_base.gd",
    "game_user.gd.txt": "tools/modding/fixtures/loader/exported/game_user.gd",
    "river_user.gd.txt": "tools/modding/fixtures/loader/exported/river_user.gd",
    "river_support.gd.txt": "world/water/river_support.gd",
}
PROJECT = """config_version=5

[application]

config/name="exported script fixtures"
"""
PRESETS = """[preset.0]

name="Linux"
platform="Linux"
runnable=true
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter=""
exclude_filter=""
export_path=""
encryption_include_filters=""
encryption_exclude_filters=""
seed=0
encrypt_pck=false
encrypt_directory=false
script_export_mode=2

[preset.0.options]

binary_format/embed_pck=false
binary_format/architecture="x86_64"
"""


def prepare(folder):
    folder = pathlib.Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "project.godot").write_text(PROJECT)
    (folder / "export_presets.cfg").write_text(PRESETS)
    for source, target in SCRIPTS.items():
        path = folder / target
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(HERE / source, path)
    print("prepared", folder)


def pack_files(path):
    """{res path: bytes} of a Godot 4 pack (format 2 or 3, not encrypted)."""
    data = pathlib.Path(path).read_bytes()
    if data[:4] != b"GDPC":
        raise SystemExit("not a Godot pack")
    fmt, = struct.unpack_from("<I", data, 4)
    flags, = struct.unpack_from("<I", data, 20)
    base, = struct.unpack_from("<Q", data, 24)
    if flags & 1:
        raise SystemExit("encrypted pack directory")
    at = struct.unpack_from("<Q", data, 32)[0] if fmt == 3 else 32 + 64
    count, = struct.unpack_from("<I", data, at); at += 4
    out = {}
    for _ in range(count):
        length, = struct.unpack_from("<I", data, at); at += 4
        name = data[at:at + length].split(b"\0")[0].decode(); at += length
        offset, size = struct.unpack_from("<QQ", data, at); at += 16 + 16
        at += 4
        out[name.removeprefix("res://")] = data[base + offset:base + offset + size]
    return out


def collect(pack):
    files = pack_files(pack)
    for target in SCRIPTS.values():
        tokens = target[:-3] + ".gdc"
        if tokens not in files:
            raise SystemExit("no %s in the pack (was it exported with binary tokens?)" % tokens)
        out = HERE / (pathlib.Path(target).name[:-3] + ".gdc.bin")
        out.write_bytes(files[tokens])
        print("wrote", out, len(files[tokens]), "bytes")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("prepare", "collect"):
        raise SystemExit(__doc__)
    (prepare if sys.argv[1] == "prepare" else collect)(sys.argv[2])
