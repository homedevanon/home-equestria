extends Node3D
## Flight presentation only. Fixed stereo self sound; two nearby physical pony sources.
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const CATALOGUE := preload("res://world/audio/flight_catalogue.gd")
const STATE := preload("res://player/flight_sound_state.gd")
const NPC_RANGE := 28.0
const NPC_LIMIT := 2
var state := STATE.new()
var _host: Node
var _body: CharacterBody3D
var _model: RefCounted
var _soft := 0
var _rush := 0
var _suspended := true
var _last_actor: CharacterBody3D
var _clearance := NAN
var _near_clock := 0.0
var _nearby: Array[Dictionary] = []
var _soft_parameters := {"intensity": 0.0, "pitch": .84}
var _rush_parameters := {"intensity": 0.0, "pitch": .90}
var _beat_parameters := {"intensity": .75, "pitch": 1.0}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = 100
	SOUNDS.register_catalogue(self, CATALOGUE.EVENTS)
	for i in NPC_LIMIT:
		_nearby.append({"actor": null, "handle": 0, "phase": -1.0, "clip": "", "parameters": {"intensity": 0.0, "pitch": 1.0}})

func setup(host: Node) -> void:
	_host = host
	var rig: Node3D = host.get("player") as Node3D
	if rig == null: return
	_body = rig as CharacterBody3D
	if _body == null: _body = rig.get_node_or_null("Body") as CharacterBody3D
	if _body != null and "wing_flight" in _body:
		_model = _body.get("wing_flight") as RefCounted
		if _model != null:
			_model.activity_changed.connect(_on_activity)
			_model.takeoff_started.connect(_on_takeoff)
			_model.wingbeat_started.connect(_on_wingbeat)
	reset()

func reset() -> void:
	state.reset(); _clearance = NAN; _near_clock = 0.0
	SOUNDS.release_source(self)
	_soft = 0; _rush = 0
	for slot: Dictionary in _nearby: _release_nearby(slot)
	_last_actor = null

func _exit_tree() -> void:
	if is_instance_valid(_model):
		if _model.activity_changed.is_connected(_on_activity): _model.activity_changed.disconnect(_on_activity)
		if _model.takeoff_started.is_connected(_on_takeoff): _model.takeoff_started.disconnect(_on_takeoff)
		if _model.wingbeat_started.is_connected(_on_wingbeat): _model.wingbeat_started.disconnect(_on_wingbeat)
	reset()

func _movement_body() -> CharacterBody3D:
	if not is_instance_valid(_body): return null
	_learn_properties()
	var driver: Variant = _body.get("form_driver") if _body_has_form else null
	if is_instance_valid(driver):
		var driver_id: int = (driver as Object).get_instance_id()
		if driver_id != _seen_driver: _seen_driver = driver_id; _driver_has_avatar = "avatar" in driver
		if _driver_has_avatar and is_instance_valid(driver.avatar):
			return driver.avatar as CharacterBody3D
	return _body

func _blocked() -> bool:
	if get_tree().paused or not is_instance_valid(_body) or not is_instance_valid(_host): return true
	_learn_properties()
	return (_body.get("controls_locked") == true if _body_has_lock else false) \
		or (_host.get("title_active") == true if _host_has_title else false)

## Which optional properties the body, host and form driver scripts declare is fixed per object:
## learned once, not by string lookups twice every tick (2026-11-08 physics-step pass).
var _seen_body := 0
var _seen_host := 0
var _seen_driver := 0
var _body_has_form := false
var _body_has_lock := false
var _host_has_title := false
var _driver_has_avatar := false

func _learn_properties() -> void:
	if _body.get_instance_id() != _seen_body:
		_seen_body = _body.get_instance_id()
		_body_has_form = "form_driver" in _body
		_body_has_lock = "controls_locked" in _body
	if _host.get_instance_id() != _seen_host:
		_seen_host = _host.get_instance_id()
		_host_has_title = "title_active" in _host

func _physics_process(delta: float) -> void:
	if _blocked():
		if not _suspended: reset()
		_suspended = true
		return
	var actor := _movement_body()
	if actor == null: return
	if _suspended or actor != _last_actor:
		reset(); _suspended = false; _last_actor = actor
	global_position = actor.global_position
	var active: bool = is_instance_valid(_model) and _model.active
	state.step(actor.global_position, actor.velocity, active, active and _model.beating,
		_model.bank_angle if active else 0.0, _clearance, delta)
	if state.discontinuity:
		reset(); _last_actor = actor
		return
	_update_player_loops(active)
	_near_clock -= delta
	if _near_clock <= 0.0:
		_near_clock = .25
		_clearance = NAN
		if active and is_instance_valid(WorldTerrain.instance):
			var ground: float = WorldTerrain.instance.height_at(actor.global_position)
			if is_finite(ground): _clearance = maxf(actor.global_position.y - ground, 0.0)
		_select_nearby(actor)
	for slot: Dictionary in _nearby: _update_nearby(slot, actor)

func _update_player_loops(active: bool) -> void:
	if not active and state.soft_gain < .002 and state.rush_gain < .002:
		if _soft != 0: SOUNDS.stop_loop(self, _soft); _soft = 0
		if _rush != 0: SOUNDS.stop_loop(self, _rush); _rush = 0
		return
	_soft_parameters.intensity = state.soft_gain; _soft_parameters.pitch = state.soft_pitch
	_rush_parameters.intensity = state.rush_gain; _rush_parameters.pitch = state.rush_pitch
	if _soft == 0: _soft = SOUNDS.start_loop(self, "flight_air_soft", _soft_parameters)
	if _rush == 0: _rush = SOUNDS.start_loop(self, "flight_air_rush", _rush_parameters)
	if _soft != 0 and not SOUNDS.update_loop(self, _soft, _soft_parameters): _soft = 0
	if _rush != 0 and not SOUNDS.update_loop(self, _rush, _rush_parameters): _rush = 0

func _on_activity(active: bool) -> void:
	if active or _suspended or _blocked(): return
	var actor := _movement_body()
	if actor == null: return
	# A relocated body may retain last tick's floor flag until its next move.
	if actor.global_position.distance_squared_to(global_position) > 16.0: return
	if actor.is_on_floor(): SOUNDS.play_event(self, "flight_fold")

func _on_takeoff() -> void:
	if _suspended or _blocked(): return
	var actor := _movement_body()
	if actor != null and actor.is_on_floor(): SOUNDS.play_event(self, "flight_takeoff")

func _on_wingbeat(strength: float, seconds: float) -> void:
	if _suspended or _blocked() or not is_finite(strength) or not is_finite(seconds) or seconds <= 0.0: return
	_beat_parameters.intensity = clampf(strength * .65, .3, 1.0)
	_beat_parameters.pitch = clampf(.40 / seconds, .72, 1.18)
	SOUNDS.play_event(self, "flight_wing_self", _beat_parameters)

func _flying(actor: CharacterBody3D) -> bool:
	if not is_instance_valid(actor) or not "flight" in actor: return false
	var flight: Variant = actor.get("flight")
	return is_instance_valid(flight) and flight.active()

func _select_nearby(player_body: CharacterBody3D) -> void:
	var first: CharacterBody3D
	var second: CharacterBody3D
	var first_distance := NPC_RANGE * NPC_RANGE
	var second_distance := first_distance
	var population: Variant = _host.get("population") if "population" in _host else null
	if is_instance_valid(population) and "live" in population:
		for id: Variant in population.live:
			var entry: Dictionary = population.live[id]
			var candidate := entry.get("actor") as CharacterBody3D
			if candidate == player_body or not is_instance_valid(candidate): continue
			# Distance first: a pony no nearer than the current second choice cannot change the
			# pick, so the flight lookups run only for the few within range (45 ponies, 4 Hz).
			var distance := candidate.global_position.distance_squared_to(player_body.global_position)
			if distance >= second_distance or not _flying(candidate): continue
			if distance < first_distance:
				second = first; second_distance = first_distance; first = candidate; first_distance = distance
			elif distance < second_distance: second = candidate; second_distance = distance
	# Keep the current slot for an audible actor when their nearest order changes.
	for slot: Dictionary in _nearby:
		if slot.actor != first and slot.actor != second: _release_nearby(slot)
	for candidate: CharacterBody3D in [first, second]:
		if candidate == null: continue
		var present := false
		for slot: Dictionary in _nearby: present = present or slot.actor == candidate
		if present: continue
		for slot: Dictionary in _nearby:
			if not is_instance_valid(slot.actor): slot.actor = candidate; break

func _release_nearby(slot: Dictionary) -> void:
	if is_instance_valid(slot.actor) and int(slot.handle) != 0: SOUNDS.stop_loop(slot.actor, int(slot.handle), 0.0)
	slot.actor = null; slot.handle = 0; slot.phase = -1.0; slot.clip = ""

func _update_nearby(slot: Dictionary, player_body: CharacterBody3D) -> void:
	if not is_instance_valid(slot.actor): _release_nearby(slot); return
	var actor := slot.actor as CharacterBody3D
	if not _flying(actor) or actor.global_position.distance_squared_to(player_body.global_position) > NPC_RANGE * NPC_RANGE:
		_release_nearby(slot); return
	var velocity := actor.velocity
	if not velocity.is_finite(): _release_nearby(slot); return
	var offset := actor.global_position - player_body.global_position
	var relative_velocity := velocity - player_body.velocity
	var approach := -relative_velocity.dot(offset.normalized()) if offset.length_squared() > .01 else 0.0
	var parameters: Dictionary = slot.parameters
	parameters.intensity = smoothstep(3.0, 35.0, velocity.length()) * .75
	parameters.pitch = clampf(1.0 + approach / 343.0, .85, 1.15)
	if parameters.intensity > .01:
		if int(slot.handle) == 0: slot.handle = SOUNDS.start_loop(actor, "flight_passby", parameters)
		if int(slot.handle) != 0 and not SOUNDS.update_loop(actor, int(slot.handle), parameters): slot.handle = 0
	elif int(slot.handle) != 0:
		SOUNDS.stop_loop(actor, int(slot.handle)); slot.handle = 0
	var pose: Variant = actor.flight.pose
	if not is_instance_valid(pose) or pose.clip not in ["hover", "fly"]:
		slot.phase = -1.0; slot.clip = ""; return
	var phase: float = pose.time / float(pose.clips[pose.clip].length)
	# One shot at the authored cycle wrap; selecting a distant actor never invents a stroke.
	if str(slot.clip) == str(pose.clip) and float(slot.phase) >= 0.0 and phase < float(slot.phase):
		SOUNDS.play_event(actor, "flight_wing_nearby", {"intensity": .65, "pitch": 1.0})
	slot.phase = phase; slot.clip = pose.clip
