extends SceneTree
## Builds the devanon patch packs of W2-BUNDLE-SMOKE-B (2026-11-08) from their sources:
## <private root>/bundled_mods/<folder>/src/mods/<pack id>/... -> <private root>/bundled_mods/<folder>/<pack id>.pck.
## The sources are plain text (mod.json, scripts); nothing is imported. Prints PATCH_PACKS_BUILT.
##   python3 tools/run_owned_godot.py --project home-equestria-public --wait-for-slot 1800 \
##       --expect PATCH_PACKS_BUILT --log LOG res://tools/modding/fixtures/smoke_b/build_patch_packs.gd
## Options: --bundled-dir=<abs folder holding the patch folders> (default: the private root's
## bundled_mods, beside home-equestria-public), --out-dir=<abs folder> (default: each pack's own folder).
## folder -> pack id. pony_dances_patch is built but not bundled unless the dev says so (DECISIONS.md:
## Pony Dances ships as-is).
const PATCHES := {"pegasus_ride_v2_patch": "pegasus_ride_v2_patch", "watch_party_patch": "watch_party_patch", "pony_dances_patch": "dance_mod_patch", "mirror_pool_patch": "mirror_pool_patch"}

func _initialize() -> void: run.call_deferred()

func arg(prefix: String, fallback: String) -> String:
	for item: String in OS.get_cmdline_user_args():
		if item.begins_with(prefix): return item.trim_prefix(prefix)
	return fallback

static func default_bundled_dir() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join("bundled_mods")

static func files_under(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir): return out
	var names := DirAccess.get_files_at(dir); names.sort()
	for name: String in names: out.append(dir.path_join(name))
	var subs := DirAccess.get_directories_at(dir); subs.sort()
	for sub: String in subs: out.append_array(files_under(dir.path_join(sub)))
	return out

## Packs <bundled>/<folder>/src into `out`; returns its sha256, or "ERROR: why".
static func build(bundled: String, folder: String, out: String) -> String:
	var src := bundled.path_join(folder).path_join("src")
	var files := files_under(src)
	if files.is_empty(): return "ERROR: no sources in " + src
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var packer := PCKPacker.new()
	if packer.pck_start(out) != OK: return "ERROR: cannot write " + out
	for path: String in files:
		if path.get_file().begins_with(".") or path.ends_with(".uid"): continue
		packer.add_file("res://" + path.trim_prefix(src + "/"), path)
	if packer.flush() != OK: return "ERROR: flush failed for " + out
	return FileAccess.get_sha256(out)

func run() -> void:
	var bundled := arg("--bundled-dir=", default_bundled_dir())
	var out_dir := arg("--out-dir=", "")
	var failed := false
	for folder: String in PATCHES:
		var id := str(PATCHES[folder])
		var out := (out_dir if not out_dir.is_empty() else bundled.path_join(folder)).path_join(id + ".pck")
		var result := build(bundled, folder, out)
		print("[patch-packs] ", id, " ", result)
		if result.begins_with("ERROR"): failed = true
	print("PATCH_PACKS_BUILT" if not failed else "PATCH_PACKS_FAILED")
	quit(1 if failed else 0)
