extends RefCounted
## Hold jump to paddle up and tread at the surface; release to sink gently. Pushing into a
## steep bank climbs out (bank_exit); pushing on without progress rescues to dry ground.
const WATER := preload("res://world/water/water_contact.gd")
const SPEED := 2.0
var active := false
var surface := -INF
var phase := 0.0

func sample(space: PhysicsDirectSpaceState3D, feet: Vector3, eye_height: float, delta: float, enabled := true) -> void:
	surface = WATER.surface_above(space, feet) if enabled else -INF
	var threshold := eye_height * (.30 if active else .40)
	active = is_finite(surface) and surface - feet.y > threshold
	phase = fmod(phase + delta * TAU / 2.8, TAU) if active else 0.0

func vertical(speed: float, feet_y: float, eye_height: float, held_jump: bool, delta: float) -> float:
	var desired := -.65
	if held_jump:
		# Move the body, never the tracked camera's local pose. About 9 cm peak-to-peak.
		var target := surface - eye_height + .14 + .045 * sin(phase)
		desired = clampf((target - feet_y) * 3.0, -.8, 1.6)
	return move_toward(clampf(speed, -2.0, 1.6), desired, 5.0 * delta)

# A steep river bank is a climb, not another surface-swimming velocity.
# Shared desktop/VR body movement; tracked camera/controller local poses stay untouched.
# Pushing into the bank is enough; jump also still works, swimming at any depth or wading
# (dev 2026-10-22: steep banks softlocked players who did not know to hold jump).
const BANK_RISE := 2.0
const BANK_REACH := 2.2
const CLIMB_SPEED := 2.5
## A long lift (from the bed of a deep canal) still ends in about this many seconds.
const CLIMB_SECONDS := 2.5
const CLIMB_MAX_SPEED := 4.0
## Seconds of pushing in water without getting anywhere before the dry-ground rescue.
const RESCUE_AFTER := 2.5
const RESCUE_RADII: Array[float] = [1.5, 2.5, 3.5, 5.0, 7.0, 10.0, 14.0, 20.0, 28.0, 40.0, 56.0]
## A rescue farther than this across moves straight there instead of climbing over.
const RESCUE_CLIMB_ACROSS := 4.0
## W2-NAV-TERRAIN hook 3 (M-NAV-04): true ranks a gorge top by horizontal distance first, height
## second. Measured 2026-11-08 (tools/water/test_river_exit.gd, river_ponyville_sea): true lifted
## the swimmer 36-39 m onto a nearer, higher top; the older cost (false) lifts 23-25 m. Kept false;
## the lasting fix is widening that river ribbon to its bank (water footprint).
const NEAREST_GORGE_TOP := false
var climbing := false
## How the last exit happened: "climb", "rescue_climb" or "rescue_move" (tests and logs).
var last_exit := ""
var _lift := Vector3.ZERO
var _landing := Vector3.ZERO
var _across := false
var _probe_wait := 0.0
var _climb_time := 0.0
var _climb_limit := 3.0
var _climb_speed := CLIMB_SPEED
var _stuck := 0.0
var _window := 0.0
var _window_from := Vector3.INF
var _wall_time := 0.0
## Where, and under what water level, the feet were last wet. Water footprints can end before
## their own steep bank, leaving a dry strip below the water level: within NEAR_WATER of that
## point and still under the level, pushing keeps the climb and the rescue available.
const NEAR_WATER := 8.0
var _wet_level := -INF
var _wet_at := Vector3.INF

func bank_exit(body: CharacterBody3D, feet: Vector3, eye_height: float,
		direction: Vector3, wants_up: bool, delta: float) -> bool:
	_probe_wait = maxf(0.0, _probe_wait-delta)
	if not climbing:
		var flat := Vector3(direction.x,0,direction.z)
		var wet := is_finite(surface) and (active or surface-feet.y>.15)
		if wet:
			_wet_level = surface; _wet_at = feet
		elif _wet_at.is_finite() and (feet.y>_wet_level-.3 or Vector2(feet.x-_wet_at.x,feet.z-_wet_at.z).length()>NEAR_WATER):
			_wet_at = Vector3.INF
		if not (wet or _wet_at.is_finite()) or flat.length_squared()<.1:
			_stuck = 0.0; _window_from = Vector3.INF
			return false
		flat = flat.normalized()
		var into_wall := body.is_on_wall() and body.get_wall_normal().dot(flat)<-.3
		# Pushing on without getting anywhere, or only sliding along a wall pushed into:
		# no bank lip is in reach (high walls, cliffs).
		if _stuck_for(feet,flat,into_wall,delta)>=RESCUE_AFTER:
			_stuck = 0.0; _window_from = Vector3.INF
			if rescue(body,feet,flat): return true
		if not body.is_on_wall() or _probe_wait>0.0: return false
		if not wants_up and not into_wall: return false
		_probe_wait = .2
		var goal := bank_target(body,feet,eye_height,direction)
		if not goal.is_finite(): return false
		_begin_climb(body,feet,goal,"climb")
	_climb_time += delta
	var target := _landing if _across else _lift
	var motion := target-body.global_position
	body.velocity = Vector3.ZERO
	if motion.length() <= .025:
		if _across:
			climbing = false; active = false; _probe_wait = .5
		else: _across = true
		return true
	var collision := body.move_and_collide(motion.limit_length(_climb_speed*delta))
	if collision != null or _climb_time>_climb_limit:
		# Moving props/doors may obstruct a previously clear climb. Never force through,
		# except to finish a rescue at its already validated dry spot.
		climbing = false; _probe_wait = .5
		if last_exit == "rescue_climb" and not body.test_move(Transform3D(body.global_basis,_landing),Vector3.ZERO,null,.01,true):
			_place(body,_landing); last_exit = "rescue_move"
	return true

func _begin_climb(body: CharacterBody3D, feet: Vector3, goal: Vector3, how: String) -> void:
	# Room-scale feet can be offset from the Body origin. Move both by the same offset.
	_landing = body.global_position + goal-feet
	_lift = Vector3(body.global_position.x,_landing.y,body.global_position.z)
	var distance := absf(_lift.y-body.global_position.y)+_lift.distance_to(_landing)
	_climb_speed = clampf(distance/CLIMB_SECONDS,CLIMB_SPEED,CLIMB_MAX_SPEED)
	_climb_limit = distance/_climb_speed+1.0
	_across = false; _climb_time = 0.0; climbing = true; last_exit = how

## Seconds spent pushing along `forward` while getting less than 0.3 m/s along it, or while
## mostly pressed into a wall. Measured from where the streak began, every half second, so
## bobbing back and forth at a bank edge or a wall contact that flickers while sliding down
## a steep bank face does not restart it.
func _stuck_for(feet: Vector3, forward: Vector3, into_wall: bool, delta: float) -> float:
	if not _window_from.is_finite():
		_window_from = feet; _window = 0.0; _wall_time = 0.0; _stuck = 0.0
	_window += delta
	if into_wall: _wall_time += delta
	if _window >= _stuck+.5:
		var moved := feet-_window_from
		if Vector3(moved.x,0,moved.z).dot(forward) < .3*_window or _wall_time > .5*_window: _stuck = _window
		else: _window_from = feet; _window = 0.0; _wall_time = 0.0; _stuck = 0.0
	return _stuck

## Last resort: climb over to, or move straight onto, the nearest dry standable ground,
## preferring the side being pushed toward. Never turns the body (headset yaw is kept).
func rescue(body: CharacterBody3D, feet: Vector3, direction: Vector3) -> bool:
	var goal := dry_spot(body,feet,direction)
	if not goal.is_finite(): return false
	var raised := body.global_transform
	raised.origin.y += goal.y-feet.y
	var landed := raised
	landed.origin += Vector3(goal.x-feet.x,0,goal.z-feet.z)
	if Vector2(goal.x-feet.x,goal.z-feet.z).length()<=RESCUE_CLIMB_ACROSS \
			and not body.test_move(body.global_transform,raised.origin-body.global_position) \
			and not body.test_move(raised,landed.origin-raised.origin):
		_begin_climb(body,feet,goal,"rescue_climb")
		return true
	_place(body,landed.origin)
	last_exit = "rescue_move"
	return true

## The water level exits are measured from: the water over the feet, else the remembered one
## while still in the dry strip beside it.
func _level() -> float:
	if is_finite(surface): return surface
	return _wet_level if _wet_at.is_finite() else -INF

func _place(body: CharacterBody3D, at: Vector3) -> void:
	if body.has_method("reset_motion"): body.call("reset_motion",Transform3D(body.global_basis,at))
	elif body.has_method("teleport"): body.call("teleport",at)
	else: body.global_position = at
	body.reset_physics_interpolation()
	body.velocity = Vector3.ZERO
	climbing = false; active = false; _probe_wait = .5; _stuck = 0.0; _window_from = Vector3.INF

## The cheapest dry, walkable spot with room for the body within 56 m: near, on the side being
## pushed toward, low over the water, under open sky (not a house floor); a dry pit below the
## waterline only when nothing at the water level is in reach. Cliff tops up to 12 m above the
## water count when nothing lower is near, and up to 60 m in a gorge.
func dry_spot(body: CharacterBody3D, feet: Vector3, direction: Vector3) -> Vector3:
	var goal := _dry_spot(body,feet,direction,12.0)
	# A gorge: walls taller than 12 m and only dry pits below the water level near. Its top, up
	# to 60 m up, beats a pit closed in by the same walls.
	var level := _level()
	var base := maxf(level,feet.y) if is_finite(level) else feet.y
	if not goal.is_finite() or goal.y<base-.3:
		# Gorge tops: NEAREST_GORGE_TOP chooses the ranking (W2-NAV-TERRAIN M-NAV-04).
		var high := _dry_spot(body,feet,direction,60.0,NEAREST_GORGE_TOP)
		if high.is_finite() and high.y>=base-.3: return high
	return goal

func _dry_spot(body: CharacterBody3D, feet: Vector3, direction: Vector3, ceiling: float, nearest_first := false) -> Vector3:
	var space := body.get_world_3d().direct_space_state
	var mask := body.collision_mask & ~WATER.MASK
	var excluded: Array[RID] = [body.get_rid()]
	var forward := Vector3(direction.x,0,direction.z).normalized()
	var level := _level()
	var base := maxf(level,feet.y) if is_finite(level) else feet.y
	var min_up := maxf(.7,cos(body.floor_max_angle)+.02)
	var spots: Array = []
	for radius: float in RESCUE_RADII:
		for k in 16:
			var offset := Vector3(cos(k*TAU/16.0),0,sin(k*TAU/16.0))*radius
			var at := feet+offset
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(at.x,base+ceiling,at.z),Vector3(at.x,base-6.0,at.z),mask,excluded))
			if hit.is_empty() or hit.normal.y<min_up: continue
			var goal: Vector3 = hit.position+Vector3.UP*.06
			if WATER.surface_above(space,goal)>goal.y+.03: continue
			var cost := radius*(1.0-.4*offset.normalized().dot(forward))+1.5*maxf(0.0,goal.y-base-1.5)
			if nearest_first: cost = radius*(1.0-.4*offset.normalized().dot(forward))*1000.0+maxf(0.0,goal.y-base)
			# A dry pit below the water level only when no spot at the level exists in reach.
			if goal.y<base-.3: cost += 1.0e7 if nearest_first else 1000.0
			var sky := PhysicsRayQueryParameters3D.create(goal+Vector3.UP*.1,goal+Vector3.UP*12.0,mask,excluded)
			if not space.intersect_ray(sky).is_empty(): cost += 10.0
			spots.append([cost,goal])
	spots.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0])<float(b[0]))
	for spot: Array in spots:
		var goal: Vector3 = spot[1]
		var placed := body.global_transform
		placed.origin += goal-feet
		if not body.test_move(placed,Vector3.ZERO,null,.01,true): return goal
	return Vector3.INF

func bank_target(body: CharacterBody3D, feet: Vector3, eye_height: float, direction: Vector3) -> Vector3:
	var forward := Vector3(direction.x,0,direction.z).normalized()
	var level := _level()
	if forward.is_zero_approx() or not is_finite(level): return Vector3.INF
	var space := body.get_world_3d().direct_space_state
	var mask := body.collision_mask & ~(1 << 15)
	var excluded: Array[RID] = [body.get_rid()]
	# The landing must be floor for this body (ponies stand on 35 degrees, Anon on 45).
	var min_up := maxf(.7,cos(body.floor_max_angle)+.02)
	# Probe the top, not the near-vertical bank face. A dry, walkable ledge with room
	# for the whole body and an unobstructed up-then-forward path is required.
	for reach: float in [.6,1.0,1.4,1.8,BANK_REACH]:
		var at := feet+forward*reach
		var ray := PhysicsRayQueryParameters3D.create(Vector3(at.x,level+BANK_RISE,at.z),
			Vector3(at.x,level-.1,at.z),mask,excluded)
		var hit := space.intersect_ray(ray)
		if hit.is_empty() or hit.normal.y<min_up: continue
		var goal: Vector3 = hit.position+Vector3.UP*.06
		if WATER.surface_above(space,goal)>goal.y+.03: continue
		var raised := body.global_transform
		raised.origin.y += goal.y-feet.y
		var landed := raised
		landed.origin += Vector3(goal.x-feet.x,0,goal.z-feet.z)
		if body.test_move(landed,Vector3.ZERO,null,.01,true): continue
		if body.test_move(body.global_transform,raised.origin-body.global_position): continue
		if body.test_move(raised,landed.origin-raised.origin): continue
		return goal
	return Vector3.INF
