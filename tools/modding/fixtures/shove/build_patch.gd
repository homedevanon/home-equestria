extends SceneTree
## Builds devanon's patch pack "shove_improvements" (patch for Anon's Tease & Discomfort Shove,
## W2-SHOVE-PATCH / M-MOD-12) from its source folder in the private root. Every file under the
## source folder goes into the pack at res://<path below the folder>, as text (the loader's
## "extends" needs the patch script's source). Prints SHOVE_PATCH_BUILT <path> <sha256>.
##   python3 tools/run_owned_godot.py --project home-equestria-public --wait-for-slot 1800 \
##       --expect SHOVE_PATCH_BUILT --log LOG res://tools/modding/fixtures/shove/build_patch.gd
## Defaults: ../bundled_mods/shove_improvements/src -> ../bundled_mods/shove_improvements/
## shove_improvements.pck (relative to the public project); `--src DIR` and `--out FILE` change them.
## Afterwards `python3 -I tools/bundled_mods/stage.py` lists it in bundled_mods.json.

func _initialize() -> void: run.call_deferred()

static func default_src() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../bundled_mods/shove_improvements/src").simplify_path()

static func default_out() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../bundled_mods/shove_improvements/shove_improvements.pck").simplify_path()

static func arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback

func run() -> void:
	var out := arg("--out", default_out())
	var result := build(arg("--src", default_src()), out)
	if not result.is_empty():
		printerr("SHOVE_PATCH_FAILED ", result); quit(1); return
	print("SHOVE_PATCH_BUILT %s %s" % [out, FileAccess.get_sha256(out)])
	quit(0)

## Writes the pack; "" when it worked, else why not.
static func build(src: String, out: String) -> String:
	var files := PackedStringArray()
	_collect(src, "", files)
	files.sort()
	if not files.has("mods/shove_improvements/mod.json"): return "no mods/shove_improvements/mod.json under %s" % src
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var packer := PCKPacker.new()
	if packer.pck_start(out) != OK: return "cannot write %s" % out
	for path: String in files:
		if packer.add_file("res://" + path, src.path_join(path)) != OK: return "cannot add %s" % path
	if packer.flush() != OK: return "cannot finish %s" % out
	print("[shove_patch] %d files: %s" % [files.size(), ", ".join(files)])
	return ""

static func _collect(root: String, sub: String, out: PackedStringArray) -> void:
	var dir := root.path_join(sub)
	for file: String in DirAccess.get_files_at(dir):
		if file.begins_with(".") or file.ends_with(".uid"): continue
		out.append(sub.path_join(file) if not sub.is_empty() else file)
	for folder: String in DirAccess.get_directories_at(dir):
		if not folder.begins_with("."): _collect(root, sub.path_join(folder) if not sub.is_empty() else folder, out)
