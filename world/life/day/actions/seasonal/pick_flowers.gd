extends "res://world/life/day/actions/seasonal/seasonal_step.gd"
## Spring: pick flowers (M-SEA-19). She wanders from patch to patch over a few metres, stopping to
## pick (a hoof raise, a unicorn's magic), and walks off with a basket of them (pony_snack.gd
## carry_basket, the existing basket). Not in the rain.
const CARRY := preload("res://world/life/day/pony_snack.gd")

func _init() -> void:
	play_kind = "flowers"
	beat_seconds = Vector2(5.0, 8.0)

func allowed(ctx: Dictionary, _at: Vector3) -> bool:
	return not WORLD.wet(ctx.tree)

func beat(ctx: Dictionary) -> void:
	if randf() < 0.5:
		ctx.nav.face_point = Vector3.INF
		ctx.nav.go_to(around(ctx, _point, 3.0), ctx.nav.Gait.WALK)
	else:
		WORLD.gesture(ctx.actor, WORLD.race(ctx.actor))

func finish(ctx: Dictionary) -> void:
	CARRY.carry_basket(ctx.actor, 180.0)
