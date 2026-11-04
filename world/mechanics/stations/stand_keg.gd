extends Node3D
## The cider stand's tap keg (P5 of docs/MECHANICS_ARCHITECTURE_2026_11_01.md, 8.5): a world-owned
## keg on its barrel beside Applejack's cider stall. Its servings are world state
## (world_context.state.jobs.cider_stand_keg = {"day", "servings", "free_day"}), not a carried item:
## each day it is topped up from the kegs the press made for the stand (stations supply
## "cider_stand", 8 servings a keg; the press's stock_to), and during Cider Season it is filled
## free once a day when no keg is waiting. While Anon works the stand (cider_stand.gd says when),
## an empty cider mug brought to the tap (VR: within 0.28 m; desktop: look at it and click) fills:
## the same one-loan change as cider_pour.gd (replace_held), the keg_pour "made" fact, one serving.
## The VR check runs four times a second only while Anon works the stand.
const KEG := preload("res://world/items/cider_keg.gd")
const FOOD := preload("res://world/food/food_interaction.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
const STATIONS := preload("res://world/mechanics/stations/stations.gd")
const HELD := preload("res://world/mechanics/stations/held_items.gd")
const BARREL := "res://world/props/ponyville_kit/barrel.scn"
const STATE_KEY := "cider_stand_keg"
const SUPPLY := "cider_stand"
const SEASON := "cider_season"
const SERVINGS := 8
const MAX_SERVINGS := 16
const TAP_REACH := 0.28
const LOOK_RADIUS := 0.4
const LOOK_REACH := 3.0
const CHECK_SECONDS := 0.25
const BARREL_HEIGHT := 0.9

var station_id := "cider_stall"
var stand: Node3D      # cider_stand.gd (working(), jobs, stations)
var _wait := 0.0
var _keg_visual: Node3D

func _ready() -> void:
	name = "StandKeg"
	add_to_group("mechanics_station_nodes")
	var barrel: Node3D = (load(BARREL) as PackedScene).instantiate() as Node3D
	if barrel != null:
		barrel.name = "Barrel"; add_child(barrel)
	_keg_visual = Node3D.new(); _keg_visual.name = "Keg"
	_keg_visual.position = Vector3(0, BARREL_HEIGHT, 0)
	add_child(_keg_visual)
	KEG.build_visual(_keg_visual)
	var body := StaticBody3D.new(); body.name = "BarrelBody"; body.collision_layer = 1; body.collision_mask = 0
	var shape := CollisionShape3D.new(); var cylinder := CylinderShape3D.new()
	cylinder.radius = 0.34; cylinder.height = BARREL_HEIGHT
	shape.shape = cylinder; shape.position = Vector3(0, BARREL_HEIGHT * 0.5, 0)
	body.add_child(shape); add_child(body)
	set_physics_process(false)

func tap_point() -> Vector3:
	return global_transform * Vector3(0, BARREL_HEIGHT + 0.22, 0)

# --- State --------------------------------------------------------------------------------------

func _jobs() -> Node:
	return stand.get("jobs") as Node if is_instance_valid(stand) and is_instance_valid(stand.get("jobs")) else null

func _stations() -> Node:
	return stand.get("stations") as Node if is_instance_valid(stand) and is_instance_valid(stand.get("stations")) else null

func _today() -> int:
	return int(STATIONS.FACTS.clock().day)

## The saved row {"day", "servings", "free_day"} (a copy; defaults when absent).
func row() -> Dictionary:
	var result := {"day": -1, "servings": 0, "free_day": -1}
	var jobs := _jobs()
	var block: Dictionary = jobs.call("_read") if jobs != null else {}
	var saved: Variant = block.get(STATE_KEY)
	if saved is Dictionary:
		for key: String in result:
			var value: Variant = (saved as Dictionary).get(key)
			if (value is int or value is float) and is_finite(float(value)): result[key] = int(value)
	result.servings = clampi(int(result.servings), 0, MAX_SERVINGS)
	return result

func servings() -> int:
	return int(row().servings)

func _write(next: Dictionary) -> bool:
	var jobs := _jobs()
	if jobs == null or not bool(jobs.call("_writable")): return false
	var block: Dictionary = jobs.call("_block")
	block[STATE_KEY] = {"day": int(next.day), "servings": clampi(int(next.servings), 0, MAX_SERVINGS), "free_day": int(next.free_day)}
	(jobs.get("context") as Node).call("_changed")
	return true

func _season_on() -> bool:
	var jobs := _jobs()
	var cal: Node = jobs.call("_calendar") if jobs != null and jobs.has_method("_calendar") else null
	return cal != null and cal.has_method("active") and bool(cal.call("active", SEASON))

## Once a second (the stand's tick): a new day, or an empty keg, takes a keg from the press's
## supply for the stand; during Cider Season a dry keg is filled free once a day.
func refill_check() -> void:
	var now := row()
	var today := _today()
	var changed := false
	if int(now.day) != today:
		now.day = today; changed = true
	var stations := _stations()
	if int(now.servings) < SERVINGS and stations != null and stations.take_supply(SUPPLY, KEG.ID, 1):
		now.servings = int(now.servings) + SERVINGS; changed = true
	elif int(now.servings) <= 0 and int(now.free_day) != today and _season_on():
		now.servings = SERVINGS; now.free_day = today; changed = true
	if changed: _write(now)
	_show()

## A pony worker's sale (cider_stand.gd serve_one, WP8): refills first, then takes one serving.
func serve_one() -> bool:
	refill_check()
	var now := row()
	if int(now.servings) <= 0: return false
	now.servings = int(now.servings) - 1
	if not _write(now): return false
	_show()
	return true

func _show() -> void:
	if is_instance_valid(_keg_visual): _keg_visual.visible = servings() > 0

# --- Filling ------------------------------------------------------------------------------------

## "" when Anon's mug in this hand could be filled now, else why not.
func can_fill(ui: Node, side: String) -> String:
	if HELD.id(ui, side) != KEG.MUG_EMPTY: return "Bring an empty cider mug"
	if not is_instance_valid(stand) or not bool(stand.call("working")): return "Applejack's stand keg"
	if servings() <= 0: return "The stand keg is empty"
	return ""

## Fills the empty mug in this hand from the tap: one saved loan change, one serving less.
func fill(ui: Node, side: String) -> bool:
	if not can_fill(ui, side).is_empty(): return false
	var mug := HELD.body(ui, side)
	var store: Variant = ui.get("inventory")
	var token := str(mug.get_meta("token", ""))
	var next := row()
	next.servings = int(next.servings) - 1
	if store == null or not bool(store.call("replace_held", token, KEG.MUG_FULL)): return false
	_write(next)
	mug.set_meta("item_id", KEG.MUG_FULL)
	var visual: Variant = mug.get_meta("food_visual") if mug.has_meta("food_visual") else null
	if visual is Node3D and is_instance_valid(visual):
		(visual as Node3D).set("food_id", KEG.MUG_FULL)
		(visual as Node3D).call("show_full")
		FOOD.configure(mug, visual as Node3D, mug.get_child(0) as CollisionShape3D)
	if ui.has_method("_refresh_holding"): ui.call("_refresh_holding")
	if ui.has_method("_haptic"): ui.call("_haptic", side)
	SFX.play_event(mug, "prop_sip", {"pitch": 0.82, "intensity": 0.9})
	STATIONS.note(self, "keg_pour", "player", [KEG.MUG_FULL])
	_show()
	return true

## Turns the 4 Hz VR tap check on while Anon works the stand (cider_stand.gd's tick).
func watch(on: bool) -> void:
	set_physics_process(on)

func _physics_process(delta: float) -> void:
	_wait -= delta
	if _wait > 0.0: return
	_wait = CHECK_SECONDS
	var ui: Node = stand.call("_ui") if is_instance_valid(stand) else null
	if ui == null or bool(ui.get("_desktop")): return
	for side: String in ["left", "right"]:
		if HELD.id(ui, side) != KEG.MUG_EMPTY: continue
		var at := HELD.point(ui, side)
		if at.is_finite() and at.distance_to(tap_point()) <= TAP_REACH and fill(ui, side): return

func station_hint(ui: Node, side: String) -> Dictionary:
	if side != "desktop":
		var at := HELD.point(ui, side)
		if not at.is_finite() or at.distance_to(tap_point()) > 0.6: return {}
	elif not HELD.looking_at(ui, tap_point(), LOOK_RADIUS, LOOK_REACH):
		return {}
	var why := can_fill(ui, side)
	var text := ""
	if why.is_empty(): text = "Hold the mug at the tap · Fill" if side != "desktop" else "Click · Fill the mug"
	elif HELD.id(ui, side) == KEG.MUG_EMPTY or HELD.id(ui, side).is_empty(): text = "%s (%d mugs left)" % [why, servings()] if why != "The stand keg is empty" else why
	if text.is_empty(): return {}
	return {"target": self, "text": text, "point": tap_point() + Vector3.UP * 0.2, "outline": _keg_visual}

func station_use(ui: Node, side: String, down: bool) -> bool:
	if not down or side != "desktop": return false
	if not HELD.looking_at(ui, tap_point(), LOOK_RADIUS, LOOK_REACH): return false
	return fill(ui, side)
