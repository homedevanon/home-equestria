extends "res://world/life/day/actions/seasonal/seasonal_step.gd"
## Winter: skate on the frozen pond or canal (M-SEA-19) once W2-SEAS-G's ice slabs are down
## (season_state ice > 0.6 and an IceSlabs slab within 200 m of the table's place). She goes to the
## nearest slab and glides in loops across it at a walk; pony locomotion has no skating gait, so it
## reads as careful laps. No slab nearby: the step is dropped.
const MIN_ICE := 0.6
const REACH := 200.0

func _init() -> void:
	play_kind = "skate"
	beat_seconds = Vector2(3.0, 4.5)

func allowed(ctx: Dictionary, at: Vector3) -> bool:
	if WORLD.amount(ctx.tree, "ice") < MIN_ICE: return false
	var slabs := WORLD.ice_points(ctx.tree, at, REACH)
	if slabs.is_empty(): return false
	_point = slabs[0]
	return true

func beat(ctx: Dictionary) -> void:
	ctx.nav.face_point = Vector3.INF
	ctx.nav.go_to(around(ctx, _point, 3.5), ctx.nav.Gait.WALK)
