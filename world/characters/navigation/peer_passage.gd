extends RefCounted
## Pony-to-pony passage outside houses (dev 2026-10-15: "fix ponies blocking eachother through
## pathfinding and allowing them to dynamically reroute"). Other ponies stay dynamic obstacles of
## the native follower (avoidance and neighbour arcs); routes are never invalidated by them. This
## adds what the follower cannot do alone, both halves owned by each navigator:
##   requester: a walking pony held by a neighbour (no progress, neighbour/yield/no-arc wait)
##     asks the ponies standing in her way ahead to step aside. A loiterer (idle, standing or
##     resting, or a lower-priority walker) answers with a short courtesy step off her corridor.
##     When nobody can make room she reroutes: the blockers become search discs for one replan.
##   yielder: walks the courtesy step on the ordinary native motor (collision stays live), then
##     an idler stays there; a walker waits until the other has passed and resumes her own trip.
## Inside house interiors indoor_peer_yield.gd and house_travel.gd keep this job.
## Bounded work: a nearby-navigator query from the batch driver at most every 0.75 s while held,
## and at most 64 floor/sweep checks per accepted request. Never touches command ownership.
const HOUSE := preload("res://world/buildings/house_interior.gd")
const TRAVEL := preload("res://world/characters/navigation/house_travel.gd")
## Held this long without progress before asking (seconds), and before rerouting instead.
const ASK_AFTER := 0.5
## Two walkers usually sort out passing themselves (avoidance); giving way waits this long.
const WALKER_AFTER := 5.0
## Head on in a lane too narrow for two bodies side by side: one gives way after this long.
const NARROW_AFTER := 1.0
const REROUTE_AFTER := 2.5
const ASK_INTERVAL := 0.75
const REROUTE_INTERVAL := 4.0
## Held means no route progress, not only standing still (2026-10-31): a stepping turn pivots on
## her hooves at about 0.15 m/s, so a walker swinging left and right in front of a pony read as
## moving and never asked or rerouted. Less than STALL_GAIN metres of corridor progress in
## STALL_SECONDS is held too.
const STALL_GAIN := 0.2
const STALL_SECONDS := 1.5
## A loiterer with free floor beside her is walked round by the native follower (a committed pass);
## she is asked to step aside only when neither side is open, or after this long held anyway.
const SIDE_PATIENCE := 3.0
## A pony who refused to make room is not asked again for this long.
const REFUSED_SECONDS := 5.0
## Reroute discs: the follower's hard separation (body radii + 0.1, + 0.1 without an avoidance
## answer; navigation_steering.cpp hard_separation), a walk-grid cell (search discs test cell
## centres) and 0.1 m to spare. navigation_batch.cpp PEER_DISC_PAD is the same value.
const PEER_DISC_PAD := 0.55
## How far ahead along her corridor a standing pony counts as in the way (metres).
const LOOK_AHEAD := 3.5
## The yielder keeps clear of this much of the requester's remaining corridor.
const CLEAR_AHEAD := 6.0
const MARGIN := 0.2
const STEP_RADII: Array[float] = [0.8, 1.2, 1.7, 2.3]
const MOVE_SECONDS := 5.0
const WAIT_SECONDS := 6.0
const STAND_SECONDS := 4.0
## Idle owners whose ponies may shuffle aside. Activities that need the exact spot (restaurant
## counter, bed, story marks, seats) are not in this list and never move for anypony.
const YIELDING_OWNERS: Array[String] = ["life:", "social:", "day:", "player:"]

## Requester state.
var held := 0.0
var _ask_at := 0.0
var _reroute_at := 0.0
var _clock := 0.0
## Route progress anchor for STALL_GAIN / STALL_SECONDS.
var _anchor_route := -1
var _anchor_progress := 0.0
var _anchor_time := 0.0
## Instance id -> clock until which that pony is not asked again (she refused).
var _refused := {}
## Yielder state: "" (none), "standing", "moving", "waiting".
var phase := ""
var goal := Vector3.INF
## Optional first point when the step must leave a doorway along it before turning aside.
var via := Vector3.INF
var owner := ""
var intent := -1
var resume := false
var until := 0.0
var requester_ref: WeakRef
## Labs print each courtesy step and its outcome.
static var debug := false
## Rollback and comparison switch: user argument --peer-passage=off.
static var enabled := not ("--peer-passage=off" in preload("res://world/dev_tools.gd").user_args())
## Counters for labs and traces.
var asked := 0
var yields := 0
var reroutes := 0


func active() -> bool:
	return not phase.is_empty()


func clear() -> void:
	phase = ""
	goal = Vector3.INF
	via = Vector3.INF
	requester_ref = null
	resume = false


## How much right of way a navigator has: a customer the player waits for, then explicit
## player/story commands, ordinary errands, wandering; an idle pony has none.
static func priority(nav: Node) -> int:
	if nav.has_meta(&"player_waiting_route"): return 4
	if not nav._has_target: return 0
	if nav._wandering: return 1
	if nav.autonomous_command(): return 2
	return 3


## Shared state checks: ownership, holding, flight, sleep, conversation, groups.
static func _free(nav: Node) -> bool:
	var pony: CharacterBody3D = nav.pony
	return nav.native_follow and not is_instance_valid(nav._follow_target) \
		and not is_instance_valid(nav._conversation_target) and not nav.face_point.is_finite() \
		and not nav._contact_approach.is_finite() and nav.reserved_by.is_empty() \
		and not pony.motion_paused and not pony._held and pony._interaction.is_empty() \
		and pony.get("sleeping") != true and pony.grounded() \
		and (pony.get("hoof_hold") == null or not pony.hoof_hold.active()) \
		and (pony.get("thrown") == null or not pony.thrown.active()) \
		and (pony.get("flight") == null or not pony.flight.active()) \
		and not pony.get_meta(&"seated", false) and not nav.indoor_yield.goal.is_finite() \
		and not nav.house_travel.active() and HOUSE.at(nav.get_tree(), pony.global_position) == null


static func _owner_yields(nav: Node) -> bool:
	var who: String = nav.command_owner
	if who.is_empty(): return true
	for prefix: String in YIELDING_OWNERS:
		if who.begins_with(prefix): return true
	return false


static func _standing(pony: Node) -> bool:
	if not pony.has_method(&"posture_status"): return true
	var status: Dictionary = pony.posture_status()
	return str(status.get("kind", "stand")) == "stand" and str(status.get("requested", "stand")) == "stand"


## Her remaining corridor from where she stands, up to `length` metres.
static func corridor(nav: Node, length: float) -> PackedVector3Array:
	var pony: Node3D = nav.pony
	var points := PackedVector3Array([pony.global_position])
	var path: PackedVector3Array = nav.path
	var left := length
	for i in range(maxi(1, int(nav._waypoint)), path.size()):
		var step := Vector2(path[i].x - points[-1].x, path[i].z - points[-1].z).length()
		if step >= left:
			points.append(points[-1].lerp(path[i], left / maxf(step, 1e-4)))
			return points
		points.append(path[i])
		left -= step
	return points


static func _distance_to(point: Vector3, line: PackedVector3Array) -> float:
	if line.size() == 1: return Vector2(point.x - line[0].x, point.z - line[0].z).length()
	var best := INF
	for i in range(1, line.size()):
		var near := Geometry3D.get_closest_point_to_segment(point, line[i - 1], line[i])
		if absf(near.y - point.y) > 1.2: continue
		best = minf(best, Vector2(point.x - near.x, point.z - near.z).length())
	return best


## --- Requester half: called after the native tick of a walking pony ---------------------------

func watch(nav: Node, delta: float) -> void:
	if not enabled: return
	_clock += delta
	var pony: CharacterBody3D = nav.pony
	# Route progress: re-anchored on every STALL_GAIN gained or on a new corridor.
	var route: int = int(nav._native_route)
	var progress: float = float(nav._native_progress)
	if not nav._native_active or route != _anchor_route or progress >= _anchor_progress + STALL_GAIN or progress < _anchor_progress - 1.0:
		_anchor_route = route
		_anchor_progress = progress
		_anchor_time = _clock
	var reason := int(nav._native_reason)
	var stalled := _clock - _anchor_time >= STALL_SECONDS and reason not in [4, 7, 15]
	# Held: (almost) no motion on an active corridor, not turning, arriving or waiting for a route;
	# or no route progress at all (creeping, turning back and forth in front of a pony).
	var waiting: bool = nav._native_active and nav._flat_distance(pony.global_position, nav.target) > 1.0 \
		and ((float(pony.actual_speed) < 0.12 and reason not in [1, 4, 7, 15]) or stalled)
	if not nav._has_target or nav.path.size() < 2 or not waiting:
		held = maxf(0.0, held - delta * 2.0)
		return
	held += delta
	if held < ASK_AFTER or _clock < _ask_at: return
	_ask_at = _clock + ASK_INTERVAL
	var blockers := _blockers(nav)
	if blockers.is_empty(): return
	if _refused.size() > 16:
		for key: int in _refused.keys():
			if float(_refused[key]) < _clock: _refused.erase(key)
	var making_room := false
	var mine := priority(nav)
	var narrow := -1
	for other: Node in blockers:
		if other.peer_passage.active() and other.peer_passage.requester_ref != null and other.peer_passage.requester_ref.get_ref() == nav:
			making_room = true
			continue
		if float(_refused.get(other.get_instance_id(), -INF)) > _clock: continue
		var theirs := priority(other)
		if other._has_target and held < WALKER_AFTER:
			# Walkers sort out passing themselves, unless the lane has no room for two side by side.
			if held < NARROW_AFTER: continue
			if narrow < 0: narrow = 1 if _narrow(nav) else 0
			if narrow == 0: continue
		if theirs < mine or (theirs == mine and other.get_instance_id() > nav.get_instance_id()):
			# Free floor beside a standing pony: the native follower walks round her; ask only when
			# neither side is open (or after a long hold anyway).
			if not other._has_target and held < SIDE_PATIENCE and _side_open(nav, other): continue
			asked += 1
			if other.peer_passage.make_room(other, nav):
				making_room = true
			else:
				_refused[other.get_instance_id()] = _clock + REFUSED_SECONDS
		elif other._has_target and not active():
			# Head on with a walker who has right of way: this one gives way instead.
			if make_room(nav, other): return
	if making_room:
		nav.reason = "Waiting for a pony to step aside"
		return
	if held < REROUTE_AFTER or _clock < _reroute_at: return
	# Walkers move on: plan around them only after they have stood in the way as long as giving way waits.
	var standing: Array[Node] = []
	for other: Node in blockers:
		if not other._has_target or held >= WALKER_AFTER: standing.append(other)
	if not standing.is_empty(): _reroute(nav, standing)


## Free floor beside `blocker`, across her way, that she can walk to: the native pass gets round.
func _side_open(nav: Node, blocker: Node) -> bool:
	var service: Node = nav._service
	if not is_instance_valid(service) or not service.ready_for_paths: return false
	var pony: CharacterBody3D = nav.pony
	var at := pony.global_position
	var line := corridor(nav, LOOK_AHEAD)
	var travel: Vector3 = line[-1] - line[0]; travel.y = 0.0
	travel = travel.normalized() if travel.length() > 0.05 else -pony.global_basis.z
	var side := travel.cross(Vector3.UP).normalized()
	var there: Vector3 = blocker.pony.global_position
	var room: float = float(pony.profile.radius) + float(blocker.pony.profile.radius) + 0.25
	for sign: float in [1.0, -1.0]:
		var spot := _floor(service, pony, there + side * sign * room, at.y)
		if spot.is_finite() and service.is_walkable(spot, pony.profile) and service.steering_segment_clear(at, spot, pony.profile):
			return true
	return false


## No room for two bodies side by side where she stands (one side of her within a body width is
## not walkable floor).
func _narrow(nav: Node) -> bool:
	var service: Node = nav._service
	if not is_instance_valid(service) or not service.ready_for_paths: return false
	var pony: CharacterBody3D = nav.pony
	var at := pony.global_position
	var line := corridor(nav, LOOK_AHEAD)
	var travel: Vector3 = line[-1] - line[0]; travel.y = 0.0
	travel = travel.normalized() if travel.length() > 0.05 else -pony.global_basis.z
	var side := travel.cross(Vector3.UP).normalized() * (float(pony.profile.radius) * 2.0 + 0.15)
	return not service.is_walkable(at + side, pony.profile) or not service.is_walkable(at - side, pony.profile)


## Navigators standing in the next few metres of her corridor (bounded batch-driver query).
func _blockers(nav: Node) -> Array[Node]:
	var result: Array[Node] = []
	var driver: Node = nav._follow_driver
	if not is_instance_valid(driver): return result
	var pony: CharacterBody3D = nav.pony
	var ahead := corridor(nav, LOOK_AHEAD)
	for other: Node in driver.nearby_navigators(pony.global_position, LOOK_AHEAD + 0.6):
		if other == nav or other.get("peer_passage") == null: continue
		var body: CharacterBody3D = other.pony
		var room: float = float(pony.profile.radius) + float(body.profile.radius) + MARGIN
		if _distance_to(body.global_position, ahead) <= room: result.append(other)
	return result


## Nobody can make room: plan once around the ponies standing there (search discs only).
func _reroute(nav: Node, blockers: Array[Node]) -> void:
	_reroute_at = _clock + REROUTE_INTERVAL
	held = 0.0
	var discs := PackedFloat32Array()
	var own: float = float(nav.pony.profile.radius)
	for other: Node in blockers:
		var at: Vector3 = other.pony.global_position
		discs.append_array([at.x, at.z, own + float(other.pony.profile.radius) + PEER_DISC_PAD])
	reroutes += 1
	# Peer discs live apart from the native obstruction evidence (a native replan no longer drops
	# them, and they expire instead of riding along the rest of the trip).
	nav._peer_discs = discs
	nav._peer_discs_msec = Time.get_ticks_msec()
	nav._cancel_queries()
	nav._needs_path = true
	nav.reason = "Rerouting around ponies in the way"


## --- Yielder half ------------------------------------------------------------------------------

## Asked by `requester` to clear her corridor. True when a courtesy step is under way.
func make_room(nav: Node, requester: Node) -> bool:
	if active(): return requester_ref != null and requester_ref.get_ref() == requester
	if not _free(nav): return false
	var pony: CharacterBody3D = nav.pony
	var walker: bool = nav._has_target
	if not walker and not _owner_yields(nav): return false
	var sitting := not _standing(pony)
	if sitting and (walker or not pony.has_method(&"request_posture") or not (nav.command_owner.is_empty() or nav.command_owner.begins_with("life:"))):
		return false
	var route := _aside_route(nav, requester)
	if route.is_empty(): return false
	goal = route[-1]
	via = route[0] if route.size() == 2 else Vector3.INF
	owner = nav.command_owner
	resume = walker
	requester_ref = weakref(requester)
	if walker:
		# A fresh intent for the courtesy leg; the trip is replanned from the new spot afterwards.
		nav._native_intent += 1
		nav._cancel_queries()
	intent = nav._native_intent
	yields += 1
	if debug: print("[peer] %s steps aside for %s: at=%s via=%s goal=%s requester=%s" % [nav.pony.name, requester.pony.name,
		pony.global_position, via, goal, requester.pony.global_position])
	if sitting:
		pony.request_posture("stand")
		phase = "standing"; until = _clock + STAND_SECONDS
	else:
		phase = "moving"; until = _clock + MOVE_SECONDS
	return true


## Nearest supported floor beside her, off the requester's corridor, reached by a clear sweep:
## [goal], or [via, goal] when she must first walk on out of a doorway, away from the requester.
func _aside_route(nav: Node, requester: Node) -> Array[Vector3]:
	var none: Array[Vector3] = []
	var service: Node = nav._service
	if not is_instance_valid(service) or not service.ready_for_paths: return none
	var pony: CharacterBody3D = nav.pony
	var at := pony.global_position
	var line := corridor(requester, CLEAR_AHEAD)
	var room: float = float(pony.profile.radius) + float(requester.pony.profile.radius) + MARGIN
	var travel: Vector3 = line[-1] - line[0]; travel.y = 0.0
	travel = travel.normalized() if travel.length() > 0.05 else -pony.global_basis.z
	var other: Vector3 = requester.pony.global_position
	var toward: Vector3 = other - at; toward.y = 0.0
	toward = toward.normalized() if toward.length() > 0.05 else -travel
	var candidates: Array = []
	for radius: float in STEP_RADII:
		for step in 16:
			var angle := float(step) * TAU / 16.0
			var direction := Vector3(cos(angle), 0.0, sin(angle))
			# Sideways first, never back toward the requester.
			var cost := radius * (1.0 + 0.5 * absf(direction.dot(travel)) + 0.8 * maxf(0.0, direction.dot(toward)))
			candidates.append([cost, at + direction * radius])
	candidates.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	# Never a step that has to squeeze past the requester (the follower's neighbour arcs refuse it).
	var apart: float = float(pony.profile.radius) + float(requester.pony.profile.radius) + 0.3
	for entry: Array in candidates:
		var point := _spot(service, pony, entry[1], at.y, line, room)
		if point.is_finite() and _leg_apart(at, point, other, apart) and _leg_clear(service, pony, at, point) and TRAVEL.controller_clear(pony, point):
			none.append(point)
			return none
	# Standing inside a doorway or an alley: walk on out of it ahead of the requester, then aside.
	var side := travel.cross(Vector3.UP)
	for distance: float in [1.2, 1.8, 2.4]:
		var lead := _floor(service, pony, at + travel * distance, at.y)
		if not lead.is_finite() or not _leg_apart(at, lead, other, apart) or not _leg_clear(service, pony, at, lead) or not TRAVEL.controller_clear(pony, lead): continue
		for lateral: float in [1.2, -1.2, 1.7, -1.7]:
			for forward: float in [0.0, 0.6]:
				var point := _spot(service, pony, lead + side * lateral + travel * forward, at.y, line, room)
				if point.is_finite() and _leg_apart(lead, point, other, apart) and _leg_clear(service, pony, lead, point) and _sweep_clear(pony, lead, point):
					none.append_array([lead, point])
					return none
	return none


## The walk grid's full body room along the leg (the motor's body is wider than its capsule);
## a start already inside that margin, standing against a wall, is judged by the sweep alone.
static func _leg_clear(service: Node, pony: CharacterBody3D, from: Vector3, to: Vector3) -> bool:
	if not service.is_walkable(from, pony.profile): return service.is_walkable(to, pony.profile)
	return service.steering_segment_clear(from, to, pony.profile)


## The leg keeps `apart` from the requester, or at least never closes in on her further.
static func _leg_apart(from: Vector3, to: Vector3, other: Vector3, apart: float) -> bool:
	var near := Geometry3D.get_closest_point_to_segment(other, from, to)
	var start := Vector2(from.x - other.x, from.z - other.z).length()
	return Vector2(near.x - other.x, near.z - other.z).length() >= minf(apart, start - 0.02)


func _floor(service: Node, pony: CharacterBody3D, wanted: Vector3, height: float) -> Vector3:
	var floor: Vector3 = service.closest(wanted, pony.profile, 0.3)
	return floor if floor.is_finite() and absf(floor.y - height) <= 0.3 else Vector3.INF


func _spot(service: Node, pony: CharacterBody3D, wanted: Vector3, height: float, line: PackedVector3Array, room: float) -> Vector3:
	if _distance_to(wanted, line) < room: return Vector3.INF
	var floor := _floor(service, pony, wanted, height)
	if not floor.is_finite() or _distance_to(floor, line) < room: return Vector3.INF
	return floor


## Her own collision shape swept from `from` to `to` (both legs of a doorway exit).
static func _sweep_clear(pony: CharacterBody3D, from: Vector3, to: Vector3) -> bool:
	var holder: CollisionShape3D = pony.get("_collision") as CollisionShape3D
	if holder == null or holder.shape == null: return false
	var sweep := PhysicsShapeQueryParameters3D.new()
	sweep.shape = holder.shape
	sweep.transform = holder.global_transform
	sweep.transform.origin += from - pony.global_position + Vector3.UP * 0.03
	sweep.margin = 0.001
	sweep.motion = to - from
	sweep.collision_mask = pony.collision_mask | 2
	sweep.exclude = [pony.get_rid()]
	var space := pony.get_world_3d().direct_space_state
	if not space.intersect_shape(sweep, 1).is_empty(): return false
	var travel := space.cast_motion(sweep)
	return travel.size() == 2 and travel[0] >= 0.9999


## Runs before the navigator's own route logic; true while the courtesy step owns this tick.
func tick(nav: Node, delta: float) -> bool:
	if not active(): return false
	_clock += delta
	if nav.command_owner != owner or nav._native_intent != intent or not _free(nav):
		var walker := resume
		clear()
		if walker and nav._has_target and nav._native_intent == intent: nav._needs_path = true
		return false
	var pony: CharacterBody3D = nav.pony
	match phase:
		"standing":
			nav._halt()
			nav.state = nav.State.IDLE; nav.reason = "Getting up to make room"
			if _standing(pony) and (not pony.has_method(&"posture_status") or bool(pony.posture_status().get("settled", true))):
				phase = "moving"; until = _clock + MOVE_SECONDS
			elif _clock >= until:
				clear()
			return true
		"moving":
			if nav._flat_distance(pony.global_position, goal) < 0.15 or _clock >= until:
				if debug: print("[peer] %s courtesy step ends at %s (goal %s, timed out %s)" % [pony.name, pony.global_position, goal, _clock >= until])
				nav.path.clear(); nav._halt()
				if not resume:
					clear()
					nav.state = nav.State.IDLE; nav.reason = "Staying here"
					return true
				phase = "waiting"; until = _clock + WAIT_SECONDS
				return true
			_walk(nav, delta)
			nav.state = nav.State.MOVING; nav.reason = "Stepping aside to let a pony pass"
			return true
		"waiting":
			nav._halt()
			nav.state = nav.State.WAITING; nav.reason = "Letting a pony pass"
			if _clock >= until or _passed(nav):
				clear()
				nav._needs_path = true
				nav._reset_lookahead()
				return false
			return true
	clear()
	return false


## One straight courtesy leg for the ordinary native follower and motor (one movement writer),
## resent only when its end moves or a turn swung her off it.
func _walk(nav: Node, delta: float) -> void:
	var pony: Node3D = nav.pony
	var path: PackedVector3Array = nav.path
	# The doorway exit point is passed once she is near it.
	if via.is_finite() and nav._flat_distance(pony.global_position, via) < 0.3: via = Vector3.INF
	var size := 3 if via.is_finite() else 2
	var changed: bool = not nav._native_authored or path.size() != size or path[-1].distance_to(goal) > 0.05 \
		or TRAVEL.off_line(pony.global_position, path) > 0.25
	if changed:
		nav.path = PackedVector3Array([pony.global_position, via, goal]) if via.is_finite() else PackedVector3Array([pony.global_position, goal])
		nav._path_serial += 1
	nav._native_authored = true
	nav._native_speed_cap = 1.2
	nav._needs_path = false
	nav._native_tick(delta)


## The requester is gone, stopped wanting this way, or is already beyond her.
func _passed(nav: Node) -> bool:
	var other: Node = requester_ref.get_ref() if requester_ref != null else null
	if not is_instance_valid(other) or not other._has_target: return true
	var here: Vector3 = nav.pony.global_position
	var there: Vector3 = other.pony.global_position
	var room: float = float(nav.pony.profile.radius) + float(other.pony.profile.radius) + MARGIN
	if _distance_to(here, corridor(other, CLEAR_AHEAD)) < room: return false
	var heading: Vector3 = corridor(other, 1.0)[-1] - there; heading.y = 0.0
	var offset := here - there; offset.y = 0.0
	return offset.length() > room and (heading.length() < 0.05 or heading.dot(offset) < 0.0)
