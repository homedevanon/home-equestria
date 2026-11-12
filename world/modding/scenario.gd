extends RefCounted
## Scenario mods (dev 2026-11-08, M-MOD-10; an anon is building a Nightmare Moon alternate start).
## A mod may declare in its mod.json one "scenario" that changes how a NEW world starts:
##   "scenario": {
##     "id": "nightmare_moon",                          ^[a-z0-9_]{1,40}$
##     "name": "Nightmare Moon",                        what menus call it ("Needs the Nightmare Moon mod")
##     "start": "res://mods/<mod id>/start.gd",         optional Node script (API below)
##     "skip_opening": true,                            optional: no forest opening, no tutorial
##     "initial_state": "res://mods/<mod id>/initial_state.json",   optional, deep-merged into context.state
##     "description": "..."}
## Rules (dev decision 2026-11-08):
## - At most one scenario mod runs. Settings → Mods switches the other scenario mods off when one is
##   switched on; a boot with two switched on keeps the first in load order and holds the rest
##   (world/modding/mod_loader.gd _one_scenario()). Scenario mods apply at the next launch only.
## - A new world started while a scenario runs is stamped: world_context.state.scenario =
##   {id, name, version, mod}. Every checkpoint carries the stamp (world/game_saves.gd snapshot()
##   "scenario", and the menu header sidecar "scenario" / "scenario_name"), so menus need no full parse.
## - A scenario save loads only while that scenario mod runs ("Needs the <Name> mod"); a vanilla save
##   (no stamp: every save made before this existed) loads only while no scenario mod runs ("Turn off
##   the <Name> mod to load this"). Incompatible saves are greyed out in the save browser with that
##   reason, never hidden, moved, deleted or rewritten.
##
## The start node API (documented for modders in res://mods/README.md "Scenario mods"):
##   extends Node
##   signal finished                                    emit once the start is done
##   func prepare(game: Node, resumed: bool) -> void    called under the loading cover, every time a
##                                                      world of this scenario starts (resumed = a
##                                                      continued world, false = brand new)
## It is added as the game's child "ScenarioStart" right after the arrival story is prepared, so
## `game.arrival` exists (its scenario hooks: end_opening(), place_player(), skip_to_free_home(),
## place_at_golden_oak()). With skip_opening the arrival story ends at once, with no forest; without
## it, on a new world the forest opening waits until `finished` (arrival_story.gd hold_opening()).
## await Scenario.loaded(node) waits until the loading screen is gone.
## No class_name (load by path): preload("res://world/modding/scenario.gd").
## Only the loader is preloaded: mod_loader.gd reads mod.json scenarios through this script at
## boot, before mods extend game scripts, so nothing else may be cached here that early.
const LOADER := preload("res://world/modding/mod_loader.gd")
const SAVE_FILE_PATH := "res://world/save_file.gd"
const SHUTDOWN_PATH := "res://world/shutdown_waits.gd"
const ID_PATTERN := "^[a-z0-9_]{1,40}$"
## world_context.state key of the stamp; checkpoint key (game_saves.gd) is the same.
const STATE_KEY := "scenario"
const START_NAME := "ScenarioStart"
## initial_state may not replace the world context's own bookkeeping (or the stamp itself).
const RESERVED := ["version", "world_id", "revision", "scenario"]
## Header sidecar keys (world/saves/save_catalogue.gd .preview.meta) written by game_saves.gd.
const HEADER_ID := "scenario"
const HEADER_NAME := "scenario_name"
## Largest initial_state file read.
const MAX_INITIAL_BYTES := 1 << 20
## Set when the game refused to enter a world (game.gd _leave_for_title()); the title shows it once.
static var notice := ""

## Parses a mod.json "scenario" value for mod `mod_id`: {scenario: Dictionary (empty when absent),
## error: String ("" when fine)}. Paths must be inside the mod's own folder.
static func parse(value: Variant, mod_id: String) -> Dictionary:
	if value == null: return {"scenario": {}, "error": ""}
	if not value is Dictionary: return {"scenario": {}, "error": "scenario must be an object like {\"id\": \"my_start\", \"name\": \"My start\"}"}
	var doc: Dictionary = value
	var id := str(doc.get("id", "")) if doc.get("id") is String else ""
	if RegEx.create_from_string(ID_PATTERN).search(id) == null:
		return {"scenario": {}, "error": "scenario id must be 1-40 lower-case letters, digits or _"}
	var out := {"id": id, "name": id, "start": "", "skip_opening": false, "initial_state": "", "description": ""}
	for key: String in ["name", "description"]:
		if not doc.has(key): continue
		if not doc[key] is String: return {"scenario": {}, "error": "scenario %s must be text" % key}
		if not str(doc[key]).strip_edges().is_empty(): out[key] = str(doc[key]).strip_edges()
	if doc.has("skip_opening"):
		if not doc.skip_opening is bool: return {"scenario": {}, "error": "scenario skip_opening must be true or false"}
		out.skip_opening = bool(doc.skip_opening)
	var own := "res://mods/%s/" % mod_id
	for key: String in ["start", "initial_state"]:
		if not doc.has(key) or (doc[key] is String and str(doc[key]).is_empty()): continue
		if not doc[key] is String or not str(doc[key]).begins_with(own) or str(doc[key]).contains(".."):
			return {"scenario": {}, "error": "scenario %s must be a path inside %s" % [key, own]}
		if not ResourceLoader.exists(str(doc[key])) and not FileAccess.file_exists(str(doc[key])):
			return {"scenario": {}, "error": "scenario %s %s is missing" % [key, doc[key]]}
		out[key] = str(doc[key])
	return {"scenario": out, "error": ""}

## The scenario of the scenario mod that runs this launch, {} when none: {id, name, version, mod,
## start, skip_opening, initial_state, description}.
static func active_scenario() -> Dictionary:
	for mod: Dictionary in LOADER.active():
		var found := _of_mod(mod)
		if not found.is_empty(): return found
	return {}

## Every installed scenario mod (on or off), for names in menus.
static func installed() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for mod: Dictionary in LOADER.mods:
		var found := _of_mod(mod)
		if not found.is_empty(): out.append(found)
	return out

static func _of_mod(mod: Dictionary) -> Dictionary:
	var scenario: Variant = mod.get("scenario")
	if not scenario is Dictionary or (scenario as Dictionary).is_empty(): return {}
	var out: Dictionary = (scenario as Dictionary).duplicate()
	out.version = str(mod.get("version", "")); out.mod = str(mod.get("id", ""))
	return out

## The name menus use for scenario `id`: the installed mod's, else `fallback`, else the id.
static func name_for(id: String, fallback := "") -> String:
	for found: Dictionary in installed():
		if found.id == id: return str(found.name)
	return fallback if not fallback.is_empty() else id

## Whether a save of scenario `save_id` ("" = vanilla) may load this launch: {ok, reason}. The
## reason is the plain line menus show.
static func compatible(save_id: String, save_name := "") -> Dictionary:
	var running := active_scenario()
	var running_id := str(running.get("id", ""))
	if save_id == running_id: return {"ok": true, "reason": ""}
	if not save_id.is_empty(): return {"ok": false, "reason": "Needs the %s mod" % name_for(save_id, save_name)}
	return {"ok": false, "reason": "Turn off the %s mod to load this" % str(running.name)}

## The stamp of a checkpoint document or a world context state: {id, name} or {} (vanilla).
static func of_doc(doc: Variant) -> Dictionary:
	if not doc is Dictionary: return {}
	var stamp: Variant = doc.get(STATE_KEY)
	if not stamp is Dictionary and doc.get("context") is Dictionary: stamp = doc.context.get(STATE_KEY)
	return _clean_stamp(stamp)

static func _clean_stamp(stamp: Variant) -> Dictionary:
	if not stamp is Dictionary or not stamp.get("id") is String: return {}
	var id := str(stamp.id)
	if RegEx.create_from_string(ID_PATTERN).search(id) == null: return {}
	var title := str(stamp.get("name", id)) if stamp.get("name") is String else id
	return {"id": id, "name": title.left(80)}

## compatible() for a parsed checkpoint document.
static func check_doc(doc: Variant) -> Dictionary:
	var stamp := of_doc(doc)
	return compatible(str(stamp.get("id", "")), str(stamp.get("name", "")))

## Adds the stamp to a checkpoint's menu header (world/saves/save_catalogue.gd header_from_doc()).
## Vanilla saves get "" so a header written by this build always says which it is.
static func stamp_header(header: Dictionary, doc: Dictionary) -> Dictionary:
	var stamp := of_doc(doc)
	header[HEADER_ID] = str(stamp.get("id", "")); header[HEADER_NAME] = str(stamp.get("name", ""))
	return header

## The stamp of a save listed by the catalogue, from its header only: the entry's own "scenario"
## when the catalogue carries it, else the .preview.meta sidecar game_saves.gd wrote with it. A
## header without the key (older builds, a header rebuilt by the catalogue) is vanilla; loading
## still checks the full document (game_saves.gd scenario_problem()).
static func of_entry(entry: Dictionary) -> Dictionary:
	if entry.has(HEADER_ID) and entry[HEADER_ID] is String:
		return _clean_stamp({"id": entry[HEADER_ID], "name": entry.get(HEADER_NAME, "")}) if not str(entry[HEADER_ID]).is_empty() else {}
	var path := str(entry.get("path", ""))
	if path.is_empty(): return {}
	var save_file: Variant = load(SAVE_FILE_PATH)
	var meta: Variant = save_file.parse(path.get_basename() + ".preview.meta", 64 * 1024)
	if not meta is Dictionary or not meta.get(HEADER_ID) is String or str(meta[HEADER_ID]).is_empty(): return {}
	return _clean_stamp({"id": meta[HEADER_ID], "name": meta.get(HEADER_NAME, "")})

## Why the save browser greys out a catalogue entry ("" when it can load this launch).
static func entry_block(entry: Dictionary) -> String:
	var stamp := of_entry(entry)
	return str(compatible(str(stamp.get("id", "")), str(stamp.get("name", ""))).reason)

# ------------------------------------------------------------------ world start
## world/game.gd, before the arrival story is created: a new world started while a scenario runs is
## stamped and gets the scenario's initial_state; Mods.world_starting(game, is_new) is emitted for
## every world that is entered. Returns why this world cannot be played this launch ("" when it can): a continued
## world whose stamp does not match the running scenario (the menus refuse such saves first).
static func begin_world(game: Node, is_new: bool) -> String:
	var context: Node = game.get("world_context")
	var running := active_scenario()
	var block := ""
	if context != null:
		if is_new and not running.is_empty(): stamp_world(context, running)
		elif not is_new: block = str(check_doc(context.get("state")).reason)
	# Only for a world that is entered: a refused one goes back to the title without world_ready.
	var mods: Node = game.get_node_or_null("/root/Mods") if game.is_inside_tree() and block.is_empty() else null
	if mods != null and mods.has_signal("world_starting"): mods.emit_signal("world_starting", game, is_new)
	return block

## Stamps a world context with `scenario` and merges its initial_state (once, for a new world).
static func stamp_world(context: Node, scenario: Dictionary) -> void:
	if context.get("_read_only") == true: return
	var state: Dictionary = context.get("state")
	var initial := str(scenario.get("initial_state", ""))
	if not initial.is_empty():
		var file := FileAccess.open(initial, FileAccess.READ)
		var text := file.get_buffer(mini(file.get_length(), MAX_INITIAL_BYTES)).get_string_from_utf8() if file != null else ""
		var data: Variant = LOADER.parse(text)
		if data is Dictionary:
			var merged: Dictionary = state.duplicate(true)
			for key: Variant in data:
				if str(key) in RESERVED: push_warning("[scenario] %s: initial_state may not set \"%s\"" % [scenario.id, key]); continue
				merged[key] = LOADER.deep_merge(merged.get(key), data[key])
			if context.has_method("_valid_state") and not context.call("_valid_state", merged, str(state.get("world_id", ""))):
				push_warning("[scenario] %s: initial_state would make the world unreadable; not applied" % scenario.id)
			else:
				state.merge(merged, true)
		else: push_warning("[scenario] %s: %s is not a JSON object; not applied" % [scenario.id, initial])
	state[STATE_KEY] = {"id": str(scenario.id), "name": str(scenario.name), "version": str(scenario.get("version", "")), "mod": str(scenario.get("mod", ""))}
	if context.has_method("_changed"): context.call("_changed")
	print("[scenario] new world stamped: %s (%s %s)" % [scenario.id, scenario.get("mod", ""), scenario.get("version", "")])

## world/game.gd, right after the arrival story is prepared: the scenario's start node (when it
## has one) for a world of this scenario, and the opening per skip_opening on a new world.
## Returns the start node or null.
static func start_world(game: Node, arrival: Node, is_new: bool) -> Node:
	var running := active_scenario()
	if running.is_empty(): return null
	var context: Node = game.get("world_context")
	if context == null or str(of_doc(context.get("state")).get("id", "")) != str(running.id): return null
	if is_new and bool(running.skip_opening) and arrival != null and arrival.has_method("end_opening"):
		arrival.call("end_opening", "scenario " + str(running.id))
	var path := str(running.get("start", ""))
	if path.is_empty(): return null
	var script := load(path) as Script
	var node: Variant = script.new() if script != null and script.can_instantiate() else null
	if not node is Node:
		push_warning("[scenario] %s: start %s is not a Node script" % [running.id, path]); return null
	var start: Node = node
	start.name = START_NAME
	game.add_child(start)
	var hold: bool = is_new and not bool(running.skip_opening) and arrival != null and arrival.has_method("hold_opening") and start.has_signal("finished")
	if hold:
		arrival.call("hold_opening", true)
		start.connect("finished", func() -> void: if is_instance_valid(arrival): arrival.call("hold_opening", false), CONNECT_ONE_SHOT)
	if start.has_method("prepare"): start.call("prepare", game, not is_new)
	print("[scenario] %s start node %s (%s)" % [running.id, path, "resumed" if not is_new else "new world"])
	return start

## Waits until the world has loaded and the loading screen is gone (false when leaving the world).
static func loaded(node: Node) -> bool:
	var game: Node = node.get_parent()
	while game != null and game.get("world_context") == null: game = game.get_parent()
	var waits: Variant = load(SHUTDOWN_PATH)
	while node.is_inside_tree():
		if game == null or not is_instance_valid(game) or game.get_node_or_null("LoadingCover") == null: return true
		if not await waits.frame(node): return false
	return false
