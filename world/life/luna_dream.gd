extends Node
## Luna's dream visit (dev 2026-09-29: "LUNA visit mechanic where you visit her on the moon and in
## space but you cant see equus ... because this is the most we see of it so not that for now").
## Some sleeps (world/life/player_sleep.gd) become a dream: Anon stands on the moon under a black
## sky full of stars, and Princess Luna is there to talk. No planet is shown. The dream lasts until
## he holds A / Space for a moment (the sleep button, never the B/Y talk buttons: a playtester
## talking to Luna woke up), or a few minutes pass; then the night goes on to morning, and
## Luna remembers the visit.
##
## Only when asked for: at night the wake picker (world/life/wake_picker.gd) takes a held Space / A
## as a wish to visit her (dev: the old 15 % chance came uninvited). The moon uses a detailed
## cratered surface far above the world (the town's streaming and sky are paused and restored
## around it).
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const MOON_TOP := Vector3(0.0, 9000.0, 0.0)
const MOON_RADIUS := 700.0
const MAX_SECONDS := 300.0
const LUNA_SCENE := "res://world/characters/princesses/luna.tscn"
const GREETING := "[Observed situation, not player speech] Anon is asleep, and you have drawn his dream up to you on the moon, where you keep watch over the night. You stand together on the grey dust under the stars. Greet him gently as the princess of dreams: perhaps say where he is, or ask what he dreams of. One or two short sentences; no action tags needed."
var game: Node
var active := false
var _surface_mesh: Node3D
var _root: Node3D
var _luna: Node3D
var _time := 0.0
var _hold := 0.0
var _wake_armed := false
var _saved := {}
var _end := false
var _space_active := false
const WAKE_HINT_SECONDS := 12.0
const WAKE_HINT_AGAIN := 6.0
## Longest press of the get-up button that counts as a tap (a longer B hold is talking).
const UP_TAP := 0.6
var _hint_until := 0.0
var _up_hold := 0.0

func setup(host: Node) -> void:
	game = host
	add_to_group("luna_dream")
	add_to_group("interaction_hint_sources")

## How to wake up, ahead of the player: for the first moments on the moon, and again after a tap of
## the get-up button. The dream had no word of it, and a Quest player who held B found no way back
## and closed the game (2026-11-12).
func interaction_hint() -> Dictionary:
	if not active or _time > _hint_until or not is_instance_valid(_surface_mesh) or not is_instance_valid(game): return {}
	var camera: Camera3D = game._find_camera(game.player)
	if camera == null: return {}
	var flat := -camera.global_basis.z; flat.y = 0.0
	var ahead: Vector3 = camera.global_position + (flat.normalized() if flat.length() > 0.01 else Vector3.FORWARD) * 1.2 - Vector3.UP * 0.15
	return {"target": _surface_mesh, "text": "Hold A · Wake up" if game.xr_active else "Hold Space · Wake up", "point": ahead, "outline": null, "visible_pick": true}

## A checkpoint during the dream resumes at the bed, where the real body was left.
func waking_pose() -> Dictionary:
	return {"feet": _saved.feet, "yaw": _saved.yaw} if active and _saved.has("feet") else {}

## Older checkpoints accidentally stored the temporary moon instead of the bed.
static func is_moon_position(point: Vector3) -> bool:
	return point.y >= MOON_TOP.y - MOON_RADIUS * 2.0 - 10.0 and point.y <= MOON_TOP.y + 10.0 \
		and Vector2(point.x - MOON_TOP.x, point.z - MOON_TOP.z).length() <= MOON_RADIUS + 10.0

func _exit_tree() -> void:
	# Scene reload/quit can interrupt visit() before its normal wake-up cleanup.
	active = false
	_end = true
	_space(false)
	_release_bed_claim()

func _state() -> Dictionary:
	var state: Dictionary = game.world_context.state
	if not state.get("luna_dreams") is Dictionary: state["luna_dreams"] = {"sleeps": 0, "visits": 0}
	return state.luna_dreams

## Called when a sleep begins: does this one become the dream? Only when he asked
## (`--luna-dream` forces it for testing).
func requested(asked: bool) -> bool:
	var record := _state()
	record.sleeps = int(record.sleeps) + 1
	if game.world_context.has_method("_changed"): game.world_context._changed()
	return asked or preload("res://world/dev_tools.gd").user_args().has("--luna-dream")

## The dream itself; returns a fresh cover for the rest of the night.
func visit(cover: Node) -> Node:
	active = true; _time = 0.0; _hold = 0.0; _end = false; _wake_armed = false; _hint_until = 0.0; _up_hold = 0.0
	var body: Node3D = game.player.get_node("Body") if game.xr_active else game.player
	var camera: Camera3D = game._find_camera(game.player)
	_saved = {"feet": Vector3(camera.global_position.x, body.global_position.y, camera.global_position.z), "yaw": camera.global_rotation.y,
		"seat": body.get("seat"), "lying": body.get_meta("couch_sleeping", false), "seat_return": body.get("_seat_return")}
	if body.has_method("stand_up") and body.get("seat") != null: body.stand_up()
	if is_instance_valid(body.get("seat")):
		active = false
		return cover
	# The dream borrows the body, not the player's reserved place in the bed.
	if is_instance_valid(_saved.seat): _saved.seat.set_meta("occupant", body)
	_build_moon()
	_space(true)
	_place(body, camera, _surface(Vector2.ZERO) + Vector3.UP * 0.1, 0.0)
	await _spawn_luna()
	if not is_inside_tree(): return null
	if "controls_locked" in body: body.controls_locked = false
	body.set_physics_process(true)
	await cover.open_eyes()
	if not is_inside_tree(): return null
	cover.finish()
	print("[dream] on the moon with Luna")
	_hint_until = _time + WAKE_HINT_SECONDS
	var director: Node = game.get("director")
	if director != null and is_instance_valid(_luna):
		if not await SHUTDOWN.seconds(self, 2.0): return null
		director.begin_player_greeting("luna", GREETING)
	while _time < MAX_SECONDS and not _end:
		if not await SHUTDOWN.frame(self): return null
	var next: Node = preload("res://world/ui/sleep_cover.gd").new()
	next.name = "SleepCover"; game.add_child(next); next.setup(game)
	if "controls_locked" in body: body.controls_locked = true
	await next.close_eyes()
	if not is_inside_tree() or SHUTDOWN.active: return null
	if director != null and is_instance_valid(_luna): director.unregister_character("luna")
	if is_instance_valid(_root): _root.queue_free()
	_space(false)
	_place(body, camera, _saved.feet, _saved.yaw)
	# A pony camera follows its separate avatar on the next frame. Let that
	# teleport settle before the seat access ray reads the camera position.
	for tick in 2:
		if not await SHUTDOWN.physics_frame(self): return null
	if not await SHUTDOWN.frame(self): return null
	_restore_bed(body)
	var record := _state(); record.visits = int(record.visits) + 1
	game.world_context.record("dream", "You drew Anon's dream up to the moon and spent a while with him there under the stars.", ["luna", "player"], ["luna", "player"])
	active = false
	return next

func _restore_bed(body: Node3D) -> void:
	var seat_value: Variant = _saved.get("seat")
	if not is_instance_valid(seat_value) or not body.has_method("sit_on"): return
	# Holding A to wake also takes off in wing sandals; land before the bed refuses a flier.
	var wings: Variant = body.get("wing_flight")
	if wings is Object and bool(wings.get("active")): wings.finish()
	var locked: bool = bool(body.get("controls_locked"))
	body.controls_locked = false
	if body.sit_on(seat_value):
		if _saved.get("seat_return") is Vector3: body.set("_seat_return", _saved.seat_return)
		if bool(_saved.get("lying", false)) and body.has_method("toggle_couch_sleep"): body.toggle_couch_sleep()
	body.controls_locked = locked
	_release_bed_claim()

func _release_bed_claim() -> void:
	var seat_value: Variant = _saved.get("seat")
	if not is_instance_valid(seat_value) or not seat_value.has_meta("occupant"): return
	var occupant: Variant = seat_value.get_meta("occupant")
	if is_instance_valid(occupant) and occupant.get("seat") != seat_value: seat_value.remove_meta("occupant")

func _physics_process(delta: float) -> void:
	if not active: return
	_time += delta
	# Hold A (VR) or Space (desktop) to wake up: the sleep button, not push-to-talk. A hold carried
	# over from falling asleep must be released first.
	var pressed := Input.is_action_pressed("move_jump")
	var up := InputMap.has_action("stand_up") and Input.is_action_pressed("stand_up")
	if game.xr_active:
		var right: XRController3D = game.player.find_child("XRControllerRight", true, false) as XRController3D
		pressed = right != null and right.is_button_pressed("ax_button")
		up = right != null and right.is_button_pressed("by_button")
	if up: _up_hold += delta
	else:
		if _up_hold > 0.0 and _up_hold < UP_TAP: _hint_until = _time + WAKE_HINT_AGAIN
		_up_hold = 0.0
	if not pressed: _wake_armed = true
	_hold = _hold + delta if pressed and _wake_armed else 0.0
	if _hold > 1.5: _end = true

func _place(body: Node3D, camera: Camera3D, feet: Vector3, yaw: float) -> void:
	if game.xr_active: body.get_node("XROrigin").rotate_y(yaw - camera.global_rotation.y)
	else: body.rotation.y = yaw
	body.global_position += feet - Vector3(camera.global_position.x, body.global_position.y, camera.global_position.z)
	if "velocity" in body: body.velocity = Vector3.ZERO

## Sculpted crater terrain, regolith detail, scattered rocks and a distant star field.
func _build_moon() -> void:
	_root = Node3D.new(); _root.name = "MoonDream"; game.add_child(_root)
	_surface_mesh = preload("res://world/life/moon_surface.gd").new()
	_surface_mesh.name = "LunarSurface"; _root.add_child(_surface_mesh)
	_surface_mesh.global_position = MOON_TOP
	_surface_mesh.build()
	var rng := RandomNumberGenerator.new(); rng.seed = 1969
	# Stars: small white points on a far sphere.
	var multi := MultiMesh.new(); multi.transform_format = MultiMesh.TRANSFORM_3D
	var star := QuadMesh.new(); star.size = Vector2.ONE * 2.2
	var glow := StandardMaterial3D.new(); glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; glow.albedo_color = Color(1, 1, 1)
	glow.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED; star.material = glow
	multi.mesh = star; multi.instance_count = 1800
	for i in multi.instance_count:
		var direction := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.15, 1), rng.randf_range(-1, 1)).normalized()
		multi.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * rng.randf_range(0.4, 1.3)), MOON_TOP + direction * 1400.0))
	var stars := MultiMeshInstance3D.new(); stars.name = "Stars"; stars.multimesh = multi
	stars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; stars.extra_cull_margin = 3000.0
	_root.add_child(stars)
	# Cold light from the far sun, low over the horizon.
	var light := DirectionalLight3D.new(); light.name = "DreamSun"; light.light_color = Color("dfe6ff"); light.light_energy = 1.1
	light.shadow_enabled = bool(get_node("/root/Quality").get_value("shadows_enabled", true))
	light.directional_shadow_max_distance = 90.0; _root.add_child(light)
	light.global_rotation = Vector3(-0.35, 0.9, 0.0)

func _surface(offset: Vector2) -> Vector3:
	if is_instance_valid(_surface_mesh):
		return MOON_TOP + Vector3(offset.x, _surface_mesh.height_at(offset), offset.y)
	return MOON_TOP

## Space: black sky, no fog, cold faint fill; the world's sky and lights paused meanwhile.
func _space(on: bool) -> void:
	if on == _space_active: return
	_space_active = on
	var sky: WorldEnvironment = get_tree().get_first_node_in_group("sky_controller") as WorldEnvironment
	if on:
		if sky != null and sky.has_method("begin_luna_dream"): sky.begin_luna_dream()
		# The town's map and the hotbar do not belong on the moon.
		var map: Variant = game.get("world_map") if is_instance_valid(game) else null
		if is_instance_valid(map) and (map is CanvasLayer or map is Node3D):
			_saved.map_owner = weakref(map)
			_saved.map_visible = map.visible
			if map.has_method("set_dream_suspended"):
				_saved.map_suspended = bool(map.get("_dream_suspended"))
				map.set_dream_suspended(true)
			map.visible = false
		if is_instance_valid(game.inventory) and "hud_hidden" in game.inventory:
			_saved.hud_hidden = game.inventory.hud_hidden
			game.inventory.hud_hidden = true
		_saved.paused = []
		var clock := get_node_or_null("/root/TimeOfDay")
		if clock != null: clock.hold("luna_dream")
		for node: Variant in [get_node_or_null("/root/ZoneManager"), WorldTerrain.instance, game.get("population")]:
			if is_instance_valid(node): _saved.paused.append([node, node.process_mode]); node.process_mode = Node.PROCESS_MODE_DISABLED
	else:
		if sky != null and sky.has_method("end_luna_dream"): sky.end_luna_dream()
		var clock := get_node_or_null("/root/TimeOfDay")
		if clock != null: clock.release("luna_dream")
		for pair: Array in _saved.get("paused", []):
			if is_instance_valid(pair[0]): pair[0].process_mode = pair[1]
		var map: Variant = (_saved.map_owner as WeakRef).get_ref() if _saved.get("map_owner") is WeakRef else null
		if is_instance_valid(map) and (map is CanvasLayer or map is Node3D):
			if map.has_method("set_dream_suspended"): map.set_dream_suspended(bool(_saved.get("map_suspended", false)))
			map.visible = bool(_saved.get("map_visible", false))
		_saved.erase("map_owner"); _saved.erase("map_visible"); _saved.erase("map_suspended")
		if is_instance_valid(game) and is_instance_valid(game.inventory) and "hud_hidden" in game.inventory: game.inventory.hud_hidden = bool(_saved.get("hud_hidden", false))

func _spawn_luna() -> void:
	if not ResourceLoader.exists(LUNA_SCENE): return
	if ResourceLoader.load_threaded_request(LUNA_SCENE, "PackedScene") != OK: return
	while ResourceLoader.load_threaded_get_status(LUNA_SCENE) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		if not await SHUTDOWN.frame(self): return
	var packed := ResourceLoader.load_threaded_get(LUNA_SCENE) as PackedScene
	if packed == null: return
	_luna = packed.instantiate()
	_luna.name = "DreamLuna"
	_root.add_child(_luna)
	# The pony size setting, as every pony in the world gets it (player bug board #25).
	if _luna.has_method("set_body_scale") and game.has_method("pony_scale_for"): _luna.set_body_scale(game.pony_scale_for(_luna))
	_luna.global_position = _surface(Vector2(0.0, -3.2)) + Vector3.UP * 0.05
	_luna.rotation.y = PI   # ponies face -Z; she stands at -Z of Anon, so turn her to face him
	var nav: Node = _luna.get_node_or_null("Navigator")
	if nav != null and "wander_enabled" in nav: nav.wander_enabled = false
	var director: Node = game.get("director")
	if director != null and "ai_profile" in _luna: director.register_character(_luna, str(_luna.get("ai_profile")))
