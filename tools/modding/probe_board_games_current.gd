extends SceneTree
## Real-path check for LEAD_NOTES item 6 (overhaul 2026-11-08): with the REAL staged bundled folder
## (`-- --bundled-dir <private root>/bundled_mods`, the launcher's path) and board_games switched on,
## every game script MLPChag's board_games pack replaces must run the CURRENT game code (devanon's
## board_games_compat merge), not his 0.3.0 copy. For each replaced .gd: the text res:// now serves,
## whether it compiles and loads, and every function of the game's own file on disk (read past the
## packs with the absolute path) present in the mounted script. `--dump DIR` writes each mounted text
## to DIR/<res path> for a byte compare with build_compat_patch.py --tree. Isolated XDG_DATA_HOME
## (the player's mods.cfg must not switch board_games off). Prints BOARD_GAMES_CURRENT_DONE PASS|FAIL.
##   XDG_DATA_HOME=<scratch>/bg-current python3 tools/run_owned_godot.py --project home-equestria-public \
##       --wait-for-slot 1800 --expect BOARD_GAMES_CURRENT_DONE --log LOG --arg=--bundled-dir \
##       --arg=<root>/bundled_mods --arg=--dump --arg=<dir> res://tools/modding/probe_board_games_current.gd
var failures := 0
var checks := 0


func _initialize() -> void: run.call_deferred()


func check(ok: bool, text: String) -> void:
	checks += 1
	print("[bg-current] ", "PASS " if ok else "FAIL ", text)
	if not ok: failures += 1


func arg(name: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else ""


func functions(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for found: RegExMatch in RegEx.create_from_string("(?m)^(?:static\\s+)?func\\s+(\\w+)").search_all(text): out.append(found.get_string(1))
	return out


func run() -> void:
	var loader: GDScript = load("res://world/modding/mod_loader.gd")
	if not loader.booted: loader.boot()
	print("[bg-current] bundled dir: ", loader.bundled_dir)
	var rows: Array = loader.call("pack_rows")
	var parent: Dictionary = {}; var compat: Dictionary = {}
	for row: Dictionary in rows:
		if row.file == "bundled/board_games.pck": parent = row
		if row.file == "bundled/board_games_compat.pck": compat = row
	check(not parent.is_empty() and parent.enabled and parent.mounted and not parent.held, "board_games is on and mounted (%s)" % str(parent.get("reason", "missing")))
	check(not compat.is_empty() and compat.enabled and compat.mounted and compat.patch_of == "bundled/board_games.pck", "board_games_compat mounts after it as its patch (%s)" % str(compat.get("reason", "missing")))
	check(bool(parent.get("covered", false)), "board_games is covered by the compat pack (not held as old)")
	var replaced: PackedStringArray = parent.get("overrides", PackedStringArray())
	var scripts := Array(replaced).filter(func(path: String) -> bool: return path.get_extension() == "gd" and FileAccess.file_exists(ProjectSettings.globalize_path(path)))
	var mine: PackedStringArray = compat.get("overrides", PackedStringArray())
	check(scripts.size() == 25, "board_games replaces %d game scripts (expected 25)" % scripts.size())
	var dump := arg("--dump")
	for path: String in scripts:
		var mounted := FileAccess.get_file_as_string(path)
		var tree := FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
		if not dump.is_empty():
			var out := dump.path_join(path.trim_prefix("res://"))
			DirAccess.make_dir_recursive_absolute(out.get_base_dir())
			var file := FileAccess.open(out, FileAccess.WRITE); file.store_string(mounted); file.close()
		var script := load(path) as GDScript
		var missing := Array(functions(tree)).filter(func(name: String) -> bool: return name not in functions(mounted))
		check(path in mine and script != null and script.can_instantiate() and missing.is_empty() and not mounted.is_empty(),
			"%s: the compat copy serves (%d lines; game file %d lines), compiles, keeps every game function%s" % [path, mounted.count("\n"), tree.count("\n"), "" if missing.is_empty() else " MISSING " + str(missing)])
	print("BOARD_GAMES_CURRENT_DONE ", "PASS" if failures == 0 else "FAIL", " checks=", checks, " failures=", failures)
	await process_frame
	quit(0 if failures == 0 else 1)
