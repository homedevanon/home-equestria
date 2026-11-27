extends "res://world/buildings/authored_home.gd"
const STAIRS := preload("res://world/buildings/stair_path_follower.gd")
const ROUTE_GRAPH := preload("res://world/buildings/indoor_route_graph.gd")
## Metre-scale, two-storey home adapter for the authored library.
const PLACE := "house:golden_oak_library"
## 2026-11-18 perf (town street, 8 s: _clear 29.5 ms / 3532 calls, _find_flat_waypoint 34 ms /
## 242 calls). _clear built a new capsule shape and query for every sweep; it now keeps one per
## (radius, height) and sets mask, exclusion, origin and motion afresh each call, so every sweep
## asks exactly the same question as before. Rollback: CLEAR_QUERY_REUSE = false.
static var CLEAR_QUERY_REUSE := true
## 2026-11-18 perf: a graph search re-swept its own direct leg (already known blocked) and a
## departure retry re-swept the same walk-point legs for every candidate. Sweep answers are kept in
## a memo that lives for one search, or for one HouseTravel._departure call that passes it in; nothing
## moves between those sweeps. Key: both ends (exact), actor and peers. Rollback: SWEEP_MEMO = false.
static var SWEEP_MEMO := true
## 2026-11-19 (board "Ponies stall leaving upstairs rooms", tools/interiors_nav/test_upstairs_exit.gd):
## the room's route capsule takes the pony profile's radius (0.45 m for a mare), wider than her
## physical controller (0.19 m). Where furniture stands closer than that (the boutique's shelf
## cabinet beside the stair foot, Sweetie Belle's bedroom door post) no leg from where she stands
## sweeps clear, the graph answers "stay where you are" and she froze until HouseTravel gave up
## after 15 s. When neither the full envelope nor the peer-free retry finds a route, the same search
## runs once more with NARROW_SCALE of the radius (never below her controller's own capsule), static
## world only; the native follower and her real collision still decide every step.
## Rollback: NARROW_FALLBACK = false. (static vars so fixtures can switch them off.)
static var NARROW_FALLBACK := true
const NARROW_SCALE := 2.0 / 3.0
## 2026-11-21 (navigation lane, card 404 in the bench world, tools/profile/nav_stall_probe.gd):
## the world's grown mares are body_scale 1.35 (Twilight Sparkle, Rarity: profile radius 0.61 m,
## controller 0.26 m), so even NARROW_FALLBACK's capsule (0.41 m) overlapped the bed or the bedroom
## door post where they stood after a rest, every leg from there was "not clear" before it began,
## and the room answered "stay" until the stuck-pony rescue moved them (Sweetie Belle, a filly, the
## same at her own scale). The lab's unscaled mare (0.45 m) never showed it. When the narrow search
## also finds nothing, it runs once more with the legs that leave her standing spot swept by her
## own controller's capsule (static world only); every other leg keeps the narrow capsule, and the
## native follower and her real collision still decide every step. Rollback: BODY_START_FALLBACK = false.
static var BODY_START_FALLBACK := true
var furniture: Node3D
var leaf: Node3D
var radius := 5.0
var loft_y := 3.4
var doorway_height := 6.75
var entry_point := Vector3(.16, 0, 4.5)
var stair_path: Array[Vector3] = []
var _route_cache: Array[Dictionary] = []
var _actor_routes: Array[Dictionary] = []

func _init() -> void:
	home_kind = "golden_oak"
	set_meta("reserved_for", "")

func configure(layout: Dictionary, interior: Node3D, door_leaf: Node3D) -> void:
	furniture = interior
	leaf = door_leaf
	radius = float(layout.get("radius", 5.0))
	loft_y = float(layout.get("loft_y", 3.4))
	_ceiling_y = float(layout.get("ceiling_y", 7.2))
	doorway = layout.get("door_position", Vector3(.16, 0, 9.04))
	door_width = float(layout.get("door_width", 3.56))
	doorway_height = float(layout.get("door_height", 6.75))
	approach = layout.get("door_approach", doorway + Vector3(0, 0, 1.4))
	entry_point = layout.get("door_inside", Vector3(.16, 0, 4.5))
	floors = [Rect2(-radius, -radius, radius * 2, radius * 2), Rect2(doorway.x - door_width * .5, 4.0, door_width, doorway.z - 4.0)]
	stair_path.assign(interior.get_meta("stair_path", []))
	bed = interior.ensure_bed("twilight_sparkle")
	for target: Node in interior.find_children("*", "Node3D", true, false):
		if target.has_meta("bed_size"):
			target.set_meta("house", self)

## Existing saves keep their chosen home. New-world Twilight gets her library.
func configure_owner(homes: Dictionary) -> bool:
	var adopt := not homes.has("twilight_sparkle") or str(homes.twilight_sparkle) == PLACE
	set_meta("reserved_for", "twilight_sparkle" if adopt else "")
	return adopt

func set_sleepers(ids: Array) -> void:
	_sleepers = ids.duplicate()

func door() -> Node: return leaf
func inside() -> Vector3: return to_global(entry_point)
func outside() -> Vector3: return to_global(approach)
func contains(at: Vector3, _lighting: bool = false) -> bool:
	var p := to_local(at)
	if p.y < -.15 or p.y > _ceiling_y: return false
	if Vector2(p.x, p.z).length_squared() <= radius * radius: return true
	return p.z >= 4.0 and p.z < doorway.z and absf(p.x - doorway.x) < door_width * .5 and p.y < doorway_height

func fits(profile: Resource) -> bool:
	return door_width > profile.radius * 2.0 + .08 and doorway_height > profile.clearance + .1

func ensure_bed(id: String = "") -> Node3D: return furniture.ensure_bed(id) if is_instance_valid(furniture) else null
func bed_shared(_id: String) -> bool: return false
func bed_side(id: String = "") -> Vector3: return furniture.bed_side(id)
func bed_rest(id: String = "") -> Transform3D: return furniture.bed_rest(id)
func on_mattress(point: Vector3, id: String = "") -> bool: return furniture.on_mattress(point, id)

func local_waypoint(from: Vector3, to: Vector3) -> Vector3:
	return _local_waypoint(from,to,null)

func local_waypoint_for(actor:CharacterBody3D, from:Vector3, to:Vector3) -> Vector3:
	return _local_waypoint(from,to,actor)

func _local_waypoint(from:Vector3,to:Vector3,actor:CharacterBody3D) -> Vector3:
	return STAIRS.waypoint(self, from, to, stair_path, loft_y, 0.0, .04, _flat_waypoint.bind(actor))

## `narrow`: NARROW_FALLBACK's slimmer capsule (_route_radius).
func _clear(a: Vector3, b: Vector3, actor:CharacterBody3D=null, peers:=true, narrow:=false) -> bool:
	# Floor changes must use the staircase, never a direct diagonal through the loft.
	if absf(a.y - b.y) > .3: return false
	if CLEAR_QUERY_REUSE:
		var size := Vector2(_route_radius(actor, narrow), float(actor.profile.clearance) if actor != null else 1.45)
		var reused := _clear_queries.get(size) as PhysicsShapeQueryParameters3D
		if reused == null:
			var made := CapsuleShape3D.new()
			made.radius = size.x
			made.height = size.y
			reused = PhysicsShapeQueryParameters3D.new()
			reused.shape = made
			reused.margin = .005
			_clear_queries[size] = reused
		reused.collision_mask = 3 if actor != null and peers else 1
		if actor != null: reused.exclude = [actor.get_rid()]
		else: reused.exclude = []
		reused.transform.origin = a + Vector3.UP * ((reused.shape as CapsuleShape3D).height * .5 + .055)
		reused.motion = b - a
		return ROUTE_GRAPH.sweep(get_world_3d().direct_space_state, reused)
	var shape := CapsuleShape3D.new()
	shape.radius = _route_radius(actor, narrow)
	shape.height = float(actor.profile.clearance) if actor != null else 1.45
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 3 if actor != null and peers else 1
	if actor != null: query.exclude = [actor.get_rid()]
	query.margin = .005
	query.transform.origin = a + Vector3.UP * (shape.height * .5 + .055)
	query.motion = b - a
	var space := get_world_3d().direct_space_state
	return ROUTE_GRAPH.sweep(space, query)

## The route capsule's radius: her profile's, or NARROW_SCALE of it, not below her controller.
static func _route_radius(actor: CharacterBody3D, narrow: bool) -> float:
	var full: float = float(actor.profile.radius) if actor != null else .34
	if not narrow or actor == null: return full
	var body := .0
	var holder := actor.get("_collision") as CollisionShape3D
	if holder != null and holder.shape is CapsuleShape3D: body = (holder.shape as CapsuleShape3D).radius
	return minf(full, maxf(full * NARROW_SCALE, body))

## BODY_START_FALLBACK: a static sweep of her own controller (its shape where it stands, moved to `a`).
## A synthetic capsule of the controller's radius at the route clearance still touched the boutique's
## shelf top and stair railings at the stair foot where her real controller touches nothing.
func _clear_body(a: Vector3, b: Vector3, actor: CharacterBody3D) -> bool:
	if absf(a.y - b.y) > .3 or actor == null: return false
	var holder := actor.get("_collision") as CollisionShape3D
	if holder == null or holder.shape == null: return false
	var query := _body_query
	if query == null:
		query = PhysicsShapeQueryParameters3D.new()
		query.margin = .001
		query.collision_mask = 1
		_body_query = query
	query.shape = holder.shape
	var at := holder.global_transform
	at.origin += a - actor.global_position + Vector3.UP * .03
	query.transform = at
	query.exclude = [actor.get_rid()]
	query.motion = Vector3(b.x - a.x, 0.0, b.z - a.z)
	return ROUTE_GRAPH.sweep(get_world_3d().direct_space_state, query)
var _body_query: PhysicsShapeQueryParameters3D

## BODY_START_FALLBACK: the narrow static search, its legs from `from` swept by her controller.
func _find_flat_waypoint_body_start(from: Vector3, to: Vector3, actor: CharacterBody3D, sweeps: Variant = null) -> Vector3:
	var known: Dictionary = sweeps if sweeps is Dictionary else {}
	var clear := func(a: Vector3, b: Vector3) -> bool:
		if a == from: return _clear_body(a, b, actor)
		return _clear_known(a, b, actor, false, known, true)
	if clear.call(from, to): return to
	var upper := to_local(from).y >= loft_y - .25
	var points: Array[Vector3] = [from, to]
	for p: Vector3 in furniture.get_meta("loft_walk_points" if upper else "ground_walk_points", []): points.append(to_global(p))
	return ROUTE_GRAPH.next(points, clear)

## CLEAR_QUERY_REUSE: one capsule query per body size, (radius, height) -> query.
var _clear_queries: Dictionary = {}

## _clear through a SWEEP_MEMO memo: [a, b, actor id, peers, narrow] -> the sweep's answer.
func _clear_known(a: Vector3, b: Vector3, actor: CharacterBody3D, peers: bool, known: Dictionary, narrow := false) -> bool:
	var key := [a, b, actor.get_instance_id() if actor != null else 0, peers, narrow]
	var hit: Variant = known.get(key)
	if hit != null: return bool(hit)
	var clear := _clear(a, b, actor, peers, narrow)
	known[key] = clear
	return clear

func _flat_waypoint(from: Vector3, to: Vector3, actor:CharacterBody3D=null) -> Vector3:
	if actor != null: return _actor_waypoint(actor,from,to)
	# Reuse routes while traversing a clear leg rather than rebuilding per physics tick.
	var now := Time.get_ticks_msec()
	for item in _route_cache:
		if now - int(item.time) < 2000 and to.distance_squared_to(item.goal) < .01 and from.distance_squared_to(item.start) < .36 and from.distance_squared_to(item.next) > .04:
			return item.next
	var next := _find_flat_waypoint(from, to)
	# Replace the completed leg. Keeping older entries can reactivate one after
	# walking 20 cm beyond it, repeatedly reversing the moving character.
	_route_cache.assign([{"time": now, "goal": to, "start": from, "next": next}])
	return next

## `sweeps`: a SWEEP_MEMO memo shared by several searches of one caller (HouseTravel._departure).
## `narrow`: search with NARROW_FALLBACK's slimmer capsule.
func _find_flat_waypoint(from: Vector3, to: Vector3, actor:CharacterBody3D=null, peers:=true, sweeps: Variant = null, narrow := false) -> Vector3:
	if not SWEEP_MEMO:
		if _clear(from, to, actor, peers, narrow): return to
	else:
		if not (sweeps is Dictionary): sweeps = {}
		if _clear_known(from, to, actor, peers, sweeps, narrow): return to
	var upper := to_local(from).y >= loft_y - .25
	var key := "loft_walk_points" if upper else "ground_walk_points"
	var points: Array[Vector3] = [from, to]
	for p: Vector3 in furniture.get_meta(key, []): points.append(to_global(p))
	if SWEEP_MEMO: return ROUTE_GRAPH.next(points, _clear_known.bind(actor, peers, sweeps, narrow))
	return ROUTE_GRAPH.next(points, _clear.bind(actor, peers, narrow))

## A recovery spot's first room waypoint toward `to` (HouseTravel._departure), stair-aware like
## local_waypoint_for but outside the per-actor leg cache: the full envelope first, then
## NARROW_FALLBACK's. Before 2026-11-19 the departure searched the flat graph of the spot's own
## floor only, so a pony upstairs with a ground-floor goal never found one.
func departure_waypoint(actor: CharacterBody3D, from: Vector3, to: Vector3, sweeps: Variant = null) -> Vector3:
	var flat := func(a: Vector3, b: Vector3) -> Vector3:
		var next: Vector3 = _find_flat_waypoint(a, b, actor, false, sweeps)
		if NARROW_FALLBACK and next.distance_squared_to(a) < .0001: next = _find_flat_waypoint(a, b, actor, false, sweeps, true)
		if NARROW_FALLBACK and BODY_START_FALLBACK and next.distance_squared_to(a) < .0001: next = _find_flat_waypoint_body_start(a, b, actor, sweeps)
		return next
	return STAIRS.waypoint(self, from, to, stair_path, loft_y, 0.0, .04, flat)

## Per-actor, short-lived leg cache. Live sweeps prevent cached paths crossing a pony
## who just entered a leg; the source point graph still owns all route alternatives.
func _actor_waypoint(actor:CharacterBody3D,from:Vector3,to:Vector3) -> Vector3:
	var now:=Time.get_ticks_msec()
	var id:=actor.get_instance_id()
	for item:Dictionary in _actor_routes:
		if int(item.actor)!=id or now-int(item.time)>=500 or to.distance_squared_to(item.goal)>=.01:continue
		if from.distance_squared_to(item.start)<.0001 and (item.next as Vector3).distance_squared_to(item.start)<.0001:return from
		if from.distance_squared_to(item.start)<.36 and from.distance_squared_to(item.next)>.04:
			var still:bool=_clear_body(from,item.next,actor) if bool(item.get("body",false)) else _clear(from,item.next,actor,not bool(item.get("peer_wait",false)),bool(item.get("narrow",false)))
			if still:return item.next
	var next:=_find_flat_waypoint(from,to,actor)
	var peer_wait:=next.distance_squared_to(from)<.0001
	# A temporary peer can occupy the only aisle. Keep the physical static route;
	# native neighbour avoidance stops short and HouseTravel requests a courtesy move.
	if peer_wait:next=_find_flat_waypoint(from,to,actor,false)
	# Furniture closer than the full envelope all round: the slimmer capsule (NARROW_FALLBACK).
	var narrow:=NARROW_FALLBACK and peer_wait and next.distance_squared_to(from)<.0001
	if narrow:next=_find_flat_waypoint(from,to,actor,false,null,true)
	# Even the narrow capsule overlaps furniture where she stands: her controller's (BODY_START_FALLBACK).
	var body:=narrow and BODY_START_FALLBACK and next.distance_squared_to(from)<.0001
	if body:next=_find_flat_waypoint_body_start(from,to,actor)
	for i in range(_actor_routes.size()-1,-1,-1):
		var old:Dictionary=_actor_routes[i]
		if now-int(old.time)>=500 or (int(old.actor)==id and from.distance_squared_to(old.start)<.01):_actor_routes.remove_at(i)
	_actor_routes.append({"actor":id,"time":now,"goal":to,"start":from,"next":next,"peer_wait":peer_wait,"narrow":narrow,"body":body})
	if _actor_routes.size()>24:_actor_routes.pop_front()
	return next
