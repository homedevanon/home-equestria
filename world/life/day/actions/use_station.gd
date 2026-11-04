extends "res://world/life/day/day_action.gd"
## Work a station (world/mechanics/stations/stations.gd; docs/MECHANICS_ARCHITECTURE_2026_11_01.md
## 6.5): walk to it, face it, fill its inputs from its supply and work it until it completes or
## the step's minutes run out. Target "station:<id>". A [use: STATION] tag puts this step at the
## front of her day card (day_runner.inject_now); day tables list it too (P7: press_cider,
## water_saplings, buck_apples). Unloaded, offscreen() completes it facts-only.
##
## Three kinds of station (P7, section 10.3):
## - process (the cider press): as above. When its supply is short she may ask Anon for the inputs
##   (a "day_plan" favour, 30 % a day, once she has met him and has no open favour), then the step fails.
## - grow (Anon's row): she waters every dry sapling (stations.water_plot), visibly at the plot.
## - adapter chores (the orchard in Applebuck Season): she goes there and works a while; a "worked"
##   fact only, never Anon's harvest ledger.
const STATIONS := preload("res://world/mechanics/stations/stations.gd")
const ASKS := preload("res://world/mechanics/asks/asks.gd")
const FACTS := preload("res://world/mechanics/facts.gd")
const ITEM_CATALOG := preload("res://world/inventory/item_catalog.gd")
## Adapter stations ponies may work as a chore, and the job its "worked" fact names.
const CHORES := {"orchard_tree": "orchard_bucking"}
const ASK_CHANCE := 0.3
const ASK_HOURS := 12.0
const WATER_SECONDS := 20.0   # real seconds at the plot before the slots count as watered
var _station := ""
var _mode := "process"   # "process", "grow" or "chore"
var _point := Vector3.INF
var _phase := "travel"
var _stay := 60.0
var _tries := 0
var reason := ""   # why it failed, for tests/debug

static func _id(step: Dictionary) -> String:
	return str(step.get("target", "")).trim_prefix("station:")

static func _stations(tree: SceneTree) -> Node:
	return STATIONS.of(tree)

## "process", "grow" or "chore" (an adapter in CHORES); "" for a station ponies do not work.
static func mode_of(spec: Dictionary) -> String:
	match str(spec.get("kind", "")):
		"process": return "process"
		"grow": return "grow"
		"adapter": return "chore" if CHORES.has(str(spec.get("id", ""))) else ""
	return ""

## "" when `pony` can start this station's step now, else why not.
static func ready_reason(stations: Node, id: String, pony: String) -> String:
	var spec: Dictionary = stations.spec(id)
	match mode_of(spec):
		"process":
			var why: String = stations.can_work(id, pony)
			if not why.is_empty(): return why
			if not bool(stations.call("_fillable", id, pony)):
				return "No %s for the %s" % [str(stations.call("_supply_missing", id, pony)), stations.display_name(id)]
			return ""
		"grow":
			var workers: Array = spec.get("workers", [])
			if not (pony in workers or "any_pony" in workers): return "You do not work the %s" % stations.display_name(id)
			if (stations.call("_dry_slots", id) as Array).is_empty(): return "Nothing to water at the %s" % stations.display_name(id)
			return ""
		"chore":
			var jobs: Node = (stations.get_tree().get_first_node_in_group("mechanics_jobs") if stations.is_inside_tree() else null)
			var employers: Variant = jobs.call("spec", CHORES[id]).get("employers", []) if jobs != null else []
			if not employers is Array or not pony in (employers as Array): return "You do not work the %s" % stations.display_name(id)
			return stations.needs_met(id)
	return "The %s is not worked that way" % stations.display_name(id)

func start(ctx: Dictionary) -> bool:
	var stations := _stations(ctx.tree)
	_station = _id(ctx.step)
	if stations == null or stations.spec(_station).is_empty(): reason = "No such station"; return false
	_mode = mode_of(stations.spec(_station))
	reason = ready_reason(stations, _station, str(ctx.id))
	if not reason.is_empty():
		if _mode == "process" and reason.begins_with("No "): shortfall_ask(ctx.tree, _station, str(ctx.id), int(ctx.get("day", -1)))
		return false
	_point = stations.work_point(_station)
	if not _point.is_finite(): reason = "Nowhere to go"; return false
	claim(ctx)
	_stay = duration(float(ctx.step.get("minutes", 20.0)))
	var far: bool = ctx.actor.global_position.distance_to(_point) > 40.0
	ctx.nav.go_to(_point, ctx.nav.Gait.TROT if far else ctx.nav.Gait.WALK)
	return true

func tick(ctx: Dictionary, delta: float) -> String:
	seconds += delta
	var nav: Node = ctx.nav
	var stations := _stations(ctx.tree)
	if stations == null: return "failed"
	match _phase:
		"travel":
			if arrived(ctx, _point, 2.5 if _mode == "process" else 4.0) or nav.state == nav.State.ARRIVED:
				nav.stay()
				var node: Node3D = stations.station_node(_station)
				if node != null: nav.face_point = node.global_position
				if _mode == "process":
					reason = stations.load_from_supply(_station, str(ctx.id))
					if not reason.is_empty():
						if reason.begins_with("No "): shortfall_ask(ctx.tree, _station, str(ctx.id), int(ctx.get("day", -1)))
						return "failed"
				_phase = "work"; seconds = 0.0
				return "running"
			if nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]:
				_tries += 1
				if _tries > 2: reason = "Could not reach it"; return "failed"
				nav.go_to(_point, nav.Gait.WALK)
			elif not nav._has_target and seconds > 3.0:
				nav.go_to(_point, nav.Gait.WALK)
			if seconds > 300.0: reason = "Could not reach it"; return "failed"
		"work":
			match _mode:
				"grow":
					# She tends the row a little while, then every dry sapling counts as watered today.
					if seconds < minf(WATER_SECONDS, _stay): return "running"
					if stations.water_plot(_station, str(ctx.id)) > 0: return "done"
					reason = "Nothing to water"; return "failed"
				"chore":
					if seconds < _stay: return "running"
					chore_done(ctx.tree, _station, str(ctx.id), int(ctx.get("day", -1)))
					return "done"
			# "made", not "done": the station's made fact already holds the memory (day_runner skips
			# its own "finished" line); running out of time with nothing made is a failure.
			if not stations.work(_station, str(ctx.id), delta).is_empty(): return "made"
			reason = stations.can_work(_station, str(ctx.id))
			if not reason.is_empty(): return "failed"
			if seconds >= _stay: reason = "Ran out of time"; return "failed"
	return "running"

## Her essence did the step while unloaded: the station completes facts-only (process), the row is
## watered (grow) or the chore counts (adapter).
static func offscreen(ctx: Dictionary) -> void:
	var tree: SceneTree = ctx.get("tree")
	var stations := _stations(tree)
	if stations == null: return
	var id := _id(ctx.get("step", {}))
	var pony := str(ctx.get("id", ""))
	match mode_of(stations.spec(id)):
		"process":
			# Only a real shortage asks Anon (as on screen): a busy press, or Anon at it, does not.
			if stations.offscreen_work(id, pony) or not str(stations.can_work(id, pony)).is_empty(): return
			if not str(stations.call("_supply_missing", id, pony)).is_empty(): shortfall_ask(tree, id, pony, int(ctx.get("day", -1)))
		"grow":
			if ready_reason(stations, id, pony).is_empty(): stations.water_plot(id, pony)
		"chore":
			if ready_reason(stations, id, pony).is_empty(): chore_done(tree, id, pony, int(ctx.get("day", -1)))

## A chore at an adapter station: one "worked" fact for its job (no text: the day runner's own
## finished line is the memory), once per pony, station and day.
static func chore_done(tree: SceneTree, id: String, pony: String, day: int) -> void:
	var facts: Node = FACTS.of(tree)
	if facts == null: return
	if day < 0: day = int(FACTS.clock().day)
	facts.add("worked", {"actor": pony, "ref": str(CHORES.get(id, id)), "count": 1, "key": "chore:%s:%s:%d" % [id, pony, day]})

## The press is short of apples: she may ask Anon for them (section 10.3). Deterministic 30 % per
## pony, station and day; only once she has met him, has no open favour and the favour rules allow
## it (asks.gd create checks her purse, caps and cooldown). True when a favour was made.
static func shortfall_ask(tree: SceneTree, id: String, pony: String, day: int) -> bool:
	var stations := _stations(tree)
	var asks: Node = ASKS.of(tree)
	if stations == null or asks == null: return false
	if day < 0: day = int(FACTS.clock().day)
	# A seeded generator, not hash() % n: string hashes of consecutive days are consecutive numbers.
	var roll := RandomNumberGenerator.new()
	roll.seed = hash("shortfall:%s:%s:%d" % [pony, id, day])
	if roll.randf() >= ASK_CHANCE: return false
	if not met_anon(tree, pony) or not (asks.open_for(pony) as Dictionary).is_empty(): return false
	var inputs: Array = stations.spec(id).get("inputs", [])
	if inputs.is_empty() or not inputs[0] is Dictionary: return false
	var entry: Dictionary = inputs[0]
	var count := maxi(1, int(entry.get("count", 1)))
	var item := str(entry.get("id", entry.get("tag", "")))
	if item.is_empty(): return false
	var kind := "item" if entry.has("id") or ITEM_CATALOG.has(item) else "tag"
	var want := "%s:%s:%d" % [kind, item, count]
	var worth := maxi(1, ITEM_CATALOG.value(item) * count) if ITEM_CATALOG.has(item) else count
	var made: Dictionary = asks.create(pony, want, "bits:%d" % worth, "for the " + stations.display_name(id), "day_plan", ASK_HOURS)
	return bool(made.get("ok", false))

## Whether she has met Anon (player_bonds knowledge); false without bonds.
static func met_anon(tree: SceneTree, pony: String) -> bool:
	var hub: Node = tree.get_first_node_in_group("mechanics") if tree != null else null
	var context: Variant = hub.call("context") if hub != null and hub.has_method("context") else null
	var bonds: Variant = (context as Node).get("player_bonds") if is_instance_valid(context) and context is Node else null
	if not is_instance_valid(bonds) or not (bonds as Node).has_method("knowledge"): return false
	var known: Variant = (bonds as Node).call("knowledge", pony)
	return known is Dictionary and bool((known as Dictionary).get("met", false))
