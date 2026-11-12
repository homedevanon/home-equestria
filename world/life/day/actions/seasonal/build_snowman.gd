extends "res://world/life/day/actions/seasonal/seasonal_step.gd"
## Winter: build a snowman (M-SEA-19). She pats and rolls snow at the spot (hoof raises, a
## unicorn's magic, short trots round it) and leaves a snowman there when the time is up, through
## W2-SEAS-F's SnowPlay.build_snowman(at, facing, by); absent = the work without the snowman.
## A snowman Anon built close by draws her there ("ponies sometimes build one beside Anon's").
const MIN_SNOW := 0.45
var _site := Vector3.INF

func _init() -> void:
	play_kind = "snowman"
	beat_seconds = Vector2(4.0, 7.0)

const BESIDE_ANON := 40.0

func allowed(ctx: Dictionary, at: Vector3) -> bool:
	if WORLD.wet(ctx.tree) or WORLD.snow_here(ctx.tree, at) < MIN_SNOW: return false
	# Anon's snowman near the place: hers goes up beside it.
	var his := WORLD.player_snowman(ctx.tree, at, BESIDE_ANON)
	if his.is_finite(): _point = around(ctx, his, 3.0)
	return true

func arrive(ctx: Dictionary) -> void:
	_site = ctx.actor.global_position - ctx.actor.global_basis.z * 1.2

func beat(ctx: Dictionary) -> void:
	ctx.nav.face_point = _site
	if randf() < 0.35:
		# Roll the next ball round the site.
		ctx.nav.go_to(around(ctx, _site, 1.4), ctx.nav.Gait.WALK)
	else:
		WORLD.gesture(ctx.actor, WORLD.race(ctx.actor))

func finish(ctx: Dictionary) -> void:
	# SnowPlay's facing is a direction (snow_play.gd _face), not a point: toward her.
	if _site.is_finite(): WORLD.build_snowman(ctx.tree, _site, ctx.actor.global_position - _site, str(ctx.id))
