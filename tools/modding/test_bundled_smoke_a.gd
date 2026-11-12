extends SceneTree
## Bundled packs, set A (W2-BUNDLE-SMOKE-A, M-MOD-13, MOD-02..06, MOD-10): grooming, flowing manes,
## idle life, balloon boarding, teleport, princess teleport and pin the tail, each booted alone and
## all together with every other bundled pack, in the real game: the loader mounts the packs from a
## staged bundled-mods folder, the Mods autoload starts their entries, a world loads behind its
## loading cover, the Settings page is built, and then the mods are left unused for 600 physics
## ticks while every node running a mod script is timed (its automatic _process/_physics_process is
## switched off and the same call is made and timed here, once per frame, so the cost is exactly the
## mod's own). Pack-specific checks: grooming's brushes reach the briefcase and fillies or a young
## player never get romance; the briefcase survives the grooming pack being removed (W1-INVENTORY
## parking, checked by a later case on the grooming case's world); flowing manes' shaders are in the
## scene while the loading cover is up (devanon patch); idle life's stretch stays inside
## pony_joint_limits and its pose is removed when the idle ends; princess teleport only runs in debug
## mode (D-36) and never moves a pony to an unchecked spot; pin the tail's prompt note is measured
## and only given near the poster. Each case writes <out>/<case>.json; `--smoke-report` prints the
## per-pack table from those files and the runner logs.
## Staging folders: python3 -I tools/modding/fixtures/smoke_a/make_fixture.py <private root> <fx dir>
## One case (from the private root, isolated data; the runner's GODOT must point at the 4.5 binary):
##   XDG_DATA_HOME=<scratch>/smoke-a-test EQ_CONTEXT_ROOT=<same>/home-equestria-public/worlds \
##   python3 tools/run_owned_godot.py --project home-equestria-public --wait-for-slot 1800 --timeout 900 \
##     --expect SMOKE_A_CASE_DONE --log LOG --arg=--no-ai --arg=--bundled-dir=<fx dir>/<case> \
##     --arg=--smoke-case=<case> --arg=--smoke-out=<out dir> [--arg=--smoke-parked=smoke_a_grooming] \
##     res://tools/modding/test_bundled_smoke_a.gd
## Report: the same with --arg=--smoke-report --arg=--smoke-out=<out dir> --arg=--smoke-logs=<log dir>
## (expect SMOKE_A_REPORT_DONE). Engine errors: none expected from the mods; the runner's count of
## SCRIPT ERROR lines is listed per case against the "none" case (the game's own baseline).
const LOADER := preload("res://world/modding/mod_loader.gd")
const STORE := preload("res://world/inventory/inventory_store.gd")
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const SET_A := ["grooming", "flowing_manes", "idle_life", "balloon_boarding", "teleport", "princess_teleport", "pin_the_tail"]
const TICKS := 600
const MANE_BRUSH := "groom-mane-brush"
## Joint-limit check: further outside a limit than this counts (the game's own poses sit on limits).
const LIMIT_SLACK_DEG := 2.0
const LOGGER_SOURCE := """extends Logger
var errors: Array = []
var lines: Array = []
var lock := Mutex.new()
func _log_error(function: String, file: String, line: int, code: String, rationale: String, editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	lock.lock(); errors.append([error_type, file, line, code, rationale]); lock.unlock()
func _log_message(message: String, error: bool) -> void:
	if message.begins_with("[grooming]") or message.begins_with("[idle_life]") or message.begins_with("[flowing_manes") or message.begins_with("[princess_teleport") or message.begins_with("[teleport]") or message.begins_with("[mods]"):
		lock.lock(); lines.append(message.strip_edges()); lock.unlock()
"""
## A node with a `form` (player_form.gd PONY_FORM_GROUP driver) for the young-player check.
const FORM_SOURCE := "extends Node\nvar form: Dictionary = {}\n"
## Records how far outside pony_joint_limits the drawn pose goes (added after every other modifier).
const LIMIT_PROBE_SOURCE := """extends SkeletonModifier3D
var limits: Variant
var worst := 0.0
var worst_bone := -1
var passes := 0
func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or limits == null: return
	passes += 1
	for bone: int in (limits.joints as Dictionary):
		var q := sk.get_bone_pose_rotation(bone)
		var held: Quaternion = (limits.constrain(bone, Basis(q)) as Basis).get_rotation_quaternion()
		var off := rad_to_deg(q.angle_to(held))
		if off > worst: worst = off; worst_bone = bone
"""
## pin_the_tail knowledge.gd's `game`: a poster, nobody blindfolded.
const PIN_GAME_SOURCE := """extends Node
var poster_node: Node3D
var pony_game: Node
func poster() -> Node3D: return poster_node
func player_blind() -> bool: return false
func player_view() -> Dictionary: return {}
"""
const IDENTITY_SOURCE := "extends Resource\nvar id := \"\"\nvar display_name := \"\"\nvar filly := false\n"

var failures := 0
var checks := 0
var fails: Array = []
var case_name := ""
var out_dir := ""
var result := {}
var logger: Object
var game: Node
var warm_seen_under_cover := false


func _initialize() -> void:
	logger = _from_source(LOGGER_SOURCE, "Logger")
	if logger != null: OS.add_logger(logger)
	run.call_deferred()


func check(ok: bool, text: String) -> void:
	checks += 1
	print("[smoke_a] ", "PASS " if ok else "FAIL ", text)
	if not ok:
		failures += 1
		fails.append(text)


func arg(name: String, fallback := "") -> String:
	for item: String in OS.get_cmdline_user_args():
		if item == "--" + name: return "1"
		if item.begins_with("--" + name + "="): return item.substr(name.length() + 3)
	return fallback


func _from_source(source: String, needs_class := "") -> Object:
	if not needs_class.is_empty() and not ClassDB.class_exists(needs_class): return null
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK: return null
	return script.new()


func run() -> void:
	if not OS.get_environment("XDG_DATA_HOME").contains("smoke-a-test"):
		printerr("SMOKE_A_REFUSED requires an isolated XDG_DATA_HOME containing smoke-a-test"); quit(2); return
	out_dir = arg("smoke-out")
	if out_dir.is_empty(): printerr("SMOKE_A_REFUSED needs --smoke-out=<dir>"); quit(2); return
	DirAccess.make_dir_recursive_absolute(out_dir)
	if arg("smoke-report") == "1":
		report(); return
	case_name = arg("smoke-case", "case")
	result = {"case": case_name, "loader": {}, "idle": {}, "modifiers": {}, "notes": [], "logger": logger != null}
	var expected := _expected_ids()
	result.expected = expected
	_check_loader(expected)
	_check_entries(expected)
	var parked := arg("smoke-parked")
	if not parked.is_empty(): _check_parked(parked, expected.has("grooming"))
	if not await _load_world("smoke_a_" + case_name):
		check(false, "the world finishes loading with %s" % case_name)
		finish(); return
	check(true, "the world finishes loading with %s" % case_name)
	for frame in 90: await process_frame
	await _check_settings_page(expected)
	if expected.has("grooming"): _check_grooming()
	if expected.has("flowing_manes"): _check_flowing_manes()
	if expected.has("pin_the_tail"): _check_pin_the_tail()
	if expected.has("princess_teleport"): _check_princess_teleport()
	if expected.has("teleport"): _check_teleport()
	if expected.has("idle_life"): await _check_idle_life()
	await _idle_probe()
	finish()


# ---------------------------------------------------------------- loader and entries

## Mod ids switched on by the staged manifest (default_on), as the player gets them.
func _expected_ids() -> Array:
	var out: Array = []
	var entries: Array[Dictionary] = preload("res://world/modding/bundled_mods.gd").entries(LOADER.bundled_dir)
	var versions := {}
	for entry: Dictionary in entries: versions[str(entry.id)] = str(entry.version)
	for entry: Dictionary in entries:
		if not bool(entry.default_on): continue
		# A patch made for another version of its mod than the one staged rightly stays off (loader).
		var fits := true
		for parent: String in (entry.patches as Dictionary):
			if versions.has(parent) and str(versions[parent]) != str(entry.patches[parent]):
				fits = false
				result.notes.append("%s patches %s %s but %s is staged: off by design" % [entry.id, parent, entry.patches[parent], versions[parent]])
		if fits: out.append(str(entry.id))
	return out


func _check_loader(expected: Array) -> void:
	var rows := LOADER.pack_rows()
	var by_id := {}
	for mod: Dictionary in LOADER.mods: by_id[str(mod.id)] = mod
	for id: String in expected:
		var mod: Dictionary = by_id.get(id, {})
		var row := {}
		for r: Dictionary in rows:
			if id in (r.ids as Array) or str(r.get("file", "")).ends_with("/" + id + ".pck"): row = r
		var ok := not mod.is_empty() and bool(mod.enabled) and (mod.errors as Array).is_empty() and bool(row.get("mounted", false)) and not bool(row.get("held", false))
		result.loader[id] = {"enabled": bool(mod.get("enabled", false)), "errors": mod.get("errors", ["not found"]), "mounted": row.get("mounted", false),
			"held": row.get("held", false), "reason": row.get("reason", ""), "patch_of": row.get("patch_of", ""), "patched_by": row.get("patched_by", [])}
		check(ok, "%s is mounted and runs (%s)" % [id, str(result.loader[id])])


func _check_entries(expected: Array) -> void:
	var mods := root.get_node_or_null("Mods")
	for mod: Dictionary in LOADER.active():
		if str(mod.entry).is_empty() or str(mod.id) not in expected: continue
		# Named after the mod id by the Mods autoload; some entries rename themselves (PegasusRide).
		var started := mods != null and mods.has_node(NodePath(str(mod.id)))
		if not started and mods != null:
			for child: Node in mods.get_children():
				var script := child.get_script() as Script
				while script != null and not started:
					started = script.resource_path == str(mod.entry)
					script = script.get_base_script()
		check(started, "%s's entry node started" % mod.id)


# ---------------------------------------------------------------- world

func _load_world(world_id: String) -> bool:
	var context: Node = preload("res://world/ai/world_context.gd").new()
	root.add_child(context)
	var opened: bool = context.open_world(world_id, OS.get_environment("EQ_CONTEXT_ROOT"))
	if opened:
		if not context.state.has("arrival"): context.state.arrival = {"stage": "done"}
		context._changed()
		context.flush()
	context.free()
	if not opened: return false
	var settings: Node = root.get_node("Settings")
	settings._values["setup/completed"] = true
	settings._values["ponies/max_nearby"] = 8
	settings._values["video/quality"] = "Low"
	game = load("res://world/main.tscn").instantiate()
	game.context_world_id = world_id
	root.add_child(game)
	current_scene = game
	var deadline := Time.get_ticks_msec() + 240000
	var frame := 0
	while Time.get_ticks_msec() < deadline:
		frame += 1
		if not is_instance_valid(game): return false
		var cover := game.get_node_or_null("LoadingCover")
		if cover != null and frame % 20 == 0 and not warm_seen_under_cover:
			warm_seen_under_cover = game.find_child("FlowingManesWarmup", true, false) != null
		if is_instance_valid(game.get("saves")) and game.saves.ready_to_save and cover == null: return true
		await process_frame
	return false


func _check_settings_page(expected: Array) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var page: Control = load("res://world/ui/settings_page.gd").new()
	layer.add_child(page)
	page.setup(Vector2(1400, 900), 20, "Back")
	for frame in 10: await process_frame
	var texts := PackedStringArray()
	for node: Node in page.find_children("*", "Label", true, false): texts.append((node as Label).text)
	for node: Node in page.find_children("*", "Button", true, false): texts.append((node as Button).text)
	var all := "\n".join(texts)
	for row: Dictionary in LOADER.pack_rows():
		if not bool(row.bundled) or not str(row.patch_of).is_empty(): continue
		if not ((row.ids as Array).any(func(id: Variant) -> bool: return str(id) in expected)): continue
		check(all.contains(str(row.title)), "Settings > Mods lists %s" % row.title)
		for patch: Variant in row.get("patched_by", []):
			var note := str(page.call("_mod_notes", row))
			check(note.contains("devanon"), "Settings > Mods notes %s's patch pack (%s)" % [row.title, note])
	if expected.has("flowing_manes"):
		check(all.contains("Flowing Manes"), "flowing manes adds its own Settings page button")
	result.settings_texts = texts.size()
	layer.queue_free()
	await process_frame


# ---------------------------------------------------------------- grooming (MOD-02)

func _check_grooming() -> void:
	var store: Object = game.inventory.inventory if is_instance_valid(game.get("inventory")) else null
	var found := false
	if store != null:
		for slot: Variant in store.slots:
			if slot is Dictionary and str((slot as Dictionary).get("id", "")).contains(MANE_BRUSH): found = true
	check(found, "grooming put its brushes in the briefcase")
	# Sentinels for the removal case: bits and a known item beside the brushes.
	if store != null:
		store.credit_bits(37)
		store.grant("apple", 2)
		result.sentinel = {"bits": int(store.bits), "path": str(store.save_path)}
	var mod: Node = root.get_node_or_null("Mods/grooming")
	var context: Node = game.get("world_context")
	var bonds: Node = context.get("player_bonds") if context != null else null
	if mod == null or bonds == null:
		check(false, "grooming's reward can be exercised (mod %s, bonds %s)" % [mod, bonds]); return
	bonds.register("apple_bloom", false)
	bonds.register("applejack", true)
	var record: Dictionary = bonds.record_for("applejack")
	record.stage = "dating"
	bonds.call("_save", "applejack", record)
	var adult_tags := _groom_tags(mod, "applejack", "mane")
	var filly_tags := _groom_tags(mod, "apple_bloom", "coat")
	check(adult_tags.contains("friendship") and adult_tags.contains("romance"), "an adult who is fond of Anon gets friendship and love from a grooming (%s)" % adult_tags)
	check(filly_tags.contains("friendship") and not filly_tags.contains("romance"), "a filly gets friendship only (%s)" % filly_tags)
	# A young AnonPony: the bonds' own rule (player_form.gd is_young) takes romance off everypony.
	var driver: Object = _from_source(FORM_SOURCE)
	(driver as Node).set("form", {"kind": "pony", "race": "earth", "sex": "colt", "age": "young", "eyes": "blue"})
	(driver as Node).add_to_group(PLAYER_FORM.PONY_FORM_GROUP)
	root.add_child(driver as Node)
	root.move_child(driver as Node, 0)
	var young := PLAYER_FORM.is_young(PLAYER_FORM.active(self))
	var young_tags := _groom_tags(mod, "applejack", "tail")
	check(young and young_tags.contains("friendship") and not young_tags.contains("romance"), "a young player gets friendship only, even from a mare he is dating (%s)" % young_tags)
	(driver as Node).queue_free()
	result.grooming = {"adult": adult_tags, "filly": filly_tags, "young": young_tags}


## The tags grooming's _reward gives `id` for `tool` (its own log line), with a stand-in pony.
func _groom_tags(mod: Node, id: String, tool: String) -> String:
	var pony := Node3D.new()
	pony.name = "SmokeGroomed_" + id
	pony.set_meta("relationship_id", id)
	game.add_child(pony)
	var before: int = (logger.get("lines") as Array).size() if logger != null else 0
	mod.call("_reward", pony, tool, 20.0)
	pony.queue_free()
	if logger == null: return "(no logger)"
	var lines: Array = logger.get("lines")
	for i in range(before, lines.size()):
		var line := str(lines[i])
		if line.begins_with("[grooming] %s enjoyed %s" % [id, tool]): return line
	return "(no reward line)"


## Run on a case without grooming, on the grooming case's world: the briefcase and bits survive and
## the brushes are parked; with grooming on again (the "all" case) they come back.
func _check_parked(world_id: String, grooming_on: bool) -> void:
	var path := ""
	var data := ProjectSettings.globalize_path("user://")
	var grooming: Variant = JSON.parse_string(FileAccess.get_file_as_string(out_dir.path_join("grooming.json"))) if FileAccess.file_exists(out_dir.path_join("grooming.json")) else null
	var sentinel_path := str((grooming as Dictionary).get("sentinel", {}).get("path", "")) if grooming is Dictionary else ""
	for candidate: String in [sentinel_path, "user://worlds/%s/inventory/briefcase.json" % world_id, OS.get_environment("EQ_CONTEXT_ROOT").path_join(world_id).path_join("inventory/briefcase.json")]:
		if not candidate.is_empty() and path.is_empty() and FileAccess.file_exists(candidate): path = candidate
	result.parked_path = path
	if path.is_empty():
		check(false, "the grooming case's briefcase exists (%s, %s)" % [world_id, data]); return
	var store := STORE.new()
	var opened := store.open(path)
	var brushes := 0
	var apples := 0
	for slot: Variant in store.slots:
		if not slot is Dictionary: continue
		if str((slot as Dictionary).get("id", "")).contains(MANE_BRUSH): brushes += 1
		if str((slot as Dictionary).get("id", "")) == "apple": apples += int((slot as Dictionary).get("count", 0))
	var parked := JSON.stringify(store.parked)
	if grooming_on:
		check(opened and brushes > 0 and store.parked.is_empty(), "with grooming back on, its parked brushes return to the case (%d, parked %s)" % [brushes, parked])
	else:
		check(opened and store.bits >= 37 and apples >= 2, "without grooming the briefcase and bits survive (opened %s, bits %d, apples %d)" % [opened, store.bits, apples])
		check(brushes == 0 and parked.contains(MANE_BRUSH), "and the brushes wait parked (%s)" % parked.left(200))
	result.parked = {"grooming_on": grooming_on, "opened": opened, "bits": store.bits, "brushes": brushes, "apples": apples, "parked": store.parked.size()}


# ---------------------------------------------------------------- flowing manes (MOD-03)

func _check_flowing_manes() -> void:
	var patch: Node = root.get_node_or_null("Mods/flowing_manes_patch")
	result.flowing = {"warm_seen_under_cover": warm_seen_under_cover, "patch": patch != null}
	if patch == null:
		result.notes.append("flowing_manes: no warm-up patch running; its shaders are made when Celestia or Luna appears")
		check(false, "flowing manes' hair shaders are warmed while the loading cover is up (no patch entry)")
		return
	var warmed: Array = patch.get("warmed")
	result.flowing.warmed = warmed
	check(warm_seen_under_cover and warmed.size() >= 3, "flowing manes' hair shaders sit in the scene under the loading cover (%s)" % str(warmed))
	check(game.find_child("FlowingManesWarmup", true, false) == null, "and the warm-up holder is gone once the cover is")
	# Loaded at run time: a preload of a mod file would not compile in a case without the pack.
	var shaders: Script = load("res://mods/flowing_manes/wave_shader.gd")
	var cel: Shader = load("res://addons/cel-shader/cel-shader-base.gdshader")
	var made: Variant = shaders.call("flowing", cel, "base")
	var kept: Array = patch.get("shaders")
	check(made != null and kept.has(made), "the warmed shaders are the mod's own cached ones, which the princesses' hair reuses")


# ---------------------------------------------------------------- pin the tail (MOD-10)

func _check_pin_the_tail() -> void:
	var stub: Node = _from_source(PIN_GAME_SOURCE)
	var poster := Node3D.new()
	stub.add_child(poster)
	stub.set("poster_node", poster)
	var knowledge: Node = load("res://mods/pin_the_tail/knowledge.gd").new()
	knowledge.set("game", stub)
	var identity: Resource = _from_source(IDENTITY_SOURCE)
	identity.set("id", "smoke_pinner"); identity.set("display_name", "Smoke Pinner")
	var holder: Node3D = _from_source("extends Node3D\nvar identity: Resource\n")
	holder.set("identity", identity)
	holder.add_to_group("ai_characters")
	var space := Node3D.new()
	root.add_child(space)
	space.add_child(stub)
	space.add_child(holder)
	space.add_child(knowledge)
	poster.global_position = Vector3(0, 1.5, 0)
	holder.global_position = Vector3(4, 0, 0)
	var near := str(knowledge.call("prompt_note", "smoke_pinner"))
	holder.global_position = Vector3(30, 0, 0)
	var far := str(knowledge.call("prompt_note", "smoke_pinner"))
	var near_bytes := near.to_utf8_buffer().size()
	check(near_bytes > 0 and far.is_empty() and near.contains("[pin_the_tail]"), "pin the tail's prompt note is given 4 m from the poster (%d bytes, ~%d tokens) and not 30 m away" % [near_bytes, near_bytes / 4])
	# The real mod: every live pony now, and how far each is from the real poster.
	var real: Node = root.get_node_or_null("Mods/pin_the_tail/PonyKnowledge")
	var given := 0
	var asked := 0
	if real != null:
		for actor: Variant in game.get("mares"):
			if not is_instance_valid(actor) or (actor as Node).get("identity") == null: continue
			asked += 1
			if not str(real.call("prompt_note", str(actor.identity.id))).is_empty(): given += 1
	var lore := _lore_bytes("pin_the_tail_game")
	result.pin_the_tail = {"note_bytes_near": near_bytes, "note_tokens_near": near_bytes / 4, "note_far": far.length(), "live_ponies": asked,
		"live_ponies_given_note": given, "real_poster": real != null and real.get("game") != null and real.get("game").call("poster") != null, "lore_bytes": lore}
	result.notes.append("pin_the_tail: note %d bytes (~%d tokens) per request within 14 m of the poster; lore %d bytes only when its words come up; %d of %d live ponies got the note at the spawn" % [near_bytes, near_bytes / 4, lore, given, asked])
	space.queue_free()


func _lore_bytes(id: String) -> int:
	var seeds: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://world/ai/context_seeds.json"))
	if not seeds is Dictionary: return -1
	for row: Variant in (seeds as Dictionary).get("lore", []):
		if row is Dictionary and str((row as Dictionary).get("id", "")) == id: return str((row as Dictionary).get("text", "")).to_utf8_buffer().size()
	return 0


# ---------------------------------------------------------------- teleports (MOD-06, D-36)

func _check_teleport() -> void:
	var console := game.get_node_or_null("CommandConsole")
	var proxy := root.find_child("TeleportConsole", true, false)
	var dev := preload("res://world/dev_tools.gd").enabled()
	check(console != null and proxy != null, "teleport hooks the debug console (dev tools on in this run: %s)" % dev)
	result.teleport = {"console": console != null, "hooked": proxy != null, "dev_tools": dev}
	result.notes.append("teleport: tp/places answer only through the debug console (` or Settings > Debug), which needs debug mode; the pack itself stays listed in Settings > Mods until the loader learns debug_only (hook note)")


func _check_princess_teleport() -> void:
	var mod: Node = root.get_node_or_null("Mods/princess_teleport")
	if mod == null: check(false, "princess teleport's entry runs"); return
	var gated := mod.has_method("allowed")
	result.princess_teleport = {"patched": gated}
	if not gated:
		check(false, "princess teleport is limited to debug mode (D-36) and checks held/posture before a trip (needs the devanon patch)")
		return
	mod.set("debug_override", 0)
	check(not bool(mod.call("allowed")), "princess teleport does nothing with debug mode off (D-36)")
	mod.set("debug_override", 1)
	check(bool(mod.call("allowed")), "and runs with it on")
	mod.set("debug_override", -1)
	# Who may be taken: a held pony, a sitting pony or a seated Anon are walked, never teleported.
	var anon: Node3D = _from_source("extends Node3D\nvar seat: Node3D\nvar controls_locked := false\n")
	var pony: Node3D = _from_source("extends Node3D\nvar _held := false\nvar kind := \"stand\"\nfunc posture_status() -> Dictionary: return {\"kind\": kind, \"requested\": kind, \"settled\": true}\n")
	var space := Node3D.new(); root.add_child(space); space.add_child(anon); space.add_child(pony)
	check(str(mod.call("refusal", pony, anon)).is_empty(), "a standing pony beside a free Anon may be teleported")
	pony.set("_held", true)
	check(not str(mod.call("refusal", pony, anon)).is_empty(), "a pony Anon is holding is not (%s)" % mod.call("refusal", pony, anon))
	pony.set("_held", false); pony.set("kind", "sit")
	check(not str(mod.call("refusal", pony, anon)).is_empty(), "nor one sitting or lying (%s)" % mod.call("refusal", pony, anon))
	pony.set("kind", "stand"); anon.set("seat", space)
	check(not str(mod.call("refusal", pony, anon)).is_empty(), "nor while Anon sits (%s)" % mod.call("refusal", pony, anon))
	# No console placement: she is not moved to an unchecked spot; she stays where she stood, seen.
	anon.set("seat", null)
	pony.global_position = Vector3(5, 0, 5); anon.global_position = Vector3(400, 0, 400)
	pony.visible = false
	var placed: bool = mod.call("place_beside", pony, anon, "No safe clear floor in front of you.")
	check(not placed and pony.global_position == Vector3(5, 0, 5) and pony.visible, "a refused placement leaves her where she stood, visible, to walk (placed %s at %s)" % [placed, pony.global_position])
	space.queue_free()
	result.princess_teleport.lore_bytes = _lore_bytes("princess_teleport_celestia")


# ---------------------------------------------------------------- idle life (MOD-04)

func _check_idle_life() -> void:
	var mod: Node = root.get_node_or_null("Mods/idle_life")
	if mod == null: check(false, "idle life's entry runs"); return
	var idles: Script = load("res://mods/idle_life/idles.gd")
	result.idle_life = {"free_reach": idles.get_script_constant_map().get("FREE_REACH", []), "patched": root.get_node_or_null("Mods/idle_life_patch") != null or LOADER.active().any(func(m: Dictionary) -> bool: return m.id == "idle_life_patch")}
	# A standing pony, the deep stretch forced, its drawn pose checked against her limits.
	var pony: Node3D = null
	for actor: Variant in game.get("mares"):
		if is_instance_valid(actor) and actor is Node3D and (actor as Node3D).get("skeleton") is Skeleton3D and (actor as Node3D).get("joint_limits") != null \
				and not (actor as Node).scene_file_path.contains("/princesses/") and (actor as Node3D).is_visible_in_tree():
			pony = actor; break
	if pony == null:
		result.notes.append("idle_life: no live pony to pose (joint-limit run skipped)")
		check(false, "a live pony to check idle life's stretch on"); return
	var sk: Skeleton3D = pony.get("skeleton")
	var probe: Object = _from_source(LIMIT_PROBE_SOURCE)
	if probe == null: check(false, "the joint-limit probe compiles"); return
	probe.set("limits", pony.get("joint_limits"))
	sk.add_child(probe as Node)
	for frame in 30: await physics_frame
	var baseline := float(probe.get("worst"))
	probe.set("worst", 0.0)
	var played: bool = mod.call("play", pony, "stretch_deep", 1.0, true)
	var length: float = idles.call("length", "stretch_deep")
	var removed := false
	# idle_life keeps its pose its skeleton's last modifier from its _physics_process: driven from
	# here, the probe goes after it every tick and reads the pose as drawn.
	mod.set_physics_process(false)
	var step := 1.0 / float(Engine.physics_ticks_per_second)
	for frame in int(length * 60.0) + 90:
		await physics_frame
		mod.call("_physics_process", step)
		sk.move_child(probe as Node, -1)
		if frame > 30 and sk.get_node_or_null("IdleLife") == null: removed = true; break
	mod.set_physics_process(true)
	var worst := float(probe.get("worst"))
	var passes := int(probe.get("passes"))
	var bone := sk.get_bone_name(int(probe.get("worst_bone"))) if int(probe.get("worst_bone")) >= 0 else ""
	(probe as Node).queue_free()
	for frame in 5: await physics_frame
	result.idle_life.stretch = {"played": played, "passes": passes, "baseline_deg": baseline, "worst_deg": worst, "worst_bone": bone, "removed": removed}
	check(played and passes > 0, "the deep stretch plays on %s (%d modifier passes)" % [pony.name, passes])
	check(worst <= baseline + LIMIT_SLACK_DEG, "it stays inside pony_joint_limits (worst %.1f deg off on %s; %.1f before it)" % [worst, bone, baseline])
	check(removed and sk.get_node_or_null("IdleLife") == null, "and its pose modifier is removed when the idle ends")
	# A princess' pose reader is kept only while it is needed (devanon patch): time one on this skeleton.
	var reader: Node = load("res://mods/idle_life/pose_reader.gd").new()
	sk.add_child(reader)
	var started := Time.get_ticks_usec()
	for i in 100: reader.call("_process_modification_with_delta", 0.016)
	result.idle_life.pose_reader_us = (Time.get_ticks_usec() - started) / 100.0
	result.idle_life.bones = sk.get_bone_count()
	reader.queue_free()
	result.notes.append("idle_life: a princess pose reader costs %.1f us per frame on a %d-bone skeleton while it is kept" % [result.idle_life.pose_reader_us, sk.get_bone_count()])


# ---------------------------------------------------------------- idle cost

## Every node running a mod script ("res://mods/<id>/..."), its mod id.
func _mod_nodes() -> Dictionary:
	var out := {}
	for node: Node in root.find_children("*", "", true, false):
		var script := node.get_script() as Script
		while script != null:
			var path := script.resource_path
			if path.begins_with("res://mods/"):
				out[node] = path.get_slice("/", 3)
				break
			script = script.get_base_script()
	return out


func _idle_probe() -> void:
	var physics := {}   # node -> id
	var process := {}
	var modifiers := {}  # id -> count
	var spent := {}      # id -> us over the run
	var parts := {}      # "<id> <script> <callback>" -> us over the run
	var peak := {}       # id -> max us in one frame
	var nodes_by_id := {}
	for frame in TICKS:
		if frame % 60 == 0:
			var found := _mod_nodes()
			for node: Node in found:
				var id := str(found[node])
				if frame == 0: nodes_by_id[id] = int(nodes_by_id.get(id, 0)) + 1
				if node is SkeletonModifier3D:
					# Modifiers alive at the start and at the last scan ("start/end" per script).
					var key := id + ":" + str((node.get_script() as Script).resource_path.get_file())
					if frame == 0: modifiers[key] = [int((modifiers.get(key, [0, 0]) as Array)[0]) + 1, 0]
					elif frame == TICKS - 60:
						var pair: Array = modifiers.get(key, [0, 0])
						modifiers[key] = [pair[0], int(pair[1]) + 1]
					continue
				if node.is_physics_processing() and node.has_method("_physics_process") and not physics.has(node):
					node.set_physics_process(false); physics[node] = id
				if node.is_processing() and node.has_method("_process") and not process.has(node):
					node.set_process(false); process[node] = id
		await physics_frame
		var delta := 1.0 / float(Engine.physics_ticks_per_second)
		var tick := {}
		for node: Variant in physics.keys():
			if not is_instance_valid(node): physics.erase(node); continue
			var started := Time.get_ticks_usec()
			(node as Node).call("_physics_process", delta)
			var used := Time.get_ticks_usec() - started
			tick[physics[node]] = int(tick.get(physics[node], 0)) + used
			var part := "%s %s _physics_process" % [physics[node], ((node as Node).get_script() as Script).resource_path.get_file()]
			parts[part] = int(parts.get(part, 0)) + used
		for node: Variant in process.keys():
			if not is_instance_valid(node): process.erase(node); continue
			var started := Time.get_ticks_usec()
			(node as Node).call("_process", root.get_process_delta_time() if root.get_process_delta_time() > 0.0 else delta)
			var used := Time.get_ticks_usec() - started
			tick[process[node]] = int(tick.get(process[node], 0)) + used
			var part := "%s %s _process" % [process[node], ((node as Node).get_script() as Script).resource_path.get_file()]
			parts[part] = int(parts.get(part, 0)) + used
		for id: String in tick:
			spent[id] = int(spent.get(id, 0)) + int(tick[id])
			peak[id] = maxi(int(peak.get(id, 0)), int(tick[id]))
	for node: Variant in physics: if is_instance_valid(node): (node as Node).set_physics_process(true)
	for node: Variant in process: if is_instance_valid(node): (node as Node).set_process(true)
	var ids: Array = spent.keys()
	for id: String in nodes_by_id: if id not in ids: ids.append(id)
	for id: String in ids:
		result.idle[id] = {"mean_us": float(spent.get(id, 0)) / TICKS, "peak_us": int(peak.get(id, 0)), "nodes": int(nodes_by_id.get(id, 0))}
		print("[smoke_a] idle %s: %.2f us per tick (peak %d us) over %d ticks" % [id, float(spent.get(id, 0)) / TICKS, int(peak.get(id, 0)), TICKS])
	_grooming_breakdown()
	result.modifiers = modifiers
	result.idle_parts = {}
	for part: String in parts: result.idle_parts[part] = float(parts[part]) / TICKS
	result.live_ponies = (game.get("mares") as Array).size() if game.get("mares") is Array else -1


## Where grooming's idle tick goes: each step of its _physics_process timed alone (200 calls, all
## no-ops or reads while nothing is groomed), and how near the nearest pony stands to Anon's camera
## (the devanon patch scans for preening only within 4 m).
func _grooming_breakdown() -> void:
	var mod: Node = root.get_node_or_null("Mods/grooming")
	if mod == null or not is_instance_valid(game): return
	var parts := {}
	var dt := 0.05
	for step: String in ["_animate_desktop_brush", "_animate_sessions", "_tick_loop", "_expire", "_sense_desktop", "_sense_vr_brushes", "_sense_preening", "_game"]:
		if not mod.has_method(step): continue
		var started := Time.get_ticks_usec()
		for i in 200:
			match step:
				"_sense_desktop", "_sense_vr_brushes", "_sense_preening": mod.call(step, game, dt)
				"_game": mod.call(step)
				_: mod.call(step, dt)
		parts[step] = (Time.get_ticks_usec() - started) / 200.0
	var camera: Variant = mod.call("_camera") if mod.has_method("_camera") else null
	var nearest := INF
	if camera is Node3D:
		for pony: Variant in game.get("mares"):
			if is_instance_valid(pony) and pony is Node3D: nearest = minf(nearest, (pony as Node3D).global_position.distance_to((camera as Node3D).global_position))
	result.grooming_breakdown = {"us_per_call": parts, "nearest_pony_m": nearest if is_finite(nearest) else -1.0}
	print("[smoke_a] grooming per step (us per call): %s; nearest pony %.1f m" % [str(parts), nearest])


# ---------------------------------------------------------------- finish and report

func finish() -> void:
	result.checks = checks
	result.failures = failures
	result.fails = fails
	if logger != null:
		var errors: Array = logger.get("errors")
		var mod_errors: Array = errors.filter(func(e: Array) -> bool: return str(e[1]).begins_with("res://mods/") or str(e[4]).contains("res://mods/") or str(e[3]).contains("res://mods/"))
		result.errors_total = errors.size()
		result.errors_mods = mod_errors.map(func(e: Array) -> String: return "%s:%d %s %s" % [e[1], e[2], e[3], e[4]])
		var ours: Array = mod_errors.filter(func(e: Array) -> bool:
			for id: String in SET_A:
				if str(e).contains("res://mods/%s/" % id) or str(e).contains("res://mods/%s_patch/" % id): return true
			return false)
		check(ours.is_empty(), "no errors from set A mod scripts after boot (%d; %d from other mods, %d engine errors in all)" % [ours.size(), mod_errors.size() - ours.size(), errors.size()])
		result.mod_lines = (logger.get("lines") as Array).slice(0, 60)
		result.checks = checks
		result.failures = failures
	var file := FileAccess.open(out_dir.path_join(case_name + ".json"), FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(result, "\t")); file.close()
	print("SMOKE_A_CASE_DONE ", "PASS" if failures == 0 else "FAIL", " case=", case_name, " checks=", checks, " failures=", failures)
	if is_instance_valid(game):
		game.queue_free()
		current_scene = null
	for frame in 15: await process_frame
	quit(0 if failures == 0 else 1)


func report() -> void:
	var logs := arg("smoke-logs")
	var rows: Array = []
	var cases := ["none"] + SET_A
	# Extra cases (an author's pack without its patch, the removal case) in name order, then "all".
	var extra := Array(DirAccess.get_files_at(out_dir)).filter(func(f: String) -> bool:
		return f.ends_with(".json") and f.get_basename() not in cases and f.get_basename() != "all").map(func(f: String) -> String: return f.get_basename())
	extra.sort()
	cases.append_array(extra)
	cases.append("all")
	var none_errors := _log_errors(logs, "none")
	print("[smoke_a] | case | checks | fails | SCRIPT ERROR lines (none: %d) | from res://mods | idle us/tick (mean / peak) by mod |" % none_errors[0])
	for case: String in cases:
		var path := out_dir.path_join(case + ".json")
		if not FileAccess.file_exists(path):
			print("[smoke_a] | %s | not run |" % case); continue
		var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not doc is Dictionary: continue
		var idle := PackedStringArray()
		for id: String in (doc.idle as Dictionary):
			idle.append("%s %.2f / %d" % [id, float(doc.idle[id].mean_us), int(doc.idle[id].peak_us)])
		var errors := _log_errors(logs, case)
		var verdict := "PASS" if int(doc.failures) == 0 and errors[2] == 0 else "FAIL"
		print("[smoke_a] | %s | %s %d | %d | %d | %d (set A: %d) | %s |" % [case, verdict, int(doc.checks), int(doc.failures), errors[0], errors[1], errors[2], ", ".join(idle)])
		for text: Variant in doc.fails: print("[smoke_a]     fail: ", text)
		for text: Variant in doc.get("notes", []): print("[smoke_a]     note: ", text)
		rows.append(doc)
	print("SMOKE_A_REPORT_DONE cases=", rows.size())
	quit(0)


## [SCRIPT ERROR lines, those naming res://mods/, those naming a set A mod or its patch] in the runner log of a case (<logs>/<case>.log).
func _log_errors(logs: String, case: String) -> Array:
	var path := logs.path_join(case + ".log")
	if logs.is_empty() or not FileAccess.file_exists(path): return [-1, -1, -1]
	var all := 0
	var mods := 0
	var ours := 0
	var lines := FileAccess.get_file_as_string(path).split("\n")
	for i in lines.size():
		if not lines[i].contains("SCRIPT ERROR"): continue
		all += 1
		var near := lines[i] + (lines[i + 1] if i + 1 < lines.size() else "")
		if near.contains("res://mods/"): mods += 1
		for id: String in SET_A:
			if near.contains("res://mods/%s/" % id) or near.contains("res://mods/%s_patch/" % id): ours += 1; break
	return [all, mods, ours]
