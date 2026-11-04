extends Node3D
## The Sweet Apple Acres cider press (P5 of docs/MECHANICS_ARCHITECTURE_2026_11_01.md, 8.4): the
## physical node of station "cider_press" (world/mechanics/data/stations.json: 8 apples, 20 work
## seconds, one goods:cider-keg). Existing models only: the kitchen barrel is the tub and the
## fishing bucket on top is the hopper, which turns as the press is cranked.
##   load:  drop an apple into the hopper (VR: let go of it over the hopper; any thrown or dropped
##          apple of Anon's that lands in it counts) or look at it and click with an apple in hand
##          (desktop). Each apple leaves the briefcase and goes into the station (stations.load_input).
##   crank: once 8 apples are in. VR: grip the hopper rim and move the hand around it (4 turns =
##          20 s of work); desktop: hold the click while looking at it (1 s held = 1 work second).
##   done:  the stations runner drops the keg beside the press as Anon's owned item and adds "made".
## A pony sent with [use: cider_press] works the same station (use_station.gd) from the press
## supply (each paid harvest basket adds 8 apples); the hopper turns while she does.
## Per-frame work only while a hand (or the desktop click) holds the crank.
const STATIONS := preload("res://world/mechanics/stations/stations.gd")
const HELD := preload("res://world/mechanics/stations/held_items.gd")
const LEDGER := preload("res://world/mechanics/ledger.gd")
const ITEM_CATALOG := preload("res://world/inventory/item_catalog.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
const STATION_ID := "cider_press"
const GROUP := "mechanics_station_nodes"
const TUB := "res://world/props/ponyville_kit/barrel.scn"
const HOPPER := "res://world/props/household/fishing-bucket.scn"
const TUB_HEIGHT := 0.9
const HOPPER_SCALE := 1.25
## Hopper rim height above the ground and its radius (the bucket is 0.48 m x 0.36 m at scale 1).
const RIM_Y := TUB_HEIGHT + 0.48 * HOPPER_SCALE
const RIM_RADIUS := 0.18 * HOPPER_SCALE
const GRIP_REACH := 0.25
const LOOK_RADIUS := 0.55
const LOOK_REACH := 3.0
## 4 turns = 20 work seconds.
const SECONDS_PER_RADIAN := 20.0 / (4.0 * TAU)
const DESKTOP_TURN_SECONDS := 5.0
const FLUSH_SECONDS := 0.25
const MAX_STEP_RADIANS := 0.6
const ITEM_LAYER := 1 << 17

var station_id := STATION_ID
var game: Node
var stations: Node
var _hopper: Node3D
var _area: Area3D
var _crank: Dictionary = {}   # side -> {"angle": float}
var _pending := 0.0
var _flush := 0.0
var _seen_progress := 0.0
var _connected: Node

func _ready() -> void:
	name = "CiderPress"
	add_to_group(GROUP)
	var tub := _instance(TUB)
	if tub != null:
		tub.name = "Tub"; add_child(tub)
	_hopper = _instance(HOPPER)
	if _hopper != null:
		_hopper.name = "Hopper"
		_hopper.scale = Vector3.ONE * HOPPER_SCALE
		_hopper.position = Vector3(0.0, TUB_HEIGHT, 0.0)
		add_child(_hopper)
	var body := StaticBody3D.new(); body.name = "PressBody"; body.collision_layer = 1; body.collision_mask = 0
	var shape := CollisionShape3D.new(); var cylinder := CylinderShape3D.new()
	cylinder.radius = 0.34; cylinder.height = TUB_HEIGHT
	shape.shape = cylinder; shape.position = Vector3(0, TUB_HEIGHT * 0.5, 0)
	body.add_child(shape); add_child(body)
	_area = Area3D.new(); _area.name = "HopperMouth"
	_area.collision_layer = 0; _area.collision_mask = ITEM_LAYER; _area.monitorable = false
	var mouth := CollisionShape3D.new(); var box := BoxShape3D.new()
	box.size = Vector3(RIM_RADIUS * 2.0, 0.35, RIM_RADIUS * 2.0)
	mouth.shape = box; mouth.position = Vector3(0, RIM_Y - 0.12, 0)
	_area.add_child(mouth); add_child(_area)
	_area.body_entered.connect(_on_body_entered)
	set_physics_process(false)
	_bind_runner()

func _bind_runner() -> void:
	if not is_instance_valid(stations): stations = STATIONS.of(get_tree())
	if is_instance_valid(stations) and _connected != stations and stations.has_signal("ticked"):
		_connected = stations
		stations.ticked.connect(_on_ticked)

static func _instance(path: String) -> Node3D:
	var packed: PackedScene = load(path) as PackedScene
	return packed.instantiate() as Node3D if packed != null else null

func _ui() -> Node:
	var found: Variant = game.get("inventory") if is_instance_valid(game) else null
	return found as Node if found is Node and is_instance_valid(found) else null

func rim_point() -> Vector3:
	return global_transform * Vector3(0, RIM_Y, 0)

## Where a pony stands to work it (use_station.gd) and where Anon's keg appears.
func station_work_point() -> Vector3:
	return global_transform * Vector3(0, 0, 0.9)

func station_output_pose() -> Transform3D:
	return Transform3D(global_basis, global_transform * Vector3(0.75, 0.35, 0.25))

func loaded() -> int:
	return (stations.row(STATION_ID).loaded as Array).size() if is_instance_valid(stations) else 0

func needed() -> int:
	var total := 0
	if is_instance_valid(stations):
		for entry: Variant in stations.spec(STATION_ID).get("inputs", []):
			if entry is Dictionary: total += STATIONS.RULES.count(entry)
	return total

static func _apple(id: String) -> bool:
	return ITEM_CATALOG.has_tag(id, "apple")

# --- Load ---------------------------------------------------------------------------------------

## One apple from Anon into the press: checked first (can_load), then it leaves his hand/briefcase,
## then the station takes it. "" or why not.
func load_from_hand(ui: Node, side: String) -> String:
	var id := HELD.id(ui, side)
	if not _apple(id): return "Only apples go in the press"
	if not is_instance_valid(stations): return "The press is not ready"
	var why: String = stations.can_load(STATION_ID, "player", id)
	if not why.is_empty(): return why
	if not HELD.use_up(ui, side): return "That apple cannot go in right now"
	return _take(id)

func _take(id: String) -> String:
	var why: String = stations.load_input(STATION_ID, "player", id)
	if why.is_empty(): SFX.play_event(self, "prop_harvest_deposit", {}, rim_point())
	else: push_warning("[press] an apple left Anon's hand but the press refused it: " + why)
	return why

## An apple of Anon's that fell into the hopper (dropped, thrown, let go of in VR).
func _on_body_entered(body: Node3D) -> void:
	_consider(body)

func _consider(body: Node3D) -> void:
	var ui := _ui()
	if ui == null or not body is RigidBody3D or not is_instance_valid(stations): return
	var id := str(body.get_meta("item_id", "")) if body.has_meta("item_id") else ""
	if not _apple(id) or not stations.can_load(STATION_ID, "player", id).is_empty(): return
	if HELD.use_up_loose(ui, body as RigidBody3D): _take(id)

# --- Crank --------------------------------------------------------------------------------------

func _hand_angle(ui: Node, side: String) -> float:
	var at := HELD.point(ui, side)
	if not at.is_finite(): return NAN
	var local := global_transform.affine_inverse() * at
	return atan2(local.x, local.z)

func _near_rim(ui: Node, side: String) -> bool:
	var at := HELD.point(ui, side)
	if not at.is_finite(): return false
	var local := global_transform.affine_inverse() * at
	return absf(Vector2(local.x, local.z).length() - RIM_RADIUS) <= GRIP_REACH and absf(local.y - RIM_Y) <= GRIP_REACH + 0.1

func can_crank() -> String:
	if not is_instance_valid(stations): return "The press is not ready"
	if not stations.inputs_ready(STATION_ID): return "Add apples first (%d/%d)" % [loaded(), needed()]
	return stations.can_work(STATION_ID, "player")

## Starts cranking with this hand (or the desktop click). Ends with stop_crank / the release.
func start_crank(ui: Node, side: String) -> bool:
	if not can_crank().is_empty(): return false
	_crank[side] = {"angle": _hand_angle(ui, side) if side != "desktop" else 0.0}
	set_physics_process(true)
	return true

func stop_crank(side: String) -> void:
	_crank.erase(side)
	_flush_work()
	if _crank.is_empty(): set_physics_process(false)

## Adds work seconds (tests and the crank loop); the hopper turns with it. Returns what it made.
func turn(seconds: float) -> Array[String]:
	if seconds <= 0.0 or not is_finite(seconds): return []
	if is_instance_valid(_hopper): _hopper.rotate_y(seconds / SECONDS_PER_RADIAN)
	_pending += seconds
	return _flush_work()

func _physics_process(delta: float) -> void:
	var ui := _ui()
	if _crank.is_empty() or ui == null: set_physics_process(false); return
	for side: String in _crank.keys():
		# stop_crank on the other hand can flush and clear _crank (keg done, press empty).
		if not _crank.has(side): continue
		var row: Dictionary = _crank[side]
		if side == "desktop":
			_pending += delta
			if is_instance_valid(_hopper): _hopper.rotate_y(delta * TAU / DESKTOP_TURN_SECONDS)
			continue
		if not _near_rim(ui, side): stop_crank(side); continue
		var angle := _hand_angle(ui, side)
		if is_nan(angle) or is_nan(float(row.angle)): row.angle = angle; continue
		var step := wrapf(angle - float(row.angle), -PI, PI)
		row.angle = angle
		step = clampf(absf(step), 0.0, MAX_STEP_RADIANS)
		_pending += step * SECONDS_PER_RADIAN
		if is_instance_valid(_hopper): _hopper.rotate_y(step)
	_flush -= delta
	if _flush <= 0.0:
		_flush = FLUSH_SECONDS
		_flush_work()

func _flush_work() -> Array[String]:
	var made: Array[String] = []
	if _pending <= 0.0 or not is_instance_valid(stations): _pending = 0.0; return made
	var amount := _pending
	_pending = 0.0
	made = stations.work(STATION_ID, "player", amount)
	if not made.is_empty():
		SFX.play_event(self, "prop_place", {}, global_position + Vector3.UP * 0.4)
		var ui := _ui()
		if ui != null: LEDGER.say(ui, "The press filled a keg of cider.")
		_crank.clear()
		set_physics_process(false)
	elif not _crank.is_empty() and not can_crank().is_empty():
		_crank.clear(); set_physics_process(false)
	return made

func _on_ticked(_at: float) -> void:
	if not is_instance_valid(stations): return
	var row: Dictionary = stations.row(STATION_ID)
	var progress := float(row.get("progress", 0.0))
	# A pony working it: the hopper turns with her work.
	if str(row.get("worker", "")) != "player" and progress > _seen_progress and is_instance_valid(_hopper):
		_hopper.rotate_y((progress - _seen_progress) / SECONDS_PER_RADIAN)
	_seen_progress = progress
	if is_instance_valid(_area) and _area.monitoring:
		for body: Node3D in _area.get_overlapping_bodies(): _consider(body)

# --- Hints and input (world/mechanics/stations/station_input.gd) ---------------------------------

func station_hint(ui: Node, side: String) -> Dictionary:
	var vr := side != "desktop"
	if vr:
		var at := HELD.point(ui, side)
		if not at.is_finite() or at.distance_to(rim_point()) > 0.6: return {}
	elif not HELD.looking_at(ui, rim_point(), LOOK_RADIUS, LOOK_REACH):
		return {}
	var text := ""
	var held := HELD.id(ui, side)
	var count := "(%d/%d)" % [loaded(), needed()]
	if _apple(held):
		var why: String = stations.can_load(STATION_ID, "player", held) if is_instance_valid(stations) else "The press is not ready"
		text = (("Let go over the hopper · Add apple " if vr else "Click · Add apple ") + count) if why.is_empty() else why
	elif can_crank().is_empty():
		text = "Grip the rim and turn · Press cider" if vr else "Hold click · Turn the press"
	elif held.is_empty():
		text = "Cider press · add apples " + count
	if text.is_empty(): return {}
	return {"target": self, "text": text, "point": rim_point() + Vector3.UP * 0.25, "outline": _hopper}

func station_use(ui: Node, side: String, down: bool) -> bool:
	if not down:
		if _crank.has(side): stop_crank(side); return true
		return false
	if side == "desktop":
		if not HELD.looking_at(ui, rim_point(), LOOK_RADIUS, LOOK_REACH): return false
		if _apple(HELD.id(ui, side)): return load_from_hand(ui, side).is_empty()
		return start_crank(ui, side)
	if not _near_rim(ui, side): return false
	return start_crank(ui, side)
