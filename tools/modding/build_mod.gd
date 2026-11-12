extends SceneTree
## Packs one mod, res://mods/<id>/, into a standalone .pck players drop into their mods folder.
## Run from a copy of the game's source project with the same Godot 4.5 build, after the editor has
## imported the mod's assets once (`godot --headless --editor --quit`):
##   godot --headless --xr-mode off --path <project> --script res://tools/modding/build_mod.gd -- <id> [--out FILE.pck]
## Default output is user://mods/<id>.pck, which is the game's own mods folder, so the next launch
## runs it. Imported assets (textures, models, sounds) go in as the game exports them: the .import
## file plus its .godot/imported data, not the source file. Text scenes and resources (.tscn, .tres)
## go in without the uid="uid://..." of their [ext_resource] lines: the players' game does not know
## a mod's UIDs and would log "invalid UID ... using text path instead" for each (M-MOD-04); the path
## is what loads either way. Prints MOD_BUILT <path> or MOD_BUILD_FAILED.
const LOADER := preload("res://world/modding/mod_loader.gd")

func _initialize() -> void: run.call_deferred()

func run() -> void:
	var args := OS.get_cmdline_user_args()
	var id := args[0] if not args.is_empty() else ""
	var out := LOADER.USER_DIR.path_join(id + ".pck")
	var at := args.find("--out")
	if at >= 0 and at + 1 < args.size(): out = args[at + 1]
	var result := build(id, out)
	if result.begins_with("ERROR"):
		printerr("MOD_BUILD_FAILED ", result); quit(1); return
	print("MOD_BUILT ", result)
	quit(0)

## A text scene or resource with the uid="uid://..." attributes of its [ext_resource] lines removed.
static func without_uids(text: String) -> String:
	return RegEx.create_from_string("(?m)^(\\[ext_resource[^\\n]*?) uid=\"uid://[^\"]*\"").sub(text, "$1", true)

## Writes the pack; returns its absolute path, or "ERROR: why".
static func build(id: String, out: String) -> String:
	var root := LOADER.MODS_ROOT.path_join(id)
	if RegEx.create_from_string(LOADER.ID_PATTERN).search(id) == null: return "ERROR: mod id must be lower-case letters, digits or _ (got \"%s\")" % id
	if not DirAccess.dir_exists_absolute(root): return "ERROR: no folder %s" % root
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(root.path_join("mod.json")))
	if not manifest is Dictionary: return "ERROR: %s/mod.json is missing or not a JSON object" % root
	var files: Dictionary = {}   # res:// path in the pack -> absolute source file
	for path: String in LOADER._files_under(root):
		if path.get_file() in [LOADER.BUILT, "README.md", "AGENTS.md"] or path.ends_with(".uid"): continue
		if path.ends_with(".import"):
			var config := ConfigFile.new()
			if config.load(path) != OK: return "ERROR: cannot read %s" % path
			files[path] = ProjectSettings.globalize_path(path)
			var dest: Variant = config.get_value("deps", "dest_files", [])
			if not dest is Array or (dest as Array).is_empty():
				if config.has_section_key("remap", "path"): dest = [config.get_value("remap", "path")]
				else: dest = []
			for imported: Variant in dest:
				if not FileAccess.file_exists(str(imported)): return "ERROR: %s is not imported yet; open the project in the Godot editor once (or run it with --headless --editor --quit)" % path.trim_suffix(".import")
				files[str(imported)] = ProjectSettings.globalize_path(str(imported))
		elif FileAccess.file_exists(path + ".import"): continue   # the import above carries it
		elif path.get_extension() in ["tscn", "tres"]:
			var plain := without_uids(FileAccess.get_file_as_string(path))
			var copy := ProjectSettings.globalize_path("user://mod_build_%s/%d.%s" % [id, files.size(), path.get_extension()])
			DirAccess.make_dir_recursive_absolute(copy.get_base_dir())
			var out_file := FileAccess.open(copy, FileAccess.WRITE)
			if out_file == null: return "ERROR: cannot write a temporary file in user://"
			out_file.store_string(plain); out_file.close()
			files[path] = copy
		else: files[path] = ProjectSettings.globalize_path(path)
	var stamp := ProjectSettings.globalize_path("user://mod_build_%s.json" % id)
	var marker := FileAccess.open(stamp, FileAccess.WRITE)
	if marker == null: return "ERROR: cannot write a temporary file in user://"
	marker.store_string(JSON.stringify({"id": id, "version": str(manifest.get("version", "")), "game_version": str(ProjectSettings.get_setting("application/config/version", "")),
		"godot": Engine.get_version_info().string}, "\t"))
	marker.close()
	files[root.path_join(LOADER.BUILT)] = stamp
	var target := ProjectSettings.globalize_path(out)
	DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	var packer := PCKPacker.new()
	if packer.pck_start(target) != OK: return "ERROR: cannot write %s" % target
	var paths := files.keys(); paths.sort()
	for path: String in paths:
		if packer.add_file(path, files[path]) != OK: return "ERROR: cannot add %s" % path
	if packer.flush() != OK: return "ERROR: cannot finish %s" % target
	print("[mods] %s: %d files" % [id, paths.size()])
	return target
