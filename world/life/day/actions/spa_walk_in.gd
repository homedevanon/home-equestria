extends "res://world/life/day/day_action.gd"
## Walk into the day spa as a customer (M-ACT-01) while Anon is not working there. She walks to
## the spa, then in through its door (world/minigames/spa/spa_customers.gd request_walk_in),
## soaks her hooves standing in a footbath, facing it like a client waiting to be filed, for the
## step's minutes, and walks out again. Only when the spa is open and has no client of Anon's;
## ringing the counter bell sends walk-ins on their way so his clients can come in. Mares and
## fillies under the rooms' size limit, never the spa staff (the spa's own rules). Her day owner
## ("day:<id>") stays on her navigator throughout. Unloaded: an ordinary stay at the spa.
## Within this of the spa's landmark she goes in (the spa's legs then run in its own time limits).
const NEAR := 25.0
var _spa: Node
var _point := Vector3.INF
var _phase := "travel"
var _tries := 0
var _soaked := false
var reason := ""

static func spa_of(tree: SceneTree) -> Node:
	var venue: Node = tree.get_first_node_in_group("spa_venue") if tree != null else null
	var customers: Variant = venue.get("customers") if venue != null else null
	return customers as Node if customers is Node and is_instance_valid(customers) and (customers as Node).has_method("request_walk_in") else null

func start(ctx: Dictionary) -> bool:
	_spa = spa_of(ctx.tree)
	if _spa == null: reason = "No spa here"; return false
	if not bool(_spa.call("is_open_now")) or not (_spa.call("anon_clients") as Array).is_empty(): reason = "The spa is not taking walk-ins"; return false
	_point = place_point(ctx, str(ctx.step.get("target", "")))
	claim(ctx)
	if not _point.is_finite() or arrived(ctx, _point, NEAR): return _go_in(ctx)
	var far: bool = ctx.actor.global_position.distance_to(_point) > 40.0
	ctx.nav.go_to(_point, ctx.nav.Gait.TROT if far else ctx.nav.Gait.WALK)
	return true

func _go_in(ctx: Dictionary) -> bool:
	ctx.nav.stay()
	reason = str(_spa.call("request_walk_in", str(ctx.id), ctx.actor, "day:" + str(ctx.id), duration(float(ctx.step.get("minutes", 30.0)))))
	_phase = "visit"
	return reason.is_empty()

func tick(ctx: Dictionary, delta: float) -> String:
	seconds += delta
	if not is_instance_valid(_spa): reason = "The spa went away"; return "failed"
	var nav: Node = ctx.nav
	var id := str(ctx.id)
	match _phase:
		"travel":
			if arrived(ctx, _point, NEAR) or nav.state == nav.State.ARRIVED:
				return "running" if _go_in(ctx) else "failed"
			if nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]:
				_tries += 1
				if _tries > 2: reason = "Could not reach the spa"; return "failed"
				nav.go_to(_point, nav.Gait.WALK)
			elif not nav._has_target and seconds > 3.0:
				nav.go_to(_point, nav.Gait.WALK)
			if seconds > 300.0: reason = "Could not reach the spa"; return "failed"
		"visit":
			if not bool(_spa.call("is_client", id)):
				return "done" if _soaked else "failed"
			if str(_spa.call("visit_phase", id)) == "soak": _soaked = true
	return "running"

func stop(ctx: Dictionary) -> void:
	_let_go(ctx)
	super.stop(ctx)

func release(ctx: Dictionary) -> void:
	_let_go(ctx)
	super.release(ctx)

func _let_go(ctx: Dictionary) -> void:
	if is_instance_valid(_spa) and bool(_spa.call("is_client", str(ctx.id))):
		_spa.call("end_walk_in", str(ctx.id), "Day plan moved on")
