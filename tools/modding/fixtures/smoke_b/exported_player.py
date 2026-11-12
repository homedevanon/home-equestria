#!/usr/bin/env python3
"""The game's player/desktop_player.gd as an exported game holds it (binary tokens, x.gdc behind
x.gd.remap), for the Sit Anywhere check of tools/modding/test_bundled_smoke_b.gd (--exported-player).

Only Godot's exporter writes binary tokens. This copies the current desktop_player.gd into a tiny
project that the same Godot 4.5 exports as a pack with script_export_mode=2, then takes the .gdc out:

    python3 -I exported_player.py prepare <empty scratch dir> <public project dir>
    run_owned_godot.py --project <scratch dir> --export-preset Linux --export-pack --export-output <scratch dir>/out.pck
    python3 -I exported_player.py collect <scratch dir>/out.pck <out .gdc file>

Tokens are tied to the engine's tokenizer version and to the game file's text: make them again
whenever either changes. Nothing here runs or mounts anything; it reads and writes bytes only.
"""
import pathlib
import shutil
import struct
import sys

SCRIPT = "player/desktop_player.gd"
PROJECT = """config_version=5

[application]

config/name="exported player fixture"
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


def prepare(folder, game):
    folder = pathlib.Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "project.godot").write_text(PROJECT)
    (folder / "export_presets.cfg").write_text(PRESETS)
    target = folder / SCRIPT
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(pathlib.Path(game) / SCRIPT, target)
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


def collect(pack, out):
    files = pack_files(pack)
    tokens = SCRIPT[:-3] + ".gdc"
    if tokens not in files:
        raise SystemExit("no %s in the pack (was it exported with binary tokens?)" % tokens)
    pathlib.Path(out).write_bytes(files[tokens])
    print("wrote", out, len(files[tokens]), "bytes")


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("prepare", "collect"):
        raise SystemExit(__doc__)
    (prepare if sys.argv[1] == "prepare" else collect)(sys.argv[2], sys.argv[3])
