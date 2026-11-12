extends "res://world/life/day/day_action.gd"
## Cook at home (M-ACT-01): she goes home (through her door, like go_to.gd's "home"), walks to
## her kitchen's stove (world/cooking/: the home_cooker station a furnished kitchen counter
## carries) and stands at it facing the pan, the pan sizzling (the Hayburger grill's recorded
## loop), for the step's minutes. Then the kitchen made a meal: a "made" fact for the home_cooker
## station (stations.json workers: "resident") with one of the cooking recipes' dishes. No kitchen
## furnished in her house (or none loaded): she cooks where she stands at home, facing the room.
## Anon's own pan, ingredients and saved cooking state are never touched. Unloaded, offscreen()
## writes the same fact.
const STATIONS := preload("res://world/mechanics/stations/stations.gd")
const INDEX := preload("res://world/cooking/cooking_index.gd")
const RECIPES := preload("res://world/cooking/cooking_recipes.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
const HOME := preload("res://world/buildings/house_interior.gd")
## Metres in front of the stove's knob where she stands.
const STOVE_GAP := 0.55
## Real seconds she tries to reach the stove inside before cooking where she is.
const STOVE_PATIENCE := 20.0
var _house: Node3D
var _stove: Node3D
var _point := Vector3.INF
var _phase := "travel"
var _stay := 60.0
var _tries := 0
var _sizzle := 0
var meal := ""      # the dish she made, for tests/debug
var reason := ""

## The dish for a step: its table item ("carrot pancakes") by recipe name, else one per pony and day.
static func dish(step: Dictionary, pony: String, day: int) -> String:
	var wanted := str(step.get("item", "")).to_lower()
	for recipe: Dictionary in RECIPES.RECIPES:
		if str(recipe.name).to_lower() == wanted: return str(recipe.output)
	var pick := absi(hash("cook:%s:%d" % [pony, day])) % RECIPES.RECIPES.size()
	return str(RECIPES.RECIPES[pick].output)

## Her kitchen's cooking station (cooking_station.gd) in `house`, or null.
static func stove_of(house: Node3D) -> Node3D:
	if not is_instance_valid(house) or not house.has_method("place_id"): return null
	var prefix := str(house.call("place_id")) + ":"
	for key: Variant in INDEX.by_station:
		if not str(key).begins_with(prefix): continue
		var station := INDEX.lookup(str(key))
		if is_instance_valid(station) and station.is_inside_tree(): return station
	return null

## Floor point in front of the stove, by the authored knob (cooking_fit.gd), facing the pan.
static func stove_front(stove: Node3D) -> Vector3:
	var pan: Node3D = stove.get("pan") as Node3D
	var knob: Node3D = stove.get("knob") as Node3D
	var x: float = pan.position.x if is_instance_valid(pan) else 0.0
	var z: float = (knob.position.z if is_instance_valid(knob) else 0.3) + STOVE_GAP
	var at := stove.to_global(Vector3(x, 0.0, z))
	at.y = stove.global_position.y
	return at

func start(ctx: Dictionary) -> bool:
	var population: Node = ctx.get("population")
	_house = population.call("home_house", str(ctx.id)) if is_instance_valid(population) and population.has_method("home_house") else null
	if not is_instance_valid(_house): reason = "No home"; return false
	_point = _house.call("center") if _house.has_method("center") else _house.global_position
	if not _point.is_finite(): reason = "No home"; return false
	claim(ctx)
	_stay = duration(float(ctx.step.get("minutes", 30.0)))
	var far: bool = ctx.actor.global_position.distance_to(_point) > 40.0
	ctx.nav.go_to(_point, ctx.nav.Gait.TROT if far else ctx.nav.Gait.WALK)
	return true

func tick(ctx: Dictionary, delta: float) -> String:
	seconds += delta
	var nav: Node = ctx.nav
	if not is_instance_valid(_house): reason = "Home went away"; return "failed"
	match _phase:
		"travel":
			var inside: bool = _house.contains(ctx.actor.global_position) and not (nav.get("house_travel") != null and nav.house_travel.active())
			if (inside and arrived(ctx, _point, 1.5)) or (inside and nav.state == nav.State.ARRIVED):
				_stove = stove_of(_house)
				if _stove == null:
					_begin_cooking(ctx)
					return "running"
				_point = stove_front(_stove)
				_phase = "to_stove"; seconds = 0.0
				nav.go_to(_point, nav.Gait.WALK)
				return "running"
			if nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]:
				_tries += 1
				if _tries > 2: reason = "Could not get home"; return "failed"
				nav.go_to(_point, nav.Gait.WALK)
			elif not nav._has_target and seconds > 3.0:
				nav.go_to(_point, nav.Gait.WALK)
			if seconds > 300.0: reason = "Could not get home"; return "failed"
		"to_stove":
			if arrived(ctx, _point, 0.45) or nav.state == nav.State.ARRIVED or seconds > STOVE_PATIENCE \
					or nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]:
				_begin_cooking(ctx)
		"cook":
			if is_instance_valid(_stove) and _sizzle != 0 and not SFX.update_loop(ctx.actor, _sizzle, {"intensity": .55}, _pan_point()): _sizzle = 0
			if seconds < _stay: return "running"
			_stop_sizzle(ctx)
			meal = dish(ctx.step, str(ctx.id), int(ctx.get("day", 0)))
			var stations: Node = STATIONS.of(ctx.tree)
			if stations != null: stations.note_made("home_cooker", str(ctx.id), [meal], "", "made")
			return "done"
	return "running"

func _begin_cooking(ctx: Dictionary) -> void:
	ctx.nav.stay()
	_phase = "cook"; seconds = 0.0
	if is_instance_valid(_stove):
		ctx.nav.face_point = _pan_point()
		if ctx.actor is Node3D and (ctx.actor as Node3D).is_inside_tree(): _sizzle = SFX.start_loop(ctx.actor, "prop_sizzle_loop", {"intensity": .55})

func _pan_point() -> Vector3:
	var pan: Node3D = _stove.get("pan") as Node3D if is_instance_valid(_stove) else null
	return pan.global_position if is_instance_valid(pan) else (_stove.global_position if is_instance_valid(_stove) else Vector3.INF)

func _stop_sizzle(ctx: Dictionary) -> void:
	if _sizzle != 0 and is_instance_valid(ctx.get("actor")): SFX.stop_loop(ctx.actor, _sizzle, .3)
	_sizzle = 0

func stop(ctx: Dictionary) -> void:
	_stop_sizzle(ctx)
	super.stop(ctx)

func release(ctx: Dictionary) -> void:
	_stop_sizzle(ctx)
	super.release(ctx)

## Her essence cooked at home while unloaded: the same meal fact.
static func offscreen(ctx: Dictionary) -> void:
	var stations: Node = STATIONS.of(ctx.get("tree"))
	if stations == null: return
	stations.note_made("home_cooker", str(ctx.get("id", "")), [dish(ctx.get("step", {}), str(ctx.get("id", "")), int(ctx.get("day", 0)))], "", "made")
