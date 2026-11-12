extends "res://world/life/day/actions/seasonal/seasonal_step.gd"
## Autumn: rake the fallen leaves back into a pile (M-SEA-19). She works back and forth over a
## few metres at a walk (a unicorn with magic), and when the time is up the scattered leaves round
## the spot are raked up through W2-SEAS-E's LeafPiles.rake(at, radius, 1); absent = the work
## alone. Only once leaves lie on the ground (season_state leaf_litter).
const MIN_LITTER := 0.2
const RADIUS := 6.0

func _init() -> void:
	play_kind = "rake"
	beat_seconds = Vector2(4.0, 6.0)

func allowed(ctx: Dictionary, _at: Vector3) -> bool:
	return not WORLD.wet(ctx.tree) and WORLD.amount(ctx.tree, "leaf_litter") >= MIN_LITTER

func beat(ctx: Dictionary) -> void:
	var stroke := around(ctx, _point, 2.0)
	ctx.nav.face_point = _point
	ctx.nav.go_to(stroke, ctx.nav.Gait.WALK)
	if WORLD.race(ctx.actor) == "unicorn": WORLD.gesture(ctx.actor, "unicorn")

func finish(ctx: Dictionary) -> void:
	WORLD.rake(ctx.tree, _point, RADIUS)
