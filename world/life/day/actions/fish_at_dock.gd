extends "res://world/life/day/day_action.gd"
## Go fishing at the river dock (M-ACT-01; world/minigames/fishing/). She walks to the dock's
## bank end, then the dock's companion controller (fishing_companions.gd invite_day) walks her
## to the rod rack, takes a rod in her mouth, carries it to a free spot at the water end, casts,
## hooks and reels with the same rod and line code Anon uses, whether or not Anon is fishing.
## Her day owner ("day:<id>") stays on her navigator the whole time, so the day runner keeps the
## step. A fish she lands is a "caught" fact for the fishing_dock station (counters only; no
## loose fish pile up when Anon is not there). Two ponies at most (the dock's companion spots,
## shared with Anon's fishing company). Unloaded, offscreen() may record a catch, facts only.
const STATIONS := preload("res://world/mechanics/stations/stations.gd")
## Her essence lands a fish this often (seeded per pony and day), facts only.
const OFFSCREEN_CATCH := 0.5
var _companions: Node
var _point := Vector3.INF
var _phase := "travel"
var _stay := 60.0
var _tries := 0
var reason := ""   # why it failed, for tests/debug

## The dock's companion controller (fishing_runtime.gd's child), or null when the dock is not loaded.
static func companions_of(tree: SceneTree) -> Node:
	var dock: Node = tree.get_first_node_in_group("fishing_docks") if tree != null else null
	var runtime: Node = dock.get_parent() if dock != null else null
	var found: Variant = runtime.get("companions") if runtime != null else null
	return found as Node if found is Node and is_instance_valid(found) and (found as Node).has_method("invite_day") else null

func start(ctx: Dictionary) -> bool:
	_companions = companions_of(ctx.tree)
	if _companions == null: reason = "No dock here"; return false
	if not bool(_companions.call("day_spot_free")): reason = "The dock is full"; return false
	var dock: Node3D = _companions.get("dock") as Node3D
	var approach: Variant = dock.get("approach") if is_instance_valid(dock) else null
	if not approach is Node3D: reason = "No dock here"; return false
	_point = (approach as Node3D).global_position
	claim(ctx)
	_stay = duration(float(ctx.step.get("minutes", 30.0)))
	var far: bool = ctx.actor.global_position.distance_to(_point) > 40.0
	ctx.nav.go_to(_point, ctx.nav.Gait.TROT if far else ctx.nav.Gait.WALK)
	return true

func tick(ctx: Dictionary, delta: float) -> String:
	seconds += delta
	var nav: Node = ctx.nav
	if not is_instance_valid(_companions): reason = "The dock went away"; return "failed"
	match _phase:
		"travel":
			if arrived(ctx, _point, 3.0) or nav.state == nav.State.ARRIVED:
				nav.stay()
				if not bool(_companions.call("invite_day", str(ctx.id), ctx.actor, "day:" + str(ctx.id))):
					reason = "No free rod or spot"; return "failed"
				_phase = "fish"; seconds = 0.0
				return "running"
			if nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]:
				_tries += 1
				if _tries > 2: reason = "Could not reach the dock"; return "failed"
				nav.go_to(_point, nav.Gait.WALK)
			elif not nav._has_target and seconds > 3.0:
				nav.go_to(_point, nav.Gait.WALK)
			if seconds > 300.0: reason = "Could not reach the dock"; return "failed"
		"fish":
			# The controller let her go (interrupted, a route refused, the rod taken): a step that
			# got her fishing counts as done, one that never cast does not.
			if not bool(_companions.call("has_day_lease", str(ctx.id))):
				return "done" if bool(_companions.call("day_fished", str(ctx.id))) else "failed"
			if seconds >= _stay:
				_companions.call("release_day", str(ctx.id), "day step over")
				return "done"
	return "running"

func stop(ctx: Dictionary) -> void:
	_let_go(ctx, "day step stopped")
	super.stop(ctx)

func release(ctx: Dictionary) -> void:
	_let_go(ctx, "day step released")
	super.release(ctx)

func _let_go(ctx: Dictionary, cause: String) -> void:
	if is_instance_valid(_companions) and bool(_companions.call("has_day_lease", str(ctx.id))):
		_companions.call("release_day", str(ctx.id), cause)

## Her essence fished while unloaded: sometimes a catch, as a fact for the dock.
static func offscreen(ctx: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("fish:%s:%d" % [str(ctx.get("id", "")), int(ctx.get("day", 0))])
	if rng.randf() >= OFFSCREEN_CATCH: return
	var stations: Node = STATIONS.of(ctx.get("tree"))
	if stations != null: stations.note_made("fishing_dock", str(ctx.get("id", "")), ["river-fish"], "", "caught")
