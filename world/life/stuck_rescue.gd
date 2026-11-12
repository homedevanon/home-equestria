extends Node
## One resident check per quarter second, not a new per-pony physics sweep.
## A full in-game day away from her bed without moving >1.25 m is a softlock.
const DAY_HOURS := 24.0
const MOVED_SQUARED := 1.25*1.25
const PLACEMENT := preload("res://world/navigation/roster_placement.gd")
const HOUSE := preload("res://world/buildings/house_interior.gd")
const VIEW := preload("res://world/player_view.gd")
## No progress toward a goal (tester 2026-10-20: Twilight wedged between her bed's foot and the
## loft rail, unable to route out or follow him). House travel's short swept departure needs
## full-radius standing room within 0.8 m and gives up after 15 s, its retry starts from the same
## spot, and the day rule above waits a whole day and then puts her beside her bed, the same aisle.
## So: a pony trying to reach a goal at least GOAL_FAR away that has not moved PROGRESS metres in
## STALL_SECONDS, while the player cannot see her, is set down on the nearest point that still has
## a route (a room walk point or the door inside a house; the next point of her certified route
## outdoors). Her command, owner and goal stay; only where she stands changes.
const STALL_SECONDS := 12.0
const PROGRESS := 1.0
const GOAL_FAR := 2.0
const RETRY_SECONDS := 30.0
const SEEN_DISTANCE := 45.0
## How far above her a bridge deck counts as the one she fell under.
const DECK_REACH := 6.0
const WALK_POINT_KEYS := ["ground_walk_points", "loft_walk_points", "upper_walk_points"]
var population: Node
var clock: Node
var _records := {}
var _timer := 0.0
var _index := 0
var _stalls := {}   # id -> {actor, at, since, retry} (seconds of this node's physics time)
var _stall_timer := 0.0
var _clock := 0.0

func setup(people: Node) -> void:
	population = people; clock = get_node("/root/TimeOfDay")

func stationary(id: String, actor_id: int, at: Vector3, hour: float, exempt := false) -> bool:
	var previous: Dictionary = _records.get(id,{})
	if exempt or previous.is_empty() or previous.actor!=actor_id or hour<float(previous.hour) or at.distance_squared_to(previous.at)>MOVED_SQUARED:
		_records[id] = {"actor":actor_id,"at":at,"hour":hour}
		return false
	return hour-float(previous.hour)>=DAY_HOURS

func _physics_process(delta: float) -> void:
	_clock += delta
	_stall_timer -= delta
	if _stall_timer <= 0.0 and population != null:
		_stall_timer = 1.0
		_begin_stall_pass()
	if _stall_at < _stall_ids.size(): _check_stall_slice()
	_timer -= delta
	if _timer>0.0 or population==null or clock==null or clock.paused: return
	_timer = .25
	var ids: Array = population.live.keys()
	if ids.is_empty(): return
	_index %= ids.size()
	var id: String = ids[_index]; _index += 1
	var actor: CharacterBody3D = population.live[id].get("actor") as CharacterBody3D
	if not is_instance_valid(actor): _records.erase(id); return
	var exempt: bool = actor.get("_held")==true or actor.get("motion_paused")==true or actor.has_meta("seated")
	var hour: float = float(clock.day)*24.0+float(clock.hours)
	if not stationary(id,actor.get_instance_id(),actor.global_position,hour,exempt): return
	var home: Node3D = population.home_house(id)
	if home==null or home.ensure_bed(id)==null: return # wait for the home to stream in
	if home.on_mattress(actor.global_position,id):
		_records.erase(id); return # already in the right bed
	if recover(id,actor,home):
		_records.erase(id)
		print("[pony] %s returned home after a full day stuck" % actor.name)

func recover(id: String, actor: CharacterBody3D, home: Node3D) -> bool:
	var rest: Transform3D = home.bed_rest(id)
	if not rest.is_finite(): return false
	# The safe standing floor immediately beside her bed lets her resume her day.
	# The ordinary bedtime system can tuck her in when it is actually time to sleep.
	var at := PLACEMENT.support(actor.get_world_3d().direct_space_state,home.bed_side(id),actor.profile,home)
	if not at.is_finite(): return false
	var night: Node = get_parent().get_node_or_null("NightRest")
	if night != null: night.release_for_recovery(id,actor)
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav != null:
		nav.stay(); nav.command_owner=""; nav.wander_enabled=true
	if "sleeping" in actor: actor.sleeping=false
	actor.motion_paused=false
	actor.water_escape.reset()
	actor.placement_recovery.pending=false
	actor.reset_motion(Transform3D(rest.basis,at))
	actor.reset_physics_interpolation()
	return true

## Once a second over the live residents: bookkeeping only, physics queries only for a stall.
## The once-a-second stall pass over every live pony is spread over STALL_SLICE_TICKS physics
## ticks (W2 perf pass: ~0.5 ms in one tick with 45 ponies, a slowest-frames spike). Each pony is
## still checked once a second, in the same order. Rollback: STALL_SLICE_TICKS = 1.
const STALL_SLICE_TICKS := 6
var _stall_ids: Array = []
var _stall_at := 0
var _stall_chunk := 1

func _check_stalls() -> void:
	_begin_stall_pass()
	_stall_chunk = _stall_ids.size()
	_check_stall_slice()

func _begin_stall_pass() -> void:
	for id: String in _stalls.keys():
		if not population.live.has(id): _stalls.erase(id)
	_stall_ids = population.live.keys()
	_stall_at = 0
	_stall_chunk = ceili(float(_stall_ids.size()) / float(maxi(STALL_SLICE_TICKS, 1)))

func _check_stall_slice() -> void:
	var end := mini(_stall_at + maxi(_stall_chunk, 1), _stall_ids.size())
	for i in range(_stall_at, end):
		var id: String = _stall_ids[i]
		if not population.live.has(id): _stalls.erase(id); continue
		_check_stall(id)
	_stall_at = end

func _check_stall(id: String) -> void:
	var value: Variant = population.live[id].get("actor")
	if not is_instance_valid(value) or not value is CharacterBody3D or not (value as Node).is_inside_tree():
		_stalls.erase(id); return
	var actor := value as CharacterBody3D
	var nav: Node = actor.get_node_or_null("Navigator")
	var goal := _goal(nav) if nav != null and "profile" in actor and _trying(actor, nav) else Vector3.INF
	var at := actor.global_position
	var row: Dictionary = _stalls.get(id, {})
	var far := goal.is_finite() and (Vector2(at.x - goal.x, at.z - goal.z).length() > GOAL_FAR or absf(at.y - goal.y) > 1.2)
	if row.is_empty() or int(row.actor) != actor.get_instance_id() or at.distance_to(row.at) >= PROGRESS:
		_stalls[id] = {"actor": actor.get_instance_id(), "at": at, "since": _clock, "still": _clock, "retry": float(row.get("retry", 0.0))}
		return
	# Under a bridge a pony may well have given up or dozed off by now, so this asks for neither
	# a goal nor that she is awake.
	if nav != null and "profile" in actor and _clock - float(row.still) >= STALL_SECONDS and _clock >= float(row.get("deck_retry", 0.0)) and _placeable(actor) and _unseen(actor, at):
		var deck := _bridge_deck_above(actor, at)
		if deck.is_finite():
			var night: Node = get_parent().get_node_or_null("NightRest")
			if night != null: night.release_for_recovery(id, actor)
			if "sleeping" in actor: actor.set("sleeping", false)
			_set_down(actor, nav, deck)
			row.at = deck; row.since = _clock; row.still = _clock
			print("[pony] %s was trapped under a bridge; set back on its deck at %s" % [actor.name, deck.round()])
			return
		row.deck_retry = _clock + RETRY_SECONDS
	if not far:
		row.since = _clock
		return
	if _clock - float(row.since) < STALL_SECONDS or _clock < float(row.retry) or not _unseen(actor, at): return
	row.retry = _clock + RETRY_SECONDS
	var spot := _reachable_spot(actor, nav, goal)
	if not spot.is_finite(): return
	_set_down(actor, nav, spot)
	row.at = spot; row.since = _clock
	print("[pony] %s made no progress for %.0f s out of sight; set down on a route point at %s" % [actor.name, STALL_SECONDS, spot.round()])

## Nopony else's to place: not held, seated, flying or thrown.
func _placeable(actor: CharacterBody3D) -> bool:
	if actor.get("_held") == true or actor.get("motion_paused") == true: return false
	if actor.has_meta("seated") or actor.has_meta("event_placed"): return false
	if actor.get("flight") != null and actor.flight.active(): return false
	var thrown: Variant = actor.get("thrown")
	return thrown == null or not thrown.active()

## The deck of the bridge right over her, or INF. A pony that slips under a deck (player report
## 2026-10-30: Rainbow Dash lost on the way back from fishing) has no route anywhere and nothing
## else brings her back. PLACEMENT.support refuses any sloped deck (its upright body volume cuts into
## the slope), so the search goes on along the deck to its flat middle, measuring the height at each
## spot; like the stall rescue, she never appears where the player is looking.
func _bridge_deck_above(actor: CharacterBody3D, at: Vector3) -> Vector3:
	var space := actor.get_world_3d().direct_space_state
	var exclude: Array[RID] = [actor.get_rid()]
	if not _bridge_over(space, at, exclude).has("position"): return Vector3.INF
	for reach: float in [0.0, 1.5, 3.0, 6.0, 10.0, 15.0]:
		for i in (1 if reach == 0.0 else 8):
			var top := _bridge_over(space, at + Vector3.FORWARD.rotated(Vector3.UP, TAU * i / 8.0) * reach, exclude)
			if top.is_empty(): continue
			var spot := PLACEMENT.support(space, top.position, actor.profile, null, exclude)
			if spot.is_finite() and _unseen(actor, spot): return spot
	return Vector3.INF

func _bridge_over(space: PhysicsDirectSpaceState3D, point: Vector3, exclude: Array[RID]) -> Dictionary:
	var top := space.intersect_ray(PhysicsRayQueryParameters3D.create(point + Vector3.UP * DECK_REACH, point + Vector3.UP * .5, 1, exclude))
	return top if not top.is_empty() and _on_bridge(top.collider) else {}

func _on_bridge(node: Variant) -> bool:
	while node is Node:
		if str((node as Node).name).to_lower().contains("bridge"): return true
		node = (node as Node).get_parent()
	return false

## Trying to get somewhere on her own legs: a route, a follow, or a route that just failed.
## Waiting at a door, for a pony to step aside or for ground support is progress of its own.
func _trying(actor: CharacterBody3D, nav: Node) -> bool:
	if not _placeable(actor) or actor.get("sleeping") == true: return false
	if actor.has_method("posture_status") and str(actor.posture_status().get("kind", "stand")) != "stand": return false
	# A story scene places her itself (placement_recovery.gd leaves reserved ponies alone too).
	if str(nav.get("reserved_by")) != "": return false
	if bool(nav.house_travel.waiting_for_ticket) or str(nav.reason).begins_with("Waiting") or str(nav.reason) == "Opening house door": return false
	if bool(nav.get("_has_target")) or is_instance_valid(nav.get("_follow_target")): return true
	return nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]

func _goal(nav: Node) -> Vector3:
	var live: Vector3 = nav.get("_live_goal")
	if live.is_finite(): return live
	var follow: Variant = nav.get("_follow_target")
	if is_instance_valid(follow) and follow is Node3D: return (follow as Node3D).global_position
	var target: Vector3 = nav.get("target")
	return target if bool(nav.get("_has_target")) else Vector3.INF

## Out of the player's sight: far, outside his view, or behind a wall or floor.
func _unseen(actor: CharacterBody3D, at: Vector3) -> bool:
	var camera := VIEW.camera(self)
	if camera == null: return true
	var chest := at + Vector3.UP * .6
	var eye := camera.global_position
	if eye.distance_to(chest) > SEEN_DISTANCE or not camera.is_position_in_frustum(chest): return true
	var ray := PhysicsRayQueryParameters3D.create(eye, chest, 1, [actor.get_rid()])
	return not actor.get_world_3d().direct_space_state.intersect_ray(ray).is_empty()

## The nearest standable point, other than where she is, from which her goal (or, for a goal
## outside, the house's door) has a route; also out of sight. INF when there is none.
func _reachable_spot(actor: CharacterBody3D, nav: Node, goal: Vector3) -> Vector3:
	var at := actor.global_position
	var space := actor.get_world_3d().direct_space_state
	var exclude: Array[RID] = [actor.get_rid()]
	var home := HOUSE.at(get_tree(), at)
	if home != null:
		var toward: Vector3 = goal if HOUSE.at(get_tree(), goal) == home else home.inside()
		var candidates: Array[Vector3] = [home.inside()]
		var furniture: Variant = home.get("furniture")
		if is_instance_valid(furniture) and furniture is Node:
			for key: String in WALK_POINT_KEYS:
				if not (furniture as Node).has_meta(key): continue
				for point: Variant in (furniture as Node).get_meta(key):
					if point is Vector3: candidates.append(home.to_global(point))
		candidates.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.distance_squared_to(at) < b.distance_squared_to(at))
		for candidate: Vector3 in candidates:
			if candidate.distance_to(at) < .3 or not _routes_on(home, actor, candidate, toward): continue
			var spot := PLACEMENT.support(space, candidate, actor.profile, home, exclude)
			if spot.is_finite() and _unseen(actor, spot): return spot
		return Vector3.INF
	# Outdoors only her own certified route counts as reachable ground.
	var path: PackedVector3Array = nav.get("path")
	for i in range(clampi(int(nav.get("_waypoint")), 0, path.size()), path.size()):
		if path[i].distance_to(at) < PROGRESS: continue
		var spot := PLACEMENT.support(space, path[i], actor.profile, null, exclude)
		if spot.is_finite() and _unseen(actor, spot): return spot
	return Vector3.INF

static func _routes_on(home: Node3D, actor: CharacterBody3D, from: Vector3, to: Vector3) -> bool:
	if from.distance_to(to) < .5: return true
	var next: Vector3 = home.local_waypoint_for(actor, from, to) if home.has_method("local_waypoint_for") else home.local_waypoint(from, to)
	return next.distance_to(from) > .05

## Same heading, new spot; the navigator plans again from there (house travel restarts its
## passage from the room she is now in). Owner, command and goal are untouched.
func _set_down(actor: CharacterBody3D, nav: Node, spot: Vector3) -> void:
	nav.house_travel.clear(actor)
	actor.reset_motion(Transform3D(actor.global_basis, spot))
	actor.reset_physics_interpolation()
	nav.path = PackedVector3Array()
	nav.set("_needs_path", true)
	nav.set("_stuck_time", 0.0)
