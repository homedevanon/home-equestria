extends RefCounted
## What the seasonal day steps (world/life/day/actions/seasonal/, M-SEA-19) read from the world:
## season_state's amounts, the weather, and the optional wave-2 season features found by name
## under SeasonState (season_state.gd FEATURES: SnowPlay, LeafPiles, IceSlabs). Every feature call
## is duck-typed: a missing feature or method leaves the pony doing the step with existing poses
## and no prop effect. All reads happen on a step's start or its few-second beats, never per frame.
const COVER := preload("res://world/seasons/snow_cover_query.gd")
const CLIMATE := preload("res://world/seasons/climate_map.gd")

static func state(tree: SceneTree) -> Node:
	return tree.get_first_node_in_group("season_state") if tree != null else null

static func weather(tree: SceneTree) -> Node:
	return tree.get_first_node_in_group("weather") if tree != null else null

static func feature(tree: SceneTree, node_name: String, group := "") -> Node:
	if tree == null: return null
	if not group.is_empty():
		var grouped := tree.get_first_node_in_group(group)
		if grouped != null: return grouped
	var seasons := state(tree)
	return seasons.get_node_or_null(node_name) if seasons != null else null

static func amount(tree: SceneTree, getter: String) -> float:
	var seasons := state(tree)
	return float(seasons.call(getter)) if seasons != null and seasons.has_method(getter) else 0.0

## Snow lying here (cover x climate, ignoring slope and trail): cheap enough for a step start.
static func snow_here(tree: SceneTree, at: Vector3) -> float:
	var cover := amount(tree, "snow_cover")
	if cover <= 0.001: return 0.0
	return cover * CLIMATE.sample(Vector2(at.x, at.z), 0)

## Raining, hailing, a blizzard: no outdoor fun (weather.gd is_wet).
static func wet(tree: SceneTree) -> bool:
	var sky := weather(tree)
	return sky != null and sky.has_method("is_wet") and bool(sky.call("is_wet"))

## Sun out and nothing falling: for sunbathing and paddling.
static func sunny(tree: SceneTree) -> bool:
	var sky := weather(tree)
	if sky == null: return true
	var params: Variant = sky.get("params")
	if not params is Dictionary or (params as Dictionary).is_empty(): return true
	var p: Dictionary = params
	return float(p.get("sun", 1.0)) >= 0.7 and float(p.get("rain", 0.0)) < 0.05 and float(p.get("snow", 0.0)) < 0.05

## "earth", "unicorn" or "pegasus" (an alicorn counts as a unicorn: magic first).
static func race(actor: Node3D) -> String:
	var identity: Variant = actor.get("identity")
	if identity == null: return "earth"
	if (identity as Object).has_method("has_horn") and bool((identity as Object).call("has_horn")): return "unicorn"
	if (identity as Object).has_method("has_wings") and bool((identity as Object).call("has_wings")): return "pegasus"
	return "earth"

## The visible part of a throw or a bit of work with existing gestures only.
static func gesture(actor: Node3D, kind: String) -> void:
	if not actor.has_method("gesture"): return
	match kind:
		"unicorn": actor.call("gesture", "magic")
		"pegasus": actor.call("gesture", "wings:flutter")
		_: actor.call("gesture", "hoofraise")

## A snowball from `actor` toward `at` through W2-SEAS-F's snow play (SnowPlay.throw_snowball(from,
## velocity, thrower)): from her mouth (a hoof throw), above her horn (magic), or from a body length
## overhead (a pegasus, from the air), on a lob that lands at `at`. False when snow play is not
## active (no snow, or the feature missing): the gesture alone then.
static func throw_snowball(tree: SceneTree, actor: Node3D, at: Vector3, style: String) -> bool:
	var play := feature(tree, "SnowPlay", "snow_play")
	if play == null or not play.has_method("throw_snowball"): return false
	var ahead := -actor.global_basis.z.normalized()
	var lift := 1.45 if style == "magic" else (2.4 if style == "air" else 0.9)
	var from := actor.global_position + ahead * 0.45 + Vector3.UP * lift
	return play.call("throw_snowball", from, lob(from, at), actor) != null

## Launch velocity from `from` that lands on `at` (gravity 9.8), flight time by distance.
static func lob(from: Vector3, at: Vector3) -> Vector3:
	var flat := Vector3(at.x - from.x, 0.0, at.z - from.z)
	var t := clampf(flat.length() / 9.0, 0.35, 1.3)
	return flat / t + Vector3.UP * ((at.y - from.y) / t + 0.5 * 9.8 * t)

## A pony-built snowman at `at`, its face along the direction `facing` (SnowPlay.build_snowman(at, facing, by)).
static func build_snowman(tree: SceneTree, at: Vector3, facing: Vector3, builder: String) -> bool:
	var play := feature(tree, "SnowPlay", "snow_play")
	if play == null or not play.has_method("build_snowman"): return false
	return play.call("build_snowman", at, facing, builder) != null

## The nearest snowman Anon built (snowman.gd `by` == "player", group "snowmen") within `reach`, or INF.
static func player_snowman(tree: SceneTree, near: Vector3, reach: float) -> Vector3:
	var best := Vector3.INF
	if tree == null: return best
	for snowman: Node in tree.get_nodes_in_group("snowmen"):
		if not snowman is Node3D or str(snowman.get("by")) != "player": continue
		var at := (snowman as Node3D).global_position
		if at.distance_to(near) <= reach and (not best.is_finite() or at.distance_to(near) < best.distance_to(near)): best = at
	return best

## Rake the scattered leaves near `at` back into their piles (W2-SEAS-E LeafPiles.rake(point,
## radius, amount): amount 1 makes a patch a fresh pile again). True when any patch moved.
static func rake(tree: SceneTree, at: Vector3, radius: float, amount := 1.0) -> bool:
	var piles := feature(tree, "LeafPiles", "leaf_piles")
	if piles == null or not piles.has_method("rake"): return false
	return int(piles.call("rake", at, radius, amount)) > 0

## Centres of the ice slabs (IceSlabs.slab_points(), else its Node3D children), nearest first.
static func ice_points(tree: SceneTree, near: Vector3, reach: float) -> Array:
	var slabs := feature(tree, "IceSlabs", "ice_slabs")
	if slabs == null: return []
	var points: Array = []
	if slabs.has_method("slab_points"):
		var listed: Variant = slabs.call("slab_points")
		if listed is Array:
			for p: Variant in listed:
				if p is Vector3: points.append(p)
	else:
		for child: Node in slabs.get_children():
			if child is Node3D and (child as Node3D).is_inside_tree(): points.append((child as Node3D).global_position)
	points = points.filter(func(p: Vector3) -> bool: return Vector2(p.x - near.x, p.z - near.z).length() <= reach)
	points.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.distance_squared_to(near) < b.distance_squared_to(near))
	return points

## Other ponies doing the same seasonal fun within `radius` (meta "season_play" set by the steps).
static func playmates(tree: SceneTree, actor: Node3D, kind: String, radius: float) -> Array:
	var found: Array = []
	var population: Node = tree.get_first_node_in_group("pony_populations") if tree != null else null
	if population == null or not population.get("live") is Dictionary: return found
	for id: String in population.live:
		var other: Variant = (population.live[id] as Dictionary).get("actor")
		if not is_instance_valid(other) or other == actor or not (other as Node3D).is_inside_tree(): continue
		if not (other as Node3D).has_meta("season_play") or str((other as Node3D).get_meta("season_play")) != kind: continue
		if (other as Node3D).global_position.distance_to(actor.global_position) <= radius: found.append(other)
	return found
