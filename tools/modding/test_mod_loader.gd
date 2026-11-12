extends SceneTree
## Mod support (world/modding/, 2026-10-26): packs from the mods folder and loose packs mount in
## name order, Off switches skip a pack, a broken mod.json is listed but never runs, JSON merges,
## script extensions, entry scripts, world save sections, and the Dinnerbone example builds into a
## pack the loader recognises and turns a pony over. Packs are made in user:// by the test itself.
##   XDG_DATA_HOME=<scratch>/mod-loader-test python3 tools/run_owned_godot.py --project home-equestria-public \
##       --expect MOD_LOADER_DONE --log LOG res://tools/modding/test_mod_loader.gd
const LOADER := preload("res://world/modding/mod_loader.gd")
const BUILD := preload("res://tools/modding/build_mod.gd")
const MODS := preload("res://world/modding/mods.gd")
const EXTENDED := "res://world/characters/hybrid_mare/dock_tail_mount.gd"
var failures := 0
var checks := 0
var temp := ""

func _initialize() -> void: run.call_deferred()
func check(ok: bool, text: String) -> void:
	checks += 1
	print("[mods] ", "PASS " if ok else "FAIL ", text)
	if not ok: failures += 1

## A pack of {res:// path: text} written with PCKPacker.
func pack(path: String, files: Dictionary) -> void:
	var packer := PCKPacker.new()
	packer.pck_start(path)
	var n := 0
	for target: String in files:
		var source := temp.path_join("src_%s_%d" % [path.get_file(), n]); n += 1
		var file := FileAccess.open(source, FileAccess.WRITE); file.store_string(str(files[target])); file.close()
		packer.add_file(target, source)
	packer.flush()

func run() -> void:
	if not OS.get_environment("XDG_DATA_HOME").contains("mod-loader-test"):
		printerr("MOD_LOADER_REFUSED requires an isolated XDG_DATA_HOME"); quit(1); return
	temp = ProjectSettings.globalize_path("user://mod_test")
	var mods_dir := temp.path_join("mods"); var loose_dir := temp.path_join("exe")
	DirAccess.make_dir_recursive_absolute(mods_dir); DirAccess.make_dir_recursive_absolute(loose_dir)
	var built := BUILD.build("dinnerbone", mods_dir.path_join("dinnerbone.pck"))
	check(FileAccess.file_exists(built), "Dinnerbone builds (%s)" % built)
	var scene := "[gd_scene format=3 uid=\"uid://keepme\"]\n\n[ext_resource type=\"Script\" uid=\"uid://b1x2\" path=\"res://mods/x/a.gd\" id=\"1\"]\n[ext_resource type=\"Texture2D\" path=\"res://mods/x/b.png\" id=\"2\"]\n"
	var plain: String = BUILD.without_uids(scene)
	check(not plain.contains("uid://b1x2") and plain.contains("path=\"res://mods/x/a.gd\" id=\"1\"") and plain.contains("uid://keepme"), "the build tool drops the mod's UIDs from [ext_resource] lines (%s)" % plain.c_escape())
	pack(mods_dir.path_join("b_merge.pck"), {
		"res://mods/merge_test/mod.json": JSON.stringify({"id": "merge_test", "name": "Merge test", "version": "2.0", "author": "Tester", "entry": "res://mods/merge_test/main.gd", "extends": ["res://mods/merge_test/ext.gd"]}),
		"res://mods/merge_test/main.gd": "extends Node\nvar started := true\n",
		"res://mods/merge_test/ext.gd": "extends \"%s\"\nconst MODDED := true\n" % EXTENDED,
		"res://mods/merge_test/merge/world/food/definitions.json": JSON.stringify({"mod_cake": {"name": "Mod Cake", "price_bits": 3}, "hayburger": {"price_bits": 99}})})
	pack(mods_dir.path_join("c_broken.pck"), {"res://mods/broken_test/mod.json": "{not json"})
	pack(mods_dir.path_join("d_off.pck"), {"res://mods/off_test/mod.json": JSON.stringify({"id": "off_test", "name": "Off"})})
	pack(loose_dir.path_join("loose_override.pck"), {"res://mods/loose_marker.txt": "loose"})
	pack(loose_dir.path_join("HomeEquestria-data.pck"), {"res://mods/game_pack_marker.txt": "game"})
	# Old mods that replace game files stay off (thread 43671981, 2026-11-03); the rest load.
	var now := LOADER.game_version()
	pack(mods_dir.path_join("e_old.pck"), {
		"res://mods/old_test/mod.json": JSON.stringify({"id": "old_test", "name": "Old menus", "game_version": "0.0.3", "author": "Home: Equestria"}),
		"res://PROJECT_SPLIT.json": "OLD", "res://world/modding/mods.gd.remap": "[remap]", "res://.godot/imported/x.ctex": "x"})
	pack(mods_dir.path_join("f_current.pck"), {
		"res://mods/current_test/mod.json": JSON.stringify({"id": "current_test", "name": "Current", "game_version": now}),
		"res://ai_config.example.json": "CURRENT"})
	pack(mods_dir.path_join("g_new.pck"), {
		"res://mods/new_files_test/mod.json": JSON.stringify({"id": "new_files_test", "name": "Adds only", "game_version": "0.0.1"})})
	pack(mods_dir.path_join("h_stamped.pck"), {
		"res://mods/stamped_test/mod.json": JSON.stringify({"id": "stamped_test", "name": "Stamped"}),
		"res://mods/stamped_test/%s" % LOADER.BUILT: JSON.stringify({"id": "stamped_test", "game_version": "0.0.2"}),
		"res://icon.png.import": "[remap]"})
	LOADER.boot([mods_dir], [loose_dir], PackedStringArray(["d_off.pck"]))
	var files: Array = LOADER.packs.map(func(row: Dictionary) -> String: return row.file)
	check(files == ["b_merge.pck", "c_broken.pck", "d_off.pck", "dinnerbone.pck", "e_old.pck", "f_current.pck", "g_new.pck", "h_stamped.pck", "loose_override.pck"], "packs in name order, the game's own pack skipped (%s)" % str(files))
	var ids: Array = LOADER.mods.map(func(mod: Dictionary) -> String: return mod.id)
	check("dinnerbone" in ids, "the built Dinnerbone pack is recognised although res://mods/dinnerbone exists in the source")
	var active: Array = LOADER.active().map(func(mod: Dictionary) -> String: return mod.id)
	check(active.has("merge_test") and active.has("dinnerbone") and not active.has("broken_test"), "valid mods run, the broken one does not (%s)" % str(active))
	var broken: Array = LOADER.mods.filter(func(mod: Dictionary) -> bool: return mod.id == "broken_test")
	check(broken.size() == 1 and not broken[0].errors.is_empty(), "the broken mod is listed with a reason")
	check(not FileAccess.file_exists("res://mods/off_test/mod.json") and "off_test" not in ids, "a switched-off pack is not mounted")
	check(FileAccess.get_file_as_string("res://mods/loose_marker.txt") == "loose", "a loose pack beside the executable still mounts")
	var row_of := func(file: String) -> Dictionary:
		for row: Dictionary in LOADER.packs:
			if row.file == file: return row
		return {}
	var old: Dictionary = row_of.call("e_old.pck")
	check(old.held and not old.mounted and old.game_version == "0.0.3" and old.title == "Old menus", "an old mod that replaces game files is held off (%s)" % str(old))
	check(old.overrides == PackedStringArray(["res://PROJECT_SPLIT.json", "res://world/modding/mods.gd"]), "its replaced game files are listed, .remap shown as the script, imports cache skipped (%s)" % str(old.overrides))
	check(FileAccess.get_file_as_string("res://PROJECT_SPLIT.json") != "OLD" and "old_test" not in ids, "and the game file stays the game's")
	var stamped: Dictionary = row_of.call("h_stamped.pck")
	check(stamped.held and stamped.game_version == "0.0.2" and stamped.overrides == PackedStringArray(["res://icon.png"]), "the build tool's version stamp counts when mod.json has none (%s)" % str(stamped))
	var current: Dictionary = row_of.call("f_current.pck")
	check(current.mounted and not current.held and FileAccess.get_file_as_string("res://ai_config.example.json") == "CURRENT" and active.has("current_test"), "a mod declaring this game version still replaces game files (%s)" % str(current))
	var adds: Dictionary = row_of.call("g_new.pck")
	check(adds.mounted and not adds.held and adds.overrides.is_empty() and active.has("new_files_test"), "an old mod that replaces nothing still loads")
	var dinner: Dictionary = row_of.call("dinnerbone.pck")
	check(dinner.overrides.is_empty() and not dinner.held, "the built Dinnerbone pack replaces no game file (%s)" % str(dinner.overrides))
	check(not LOADER.switched_on("e_old.pck") and LOADER.switched_on("f_current.pck"), "the Mods screen shows the held mod as Off")
	LOADER.set_enabled("e_old.pck", true)
	check(LOADER.switched_on("e_old.pck"), "switching it on allows it for this game version")
	ProjectSettings.set_setting("application/config/version", "99.0.0")
	check(not LOADER.switched_on("e_old.pck"), "and the next game version asks again")
	ProjectSettings.set_setting("application/config/version", now)
	LOADER.set_enabled("e_old.pck", false)
	check(not LOADER.switched_on("e_old.pck") and "e_old.pck" in LOADER.disabled_files(), "switching it off again sticks")
	check(LOADER.version_older("0.1.0-maredev", "0.1.1.1") and LOADER.version_older("0.1.1", "0.1.1.1") and not LOADER.version_older("0.1.0", "0.1.0-maredev")
		and not LOADER.version_older("", "0.1.1") and not LOADER.version_older("0.2.0", "0.1.9") and LOADER.version_older("0.9", "0.10"), "version order by numbers")
	var page: Control = load("res://world/ui/settings_page.gd").new()
	var old_row: Dictionary = {}
	for row: Dictionary in LOADER.pack_rows():
		if row.file == "e_old.pck": old_row = row
	var held_text: String = str(page.call("_mod_text", old_row, LOADER.mods)) + "\n" + str(page.call("_mod_notes", old_row))
	check(held_text.contains("Old menus") and held_text.contains("Made for game 0.0.3") and held_text.contains("Kept off") and held_text.contains("res://PROJECT_SPLIT.json"), "the Mods screen names the old mod, its version and the files it replaces (%s)" % held_text)
	check(old_row.held and old_row.switchable and not old_row.enabled and not str(old_row.reason).is_empty() and old_row.title == "Old menus", "pack_rows() shows the held state and its reason (%s)" % str(old_row))
	var fake_author := {"file": "x.pck", "name": "Anonfilly", "version": "1", "author": "Home: Equestria", "description": "", "errors": []}
	check((page.call("_mod_text", {"file": "x.pck", "error": ""}, [fake_author]) as String).contains("Third-party mod"), "and flags a mod naming the game as its author")
	page.free()
	check(LOADER.claims_game_author("Home: Equestria") and LOADER.claims_game_author("home equestria") and not LOADER.claims_game_author("Anon") and not LOADER.claims_game_author(""), "a mod naming the game as its author is spotted")
	var food: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://world/food/definitions.json"))
	check(food.get("mod_cake", {}).get("name") == "Mod Cake" and int(food.hayburger.price_bits) == 99 and str(food.hayburger.name) == "Hayburger", "JSON merge adds and overrides keys, keeps the rest")
	check(food.size() > 2, "merged data keeps the game's entries (%d)" % food.size())
	var script := load(EXTENDED) as Script
	check(script != null and script.get_script_constant_map().get("MODDED") == true and script.get_base_script() != null, "the game script path now loads the mod's extension")
	# Player board #40: a script compiled after the extension that preload()s the game script.
	var later_script := GDScript.new()
	later_script.source_code = "extends RefCounted\nconst X := preload(\"%s\")\nfunc modded() -> bool:\n\tvar s: Script = X\n\treturn s.get_script_constant_map().get(\"MODDED\", false)\n" % EXTENDED
	var compiled := later_script.reload()
	check(compiled == OK and later_script.can_instantiate() and later_script.new().modded(), "a later preload() of the extended game script parses and gets the mod's subclass (%s)" % error_string(compiled))
	check(LOADER.deep_merge([1], [2]) == [1, 2] and LOADER.deep_merge({"a": {"b": 1}}, {"a": {"c": 2}}) == {"a": {"b": 1, "c": 2}}, "lists append, objects merge")
	LOADER.set_enabled("dinnerbone.pck", false)
	check("dinnerbone.pck" in LOADER.disabled_files(), "a switch is saved")
	LOADER.set_enabled("dinnerbone.pck", true)
	check("dinnerbone.pck" not in LOADER.disabled_files(), "and switched back on")
	# The autoload part: entry scripts run, matchers, save sections.
	var mods: Node = MODS.new(); mods.name = "ModsUnderTest"; root.add_child(mods)
	await process_frame
	check(mods.get_node_or_null("merge_test") != null and bool(mods.get_node("merge_test").get("started")), "entry script added and started")
	var grouped := Node.new(); grouped.add_to_group("ponies_test"); root.add_child(grouped)
	var seen: Array = []
	mods.on_node("group:ponies_test", func(n: Node) -> void: seen.append(n))
	var later := Node.new(); later.add_to_group("ponies_test"); root.add_child(later)
	await process_frame
	check(seen.size() == 2 and seen.has(grouped) and seen.has(later), "on_node finds existing and later nodes (%d)" % seen.size())
	check(MODS.matches(later, "class:Node") and not MODS.matches(later, "class:Node3D"), "class matcher")
	var context: Node = preload("res://world/ai/world_context.gd").new()
	var game_script := GDScript.new(); game_script.source_code = "extends Node\nvar world_context: Node\n"; game_script.reload()
	var game := Node.new(); game.set_script(game_script)
	game.set("world_context", context); mods.game = game
	mods.state("merge_test").score = 3
	check(int(context.state.mods.merge_test.score) == 3, "state() writes the mod's world save section")
	var saved := {"version": context.VERSION, "world_id": "w", "events": [], "relationships": {}, "lore": {}, "removed_lore": [], "mods": {"merge_test": {"score": 3}}}
	check(context._valid_state(saved, "w"), "a save with a mods section is valid")
	saved.mods = {"merge_test": 3}
	check(not context._valid_state(saved, "w"), "a malformed mods section is refused")
	# Dinnerbone on a stand-in pony: one bone 1.2 m up, the model turned over and lifted by it.
	var pony_script := GDScript.new(); pony_script.source_code = "extends Node3D\nvar _model: Node3D\nvar skeleton: Skeleton3D\n"; pony_script.reload()
	var pony := Node3D.new(); pony.set_script(pony_script); root.add_child(pony)
	var model := Node3D.new(); pony.add_child(model)
	var skeleton := Skeleton3D.new(); model.add_child(skeleton)
	skeleton.add_bone("ear"); skeleton.set_bone_rest(0, Transform3D(Basis(), Vector3(0, 1.2, 0)))
	pony.set("_model", model); pony.set("skeleton", skeleton)
	var dinnerbone: Node = mods.get_node_or_null("dinnerbone")
	check(dinnerbone != null, "Dinnerbone's entry script runs from its pack")
	if dinnerbone != null:
		dinnerbone.call("_turn", pony)
		check(model.transform.basis.y.is_equal_approx(Vector3.DOWN) and is_equal_approx(model.transform.origin.y, 1.2), "Dinnerbone turns the model over and stands it on its ears (%s)" % str(model.transform))
		dinnerbone.call("_turn", pony)
		check(model.transform.basis.y.is_equal_approx(Vector3.DOWN), "turning twice does not turn her back")
	# Live switches: entry-only packs start and stop now, the rest wait for the next launch.
	check(mods.switch("dinnerbone.pck", false) and mods.get_node_or_null("dinnerbone") == null, "switching Dinnerbone off stops it now")
	check("dinnerbone.pck" in LOADER.disabled_files() and not mods.is_active("dinnerbone"), "and saves the switch")
	check(model.transform.basis.y.is_equal_approx(Vector3.UP) and is_zero_approx(model.transform.origin.y), "and turns ponies back onto their hooves (%s)" % str(model.transform))
	var after_off := Node.new(); after_off.add_to_group("ponies_test"); root.add_child(after_off)
	await process_frame
	check(mods.switch("dinnerbone.pck", true) and mods.get_node_or_null("dinnerbone") != null, "switching it back on starts it again")
	check(mods.switch("d_off.pck", true) and FileAccess.file_exists("res://mods/off_test/mod.json") and mods.is_active("off_test"), "a pack switched off at launch mounts and runs when switched on")
	check(not mods.switch("b_merge.pck", false) and mods.get_node_or_null("merge_test") != null, "a pack with merges and script extensions waits for the next launch")
	check("b_merge.pck" in LOADER.disabled_files(), "but its switch is saved")
	after_off.queue_free()
	print("MOD_LOADER_DONE ", "PASS" if failures == 0 else "FAIL", " checks=", checks, " failures=", failures)
	mods.queue_free(); pony.queue_free(); grouped.queue_free(); later.queue_free(); context.free(); game.free()
	await process_frame
	quit(0 if failures == 0 else 1)
