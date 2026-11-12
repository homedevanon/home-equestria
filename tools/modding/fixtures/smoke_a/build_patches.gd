extends SceneTree
## Builds the devanon patch packs of bundled set A (W2-BUNDLE-SMOKE-A) from their sources:
## <patch root>/<name>/src/<path> goes into <patch root>/<name>/<name>.pck at res://<path>, files
## sorted, nothing else added (no README, no .uid; the patch's mod.json carries "patches"). The
## authors' packs are not read or touched. From the private root:
##   python3 tools/run_owned_godot.py --project home-equestria-public --wait-for-slot 1800 \
##     --expect SMOKE_A_PATCHES_BUILT --log LOG --arg=--patch-root=<private root>/bundled_mods \
##     --arg=--patches=idle_life_patch,princess_teleport_patch,flowing_manes_patch \
##     res://tools/modding/fixtures/smoke_a/build_patches.gd
## Prints the sha256 of each pack built.

func _initialize() -> void:
	var root := ""
	var names := PackedStringArray()
	for item: String in OS.get_cmdline_user_args():
		if item.begins_with("--patch-root="): root = item.substr(13)
		if item.begins_with("--patches="): names = item.substr(10).split(",", false)
	if root.is_empty() or names.is_empty():
		printerr("build_patches: needs --patch-root=<dir> and --patches=<a,b>"); quit(2); return
	var built := 0
	for name: String in names:
		var src := root.path_join(name).path_join("src")
		var files := _files(src)
		files.sort()
		if files.is_empty() or not FileAccess.file_exists(src.path_join("mods").path_join(name).path_join("mod.json")):
			printerr("build_patches: %s has no src/mods/%s/mod.json" % [name, name]); continue
		var out := root.path_join(name).path_join(name + ".pck")
		var packer := PCKPacker.new()
		if packer.pck_start(out) != OK: printerr("build_patches: cannot write ", out); continue
		for file: String in files:
			packer.add_file("res://" + file.trim_prefix(src + "/"), file)
		if packer.flush() != OK: printerr("build_patches: flush failed for ", out); continue
		built += 1
		print("[build_patches] %s: %d files, sha256 %s" % [out, files.size(), FileAccess.get_sha256(out)])
	print("SMOKE_A_PATCHES_BUILT ", built, "/", names.size())
	quit(0 if built == names.size() else 1)


func _files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for name: String in DirAccess.get_files_at(dir):
		if not name.begins_with("."): out.append(dir.path_join(name))
	for sub: String in DirAccess.get_directories_at(dir):
		out.append_array(_files(dir.path_join(sub)))
	return out
