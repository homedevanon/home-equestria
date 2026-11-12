extends "res://world/life/day/day_action.gd"
## Eat at the Hayburger (M-ACT-01, board #348). She walks to the restaurant, then comes in as one
## of its own customers (world/minigames/hayburger/hayburger_customers.gd request_day_visit):
## through the one-way door, to the counter when Anon is working a shift (she orders from him and
## waits for her burger) or to the self-serve kiosk when he is not, then she sits in a booth at a
## table (seating.gd booth_seats) and eats for the step's minutes, and walks out. The visit keeps
## her day owner ("day:<id>") on her navigator, so the day runner keeps the step; the restaurant's
## three-visitor limit holds for day visits too. Closed, full, or no restaurant loaded: the step
## is dropped. Unloaded: an ordinary stay there (day_runner essence).
## Within this of the restaurant's landmark she asks to come in (its legs then run inside the
## restaurant's own 120 s travel limit).
const NEAR := 25.0
var _customers: Node
var _point := Vector3.INF
var _phase := "travel"
var _tries := 0
var _ate := false
var reason := ""

static func customers_of(tree: SceneTree) -> Node:
	var found: Node = tree.get_first_node_in_group("hayburger_customers") if tree != null else null
	return found if is_instance_valid(found) and found.has_method("request_day_visit") else null

func start(ctx: Dictionary) -> bool:
	_customers = customers_of(ctx.tree)
	if _customers == null: reason = "No Hayburger here"; return false
	if _customers.get("_open") == false: reason = "The Hayburger is closed"; return false
	_point = place_point(ctx, str(ctx.step.get("target", "")))
	claim(ctx)
	if not _point.is_finite() or arrived(ctx, _point, NEAR): return _come_in(ctx)
	var far: bool = ctx.actor.global_position.distance_to(_point) > 40.0
	ctx.nav.go_to(_point, ctx.nav.Gait.TROT if far else ctx.nav.Gait.WALK)
	return true

func _come_in(ctx: Dictionary) -> bool:
	ctx.nav.stay()
	reason = str(_customers.call("request_day_visit", str(ctx.id), ctx.actor, "day:" + str(ctx.id), duration(float(ctx.step.get("minutes", 25.0)))))
	_phase = "visit"
	return reason.is_empty()

func tick(ctx: Dictionary, delta: float) -> String:
	seconds += delta
	if not is_instance_valid(_customers): reason = "The Hayburger went away"; return "failed"
	var nav: Node = ctx.nav
	var id := str(ctx.id)
	match _phase:
		"travel":
			if arrived(ctx, _point, NEAR) or nav.state == nav.State.ARRIVED:
				return "running" if _come_in(ctx) else "failed"
			if nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]:
				_tries += 1
				if _tries > 2: reason = "Could not reach the Hayburger"; return "failed"
				nav.go_to(_point, nav.Gait.WALK)
			elif not nav._has_target and seconds > 3.0:
				nav.go_to(_point, nav.Gait.WALK)
			if seconds > 300.0: reason = "Could not reach the Hayburger"; return "failed"
		"visit":
			if not bool(_customers.call("has_visit", id)):
				return "done" if _ate else "failed"
			if str(_customers.call("visit_phase", id)) in ["eating", "rising"]: _ate = true
	return "running"

func stop(ctx: Dictionary) -> void:
	_let_go(ctx)
	super.stop(ctx)

func release(ctx: Dictionary) -> void:
	_let_go(ctx)
	super.release(ctx)

func _let_go(ctx: Dictionary) -> void:
	if is_instance_valid(_customers) and bool(_customers.call("has_visit", str(ctx.id))):
		_customers.call("end_day_visit", str(ctx.id), "Day plan moved on")
