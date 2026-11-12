extends Node3D
## The player's hands at the spa (plan steps 8-10, wave 1): filing strokes with the hoof file, the slow back-hoof rub, wing massage and preening, plucking stray feathers, the counter
## bell. VR reads inventory.hand_sample(); desktop aims with the view and drags with the mouse
## (mouse motion is consumed while a spa drag runs, as world/relationships/cuddle/player_input.gd
## does). Everything that counts goes through spa_customers.gd; pay is never decided here.
##
## The hoof file is an ordinary briefcase item, "hoof-file" (dev 2026-10-29: "make the hoof file an
## item in your inventory"): it lies on the counter as an owned drop, the inventory picks it up,
## stashes and throws it like anything else, and filing reads whichever hand holds it. It belongs to
## the spa: once the player is outside with it (in hand or in the briefcase), or it lies outside,
## it goes back onto the counter (SPA_FILE_REST); see _keep_file_home().
##
## Sounds reuse existing foley (no downloads). TODO(Anon): a real file rasp and a contented sigh;
## the rasp is paper_0x pitched up for now. Small hints near the hoof ("File · 7/12") are allowed.
## Romance firewall, desktop keys (they reach this _input before the interactor's and the kisser's
## _unhandled_input): G does not lift a spa client (it ended her visit), a right click does not
## slap her, and K/H do not start a kiss or hug with a client face to face. VR chest grips are
## refused by pony_grabber.gd; a VR kiss or hug is ended by spa_customers._end_affection.
const STROKES := preload("res://world/minigames/spa/spa_strokes.gd")
const LOOSE_TIDY := preload("res://world/inventory/loose_tidy.gd")
const LEDGER := preload("res://world/mechanics/ledger.gd")
## K or H with a client's face this near the player's eyes is meant for her (the kisser's own reach
## is 0.85 m for a hug).
const AFFECTION_GATE := 0.9
const FEATHERS := preload("res://world/minigames/spa/spa_feathers.gd")
const SHOW_FX := preload("res://world/events/trixie_show/show_fx.gd")
const FLIGHT_INPUT := preload("res://player/wing_flight.gd")
const SIDES: Array[String] = ["left", "right"]
## The file's blade in its own frame (grip at the origin, blade toward -Z; hoof_file.glb).
const BLADE_A := Vector3(0, 0, -0.05)
const BLADE_B := Vector3(0, 0, -0.20)
const FILE_CONTACT := 0.04
const FILE_ID := "hoof-file"
const FILE_HOME_SECONDS := 1.0
## Metres from the spa within which the counter's hoof file is kept laid out (_keep_file_home).
const FILE_RESTOCK_REACH := 30.0
## A hand on her leg: contact this far past her leg radius; pressure rises from 0 there to full
## PRESS_DEPTH inside.
const RUB_CONTACT := 0.03
const PRESS_DEPTH := 0.04
const WING_CONTACT := 0.06
const PINCH_REACH := 0.05
const BELL_REACH := 0.07
const DESKTOP_REACH := 2.0
const DESKTOP_AIM := 0.09
## A massage starts from a click anywhere near her leg, not only on its centre line (dev
## 2026-10-29: "i have to look for the hitbox").
const DESKTOP_RUB_AIM := 0.2
## Desktop drags: metres per mouse pixel. The rub hand is heavy: reduced speed, ~0.4 s lag.
const DESKTOP_FILE_GAIN := 0.0006
const DESKTOP_RUB_GAIN := 0.0008
const DESKTOP_LAG := 0.4
const DESKTOP_PRESSURE := 0.7
## The rub buzz: about 8 low pulses a second, gentle to medium with pressure.
const BUZZ_RATE := 8.0
const SOUNDS := {
	"rasp": ["res://world/audio/designed/foley/paper_01.wav", "res://world/audio/designed/foley/paper_02.wav", "res://world/audio/designed/foley/paper_03.wav"],
	"cloth": ["res://world/audio/designed/foley/cloth_01.wav", "res://world/audio/designed/foley/cloth_02.wav", "res://world/audio/designed/foley/cloth_03.wav"],
	"rub": [],
	"coin": ["res://world/audio/designed/foley/coin_01.wav"],
	"bell": ["res://world/inventory/assets/deposit.wav"],
	"pluck": ["res://world/audio/designed/foley/select_01.wav"],
}

var spa: Node
var game: Node
var inventory: Node
var file_rest := Transform3D.IDENTITY
var _file_home_clock := FILE_HOME_SECONDS
## True when the last try to lay a file on the counter found no room (the 24 things out of the
## briefcase are all kept things, or the briefcase has no slot for it).
var file_blocked := false
var bell_node: Node3D
var _bell_striker: Node3D
var _bell_cooldown := 0.0
var _file_passes: Dictionary = {}
var _rub: Dictionary = {}
var _preen: Dictionary = {}
var _pinch: Dictionary = {}
var _loose: Dictionary = {}
var _pressed: Dictionary = {"left": true, "right": true}
var _trigger_down: Dictionary = {"left": true, "right": true}
var _previous_tip: Dictionary = {}
var _buzz_clock: Dictionary = {}
var _sound_clock: Dictionary = {}
var _players: Dictionary = {}
# Desktop drag state.
var _desk_mode := ""
var _desk_id := ""
var _desk_raw := Vector3.INF
var _desk_point := Vector3.INF
var _desk_along := 0.0
var _desk_pull := 0.0
var _desk_press := 0.0
var _desk_feather: Node3D
var _desk_pose_owned := false
## The rub target being massaged this frame (rub_targets row).
var _desk_leg := {}


func _ready() -> void:
	top_level = true
	process_physics_priority = -55
	process_priority = 100
	add_to_group("interaction_hint_sources")


func setup(controller: Node, host: Node) -> void:
	spa = controller
	game = host
	inventory = host.get("inventory") as Node if is_instance_valid(host) else null
	spa.bits_paid.connect(_on_paid)
	spa.reaction.connect(_on_reaction)
	for kind: String in SOUNDS:
		var player := AudioStreamPlayer3D.new()
		player.name = "Spa_" + kind
		player.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
		player.volume_db = -16.0
		player.max_distance = 12.0
		add_child(player)
		_players[kind] = player
	_place_props()


func _place_props() -> void:
	var venue: Node3D = spa.get("_venue") as Node3D
	# The interior may already carry the bell; otherwise it sits on SPA_BELL.
	bell_node = venue.find_child("spa_bell", true, false) as Node3D if is_instance_valid(venue) else null
	if bell_node == null and spa.has_marker("SPA_BELL"):
		bell_node = FEATHERS.load_prop(FEATHERS.BELL)
		if bell_node != null:
			add_child(bell_node)
			bell_node.global_transform = spa.marker("SPA_BELL")
	if bell_node != null: _bell_striker = bell_node.find_child("spa_bell_striker", true, false) as Node3D
	# The file lies on the counter: SPA_FILE_REST if the interior has it, else 0.35 m beside the bell.
	if spa.has_marker("SPA_FILE_REST"): file_rest = spa.marker("SPA_FILE_REST")
	elif spa.has_marker("SPA_BELL"):
		var bell: Transform3D = spa.marker("SPA_BELL")
		file_rest = Transform3D(bell.basis, bell.origin + bell.basis.x.normalized() * 0.35 + Vector3.UP * 0.017)
	else: file_rest = Transform3D(Basis(), Vector3.INF)


func available() -> bool:
	if not is_instance_valid(spa) or not is_instance_valid(inventory) or not is_instance_valid(inventory.get("camera")): return false
	if get_tree().paused or (inventory.has_method("_map_open") and inventory._map_open()): return false
	var case: Node = inventory.get("case") as Node
	if is_instance_valid(case) and case.get("visible") == true: return false
	if bool(inventory.get("_desktop")) and not _desktop_ready(): return false
	return true


func _desktop_ready() -> bool:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or FLIGHT_INPUT.mouse_banking(inventory.get("player_body")): return false
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return false
	var owner: Variant = inventory.get_meta("desktop_activity_owner") if inventory.has_meta("desktop_activity_owner") else null
	return not is_instance_valid(owner) or owner == self


# ------------------------------------------------------------------ the hoof file (a briefcase item)

## The hoof file in this hand ("left", "right" or "desktop"), or null.
func held_file(side: String) -> Node3D:
	if not is_instance_valid(inventory) or not inventory.get("held") is Dictionary: return null
	var item: Variant = (inventory.get("held") as Dictionary).get(side)
	if not is_instance_valid(item) or str((item as Node).get_meta("item_id", "")) != FILE_ID: return null
	return item as Node3D


## The file's blade in this hand, [a, b] in world space, or [].
func file_blade(side: String) -> Array:
	var item := held_file(side)
	if item == null: return []
	return [item.global_transform * BLADE_A, item.global_transform * BLADE_B]


## Once a second: exactly one hoof file, and it stays at the spa. Outside the spa (the player's
## head beyond the door) a file in hand or in the briefcase goes back onto the counter; a file lying
## outside goes back whatever the player does. With none at all, a new one is put on the counter.
func _keep_file_home(delta: float) -> void:
	_file_home_clock -= delta
	if _file_home_clock > 0.0: return
	_file_home_clock = FILE_HOME_SECONDS
	var venue: Node3D = spa.get("_venue") as Node3D
	var store: Variant = inventory.get("inventory")
	if not is_instance_valid(venue) or store == null or not file_rest.origin.is_finite(): return
	var camera: Node3D = inventory.get("camera") as Node3D
	if not is_instance_valid(camera): return
	var player_out: bool = not venue.is_inside(camera.global_position)
	var held: Dictionary = inventory.get("held")
	var loose: Dictionary = inventory.get("loose")
	var home: RigidBody3D = null
	for token: Variant in loose.keys():
		var item: RigidBody3D = loose[token] as RigidBody3D
		if not is_instance_valid(item) or item in held.values() or str(item.get_meta("item_id", "")) != FILE_ID: continue
		if venue.is_inside(item.global_position) and home == null: home = item
		else: _to_counter(item, str(token), store)
	if player_out:
		for side: Variant in held.keys():
			if held_file(str(side)) != null: _take_out_of_hand(str(side), store)
		store.discard(FILE_ID)
		# Away from the spa: the counter's file is laid again when he comes back within reach,
		# well before the door. The loan scan and the lay-a-file retry (a spawn, and at the loose
		# cap a tidy, every second) were the spa's per-step cost in town (W1-PERF-STEP-OTHER).
		if camera.global_position.distance_squared_to(venue.global_position) > FILE_RESTOCK_REACH * FILE_RESTOCK_REACH: return
	if home != null: file_blocked = false; return
	for item: Variant in loose.values():
		if is_instance_valid(item) and str((item as Node).get_meta("item_id", "")) == FILE_ID: file_blocked = false; return
	# A loaned file with no body in the world (out of the case, but nowhere to be found) used to
	# count as owned, so no file was laid and the guide pointed at an empty counter (thread
	# 43694970): its loan ends and a fresh file goes onto the counter.
	var lost: Array[String] = []
	for token: Variant in store.loans.keys():
		var loan: Dictionary = store.loans[token]
		if str(loan.id) == FILE_ID and not loan.get("equipped", false) and not loose.has(token): lost.append(str(token))
	for token: String in lost: store.consume(token)
	var owned := 0
	for slot: Dictionary in store.slots:
		if not slot.is_empty() and str(slot.id) == FILE_ID: owned += int(slot.count)
	# Stashed in the briefcase inside the spa: hers to take out again (the guide says so).
	if owned > 0: file_blocked = false; return
	var spawned: RigidBody3D = inventory.spawn_owned_drop(FILE_ID, file_rest)
	# At the 24-things cap a left-over mug or photo goes back into the briefcase first (M-INV-01).
	if spawned == null and LOOSE_TIDY.make_room(inventory): spawned = inventory.spawn_owned_drop(FILE_ID, file_rest)
	file_blocked = spawned == null
	if spawned != null: spawned.freeze = true


## Where the player's hoof file is, for the guide: {"where": "hand" | "loose" | "case" | "full" |
## "none", "point": world position or INF}. "loose" is a file lying inside the spa (on the counter
## or wherever it was put down); "case" is stashed in the briefcase; "full" is no room to lay one;
## "none" is a moment before the next one is laid (at most FILE_HOME_SECONDS).
func file_status() -> Dictionary:
	var none := {"where": "none", "point": Vector3.INF}
	if not is_instance_valid(inventory) or not is_instance_valid(spa): return none
	var held: Variant = inventory.get("held")
	if held is Dictionary:
		for side: Variant in (held as Dictionary).keys():
			var item := held_file(str(side))
			if item != null: return {"where": "hand", "point": item.global_position}
	var venue: Node3D = spa.get("_venue") as Node3D
	var loose: Variant = inventory.get("loose")
	if loose is Dictionary:
		for item: Variant in (loose as Dictionary).values():
			if not is_instance_valid(item) or str((item as Node).get_meta("item_id", "")) != FILE_ID: continue
			if held is Dictionary and item in (held as Dictionary).values(): continue
			var at: Vector3 = (item as Node3D).global_position
			if not is_instance_valid(venue) or not venue.has_method("is_inside") or venue.is_inside(at): return {"where": "loose", "point": at}
	var store: Variant = inventory.get("inventory")
	if store != null:
		for slot: Dictionary in store.slots:
			if not slot.is_empty() and str(slot.id) == FILE_ID: return {"where": "case", "point": Vector3.INF}
	if file_blocked: return {"where": "full", "point": Vector3.INF}
	return none


func _to_counter(item: RigidBody3D, token: String, store: Variant) -> void:
	item.linear_velocity = Vector3.ZERO; item.angular_velocity = Vector3.ZERO
	item.global_transform = file_rest
	item.freeze = true
	store.update_drops({token: file_rest})


## The file leaves the hand and the case without a drop (the way an eaten apple does,
## briefcase_held.gd); _keep_file_home then lays a fresh one on the counter.
func _take_out_of_hand(side: String, store: Variant) -> void:
	var item: RigidBody3D = (inventory.get("held") as Dictionary).get(side) as RigidBody3D
	var token := str(item.get_meta("token", ""))
	if side == "desktop": _end_desk_mode()
	if not store.consume(token): return
	inventory._unglow(item)
	(inventory.get("held") as Dictionary).erase(side)
	(inventory.get("loose") as Dictionary).erase(token)
	(inventory.get("_track") as Dictionary).erase(side)
	(inventory.get("_eat_time") as Dictionary).erase(side)
	inventory._claim(side, false)
	item.queue_free()
	inventory._refresh_holding()


# ------------------------------------------------------------------ VR

func _physics_process(delta: float) -> void:
	_bell_cooldown = maxf(0.0, _bell_cooldown - delta)
	if not is_instance_valid(spa) or not is_instance_valid(inventory): return
	_keep_file_home(delta)
	if bool(inventory.get("_desktop")):
		_desktop_tick(delta)
		return
	if _hands_idle_far(): return
	for side: String in SIDES:
		var sample: Dictionary = inventory.hand_sample(side)
		var pose: Transform3D = sample.get("pose", sample.get("aim", Transform3D.IDENTITY))
		var active: bool = available() and sample.get("active", false) and pose.is_finite()
		var grip := float(sample.get("grip", 0.0))
		var trigger := float(sample.get("trigger", 0.0))
		var palm: Vector3 = sample.get("grip_position", pose.origin)
		var tip: Vector3 = sample.get("tip", palm)
		if held_file(side) != null:
			if active: _file_contact(side, delta)
		elif active:
			if _loose.has(side): _carry_loose(side, tip, trigger)
			elif _pinch.has(side) or (trigger > 0.6 and not _trigger_down[side]): _pinch_tick(side, tip, trigger > 0.45, delta)
			else:
				var pressure := _rub_contact(side, palm, delta)
				if pressure < 0.0: _wing_contact(side, palm, delta)
				_bell_contact(side, tip, delta)
		else:
			_drop_hand(side)
		_pressed[side] = grip > 0.45 if active else true
		_trigger_down[side] = trigger > 0.6 if active else true
		_previous_tip[side] = tip if active else Vector3.INF


## VR, the player's head beyond FILE_RESTOCK_REACH of the spa with nothing of it in hand: no hand
## can reach a client, a feather or the bell, so the per-hand sampling stops (W1-PERF-STEP-OTHER
## hook 2). The hands read as inactive, as they would there: no press edge carries back in.
func _hands_idle_far() -> bool:
	if not (_loose.is_empty() and _pinch.is_empty() and _rub.is_empty() and _preen.is_empty()): return false
	var venue: Node3D = spa.get("_venue") as Node3D
	var camera: Node3D = inventory.get("camera") as Node3D
	if not is_instance_valid(venue) or not is_instance_valid(camera): return false
	if camera.global_position.distance_squared_to(venue.global_position) <= FILE_RESTOCK_REACH * FILE_RESTOCK_REACH: return false
	for side: String in SIDES:
		if held_file(side) != null: return false
	for side: String in SIDES:
		_pressed[side] = true; _trigger_down[side] = true; _previous_tip[side] = Vector3.INF
	return true


func _drop_hand(side: String) -> void:
	_rub.erase(side); _preen.erase(side); _pinch.erase(side)
	if _loose.has(side):
		var loose: Node3D = _loose[side]
		_loose.erase(side)
		if is_instance_valid(loose): spa.drop_feather(loose)


## The file's blade across a raised front hoof: within FILE_CONTACT of its tip, and each one-way
## pass along the blade counts (dust puff, rasp, buzz).
func _file_contact(side: String, delta: float) -> void:
	var blade := file_blade(side)
	if blade.is_empty(): return
	var a: Vector3 = blade[0]
	var b: Vector3 = blade[1]
	var axis := (b - a).normalized()
	for target: Dictionary in spa.filing_targets((a + b) * 0.5, 0.4):
		var tip: Vector3 = target.tip
		var touching := Geometry3D.get_closest_point_to_segment(tip, a, b).distance_to(tip) <= FILE_CONTACT
		var id: String = target.id
		if not _file_passes.has(id): _file_passes[id] = STROKES.Passes.new(0.035)
		# Where on the blade the hoof is: the blade moving across it changes this.
		var along := (tip - a).dot(axis)
		if _file_passes[id].feed(touching, along, delta): _filed(id, tip, side, int(target.strokes) + 1)
		if touching: return


func _filed(id: String, tip: Vector3, side: String, count: int) -> void:
	if not spa.file_stroke(id): return
	SHOW_FX.puff(self, tip, Color(0.84, 0.8, 0.72), 0.06)
	_buzz(side, 0.3, 0.03)
	# The rasp gets smoother (lower, softer) as the hoof is done.
	var smooth := clampf(float(count) / float(spa.FILE_STROKES), 0.0, 1.0)
	_play("rasp", tip, lerpf(1.7, 1.25, smooth), lerpf(-14.0, -20.0, smooth))


## A hand on a resting back hoof. Returns the pressure, or -1 when not on a rub client's leg.
func _rub_contact(side: String, palm: Vector3, delta: float) -> float:
	for target: Dictionary in spa.rub_targets(palm, 0.25):
		var on := leg_point(target, palm)
		var closest: Vector3 = on.point
		var gap := palm.distance_to(closest) - float(on.radius)
		if gap > RUB_CONTACT: continue
		# Pressure builds from first contact, not only past her leg's surface: the palm point sits
		# inside the hand, which stops at her skin, so the massage stayed at 0% in VR (player board #43).
		var pressure := clampf((RUB_CONTACT - gap) / (RUB_CONTACT + PRESS_DEPTH), 0.0, 1.0)
		# The detector measures the tracked palm, not the contact on her leg: a held hoof that shakes
		# (a filly's flips at its joint limit, a rotation) is not the hand rubbing fast.
		_rub_feed(side, target.id, palm, pressure, (closest - palm).normalized() * PRESS_DEPTH * pressure, delta, "rub")
		return pressure
	if _rub.has(side) and str(_rub[side].kind) == "rub": _rub.erase(side)
	return -1.0


## The nearest point on a rub target's leg, hoof to hip: {point, radius} (thicker up the thigh).
static func leg_point(target: Dictionary, point: Vector3) -> Dictionary:
	var lower := Geometry3D.get_closest_point_to_segment(point, target.top, target.bottom)
	if not target.has("upper"): return {"point": lower, "radius": float(target.radius)}
	var upper := Geometry3D.get_closest_point_to_segment(point, target.upper, target.top)
	if upper.distance_to(point) >= lower.distance_to(point): return {"point": lower, "radius": float(target.radius)}
	# The thigh thickens from the hock (lower radius) to the hip.
	var span: float = Vector3(target.upper).distance_to(target.top)
	var up := clampf(upper.distance_to(target.top) / maxf(span, .001), 0.0, 1.0)
	return {"point": upper, "radius": lerpf(float(target.radius), float(target.get("upper_radius", target.radius)), up)}


func _rub_feed(side: String, id: String, point: Vector3, pressure: float, push: Vector3, delta: float, kind: String) -> void:
	if not _rub.has(side) or _rub[side].id != id or _rub[side].kind != kind:
		_rub[side] = {"id": id, "kind": kind, "detector": STROKES.SlowRub.new()}
	var detector: STROKES.SlowRub = _rub[side].detector
	var credited := detector.feed(true, point, pressure, delta)
	if kind == "rub": spa.rub(id, credited, pressure, push)
	elif credited > 0.0: spa.wing_massage(id, credited)
	if detector.too_fast and kind == "rub": spa.rub_too_fast(id)
	# A slow, low buzz under pressure, and a soft cloth sound that quietens as she relaxes.
	_buzz_clock[side] = float(_buzz_clock.get(side, 0.0)) - delta
	if detector.in_pass() and float(_buzz_clock[side]) <= 0.0:
		_buzz_clock[side] = 1.0 / BUZZ_RATE
		_buzz(side, 0.12 + 0.35 * pressure, 0.05)
	_sound_clock[side] = float(_sound_clock.get(side, 0.0)) - delta
	if detector.in_pass() and float(_sound_clock[side]) <= 0.0:
		_sound_clock[side] = 0.85
		_play("rub", point, 1.0, -20.0 - 4.0 * detector.pass_ratio())


## A hand on her open wing: slow massage (the same slow-rub rule) and base-to-tip preening.
func _wing_contact(side: String, palm: Vector3, delta: float) -> void:
	for target: Dictionary in spa.wing_targets(palm, 0.6):
		for segment: Array in target.wings:
			var base: Vector3 = segment[0]
			var tip: Vector3 = segment[1]
			var closest := Geometry3D.get_closest_point_to_segment(palm, base, tip)
			if palm.distance_to(closest) > WING_CONTACT: continue
			_rub_feed(side, target.id, closest, 0.6, Vector3.ZERO, delta, "wing")
			if not _preen.has(side): _preen[side] = STROKES.Passes.new(0.08, 1)
			if _preen[side].feed(true, (closest - base).dot((tip - base).normalized()), delta):
				spa.preen_stroke(target.id)
				_play("cloth", closest, 1.1, -22.0)
			return
	if _rub.has(side) and str(_rub[side].kind) == "wing": _rub.erase(side)
	if _preen.has(side): _preen[side].feed(false, 0.0, delta)


## Trigger near a stray feather: it bends toward the hand, resists, then pops free.
func _pinch_tick(side: String, tip: Vector3, pinching: bool, delta: float) -> void:
	if not _pinch.has(side):
		var best := _nearest_feather(tip, PINCH_REACH)
		if best.is_empty(): return
		_pinch[side] = {"id": best.id, "feather": best.feather, "pull": STROKES.FeatherPull.new()}
	var pinch: Dictionary = _pinch[side]
	var feather: Node3D = pinch.feather
	if not is_instance_valid(feather): _pinch.erase(side); return
	var result: String = pinch.pull.feed(pinching, tip.distance_to(FEATHERS.root_point(feather)), delta)
	match result:
		"resist":
			FEATHERS.bend(feather, tip, pinch.pull.bend())
		"pop":
			_pinch.erase(side)
			var loose: Node3D = spa.pluck(pinch.id, feather, get_tree().current_scene if get_tree().current_scene != null else self)
			if loose != null:
				loose.call("hold", side)
				_loose[side] = loose
				_buzz(side, 0.6, 0.02)
				_play("pluck", tip, 1.3, -16.0)
		_:
			if is_instance_valid(feather): FEATHERS.bend(feather, tip, 0.0)
			_pinch.erase(side)


func _nearest_feather(point: Vector3, reach: float) -> Dictionary:
	var best := {}
	var distance := reach
	for target: Dictionary in spa.wing_targets(point, 0.8):
		for feather: Node3D in target.feathers:
			var gap := minf(point.distance_to(FEATHERS.tip_point(feather)), point.distance_to(FEATHERS.root_point(feather)))
			if gap < distance: distance = gap; best = {"id": target.id, "feather": feather}
	return best


func _carry_loose(side: String, tip: Vector3, trigger: float) -> void:
	var loose: Node3D = _loose[side]
	if not is_instance_valid(loose): _loose.erase(side); return
	loose.global_position = tip
	if trigger < 0.3:
		_loose.erase(side)
		spa.drop_feather(loose)


## A downward tap on the bell's striker.
func _bell_contact(side: String, tip: Vector3, delta: float) -> void:
	if bell_node == null or _bell_cooldown > 0.0: return
	var top := _bell_top()
	var previous: Vector3 = _previous_tip.get(side, Vector3.INF)
	if not previous.is_finite() or tip.distance_to(top) > BELL_REACH: return
	if (previous.y - tip.y) / maxf(delta, 0.001) > 0.25: ring(side)


func _bell_top() -> Vector3:
	return _bell_striker.global_position + Vector3.UP * 0.01 if _bell_striker != null else bell_node.global_position + Vector3.UP * 0.1


func ring(side: String) -> void:
	_bell_cooldown = 1.0
	_play("bell", _bell_top(), 1.0, -12.0)
	_buzz(side, 0.4, 0.03)
	if _bell_striker != null:
		var rest := _bell_striker.position
		var tween := create_tween()
		tween.tween_property(_bell_striker, "position", rest + Vector3.DOWN * 0.006, 0.05)
		tween.tween_property(_bell_striker, "position", rest, 0.12)
	if spa.has_method("ring_bell"): spa.ring_bell()


# ------------------------------------------------------------------ desktop

func _aim() -> Dictionary:
	var camera: Camera3D = inventory.get("camera") as Camera3D
	return {"from": camera.global_position, "dir": -camera.global_basis.z.normalized(), "camera": camera}


## Distance from the view ray to a point, or INF beyond reach / behind.
func _ray_gap(point: Vector3) -> float:
	var aim := _aim()
	var along: float = (point - aim.from).dot(aim.dir)
	if along < 0.05 or along > DESKTOP_REACH: return INF
	return point.distance_to(aim.from + aim.dir * along)


func _ray_segment(a: Vector3, b: Vector3) -> Dictionary:
	var aim := _aim()
	var points := Geometry3D.get_closest_points_between_segments(aim.from, aim.from + aim.dir * DESKTOP_REACH, a, b)
	return {"gap": points[0].distance_to(points[1]), "point": points[1]}


func _input(event: InputEvent) -> void:
	if event is InputEventKey and preload("res://world/ui/typing_guard.gd").active(): return  # typing never drives the game
	if not is_instance_valid(inventory) or not bool(inventory.get("_desktop")): return
	if (event is InputEventKey or event is InputEventMouseButton) and event.is_pressed() and _firewall(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		if not _desk_mode.is_empty():
			_end_desk_mode()
			get_viewport().set_input_as_handled()
		return
	if not available(): return
	if event is InputEventMouseMotion and not _desk_mode.is_empty():
		_desk_drag(event.relative)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _desk_begin(): get_viewport().set_input_as_handled()


## Desktop romance firewall (header): true when this press would lift, slap, kiss or hug a spa
## client, and is kept from the interactor (G), desktop_interactions (right click) and the kisser
## (K, H). Only while there are clients; nothing else is touched.
func _firewall(event: InputEvent) -> bool:
	if not is_instance_valid(spa) or spa.clients().is_empty() or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED: return false
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return false
	var target := firewall_target(event)
	if target == null: return false
	print("[spa] firewall: %s kept off spa client %s" % [event.as_text(), target.name])
	LEDGER.say(inventory, "Spa clients are not picked up; she is here for hoof care." if event is InputEventKey \
		and (event as InputEventKey).physical_keycode == KEY_G else "She is here for hoof care.")
	return true


## The spa client this desktop press would lift (G), slap (right click), kiss (K) or hug (H), or null.
func firewall_target(event: InputEvent) -> Node3D:
	var desk: Node = get_tree().get_first_node_in_group("desktop_interactions")
	var target: Node3D = null
	if event is InputEventMouseButton:
		if (event as InputEventMouseButton).button_index != MOUSE_BUTTON_RIGHT or desk == null or not desk.has_method("_select"): return null
		var offer: Variant = desk.call("_select", true)
		if offer is Dictionary: target = (offer as Dictionary).get("target") as Node3D
	elif event is InputEventKey and not (event as InputEventKey).echo:
		match (event as InputEventKey).physical_keycode:
			KEY_G:
				var interactor: Node = desk.get("interactor") as Node if desk != null else null
				# G with a pony in his arms sets her down or throws her: not a pickup.
				if interactor == null or interactor.get("held") != null or not interactor.has_method("_looking_at_pony"): return null
				target = interactor.call("_looking_at_pony") as Node3D
			KEY_K, KEY_H:
				target = _client_face_near(AFFECTION_GATE)
	return target if is_instance_valid(target) and target.has_meta("spa_client") else null


## The spa client whose face is nearest the player's eyes within `reach`, or null.
func _client_face_near(reach: float) -> Node3D:
	var camera: Node3D = inventory.get("camera") as Node3D
	var population: Node = game.get("population") as Node if is_instance_valid(game) else null
	if not is_instance_valid(camera) or not is_instance_valid(population): return null
	var live: Variant = population.get("live")
	if not live is Dictionary: return null
	var best: Node3D = null
	for id: String in spa.clients():
		var entry: Variant = (live as Dictionary).get(id)
		var actor: Variant = (entry as Dictionary).get("actor") if entry is Dictionary else null
		if not is_instance_valid(actor) or not (actor as Node).has_method("listen_point"): continue
		var gap: float = Vector3((actor as Node).call("listen_point")).distance_to(camera.global_position)
		if gap < reach: reach = gap; best = actor as Node3D
	return best


## What a left click starts, in order: filing (file in hand), a feather, the bell, a back hoof, a
## wing. The file itself is picked up, stashed and thrown by the inventory (E, Q).
func _desk_begin() -> bool:
	if held_file("desktop") != null:
		for target: Dictionary in spa.filing_targets(Vector3.INF):
			if _ray_gap(target.tip) <= DESKTOP_AIM:
				return _desk_start("file", target.id, target.tip)
		# A filed hoof is massaged next; the file stays in the other hand meanwhile.
		return _desk_begin_rub()
	var feather := {}
	var best := DESKTOP_AIM * 0.5
	for target: Dictionary in spa.wing_targets(Vector3.INF):
		for node: Node3D in target.feathers:
			var gap := _ray_gap(FEATHERS.tip_point(node))
			if gap < best: best = gap; feather = {"id": target.id, "feather": node}
	if not feather.is_empty():
		_desk_feather = feather.feather
		return _desk_start("pluck", feather.id, FEATHERS.tip_point(_desk_feather))
	if bell_node != null and _ray_gap(_bell_top()) <= DESKTOP_AIM and _bell_cooldown <= 0.0:
		ring("desktop")
		return true
	if _desk_begin_rub(): return true
	for target: Dictionary in spa.wing_targets(Vector3.INF):
		for segment: Array in target.wings:
			var hit := _ray_segment(segment[0], segment[1])
			if float(hit.gap) <= DESKTOP_AIM: return _desk_start("wing", target.id, hit.point)
	return false


func _desk_begin_rub() -> bool:
	for target: Dictionary in spa.rub_targets(Vector3.INF):
		var best := _ray_segment(target.top, target.bottom)
		if target.has("upper"):
			var thigh := _ray_segment(target.upper, target.top)
			if float(thigh.gap) < float(best.gap): best = thigh
		if float(best.gap) <= DESKTOP_RUB_AIM: return _desk_start("rub", target.id, best.point)
	return false


func _desk_start(mode: String, id: String, point: Vector3) -> bool:
	_desk_mode = mode; _desk_id = id
	_desk_raw = point; _desk_point = point
	_desk_along = 0.0; _desk_pull = 0.0; _desk_press = 0.0
	inventory.set_meta("desktop_activity_owner", self)
	return true


func _desk_drag(relative: Vector2) -> void:
	var camera: Camera3D = inventory.get("camera") as Camera3D
	match _desk_mode:
		"file":
			_desk_along += relative.x * DESKTOP_FILE_GAIN
		"pluck":
			_desk_pull += relative.length() * DESKTOP_RUB_GAIN
		"rub", "wing":
			_desk_raw += camera.global_basis.x * relative.x * DESKTOP_RUB_GAIN - camera.global_basis.y * relative.y * DESKTOP_RUB_GAIN


func _desktop_tick(delta: float) -> void:
	if _desk_mode.is_empty(): return
	if not available(): _end_desk_mode(); return
	match _desk_mode:
		"file":
			var target := _desk_target_tip()
			if not target.is_finite(): _end_desk_mode(); return
			_desk_point = target
			if not _file_passes.has(_desk_id): _file_passes[_desk_id] = STROKES.Passes.new(0.035)
			if _file_passes[_desk_id].feed(_ray_gap(target) <= DESKTOP_AIM * 1.5, _desk_along, delta):
				_filed(_desk_id, target, "desktop", _strokes_of(_desk_id) + 1)
		"rub", "wing":
			var segment := _desk_segment()
			if segment.is_empty(): _end_desk_mode(); return
			# Keep the hand on her leg or wing; it follows the mouse through thick oil. A leg is
			# hoof to hip, so the hand slides up her thigh too.
			var on: Vector3 = leg_point(_desk_leg, _desk_raw).point if _desk_mode == "rub" else Geometry3D.get_closest_point_to_segment(_desk_raw, segment[0], segment[1])
			_desk_raw = on + (_desk_raw - on).limit_length(0.03)
			_desk_point = _desk_point.lerp(_desk_raw, 1.0 - exp(-delta / DESKTOP_LAG))
			_desk_press = move_toward(_desk_press, DESKTOP_PRESSURE, delta / 0.5)
			var push: Vector3 = -(inventory.get("camera") as Camera3D).global_basis.z * 0.01 * _desk_press
			_rub_feed("desktop", _desk_id, _desk_point, _desk_press, push, delta, _desk_mode)
			if _desk_mode == "wing":
				if not _preen.has("desktop"): _preen["desktop"] = STROKES.Passes.new(0.08, 1)
				if _preen["desktop"].feed(true, (_desk_point - segment[0]).dot((segment[1] - segment[0]).normalized()), delta):
					spa.preen_stroke(_desk_id)
			if _desk_mode == "rub": _present_palm(_desk_point, _desk_leg)
			else: _present_hand(_desk_point)
		"pluck":
			if _loose.has("desktop"):
				var loose: Node3D = _loose["desktop"]
				var camera: Camera3D = inventory.get("camera") as Camera3D
				if is_instance_valid(loose): loose.global_position = camera.global_transform * Vector3(0.1, -0.12, -0.45)
				return
			if not is_instance_valid(_desk_feather): _end_desk_mode(); return
			var pull: STROKES.FeatherPull = _pinch.get("desktop", {}).get("pull") if _pinch.has("desktop") else null
			if pull == null:
				pull = STROKES.FeatherPull.new()
				_pinch["desktop"] = {"id": _desk_id, "feather": _desk_feather, "pull": pull}
			var result := pull.feed(true, _desk_pull, delta)
			if result == "resist":
				FEATHERS.bend(_desk_feather, (inventory.get("camera") as Camera3D).global_position, pull.bend())
			elif result == "pop":
				_pinch.erase("desktop")
				var loose: Node3D = spa.pluck(_desk_id, _desk_feather, get_tree().current_scene if get_tree().current_scene != null else self)
				_desk_feather = null
				if loose != null:
					loose.call("hold", "desktop")
					_loose["desktop"] = loose
					_play("pluck", loose.global_position, 1.3, -16.0)


## Desktop filing: the held file sweeps across the hoof front with the mouse. Runs after the
## inventory has placed the held item for this frame (process_priority in _ready).
func _process(_delta: float) -> void:
	if _desk_mode != "file" or not _desk_point.is_finite(): return
	var item := held_file("desktop")
	if item == null: return
	var camera: Camera3D = inventory.get("camera") as Camera3D
	var across: Vector3 = camera.global_basis.x
	var at := _desk_point + across * _desk_along - (-camera.global_basis.z) * 0.02
	item.global_transform = Transform3D(Basis.looking_at(across, Vector3.UP), at - across * 0.125)


func _desk_target_tip() -> Vector3:
	for target: Dictionary in spa.filing_targets(Vector3.INF):
		if target.id == _desk_id: return target.tip
	return Vector3.INF


func _strokes_of(id: String) -> int:
	for target: Dictionary in spa.filing_targets(Vector3.INF):
		if target.id == id: return int(target.strokes)
	return 0


func _desk_segment() -> Array:
	if _desk_mode == "rub":
		for target: Dictionary in spa.rub_targets(Vector3.INF):
			if target.id == _desk_id:
				_desk_leg = target
				return [target.top, target.bottom]
	else:
		for target: Dictionary in spa.wing_targets(Vector3.INF):
			if target.id != _desk_id: continue
			var best := []
			var gap := INF
			for segment: Array in target.wings:
				var d := Geometry3D.get_closest_point_to_segment(_desk_raw, segment[0], segment[1]).distance_to(_desk_raw)
				if d < gap: gap = d; best = segment
			return best
	return []


func _end_desk_mode() -> void:
	if _loose.has("desktop"):
		var loose: Node3D = _loose["desktop"]
		_loose.erase("desktop")
		if is_instance_valid(loose): spa.drop_feather(loose)
	if _pinch.has("desktop"):
		var feather: Node3D = _pinch["desktop"].feather
		if is_instance_valid(feather): FEATHERS.bend(feather, Vector3.INF, 0.0)
	_pinch.erase("desktop"); _rub.erase("desktop"); _preen.erase("desktop")
	_desk_mode = ""; _desk_id = ""; _desk_feather = null
	_clear_hand()
	_end_desktop_owner()


func _end_desktop_owner() -> void:
	if is_instance_valid(inventory) and inventory.has_meta("desktop_activity_owner") and inventory.get_meta("desktop_activity_owner") == self:
		inventory.remove_meta("desktop_activity_owner")


func cancel_desktop_activity() -> void:
	_end_desk_mode()


func _present_hand(point: Vector3) -> void:
	var visual: Node = inventory.get("desktop_presentation") as Node
	if not is_instance_valid(visual) or not visual.has_method("set_hold_target"): return
	var camera: Camera3D = inventory.get("camera") as Camera3D
	visual.set_hold_target("right", Transform3D(camera.global_basis.orthonormalized(), point + camera.global_basis.z * 0.03), "hold")
	_desk_pose_owned = true


## The massaging hand flat on her leg, palm toward it, fingers along it (dev 2026-10-29: "my hand
## is not angled to actually ... palm towards the hoof"). The frame is the desktop slap's palm frame
## (desktop_anon.gd): X out of the surface toward the player, fingers along -Z.
func _present_palm(point: Vector3, leg: Dictionary) -> void:
	var visual: Node = inventory.get("desktop_presentation") as Node
	if not is_instance_valid(visual) or not visual.has_method("set_hold_target") or leg.is_empty(): return
	var camera: Camera3D = inventory.get("camera") as Camera3D
	var on: Dictionary = leg_point(leg, point)
	var along: Vector3 = (Vector3(leg.top) - Vector3(leg.bottom)).normalized()
	if leg.has("upper") and Vector3(on.point).distance_to(leg.upper) < Vector3(on.point).distance_to(leg.bottom) * .5:
		along = (Vector3(leg.upper) - Vector3(leg.top)).normalized()
	var out: Vector3 = camera.global_position - Vector3(on.point)
	out = (out - along * out.dot(along)).normalized()
	if not out.is_finite() or out.length_squared() < .5: out = camera.global_basis.z
	var fingers := (along - out * along.dot(out)).normalized()
	var palm: Vector3 = Vector3(on.point) + out * (float(on.radius) + 0.035)
	visual.set_hold_target("right", Transform3D(Basis(out, -fingers.cross(out), -fingers).orthonormalized(), palm), "rub")
	_desk_pose_owned = true


func _clear_hand() -> void:
	if not _desk_pose_owned: return
	_desk_pose_owned = false
	var visual: Node = inventory.get("desktop_presentation") as Node if is_instance_valid(inventory) else null
	if is_instance_valid(visual) and visual.has_method("clear_hold_target"): visual.clear_hold_target("right")


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_instance_valid(inventory) and bool(inventory.get("_desktop")):
		cancel_desktop_activity()


# ------------------------------------------------------------------ feedback

func _buzz(side: String, amplitude: float, seconds: float) -> void:
	if not is_instance_valid(inventory) or not inventory.get("controllers") is Dictionary: return
	var controller: Variant = (inventory.get("controllers") as Dictionary).get(side)
	if controller is XRController3D and controller.get_is_active():
		controller.trigger_haptic_pulse("haptic", 0.0, clampf(amplitude, 0.0, 1.0), seconds, 0.0)


func _play(kind: String, at: Vector3, pitch: float, volume: float) -> void:
	var player: AudioStreamPlayer3D = _players.get(kind)
	if player == null: return
	if kind == "rub":
		player.stream = _rub_sound()
		player.global_position = at
		player.pitch_scale = pitch * randf_range(0.9, 1.1)
		player.volume_db = volume
		player.play()
		return
	var paths: Array = SOUNDS[kind]
	var path: String = paths[randi() % paths.size()]
	if not ResourceLoader.exists(path): return
	player.stream = load(path)
	player.global_position = at
	player.pitch_scale = pitch * randf_range(0.95, 1.05)
	player.volume_db = volume
	player.play()


## The massage: a soft, low brush of a palm over a coat, made once here. The crinkly cloth foley
## with its sharp clicks sounded like crushing a plastic bottle (player board #42).
static var _rub_stream: AudioStreamWAV
static func _rub_sound() -> AudioStreamWAV:
	if _rub_stream != null: return _rub_stream
	var rate := 22050
	var count := int(rate * 0.9)
	var rng := RandomNumberGenerator.new(); rng.seed = 4242
	var data := PackedByteArray(); data.resize(count * 2)
	var low := 0.0
	var lower := 0.0
	for i in count:
		# White noise through two one-pole low passes (a dull hush, no clicks), under a slow
		# swell-and-fade envelope.
		low += 0.03 * (rng.randf_range(-1.0, 1.0) - low)
		lower += 0.12 * (low - lower)
		var t := float(i) / float(count)
		var envelope := pow(sin(PI * t), 1.5)
		data.encode_s16(i * 2, int(clampf(lower * envelope * 5.0, -1.0, 1.0) * 26000.0))
	_rub_stream = AudioStreamWAV.new()
	_rub_stream.format = AudioStreamWAV.FORMAT_16_BITS
	_rub_stream.mix_rate = rate
	_rub_stream.data = data
	return _rub_stream


func _on_paid(_id: String, amount: int, at: Vector3, _what: String) -> void:
	_play("coin", at, 1.0, -14.0)
	var label := Label3D.new()
	label.text = "+%d bit%s" % [amount, "" if amount == 1 else "s"]
	label.font_size = 48; label.pixel_size = 0.0012; label.outline_size = 10
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color(1.0, 0.86, 0.35)
	add_child(label)
	label.global_position = at
	var tween := create_tween()
	tween.tween_property(label, "global_position", at + Vector3.UP * 0.3, 1.5)
	tween.parallel().tween_property(label, "modulate:a", 0.0, 1.5)
	tween.tween_callback(label.queue_free)


func _on_reaction(_id: String, _kind: String) -> void:
	pass  # TODO(wave 2): ear flick, wince and stretch on her rig (no API yet).


## Small contextual hints only (plan: "File · 7/12" near the hoof, no panel).
func interaction_hint() -> Dictionary:
	if not available(): return {}
	var desktop := bool(inventory.get("_desktop"))
	var near := (inventory.get("camera") as Node3D).global_position
	for target: Dictionary in spa.filing_targets(near, 1.6):
		var text := "File · %d/%d" % [int(target.strokes), int(target.needed)]
		var holding := held_file("desktop" if desktop else "left") != null or (not desktop and held_file("right") != null)
		if not holding: text = "Pick up the hoof file · " + text
		elif desktop: text = "[Hold LMB, move left/right] " + text
		return {"target": self, "point": target.tip + Vector3.UP * 0.08, "text": text}
	for target: Dictionary in spa.rub_targets(near, 1.6):
		return {"target": self, "point": target.bottom + Vector3.UP * 0.12,
			"text": ("[Hold LMB, drag slowly] " if desktop else "") + "Rub slowly · %d%%" % roundi(float(target.progress) * 100.0)}
	for target: Dictionary in spa.wing_targets(near, 1.6):
		var left: int = (target.feathers as Array).size()
		return {"target": self, "point": near - (inventory.get("camera") as Node3D).global_basis.z * 0.6,
			"text": "Massage · %d%%%s" % [roundi(minf(float(target.progress), 1.0) * 100.0), (" · Pluck %d stray" % left) if left > 0 else ""]}
	if desktop and bell_node != null and _ray_gap(_bell_top()) <= DESKTOP_AIM:
		return {"target": bell_node, "point": _bell_top(), "text": "[LMB] Ring to open" if spa.is_open_now() else "Closed (09:00-19:00)"}
	return {}


func _exit_tree() -> void:
	cancel_desktop_activity()
	for side: String in SIDES: _drop_hand(side)
