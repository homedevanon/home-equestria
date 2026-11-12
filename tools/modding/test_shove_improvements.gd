extends SceneTree
## devanon's "shove improvements" patch pack for Anon's Tease & Discomfort Shove (W2-SHOVE-PATCH,
## M-MOD-12, MOD-09). Mounts the author's tease_shove 2.2.1 pack (unchanged) and the patch pack from
## a test bundled folder through the real loader (bundled_mods.json, patches, depends, extends), then
## feeds fixture replies through the evaluator with a stand-in director, player and ponies:
## tools/modding/fixtures/shove/ordinary.json (50 ordinary exchanges: nobody may shove) and
## teases.json (teases, insults, pushback, Rainbow Crash, cooldowns; expected result per shove
## setting). Each case runs in all three of the author's settings, first through his own evaluator
## (the script under the patch, "before") and then through the patched one ("after"); it prints the
## false-trigger rate of both. Only "after" is checked. Optional `--old-source FILE` also measures the
## 2.0.0 main.gd text (one setting). `--build-patch` first rebuilds the patch pack from its source
## (fixtures/shove/build_patch.gd). The packs: `--tease-pack FILE` (default
## ../bundled_mods/tease_shove/tease_shove.pck), `--patch-pack FILE` (default
## ../bundled_mods/shove_improvements/shove_improvements.pck).
##   XDG_DATA_HOME=<scratch>/mod-shove-test python3 tools/run_owned_godot.py --project home-equestria-public \
##       --wait-for-slot 1800 --expect SHOVE_IMPROVEMENTS_DONE --log LOG res://tools/modding/test_shove_improvements.gd \
##       --arg=--tease-pack --arg=<tease_shove 2.2.1 pck>
const LOADER := preload("res://world/modding/mod_loader.gd")
const BUILDER := preload("res://tools/modding/fixtures/shove/build_patch.gd")
const FIXTURES := "res://tools/modding/fixtures/shove/"
const MODES: Array[String] = ["a_lot", "normal", "sometimes"]
const TEASE_VERSION := "2.2.1"
## id -> [name, position]; Anon stands at the origin.
const PONIES := {
	"twilight_sparkle": ["Twilight Sparkle", Vector3(1.5, 0, 0)],
	"fluttershy": ["Fluttershy", Vector3(0, 0, 1.6)],
	"rainbow_dash": ["Rainbow Dash", Vector3(-1.8, 0, 0)],
	"rarity": ["Rarity", Vector3(0, 0, -1.7)],
	"applejack": ["Applejack", Vector3(1.2, 0, 1.2)],
	"pinkie_pie": ["Pinkie Pie", Vector3(-1.2, 0, -1.2)],
}

const PONY_SOURCE := "extends CharacterBody3D\nvar identity := {}\nvar sleeping := false\nvar boop_node: Node = null\n"
const BOOP_SOURCE := "extends Node\nvar blush_amount := 0.0\n"
const DIRECTOR_SOURCE := """extends Node
signal reply(character_id: String, text: String)
signal transcript(text: String)
var characters := {}
var world_context: Variant = null
var _player_text := ""
var _pending_impression: Dictionary = {}
var _current := ""
var _listener_id := ""
var _proactive_turn := false
var _physical_context := ""
"""
const IMPRESSIONS_SOURCE := "extends Node\nsignal changed(id: String)\nvar notes := {}\n"

var failures := 0
var checks := 0
var player: CharacterBody3D
var ponies := {}
var director: Node
var impressions: Node

func _initialize() -> void: run.call_deferred()

func check(ok: bool, text: String) -> void:
	checks += 1
	print("[shove] ", "PASS " if ok else "FAIL ", text)
	if not ok: failures += 1

func script_from(source: String) -> GDScript:
	var script := GDScript.new()
	script.source_code = source
	script.reload()
	return script

func mod_of(id: String) -> Dictionary:
	for mod: Dictionary in LOADER.mods:
		if mod.id == id: return mod
	return {}

func row_of(file: String) -> Dictionary:
	for row: Dictionary in LOADER.pack_rows():
		if row.file == file: return row
	return {}

func cases(name: String) -> Array:
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURES + name))
	return (doc as Dictionary).get("cases", []) if doc is Dictionary else []

func finish() -> void:
	print("SHOVE_IMPROVEMENTS_DONE %s %d/%d" % ["PASS" if failures == 0 else "FAIL", checks - failures, checks])
	quit(0 if failures == 0 else 1)

func run() -> void:
	if not OS.get_environment("XDG_DATA_HOME").contains("mod-shove-test"):
		printerr("SHOVE_IMPROVEMENTS_REFUSED requires an isolated XDG_DATA_HOME"); quit(1); return
	var temp := ProjectSettings.globalize_path("user://shove_test")
	var bundled := temp.path_join("bundled")
	var empty := temp.path_join("none")
	for dir: String in [bundled, empty]: DirAccess.make_dir_recursive_absolute(dir)
	var root := ProjectSettings.globalize_path("res://")
	var tease_pack := BUILDER.arg("--tease-pack", root.path_join("../bundled_mods/tease_shove/tease_shove.pck").simplify_path())
	var patch_pack := BUILDER.arg("--patch-pack", BUILDER.default_out())
	if OS.get_cmdline_user_args().has("--build-patch"):
		var error := BUILDER.build(BUILDER.arg("--patch-src", BUILDER.default_src()), patch_pack)
		check(error.is_empty(), "patch pack built from its source (%s)" % error)
	if not FileAccess.file_exists(tease_pack) or not FileAccess.file_exists(patch_pack):
		check(false, "packs present: %s, %s" % [tease_pack, patch_pack]); finish(); return

	# ---- the bundled folder, as the release stages it: the author's pack, then the patch pack
	DirAccess.copy_absolute(tease_pack, bundled.path_join("tease_shove.pck"))
	DirAccess.copy_absolute(patch_pack, bundled.path_join("shove_improvements.pck"))
	var manifest := {"format": 1, "mods": [
		{"id": "tease_shove", "title": "Tease & Discomfort Shove", "author": "Anon", "version": TEASE_VERSION,
			"file": "tease_shove.pck", "sha256": FileAccess.get_sha256(bundled.path_join("tease_shove.pck")),
			"default_on": true, "source_url": "https://example.invalid/tease_shove", "order": 100},
		{"id": "shove_improvements", "title": "Shove improvements from devanon", "author": "devanon", "version": "1.0.1",
			"file": "shove_improvements.pck", "sha256": FileAccess.get_sha256(bundled.path_join("shove_improvements.pck")),
			"default_on": true, "source_url": "", "order": 101, "patches": {"tease_shove": TEASE_VERSION}}]}
	var file := FileAccess.open(bundled.path_join("bundled_mods.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(manifest, "\t")); file.close()
	LOADER.boot([empty], [empty], PackedStringArray(), bundled)

	var parent_row := row_of("bundled/tease_shove.pck")
	var patch_row := row_of("bundled/shove_improvements.pck")
	check(bool(parent_row.get("mounted", false)) and str(parent_row.get("version", "")) == TEASE_VERSION, "the author's tease_shove %s mounts unchanged (%s)" % [TEASE_VERSION, str(parent_row.get("reason", ""))])
	check(bool(patch_row.get("mounted", false)) and str(patch_row.get("patch_of", "")) == "bundled/tease_shove.pck", "the patch pack mounts right after it as its patch (%s)" % str(patch_row.get("reason", "")))
	var tease_mod := mod_of("tease_shove")
	var patch_mod := mod_of("shove_improvements")
	check(not tease_mod.is_empty() and (tease_mod.errors as Array).is_empty(), "tease_shove runs (%s)" % str(tease_mod.get("errors", [])))
	check(not patch_mod.is_empty() and (patch_mod.errors as Array).is_empty() and str(patch_mod.author) == "devanon" and str(patch_mod.name) == "Shove improvements from devanon",
		"shove_improvements runs: depends and patches satisfied (%s)" % str(patch_mod.get("errors", [])))
	var patched := load(str(tease_mod.get("entry", ""))) as Script
	var author: Script = patched.get_base_script() if patched != null else null
	check(patched != null and patched.get_script_constant_map().get("LOG", true) == false, "the author's entry path now runs the patch, logs off by default")
	check(author != null and not author.get_script_constant_map().has("LOG") and author.get_script_constant_map().get("MODE_A_LOT", "") == "a_lot",
		"the author's own script stands under it")
	var patch_text := FileAccess.get_file_as_string("res://mods/shove_improvements/main_patch.gd")
	if patched != null:
		var probe: Node = patched.new()
		check(str(probe.call("_mode_help", "sometimes")).contains("outright insult") and str(probe.call("_mode_help", "a_lot")).contains("devanon"), "his Settings tab describes the patched settings")
		probe.free()
	check(not patch_text.is_empty() and not patch_text.contains("func _process") and not patch_text.contains("func _physics_process") and not patch_text.contains("func _input"),
		"the patch adds no per-frame callbacks")
	if patched == null or author == null: finish(); return

	_build_world()
	var ordinary := cases("ordinary.json")
	var teases := cases("teases.json")
	check(ordinary.size() == 50 and teases.size() >= 10, "fixtures: %d ordinary, %d tease cases" % [ordinary.size(), teases.size()])

	# ---- before: the author's evaluator (2.2.1, and 2.0.0 when its text is given)
	var before := _spawn(author)
	for mode: String in MODES:
		var fired := PackedStringArray()
		for c: Dictionary in ordinary:
			if _run_case(before, c, mode): fired.append(str(c.reply).left(40))
		print("[shove] BEFORE 2.2.1 %s: %d/50 ordinary exchanges shove (%d%%): %s" % [mode, fired.size(), fired.size() * 2, " | ".join(fired)])
	var old_source := BUILDER.arg("--old-source", "")
	if not old_source.is_empty() and FileAccess.file_exists(old_source):
		var old := _spawn(script_from(FileAccess.get_file_as_string(old_source)))
		var fired_old := 0
		for c: Dictionary in ordinary:
			if _run_case(old, c, "a_lot"): fired_old += 1
		print("[shove] BEFORE 2.0.0: %d/50 ordinary exchanges shove (%d%%)" % [fired_old, fired_old * 2])
		old.queue_free()
	before.queue_free()

	# ---- after: the patched evaluator
	var node := _spawn(patched)
	for mode: String in MODES:
		var fired := 0
		for c: Dictionary in ordinary:
			var shoved := _run_case(node, c, mode)
			if shoved:
				fired += 1
				check(false, "%s: no shove for \"%s\" -> \"%s\" (%s)" % [mode, c.said, c.reply, str(node.get("last_decision"))])
		print("[shove] AFTER %s: %d/50 ordinary exchanges shove (%d%%)" % [mode, fired, fired * 2])
		check(fired == 0, "%s: none of the 50 ordinary exchanges shoves" % mode)
	for mode: String in MODES:
		node.set("_cooldowns", {})
		for c: Dictionary in teases:
			var want := bool((c.expect as Dictionary)[mode])
			var shoved := _run_case(node, c, mode)
			var decision: Dictionary = node.get("last_decision")
			var ok := shoved == want
			if ok and shoved and c.has("heavy"):
				ok = str(decision.get("why", "")).begins_with("hard") == bool(c.heavy)
			check(ok, "%s: %s -> %s (%s)" % [mode, c.name, "shove" if shoved else "no shove", str(decision.get("why", ""))])

	# ---- one shove carried out to the end: the wind-up, then Anon slides back
	node.set("_cooldowns", {})
	var start := player.global_position
	var first: Dictionary = teases[0]
	check(_run_case(node, first, "a_lot", true), "a tease starts a shove")
	var frames := 0
	while frames < 240 and (not (node.get("_pending") as Dictionary).is_empty() or not (node.get("_shove") as Dictionary).is_empty()):
		await physics_frame
		frames += 1
	var moved := Vector2(player.global_position.x - start.x, player.global_position.z - start.z).length()
	check(moved > 0.2 and frames < 240, "the shove runs through: Anon moved %.2f m in %d physics frames" % [moved, frames])
	node.queue_free()
	await process_frame
	finish()

func _build_world() -> void:
	player = CharacterBody3D.new()
	player.name = "ShoveTestPlayer"
	root.add_child(player)
	director = script_from(DIRECTOR_SOURCE).new()
	root.add_child(director)
	impressions = script_from(IMPRESSIONS_SOURCE).new()
	root.add_child(impressions)
	var pony_script := script_from(PONY_SOURCE)
	var boop_script := script_from(BOOP_SOURCE)
	var chars := {}
	for id: String in PONIES:
		var pony: CharacterBody3D = pony_script.new()
		pony.name = id
		pony.set("identity", {"id": id})
		var boop: Node = boop_script.new()
		pony.add_child(boop)
		pony.set("boop_node", boop)
		root.add_child(pony)
		pony.global_position = PONIES[id][1]
		ponies[id] = pony
		chars[id] = {"node": pony, "profile": {"name": PONIES[id][0]}}
	chars["apple_bloom"] = {"node": null, "profile": {"name": "Apple Bloom"}}
	chars["big_mcintosh"] = {"node": null, "profile": {"name": "Big McIntosh"}}
	chars["twilight_velvet"] = {"node": null, "profile": {"name": "Twilight Velvet"}}
	director.set("characters", chars)

func _spawn(script: Script) -> Node:
	var node: Node = script.new()
	root.add_child(node)
	node.set("_director", director)
	node.set("_impressions", impressions)
	node.set("_player", player)
	return node

## Runs one fixture case on `node` in `mode`; true when a shove started for the pony (his wind-up,
## `_pending`, names her). `run_out` keeps that wind-up so the shove can play out.
func _run_case(node: Node, c: Dictionary, mode: String, run_out := false) -> bool:
	node.set("_mode", mode)
	if not bool(c.get("keep_cooldown", false)): node.set("_cooldowns", {})
	node.set("_pending", {}); node.set("_shove", {}); node.set("_last_reply", {})
	node.set("_player_line", ""); node.set("_player_line_at", -1.0e9)
	var pid := str(c.pony)
	if c.has("rainbow_crash"):
		node.call("_on_transcript", str(c.rainbow_crash))
	else:
		var said := str(c.get("said", ""))
		director.set("_current", str(c.get("current", pid)))
		director.set("_listener_id", str(c.get("listener", "player")))
		director.set("_player_text", said)
		director.set("_proactive_turn", bool(c.get("proactive", false)))
		director.set("_physical_context", str(c.get("touch", "")))
		var impression := {}
		if bool(c.get("impression", true)):
			impression = {"friendship": int(c.get("friendship", 0)), "romance": int(c.get("romance", 0))}
			if not str(c.get("mood", "")).is_empty(): impression["mood"] = str(c.mood)
			if not str(c.get("thought", "")).is_empty(): impression["thought"] = str(c.thought)
		director.set("_pending_impression", impression)
		var notes := {}
		if c.get("note") is Dictionary:
			var note: Dictionary = c.note
			var at := Time.get_unix_time_from_system() - float(note.get("age", 0))
			notes[pid] = {"mood": str(note.get("mood", "")), "mood_at": at, "thought": str(note.get("thought", "")), "thought_at": at}
		impressions.set("notes", notes)
		for id: String in ponies:
			((ponies[id] as Node).get("boop_node") as Node).set("blush_amount", float(c.get("blush", 0.0)) if id == pid else 0.0)
		if not said.is_empty():
			node.call("_on_transcript", said)
			node.set("_player_line_at", float(node.call("_now")) - float(c.get("age", 2.0)))
		node.call("_on_reply", pid, str(c.reply))
	var pending: Dictionary = node.get("_pending")
	var shoved := str(pending.get("pid", "")) == pid
	if not run_out: node.set("_pending", {})
	return shoved
