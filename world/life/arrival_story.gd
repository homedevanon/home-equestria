extends Node
## Arrival (NEXT_STEPS first priority, bulk prompt package 9, dev 2026-09-27/30, 2026-10-01): a new
## world starts with Anon waking on the floor of the deep Everfree (world/life/arrival_wake.gd).
## The opening is the tutorial (world/life/arrival_tutorial.gd): in a small gap among the trees,
## held in by thorns and a fallen log (world/life/arrival_pocket.gd), he learns to walk, pick up,
## use his briefcase, eat and change clothes. Then Twilight Sparkle finds him: she lifts the log
## aside with her magic, walks up slowly, talks, he learns to see how a pony feels about him; a
## timberwolf howls and she teleports them both straight inside Golden Oak Library, where she
## offers its guest bed. That is the whole opening (dev 2026-10-14: "remove the celestia bit
## altogether... twilight finds you and you can sleep in the guest bed if you want and thats it";
## landing inside also means he cannot wander off on the walk through town). Then he is free.
##
## State lives in the world context ("arrival": stage, home place id, one-time flags), so a save
## and reload resumes the current step and nothing is granted twice. Worlds that already had
## progress before this existed are marked done and never replay it.
##
## Before he wakes, in the black, the player chooses who he is (dev 2026-10-01,
## docs/ANONPONY_DESIGN_2026_10_01.md): human Anon or AnonPony (world/life/pony_creator.gd).
## The choice is stored once in the world context (world/life/player_form.gd) and applied on
## every load: AnonPony on desktop and seated VR (player/pony_form.gd); room-scale VR plays Anon.
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const CORE := preload("res://world/life/living_world.gd")
const FOOD_SPAWN := preload("res://world/food/food_spawn.gd")
const FOOD_CONTACT := preload("res://world/food/food_interaction.gd")
const EXECUTOR := preload("res://world/ai/pony_action_executor.gd")
const HOUSE := preload("res://world/buildings/house_interior.gd")
const MAGIC := preload("res://world/characters/magic/unicorn_magic.gd")
const PLACES := preload("res://world/navigation/place_directory.gd")
const TWILIGHT := "twilight_sparkle"
## The middle of the Everfree, deep among the trees and over 300 m from every trail (dev
## 2026-10-01: "the MIDDLE of the everfree forest not on a path"; "no clearing, a dense everfree").
## The exact spot is the best natural gap among the streamed trees near here.
const WAKE := Vector3(380.0, 0.0, 1080.0)
## Conversation range from which Twilight may offer the teleport before her close approach.
const TELEPORT_TALK_RANGE := 12.0
## Twilight's teleport lands in Ponyville itself, on open level ground 50 m north of Town Hall
## (dev 2026-10-02: from the Everfree's edge at (60, 312) it was "like a 5 minute walk", and her lead
## got stuck at a river bridge). Probed clear of buildings and water: tools/life/probe_landing_spots.gd.
const FOREST_EDGE := Vector3(95.8, 0.0, -161.2)
const POCKET := preload("res://world/life/arrival_pocket.gd")
const WAKE_SCENE := preload("res://world/life/arrival_wake.gd")
const TUTORIAL := preload("res://world/life/arrival_tutorial.gd")
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const PONY_FORM := preload("res://player/pony_form.gd")
const CREATOR := preload("res://world/life/pony_creator.gd")
const FOREST_STAGES := ["wake", "tutorial", "found"]
## The tutorial waits for him, but never forever: Twilight comes after this long regardless.
const TUTORIAL_PATIENCE := 90.0
const LIBRARY := "house:golden_oak_library"
const RESCUE := "arrival_rescue"
const SHELTER := "arrival_shelter"
const GOLDEN_OAK := Vector3(-24.5, -11.3, -259.2)
const STARTING_BITS := 50
const BASKET := ["food:red-apple", "food:red-apple", "food:red-apple", "food:red-apple", "food:carrot",
	"food:carrot", "food:carrot", "food:carrot", "food:bread-loaf", "food:hayburger", "food:hayburger"]
## Factual purposes for AI generation. None is dialogue to recite.
const LINES := {
	"found":"You unexpectedly discover an unfamiliar sapient creature alone in the dangerous Everfree. Speak softly and slowly, the way you would to someone frightened; you have just come round a log and found them. React with gentle, startled concern for their immediate wellbeing; find out whether they are okay or hurt. Your bookish curiosity about someone unlike any creature you have met may slip through, but stay kind and address a person, not a specimen. You do not know the word human for their species unless they have told you; body labels in supplied context are not taxonomy you have learned. Let your name follow naturally if it fits, rather than leading with a formal introduction or a memory interview. Do not diagnose injury or amnesia, invent appearance details, or supply their answer.",
	"settle":"You have sat down a step away from the stranger you just found in the Everfree, so you are not looming over them. Gently tell them your name and where they are: the Everfree Forest, at the edge of Ponyville, and it will be dark soon. Ask, kindly and without pressure, what their name is or how they ended up out here. Then let them answer; do not rush on. Two or three short, warm sentences.",
	"wolves":"A timberwolf just howled somewhere in the trees. You flinched and your ears went up, but you keep your voice low and calm for the stranger: explain in a hushed way that timberwolves are wolves made of wood and branches that roam this forest at dusk, and that it is no place to be after dark. Do not offer to leave yet. Two short sentences.",
	"teleport":"A second howl, closer. Gently ask the stranger if they will let you take them somewhere safe: Ponyville, your home at the Golden Oak Library, with a warm guest bed. Tell them you can bring you both there with a teleport spell, that it only tingles for a moment, and ask them to stay close to you. Two or three short, kind sentences. The teleport has not happened yet.",
	"edge":"You have both just teleported to Ponyville. Invite the newcomer to follow you to your nearby treehouse, Golden Oak Library. One short sentence; speak to them, not about the scene.",
	"shelter":"You and the newcomer have just teleported inside your treehouse, Golden Oak Library, safe from the forest. Gently tell them they can stay as long as they need: the guest bed downstairs is theirs, and Ponyville is right outside whenever they feel like looking around. Two or three short, warm sentences.",
	"welcome":"Twilight brought this newcomer from the Everfree. Welcome them to Equestria and explain their safety and the permanent, freely given Ponyville house, with nothing owed. Ask Twilight to escort them home.",
	"home":"You and the newcomer have reached their freely given home. Welcome them home and explain that it is theirs with nothing owed. Ponies do not lock their homes or use house keys; they can simply come in.",
	"done":"The home and furnishing are confirmed. Explain the bed, furniture, welcome food and 50 bits already provided, and leave them free to choose their next activity. Briefly offer one optional outing: the library, paid counter work at Hayburger (8 am–10 pm), the market's produce or general-goods tent, or outfits at Rarity's Boutique. Work is optional; their home is already secure. Do not turn the welcome into a list of chores.",
}
const LINES_PONY := {
	"found":"You unexpectedly discover an unfamiliar pony alone in the dangerous Everfree. React with spontaneous, startled concern for their immediate wellbeing; find out whether they are okay or hurt. Recognize their actual pony species from the supplied body context; this is not an alien or human discovery. Your curiosity stays kind, and any surprise about rare or unusual features must be warranted by their actual supplied body. Let your name follow naturally if it fits, rather than leading with a formal introduction or a memory interview. Do not diagnose injury or amnesia, invent appearance details or shared history, or supply their answer.",
}
var game: Node
var data: Dictionary = {}
var _twilight: Node3D
var _executor: Node
var _own_executor := false
var _turn := 0
var _timer := 0.0
var _stage_time := 0.0
var _spawning := false
var pocket: Node3D
var tutorial: Node3D
var _wake_node: Node
var _forest_running := false
var _context_epoch := -1
## Scenario mods (world/modding/scenario.gd): while set, a new world's forest opening waits (the
## scenario's start node runs first; hold_opening()).
var _opening_held := false

## Retire the former handoff while retaining delivered speech and one-time grant receipts.
## Only this story's saved plan changes; unrelated encounters and recorded history remain.
func _migrate_key_handoff() -> void:
	if stage() == "key": data.stage = "home"
	for field: String in ["key_given", "key_taken", "key_token"]: data.erase(field)
	var context: Node = game.get("world_context") if game != null else null
	if context == null or not context.state.get("encounters") is Dictionary: return
	var encounters: Dictionary = context.state.encounters
	if not encounters.get(WELCOME) is Dictionary: return
	var row: Dictionary = encounters[WELCOME]
	if row.get("commitment") is Dictionary and row.commitment.has(TWILIGHT):
		row.commitment[TWILIGHT] = "Help Celestia welcome the newcomer, then show them their freely given home. Ponies do not use house keys or locks."
	if row.get("beats") is Array:
		for beat: Variant in row.beats:
			if beat is Dictionary and str(beat.get("id", "")) == "home":
				beat.label = "welcoming the newcomer home"
				if beat.has("intent"): beat.intent = LINES.home

## Before loading: read or start the story; a new world puts the player at the wake spot.
func prepare(host: Node, resumed: Dictionary) -> void:
	game = host
	add_to_group("arrival_story")
	_context_epoch = int(game.world_context.epoch)
	var state: Dictionary = game.world_context.state
	if state.get("arrival") is Dictionary:
		data = (state.arrival as Dictionary).duplicate(true)
	elif resumed.is_empty() and (state.get("events", []) as Array).is_empty():
		data = {"stage": "wake"}
	else:
		data = {"stage": "done", "skipped": "world older than the arrival story"}
	_migrate_key_handoff()
	# The Celestia morning and the walk home are gone (dev 2026-10-14): a save waiting for them
	# is simply done; the guest bed stays offered.
	if stage() in ["overnight", "welcome", "to_home", "home", "key"]: data.stage = "done"
	# The saved encounter owns dialogue purposes and pony reservations separately
	# from the stage. Retire unfinished old purposes without inventing speech receipts.
	# Include already-migrated done saves; completed/cancelled history stays intact.
	if stage() == "done":
		var encounters := _encounters()
		if encounters != null:
			for id: String in [RESCUE, SHELTER, WELCOME]:
				if encounters.active(id): encounters.cancel(id, "The arrival opening now ends with the Golden Oak guest-bed offer.")
	# A save can capture the flash before either actor moves. Resume the transport,
	# never an escort stranded at the old forest coordinates.
	var resume_teleport := stage() == "teleport"
	if resume_teleport: data.stage = "to_library"; data.teleported = true
	# Preserve already delivered welcomes/grants; only unfinished old escorts change destination.
	if stage() == "to_town_hall":
		data.stage = "to_library"
		if _encounters() != null: _encounters().cancel("arrival_welcome", "The newcomer now shelters at Golden Oak first")
	_save()
	# A saved AnonPony is the player in every stage, finished worlds included. Here, after the
	# save's context is restored and before anything places him, under the loading cover.
	_apply_form()
	if resume_teleport: _place_player(FOREST_EDGE, Vector3.FORWARD)
	if stage() == "done": return
	if stage() in FOREST_STAGES:
		var spot: Vector3 = Vector3(data.pocket[0], data.pocket[1], data.pocket[2]) if data.get("pocket") is Array else WAKE
		_place_player(spot, Vector3.FORWARD)
		# Black from the first frame: he wakes with his eyes shut (world/life/arrival_wake.gd).
		if stage() == "wake":
			_wake_node = WAKE_SCENE.new(); _wake_node.name = "ArrivalWake"; add_child(_wake_node); _wake_node.setup(game)
	print("[arrival] stage ", stage())

## Puts Anon's feet at `at` (on the terrain), facing `facing`, and streams the world there.
func _place_player(at: Vector3, facing: Vector3) -> void:
	var body: Node3D = game.player.get_node("Body") if game.xr_active else game.player
	var ground: float = WorldTerrain.instance.height_at(at) if is_instance_valid(WorldTerrain.instance) else NAN
	var feet := Vector3(at.x, (ground if is_finite(ground) else at.y) + 0.15, at.z)
	var camera: Camera3D = game._find_camera(game.player)
	facing.y = 0.0
	var heading := atan2(-facing.x, -facing.z)
	if game.xr_active:
		var origin := body.find_child("XROrigin", true, false) as Node3D
		if origin != null and camera != null: origin.rotate_y(heading - camera.global_rotation.y)
		var destination:=body.global_position+feet-Vector3(camera.global_position.x,body.global_position.y,camera.global_position.z) if camera!=null else feet
		# The physics hands are top-level bodies: moving the view alone strands them
		# at the previous location and leaves nearby pony contact asleep.
		if body.has_method("teleport"):body.teleport(destination)
		else:body.global_position=destination
	else:
		# The rig's own feet on the spot, turned so the view faces `facing`. For human desktop this
		# equals setting the heading and moving the camera's XZ there (its camera has no yaw or XZ
		# of its own); an AnonPony's eye sits a head ahead of its feet, and a seated headset adds
		# the tracked head, so neither is used for the position.
		var yaw: float = camera.global_rotation.y if camera != null else NAN
		if is_finite(yaw): body.rotate_y(heading - yaw)
		else: body.rotation.y = heading
		body.global_position = feet
	if "velocity" in body: body.set("velocity", Vector3.ZERO)
	if is_instance_valid(WorldTerrain.instance): WorldTerrain.instance.focus(feet)

## A saved AnonPony becomes the player's body (player/pony_form.gd) on desktop and in seated VR.
## Room-scale VR plays as Anon and keeps the saved form. `chosen` is the creator's answer, applied
## even when a read-only world could not store it.
func _apply_form(chosen: Dictionary = {}) -> void:
	var context: Node = game.get("world_context")
	var form: Dictionary = chosen
	if form.is_empty() and context != null: form = PLAYER_FORM.saved(context.get("state"))
	if not PLAYER_FORM.is_pony(form): return
	if game.xr_active:
		print("[arrival] pony form kept; room-scale VR plays as Anon")
		return
	var driver: Node = PONY_FORM.attach(game, form)
	print("[arrival] the player is AnonPony, ", PLAYER_FORM.describe(form), "" if driver != null else " (not attached)")

## Before he wakes, in the black: human Anon or AnonPony. The answer is stored and flushed at
## once, so a crash right after choosing loses nothing; an autosave before it keeps stage "wake"
## without a form, so a reload asks again.
func _choose_form() -> void:
	var creator: Node = CREATOR.new(); creator.name = "PonyCreator"
	# The last child of game: its _input hears every key before the menus and hotkeys do.
	game.add_child(creator)
	var form: Dictionary = await creator.run(game)
	if is_instance_valid(creator): creator.queue_free()
	if not _alive() or form.is_empty(): return
	PLAYER_FORM.store(game, form)
	_apply_form(form)

## The form the player has right now (a pony only while PonyForm drives one).
func _pony_now() -> bool:
	return PLAYER_FORM.is_pony(PLAYER_FORM.active(get_tree()))

func stage() -> String:
	return str(data.get("stage", "done"))

func _set_stage(value: String) -> void:
	data.stage = value; _stage_time = 0.0; _save()
	_recovering_follower = false
	_road_started = false
	print("[arrival] stage ", value)

func _save() -> void:
	var context: Node = game.world_context
	if context == null or context.get("_read_only") == true: return
	context.state["arrival"] = data.duplicate(true)
	if context.has_method("_changed"): context._changed()

func _player() -> Node3D:
	return game._find_camera(game.player)

func _feet() -> Vector3:
	var camera := _player()
	var body: Node3D = game.player.get_node("Body") if game.xr_active else game.player
	return Vector3(camera.global_position.x, body.global_position.y, camera.global_position.z)

var _reserve_timer := 0.0
func _physics_process(delta: float) -> void:
	if not _alive(): return
	_reserve_timer -= delta
	if _reserve_timer <= 0.0:
		_reserve_timer = 2.0
		_home_reserved()
	if stage() == "done" or game == null or game.get("title_active") == true: return
	# Twilight belongs to the story until it ends: the population does not spawn her elsewhere.
	if is_instance_valid(game.get("population")) and not game.population.visiting.has(TWILIGHT): game.population.visiting[TWILIGHT] = true
	if game.get_node_or_null("LoadingCover") != null: return
	if _opening_held and stage() in FOREST_STAGES: return
	_stage_time += delta
	if stage() in FOREST_STAGES:
		if stage() == "found": _tick_transport_request(delta)
		if not _forest_running: _forest()
		return
	if stage() == "teleport": return
	_timer -= delta
	if _timer > 0.0: return
	_timer = 0.25
	if stage() == "to_library": _to_library()

# ---------------------------------------------------------------- the forest opening
## Wake, tutorial and Twilight's arrival run as one sequence. Each stage is saved, so a reload
## resumes at the start of the stage it was in; the pocket keeps the same place.
func _forest() -> void:
	_forest_running = true
	# A fresh world asks who he is first, under the wake's black and before the ringing. Room-scale
	# VR never asks and stores nothing, so that world stays human once the stage moves on.
	if stage() == "wake" and not game.xr_active and PLAYER_FORM.saved(game.world_context.state).is_empty():
		if not is_instance_valid(_wake_node):
			_wake_node = WAKE_SCENE.new(); _wake_node.name = "ArrivalWake"; add_child(_wake_node); _wake_node.setup(game)
		await _choose_form()
		if not _alive(): return
	if stage() == "wake" and _skip_opening_wanted():
		await _skip_opening()
		return
	var at := Vector3.INF
	if data.get("pocket") is Array: at = Vector3(data.pocket[0], data.pocket[1], data.pocket[2])
	var waited := 0.0
	while not at.is_finite() and waited < 15.0:
		at = POCKET.find(WAKE)
		if at.is_finite(): break
		if not await _wait(0.5): return
		waited += 0.5
	if not at.is_finite():
		var h: float = WorldTerrain.instance.height_at(WAKE) if is_instance_valid(WorldTerrain.instance) else 0.0
		at = Vector3(WAKE.x, h if is_finite(h) else 0.0, WAKE.z)
		print("[arrival] no tree gap found near ", WAKE, "; using it directly")
	data.pocket = [at.x, at.y, at.z]; _save()
	var body: Node = game.player.get_node("Body") if game.xr_active else game.player
	# The pocket wall goes on whatever really moves: AnonPony's body, else the rig.
	pocket = POCKET.new(); add_child(pocket); pocket.build(game, at, body.motion_body() if body.has_method("motion_body") else body)
	tutorial = TUTORIAL.new(); add_child(tutorial)
	var saved_receipts: Dictionary = data.get("tutorial_receipts", {}) if data.get("tutorial_receipts", {}) is Dictionary else {}
	tutorial.receipts_changed.connect(func() -> void:
		data.tutorial_receipts = tutorial.receipts.duplicate(true)
		_save())
	tutorial.setup(game, pocket, saved_receipts)
	var lie: Vector3 = pocket.centre - pocket.gate_dir * 0.4
	if stage() == "wake":
		if not is_instance_valid(_wake_node):
			_wake_node = WAKE_SCENE.new(); _wake_node.name = "ArrivalWake"; add_child(_wake_node); _wake_node.setup(game)
		await _wake_node.play(lie, pocket.gate_dir)
		if not _alive(): return
		data.tutorial = 0
		_set_stage("tutorial")
	else:
		_place_player(lie - pocket.gate_dir * 0.35, pocket.gate_dir)
	if stage() == "tutorial":
		var began := _stage_time
		while int(data.get("tutorial", 0)) < TUTORIAL.STEPS.size():
			var step_id: String = TUTORIAL.STEPS[int(data.get("tutorial", 0))]
			# AnonPony wears no clothes: the wardrobe step is passed over (STEPS and saved indices
			# stay as they are).
			if step_id == "clothes" and _pony_now():
				data.tutorial = int(data.get("tutorial", 0)) + 1; _save()
				continue
			tutorial.start(step_id)
			while not str(tutorial.step).is_empty() and _stage_time - began < TUTORIAL_PATIENCE:
				if not await _wait(0.25): return
			if not str(tutorial.step).is_empty(): break
			data.tutorial = int(data.get("tutorial", 0)) + 1; _save()
		tutorial.stop()
		_set_stage("found")
	await _encounter()

func _alive() -> bool:
	return is_inside_tree() and not is_queued_for_deletion() and is_instance_valid(game) and (_context_epoch < 0 or (is_instance_valid(game.world_context) and int(game.world_context.epoch) == _context_epoch))

func _wait(seconds: float) -> bool:
	if not await SHUTDOWN.seconds(self, seconds): return false
	return _alive()

func _found_ongoing() -> bool:
	return stage() == "found" and not bool(data.get("transport_requested", false))

## A pause for him to answer: at least `seconds`, longer while either of them is still talking
## (her reply to him included), never more than a minute.
func _breathe(seconds: float) -> bool:
	var waited := 0.0
	while waited < 60.0:
		if not await _wait(0.25) or not _found_ongoing(): return false
		waited += 0.25
		var director: Node = game.get("director") if game != null else null
		var talking: bool = is_instance_valid(_twilight) and _twilight.get("head") != null and _twilight.head.is_speaking()
		if director != null and director.has_method("is_busy"): talking = talking or bool(director.is_busy())
		if waited >= seconds and not talking: return true
	return true

## Twilight finds him: a snapped twig and rustling past the log, her voice, the log lifted aside
## by her magic, then she walks up slowly and stays while she talks (dev 2026-10-01: she ran up
## and walked away straight after).
func _encounter() -> void:
	_transport_restoring_path = bool(data.get("transport_requested", false))
	_begin_rescue()
	var outside: Vector3 = pocket.gate + pocket.gate_dir * 11.0
	_rustle(pocket.gate + pocket.gate_dir * 9.0)
	if not await _wait(1.4): return
	var tries := 0
	while not is_instance_valid(_twilight) and tries < 12:
		if not _spawning: _bring_twilight(_ground(outside + pocket.gate_dir.rotated(Vector3.UP, PI * 0.5) * float(tries % 3 - 1) * 4.0))
		if not await _wait(1.0): return
		if not _spawning and not is_instance_valid(_twilight): tries += 1
	if not is_instance_valid(_twilight):
		print("[arrival] Twilight could not reach the forest: ", game.get("spawn_failure"))
		# Keep the unfinished rescue pending, rather than silently skipping it without her.
		if await _wait(3.0): _encounter()
		return
	# A saved request resumes only after the rescue and its actual actor are restored.
	if bool(data.get("transport_requested", false)):
		# Rebuilt pockets restore the fallen log closed. Clear the real path
		# before the pending request resumes its close-range reunion.
		await _lift_log()
		_transport_restoring_path = false
		return
	# Through the trees to just outside the log at a trot (dev 2026-10-02: at a walk she took
	# "WAY too slowly" to come into the scene); the last steps up to him stay a walk.
	var outside_log: Vector3 = pocket.gate + pocket.gate_dir * 1.6
	_command([{"id": "arrival_to_log", "type": "go_to", "location_id": _point_id(Vector2(outside_log.x, outside_log.z)), "pace": "trot"}])
	var walked := 0.0
	while is_instance_valid(_twilight) and walked < 30.0 and _flat(_twilight.global_position, outside_log) > 1.4:
		if not await _wait(0.25): return
		walked += 0.25
		if is_instance_valid(_twilight) and _idle() and walked > 3.0 and _flat(_twilight.global_position, outside_log) > 1.4:
			_command([{"id": "arrival_to_log_again", "type": "go_to", "location_id": _point_id(Vector2(outside_log.x, outside_log.z)), "pace": "trot"}])
	_command([{"id": "arrival_wait_log", "type": "stay", "duration_s": 600.0}, {"id": "arrival_look_log", "type": "look_at", "target_id": "player", "duration_s": 30.0}])
	# The rustle and visible approach establish her arrival; avoid an extra model/TTS wait.
	await _lift_log()
	if not _alive(): return
	# M-ARR-03: she can leave the tree during the walk or the lift (despawn, rescue); a freed
	# actor read below would stop this coroutine with a script error. Find her again instead.
	if not is_instance_valid(_twilight):
		if await _wait(1.0): _encounter()
		return
	# She comes in slowly, stops a comfortable step away, and stays.
	var approached := 0.0
	_command([{"id": "arrival_approach", "type": "approach", "target_id": "player", "distance_m": 1.7, "pace": "walk"}])
	while is_instance_valid(_twilight) and approached < 40.0 and _flat(_twilight.global_position, _feet()) > 2.3:
		if not await _wait(0.25): return
		approached += 0.25
		if not is_instance_valid(_twilight): break
		if _idle() and _flat(_twilight.global_position, _feet()) > 2.3 and fmod(approached, 4.0) < 0.25:
			# A refused approach falls back to a fixed spot beside him, inside the pocket.
			var beside: Vector3 = _feet() + (_twilight.global_position - _feet()).normalized() * 1.8
			if approached > 8.0: _command([{"id": "arrival_beside", "type": "go_to", "location_id": _point_id(Vector2(beside.x, beside.z)), "pace": "walk"}])
			else: _command([{"id": "arrival_approach_again", "type": "approach", "target_id": "player", "distance_m": 1.7, "pace": "walk"}])
	if not is_instance_valid(_twilight):
		if await _wait(1.0): _encounter()
		return
	_command([{"id": "arrival_stay", "type": "stay", "duration_s": 600.0}, {"id": "arrival_look", "type": "look_at", "target_id": "player", "duration_s": 30.0}])
	# The encounter begins before spawning; only her actual close approach proves
	# she has found the newcomer, even if their first speech is interrupted.
	if _flat(_twilight.global_position, _feet()) <= 2.3 and _twilight.global_position.distance_to(_feet()) <= 3.0 and not bool(data.get("forest_met", false)):
		data.forest_met = true; _save()
	# Offer inspection while she greets the player, rather than adding a silent
	# fifteen-second pause afterward. An opened profile still gets reading time.
	tutorial.twilight = _twilight
	tutorial.start("inspect")
	# M-ARR-05 (threads 43664204, 43665023: "I press J, click Twilight... nothing happens"). With AI
	# usage off there is no director: no pony can speak, and every line below waited forever.
	# Then she still takes him out of the forest, once he has looked at her (or after 20 s).
	if not _dialogue_available():
		var waited := 0.0
		while str(tutorial.step) == "inspect" and waited < 20.0:
			if not await _wait(0.25) or not _found_ongoing(): return
			waited += 0.25
		tutorial.stop()
		print("[arrival] no AI dialogue: Twilight takes the newcomer to safety without talking")
		if _found_ongoing() and is_instance_valid(_twilight): request_teleport_to_ponyville(TWILIGHT, _twilight, _context_epoch)
		return
	# With dialogue, the opening now waits for him to answer her: say how, once he has looked.
	var talk_hint := func(id: String) -> void:
		if id == "inspect" and _found_ongoing() and is_instance_valid(tutorial): tutorial.start("talk")
	tutorial.step_done.connect(talk_hint)
	if not await _line("found") or stage() != "found" or bool(data.get("transport_requested", false)):
		if is_instance_valid(tutorial):
			if tutorial.step_done.is_connected(talk_hint): tutorial.step_done.disconnect(talk_hint)
			tutorial.stop()
		return
	var looked := 0.0
	while str(tutorial.step) == "inspect" and looked < 15.0 and (looked < 3.0 or bool(tutorial._seen_open)):
		if not await _wait(0.25) or stage() != "found" or bool(data.get("transport_requested", false)): return
		looked += 0.25
	if tutorial.step_done.is_connected(talk_hint): tutorial.step_done.disconnect(talk_hint)
	tutorial.stop()
	tutorial.start("talk")
	# Let it breathe (dev 2026-10-14: "Hi. Are you ok? That's a timberwolf. Ok let's go."): she
	# waits for him to answer, sits beside him, says who she is and where he is, listens; only
	# then the howls, her quiet worry, and the offer.
	if not await _breathe(8.0): return
	tutorial.stop()
	_command([{"id": "arrival_sit", "type": "sit"}, {"id": "arrival_look_sit", "type": "look_at", "target_id": "player", "duration_s": 60.0}])
	if not await _wait(1.5) or not _found_ongoing(): return
	if not await _line("settle") or not _found_ongoing(): return
	if not await _breathe(18.0): return
	_howl()
	if not await _wait(1.2) or not _found_ongoing(): return
	_command([{"id": "arrival_stand", "type": "stand"}, {"id": "arrival_look_wolf", "type": "look_at", "target_id": "player", "duration_s": 30.0}])
	if not await _line("wolves") or not _found_ongoing(): return
	if not await _breathe(5.0): return
	_howl()
	if not await _wait(1.0) or not _found_ongoing(): return
	if not await _line("teleport") or stage() != "found" or bool(data.get("transport_requested", false)): return
	if not _alive(): return
	request_teleport_to_ponyville(TWILIGHT, _twilight, _context_epoch)

## Required generated speech stays pending through provider failure or absence.
func _line(key: String) -> bool:
	var intent: String = LINES_PONY[key] if LINES_PONY.has(key) and _pony_now() else LINES[key]
	var delivered_key := "speech_" + key
	var context: Node = game.world_context
	var epoch: int = int(context.epoch)
	var line_stage := stage()
	while _alive() and not bool(data.get(delivered_key,false)):
		if int(context.epoch) != epoch or stage() != line_stage or (key in ["found", "settle", "wolves", "teleport"] and bool(data.get("transport_requested", false))): return false
		# Story speech can wait on a provider or a player interruption for any length
		# of time. If the player walks off after teleport, she comes with them.
		if key in ["found", "settle", "wolves", "teleport", "edge"] and is_instance_valid(_twilight) and game.get("player") != null:
			if not _recover_follower():
				var executor := _exec()
				if executor != null and str(executor.movement.get("type", "")) != "stay":
					_command([{"id": "arrival_rejoin_stay", "type": "stay", "duration_s": 600.0}])
		_say(TWILIGHT,intent,"arrival_" + key,null,func() -> void:
			data[delivered_key] = true; _save())
		if not await _wait(0.25): return false
	if not _alive() or int(context.epoch) != epoch or (key in ["found", "settle", "wolves", "teleport"] and bool(data.get("transport_requested", false))): return false
	if not await _wait(0.15): return false
	return int(context.epoch) == epoch and not (key in ["found", "settle", "wolves", "teleport"] and bool(data.get("transport_requested", false)))

## Twilight lifts the fallen log out of the way with her magic.
func _lift_log() -> void:
	if not is_instance_valid(pocket) or not is_instance_valid(pocket.log_node): return
	var log_node: Node3D = pocket.log_node
	var magic: Node = _twilight.get("magic") if is_instance_valid(_twilight) else null
	var meshes: Array = []
	if magic != null:
		magic.hold(true)
		meshes = magic.glow_object(log_node)
	var from := log_node.global_transform
	var aside: Vector3 = pocket.gate_dir.cross(Vector3.UP).normalized() * 2.4 + pocket.gate_dir * 0.8
	var to := Transform3D(from.basis.rotated(Vector3.UP, 1.1), from.origin + aside)
	var t := 0.0
	var lifting := true
	while t < 2.6:
		# M-ARR-03: the teleport can free the pocket (and its log) mid-lift, and a quit or reload
		# ends the wait; either way stop moving it and still let the glow and horn go.
		if not await _wait(0.03) or not is_instance_valid(log_node) or not log_node.is_inside_tree():
			lifting = false; break
		t += 0.03
		var k := smoothstep(0.0, 1.0, t / 2.6)
		var lifted := from.interpolate_with(to, k)
		lifted.origin.y += sin(k * PI) * 0.9
		log_node.global_transform = lifted
	MAGIC.unglow_object(meshes)
	if is_instance_valid(magic): magic.hold(false)
	if lifting: await _wait(0.5)

## Intent remains available throughout the local rescue. Casting still requires
## Twilight to physically rejoin the newcomer at the original close distance.
var _transport_running := false
var _transport_started := false
var _transport_queued := false
var _transport_retry := 0.0
var _transport_restoring_path := false
func can_teleport_to_ponyville(id: String, actor: Node3D) -> bool:
	return teleport_block_reason(id, actor).is_empty()

## Why Twilight cannot offer the teleport right now; empty when she can. Logged when a
## spoken teleport is refused, so a failure in play names its cause.
func teleport_block_reason(id: String, actor: Node3D) -> String:
	if not _alive(): return "arrival story not running"
	if id != TWILIGHT: return "only Twilight teleports"
	if not is_instance_valid(actor) or actor != _twilight: return "speaker is not the story's Twilight"
	if stage() != "found": return "stage is " + stage()
	if _transport_running: return "teleport already running"
	if bool(data.get("teleported", false)): return "already teleported"
	var feet := _feet()
	# Meeting is her close approach, or talking with the newcomer from conversation range:
	# the cast itself still waits until she regroups beside them (_transport_ready).
	if not bool(data.get("forest_met", false)) and not (feet.is_finite() and _flat(actor.global_position, feet) <= TELEPORT_TALK_RANGE):
		return "Twilight has not reached the newcomer"
	var runtime := _encounters()
	if runtime == null or not runtime.active(RESCUE): return "rescue encounter not active"
	var origin := WAKE
	if data.get("pocket") is Array:
		if data.pocket.size() != 3: return "saved forest pocket is invalid"
		origin = Vector3(data.pocket[0], data.pocket[1], data.pocket[2])
	if not (origin.is_finite() and feet.is_finite() and actor.global_position.is_finite()): return "positions not finite"
	if _flat(feet, origin) > 100.0 or _flat(actor.global_position, origin) > 100.0: return "too far from the forest pocket"
	return ""

## The forest intro keeps Twilight on her script until the teleport lands in Ponyville; every
## later scene lets the model send her places, follow or lead (dev 2026-10-15).
func holds_actions() -> bool:
	return _alive() and not bool(data.get("teleported", false))

## The same journey already requested or under way, from the story's own line or an earlier reply.
func teleport_pending() -> bool:
	return bool(data.get("transport_requested", false)) or _transport_running or bool(data.get("teleported", false)) or stage() == "teleport"

func _transport_ready() -> bool:
	return can_teleport_to_ponyville(TWILIGHT, _twilight) and _flat(_feet(), _twilight.global_position) <= 2.3 and _feet().distance_to(_twilight.global_position) <= 3.0

func request_teleport_to_ponyville(id: String, actor: Node3D, epoch: int) -> bool:
	if not can_teleport_to_ponyville(id, actor) or int(game.world_context.epoch) != epoch: return false
	if bool(data.get("transport_requested", false)): return true
	# This durable action receipt never claims that interrupted speech finished.
	data.transport_requested = true
	_save()
	_cancel_forest_speech()
	if is_instance_valid(tutorial): tutorial.stop()
	_tick_transport_request(0.0)
	return true

func _cancel_forest_speech() -> void:
	var director: Node = game.get("director")
	if director != null and director.has_method("cancel_authored_line"):
		for key: String in ["arrival_found", "arrival_teleport"]: director.cancel_authored_line(key)

## Serviced even while the original encounter coroutine is waiting on speech.
## Missing Twilight on a found-stage reload waits for _encounter to restore her.
func _tick_transport_request(delta: float) -> void:
	if not bool(data.get("transport_requested", false)) or _transport_running or bool(data.get("teleported", false)): return
	if not _alive() or stage() != "found" or _transport_restoring_path: return
	var runtime := _encounters()
	if runtime == null or not runtime.active(RESCUE): return
	if not is_instance_valid(_twilight): return
	if not can_teleport_to_ponyville(TWILIGHT, _twilight): return
	if _transport_ready():
		if not _transport_queued:
			_transport_queued = true
			_begin_transport.call_deferred()
		return
	_transport_retry -= delta
	if _transport_retry > 0.0: return
	_transport_retry = 2.0
	var executor := _exec()
	var movement: Dictionary = executor.movement if executor != null else {}
	var healthy_follow := str(movement.get("type", "")) == "follow" and str(movement.get("target_id", "")) == "player" and is_equal_approx(float(movement.get("distance_m", 0.0)), 1.7) and str(movement.get("status", "")) not in ["completed", "failed", "cancelled", "stopped"]
	if healthy_follow: return
	_command([{"id": "arrival_transport_rejoin", "type": "follow", "target_id": "player", "formation": "right", "distance_m": 1.7}])

func _begin_transport() -> void:
	_transport_queued = false
	# Speech completion schedules intent, not an unchecked remote cast. Recheck
	# after deferral too: the player or world may have moved since the request.
	if not bool(data.get("transport_requested", false)) or _transport_restoring_path or not _transport_ready(): return
	_transport_running = true
	_set_stage("teleport")
	_teleport()

## The flash of her teleport: both of them into Ponyville, then inside Golden Oak Library.
func _teleport() -> void:
	if not _alive() or _transport_started or (stage() != "found" and stage() != "teleport") or bool(data.get("teleported", false)): return
	_transport_started = true
	_transport_running = true
	_set_stage("teleport")
	if is_instance_valid(_twilight) and _twilight.has_method("cast_magic"): _twilight.cast_magic(3.0)
	var colour := Color("d86ef0")
	var identity: Resource = _twilight.get("identity") if is_instance_valid(_twilight) else null
	if identity != null: colour = MAGIC.color_for(identity)
	var body: Node3D = game.player.get_node("Body") if game.xr_active else game.player
	# Around the player at about chest height: AnonPony's is lower than a human's.
	var lift := 1.0
	var camera := _player()
	if _pony_now() and camera != null: lift = clampf(0.8 * (camera.global_position.y - body.global_position.y), 0.3, 1.0)
	MAGIC.burst(body, Vector3.UP * lift, colour, 2.4, 0.9)
	if is_instance_valid(_twilight): MAGIC.burst(_twilight, Vector3.UP * 1.0, colour, 2.4, 0.9)
	var flash := WAKE_SCENE.new(); flash.name = "TeleportFlash"; add_child(flash); flash.setup(game)
	flash.whiten(); flash._set_closed(0.0)
	await flash._lids(1.0, 1.1)
	if not _alive(): return
	if is_instance_valid(tutorial): tutorial.queue_free()
	if is_instance_valid(pocket): pocket.open(); pocket.queue_free()
	for apple: Node in get_tree().get_nodes_in_group("arrival_apples"): apple.queue_free()
	if is_instance_valid(_twilight):
		var actor := _twilight
		_twilight = null
		game._despawn_resident(TWILIGHT, actor)
		if _own_executor and is_instance_valid(_executor): _executor.queue_free()
		_executor = null
	_place_player(FOREST_EDGE, Vector3(0.0, 0.0, -1.0))
	await ZoneManager.wait_until_idle()
	if not await _wait(0.6): return
	# Once Ponyville is streamed, land just outside the actual library entrance under
	# the same flash. Its authored exterior approach avoids a long Town Hall detour.
	# Land inside the library itself: no walk through town to wander off from.
	var library := _library()
	var twilight_at := _feet() + Vector3(2.2, 0.0, 0.6)
	if library != null:
		var inward: Vector3 = library.center() - library.inside(); inward.y = 0.0
		_place_player(library.inside() + (inward.normalized() * 0.8 if inward.length() > 0.01 else Vector3.ZERO), inward.normalized() if inward.length() > 0.01 else Vector3(0, 0, -1))
		twilight_at = library.center()
	var spawned := 0.0
	while not is_instance_valid(_twilight) and spawned < 20.0:
		if not _spawning: _bring_twilight(twilight_at)
		if not await _wait(0.5): return
		spawned += 0.5
	if is_instance_valid(_twilight):
		_command([{"id": "arrival_edge_stay", "type": "stay", "duration_s": 60.0}, {"id": "arrival_edge_look", "type": "look_at", "target_id": "player", "duration_s": 15.0}])
	data.teleported = true; _save()
	await flash._lids(0.0, 1.2)
	flash.queue_free()
	if not _alive(): return
	_set_stage("to_library")

## Settings → World → Opening "skip" (dev 2026-10-23: "skip the intro every time and just have
## it in the ai context"): after choosing who he is, he wakes inside Golden Oak Library, and the
## world remembers the same arrival the forest opening leaves behind (Twilight found him in the
## Everfree and offered her guest bed). No forest, tutorial or teleport scene.
func _skip_opening_wanted() -> bool:
	var settings: Node = get_node_or_null("/root/Settings")
	return settings != null and str(settings.get_value("world/opening")) == "skip"

func _skip_opening() -> void:
	if not await place_at_golden_oak(): return
	data.opening_skipped = true; data.teleported = true; data.shelter_explained = true
	game.world_context.record("arrival", "Twilight found the newcomer in the Everfree, teleported them to Golden Oak Library and offered her guest bed for as long as they need.", [TWILIGHT], [TWILIGHT])
	_finish()
	print("[arrival] opening skipped; the newcomer starts in Golden Oak Library")
	if is_instance_valid(_wake_node):
		await _wake_node._lids(0.0, 1.2)
		if is_instance_valid(_wake_node): _wake_node.queue_free()

# ---------------------------------------------------------------- scenario hooks
## For scenario mods' start nodes (world/modding/scenario.gd, res://mods/README.md "Scenario mods"),
## so a mod never copies this story. end_opening() and hold_opening() belong before the opening
## starts (a start node's prepare()); the placement helpers work at any time after that.

## The opening is over without being played: no forest, tutorial, form choice or Twilight scene;
## the stage is "done" (saved), Twilight goes back to her day, the player stays where he is.
## A scenario with "skip_opening" gets this on its new world before its start node's prepare().
func end_opening(note := "") -> void:
	if stage() == "done": return
	if is_instance_valid(_wake_node):
		# Gone at once (its black must not cover the scenario's own start).
		if _wake_node.get_parent() != null: _wake_node.get_parent().remove_child(_wake_node)
		_wake_node.queue_free()
	_wake_node = null
	if is_instance_valid(tutorial): tutorial.stop()
	data.opening_skipped = true
	if not note.is_empty(): data.skipped = note
	_finish()
	print("[arrival] opening ended by ", note if not note.is_empty() else "a mod")

## While `on`, a new world's forest opening (the black wake included) waits; the scenario start
## node releases it when it emits `finished`.
func hold_opening(on: bool) -> void:
	_opening_held = on

## Puts the player's feet at `at` on the ground, facing `facing`, and streams the world there.
## Under the loading cover (in prepare()) the world then loads around that place.
func place_player(at: Vector3, facing: Vector3) -> void:
	_place_player(at, facing)

## Inside Golden Oak Library, facing in, as the "skip the opening" setting does. `via_town`: first
## stand in Ponyville and let the streaming settle (needed when he is far away). Returns false
## when the world is being left. A coroutine: await it.
func place_at_golden_oak(via_town := true) -> bool:
	if via_town or _library() == null:
		_place_player(FOREST_EDGE, Vector3(0.0, 0.0, -1.0))
		await ZoneManager.wait_until_idle()
		if not await _wait(0.6): return false
	var library := _library()
	if library != null:
		var inward: Vector3 = library.center() - library.inside(); inward.y = 0.0
		_place_player(library.inside() + (inward.normalized() * 0.8 if inward.length() > 0.01 else Vector3.ZERO), inward.normalized() if inward.length() > 0.01 else Vector3(0, 0, -1))
	return _alive()

## The whole "skip the opening" start: he wakes in Golden Oak Library, the world remembers that
## Twilight found him and offered her guest bed, and the story is done. A coroutine.
func skip_to_free_home() -> void:
	if stage() == "done": return
	if is_instance_valid(tutorial): tutorial.stop()
	await _skip_opening()

## The human Anon / AnonPony choice of a new world (stored in the world), for a scenario that
## skips the opening but still lets the player choose. A coroutine.
func choose_form() -> void:
	if game.xr_active or not PLAYER_FORM.saved(game.world_context.state).is_empty(): return
	await _choose_form()

func _ground(p: Vector3) -> Vector3:
	var h: float = WorldTerrain.instance.height_at(p) if is_instance_valid(WorldTerrain.instance) else NAN
	return Vector3(p.x, h if is_finite(h) else p.y, p.z)

static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

## A twig snapping and leaves rustling in the trees at `at`.
func _rustle(at: Vector3) -> void:
	var sound := AudioStreamPlayer3D.new()
	sound.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	sound.stream = _rustle_wav(); sound.unit_size = 6.0; sound.max_distance = 60.0; sound.volume_db = -2.0
	add_child(sound); sound.global_position = at; sound.play()
	sound.finished.connect(sound.queue_free)

static func _rustle_wav() -> AudioStreamWAV:
	var rate := 22050; var length := int(rate * 1.6)
	var bytes := PackedByteArray(); bytes.resize(length * 2)
	var noise := RandomNumberGenerator.new(); noise.seed = 11
	var low := 0.0
	for i in length:
		var t := float(i) / rate
		var snap := exp(-absf(t - 0.05) * 220.0) * 1.2 + exp(-absf(t - 0.09) * 260.0) * 0.6
		low = lerpf(low, noise.randf_range(-1.0, 1.0), 0.18)
		var rustle := low * 0.55 * smoothstep(0.15, 0.35, t) * (1.0 - smoothstep(0.9, 1.6, t)) * (0.6 + 0.4 * sin(t * 23.0))
		var v := noise.randf_range(-1.0, 1.0) * snap + rustle
		bytes.encode_s16(i * 2, roundi(clampf(v, -1.0, 1.0) * 32767))
	var wav := AudioStreamWAV.new(); wav.format = AudioStreamWAV.FORMAT_16_BITS; wav.mix_rate = rate; wav.data = bytes
	return wav

## A timberwolf howling somewhere off in the trees.
func _howl() -> void:
	var sound := AudioStreamPlayer3D.new()
	sound.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	sound.stream = load("res://world/audio/everfree/wolf01.ogg"); sound.unit_size = 30.0; sound.max_distance = 300.0; sound.volume_db = 2.0
	add_child(sound)
	var away: Vector3 = -pocket.gate_dir if is_instance_valid(pocket) else Vector3.BACK
	sound.global_position = _feet() + away.rotated(Vector3.UP, 0.6) * 45.0 + Vector3.UP * 2.0
	sound.play(); sound.finished.connect(sound.queue_free)

## Twilight is out of the town for this: she walks in from the trees near the player.
func _bring_twilight(at: Vector3) -> void:
	_spawning = true
	var live: Dictionary = game.population.live.get(TWILIGHT, {})
	if is_instance_valid(live.get("actor")):
		_adopt(live.actor); _spawning = false; return
	var path: String = game.population.available.get(TWILIGHT, "")
	if path == "": _spawning = false; return
	if ResourceLoader.load_threaded_request(path, "PackedScene") != OK: _spawning = false; return
	while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		if not await SHUTDOWN.frame(self) or not _alive(): _spawning = false; return
	if not _alive(): _spawning = false; return
	var packed := ResourceLoader.load_threaded_get(path) as PackedScene
	var actor: Node3D = null
	for region: String in ["everfree", "ponyville"]:
		if actor == null and packed != null: actor = await game._spawn_resident(TWILIGHT, "ponyville", at, packed, region)
		if not _alive():
			if is_instance_valid(actor): game._despawn_resident(TWILIGHT, actor)
			_spawning = false; return
	if actor == null:
		print("[arrival] Twilight could not arrive yet: ", game.get("spawn_failure"))
		_timer = 3.0; _spawning = false; return
	_adopt(actor)
	_spawning = false

func _adopt(actor: Node3D) -> void:
	_twilight = actor
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav != null:
		nav.wander_enabled = false
		if _encounters() != null: _encounters()._sync_presence()

## Her action executor: the AI director's own one when the AI runs (so two never drive her),
## else one owned by the story.
func _exec() -> Node:
	var director: Node = game.get("director")
	if director != null and director.get("actions") != null:
		_own_executor = false
		_executor = director.actions.executors.get(TWILIGHT)
		return _executor if is_instance_valid(_executor) else null
	if not is_instance_valid(_executor) and is_instance_valid(_twilight):
		_executor = EXECUTOR.new(); add_child(_executor); _executor.bind(_twilight); _own_executor = true
	return _executor

func _idle() -> bool:
	var executor := _exec()
	return executor != null and (executor.movement as Dictionary).is_empty()

var _sent := 0
func _command(actions: Array) -> void:
	if _exec() == null: return
	var director: Node = game.get("director")
	# Share the director's turn counter, so its own later actions are never refused as stale.
	_turn = int(director.get("_turn_id")) if director != null and not _own_executor else _turn + 1
	# The executor drops a repeat of the same id within one turn as a replay. Sharing the
	# director's turn, every re-issued lead ("asking again") was dropped while the AI was quiet
	# (dev 2026-10-01: Twilight never led him to Ponyville with the AI on), so each submission
	# gets its own id.
	_sent += 1
	var stamped: Array = []
	for action: Dictionary in actions:
		var copy := action.duplicate()
		copy.id = "%s#%d" % [str(action.get("id", "arrival")), _sent]
		stamped.append(copy)
	_executor.submit(stamped, {"player": _player()}, _turn)

# ---------------------------------------------------------------- Shelter and the following morning
func _begin_rescue() -> void:
	var runtime := _encounters()
	if runtime == null: return
	var begun: bool = runtime.begin(RESCUE, {
		"title": "helping the stranger found in the Everfree", "place": "Everfree Forest, then Golden Oak Library",
		"participants": [TWILIGHT],
		"knows": {TWILIGHT: ["You have just met this confused newcomer. Their origin and missing memories are unresolved; do not invent answers or shared history."]},
		"commitment": {TWILIGHT: "Check the newcomer's safety, introduce yourself, take them out of danger to your treehouse library, and offer its guest bed. Answer interruptions briefly without abandoning them. They may stay in your guest bed as long as they need."},
		"movers": {TWILIGHT: ["arrival"]},
		"beats": [{"id": "shelter", "speaker": TWILIGHT, "label": "bring the newcomer safely inside Golden Oak and offer shelter"}]})
	if begun: runtime._sync_presence()

func _library() -> Node3D:
	for home: Node in get_tree().get_nodes_in_group("house_interiors"):
		if home.has_method("place_id") and home.place_id() == LIBRARY: return home as Node3D
	return null

## A resumed indoor story brings Twilight to the real entrance, not an offset through a wall.
func _twilight_spawn_hint(offset: Vector3) -> Vector3:
	var feet := _feet()
	var home := HOUSE.at(get_tree(), feet)
	return home.outside() if home != null else feet + offset

var _recovering_follower := false
func _recover_follower() -> bool:
	if not is_instance_valid(_twilight): return false
	var feet := _feet()
	var gap := _flat(_twilight.global_position, feet)
	var player_room := HOUSE.at(get_tree(), feet)
	var pony_room := HOUSE.at(get_tree(), _twilight.global_position)
	var different_rooms := player_room != pony_room
	var executor := _exec()
	var movement: Dictionary = executor.movement if executor != null else {}
	if different_rooms and gap <= 4.0 and absf(feet.y - _twilight.global_position.y) < 1.0:
		var nav: Node = _twilight.get_node_or_null("Navigator")
		# Crossing the room boundary is expected while leading through a door. Replacing
		# that owned passage with follow/stay strands her between the room and grid floor.
		if nav != null and nav.house_travel.active() and nav.house_travel.phase == nav.house_travel.Phase.CROSS \
				and str(movement.get("type", "")) == "lead" and str(movement.get("status", "")) in ["accepted", "running", "blocked"] \
				and str(nav.command_owner) == str(movement.get("id", "")):
			var passage: Node3D = nav.house_travel.home
			if (player_room == null or player_room == passage) and (pony_room == null or pony_room == passage):
				different_rooms = false
	if gap > 10.0 or different_rooms or (_recovering_follower and gap > 4.0):
		var following: bool = str(movement.get("type", "")) == "follow" and str(movement.get("status", "")) not in ["completed", "failed", "cancelled"]
		if not _recovering_follower or not following:
			_command([{"id": "arrival_recover_player", "type": "follow", "target_id": "player", "formation": "right", "distance_m": 2.5}])
		_recovering_follower = true
		return true
	if _recovering_follower:
		_recovering_follower = false
		_command([{"id": "arrival_reunited", "type": "stay", "duration_s": 1.0}])
		_road_started = false
		return true
	return false

func _to_library() -> void:
	_begin_rescue()
	if not is_instance_valid(_twilight):
		if not _spawning: _bring_twilight(_twilight_spawn_hint(Vector3(-4.0, 0.0, -4.0)))
		return
	var home := _library()
	# Walking off outdoors instead of following her home turns the escort down (player board
	# #39: she would not stop following and reminding about the bed). The guest bed stays
	# offered and the opening ends here, as it does inside the library.
	if home != null and _flat(_twilight.global_position, _feet()) > 12.0 and HOUSE.at(get_tree(), _feet()) == null \
			and not home.contains(_twilight.global_position):
		if not bool(data.get("shelter_explained", false)):
			data.shelter_explained = true
			game.world_context.record("arrival", "Twilight teleported the newcomer out of the Everfree to Ponyville and offered her guest bed at Golden Oak Library for as long as they need. They chose to look around on their own first; the bed is theirs whenever they want it.", [TWILIGHT], [TWILIGHT])
			_save()
		if _encounters() != null: _encounters().complete(RESCUE)
		_finish()
		return
	if _recover_follower(): return
	if home == null: return
	if home.contains(_feet()) and home.contains(_twilight.global_position):
		var executor := _exec()
		if executor != null and str(executor.movement.get("type", "")) != "stay":
			_command([{"id": "arrival_shelter_stay", "type": "stay", "duration_s": 600.0}])
		if not bool(data.get("shelter_explained", false)):
			# With AI usage off nopony can say it: the shelter is simply his (M-ARR-05).
			if _dialogue_available(): _say(TWILIGHT, LINES.shelter, "arrival_shelter", null, _shelter_delivered)
			else: _shelter_delivered()
		if not bool(data.get("shelter_explained", false)): return
		if _encounters() != null: _encounters().complete(RESCUE)
		_finish()
		return
	if not _road_started or _idle():
		_road_started = true
		_lead(LIBRARY, "arrival_lead_library")
	# The executor retries a failed lead through the actual house adapter.

func _shelter_delivered() -> void:
	if not _alive() or bool(data.get("shelter_explained", false)): return
	data.shelter_explained = true
	game.world_context.record("arrival", "Twilight found the newcomer in the Everfree, teleported them to Golden Oak Library and offered her guest bed for as long as they need.", [TWILIGHT], [TWILIGHT])
	_save()

# ---------------------------------------------------------------- leading on foot
## The retired Celestia welcome's encounter id: old saves still carry its row, which prepare()
## cancels or migrates (the welcome, overnight and walk-home stages were retired on 2026-10-14;
## their code is in archive/arrival-legacy-routing-2026-11-08/).
const WELCOME := "arrival_welcome"
var _road_started := false    # the lead to the library was issued this stage

static func _point_id(point: Vector2) -> String:
	return "point:%.1f,%.1f" % [point.x, point.y]

func _lead(goal: String, action_id: String) -> void:
	_command([{"id": action_id, "type": "lead", "target_id": "player", "location_id": goal, "wait_distance_m": 7.0, "pace": "trot"}])

func _encounters() -> Node:
	return game.get("encounters") if game != null else null

## A pony can speak at all: the conversation director exists (game_player_rig.gd leaves it out
## exactly when AI usage is off or --no-ai is given).
func _dialogue_available() -> bool:
	return game != null and game.get("director") != null

# ---------------------------------------------------------------- the house
## The Ponyville plot house with the fewest residents, nearest `near` among equals (only the
## house `only` when one is named).
func _free_house(near: Vector3, only := "") -> Node3D:
	var population: Node = game.get("population") if game != null else null
	if population == null: return null
	var best: Node3D = null
	var best_score := INF
	var counts := {}
	population._assign_houses()
	for id: String in population.houses: counts[population.houses[id]] = int(counts.get(population.houses[id], 0)) + 1
	for node: Node in get_tree().get_nodes_in_group("house_interiors"):
		var candidate := node as Node3D
		if candidate == null or candidate.has_meta("reserved_for") or not str(candidate.get_path()).contains("PonyvilleTown/plot"): continue
		if not only.is_empty() and candidate.place_id() != only: continue
		var score := float(counts.get(candidate.place_id(), 0)) * 1000.0 + candidate.global_position.distance_to(near)
		if score < best_score: best = candidate; best_score = score
	return best

## A house can still be given: he has none yet (the opening no longer grants one, dev 2026-10-14).
func can_grant_home() -> bool:
	return _alive() and str(data.get("home", "")) == ""

## A pony's house grant ([give_house], pony_action_coordinator.gd): the vacant house he is in
## or beside (else the nearest free one) becomes his through the same saved `home` the welcome
## used, so _home_reserved keeps it his on every load: his bed, furnishing, "Your home" on the
## map and "Anon's house" in every pony's places. `place` is the house she is leading him to in
## the same reply, used when it is a vacant plot. Returns the house, or null when none is given.
func grant_home(by: String, place := "") -> Node3D:
	if not can_grant_home() or game.get("player") == null: return null
	var house: Node3D = null
	if not place.is_empty():
		var named := _free_house(Vector3.ZERO, place)
		if named != null and game.population.residents_of(place).is_empty(): house = named
	if house == null: house = _free_house(_feet())
	if house == null: return null
	data.home = house.place_id(); data.home_given_by = by; _save()
	_home_reserved()
	print("[arrival] home ", data.home, " given by ", by)
	var context: Node = game.get("world_context")
	if context != null:
		context.record("home", "%s officially gave Anon %s as his own Ponyville home, freely and for good." % [by.replace("_", " ").capitalize(), house.label()], [by], [by])
	return house

func _home_house() -> Node3D:
	var place := str(data.get("home", ""))
	if place == "": return null
	for node: Node in get_tree().get_nodes_in_group("house_interiors"):
		if (node as Node3D) != null and node.place_id() == place: return node
	return null

## Keep the granted house reserved for the player after every load (house nodes stream in).
func _home_reserved() -> void:
	if str(data.get("home", "")) == "": return
	var house := _home_house()
	if house == null: return
	# New grants reserve a real table before optional decoration. Persist that layout
	# choice for streamed/reloaded homes, without rearranging older completed homes.
	# A later pony's grant has no welcome basket, so its furniture is left as it stands.
	var welcome_grant := str(data.get("home_given_by", "")) == ""
	if welcome_grant and (not bool(data.get("furnished", false)) or bool(data.get("welcome_table_required", false))):
		if not bool(data.get("welcome_table_required", false)):
			data.welcome_table_required = true; _save()
		if house.has_method("require_welcome_table"): house.require_welcome_table()
	if str(house.get_meta("reserved_for", "")) == "player": return
	house.set_meta("reserved_for", "player")
	# M-ARR-01: the grant's own _free_house already ran this frame's assignment pass, so a plain
	# _assign_houses() returned early and the old residents stayed listed in the house until a
	# later frame. Reassign now, then refresh the desktop map (else it waits for its 2 s sample).
	var population: Node = game.get("population")
	if population == null: return
	if population.has_method("reassign_houses"): population.reassign_houses()
	else:
		population.set("_house_signature", 0)
		population._assign_houses()
	var hud: Variant = game.get("world_map")
	if not is_instance_valid(hud): return
	var map: Variant = (hud as Object).get("map")
	var tracked: Variant = (hud as Object).get("tracked")
	# The VR map (world_map_vr.gd) has no `tracked`; it samples from the head camera.
	if not is_instance_valid(tracked): tracked = (hud as Object).get("camera")
	if is_instance_valid(map) and is_instance_valid(tracked) and (map as Object).has_method("update_ponies"):
		(map as Object).call("update_ponies", tracked, true)

## The retired welcome's home step and its one-time furnishing (welcome food, starting bits).
## No stage reaches it any more (prepare() retires "home"); kept because the welcome-table
## reservation above and its fixtures (tools/life/test_welcome_food_surface.gd,
## arrival_shelter_fixture.gd, persistence_run.gd) still use the same receipts.
## Complete the welcome after reaching home; no physical token gates its use.
func _home_step() -> void:
	if not is_instance_valid(_twilight):
		if not _spawning: _bring_twilight(_twilight_spawn_hint(Vector3(4.0, 0.0, 4.0)))
		return
	if _recover_follower(): return
	if not _furnish(): return
	_say(TWILIGHT,LINES.done,"arrival_done",null,func() -> void:
		data.done_explained = true; _save())
	if not bool(data.get("done_explained",false)): return
	var runtime := _encounters()
	if runtime != null: runtime.mark_delivered(WELCOME,"home")
	_finish()

## One-time welcome food and starting bits. Furnishing runs asynchronously, so keep
## the home welcome pending until the generated furniture has a real support surface.
func _furnish() -> bool:
	if bool(data.get("furnished", false)): return true
	var house := _home_house()
	if house == null or not bool(house.get("furnish_done")): return false
	var table := _table_top(house)
	if not table.is_finite(): return false
	var granted := clampi(int(data.get("welcome_items_granted", 0)), 0, BASKET.size())
	for i in range(granted, BASKET.size()):
		var offset := _welcome_basis * _gift_offset(i)
		var rest := FOOD_CONTACT.rest_height(BASKET[i], _welcome_basis)
		var gift: RigidBody3D = game.inventory.spawn_owned_drop(BASKET[i], Transform3D(_welcome_basis, table + offset + Vector3.UP * rest))
		if gift == null: return false
		data.welcome_items_granted = i + 1; _save()
	var proposed: Dictionary = data.duplicate(true)
	proposed.furnished = true
	var saves: Node = game.get("saves")
	if not is_instance_valid(saves) or not saves.has_method("commit_arrival_welcome") or not saves.commit_arrival_welcome(proposed): return false
	data = proposed; _save()
	return true

var _welcome_basis := Basis.IDENTITY

func _gift_offset(index: int) -> Vector3:
	var row := index / 4
	# The café tabletop has a measured 4.7 mm plank seam at its centre. Keep the
	# middle row on the actual plank, without changing any collision dimensions.
	return Vector3((index % 4) * 0.13 - 0.2, 0.0, 0.02 if row == 1 else row * 0.14 - 0.14)

func _gift_support_points() -> PackedVector3Array:
	var points := PackedVector3Array()
	for i in BASKET.size():
		var bounds := FOOD_CONTACT.item_bounds(BASKET[i])
		var offset := _gift_offset(i)
		points.append(offset)
		for x: float in [bounds.position.x, bounds.end.x]:
			for z: float in [bounds.position.z, bounds.end.z]: points.append(offset + Vector3(x, 0.0, z))
	return points

## Only a measured, flat furniture collider can support the welcome food. The old
## floor fallback permanently granted it before the asynchronous layout was ready.
func _table_top(house: Node3D) -> Vector3:
	var space := house.get_world_3d().direct_space_state
	var footprint := _gift_support_points()
	var candidates := house.find_children("*", "Node3D", true, false)
	# A kitchen's whole-model box includes its sink/tap and can sit above the visible
	# counter. Prefer actual tables, and require rendered support as well as physics.
	candidates.sort_custom(func(a: Node, b: Node):
		var a_welcome := bool(a.get_meta("welcome_table", false))
		var b_welcome := bool(b.get_meta("welcome_table", false))
		if a_welcome != b_welcome: return a_welcome
		return int("table" in str(a.name).to_lower()) > int("table" in str(b.name).to_lower()))
	for node: Node in candidates:
		var name := str(node.name).to_lower()
		if not ("table" in name or "island" in name or "kitchen" in name): continue
		var surface_basis := Basis(Vector3.UP, atan2(node.global_basis.z.x, node.global_basis.z.z))
		for collision: CollisionShape3D in node.find_children("*", "CollisionShape3D", true, false):
			if collision.disabled or not collision.shape is BoxShape3D: continue
			var body := collision.get_parent() as StaticBody3D
			if body == null or (body.collision_layer & 1) == 0: continue
			var size: Vector3 = (collision.shape as BoxShape3D).size
			var box: AABB = collision.global_transform * AABB(-size * 0.5, size)
			if box.size.y < 0.3 or box.size.y > 1.4: continue
			var top := Vector3(box.get_center().x, box.end.y, box.get_center().z)
			# The whole gift footprint, not just the centre, needs tabletop support.
			var supported := true
			for offset: Vector3 in footprint:
				var point := top + surface_basis * offset
				var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(point + Vector3.UP * 0.12, point - Vector3.UP * 0.12, 1))
				if hit.is_empty() or hit.get("collider") != body or Vector3(hit.get("normal", Vector3.ZERO)).y < 0.95 or absf(Vector3(hit.get("position", Vector3.ZERO)).y - top.y) > 0.02 or not _visible_surface_at(node, point):
					supported = false; break
			if supported:
				_welcome_basis = surface_basis
				return top
	return Vector3.INF

## Inspect real triangles near the contact height, not another whole-model AABB.
## This is used once when the welcome grant is ready, never as a locomotion rule.
func _visible_surface_at(furniture: Node3D, point: Vector3) -> bool:
	for mesh: MeshInstance3D in furniture.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null or not mesh.visible: continue
		var inverse := mesh.global_transform.affine_inverse()
		var start := inverse * (point + Vector3.UP * 0.02)
		var end := inverse * (point - Vector3.UP * 0.02)
		if not mesh.get_aabb().grow(0.0001).intersects_segment(start, end): continue
		var faces := mesh.mesh.get_faces()
		for i in range(0, faces.size(), 3):
			if Geometry3D.segment_intersects_triangle(start, end, faces[i], faces[i + 1], faces[i + 2]) != null: return true
	return false

func _finish() -> void:
	_set_stage("done")
	var runtime := _encounters()
	if runtime != null: runtime.complete(WELCOME)
	var population: Node = game.get("population")
	if is_instance_valid(_twilight):
		_command([{"id": "arrival_home_again", "type": "resume_routine"}])
		# Back in the town's hands: the population and living world own her from here.
		if population != null:
			population.visiting.erase(TWILIGHT)
			if not population.live.has(TWILIGHT):
				population.live[TWILIGHT] = {"actor": _twilight, "region": "ponyville"}
				if is_instance_valid(game.get("life")): game.life.attach(TWILIGHT, _twilight)
		var nav: Node = _twilight.get_node_or_null("Navigator")
		if nav != null: nav.wander_enabled = true; nav.set("face_point", Vector3.INF)
	elif population != null:
		population.visiting.erase(TWILIGHT)
	if _own_executor and is_instance_valid(_executor): _executor.queue_free()
	_executor = null

# ---------------------------------------------------------------- speech
## Queue facts and purpose; only AI-generated, completed speech satisfies the callback.
func _say(id: String, intent: String, key: String, _actor: Node3D = null, finished := Callable()) -> void:
	if game == null: return
	var director: Node = game.get("director")
	if director == null or not director.has_method("queue_generated_intent"): return
	var context: Node = game.world_context
	var epoch: int = int(context.epoch)
	var current_stage := stage()
	var pacing := "Use at most three short spoken sentences or an equivalent brief burst, about 50 words maximum; let the reaction flow naturally rather than completing a checklist." if key == "arrival_found" else "Use at most two short sentences."
	var purpose := intent + " Speak naturally in character to the listener. " + pacing + " Never give a weather/season report, scene description, stage direction, or recap of prompt metadata. Respect their current species and what you actually know."
	director.queue_generated_intent(id,purpose,key,func() -> bool:
		return _alive() and int(context.epoch) == epoch and stage() == current_stage,finished)
