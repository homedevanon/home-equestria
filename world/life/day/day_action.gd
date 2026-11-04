extends RefCounted
## One kind of day-plan step (docs/DAY_PLANS.md). The runner makes a new instance for every step
## and calls start() once, tick() every half second until it returns "done" or "failed", and
## stop() if the step is cut short (bedtime, the player picking her up, a command). A handler owns
## the pony's navigator while it runs (command_owner "day:<id>"); the living world pauses itself
## meanwhile and takes her back afterwards.
##
## ctx: {"id", "actor", "nav", "step", "runner", "population", "night_rest", "tree"}

const SPOTS := preload("res://world/props/ponyville_kit/kit_spots.gd")
const PLACES := preload("res://world/navigation/place_directory.gd")
var seconds := 0.0        # time spent in this step (real seconds)

## Begin the step; false if it cannot be done now (the runner drops it).
func start(_ctx: Dictionary) -> bool: return false

## "running", "done" or "failed"; "made" is done with the memory already written by the handler.
func tick(_ctx: Dictionary, _delta: float) -> String: return "done"

## Cut short: leave the pony standing and free.
func stop(ctx: Dictionary) -> void:
	release(ctx)

func claim(ctx: Dictionary) -> void:
	ctx.nav.stay()
	ctx.nav.command_owner = "day:" + str(ctx.id)
	ctx.nav.wander_enabled = false

func release(ctx: Dictionary) -> void:
	var nav: Node = ctx.get("nav") if is_instance_valid(ctx.get("nav")) else null
	if is_instance_valid(nav) and str(nav.command_owner) == "day:" + str(ctx.id):
		nav.stay()
		nav.face_point = Vector3.INF
		nav.command_owner = ""

## Real seconds a step of `minutes` game minutes lasts: at least a minute, however fast the day.
func duration(minutes: float) -> float:
	var clock: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null("TimeOfDay")
	var per_hour := 75.0
	if clock != null and "day_length_minutes" in clock: per_hour = float(clock.day_length_minutes) * 60.0 / 24.0
	return maxf(60.0, minutes / 60.0 * per_hour)

## A standable point for a table target: "home", "landmark:<id>", a house place id, a region.
func place_point(ctx: Dictionary, target: String) -> Vector3:
	if target.begins_with("spot:"):
		var record := spot(ctx, target)
		return record.get("approach", Vector3.INF)
	if target == "home":
		var house: Node3D = ctx.population.home_house(ctx.id) if ctx.population.has_method("home_house") else null
		return house.center() if house != null else ctx.population.home_position(ctx.id, true) if ctx.population.has_method("home_position") else Vector3.INF
	return PLACES.resolve(ctx.tree, target)

## A label for talk and debug: "Sugarcube Corner", "home", "Fluttershy".
static func label(tree: SceneTree, target: String) -> String:
	if target.begins_with("spot:"): return target.trim_prefix("spot:").replace("_", " ")
	if target == "home": return "home"
	if target.begins_with("station:") or target.begins_with("job:"):
		# Mechanics stations and jobs (P7 day tables): their names ("cider press", "cider stand").
		var owner: Node = tree.get_first_node_in_group("mechanics_stations" if target.begins_with("station:") else "mechanics_jobs") if tree != null else null
		var id := target.get_slice(":", 1)
		var row: Variant = owner.call("spec", id) if owner != null and owner.has_method("spec") else null
		return str((row as Dictionary).get("name", id.replace("_", " "))) if row is Dictionary else id.replace("_", " ")
	if not target.contains(":"): return target.replace("_", " ").capitalize().split(" ")[0]
	var e := PLACES.find(tree, target)
	return str(e.get("label", target))

func arrived(ctx: Dictionary, point: Vector3, radius := 2.5) -> bool:
	var here: Vector3 = ctx.actor.global_position
	return Vector2(here.x - point.x, here.z - point.z).length() < radius and absf(here.y - point.y) < 2.0

## Resolve once per requested kind for this handler, including chained well/garden work.
func spot(ctx: Dictionary, kind := "") -> Dictionary:
	var target := str(ctx.step.target) if kind.is_empty() else kind
	var key := target.trim_prefix("spot:")
	if not ctx.has("spots"): ctx.spots = {}
	if not ctx.spots.has(key):
		var record: Dictionary = SPOTS.resolve(ctx.population, str(ctx.id), key)
		if not record.is_empty() and str(record.kind) in ["bench", "tree_stump"]:
			record.seat_point = kit_seat_point(ctx.tree, str(record.id))
		ctx.spots[key] = record
	return ctx.spots[key]

## The live seat marker kit_dressing.gd made for a kit bench/stump (meta kit_spot_id), or INF.
## Never an invented height: no marker, no seat.
static func kit_seat_point(tree: SceneTree, spot_id: String) -> Vector3:
	if tree == null: return Vector3.INF
	for seat: Node in tree.get_nodes_in_group("pony_seats"):
		if seat is Node3D and seat.has_meta("kit_spot_id") and str(seat.get_meta("kit_spot_id")) == spot_id:
			return (seat as Node3D).global_position
	return Vector3.INF
