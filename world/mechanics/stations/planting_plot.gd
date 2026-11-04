extends Node3D
## Anon's row at Sweet Apple Acres (P5 of docs/MECHANICS_ARCHITECTURE_2026_11_01.md, 8.2): the
## planting plot, station "saa_plot" (kind grow in world/mechanics/data/stations.json). Eight slots
## continue the orchard grid east of its last column. Plant anything tagged `plantable` (the apple
## sapling from Applejack's stall) by holding it at an empty slot's stake (VR, half a second) or
## looking at the slot and clicking (desktop); water it with the spray bottle (or a wet day, or a
## pony's watering step), one watering a day; three watered days in a growing season and at least
## three days after planting it grows into a real orchard tree (farm_dressing.add_tree) that joins
## the apple harvest (apple_bucking._add_row, the harvest ledger keyed "saa:pNN").
## Facts: planted (memory), watered (counts only), grew (memory); the first tree also makes the
## "made" fact "Applejack named the new trees Anon's row." (gossip material; the sign reads it).
## Saved in world_context.state.stations.plots.saa_plot = {"slots": [8 slot rows], "named": bool}
## through stations.plot_state(); a slot row is {} or {"item", "by", "planted_day", "watered": [days],
## "stage": 0..3, "tree_id", "grown_day"}.
## Ticks with the stations runner (1 Hz `ticked`); the VR hold check runs at 10 Hz only while Anon
## is near the row holding something.
const STATIONS := preload("res://world/mechanics/stations/stations.gd")
const SAPLING := preload("res://world/items/apple_sapling.gd")
const HELD := preload("res://world/mechanics/stations/held_items.gd")
const ITEM_CATALOG := preload("res://world/inventory/item_catalog.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
const STATION_ID := "saa_plot"
const GROUP := "mechanics_station_nodes"
const SLOT_X := [113.0, 120.5, 128.0, 135.5]
const SLOT_Z := [-484.0, -472.0]
const SLOTS := 8
const GROW_DAYS := 3
const WATER_DAYS := 3
## Sapling heights by stage (fractions of a 5 m tree: apple_sapling.gd REFERENCE_HEIGHT).
const STAGE_SCALES := [0.12, 0.2, 0.3]
## A grown tree's scale, inside the orchard's own range (farm_layout.json orchard.scale 0.5-0.62).
const TREE_SCALE := 0.56
const PLANT_REACH := 0.5
const PLANT_HOLD := 0.5
const LOOK_RADIUS := 0.7
const LOOK_REACH := 3.0
const WITNESS_RANGE := 30.0
const NEAR := 25.0
const HOLD_TICK := 0.1
const STAKE := "res://world/props/ponyville_kit/rail_fence_post.scn"
const SOIL := "res://world/props/ponyville_kit/crop_row.scn"
const SIGNPOST := "res://world/props/ponyville_kit/signpost.scn"
const SIGN_AT := Vector3(108.6, 0.0, -478.0)
const SPRAY_ID := "spray-bottle"

## One slot: a stake, a soil patch and (when planted) the sapling; the body the spray bottle hits
## (its ray finds the first ancestor with physical_reaction) and the node station_input.gd finds.
class Slot extends Node3D:
	signal physical_reaction(kind: String)
	var plot: Node3D
	var index := 0
	var station_id := "saa_plot"
	func station_hint(ui: Node, side: String) -> Dictionary: return plot.slot_hint(index, ui, side) if is_instance_valid(plot) else {}
	func station_use(ui: Node, side: String, down: bool) -> bool: return plot.slot_use(index, ui, side, down) if is_instance_valid(plot) else false
	func station_work_point() -> Vector3: return plot.station_work_point() if is_instance_valid(plot) else global_position

var station_id := STATION_ID
var game: Node
var stations: Node
var facts: Node
var population: Node   # optional (tests); else group "pony_populations"
var farm: Node3D       # farm_dressing.gd; default the parent
var _slots: Array[Slot] = []
var _shown: Dictionary = {}       # index -> shown stage (-1 empty)
var _sign_label: Label3D
var _sign: Node3D
var _hold: Dictionary = {}        # side -> [slot index, seconds]
var _hold_wait := 0.0
var _rain_day := -1
var _restored := false
var _connected: Node
var _context: Node                # world_context whose `reopened` (a loaded save) re-runs restore()

func _ready() -> void:
	name = "SaaPlantingPlot"
	if farm == null and get_parent() is Node3D: farm = get_parent() as Node3D
	for index: int in SLOTS:
		var slot := Slot.new()
		slot.name = "Slot%d" % index
		slot.plot = self; slot.index = index
		add_child(slot)
		slot.add_to_group(GROUP)
		slot.physical_reaction.connect(_on_slot_reaction.bind(index))
		_slots.append(slot)
		_build_slot(slot)
	_place_slots()
	set_physics_process(false)
	_bind_runner()
	if farm != null and bool(farm.get("_built")): restore()
	elif farm != null and farm.has_signal("orchard_ready"): farm.connect("orchard_ready", restore, CONNECT_ONE_SHOT)
	else: restore()

func _bind_runner() -> void:
	if not is_instance_valid(stations): stations = STATIONS.of(get_tree())
	if is_instance_valid(stations) and _connected != stations and stations.has_signal("ticked"):
		_connected = stations
		stations.ticked.connect(_on_ticked)
	if not is_instance_valid(facts) and is_instance_valid(stations): facts = stations.get("facts")
	var context: Variant = stations.get("context") if is_instance_valid(stations) else null
	if context is Node and context != _context and (context as Node).has_signal("reopened"):
		_context = context
		(context as Node).connect("reopened", _on_reopened)

# --- Pure rules (tests call these directly) -------------------------------------------------------

static func slot_point(index: int) -> Vector3:
	return Vector3(float(SLOT_X[index % SLOT_X.size()]), 0.0, float(SLOT_Z[index / SLOT_X.size()]))

static func tree_id(index: int) -> String:
	return "saa:p%02d" % index

static func _whole(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floor(float(value)) and float(value) >= 0.0

## A planted slot row as saved (an empty slot is {}).
static func valid_slot(slot: Variant) -> bool:
	if not slot is Dictionary: return false
	var row: Dictionary = slot
	if row.is_empty(): return true
	if not row.get("item") is String or str(row.item).is_empty() or not row.get("tree_id") is String: return false
	if not _whole(row.get("planted_day")) or not _whole(row.get("stage")) or int(row.stage) > 3: return false
	if not row.get("watered") is Array or (row.watered as Array).size() > 64: return false
	for day: Variant in row.watered:
		if not _whole(day): return false
	return true

static func watered_days(slot: Dictionary) -> int:
	var days := {}
	for day: Variant in slot.get("watered", []): days[int(day)] = true
	return days.size()

## What it shows: 0-2 by watered days while a sapling, 3 once grown.
static func stage_of(slot: Dictionary) -> int:
	if slot.is_empty(): return -1
	if int(slot.get("stage", 0)) >= 3: return 3
	return mini(2, watered_days(slot))

## Puts a plantable item into an empty slot row.
static func plant_into(slot: Dictionary, index: int, item_id: String, day: int, by := "player") -> void:
	slot.clear()
	slot.merge({"item": item_id, "by": by, "planted_day": day, "watered": [], "stage": 0, "tree_id": tree_id(index), "grown_day": -1})

## At most one watering a day counts. True when this one counted.
static func water_slot(slot: Dictionary, day: int) -> bool:
	if slot.is_empty() or int(slot.get("stage", 0)) >= 3: return false
	var watered: Array = slot.get("watered", [])
	for seen: Variant in watered:
		if int(seen) == day: return false
	watered.append(day)
	while watered.size() > WATER_DAYS + 4: watered.pop_front()
	slot.watered = watered
	slot.stage = stage_of(slot)
	return true

## Three distinct watered days, not winter, and planted at least GROW_DAYS days ago.
static func growable(slot: Dictionary, day: int, season: String) -> bool:
	if slot.is_empty() or int(slot.get("stage", 0)) >= 3 or season == "winter": return false
	return watered_days(slot) >= WATER_DAYS and day - int(slot.get("planted_day", day)) >= GROW_DAYS

# --- State --------------------------------------------------------------------------------------

func _day() -> int:
	return int(STATIONS.FACTS.clock().day)

func _season() -> String:
	return str(stations.season()) if is_instance_valid(stations) else "summer"

## The live saved block {"slots": [8], "named"} (repaired), or {} when the world is read-only.
func _block() -> Dictionary:
	if not is_instance_valid(stations): return {}
	var block: Dictionary = stations.plot_state(STATION_ID)
	if block.is_empty(): return {}
	var slots: Variant = block.get("slots")
	if not slots is Array: slots = []
	var fixed: Array = []
	for index: int in SLOTS:
		var row: Variant = (slots as Array)[index] if index < (slots as Array).size() else {}
		fixed.append(row if valid_slot(row) else {})
	block.slots = fixed
	if not block.get("named") is bool: block.named = false
	return block

## A copy of slot `index` ({} when empty or unknown).
func slot(index: int) -> Dictionary:
	var block := _block()
	if block.is_empty() or index < 0 or index >= SLOTS: return {}
	return (block.slots[index] as Dictionary).duplicate(true)

func named() -> bool:
	var block := _block()
	return bool(block.get("named", false))

func _changed() -> void:
	if is_instance_valid(stations): stations.changed()

# --- Actions ------------------------------------------------------------------------------------

## "" when `item_id` could go into slot `index` now, else why not. Changes nothing.
func can_plant(index: int, item_id: String) -> String:
	if index < 0 or index >= SLOTS: return "No such spot"
	if not ITEM_CATALOG.has_tag(item_id, "plantable"): return "That does not grow here"
	if _block().is_empty(): return "The world cannot change right now"
	if not slot(index).is_empty(): return "Something already grows there"
	if _season() == "winter": return "The ground is frozen; plant it in spring"
	return ""

## Plants into slot `index` (the item already left its owner: callers check can_plant first).
func plant(index: int, worker: String, item_id: String) -> String:
	var why := can_plant(index, item_id)
	if not why.is_empty(): return why
	var block := _block()
	var row: Dictionary = block.slots[index]
	plant_into(row, index, ITEM_CATALOG.canonical(item_id), _day(), worker)
	_changed()
	var who := "Anon" if worker == "player" else worker.replace("_", " ").capitalize()
	var whose := "his" if worker == "player" else "Anon's"
	_fact("planted", {"actor": worker, "target": "applejack", "item": str(row.item), "ref": STATION_ID, "place": tree_id(index),
		"key": "plant:%s:%d" % [tree_id(index), _day()]},
		"%s planted %s in %s row at Sweet Apple Acres." % [who, _phrase(str(row.item)), whose], _witnesses(index, worker))
	_show(index)
	return ""

## One watering for slot `index` today ("player", a pony id or "weather"). True when it counted.
func water(index: int, worker: String) -> bool:
	var block := _block()
	if block.is_empty() or index < 0 or index >= SLOTS: return false
	var row: Dictionary = block.slots[index]
	if not water_slot(row, _day()): return false
	_changed()
	_fact("watered", {"actor": worker, "item": str(row.item), "ref": STATION_ID, "place": tree_id(index),
		"key": "water:saa:%d:%d" % [index, _day()]})
	_show(index)
	return true

## Waters every planted slot that still needs today's watering. Returns how many counted.
func water_all(worker: String) -> int:
	var count := 0
	for index: int in SLOTS:
		if water(index, worker): count += 1
	return count

## Slots still needing water today (pony day plans, WP8's water_saplings, ask this).
func thirsty() -> Array[int]:
	var found: Array[int] = []
	var today := _day()
	for index: int in SLOTS:
		var row := slot(index)
		if row.is_empty() or int(row.get("stage", 0)) >= 3: continue
		if not today in (row.get("watered", []) as Array).map(func(d: Variant) -> int: return int(d)): found.append(index)
	return found

## For a pony's watering step (loaded or not): the plot node waters every thirsty slot.
static func water_for(tree: SceneTree, worker: String) -> int:
	if tree == null: return 0
	for node: Node in tree.get_nodes_in_group(GROUP):
		if str(node.get("station_id")) == STATION_ID and node.get("plot") is Node and (node.get("plot") as Node).has_method("water_all"):
			return int((node.get("plot") as Node).call("water_all", worker))
	return 0

## Grows every slot that is ready. Returns how many grew.
func grow_check() -> int:
	var block := _block()
	if block.is_empty(): return 0
	var grown := 0
	var today := _day()
	var season := _season()
	for index: int in SLOTS:
		var row: Dictionary = block.slots[index]
		if not growable(row, today, season): continue
		row.stage = 3
		row.grown_day = today
		grown += 1
		_changed()
		_add_tree(index)
		_fact("grew", {"actor": str(row.get("by", "player")), "item": str(row.item), "ref": STATION_ID, "place": tree_id(index),
			"key": "grew:%s:%d" % [tree_id(index), int(row.planted_day)]},
			"Anon's sapling grew into an apple tree." if str(row.get("by", "player")) == "player" else "A sapling in Anon's row grew into an apple tree.",
			["player", "applejack"])
		_show(index)
		if not bool(block.get("named", false)):
			block.named = true
			_changed()
			_fact("made", {"actor": "applejack", "item": "", "ref": STATION_ID, "place": "anons_row", "key": "named:anons_row"},
				"Applejack named the new trees Anon's row.", ["applejack", "player"])
			_update_sign()
	return grown

## After the orchard is built: grown slots become trees again, saplings show their stage.
func restore() -> void:
	_restored = true
	for index: int in SLOTS:
		if int(slot(index).get("stage", 0)) >= 3: _add_tree(index)
		_show(index)
	_update_sign()

## A save loaded mid-session (game_saves._restore -> world_context.restore_checkpoint swaps the
## state in place): trees the loaded row does not have are removed (with their harvest rows,
## before apple_bucking.restore runs), its grown ones are added, every slot and the sign redrawn.
func _on_reopened(_world_id: String) -> void:
	if not _restored: return
	for index: int in SLOTS:
		if int(slot(index).get("stage", 0)) < 3 and is_instance_valid(farm) and farm.has_method("remove_tree"):
			farm.call("remove_tree", tree_id(index))
	_shown.clear()
	restore()

func _add_tree(index: int) -> void:
	if not is_instance_valid(farm) or not farm.has_method("add_tree"): return
	var at := _ground(slot_point(index))
	if not at.is_finite(): at = slot_point(index)
	farm.call("add_tree", tree_id(index), at, TREE_SCALE)

func _on_ticked(_at_hours: float) -> void:
	if not is_inside_tree(): return
	var today := _day()
	if today != _rain_day:
		var weather: Node = get_tree().get_first_node_in_group("weather")
		if weather != null and weather.has_method("wet_day"):
			_rain_day = today
			if bool(weather.call("wet_day")): water_all("weather")
		else:
			_rain_day = today
	grow_check()
	if not _slots.is_empty() and not _slots[0].global_position.is_finite(): _place_slots()
	# The 10 Hz VR hold check runs only while Anon is near the row holding something.
	set_physics_process(_anon_near_holding())

func _on_slot_reaction(kind: String, index: int) -> void:
	if kind == "sprayed": water(index, "player")

# --- Input --------------------------------------------------------------------------------------

func _ui() -> Node:
	var found: Variant = game.get("inventory") if is_instance_valid(game) else null
	return found as Node if found is Node and is_instance_valid(found) else null

func _slot_top(index: int) -> Vector3:
	return _slots[index].global_position + Vector3.UP * 0.3 if index < _slots.size() else Vector3.INF

func _hint_text(index: int, held: String, vr: bool) -> String:
	var row := slot(index)
	if row.is_empty():
		if not ITEM_CATALOG.has_tag(held, "plantable"): return ""
		var why := can_plant(index, held)
		if not why.is_empty(): return why
		return "Hold it at the stake · Plant" if vr else "Click · Plant sapling"
	if int(row.get("stage", 0)) >= 3: return ""
	var days := watered_days(row)
	if held == SPRAY_ID and index in thirsty(): return ("Trigger · Water the sapling" if vr else "Click · Water the sapling")
	return "Sapling · watered %d of %d days" % [days, WATER_DAYS]

func slot_hint(index: int, ui: Node, side: String) -> Dictionary:
	var vr := side != "desktop"
	var held := HELD.id(ui, side)
	if vr:
		var at := HELD.point(ui, side)
		if not at.is_finite() or at.distance_to(_slot_top(index)) > PLANT_REACH * 1.6: return {}
	elif not HELD.looking_at(ui, _slot_top(index), LOOK_RADIUS, LOOK_REACH):
		return {}
	var text := _hint_text(index, held, vr)
	if text.is_empty(): return {}
	var glow: Node3D = _slots[index].get_node_or_null("Growth") as Node3D
	if glow == null or glow.get_child_count() == 0: glow = _slots[index].get_node_or_null("Stake") as Node3D
	return {"target": _slots[index], "text": text, "point": _slot_top(index) + Vector3.UP * 0.3, "outline": glow}

## Desktop click (or a VR grip that reached it): plant what is held, or water with the spray bottle.
func slot_use(index: int, ui: Node, side: String, down: bool) -> bool:
	if not down: return false
	if side == "desktop" and not HELD.looking_at(ui, _slot_top(index), LOOK_RADIUS, LOOK_REACH): return false
	var held := HELD.id(ui, side)
	if ITEM_CATALOG.has_tag(held, "plantable") and slot(index).is_empty():
		return _plant_from_hand(index, ui, side)
	if held == SPRAY_ID and index in thirsty():
		var bottle := HELD.body(ui, side)
		if bottle != null:
			for node: Node in bottle.find_children("*", "Node3D", true, false):
				if node.has_method("spray"): node.call("spray"); break
		return water(index, "player")
	return false

func _plant_from_hand(index: int, ui: Node, side: String) -> bool:
	var held := HELD.id(ui, side)
	if not can_plant(index, held).is_empty(): return false
	if not HELD.use_up(ui, side): return false
	var why := plant(index, "player", held)
	if not why.is_empty():
		push_warning("[plot] planting failed after the sapling left the hand: " + why)
		return false
	SFX.play_event(_slots[index], "prop_impact", {"material": "soft", "intensity": 0.6})
	return true

func _anon_near_holding() -> bool:
	var ui := _ui()
	if ui == null or bool(ui.get("_desktop")): return false
	var camera: Variant = ui.get("camera")
	if not camera is Node3D or not is_instance_valid(camera): return false
	var centre := (_slots[0].global_position + _slots[SLOTS - 1].global_position) * 0.5 if _slots.size() == SLOTS else global_position
	if (camera as Node3D).global_position.distance_to(centre) > NEAR: return false
	for side: String in ["left", "right"]:
		if ITEM_CATALOG.has_tag(HELD.id(ui, side), "plantable"): return true
	return false

## VR: a plantable thing held at an empty slot's stake for PLANT_HOLD seconds goes in.
func _physics_process(delta: float) -> void:
	_hold_wait -= delta
	if _hold_wait > 0.0: return
	_hold_wait = HOLD_TICK
	var ui := _ui()
	if ui == null: return
	for side: String in ["left", "right"]:
		var held := HELD.id(ui, side)
		var at := HELD.point(ui, side)
		var best := -1
		if ITEM_CATALOG.has_tag(held, "plantable") and at.is_finite():
			for index: int in SLOTS:
				if slot(index).is_empty() and at.distance_to(_slot_top(index)) <= PLANT_REACH: best = index; break
		var row: Array = _hold.get(side, [-1, 0.0])
		if best < 0: _hold.erase(side); continue
		row = [best, float(row[1]) + HOLD_TICK if int(row[0]) == best else 0.0]
		_hold[side] = row
		if float(row[1]) >= PLANT_HOLD:
			_hold.erase(side)
			_plant_from_hand(best, ui, side)

# --- Looks --------------------------------------------------------------------------------------

func _ground(point: Vector3) -> Vector3:
	if is_instance_valid(farm) and farm.has_method("_ground"):
		var hit: Variant = farm.call("_ground", point)
		if hit is Vector3 and (hit as Vector3).is_finite(): return hit
	if is_instance_valid(WorldTerrain.instance):
		var h: float = WorldTerrain.instance.height_at(Vector3(point.x, 0, point.z))
		if is_finite(h): return Vector3(point.x, h, point.z)
	return Vector3.INF

func _place_slots() -> void:
	for index: int in _slots.size():
		var at := _ground(slot_point(index))
		_slots[index].global_position = at if at.is_finite() else slot_point(index)
	if is_instance_valid(_sign):
		var at := _ground(SIGN_AT)
		_sign.global_position = at if at.is_finite() else SIGN_AT

static func _instance(path: String) -> Node3D:
	var packed: PackedScene = load(path) as PackedScene
	return packed.instantiate() as Node3D if packed != null else null

func _build_slot(slot_node: Slot) -> void:
	var soil := _instance(SOIL)
	if soil != null:
		soil.name = "Soil"
		soil.scale = Vector3(0.36, 0.5, 0.5)
		slot_node.add_child(soil)
	var stake := _instance(STAKE)
	if stake != null:
		stake.name = "Stake"
		stake.scale = Vector3.ONE * 0.7
		stake.position = Vector3(0.32, 0.0, 0.0)
		slot_node.add_child(stake)
	var body := StaticBody3D.new()
	body.name = "SlotBody"
	body.collision_layer = 2; body.collision_mask = 0
	var shape := CollisionShape3D.new(); var box := BoxShape3D.new()
	box.size = Vector3(0.9, 0.25, 0.9)
	shape.shape = box; shape.position = Vector3(0, 0.125, 0)
	body.add_child(shape)
	slot_node.add_child(body)
	var growth := Node3D.new(); growth.name = "Growth"
	slot_node.add_child(growth)
	if slot_node.index == 0: _build_sign()

func _build_sign() -> void:
	_sign = _instance(SIGNPOST)
	if _sign == null: return
	_sign.name = "AnonsRowSign"
	_sign.scale = Vector3.ONE * 0.8
	add_child(_sign)
	_sign_label = Label3D.new()
	_sign_label.name = "Words"
	# Painted on the front of the arrow board that points east, toward the row (between the post
	# and the board's apple icon).
	_sign_label.pixel_size = 0.0015; _sign_label.font_size = 40
	_sign_label.modulate = Color("f3e3c0"); _sign_label.outline_size = 0
	_sign_label.position = Vector3(0.25, 1.66, 0.2)
	_sign.add_child(_sign_label)
	_update_sign()

func _update_sign() -> void:
	if is_instance_valid(_sign_label): _sign_label.text = "Anon's row" if named() else "Saplings"

func _show(index: int) -> void:
	if index < 0 or index >= _slots.size(): return
	var row := slot(index)
	var stage := stage_of(row)
	if int(_shown.get(index, -2)) == stage: return
	_shown[index] = stage
	var growth: Node3D = _slots[index].get_node("Growth")
	for child: Node in growth.get_children(): child.queue_free()
	var stake: Node3D = _slots[index].get_node_or_null("Stake") as Node3D
	var soil: Node3D = _slots[index].get_node_or_null("Soil") as Node3D
	if stake != null: stake.visible = stage < 3
	if soil != null: soil.visible = stage < 3
	(_slots[index].get_node("SlotBody") as CollisionObject3D).collision_layer = 0 if stage >= 3 else 2
	if stage >= 0 and stage < 3:
		var holder := Node3D.new(); holder.name = "Stage%d" % stage
		growth.add_child(holder)
		SAPLING.build_visual(holder, float(STAGE_SCALES[stage]), false, tree_id(index))

static func _phrase(item_id: String) -> String:
	return STATIONS._phrase(item_id)

func _population() -> Node:
	if is_instance_valid(population): return population
	return get_tree().get_first_node_in_group("pony_populations") if is_inside_tree() else null

## The worker, Anon, Applejack and the ponies within WITNESS_RANGE of the slot.
func _witnesses(index: int, worker: String) -> Array:
	var who: Array = []
	for id: String in [worker, "player", "applejack"]:
		if not id in who and STATIONS.FACTS._witness_ok(id): who.append(id)
	var at := _slots[index].global_position if index < _slots.size() else slot_point(index)
	var people := _population()
	var live: Variant = people.get("live") if people != null else null
	if live is Dictionary:
		for other: Variant in live:
			var entry: Variant = (live as Dictionary)[other]
			var body: Variant = (entry as Dictionary).get("actor") if entry is Dictionary else null
			if not str(other) in who and is_instance_valid(body) and body is Node3D and (body as Node3D).is_inside_tree() \
					and (body as Node3D).global_position.distance_to(at) <= WITNESS_RANGE:
				who.append(str(other))
	return who

func _fact(type: String, data: Dictionary, text := "", witnesses: Array = []) -> void:
	if is_instance_valid(facts): facts.call("add", type, data, text, witnesses)
	else: STATIONS.FACTS.note(self, type, data, text, witnesses)

func station_work_point() -> Vector3:
	return _slots[0].global_position if not _slots.is_empty() else global_position
