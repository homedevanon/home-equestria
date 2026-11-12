extends SceneTree
## Scenario mods (M-MOD-10, world/modding/scenario.gd): mod.json "scenario" parsing, one scenario
## mod at a time, the world start (stamp, initial_state, start node, skip_opening / held opening),
## stamped saves and the load rules on every path (title stage, in-game load and F8, resume, save
## browser greyed rows). The example mod (res://mods/example_scenario) is built into a real pack
## with tools/modding/build_mod.gd. Real loader, GameSaves, world context, arrival story and save
## browser; the game host and the checkpoint snapshot are fixtures (as tools/saves/ tests do).
##   XDG_DATA_HOME=/tmp/scenario-test-X python3 tools/run_owned_godot.py --project home-equestria-public \
##       --expect SCENARIO_MODS_DONE --log LOG res://tools/modding/test_scenario_mods.gd
const LOADER := preload("res://world/modding/mod_loader.gd")
const BUILD := preload("res://tools/modding/build_mod.gd")
const SCENARIO := preload("res://world/modding/scenario.gd")
const SAVES := preload("res://world/game_saves.gd")
const FILE := preload("res://world/save_file.gd")
const CATALOGUE := preload("res://world/saves/save_catalogue.gd")
const CONTEXT := preload("res://world/ai/world_context.gd")
const STORE := preload("res://world/inventory/inventory_store.gd")
const CLOTHES := preload("res://world/customization/clothing_profile.gd")
const NEEDS := "Needs the Example Scenario mod"
const TURN_OFF := "Turn off the Example Scenario mod to load this"
var checks := 0
var failures := 0
var temp := ""
var starting: Array = []

class Checkpoints extends "res://world/game_saves.gd":
	var fixture: Dictionary
	func snapshot() -> Dictionary:
		return fixture.duplicate(true)

class Inventory extends Node:
	var inventory := STORE.new()
	var clothing := CLOTHES.new()
	var customizer := Draft.new()

class Draft extends RefCounted:
	var opened := false

class Host extends Node:
	var world_context: Node
	var inventory: Node
	var context_world_id := "default"
	var director: Node
	var encounters: Node
	var xr_active := false
	var player: Node3D
	var arrival: Node
	func _find_camera(_rig: Node) -> Camera3D: return null

## Golden Oak Library's interior, as arrival_story.gd _library() finds it.
class Library extends Node3D:
	func place_id() -> String: return "house:golden_oak_library"
	func center() -> Vector3: return global_position + Vector3(0, 0, -4)
	func inside() -> Vector3: return global_position

func _initialize() -> void: run.call_deferred()

func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("[scenario] ", "PASS " if ok else "FAIL ", text)

func pack(path: String, files: Dictionary) -> void:
	var packer := PCKPacker.new()
	packer.pck_start(path)
	var n := 0
	for target: String in files:
		var source := temp.path_join("src_%s_%d" % [path.get_file(), n]); n += 1
		var file := FileAccess.open(source, FileAccess.WRITE); file.store_string(str(files[target])); file.close()
		packer.add_file(target, source)
	packer.flush()

func boot(dir: String) -> void:
	LOADER.boot([dir], [], PackedStringArray(), "")

func checkpoint(id: String, bits: int, stamp: Dictionary) -> Dictionary:
	var slots: Array = []
	for i in 27: slots.append({})
	var legacy := {"version": 1, "world_id": id, "saved_at": Time.get_unix_time_from_system(), "position": [1, 2, 3], "yaw": 0,
		"hours": 10, "day": 3, "residents": {}, "clothes": CLOTHES.defaults(),
		"inventory": {"version": 1, "slots": slots, "checked_out": {}, "bits": bits},
		"context": {"version": 1, "world_id": id, "events": [], "relationships": {}, "lore": {}, "removed_lore": [], "revision": 0}}
	var prepared: Dictionary = SAVES.prepare(legacy, id).doc
	prepared.summary = {}
	if not stamp.is_empty():
		prepared.context.scenario = stamp.duplicate()   # as the world context holds it
		prepared.scenario = {"id": stamp.id, "name": stamp.name}   # as snapshot() adds it
	return prepared

func host_for(world: String) -> Host:
	var host := Host.new(); host.name = "Game_" + world; host.context_world_id = world
	root.add_child(host)
	host.world_context = CONTEXT.new(); host.add_child(host.world_context)
	check(host.world_context.open_world(world), "isolated context opens for " + world)
	host.inventory = Inventory.new(); host.add_child(host.inventory)
	host.player = Node3D.new(); host.player.name = "Player"; host.add_child(host.player)
	return host

## What game.gd _ready does around the arrival story (world/game.gd, SCENARIO calls).
func start_world(host: Host, is_new: bool, arrival_script: Script) -> Dictionary:
	var block := SCENARIO.begin_world(host, is_new)
	host.arrival = arrival_script.new(); host.arrival.name = "ArrivalStory"
	host.add_child(host.arrival); host.arrival.set_physics_process(false)
	host.arrival.prepare(host, {})
	var start: Node = SCENARIO.start_world(host, host.arrival, is_new)
	return {"block": block, "start": start}

func save_into(host: Host, doc: Dictionary) -> String:
	var saves := Checkpoints.new(); host.add_child(saves)
	saves.setup(host, "user://worlds/" + host.context_world_id + "/saves")
	saves.ready_to_save = true; saves.fixture = doc
	check(saves.save_slot(0), "a slot save starts in " + host.context_world_id)
	while saves.busy: await process_frame
	return saves.slot_path(0)

func entry_for(path: String) -> Dictionary:
	for entry: Dictionary in CATALOGUE.catalogue():
		if str(entry.path) == path: return entry
	return {}

func reset_staging() -> void:
	SAVES.pending = {}; SAVES.requested_world = ""; SAVES.start_fresh = false; SAVES.last_problem = ""

## A save browser on the title (no GameSaves): the card of `path` and why it is greyed.
func browser_card(path: String, world: String) -> Dictionary:
	var browser: Control = load("res://world/ui/save_browser.gd").new()
	root.add_child(browser)
	browser.setup(Vector2(1200, 800), 20, null, false)
	browser.open(world)
	await process_frame
	var out := {"found": false}
	for card: Node in browser.find_children("*", "Button", true, false):
		if not card.has_meta("path") or str(card.get_meta("path")) != path: continue
		out = {"found": true, "alpha": (card as Control).modulate.a, "tip": (card as Control).tooltip_text}
	var entry := {}
	for e: Dictionary in browser.get("_entries"):
		if str(e.path) == path: entry = e
	if not entry.is_empty():
		browser.call("_show_save", entry)
		await process_frame
		for b: Node in browser.find_children("*", "Button", true, false):
			if (b as Button).text == "Load this save": out["page_load_off"] = (b as Button).disabled
	browser.queue_free()
	await process_frame
	return out

func run() -> void:
	if not OS.get_environment("XDG_DATA_HOME").contains("scenario-test"):
		printerr("SCENARIO_MODS_REFUSED requires an isolated XDG_DATA_HOME (scenario-test)"); quit(1); return
	await process_frame   # arrival_story.gd names autoloads: load it only after they exist
	var arrival_script: Script = load("res://world/life/arrival_story.gd")
	temp = ProjectSettings.globalize_path("user://scenario_test")
	var none_dir := temp.path_join("none"); var example_dir := temp.path_join("example")
	var two_dir := temp.path_join("two"); var hold_dir := temp.path_join("hold")
	for dir: String in [none_dir, example_dir, two_dir, hold_dir]: DirAccess.make_dir_recursive_absolute(dir)
	var mods: Node = root.get_node_or_null("Mods")
	check(mods != null and mods.has_signal("world_starting"), "the Mods autoload has world_starting(game, is_new)")
	if mods != null: mods.connect("world_starting", func(game: Node, is_new: bool) -> void: starting.append([game.name, is_new]))

	# 0. mod.json "scenario" parsing.
	check(str(SCENARIO.parse({"id": "Bad Id"}, "x").error).contains("lower-case"), "a bad scenario id is refused")
	check(str(SCENARIO.parse({"id": "ok", "start": "res://world/game.gd"}, "x").error).contains("inside res://mods/x/"), "a start outside the mod's folder is refused")
	check(str(SCENARIO.parse({"id": "ok", "skip_opening": "yes"}, "x").error).contains("true or false"), "skip_opening must be a bool")
	var plain: Dictionary = SCENARIO.parse({"id": "ok"}, "x")
	check(str(plain.error).is_empty() and plain.scenario.name == "ok" and plain.scenario.skip_opening == false, "a bare scenario gets defaults (%s)" % str(plain))

	# (a) No scenario mod: a new world is not stamped and the opening plays.
	var built := BUILD.build("example_scenario", example_dir.path_join("example_scenario.pck"))
	check(FileAccess.file_exists(built), "the example scenario builds with build_mod.gd (%s)" % built)
	boot(none_dir)
	check(SCENARIO.active_scenario().is_empty(), "(a) no scenario runs without a scenario mod")
	var vanilla := host_for("scn-vanilla")
	var started := start_world(vanilla, true, arrival_script)
	check(str(started.block).is_empty() and not vanilla.world_context.state.has("scenario"), "(a) a new world has no scenario stamp")
	check(started.start == null and vanilla.arrival.stage() == "wake", "(a) no start node; the forest opening begins (stage %s)" % vanilla.arrival.stage())
	check(starting.size() == 1 and starting[0] == [vanilla.name, true], "(a) Mods.world_starting(game, true) for the new world (%s)" % str(starting))
	var vanilla_slot: String = await save_into(vanilla, checkpoint("scn-vanilla", 11, {}))
	var vanilla_meta: Variant = FILE.parse(CATALOGUE.meta_path(vanilla_slot), 65536)
	check(vanilla_meta is Dictionary and vanilla_meta.get("scenario") == "", "(a) a vanilla save's header says it is vanilla (%s)" % str(vanilla_meta))

	# (b) The example scenario on: stamped, initial state merged, start node ran, opening skipped.
	boot(example_dir)
	var running := SCENARIO.active_scenario()
	check(running.get("id") == "example_scenario" and running.get("name") == "Example Scenario" and running.get("skip_opening") == true and running.get("mod") == "example_scenario", "(b) the example scenario runs (%s)" % str(running))
	var library := Library.new(); library.add_to_group("house_interiors"); root.add_child(library)
	library.global_position = Vector3(-24.0, 1.0, -262.0)
	var example := host_for("scn-example")
	starting.clear()
	started = start_world(example, true, arrival_script)
	var state: Dictionary = example.world_context.state
	check(str(started.block).is_empty() and state.get("scenario") is Dictionary and state.scenario.id == "example_scenario" and state.scenario.name == "Example Scenario" and state.scenario.version == "1.0.0", "(b) the new world is stamped (%s)" % str(state.get("scenario")))
	check(state.get("mods") is Dictionary and int(state.mods.get("example_scenario", {}).get("chapter", 0)) == 1, "(b) initial_state.json is merged into the world (%s)" % str(state.get("mods")))
	check(starting.size() == 1 and starting[0] == [example.name, true], "(b) Mods.world_starting fires for it too")
	var start: Node = started.start
	check(start != null and start.name == "ScenarioStart" and start.get_parent() == example, "(b) the start node is the game's child ScenarioStart")
	check(example.arrival.stage() == "done" and example.arrival.get_node_or_null("ArrivalWake") == null and bool(example.arrival.data.get("opening_skipped", false)), "(b) skip_opening: no forest, no wake (stage %s)" % example.arrival.stage())
	# No loading cover here, so the example start may already have finished inside prepare().
	var waited := 0
	while not bool(state.get("mods", {}).get("example_scenario", {}).get("started_at_golden_oak", false)) and waited < 600: await process_frame; waited += 1
	check(start != null and start.has_signal("finished"), "(b) the start node has the finished signal")
	check(bool(state.get("mods", {}).get("example_scenario", {}).get("started_at_golden_oak", false)), "(b) the start node ran to the end: its world flag is set (%d frames)" % waited)
	var feet := example.player.global_position
	check(Vector2(feet.x, feet.z).distance_to(Vector2(library.inside().x, library.inside().z)) < 1.5, "(b) Anon stands in Golden Oak Library (%s)" % str(feet))
	var stamped_doc := checkpoint("scn-example", 22, state.scenario)
	check(SCENARIO.of_doc({"context": {"scenario": state.scenario}}).get("id") == "example_scenario", "(b) a checkpoint's context carries the stamp")
	var scenario_slot: String = await save_into(example, stamped_doc)
	var scenario_meta: Variant = FILE.parse(CATALOGUE.meta_path(scenario_slot), 65536)
	check(scenario_meta is Dictionary and scenario_meta.get("scenario") == "example_scenario" and scenario_meta.get("scenario_name") == "Example Scenario", "(b) the save header carries the scenario (%s)" % str(scenario_meta))
	reset_staging()
	check(SAVES.stage(entry_for(scenario_slot)) and SAVES.last_problem == "", "(b) its own save loads while the mod runs")
	reset_staging()

	# (c) The scenario save with the mod off: refused everywhere, greyed in the browser, untouched.
	boot(none_dir)
	var before_bytes := FileAccess.get_file_as_bytes(scenario_slot)
	check(not SAVES.stage(entry_for(scenario_slot)) and SAVES.last_problem == NEEDS, "(c) title Continue / Load game refuses it: '%s'" % SAVES.last_problem)
	reset_staging()
	var ingame := Checkpoints.new(); example.add_child(ingame)
	ingame.setup(example, "user://worlds/scn-example/saves")
	check(not ingame.load_save(scenario_slot) and ingame.message == NEEDS + ".", "(c) in-game load and F8 refuse it: '%s'" % ingame.message)
	var elsewhere := Checkpoints.new(); vanilla.add_child(elsewhere)
	elsewhere.setup(vanilla, "user://worlds/scn-vanilla/saves")
	check(not elsewhere.load_world_save(entry_for(scenario_slot)) and elsewhere.message == NEEDS + ".", "(c) loading it from another world refuses it: '%s'" % elsewhere.message)
	reset_staging()
	SAVES.pending = FILE.parse(scenario_slot, 1 << 24)
	var resumed: Dictionary = ingame.take_resume()
	check(resumed.is_empty() and ingame.scenario_block == NEEDS, "(c) the resume is refused, not applied ('%s')" % ingame.scenario_block)
	var archived := Array(DirAccess.get_files_at("user://worlds/scn-example/saves/archive")).filter(func(f: String) -> bool: return f.contains("not_resumed"))
	check(FileAccess.file_exists(scenario_slot) and FileAccess.get_file_as_bytes(scenario_slot) == before_bytes and archived.is_empty(), "(c) the save is neither moved nor rewritten (%s)" % str(archived))
	reset_staging()
	check(SCENARIO.entry_block(entry_for(scenario_slot)) == NEEDS, "(c) the browser's header read gives the reason")
	var card: Dictionary = await browser_card(scenario_slot, "scn-example")
	check(bool(card.get("found", false)) and float(card.get("alpha", 1.0)) < 0.7 and str(card.get("tip", "")) == NEEDS, "(c) the browser shows its card greyed with the reason (%s)" % str(card))
	check(bool(card.get("page_load_off", false)), "(c) and its Load button is off")
	starting.clear()
	check(str(SCENARIO.begin_world(example, false)) == NEEDS, "(c) game.gd would not enter that world (--world-id)")
	check(starting.is_empty(), "(c) and Mods.world_starting does not fire for a world that is not entered (%s)" % str(starting))

	# (d) A vanilla save with the scenario on: refused with 'Turn off ...'.
	boot(example_dir)
	reset_staging()
	check(not SAVES.stage(entry_for(vanilla_slot)) and SAVES.last_problem == TURN_OFF, "(d) a vanilla save is refused: '%s'" % SAVES.last_problem)
	reset_staging()
	var vanilla_saves := Checkpoints.new(); vanilla.add_child(vanilla_saves)
	vanilla_saves.setup(vanilla, "user://worlds/scn-vanilla/saves")
	check(not vanilla_saves.load_save(vanilla_slot) and vanilla_saves.message == TURN_OFF + ".", "(d) in-game load and F8 refuse it: '%s'" % vanilla_saves.message)
	reset_staging()
	check(SCENARIO.entry_block(entry_for(vanilla_slot)) == TURN_OFF, "(d) the browser greys it with 'Turn off ...'")
	card = await browser_card(vanilla_slot, "scn-vanilla")
	check(bool(card.get("found", false)) and float(card.get("alpha", 1.0)) < 0.7 and bool(card.get("page_load_off", false)), "(d) its card is greyed and Load is off (%s)" % str(card))
	check(str(SCENARIO.begin_world(vanilla, false)) == TURN_OFF, "(d) game.gd would not enter the vanilla world")

	# (e) Two scenario mods switched on: the first in load order runs, the other is held.
	DirAccess.copy_absolute(built, two_dir.path_join("example_scenario.pck"))
	pack(two_dir.path_join("z_second.pck"), {"res://mods/second_scenario/mod.json": JSON.stringify({"id": "second_scenario", "name": "Second", "version": "1.0.0",
		"scenario": {"id": "second_scenario", "name": "Second Scenario"}})})
	boot(two_dir)
	var rows := LOADER.pack_rows()
	var second := {}; var first := {}
	for row: Dictionary in rows:
		if row.file == "z_second.pck": second = row
		if row.file == "example_scenario.pck": first = row
	check(first.get("enabled") == true and (first.get("scenario", {}) as Dictionary).get("id") == "example_scenario", "(e) the first scenario mod runs (%s)" % str(first.get("scenario")))
	check(second.get("enabled") == false and second.get("held") == true and second.get("scenario_held") == true and str(second.get("reason", "")).contains("Only one scenario mod runs"), "(e) the second is held with a reason (%s)" % str(second.get("reason")))
	check(SCENARIO.active_scenario().get("id") == "example_scenario" and LOADER.active().filter(func(m: Dictionary) -> bool: return not (m.get("scenario", {}) as Dictionary).is_empty()).size() == 1, "(e) exactly one scenario is active")
	var page: Control = load("res://world/ui/settings_page.gd").new()
	var notes := str(page.call("_mod_notes", second))
	check(notes.contains("Only one scenario") and notes.contains("Scenario: Second Scenario") and not notes.contains("loads the next time"), "(e) Settings says why (%s)" % notes.c_escape())
	check(mods != null and not mods.call("switch", "z_second.pck", true), "(e) a scenario switch never applies mid-game")
	var note := str(page.call("_one_scenario_switch", second, true))
	check(not LOADER.switched_on("example_scenario.pck") and LOADER.switched_on("z_second.pck") and note.contains("Switched off Example Scenario"), "(e) switching one on switches the other off, with a note (%s)" % note)
	page.free()
	LOADER.set_enabled("example_scenario.pck", true)

	# (f) Old saves without the field are vanilla.
	var old_doc: Dictionary = checkpoint("scn-old", 5, {})
	old_doc.erase("summary")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://worlds/scn-old/saves"))
	var old_path := "user://worlds/scn-old/saves/slot_1.json"
	check(FILE.write(old_path, old_doc) == OK and not FileAccess.file_exists(CATALOGUE.meta_path(old_path)), "(f) an old-style save without a header is on disk")
	boot(none_dir)
	reset_staging()
	check(SCENARIO.of_doc(old_doc).is_empty() and SCENARIO.entry_block(entry_for(old_path)) == "" and SAVES.stage(entry_for(old_path)), "(f) it loads as vanilla with no scenario mod")
	reset_staging()
	boot(example_dir)
	check(SCENARIO.entry_block(entry_for(old_path)) == TURN_OFF and not SAVES.stage(entry_for(old_path)), "(f) and counts as vanilla while a scenario runs")
	reset_staging()

	# A scenario with a start node and no skip_opening holds the opening until it finishes.
	pack(hold_dir.path_join("hold.pck"), {"res://mods/hold_scenario/mod.json": JSON.stringify({"id": "hold_scenario", "name": "Hold", "version": "0.1.0",
		"scenario": {"id": "hold_scenario", "name": "Hold Scenario", "start": "res://mods/hold_scenario/start.gd"}}),
		"res://mods/hold_scenario/start.gd": "extends Node\nsignal finished\nvar seen := []\nfunc prepare(game: Node, resumed: bool) -> void:\n\tseen = [game.name, resumed]\n"})
	boot(hold_dir)
	var held := host_for("scn-hold")
	started = start_world(held, true, arrival_script)
	var hold_start: Node = started.start
	check(hold_start != null and hold_start.get("seen") == [held.name, false], "prepare(game, resumed=false) runs on the new world")
	check(held.arrival.stage() == "wake" and bool(held.arrival.get("_opening_held")), "the forest opening waits for the start node")
	if hold_start != null: hold_start.emit_signal("finished")
	check(not bool(held.arrival.get("_opening_held")), "and goes on once it finishes")
	var again := start_world(held, false, arrival_script)
	check(again.start != null and (again.start as Node).get("seen") == [held.name, true], "a continued world of the scenario gets prepare(game, resumed=true)")

	# The scripts that call the scenario rules compile (the full game boot is not run here).
	for path: String in ["res://world/game.gd", "res://world/ui/title_screen.gd", "res://world/ui/save_menu.gd"]:
		var compiled := load(path) as GDScript
		check(compiled != null and compiled.can_instantiate(), "%s compiles" % path)
	check((load("res://world/game.gd") as GDScript).get_script_constant_map().get("SCENARIO") == SCENARIO, "game.gd uses these scenario rules")
	print("SCENARIO_MODS_DONE ", "PASS" if failures == 0 else "FAIL", " checks=", checks, " failures=", failures)
	for host: Node in [vanilla, example, held]:
		host.world_context.flush(); host.queue_free()
	library.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
