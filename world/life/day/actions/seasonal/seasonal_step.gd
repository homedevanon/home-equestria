extends "res://world/life/day/day_action.gd"
## Shared shape of the seasonal day steps (M-SEA-19, world/life/day/tables/seasonal.json): walk to
## the step's place (or stay where she is for an injected step with no target), then do the fun
## there on a beat every few seconds until the step's time is up. Existing poses and gestures only.
## Subclasses override allowed(), arrive(), beat() and finish(). The runner ticks every 0.5 s.
const WORLD := preload("res://world/life/day/actions/seasonal/season_world.gd")
const TRAVEL_LIMIT := 300.0
var _point := Vector3.INF
var _phase := "travel"
var _stay := 60.0
var _tries := 0
var _beat_in := 0.0
## What she does, as meta "season_play" while playing (playmates find each other by it).
var play_kind := ""
## Seconds between beats.
var beat_seconds := Vector2(3.0, 6.0)

## Whether the season and weather allow the step here and now (snow lying, sun out...).
func allowed(_ctx: Dictionary, _at: Vector3) -> bool: return true

func arrive(_ctx: Dictionary) -> void: pass

func beat(_ctx: Dictionary) -> void: pass

func finish(_ctx: Dictionary) -> void: pass

func start(ctx: Dictionary) -> bool:
	var target := str(ctx.step.get("target", ""))
	_point = ctx.actor.global_position if target.is_empty() else place_point(ctx, target)
	if not _point.is_finite(): return false
	# Spread out around a shared place instead of all standing on one point.
	if not target.is_empty():
		var h := absi(hash(str(ctx.id) + target))
		var angle := float(h % 360) * PI / 180.0
		_point += Vector3(cos(angle), 0.0, sin(angle)) * (2.0 + float(h % 5) * 0.5)
	if ctx.nav.has_method("command_support"):
		var walkable: Vector3 = ctx.nav.command_support(_point)
		if walkable.is_finite(): _point = walkable
	if not allowed(ctx, _point): return false
	claim(ctx)
	_stay = duration(float(ctx.step.get("minutes", 20.0)))
	if target.is_empty() or arrived(ctx, _point, 3.0):
		_begin(ctx)
	else:
		var far: bool = ctx.actor.global_position.distance_to(_point) > 40.0
		ctx.nav.go_to(_point, ctx.nav.Gait.TROT if far else ctx.nav.Gait.WALK)
	return true

func _begin(ctx: Dictionary) -> void:
	_phase = "play"; seconds = 0.0
	ctx.nav.stay()
	if not play_kind.is_empty(): ctx.actor.set_meta("season_play", play_kind)
	_beat_in = 1.0
	arrive(ctx)

func tick(ctx: Dictionary, delta: float) -> String:
	seconds += delta
	var nav: Node = ctx.nav
	match _phase:
		"travel":
			if arrived(ctx, _point, 3.0) or nav.state == nav.State.ARRIVED:
				_begin(ctx)
				return "running"
			if nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]:
				_tries += 1
				if _tries > 2: return "failed"
				nav.go_to(_point, nav.Gait.WALK)
			elif not nav._has_target and seconds > 3.0:
				nav.go_to(_point, nav.Gait.WALK)
			if seconds > TRAVEL_LIMIT: return "failed"
		"play":
			if seconds >= _stay:
				finish(ctx)
				return "done"
			_beat_in -= delta
			if _beat_in <= 0.0:
				_beat_in = randf_range(beat_seconds.x, beat_seconds.y)
				beat(ctx)
	return "running"

func release(ctx: Dictionary) -> void:
	var actor: Variant = ctx.get("actor")
	if is_instance_valid(actor) and (actor as Node3D).has_meta("season_play"): (actor as Node3D).remove_meta("season_play")
	super.release(ctx)

## A point `radius` around `centre` at a random angle, snapped to walkable ground when it can be.
func around(ctx: Dictionary, centre: Vector3, radius: float) -> Vector3:
	var angle := randf() * TAU
	var at := centre + Vector3(cos(angle), 0.0, sin(angle)) * radius
	if ctx.nav.has_method("command_support"):
		var walkable: Vector3 = ctx.nav.command_support(at)
		if walkable.is_finite(): return walkable
	return at
