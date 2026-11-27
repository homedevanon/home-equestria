extends "res://world/buildings/authored_home.gd"
const ROUTE_GRAPH := preload("res://world/buildings/indoor_route_graph.gd")
## Authored ground floor in the measured cottage, using the shared bed/door APIs.
## Home coordinates use the existing 10 cm convention; no generic shell repairs.
const PLACE := "house:fluttershy_cottage"
## 2026-11-18 perf (town street, 8 s: local_waypoint 15.6 ms / 86 calls, _segment_clear 14.7 ms /
## 327 calls). One _route() call swept some legs twice: the direct leg (known blocked) again as the
## first graph edge, and every leg it had just swept live again while confirming the chosen route.
## Answers swept live inside the same _route() call are reused within that call only (nothing moves
## between them). Legs that came from the older _links cache are still re-swept live, as before.
## Key: both ends (exact). Rollback: ROUTE_LIVE_MEMO = false.
const ROUTE_LIVE_MEMO := true
var boundary := PackedVector2Array()
var room_center := Vector3.ZERO
var waypoints: Array[Vector3] = []
# Only static anchor-to-anchor visibility is cached. Each returned route is checked
# against live collision, including furniture changes, before it can be followed.
var _links: Dictionary = {}
var _link_transform := Transform3D.IDENTITY
var _walk_query: PhysicsShapeQueryParameters3D

func _init() -> void:
	home_kind = "fluttershy"
	# Reserve the building from random assignment WITHOUT displacing a saved owner.
	# Main calls configure_owner only after loading that world's homes dictionary.
	set_meta("reserved_for", "")

## Read-only policy decision: never modifies homes or writes persistent state.
## Existing-world Fluttershy keeps her address; missing/new-world address may adopt.
func configure_owner(homes: Dictionary) -> bool:
	var adopt := not homes.has("fluttershy") or str(homes.fluttershy) == PLACE
	set_meta("reserved_for", "fluttershy" if adopt else "")
	return adopt

func center() -> Vector3: return to_global(room_center)
## The first point past the exterior door (home frame), before the fitted foyer bends
## toward the main room. The remaining turn uses the measured indoor route anchors.
var inside_at := Vector3.INF
func inside() -> Vector3: return to_global(inside_at if inside_at.is_finite() else Vector3(0, floor_y, -.20))

func contains(at: Vector3, lighting := false) -> bool:
	var p := to_local(at)
	if p.y < floor_y - .025 or p.y > (_ceiling_y if lighting else floor_y + .25): return false
	return Geometry2D.is_point_in_polygon(Vector2(p.x, p.z), boundary)

func _segment_clear(a: Vector3, b: Vector3) -> bool:
	if not contains(a) or not contains(b): return false
	var local_a := to_local(a)
	var local_b := to_local(b)
	var start := Vector2(local_a.x, local_a.z)
	var end := Vector2(local_b.x, local_b.z)
	if not start.is_equal_approx(end):
		# Native polygon clipping checks the entire segment, including narrow concave
		# gaps that the previous quarter-metre point sampling could miss.
		var clipped := Geometry2D.intersect_polyline_with_polygon(PackedVector2Array([start, end]), boundary)
		if clipped.size() != 1: return false
		var line: PackedVector2Array = clipped[0]
		if line.size() < 2: return false
		if not ((line[0].is_equal_approx(start) and line[-1].is_equal_approx(end)) or (line[0].is_equal_approx(end) and line[-1].is_equal_approx(start))): return false
	if _walk_query == null:
		var shape := CapsuleShape3D.new()
		shape.radius = .34
		shape.height = 1.45
		_walk_query = PhysicsShapeQueryParameters3D.new()
		_walk_query.shape = shape
		_walk_query.collision_mask = 1
		_walk_query.margin = .005
	var query := _walk_query
	query.transform.origin = a + Vector3.UP * .76
	query.motion = b - a
	var space := get_world_3d().direct_space_state
	return ROUTE_GRAPH.sweep(space, query)

## The room has its source outline, not the standard two-rectangle/L-house layout.
## A small visibility graph keeps indoor walking around the real bed and kitchen.
func local_waypoint(from: Vector3, to: Vector3) -> Vector3:
	if global_transform != _link_transform or _links.size() > 2048:
		_links.clear(); _link_transform = global_transform
	return _route(from, to, true)

func _route(from: Vector3, to: Vector3, retry: bool) -> Vector3:
	if _segment_clear(from, to): return to
	# ROUTE_LIVE_MEMO: [a, b] -> _segment_clear(a, b) swept in this call.
	var live := {}
	if ROUTE_LIVE_MEMO: live[[from, to]] = false
	var points: Array[Vector3] = [from, to, center(), inside()]
	for point in waypoints: points.append(to_global(point))
	var distance: Array[float] = []
	var previous: Array[int] = []
	var done: Array[bool] = []
	for i in points.size(): distance.append(INF); previous.append(-1); done.append(false)
	distance[0] = 0.0
	for iteration in points.size():
		var next := -1
		for i in points.size():
			if not done[i] and (next < 0 or distance[i] < distance[next]): next = i
		if next < 0 or not is_finite(distance[next]):
			if retry and not _links.is_empty():
				_links.clear(); return _route(from, to, false)
			break
		if next == 1:
			var step := 1
			var first := 1
			while previous[step] >= 0:
				var before: int = previous[step]
				var leg := [points[before], points[step]]
				var leg_clear: bool = bool(live[leg]) if live.has(leg) else _segment_clear(points[before], points[step])
				if not leg_clear:
					_links[[points[before], points[step]]] = false
					_links[[points[step], points[before]]] = false
					return _route(from, to, false) if retry else from
				first = step; step = before
			return points[first]
		done[next] = true
		for i in points.size():
			var cost := distance[next] + points[next].distance_to(points[i])
			if done[i] or cost >= distance[i]: continue
			var clear: bool
			if next >= 2 and i >= 2:
				var key := [points[next], points[i]]
				if not _links.has(key):
					_links[key] = _segment_clear(points[next], points[i])
					if ROUTE_LIVE_MEMO: live[key] = _links[key]
				clear = bool(_links[key])
			else:
				var edge := [points[next], points[i]]
				if live.has(edge): clear = bool(live[edge])
				else:
					clear = _segment_clear(points[next], points[i])
					if ROUTE_LIVE_MEMO: live[edge] = clear
			if clear: distance[i] = cost; previous[i] = next
	return from # Real obstruction: wait rather than walking through a wall or furniture.
