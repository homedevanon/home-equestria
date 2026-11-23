extends RefCounted
## A follower uses the leader's recent grounded footsteps while approaching a house
## entrance. HouseTravel still owns the actual route, door queue and crossing.
const HOUSE_TRAVEL := preload("res://world/characters/navigation/house_travel.gd")
const SAMPLE_M := .7
const APPROACH_M := 5.5
const HANDLE_ROOM_M := 1.25

var home: Node3D
var _trail: Array[Vector3] = []
var _started_inside := false
var _closest := INF
var _footstep := Vector3.INF
var _supported := Vector3.INF
var _blocked_until := {}

func reset() -> void:
	home = null
	_trail.clear()
	_footstep = Vector3.INF
	_supported = Vector3.INF
	_blocked_until.clear()

func _nearby_entrance(tree: SceneTree, before: Vector3, leader: Vector3) -> Node3D:
	var best: Node3D
	var best_gap := APPROACH_M
	for room: Node3D in HOUSE_TRAVEL.houses(tree):
		if room.global_position.distance_to(leader) > sqrt(room._reach_squared()) + APPROACH_M: continue
		var inside: Vector3 = room.inside()
		var outside: Vector3 = room.outside()
		if not inside.is_finite() or not outside.is_finite() or inside.is_equal_approx(outside): continue
		var near := Geometry3D.get_closest_point_to_segment(leader, inside, outside)
		var gap := near.distance_to(leader)
		if gap >= best_gap or absf(near.y - leader.y) > 1.0: continue
		# Require movement toward the entrance. Walking past an outside wall or
		# chatting near the door should not switch formation just on proximity.
		var heading := (leader - before).normalized()
		if heading.dot((near - before).normalized()) < .6: continue
		if not room.contains(before):
			var inward := inside - outside
			inward.y = 0
			if heading.dot(inward.normalized()) < .35: continue
		if not is_instance_valid(room.door()) or not room.contains(inside): continue
		best = room
		best_gap = gap
	return best

## Return true while the doorway owns the formation. Small grip adjustments keep
## the chosen target stable. A discontinuous step (teleport/load) starts fresh.
func update(tree: SceneTree, leader: Vector3, follower: Vector3) -> bool:
	if not leader.is_finite() or (not _trail.is_empty() and leader.distance_to(_trail.back()) > 4.0):
		reset()
	if not leader.is_finite(): return false
	if _trail.is_empty():
		_trail.append(leader)
		return false
	var before: Vector3 = _trail.back()
	var moved := before.distance_to(leader) >= SAMPLE_M
	if moved:
		_trail.append(leader)
		if _trail.size() > 32: _blocked_until.erase(_trail.pop_front())
	if not is_instance_valid(home):
		if not moved: return false
		home = _nearby_entrance(tree, before, leader)
		if not is_instance_valid(home): return false
		_started_inside = home.contains(before)
		_closest = INF
		_footstep = Vector3.INF
		_supported = Vector3.INF
		_blocked_until.clear()
	var inside: Vector3 = home.inside()
	var outside: Vector3 = home.outside()
	var near := Geometry3D.get_closest_point_to_segment(leader, inside, outside)
	var gap := leader.distance_to(near)
	_closest = minf(_closest, gap)
	var leader_inside: bool = home.contains(leader)
	var together: bool = leader_inside == home.contains(follower)
	var follower_near := Geometry3D.get_closest_point_to_segment(follower, inside, outside)
	var crossed := leader_inside != _started_inside and together and follower.distance_to(follower_near) > 1.0
	var turned_back := leader_inside == _started_inside and gap > _closest + 1.6
	if gap > 12.0 or absf(leader.y - near.y) > 1.5 or (gap > HANDLE_ROOM_M and (turned_back or crossed)):
		home = null
		return false
	return true

## Admit at most one footprint per decision. The route and motor still test live
## obstructions. A player's narrower body is never proof that a pony will fit.
func goal(nav: Node, leader: Vector3, follower: Vector3, spacing: float) -> Vector3:
	var near := Geometry3D.get_closest_point_to_segment(leader, home.inside(), home.outside())
	if _supported.is_finite() and leader.distance_to(near) <= HANDLE_ROOM_M:
		return _supported
	var now := Time.get_ticks_msec()
	for i in range(_trail.size() - 1, -1, -1):
		var point := _trail[i]
		var gap := Vector2(point.x - leader.x, point.z - leader.z).length()
		if gap < spacing or gap > spacing + 3.0: continue
		if now < int(_blocked_until.get(point, 0)): continue
		if point == _footstep: return _supported
		var floor: Vector3
		if home.contains(point):
			floor = nav._indoor_follow_support(home, point, point.y)
		else:
			floor = nav.command_support(point)
			if floor.is_finite() and (home.contains(floor) or floor.distance_to(point) > 1.0):
				floor = Vector3.INF
		if floor.is_finite():
			_footstep = point
			_supported = floor
		else:
			# Keep the last usable step. On the next decision try another recent
			# footprint, without bursting through the whole trail in one frame.
			_blocked_until[point] = now + 1000
		return _supported
	return _supported if _supported.is_finite() or not _blocked_until.is_empty() else follower

func route_failed() -> void:
	if is_instance_valid(home) and _footstep.is_finite():
		_blocked_until[_footstep] = Time.get_ticks_msec() + 1000
		_footstep = Vector3.INF
		_supported = Vector3.INF
