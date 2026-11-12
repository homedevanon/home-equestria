extends SceneTree
## MLPChag's Board games 1.2.0 shipped as a bundled mod with devanon's board_games_compat patch pack
## (M-MOD-11, M-MOD-03, MOD-01; dev 2026-11-08). His pack carries copies of 25 game scripts from game
## 0.3.0; the compat pack (private tools/bundled_mods/build_compat_patch.py) replaces them again with a
## three-way merge onto the current game. Two scenarios, one process each (a mounted pack cannot be
## taken back):
##
##   --scenario bundle: board_games 1.2.0 + compat from a bundled folder made here in user://, and an
##     old board_games pack (1.0.0) in the player's mods folder. Checks: 1.0.0 superseded and not
##     mounted, 1.2.0 mounted and covered by its patch, every overridden script compiles as mounted, no
##     function of the game's own copy is missing, wave-1 fixes and his hooks present (fixtures/
##     board_games/expect.json), the Golden Oak interior builds its library pieces and the game table,
##     the spa is wired, item_tags has goods:game-board, chess has 20 legal first moves and checkers 7,
##     and the board_game prompt help before (his copy) and after (compat) in bytes.
##   --scenario takeover --pack FILE --label NAME: what one board_games pack does on its own over the
##     current game (findings for M-MOD-03): the loader's verdict, then mounted (forced when held) and
##     each overridden script compiled, missing functions listed, Golden Oak and spa checked. Records
##     only; prints BOARD_GAMES_TAKEOVER_DONE.
##
## Packs come from the private root (`--packs <root>`, default the folder above the project):
## bundled_mods/board_games/board_games.pck, bundled_mods/board_games_compat/board_games_compat.pck and,
## for the supersede check, `--old-pack <file>` (the inner .pck of the 1.0.0 download, test only).
## Expected engine errors: copies that do not compile print parse errors (takeover runs).
##   XDG_DATA_HOME=<scratch>/board-games-test-N python3 tools/run_owned_godot.py --project home-equestria-public \
##       --wait-for-slot 1800 --expect BOARD_GAMES_BUNDLE_DONE --log LOG --arg=--scenario --arg=bundle \
##       --arg=--old-pack --arg=/path/board_games-1.0.0.pck res://tools/modding/test_board_games_bundle.gd
const LOADER := preload("res://world/modding/mod_loader.gd")
const EXPECT := "res://tools/modding/fixtures/board_games/expect.json"
const INTERIOR := "res://world/buildings/golden_oak/interior.gd"
const BOARD_TABLE := "res://world/minigames/board_games/board_table.gd"
const SCHEMA := "res://world/ai/pony_action_schema.gd"
const BOARD_SCRIPTS := ["board_adjourned", "board_engine", "board_fold", "board_models", "board_session", "board_table",
	"board_view", "checkers_rules", "chess_rules", "plaza_table"]
var failures := 0
var checks := 0
var temp := ""
var args := {}

func _initialize() -> void: run.call_deferred()

func check(ok: bool, text: String) -> void:
	checks += 1
	print("[board_games] ", "PASS " if ok else "FAIL ", text)
	if not ok: failures += 1

func note(text: String) -> void:
	print("[board_games] NOTE ", text)

func _args() -> void:
	var list := OS.get_cmdline_user_args()
	for i in list.size():
		if list[i].begins_with("--") and i + 1 < list.size() and not list[i + 1].begins_with("--"): args[list[i].trim_prefix("--")] = list[i + 1]

func _root() -> String:
	return str(args.get("packs", ProjectSettings.globalize_path("res://").path_join("..").simplify_path()))

func row_of(file: String) -> Dictionary:
	for row: Dictionary in LOADER.pack_rows():
		if row.file == file: return row
	return {}

func mod_of(id: String) -> Dictionary:
	for mod: Dictionary in LOADER.mods:
		if mod.id == id: return mod
	return {}

func run() -> void:
	_args()
	if not OS.get_environment("XDG_DATA_HOME").contains("board-games-test"):
		printerr("BOARD_GAMES_REFUSED requires an isolated XDG_DATA_HOME (containing board-games-test)"); quit(1); return
	temp = ProjectSettings.globalize_path("user://board_games_test")
	DirAccess.make_dir_recursive_absolute(temp)
	if str(args.get("scenario", "bundle")) == "takeover": await takeover()
	else: await bundle()

## The game scripts a pack replaces (its .gd copies at paths the game has; .remap counts as the .gd).
func overridden(pack: String) -> PackedStringArray:
	var out := PackedStringArray()
	for path: String in LOADER.pack_index(pack):
		if path.begins_with("res://mods/"): continue
		var plain := path.trim_suffix(".remap")
		if plain.get_extension() == "gd" and plain not in out and FileAccess.file_exists(ProjectSettings.globalize_path(plain)): out.append(plain)
	out.sort()
	return out

## Compiles a script's text as it stands at its res:// path now (class_name line dropped, as the
## loader's compile check does); false when it does not compile.
func compiles(path: String) -> bool:
	var script := GDScript.new()
	script.source_code = RegEx.create_from_string("(?m)^class_name\\s+\\w+\\s*").sub(FileAccess.get_file_as_string(path), "", true)
	return script.reload() == OK

## Top-level function names of a GDScript text.
func functions(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for found: RegExMatch in RegEx.create_from_string("(?m)^(?:static\\s+)?func\\s+(\\w+)").search_all(text):
		out.append(found.get_string(1))
	return out

## Functions the game's own file on disk declares that the mounted copy at its res:// path lacks.
## (An absolute path reads the disk; res:// reads through the mounted packs.)
func missing_functions(path: String) -> PackedStringArray:
	var mine := functions(FileAccess.get_file_as_string(ProjectSettings.globalize_path(path)))
	var mounted := functions(FileAccess.get_file_as_string(path))
	var out := PackedStringArray()
	for name: String in mine:
		if name not in mounted: out.append(name)
	return out

## Builds the Golden Oak interior from the mounted interior.gd: {built, beds, book_rest, table, seats, error}.
func golden_oak() -> Dictionary:
	var result := {"built": false, "beds": [], "book_rest": false, "table": false, "seats": false, "nodes": 0, "error": ""}
	var script := load(INTERIOR) as GDScript
	if script == null or not script.can_instantiate():
		result.error = "interior.gd does not compile"; return result
	var holder := Node3D.new()
	holder.name = "GoldenOakFixture"
	root.add_child(holder)
	var interior := script.new() as Node3D
	holder.add_child(interior)
	interior.call("build", {})
	result.built = interior.has_meta("review_views")
	result.beds = (interior.get("beds") as Dictionary).keys() if interior.get("beds") is Dictionary else []
	result.book_rest = interior.get_node_or_null("TableBookRest") != null
	var table := interior.get_node_or_null("GameTable")
	result.table = table != null and table.get_script() != null and (table.get_script() as Script).resource_path == BOARD_TABLE and table.is_in_group("board_tables")
	result.seats = table != null and table.get("player_seat") is Node3D and table.get("pony_seat") is Node3D
	result.nodes = interior.find_children("*", "", true, false).size()
	await process_frame
	holder.queue_free()
	await process_frame
	return result

func spa_wired() -> Dictionary:
	var adapters := FileAccess.get_file_as_string("res://world/game_town_adapters.gd")
	var game := FileAccess.get_file_as_string("res://world/game.gd")
	var jobs := FileAccess.get_file_as_string("res://world/mechanics/data/jobs.json")
	var venue := load("res://world/minigames/spa/spa_venue.gd") as GDScript
	return {"building": adapters.contains("res://world/minigames/spa/spa_venue.gd"), "setup": game.contains("get_nodes_in_group(\"spa_venue\")"),
		"job": jobs.contains("\"id\": \"spa\""), "venue_script": venue != null and venue.can_instantiate()}

## The prompt cost of the board_game command near a table, in bytes (tools/ai/prompt_sizes.gd method:
## pony_action_schema tag_rules over every command, with and without board_game).
func help_cost(schema: Script) -> Dictionary:
	var help: Dictionary = schema.get_script_constant_map().get("TAG_HELP", {})
	var caps: Array = help.keys()
	var without: Array = caps.filter(func(c: Variant) -> bool: return str(c) != "board_game")
	var names := ["player", "twilight_sparkle", "spike"]
	var all_rules := str(schema.call("tag_rules", caps, names, "(none)"))
	var other_rules := str(schema.call("tag_rules", without, names, "(none)"))
	return {"line": str(help.get("board_game", "")).to_utf8_buffer().size(), "near_table": all_rules.to_utf8_buffer().size() - other_rules.to_utf8_buffer().size(),
		"all": all_rules.to_utf8_buffer().size()}

func copy_to(source: String, folder: String, name: String) -> String:
	DirAccess.make_dir_recursive_absolute(folder)
	var target := folder.path_join(name)
	if DirAccess.copy_absolute(source, target) != OK: return ""
	return target

# ---------------------------------------------------------------------------------------------- bundle

func bundle() -> void:
	var source_parent := _root().path_join("bundled_mods/board_games/board_games.pck")
	var source_compat := _root().path_join("bundled_mods/board_games_compat/board_games_compat.pck")
	var old_pack := str(args.get("old-pack", ""))
	var bundled := temp.path_join("install/mods/bundled"); var user := temp.path_join("user_mods"); var empty := temp.path_join("none")
	for dir: String in [bundled, user, empty]: DirAccess.make_dir_recursive_absolute(dir)
	var parent := copy_to(source_parent, bundled, "board_games.pck")
	var compat := copy_to(source_compat, bundled, "board_games_compat.pck")
	check(not parent.is_empty() and not compat.is_empty(), "the bundled packs are there (%s, %s)" % [source_parent, source_compat])
	if parent.is_empty() or compat.is_empty():
		finish("BOARD_GAMES_BUNDLE_DONE"); return
	var manifest := {"format": 1, "mods": [
		{"id": "board_games", "title": "Board games: chess & checkers", "author": "MLPChag", "version": "1.2.0", "file": "board_games.pck",
			"sha256": FileAccess.get_sha256(parent), "default_on": true, "source_url": "https://u.pone.rs/zrxpzyzc.zip", "order": 10},
		{"id": "board_games_compat", "title": "Board games: compatibility patch", "author": "devanon", "version": "1.2.0-he.1", "file": "board_games_compat.pck",
			"sha256": FileAccess.get_sha256(compat), "default_on": true, "source_url": "", "patches": {"board_games": "1.2.0"}, "order": 11}]}
	var file := FileAccess.open(bundled.path_join("bundled_mods.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(manifest, "\t")); file.close()
	var has_old := not old_pack.is_empty() and not copy_to(old_pack, user, "board_games.pck").is_empty()
	check(old_pack.is_empty() or has_old, "the player's old copy is in his mods folder (%s)" % old_pack)
	var scripts := overridden(parent)
	check(scripts.size() == 25, "board_games 1.2.0 replaces %d game scripts (25 expected)" % scripts.size())
	var compat_scripts := overridden(compat)
	check(Array(scripts).all(func(p: String) -> bool: return p in compat_scripts), "the compat pack replaces every one of them again")
	for path: String in scripts:
		if ResourceLoader.has_cached(path): note("%s was cached before the packs mounted (checked from text)" % path)

	LOADER.boot([user], [empty], PackedStringArray(), bundled)
	var files: Array = LOADER.packs.map(func(row: Dictionary) -> String: return row.file)
	var bg := row_of("bundled/board_games.pck"); var patch := row_of("bundled/board_games_compat.pck")
	print("[board_games] mount order ", files)
	check(bg.enabled and bg.mounted and not bg.held and bg.covered, "board_games 1.2.0 mounts, covered by its patch, not held (%s)" % str(bg.reason))
	check(patch.enabled and patch.mounted and patch.patch_of == "bundled/board_games.pck" and files.find("bundled/board_games_compat.pck") == files.find("bundled/board_games.pck") + 1,
		"the compat pack mounts right after it and follows its switch (%s)" % str(patch.reason))
	if has_old:
		var old := row_of("board_games.pck")
		check(not old.enabled and not old.mounted and str(old.superseded_by).contains("1.2.0") and str(old.reason).begins_with("Superseded by"),
			"the player's board_games %s is superseded by the bundled 1.2.0 and never mounts (%s)" % [str(old.version), str(old.reason)])
	check(mod_of("board_games").errors.is_empty() and mod_of("board_games_compat").errors.is_empty() and LOADER.active().has(mod_of("board_games")) and LOADER.active().has(mod_of("board_games_compat")),
		"both mods run (%s / %s)" % [str(mod_of("board_games").errors), str(mod_of("board_games_compat").errors)])

	var broken := PackedStringArray(); var lost := []
	for path: String in scripts:
		var text := FileAccess.get_file_as_string(path)
		if text.contains("\n<<<<<<< ") or text.contains("\n>>>>>>> "): broken.append(path + " (conflict markers)"); continue
		if not compiles(path): broken.append(path)
		var missing := missing_functions(path)
		if not missing.is_empty(): lost.append("%s: %s" % [path.trim_prefix("res://"), ", ".join(missing)])
	check(broken.is_empty(), "every overridden game script compiles as mounted (%s)" % ", ".join(broken))
	check(lost.is_empty(), "no function of the game's own scripts is missing in the mounted copies (%s)" % "; ".join(PackedStringArray(lost.map(func(x: Variant) -> String: return str(x)))))
	var his_broken := PackedStringArray()
	for name: String in BOARD_SCRIPTS:
		var path := "res://world/minigames/board_games/%s.gd" % name
		if not FileAccess.file_exists(path) or not compiles(path): his_broken.append(name)
	check(his_broken.is_empty(), "his 10 board_games scripts compile (%s)" % ", ".join(his_broken))
	var expect: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(EXPECT))
	for group: String in ["base", "hooks"]:
		var absent := PackedStringArray()
		for path: String in expect[group]:
			var text := FileAccess.get_file_as_string("res://" + path)
			for marker: String in expect[group][path]:
				if not text.contains(marker): absent.append("%s: %s" % [path, marker])
		check(absent.is_empty(), "%s present in the mounted copies (%s)" % ["game fixes since 0.3.0 (incl. the M-INP-01 typing guard)" if group == "base" else "his board-game hooks", "; ".join(absent)])
	var wrong := PackedStringArray()
	var fixes: Dictionary = expect["fixes"]
	for path: String in fixes:
		var text := FileAccess.get_file_as_string("res://" + path)
		var rule: Dictionary = fixes[path]
		for marker: String in rule["has"]:
			if not text.contains(marker): wrong.append("%s lacks %s" % [path, marker])
		for marker: String in rule["lacks"]:
			if text.contains(marker): wrong.append("%s still has %s" % [path, marker])
	check(wrong.is_empty(), "compat fixes in place: SHUTDOWN waits, table range, aliases (%s)" % "; ".join(wrong))

	var oak := await golden_oak()
	check(oak.built and "twilight" in oak.beds and "spike" in oak.beds and oak.book_rest, "the Golden Oak interior builds its library: beds %s, book rest %s, %d nodes (%s)" % [str(oak.beds), str(oak.book_rest), int(oak.nodes), str(oak.error)])
	check(oak.table and oak.seats, "and the game table by the fireplace with both cushions (board_table.gd)")
	var spa := spa_wired()
	check(spa.building and spa.setup and spa.job and spa.venue_script, "the spa is wired: building %s, venue setup %s, job %s, script %s" % [spa.building, spa.setup, spa.job, spa.venue_script])
	var tags: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://world/inventory/item_tags.json"))
	var table_tags: Dictionary = (tags as Dictionary).get("tags", {}) if tags is Dictionary else {}
	check(table_tags.get("goods:game-board") == ["tool"] and table_tags.has("goods:easel"), "item_tags has goods:game-board (merged; the game's own tags kept)")
	var chess: RefCounted = (load("res://world/minigames/board_games/chess_rules.gd") as GDScript).new()
	var checkers: RefCounted = (load("res://world/minigames/board_games/checkers_rules.gd") as GDScript).new()
	var chess_moves: Array = chess.call("moves"); var checkers_moves: Array = checkers.call("moves")
	check(chess_moves.size() == 20, "chess: %d legal moves from the start position (20)" % chess_moves.size())
	check(checkers_moves.size() == 7, "checkers: %d legal moves from the start position (7)" % checkers_moves.size())

	# Token cost near a table: his copy of the schema (compiled from his pack) against the mounted one.
	var his := GDScript.new()
	his.source_code = LOADER.pack_text(parent, LOADER.pack_index(parent)[SCHEMA])
	var before := help_cost(his) if his.reload() == OK else {}
	var after := help_cost(load(SCHEMA) as Script)
	print("SIZE board_game help line: before %d bytes (~%d tokens), after %d bytes (~%d tokens)" % [int(before.get("line", 0)), int(before.get("line", 0)) / 4, int(after.line), int(after.line) / 4])
	print("SIZE tag rules near a table (board_game included minus excluded): before %d bytes (~%d tokens), after %d bytes (~%d tokens); all tags after %d bytes" % [
		int(before.get("near_table", 0)), int(before.get("near_table", 0)) / 4, int(after.near_table), int(after.near_table) / 4, int(after.all)])
	check(int(after.near_table) > 0 and int(after.near_table) <= 240 + 8, "the board_game help costs <= ~60 tokens near a table (%d bytes)" % int(after.near_table))
	finish("BOARD_GAMES_BUNDLE_DONE")

# -------------------------------------------------------------------------------------------- takeover

func takeover() -> void:
	var source := str(args.get("pack", "")); var label := str(args.get("label", source.get_file()))
	var dir := temp.path_join("takeover"); var empty := temp.path_join("none")
	DirAccess.make_dir_recursive_absolute(empty)
	var pack := copy_to(source, dir, "board_games.pck")
	if pack.is_empty():
		printerr("no pack at ", source); finish("BOARD_GAMES_TAKEOVER_DONE"); return
	var scripts := overridden(pack)
	print("[takeover %s] replaces %d game scripts" % [label, scripts.size()])
	LOADER.boot([dir], [empty], PackedStringArray(), "")
	var row := row_of("board_games.pck")
	print("[takeover %s] loader, not allowed: enabled=%s held=%s mounted=%s reason=%s" % [label, row.enabled, row.held, row.mounted, row.reason])
	if not row.mounted and row.held:
		# The player switches it on anyway (Settings -> Mods): the compile check decides.
		LOADER.set_enabled("board_games.pck", true)
		LOADER.boot([dir], [empty], PackedStringArray(), "")
		row = row_of("board_games.pck")
		print("[takeover %s] loader, allowed by the player: enabled=%s held=%s mounted=%s reason=%s" % [label, row.enabled, row.held, row.mounted, row.reason])
	if not row.mounted:
		print("[takeover %s] mounted by force to record the damage (an old loader, or a pack without a version)" % label)
		ProjectSettings.load_resource_pack(pack, true)
	var broken := PackedStringArray()
	for path: String in scripts:
		var ok := compiles(path)
		if not ok: broken.append(path.trim_prefix("res://"))
		var missing := missing_functions(path)
		print("[takeover %s] %s %s; game functions missing: %s" % [label, "COMPILES" if ok else "DOES NOT COMPILE", path.trim_prefix("res://"), ", ".join(missing) if not missing.is_empty() else "none"])
	print("[takeover %s] scripts that do not compile: %d (%s)" % [label, broken.size(), ", ".join(broken)])
	var expect: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(EXPECT))
	var base: Dictionary = expect["base"]
	for path: String in base:
		var text := FileAccess.get_file_as_string("res://" + path)
		for marker: String in base[path]:
			if not text.contains(marker): print("[takeover %s] reverted fix: %s lacks %s" % [label, path, marker])
	var oak := await golden_oak()
	print("[takeover %s] Golden Oak: built=%s beds=%s book_rest=%s game_table=%s seats=%s nodes=%d error=%s" % [label, oak.built, str(oak.beds), oak.book_rest, oak.table, oak.seats, int(oak.nodes), oak.error])
	var spa := spa_wired()
	print("[takeover %s] spa: building=%s venue_setup=%s job=%s venue_script=%s" % [label, spa.building, spa.setup, spa.job, spa.venue_script])
	finish("BOARD_GAMES_TAKEOVER_DONE")

func finish(marker: String) -> void:
	print(marker, " ", "PASS" if failures == 0 else "FAIL", " checks=", checks, " failures=", failures)
	await process_frame
	quit(0 if failures == 0 else 1)
