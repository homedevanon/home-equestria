extends "res://world/life/day/actions/seasonal/seasonal_step.gd"
## Winter: play in the snow with whoever else is out (M-SEA-19). Every few seconds she throws a
## snowball at a playmate within 14 m, or into the snow when nopony is about: earth ponies with a
## hoof, unicorns by magic, pegasi from above with a wing flutter (existing gestures; the snowball
## itself is W2-SEAS-F's SnowPlay.throw_snowball; inactive = the gesture alone). Needs lying snow.
const MIN_SNOW := 0.3
const REACH := 14.0
const HOME := preload("res://world/buildings/house_interior.gd")

func _init() -> void:
	play_kind = "snow"
	beat_seconds = Vector2(3.0, 6.5)

func allowed(ctx: Dictionary, at: Vector3) -> bool:
	if WORLD.wet(ctx.tree): return false
	# An injected step plays where she stands: never inside a house (snowballs indoors).
	if str(ctx.step.get("target", "")).is_empty() and HOME.at(ctx.tree, at) != null: return false
	if WORLD.snow_here(ctx.tree, at) >= MIN_SNOW: return true
	# Sent out by the shelter owner as the first flakes fall (no target): she frolics in the falling
	# snow before any lies; the snowballs start once it does.
	var sky := WORLD.weather(ctx.tree)
	return str(ctx.step.get("target", "")).is_empty() and sky != null and sky.has_method("is_snowing") and bool(sky.call("is_snowing"))

func beat(ctx: Dictionary) -> void:
	var actor: Node3D = ctx.actor
	var friends := WORLD.playmates(ctx.tree, actor, play_kind, REACH)
	var at: Vector3
	if not friends.is_empty():
		var friend: Node3D = friends[randi() % friends.size()]
		at = friend.global_position + Vector3.UP * 0.6
	else:
		at = around(ctx, actor.global_position, 5.0)
	ctx.nav.face_point = at
	var kind := WORLD.race(actor)
	WORLD.gesture(actor, kind)
	var style: String = "magic" if kind == "unicorn" else ("air" if kind == "pegasus" else "hoof")
	WORLD.throw_snowball(ctx.tree, actor, at, style)
	# Now and then she scampers to a new spot, as one does in a snowball fight.
	if randf() < 0.3: ctx.nav.go_to(around(ctx, _point, 3.0), ctx.nav.Gait.TROT)
