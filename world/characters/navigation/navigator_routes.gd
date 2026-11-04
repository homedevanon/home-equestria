extends RefCounted
## Route results and long trips of pony_navigator.gd (split 2026-10-13): joining a route that
## arrived while she kept moving, the legs of a long trip (bridges over the town river, pegasus
## hops) and where a flight lands. State stays on the navigator; calls back go through `nav.`.

const HOUSE := preload("res://world/buildings/house_interior.gd")
const NATIVE_ADAPTER := preload("res://world/characters/navigation/navigator_native_adapter.gd")


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


static func path_ready(nav: Node, result: Dictionary, request_id: int, completed_revision: int) -> void:
	if request_id != nav._request or not nav._has_target: return
	nav._request = -1
	var service: Variant = nav._service
	if result.get("stale", false) or completed_revision != service.revision:
		nav._needs_path = true
		return
	nav._needs_path = false
	var candidate: PackedVector3Array = result.get("path", PackedVector3Array())
	# A one-point route goes nowhere: the goal region was shut (discs, ponies) and the nearest
	# reachable cell was her own. The follower needs two points, so before 2026-10-31 she stood on
	# "Sampling terrain / planning route" with nothing left to replan it, 20 s to two minutes in
	# front of the Hayburger door (tools/hayburger/test_doorway_traffic.gd).
	# A moving goal keeps refreshing its route by itself and is left as before.
	var nowhere: bool = candidate.size() == 1 and not nav._moving_goal
	if (candidate.is_empty() or nowhere) and nav._planned_with_peers:
		# Discs round ponies in the way shut every route (a lane they fill): search again without
		# them and let the follower's neighbour steering and peer passage sort it out, as before.
		nav._peer_discs = PackedFloat32Array()
		nav._planned_with_peers = false
		nav._needs_path = true
		return
	if candidate.is_empty() or nowhere:
		var journey: Vector3 = nav._journey_goal
		if journey.is_finite() and nav._journey_attempt < 6:
			nav._journey_attempt += 1
			nav._next_leg()
			return
	if candidate.is_empty():
		nav._fail(result.get("reason", "No safe route")); return
	if nowhere:
		# She already stands on the nearest reachable spot: an arrival there, told apart as an
		# alternative when the goal itself is farther than her arrival distance (never silent).
		var goal: Vector3 = nav._live_goal if nav._live_goal.is_finite() else nav.target
		var short: bool = _flat(nav.pony.global_position, goal) > float(nav.arrival_distance)
		nav.path = PackedVector3Array()
		if nav._native_active: nav._native_clear()
		NATIVE_ADAPTER.on_event(nav, {"intent": nav._native_intent, "kind": 1, "alternative": short})
		return
	nav._unknown_pursuit = false
	nav._direct_snapshot = {}
	nav._direct_serial = -1
	nav.path = candidate
	nav.target = candidate[-1]
	nav._waypoint = 0
	nav._path_serial += 1
	if nav.trace != null: nav.trace.route_generation += 1
	# The pony moves while the worker plans. Join the nearest safe segment of
	# the returned route instead of walking back to its obsolete start point.
	var pony: CharacterBody3D = nav.pony
	var position := pony.global_position
	var nearest_distance := INF
	var join_index := 0
	for i in range(1, candidate.size()):
		var closest := Geometry3D.get_closest_point_to_segment(position, candidate[i - 1], candidate[i])
		var distance := _flat(position, closest)
		if distance < nearest_distance and absf(closest.y - position.y) < .65:
			nearest_distance = distance; join_index = i
	# A direct pending leg can run beside the eventual sampled route by more than
	# 80 cm. Use the same short 2.4 m reach as pending legs, with the existing
	# body/terrain certification, instead of sending her back to the old start.
	if join_index > 0 and nearest_distance < 2.4 and service.steering_segment_clear(position, candidate[join_index], pony.profile, true):
		nav._waypoint = join_index
	nav._reset_lookahead()
	nav.agent.target_position = nav.target
	if nav.state != nav.State.MOVING: nav._safe_velocity = Vector3.ZERO
	nav.route_changed.emit()


## The next leg of a long trip: a point up to JOURNEY_LEG along the way, turned aside
## on retries when the straight line meets water, cliffs or buildings.
const ENTRY_REACH := 3.0

static func next_leg(nav: Node) -> void:
	var pony: CharacterBody3D = nav.pony
	var from := pony.global_position
	var leg_length: float = nav.JOURNEY_LEG
	var via: Array = nav._journey_via
	# Bridge approaches in order: the far one is passed once she is within 12 m of it, the near
	# (entry) one only within ENTRY_REACH. At 12 m she cut diagonally onto the East bridge's steep
	# deck end and turned on it, crawling at 0.2 m/s until the route gave up (player board #21,
	# 2026-10-26); from the approach point, 5 m out on the span's line, she walks on straight.
	while not via.is_empty() and _flat(from, via[0]) < (ENTRY_REACH if via.size() > 1 else 12.0):
		via.pop_front()
	if not via.is_empty():
		var bridge: Vector3 = via[0]
		# Already heading there: do not re-plan the same leg every frame.
		var path: PackedVector3Array = nav.path
		if _flat(nav.target, bridge) < .5 and (not path.is_empty() or nav._request >= 0 or nav._needs_path): return
		if _flat(from, bridge) <= leg_length * 1.2:
			nav.target = bridge; nav._live_goal = bridge; nav._needs_path = true; nav._request = -1
			nav.reason = "Crossing the river by the bridge"
			return
	var journey: Vector3 = nav._journey_goal
	var aim: Vector3 = via[0] if not via.is_empty() else journey
	var toward := aim - from; toward.y = 0.0
	if toward.length() <= leg_length * 1.2:
		# Already on the final stretch: do not re-plan it every logic tick. A goal inside a house
		# ends every grid route at its door (house travel takes the rest), so the route always
		# "ends short" and this re-requested it five times a second (2026-10-24 route probe).
		var current: PackedVector3Array = nav.path
		if _flat(nav.target, journey) < .5 and (not current.is_empty() or nav._request >= 0 or nav._needs_path): return
		nav.target = journey; nav._live_goal = journey; nav._needs_path = true
		nav.reason = "Final stretch of a long trip"
		return
	var turns := [0.0, .45, -.45, .9, -.9, 1.3, -1.3]
	var attempt: int = nav._journey_attempt
	var length := leg_length * (1.0 if attempt < 3 else .6)
	var direction := toward.normalized().rotated(Vector3.UP, turns[attempt % turns.size()])
	var point := from + direction * length
	if is_instance_valid(WorldTerrain.instance):
		var h: float = WorldTerrain.instance.height_at(point)
		if is_finite(h): point.y = h
	# Pegasi hop long legs through the air when the corridor and landing allow it.
	if nav._flight_shortcuts and pony.has_method("request_flight") and pony.identity != null and pony.identity.has_wings() and nav._journey_flights < 40:
		var landing := journey if _flat(from, journey) < 400.0 else from + toward.normalized() * minf(toward.length(), 380.0)
		if is_instance_valid(WorldTerrain.instance):
			var lh: float = WorldTerrain.instance.height_at(landing)
			if is_finite(lh): landing.y = maxf(landing.y, lh) if landing == journey else lh
		if pony.request_flight(landing, 0.0, true):
			nav._journey_flights += 1
			nav._cancel_queries(); nav.path = PackedVector3Array(); nav._needs_path = true
			nav.target = landing; nav._live_goal = landing
			nav.state = nav.State.MOVING; nav.reason = "Flying toward a far destination"
			return
	nav.target = point; nav._live_goal = point; nav._needs_path = true; nav._request = -1
	nav.reason = "Walking a long trip in legs"


static func flight_landing(nav: Node, destination: Vector3) -> Vector3:
	var pony: CharacterBody3D = nav.pony
	var house: Node3D = HOUSE.at(pony.get_tree(), destination)
	return house.outside() if house != null else destination
