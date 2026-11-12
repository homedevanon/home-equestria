extends RefCounted
## Intentional flight only. Grounded ledge guards remain in force until takeoff.
const WATER_MASK := 1 << 15
const POSE = preload("res://world/characters/locomotion/pony_flight_pose.gd")
const WINGS = preload("res://world/characters/hybrid_mare/hybrid_open_wings.gd")
var pony: CharacterBody3D
var pose: RefCounted
var wings: Node
var state := "grounded"
var reason := ""
var home := Vector3.ZERO
var destination := Vector3.ZERO
var cruise_y := 0.0
var hover_seconds := 0.0
var _blend := 0.0
var _previous: Array[Transform3D] = []
var _blocked := 0.0
var _route: Array[Vector3] = []
var _returning := false
## Landing checked against the heightmap only (collision not streamed there yet).
var _provisional := false
## Loop-de-loops still to fly on this trip, and the one in progress.
var loops := 0
var _loop_angle := -1.0
var _loop_origin := Vector3.ZERO
var _loop_forward := Vector3.FORWARD
var _loop_radius := 3.0
var _cruise_start := Vector3.INF
var _hover_at := Vector3.INF
var _trail: Node3D
var _boomed := false
## A rider she carries (M-LIF-09, W1-PERF-PONY 2026-11-08): the RIDs of his body, hands and
## whatever he holds. Every obstacle, landing and ground probe of her flight ignores them as it
## ignores her own body; her probe ball grows with her size and otherwise takes in her rider
## (Pegasus Ride 2.2.1 switched Anon's colliders off to get round it). A ride sets them on mount
## with set_rider() and clears them on dismount with set_rider([]).
var rider_rids: Array[RID] = []

## `nodes`: CollisionObject3D nodes or nodes above them; every CollisionObject3D at or under each
## is excluded. A held item that sits elsewhere in the tree is passed in its own right.
func set_rider(nodes: Array) -> void:
	rider_rids.clear()
	for node: Variant in nodes:
		# Validity first: `is` on a freed instance is a runtime error in debug builds.
		if not (is_instance_valid(node) and node is Node): continue
		var found: Array[Node] = (node as Node).find_children("*", "CollisionObject3D", true, false)
		if node is CollisionObject3D: found.append(node)
		for body: Node in found:
			var rid := (body as CollisionObject3D).get_rid()
			if not rider_rids.has(rid): rider_rids.append(rid)

## Her own body and her rider's (rider_rids): what her flight probes never treat as an obstacle.
func _own_rids() -> Array[RID]:
	var rids: Array[RID] = [pony.get_rid()]
	if not rider_rids.is_empty(): rids.append_array(rider_rids)
	return rids
## Tricks a pony can be asked for (world/ai/pony_action_executor.gd): "loop" (loop-de-loop),
## "barrel_roll", "circle" (laps over _circle_centre) and "rainboom" (Rainbow Dash only).
## The trick runs once the cruise has open sky; `loops` counts how many are left.
var _trick := "loop"
## Air show (the AI's [air_show: ...], dev 2026-10-17: "add more fly actions that can be chained
## together by the ai for an air show"): one takeoff to a show point SHOW_ALTITUDE up beside
## `centre`, each manoeuvre in turn as a pre-checked path flown at SHOW_SPEED (the body pitched
## and rolled along it), back to the show point between figures, then the usual glide in.
const SHOW_MOVES := ["loop", "barrel_roll", "aileron_roll", "spiral_climb", "dive", "figure_eight", "immelmann", "split_s", "hammerhead", "flyby", "circle"]
const SHOW_ALTITUDE := 14.0
const SHOW_SPEED := 9.0
const SHOW_LIMIT := 8
var _show: Array[String] = []
var _show_centre := Vector3.INF
var _show_point := Vector3.INF
var _show_side := 1.0
## Figures flown this show, in order ("name" or "name:skipped"; labs and reports).
var show_log: Array[String] = []
var _man_name := ""
var _man_points := PackedVector3Array()
var _man_ups := PackedVector3Array()
var _man_cum := PackedFloat32Array()
var _man_t := -1.0         # metres flown along the current figure; -1 when none
var _man_i := 0
var _circle_centre := Vector3.INF
var _circle_angle := 0.0
var _circle_radius := 5.0
var _circle_turns := 0.0
## The sonic rainboom's burst: acceleration and braking times this during the out-and-back.
const RAINBOOM_BOOST := 10.0
var _boost := 1.0
## The current waypoint and where she was when it became current (waypoint passing).
var _leg_goal := Vector3.INF
var _leg_from := Vector3.INF
## Flight speeds (m/s, times body scale). dev 2026-09-26: fly way faster; Rainbow Dash can break
## the sound barrier (she gets the rainbow trail when fast, and a sonic rainboom at ~340 m/s).
const CRUISE := 20.0
const ACCEL := 7.0
const BRAKE := 6.0
const DASH_CRUISE := 350.0
const DASH_ACCEL := 45.0
const DASH_BRAKE := 40.0
const SOUND_BARRIER := 340.0
const TRAIL := preload("res://world/characters/locomotion/rainbow_trail.gd")
const NATIVE_AIR := preload("res://world/characters/locomotion/native_air.gd")
## The cruise of this flight follows a native 3D air route (native_air.gd) from the takeoff point
## to the glide-in's approach point; takeoff and the glide-in keep this script's own steps.
var _native_leg := false
var _native_id := 0
var _recovery_retry := 0.0
## A caught throw, a hover with no clear corridor and a flight that stopped getting anywhere are
## bounded (2026-10-15: thrown Dash hovered 0.8 m up for minutes until told to stop). An
## autonomous leg without PROGRESS_SECONDS of progress replans its landing; a flight that must land
## and has not within RESCUE_SECONDS settles straight down on her own swept body; with nothing
## below within SETTLE_SECONDS, placement recovery's rescue hover.
const PROGRESS_SECONDS := 6.0
const RESCUE_SECONDS := 12.0
const SETTLE_SECONDS := 6.0
var _must_land := false
var _stall := 0.0
var _settle_for := 0.0
var _progress_at := Vector3.INF
var _progress_for := 0.0

## Player flight: cached input and one shared momentum/stamina state, no new mover.
const PILOT_GRACE := 0.6
var pilot_model: RefCounted
var pilot_view := Basis.IDENTITY
var pilot_input := Vector2.ZERO
var pilot_flap := false
var pilot_boost := false
var pilot_retract := false
var _piloted_for := 0.0
var _visual_pitch := 0.0

func pilot(model: RefCounted = null, resuming := false) -> bool:
	if pony.identity == null or not pony.identity.has_wings(): reason = "No wings"; return false
	if active(): return state == "piloted"
	if model == null: model = preload("res://player/wing_flight.gd").new()
	if model.charge < 1.0 and not resuming: reason = "Rest or glide to recover wing stamina"; return false
	if not _prepare_visuals(): reason = "Flight wings unavailable"; return false
	home = pony.global_position; destination = home
	pilot_model = model; _piloted_for = 0.0
	pilot_view = pony.global_basis; pilot_input = Vector2.ZERO
	pilot_flap = false; pilot_boost = false; pilot_retract = false
	pony.floor_snap_length = 0.0
	pony.velocity = (pilot_model.resume() if resuming else pilot_model.begin(pony.velocity / pony.body_scale, -pilot_view.z)) * pony.body_scale
	pose.choose("hover"); state = "piloted"; reason = "Piloted"
	return true

func _update_piloted(delta: float) -> void:
	var s: float = pony.body_scale
	_piloted_for += delta
	pony.velocity = pilot_model.step(pony.velocity / s, pilot_view, pilot_input,
		pilot_flap, pilot_boost, pilot_retract, delta) * s
	pony.move_and_slide()
	pony.actual_speed = Vector2(pony.velocity.x, pony.velocity.z).length()
	var flat := Vector3(pony.velocity.x, 0.0, pony.velocity.z)
	if flat.length() > 0.3:
		pony.rotation.y = lerp_angle(pony.rotation.y, atan2(-flat.x, -flat.z), 1.0 - exp(-delta * 10.0))
	if _piloted_for > PILOT_GRACE and pony.is_on_floor() and pony.velocity.y <= 0.0:
		destination = pony.global_position
		_finish()
		return
	# Keep the cyclic pose across a pending next beat instead of blending to glide
	# for a single boundary frame, then allocating another blend on the next tick.
	var next_beat: bool = pilot_flap and not pilot_retract and not pilot_model.landing and pilot_model.charge >= (1.5 if pilot_boost else 1.0)
	_animate(delta, "fly" if pilot_model.beating or next_beat else "glide")

func _is_dash() -> bool: return pony.identity != null and str(pony.identity.id) == "rainbow_dash"
func _top() -> float: return (DASH_CRUISE if _is_dash() else CRUISE) * pony.body_scale
func _accel() -> float: return (DASH_ACCEL if _is_dash() else ACCEL) * pony.body_scale * _boost
func _brake() -> float: return (DASH_BRAKE if _is_dash() else BRAKE) * pony.body_scale * _boost

func bind(actor: CharacterBody3D) -> void: pony = actor
func active() -> bool: return state != "grounded"

func _end_loop() -> void:
	if _loop_angle < 0.0: return
	pony.global_basis = Basis(Vector3.UP, atan2(-_loop_forward.x, -_loop_forward.z))
	_loop_angle = -1.0

func cancel() -> void:
	if state == "piloted" and pilot_model != null: pilot_model.finish()
	_end_loop()
	_end_show()
	_boost = 1.0
	_native_clear()
	state = "grounded"
	# A cancelled [hover] order is over: its leftover seconds made the next caught throw hover.
	hover_seconds = 0.0; _must_land = false; _stall = 0.0; _progress_for = 0.0; _progress_at = Vector3.INF
	if wings != null: wings.set_open(false)
	pony.floor_snap_length = .3 * pony.body_scale

func _prepare_visuals() -> bool:
	if wings == null:
		wings = WINGS.new(); pony.add_child(wings)
		if not wings.bind(pony): wings.queue_free(); wings = null; return false
	if pose == null: pose = POSE.new(); pose.bind(pony,false)
	_previous = pony.corrected_pose.duplicate(); _blend = 0.0
	_visual_pitch = 0.0
	wings.set_open(true)
	return true

## A thrown pegasus already has momentum: open the wings without a ground takeoff.
func catch_throw() -> bool:
	if pony.identity == null or not pony.identity.has_wings(): return false
	if not _prepare_visuals(): return false
	pony.floor_snap_length = 0.0
	home = pony.global_position; cruise_y = home.y
	_returning = false; _blocked = 0.0
	# Nothing from an earlier flight carries over: a stale hover time or hover point turned the
	# catch's last metre into an unbounded hover.
	hover_seconds = 0.0; _hover_at = Vector3.INF; _leg_goal = Vector3.INF
	loops = 0; _provisional = false
	_must_land = true; _settle_for = 0.0
	var forward := Vector3(pony.velocity.x,0,pony.velocity.z).normalized()
	destination = Vector3.INF
	for distance in [8.0,4.0,12.0,0.0]:
		var at: Vector3 = home + forward * distance * pony.body_scale
		var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP,at - Vector3.UP * 8.0,pony.floor_mask | WATER_MASK,_own_rids())
		var hit := pony.get_world_3d().direct_space_state.intersect_ray(q)
		if hit.is_empty(): continue
		var floor_at := landing_surface(hit.position)
		if floor_at.is_finite() and clear_segment(home,floor_at):
			destination = floor_at; break
	if destination.is_finite():
		_route = [destination + Vector3.UP * (.8 * pony.body_scale),destination]
		state = "catching"
	else:
		# Over a cloud edge or unloaded floor, catch at this altitude. Never dive
		# to distant terrain or invent a landing. The player can grab her again.
		destination = home; state = "rescue_hover"
	pose.choose("glide"); reason = "Caught the throw"
	return true

func landing_surface(at: Vector3, departing_roof:=false) -> Vector3:
	if not at.is_finite(): return Vector3.INF
	var centre := Vector3.INF
	var radius: float = .35 * pony.body_scale
	for offset in [Vector3.ZERO,Vector3(radius,0,0),Vector3(-radius,0,0),Vector3(0,0,radius),Vector3(0,0,-radius)]:
		var query := PhysicsRayQueryParameters3D.create(at + offset + Vector3.UP * 1.0, at + offset - Vector3.UP * 2.0, pony.floor_mask | WATER_MASK, _own_rids())
		var hit := pony.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty() or hit.normal.y < cos(deg_to_rad(25.0)): return Vector3.INF
		if hit.collider is CollisionObject3D and hit.collider.collision_layer & WATER_MASK: return Vector3.INF
		if not departing_roof and pony.placement_recovery._roof(pony,hit):return Vector3.INF
		if not centre.is_finite(): centre = hit.position
		elif absf(hit.position.y - centre.y) > .18 * pony.body_scale: return Vector3.INF
	return centre

func clear_segment(from: Vector3, to: Vector3) -> bool:
	var shape := SphereShape3D.new(); shape.radius = .7 * pony.body_scale
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape; query.collision_mask = pony.floor_mask; query.exclude = _own_rids()
	query.transform = Transform3D(Basis.IDENTITY, from + Vector3.UP * (.8 * pony.body_scale))
	query.motion = to - from; query.margin = .02
	var space := pony.get_world_3d().direct_space_state
	if not space.intersect_shape(query,1).is_empty(): return false
	var motion := space.cast_motion(query)
	return motion.size() == 2 and motion[0] >= .999

## A capsule can stop beside scenery with the larger flight envelope touching it. A sweep
## then refuses every direction, including away from the obstacle. Move only along the live
## contact's outward normal, with the actual body still swept by move_and_collide. This is
## bounded physical separation, never a position reset or an exception for a normal route.
func _separate_contact(delta: float) -> bool:
	var shape := SphereShape3D.new(); shape.radius = .7 * pony.body_scale
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape; query.collision_mask = pony.floor_mask; query.exclude = _own_rids()
	query.transform.origin = pony.global_position + Vector3.UP * (.8 * pony.body_scale)
	query.margin = .02
	var contact := pony.get_world_3d().direct_space_state.get_rest_info(query)
	if contact.is_empty(): return false
	var normal: Vector3 = contact.normal
	if not normal.is_finite() or normal.length_squared() < .9: return false
	var movement: Vector3 = normal.normalized() * (.6 * pony.body_scale * delta)
	var before := pony.global_position
	pony.move_and_collide(movement)
	pony.velocity = Vector3.ZERO
	return pony.global_position.distance_squared_to(before) > 1e-8

## Ground height (terrain) under a point, or NAN.
func _terrain_y(at: Vector3) -> float:
	if not is_instance_valid(WorldTerrain.instance): return NAN
	return WorldTerrain.instance.height_at(at)

## Short trips fly 3 body heights up; long ones clear the highest ground on the way.
func request(at: Vector3, hover_for := 0.0, long_range := false, altitude := 3.0, allow_native := true) -> bool:
	if pony.get("thrown") != null and pony.thrown.active(): reason = "Recovering from a throw"; return false
	if active(): reason = "Already flying"; return false
	if pony.identity == null or not pony.identity.has_wings(): reason = "No wings"; return false
	if pony._held or pony.hoof_hold.active() or not pony._interaction.is_empty(): reason = "Physical interaction"; return false
	if pony.posture != null and pony.posture.active(): reason = "Stand before takeoff"; return false
	var start := landing_surface(pony.global_position,true) # A stranded pegasus may take off from a roof.
	var end := landing_surface(at)
	_provisional = false
	if long_range and not end.is_finite() and start.is_finite():
		var ground := _terrain_y(at)
		if is_finite(ground) and ground > WorldLayout.sea_level() + 1.0:
			end = Vector3(at.x, ground, at.z); _provisional = true
	if not start.is_finite() or not end.is_finite(): reason = "No safe landing footprint"; return false
	var reach_m := (6000.0 if long_range else 400.0) if _is_dash() else (600.0 if long_range else 200.0)
	if start.distance_to(end) > reach_m: reason = "Destination outside local flight range"; return false
	_trick = "loop"; _boost = 1.0; _circle_centre = Vector3.INF
	var native: Array[Vector3] = _native_route(start, end) if allow_native else ([] as Array[Vector3])
	if not native.is_empty():
		pony.set_sim_tier(pony.SimTier.HERO,0)
		if not _prepare_visuals(): _native_clear(); reason = "Flight wings unavailable"; return false
		home = start; destination = end; hover_seconds = hover_for
		cruise_y = native[0].y
		for point: Vector3 in native: cruise_y = maxf(cruise_y, point.y)
		_route = native
		_returning = false; _blocked = 0.0; _hover_at = Vector3.INF; _boomed = false
		loops = 0; _loop_angle = -1.0; _cruise_start = Vector3.INF
		_previous = pony.corrected_pose.duplicate(); _blend = 0.0
		pony.velocity = Vector3.ZERO; pony.floor_snap_length = 0.0
		wings.set_open(true); pose.choose("hover"); state = "takeoff"; reason = ""
		return true
	var height: float = maxf(start.y,end.y) + altitude * pony.body_scale
	if long_range:
		# Clear the terrain (and the trees on it) all along the way.
		var steps := ceili(start.distance_to(end) / 15.0)
		for i in steps + 1:
			var ground := _terrain_y(start.lerp(end, float(i) / maxf(1, steps)))
			if is_finite(ground): height = maxf(height, ground + 14.0)
	# A low cruise ran into the destination's own clouds and walls (Rainbow Dash's flight home
	# to the Cloudominium was "obstructed" every night): climb higher before giving up.
	var up := Vector3(start.x,height,start.z)
	var across := Vector3(end.x,height,end.z)
	var clear := false
	# Long trips climb out at an angle, moving off toward the destination, instead of rising
	# straight up like a lift for most of a minute.
	var flat := Vector2(end.x-start.x,end.z-start.z)
	for extra: float in [0.0, 6.0, 12.0, 20.0, 35.0]:
		var climb := height + extra - start.y
		var lead := minf(climb * 1.4, flat.length() * .4) if long_range and flat.length() > 1.0 else 0.0
		var off := flat.normalized() * lead if lead > 0.0 else Vector2.ZERO
		up = Vector3(start.x+off.x,height+extra,start.z+off.y); across = Vector3(end.x,height+extra,end.z)
		if clear_segment(start,up) and clear_segment(up,across) and clear_segment(across,end):
			height += extra; clear = true; break
	if not clear:
		reason = "Flight corridor is obstructed"; return false
	pony.set_sim_tier(pony.SimTier.HERO,0)
	if not _prepare_visuals(): reason = "Flight wings unavailable"; return false
	home = start; destination = end; cruise_y = height; hover_seconds = hover_for
	var glide := _glide_in(up, across, end)
	# Built as a typed array: [up] + glide is a plain Array, which Array[Vector3] refuses (the fun
	# flights failed to start with "Trying to assign an array of type Array").
	var route: Array[Vector3] = [up]
	if glide.is_empty(): route.append_array([across, end])
	else: route.append_array(glide)
	_route = route
	_returning = false; _blocked = 0.0; _hover_at = Vector3.INF; _boomed = false
	loops = 1 if long_range and randf() < .25 else 0
	_loop_angle = -1.0; _cruise_start = Vector3.INF
	_previous = pony.corrected_pose.duplicate(); _blend = 0.0
	pony.velocity = Vector3.ZERO; pony.floor_snap_length = 0.0
	wings.set_open(true); pose.choose("hover"); state = "takeoff"; reason = ""
	return true

## The way down (dev 2026-09-26: "a flying pony should never fly straight downwards while
## flapping their wings. they glide forwards"): from cruise height a forward glide, about 3 m
## ahead for every metre down, to a short flare just before the spot. [glide start, flare, end],
## or [] when that path is not clear (then the old corridor is used).
func _glide_in(up: Vector3, across: Vector3, end: Vector3) -> Array:
	var s: float = pony.body_scale
	var flat := Vector2(end.x - up.x, end.z - up.z)
	var drop := across.y - end.y
	if flat.length() < 2.0 * s or drop < 1.0 * s: return []
	var dir := Vector3(flat.x, 0, flat.y).normalized()
	var run := minf(drop * 3.0, flat.length() * 0.85)
	var start := Vector3(end.x, across.y, end.z) - dir * run
	var flare := end - dir * (1.4 * s) + Vector3.UP * (0.7 * s)
	if clear_segment(up, start) and clear_segment(start, flare) and clear_segment(flare, end):
		return [start, flare, end]
	return []

## A native 3D air route between a footprint and a landing spot (both live-checked by
## landing_surface): [takeoff, approach, flare, end], or [] when the baked air volume does not
## cover the trip or has no certified route (then the old corridors are tried). Takeoff rises
## straight into the first free air above the footprint; the approach sits above and behind the
## landing spot so the last part is the usual forward glide and flare, never a vertical drop.
func _native_route(start: Vector3, end: Vector3) -> Array[Vector3]:
	var none: Array[Vector3] = []
	var air: RefCounted = NATIVE_AIR.instance()
	if air == null or NATIVE_AIR.size_of(pony) > NATIVE_AIR.MAX_BODY_SCALE: return none
	var s: float = pony.body_scale
	var takeoff := Vector3.INF
	for lift: float in [2.0, 2.5, 3.0, 3.5, 4.0, 5.0, 6.0]:
		var point := start + Vector3.UP * lift * s
		if int(air.sample(point)) == NATIVE_AIR.FREE:
			if clear_segment(start, point): takeoff = point
			break
	if not takeoff.is_finite(): return none
	var flat := Vector2(end.x - start.x, end.z - start.z)
	var dir := Vector3(flat.x, 0, flat.y).normalized() if flat.length() > 0.5 else -pony.global_basis.z
	dir.y = 0.0; dir = dir.normalized()
	var flare := end - dir * (1.4 * s) + Vector3.UP * (0.7 * s)
	if not clear_segment(flare, end): return none
	for height: float in [2.5, 3.5, 5.0, 7.0]:
		# The glide: about 3 m forward for every metre down (_glide_in).
		var approach := end - dir * (3.0 * height * s) + Vector3.UP * height * s
		if int(air.sample(approach)) != NATIVE_AIR.FREE or not clear_segment(approach, flare): continue
		if _native_id == 0: _native_id = NATIVE_AIR.new_id()
		var plan: Dictionary = air.plan(_native_id, takeoff, approach, {"body_scale": s, "dash": _is_dash(), "half_extent": 0.75})
		if not bool(plan.get("prepared", false)):
			reason = "No native air route: %s" % str(plan.get("status_name", "?"))
			continue
		_native_leg = true
		return [takeoff, approach, flare, end]
	return none

func _native_clear() -> void:
	if _native_leg and _native_id != 0:
		var air: RefCounted = NATIVE_AIR.instance()
		if air != null: air.clear(_native_id)
	_native_leg = false

## The cruise on the native air route: the follower's velocity (already inside its turn, climb,
## glide and stopping limits, certified through the baked volume) moves her, the live sphere sweep
## stays authoritative, and the approach point hands over to the glide-in.
func _native_fly(delta: float) -> void:
	var air: RefCounted = NATIVE_AIR.instance()
	var command: Dictionary = air.step(_native_id, pony.global_position, pony.velocity, pony.rotation.y, delta, -1.0) if air != null else {"mode": NATIVE_AIR.FAILED}
	var mode := int(command.get("mode", NATIVE_AIR.FAILED))
	if mode == NATIVE_AIR.ARRIVED:
		_native_clear(); _route.pop_front(); state = "cruise"
	elif mode == NATIVE_AIR.FAILED:
		reason = "Air route failed (%s)" % str(command.get("reason", "?"))
		_native_clear(); land(); return
	var next: Vector3 = command.get("velocity", Vector3.ZERO)
	if not clear_segment(pony.global_position, pony.global_position + next * delta):
		pony.velocity = Vector3.ZERO; _blocked += delta
		reason = "Obstacle ahead; holding position"
		if _blocked > 2.0: _native_clear(); land(); return
	else:
		_blocked = 0.0; pony.velocity = next; pony.move_and_slide()
	pony.actual_speed = Vector2(pony.velocity.x, pony.velocity.z).length()
	if pony.actual_speed > .15:
		pony.rotation.y = lerp_angle(pony.rotation.y, atan2(-pony.velocity.x, -pony.velocity.z), 1.0 - exp(-delta * 4.0))
	var speed: float = pony.velocity.length()
	_animate(delta, "glide" if speed > 4.5 else ("fly" if speed > 1.5 else "hover"))
	_dash_effects()

## Takeoff, a loop-de-loop or two over nearby open ground, then land somewhere close.
func request_fun() -> bool:
	var from := pony.global_position
	var heading := -pony.global_basis.z; heading.y = 0.0
	for attempt in 8:
		var direction := heading.normalized().rotated(Vector3.UP, randf_range(-1.2, 1.2)) if heading.length_squared() > .01 else Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU)
		var at: Vector3 = from + direction * randf_range(22.0, 40.0) * pony.body_scale
		var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 12.0, at - Vector3.UP * 12.0, pony.floor_mask | WATER_MASK, _own_rids())
		var hit := pony.get_world_3d().direct_space_state.intersect_ray(q)
		if hit.is_empty(): continue
		if request(hit.position, randf_range(0.0, 2.0), false, randf_range(6.0, 9.0), false):
			loops = 1 if randf() < .6 else 2
			reason = "Flying for fun"
			return true
	return false

func _try_loop() -> bool:
	var forward := Vector3(pony.velocity.x, 0, pony.velocity.z)
	if forward.length() < 1.0: return false
	forward = forward.normalized()
	var radius: float = 3.0 * pony.body_scale
	var origin := pony.global_position
	var previous := origin
	for k in range(1, 9):
		var a := TAU * k / 8.0
		var point := origin + forward * radius * sin(a) + Vector3.UP * radius * (1.0 - cos(a))
		if not clear_segment(previous, point): return false
		previous = point
	_loop_origin = origin; _loop_forward = forward; _loop_radius = radius; _loop_angle = 0.0
	return true

## One vertical circle along the heading; the body pitches all the way round.
func _update_loop(delta: float) -> void:
	var speed: float = 6.0 * pony.body_scale
	_loop_angle = minf(TAU, _loop_angle + delta * speed / _loop_radius)
	var a := _loop_angle
	var tangent := (_loop_forward * cos(a) + Vector3.UP * sin(a)).normalized()
	var up := (-_loop_forward * sin(a) + Vector3.UP * cos(a)).normalized()
	pony.global_position = _loop_origin + _loop_forward * _loop_radius * sin(a) + Vector3.UP * _loop_radius * (1.0 - cos(a))
	pony.velocity = tangent * speed
	pony.global_basis = Basis(tangent.cross(up), up, -tangent)
	if _loop_angle >= TAU:
		pony.global_basis = Basis(Vector3.UP, atan2(-_loop_forward.x, -_loop_forward.z))
		pony.velocity = _loop_forward * speed
		_loop_angle = -1.0; loops -= 1; _cruise_start = pony.global_position

## Starts an air show: `moves` from SHOW_MOVES (at most SHOW_LIMIT), flown near `centre` (the
## audience; her own position when INF). False when no open sky or landing is found.
func request_show(moves: Array, centre := Vector3.INF) -> bool:
	var list: Array[String] = []
	for move in moves:
		var name := str(move)
		if name in SHOW_MOVES and list.size() < SHOW_LIMIT: list.append(name)
	if list.is_empty(): reason = "No air show figures"; return false
	var around: Vector3 = centre if centre.is_finite() else pony.global_position
	for attempt in 10:
		var dir := Vector3.FORWARD.rotated(Vector3.UP, TAU * attempt / 10.0 + randf() * 0.5)
		var ground: Vector3 = around + dir * randf_range(7.0, 11.0) * pony.body_scale
		var q := PhysicsRayQueryParameters3D.create(ground + Vector3.UP * 14.0, ground - Vector3.UP * 14.0, pony.floor_mask | WATER_MASK, _own_rids())
		var hit := pony.get_world_3d().direct_space_state.intersect_ray(q)
		if hit.is_empty(): continue
		if request(hit.position, 600.0, false, SHOW_ALTITUDE, false):
			_show = list; show_log.clear(); _show_centre = around; _show_point = Vector3.INF; _show_side = 1.0
			loops = 0
			reason = "Putting on an air show"
			return true
	reason = "No open sky for an air show"
	return false

func showing() -> bool:
	return not _show.is_empty() or _man_t >= 0.0

func _end_show() -> void:
	_show.clear(); _show_point = Vector3.INF
	if _man_t >= 0.0:
		_man_t = -1.0
		var heading := pony.velocity; heading.y = 0.0
		if heading.length() > .1: pony.global_basis = Basis(Vector3.UP, atan2(-heading.x, -heading.z))

## The next figure from the show point: broadside to the audience (toward them for the fly-by),
## in the first of four headings whose whole path is clear of terrain and buildings.
func _next_figure() -> void:
	var move: String = _show.pop_front()
	var at := pony.global_position
	var to_centre := Vector3(_show_centre.x - at.x, 0, _show_centre.z - at.z)
	var base: Vector3 = to_centre.normalized() if to_centre.length() > .5 else Vector3(-pony.global_basis.z.x, 0, -pony.global_basis.z.z).normalized()
	for attempt in 4:
		var heading: Vector3 = base if move == "flyby" else base.cross(Vector3.UP).normalized() * _show_side
		heading = heading.rotated(Vector3.UP, PI * 0.5 * attempt)
		var built := figure_path(move, at, heading, _show_centre, pony.body_scale)
		if built.is_empty(): break
		if _path_clear(built.points):
			_man_name = move; _man_points = built.points; _man_ups = built.ups
			_man_cum = PackedFloat32Array([0.0])
			for i in range(1, _man_points.size()): _man_cum.append(_man_cum[i - 1] + _man_points[i].distance_to(_man_points[i - 1]))
			_man_t = 0.0; _man_i = 0; _show_side = -_show_side
			reason = "Air show: " + move.replace("_", " ")
			return
	show_log.append(move + ":skipped")

func _path_clear(points: PackedVector3Array) -> bool:
	var s: float = pony.body_scale
	var debug := "--air-debug" in preload("res://world/dev_tools.gd").user_args()
	for i in range(1, points.size()):
		if not clear_segment(points[i - 1], points[i]):
			if debug: print("[air] blocked at sample ", i, " ", points[i], " from ", pony.global_position)
			return false
		# Never closer than a pony height to the ground under the figure.
		if i % 4 == 0 and not clear_segment(points[i], points[i] - Vector3.UP * 1.6 * s):
			if debug: print("[air] too low at sample ", i, " ", points[i])
			return false
	return true

func _update_figure(delta: float) -> void:
	var speed: float = SHOW_SPEED * pony.body_scale
	_man_t += speed * delta
	var last := _man_points.size() - 1
	if _man_t >= _man_cum[last]:
		var out := (_man_points[last] - _man_points[last - 1]).normalized()
		var level := Vector3(out.x, 0, out.z)
		if level.length() < .1: level = Vector3(-pony.global_basis.z.x, 0, -pony.global_basis.z.z)
		pony.global_position = _man_points[last]
		pony.global_basis = Basis(Vector3.UP, atan2(-level.x, -level.z))
		pony.velocity = level.normalized() * speed * 0.5
		show_log.append(_man_name)
		_man_t = -1.0; _hover_at = _show_point
		return
	while _man_i < last - 1 and _man_cum[_man_i + 1] < _man_t: _man_i += 1
	var span: float = maxf(_man_cum[_man_i + 1] - _man_cum[_man_i], 1e-4)
	var k := clampf((_man_t - _man_cum[_man_i]) / span, 0.0, 1.0)
	var position := _man_points[_man_i].lerp(_man_points[_man_i + 1], k)
	var forward := (_man_points[_man_i + 1] - _man_points[_man_i]).normalized()
	var up := _man_ups[_man_i].lerp(_man_ups[_man_i + 1], k)
	up = (up - forward * up.dot(forward))
	if up.length() < .05: up = pony.global_basis.y
	up = up.normalized()
	pony.velocity = forward * speed
	pony.global_position = position
	pony.global_basis = Basis(up.cross(forward).normalized(), up, -forward)

## One figure's path from `o` heading `f` (horizontal): {"points", "ups"} sampled along it, or {}
## (a fly-by or circle needs an audience). Pitch-only figures keep the pilot's head toward the
## inside of the curve (inverted at the top of a loop); rolls turn that about the heading; level
## turns bank into the curve.
static func figure_path(move: String, o: Vector3, f: Vector3, centre: Vector3, s: float) -> Dictionary:
	var u := Vector3.UP
	var r := f.cross(u).normalized()
	var points := PackedVector3Array()
	var rolls := PackedFloat32Array()
	var planar := true
	match move:
		"loop":
			var rad := 3.5 * s
			for i in 49:
				var a := TAU * i / 48.0
				points.append(o + f * rad * sin(a) + u * rad * (1.0 - cos(a))); rolls.append(0.0)
		"barrel_roll":
			var length := 10.0 * s
			for i in 41:
				var t := i / 40.0
				points.append(o + f * length * t + (u - u.rotated(f, TAU * t)) * 0.8 * s); rolls.append(TAU * t)
		"aileron_roll":
			for i in 33:
				var t := i / 32.0
				points.append(o + f * 9.0 * s * t); rolls.append(TAU * smoothstep(0.0, 1.0, t))
		"dive":
			for i in 41:
				var t := i / 40.0
				points.append(o + f * 16.0 * s * t - u * 6.0 * s * pow(sin(PI * t), 2.0)); rolls.append(0.0)
		"immelmann":
			var rad := 4.0 * s
			for i in 25:
				var a := PI * i / 24.0
				points.append(o + f * rad * sin(a) + u * rad * (1.0 - cos(a))); rolls.append(0.0)
			var top := o + u * rad * 2.0
			for i in range(1, 17):
				var t := i / 16.0
				points.append(top - f * 6.0 * s * t); rolls.append(PI * smoothstep(0.0, 1.0, t))
		"split_s":
			var rad := 4.0 * s
			for i in 17:
				var t := i / 16.0
				points.append(o + f * 6.0 * s * t); rolls.append(PI * smoothstep(0.0, 1.0, t))
			var start := o + f * 6.0 * s
			for i in range(1, 25):
				var a := PI * i / 24.0
				points.append(start + f * rad * sin(a) - u * rad * (1.0 - cos(a))); rolls.append(PI)
		"hammerhead":
			var r1 := 3.0 * s
			var climb := 6.0 * s
			var r2 := 1.0 * s
			for i in 13:
				var a := PI * 0.5 * i / 12.0
				points.append(o + f * r1 * sin(a) + u * r1 * (1.0 - cos(a))); rolls.append(0.0)
			var foot := o + f * r1 + u * r1
			for i in range(1, 9):
				points.append(foot + u * climb * i / 8.0); rolls.append(0.0)
			var top_centre := foot + u * climb - f * r2
			for i in range(1, 13):
				var a := PI * i / 12.0
				points.append(top_centre + f * r2 * cos(a) + u * r2 * sin(a)); rolls.append(0.0)
			var down := top_centre - f * r2
			for i in range(1, 9):
				points.append(down - u * climb * i / 8.0); rolls.append(0.0)
			var bottom := down - u * climb
			var turn_centre := bottom - f * r1
			for i in range(1, 13):
				var a := PI * 0.5 * i / 12.0
				points.append(turn_centre + f * r1 * cos(a) - u * r1 * sin(a)); rolls.append(0.0)
		"spiral_climb":
			planar = false
			var rad := 4.0 * s
			var c := o + r * rad
			for i in 61:
				var t := i / 60.0
				var phi := TAU * 1.5 * t
				points.append(c - r * rad * cos(phi) + f * rad * sin(phi) + u * 8.0 * s * t)
		"figure_eight":
			planar = false
			var a := 6.0 * s
			for i in 65:
				var th := TAU * i / 64.0
				points.append(o + f * a * sin(th) + r * a * sin(th) * cos(th))
		"flyby":
			if not centre.is_finite(): return {}
			planar = false
			var low := centre.y + 3.0 * s
			var across := Vector3(centre.x - o.x, 0, centre.z - o.z)
			for i in 41:
				var t := i / 40.0
				var p := o + across * 2.0 * t
				p.y = lerpf(o.y, low, sin(PI * t))
				points.append(p)
		"circle":
			planar = false
			var middle := centre if centre.is_finite() else o + f * 6.0 * s
			var off := Vector3(o.x - middle.x, 0, o.z - middle.z)
			var rad := clampf(off.length(), 5.0 * s, 8.0 * s)
			var start := atan2(off.z, off.x) if off.length() > .1 else 0.0
			for i in 49:
				var a := start + TAU * 1.25 * i / 48.0
				points.append(Vector3(middle.x, o.y, middle.z) + Vector3(cos(a), 0, sin(a)) * rad)
		_:
			return {}
	var ups := PackedVector3Array()
	var n := points.size()
	for i in n:
		var ahead := points[mini(i + 1, n - 1)] - points[maxi(i - 1, 0)]
		var t := ahead.normalized() if ahead.length() > 1e-5 else f
		if planar:
			ups.append(r.cross(t).normalized().rotated(t, rolls[i] if i < rolls.size() else 0.0))
		else:
			var up := u - t * u.dot(t)
			up = up.normalized() if up.length() > .2 else (ups[i - 1] if i > 0 else u)
			# Bank into the turn: the sideways part of the curve's bend tilts the head inward.
			var bend := points[mini(i + 1, n - 1)] + points[maxi(i - 1, 0)] - points[i] * 2.0
			var side := bend - t * bend.dot(t) - up * bend.dot(up)
			if side.length() > 1e-4: up = (up + side.normalized() * minf(side.length() * 6.0, 1.0)).normalized()
			ups.append(up)
	return {"points": points, "ups": ups}

## A trick on request (the AI's barrel_roll, circle_over, loop_de_loop and sonic_rainboom actions):
## takeoff toward open ground nearby (or near `centre` for circling), the trick once the cruise has
## room for it, then the usual glide in. False when no clear sky or landing is found.
func request_trick(kind: String, centre := Vector3.INF) -> bool:
	if kind == "rainboom": return _request_rainboom()
	if kind == "circle":
		if not centre.is_finite(): reason = "Nothing to circle"; return false
		var from := pony.global_position
		for attempt in 8:
			var around := Vector3.FORWARD.rotated(Vector3.UP, TAU * attempt / 8.0 + randf() * .4)
			var at: Vector3 = centre + around * randf_range(3.0, 5.0) * pony.body_scale
			var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 12.0, at - Vector3.UP * 12.0, pony.floor_mask | WATER_MASK, _own_rids())
			var hit := pony.get_world_3d().direct_space_state.intersect_ray(q)
			if hit.is_empty() or Vector2(hit.position.x - from.x, hit.position.z - from.z).length() < 2.0: continue
			if request(hit.position, 0.0, false, 6.0, false):
				_trick = "circle"; _circle_centre = centre; loops = 1
				reason = "Circling overhead"
				return true
		return false
	if not request_fun(): return false
	_trick = "barrel_roll" if kind == "barrel_roll" else "loop"
	loops = 1 if kind == "barrel_roll" else loops
	reason = "Showing off a barrel roll" if kind == "barrel_roll" else reason
	return true

func _try_trick() -> bool:
	match _trick:
		"barrel_roll": return _try_roll()
		"circle": return _try_circle()
		_: return _try_loop()

## A barrel roll: one full roll around her heading while she flies a short corkscrew forward.
func _try_roll() -> bool:
	var forward := Vector3(pony.velocity.x, 0, pony.velocity.z)
	if forward.length() < 1.0: return false
	forward = forward.normalized()
	var s: float = pony.body_scale
	var origin := pony.global_position
	var previous := origin
	for k in range(1, 9):
		var a := TAU * k / 8.0
		var point := origin + forward * (10.0 * s * k / 8.0) + (Vector3.UP - Vector3.UP.rotated(forward, a)) * 0.6 * s
		if not clear_segment(previous, point): return false
		previous = point
	_loop_origin = origin; _loop_forward = forward; _loop_radius = 0.6 * s; _loop_angle = 0.0
	return true

func _update_roll(delta: float) -> void:
	var s: float = pony.body_scale
	var speed: float = 7.0 * s
	_loop_angle = minf(TAU, _loop_angle + delta * speed / (10.0 * s) * TAU)
	var a := _loop_angle
	var up := Vector3.UP.rotated(_loop_forward, a)
	var position := _loop_origin + _loop_forward * (10.0 * s * a / TAU) + (Vector3.UP - up) * _loop_radius
	pony.velocity = (position - pony.global_position) / maxf(delta, 1e-4)
	pony.global_position = position
	pony.global_basis = Basis(up.cross(_loop_forward), up, -_loop_forward)
	if _loop_angle >= TAU:
		pony.global_basis = Basis(Vector3.UP, atan2(-_loop_forward.x, -_loop_forward.z))
		pony.velocity = _loop_forward * speed
		_loop_angle = -1.0; loops -= 1; _cruise_start = pony.global_position

## Laps over whoever asked: once the cruise brings her near the centre, a banked circle around it
## at her height (a lap and a quarter), then on to her landing beside them.
func _try_circle() -> bool:
	if not _circle_centre.is_finite(): return false
	var s: float = pony.body_scale
	var offset := Vector3(pony.global_position.x - _circle_centre.x, 0, pony.global_position.z - _circle_centre.z)
	if offset.length() > 9.0 * s: return false
	var radius := clampf(offset.length(), 4.0 * s, 7.0 * s)
	var start := atan2(offset.z, offset.x) if offset.length() > .1 else 0.0
	var centre := Vector3(_circle_centre.x, pony.global_position.y, _circle_centre.z)
	var previous := centre + Vector3(cos(start), 0, sin(start)) * radius
	if not clear_segment(pony.global_position, previous): return false
	for k in range(1, 17):
		var point := centre + Vector3(cos(start + TAU * k / 16.0), 0, sin(start + TAU * k / 16.0)) * radius
		if not clear_segment(previous, point): return false
		previous = point
	_loop_origin = centre; _circle_radius = radius; _circle_angle = start; _circle_turns = 0.0; _loop_angle = 0.0
	return true

func _update_circle(delta: float) -> void:
	var speed: float = 6.0 * pony.body_scale
	var step := delta * speed / _circle_radius
	_circle_angle += step; _circle_turns += step
	var position := _loop_origin + Vector3(cos(_circle_angle), 0, sin(_circle_angle)) * _circle_radius
	var tangent := Vector3(-sin(_circle_angle), 0, cos(_circle_angle))
	pony.velocity = tangent * speed
	pony.global_position = position
	# Banked into the turn (the centre is to her left).
	pony.global_basis = Basis(Vector3.UP, atan2(-tangent.x, -tangent.z)) * Basis(Vector3.BACK, 0.45)
	if _circle_turns >= TAU * 1.25:
		pony.global_basis = Basis(Vector3.UP, atan2(-tangent.x, -tangent.z))
		_loop_forward = tangent
		_loop_angle = -1.0; loops -= 1; _cruise_start = pony.global_position

## Rainbow Dash's sonic rainboom: straight up, a burst out over open ground past the sound barrier
## (rainbow_trail.gd's boom ring fires at SOUND_BARRIER), round and back to land where she began.
func _request_rainboom() -> bool:
	if not _is_dash(): reason = "Only Rainbow Dash can do a sonic rainboom"; return false
	if active(): reason = "Already flying"; return false
	var start := landing_surface(pony.global_position, true)
	if not start.is_finite(): reason = "No safe footprint to take off from"; return false
	var heading := -pony.global_basis.z; heading.y = 0.0
	if heading.length() < .1: heading = Vector3.FORWARD
	for attempt in 8:
		var direction := heading.normalized().rotated(Vector3.UP, TAU * attempt / 8.0)
		# Out 380 m and straight back: the turn at the far end is a hairpin she brakes into
		# (update's corner braking), so no point of the way back is skipped as already passed.
		var far := start + direction * 380.0
		var height := start.y + 40.0
		for i in 21:
			var ground := _terrain_y(start.lerp(far, i / 20.0))
			if is_finite(ground): height = maxf(height, ground + 30.0)
		var up := Vector3(start.x, height, start.z)
		far.y = height
		var route: Array[Vector3] = [up, far]
		if not clear_segment(start, up) or not clear_segment(up, far): continue
		if not request(start, 0.0, true, height - start.y, false): continue
		var glide := _glide_in(far, far, start)
		if glide.is_empty(): route.append_array([up, start])
		else: route.append_array(glide)
		_route = route
		destination = start; cruise_y = height
		_trick = "rainboom"; loops = 0; _boost = RAINBOOM_BOOST
		reason = "Going for a sonic rainboom"
		return true
	reason = "No open sky for a sonic rainboom"
	return false

## Arrive from the sky (a princess visit): she is already placed in the air; glide to just
## above `landing`, then land there.
func arrive(landing: Vector3) -> bool:
	if pony.identity == null or not pony.identity.has_wings(): reason = "No wings"; return false
	if active(): reason = "Already flying"; return false
	pony.set_sim_tier(pony.SimTier.HERO, 0)
	if not _prepare_visuals(): reason = "Flight wings unavailable"; return false
	home = landing; destination = landing; cruise_y = pony.global_position.y; hover_seconds = 0.0
	_route = [landing + Vector3.UP * (1.5 * pony.body_scale), landing]
	_returning = false; _blocked = 0.0; _provisional = false
	loops = 0; _loop_angle = -1.0; _cruise_start = Vector3.INF
	pony.velocity = Vector3.ZERO; pony.floor_snap_length = 0.0
	wings.set_open(true); pose.choose("glide"); state = "cruise"; reason = "Arriving"
	return true

func land() -> void:
	if not active(): return
	_native_clear()
	_end_show()
	if state == "piloted":
		# Glide down where she is: the descent and touchdown are the piloted path's.
		pilot_model.landing = true
		return
	if state == "rescue_hover":
		catch_throw()
		return
	_end_loop(); loops = 0; _boost = 1.0
	_returning = true
	_provisional = false
	_blocked = 0.0
	# Glide down and forward to the ground ahead; only straight below if nothing ahead is clear.
	var s: float = pony.body_scale
	var ahead := Vector3(pony.velocity.x, 0, pony.velocity.z)
	if ahead.length() < 0.5: ahead = -pony.global_basis.z; ahead.y = 0.0
	ahead = ahead.normalized()
	var probes: Array[Vector3] = []
	for distance: float in [8.0, 5.0, 12.0, 3.0]: probes.append(ahead * distance * s)
	# A blocked return must also look beside and behind the obstruction. The old one-shot
	# return only searched forward, then remained stuck forever on its new straight corridor.
	for distance: float in [8.0, 12.0, 18.0, 26.0, 38.0, 54.0]:
		for i in range(1, 8): probes.append(ahead.rotated(Vector3.UP, TAU * i / 8.0) * distance * s)
	for offset: Vector3 in probes:
		var direction := offset.normalized()
		var probe := pony.global_position + offset
		var q := PhysicsRayQueryParameters3D.create(probe + Vector3.UP, probe - Vector3.UP * 160.0, pony.floor_mask | WATER_MASK, _own_rids())
		var hit := pony.get_world_3d().direct_space_state.intersect_ray(q)
		if hit.is_empty(): continue
		var spot := landing_surface(hit.position)
		var flare := spot - direction * (1.4 * s) + Vector3.UP * (0.7 * s) if spot.is_finite() else Vector3.INF
		if spot.is_finite() and clear_segment(pony.global_position, flare) and clear_segment(flare, spot):
			destination = spot; _route = [flare, spot]; state = "cruise"; hover_seconds = 0.0
			return
	var below := landing_surface(pony.global_position - Vector3.UP * (3.0 * pony.body_scale))
	if below.is_finite() and clear_segment(pony.global_position,below):
		destination = below; state = "landing"; hover_seconds = 0.0
	else:
		# Native cruise may have gone around a building: the line home is not its corridor.
		# Replan in the air volume, or certify every leg of the legacy return before using it.
		var safe_home := landing_surface(home)
		if safe_home.is_finite():
			var native := _native_route(pony.global_position, safe_home)
			if not native.is_empty():
				destination = safe_home; _route = native; state = "takeoff"; hover_seconds = 0.0
				return
			var up := Vector3(pony.global_position.x, cruise_y, pony.global_position.z)
			var across := Vector3(safe_home.x, cruise_y, safe_home.z)
			if clear_segment(pony.global_position, up) and clear_segment(up, across) and clear_segment(across, safe_home):
				destination = safe_home; _route = [up, across, safe_home]; state = "takeoff"; hover_seconds = 0.0
				return
		# Hold the actual position and retry when live geometry changes. This remains flight
		# owned; placement recovery must not teleport an airborne pony through a building.
		destination = pony.global_position; _route.clear(); pony.velocity = Vector3.ZERO
		state = "recovery_hover"; _recovery_retry = 1.0; hover_seconds = 0.0
		reason = "No clear landing corridor; searching from the air"

func update(delta: float) -> void:
	if not active(): return
	if state == "piloted":
		_update_piloted(delta)
		return
	if pony._held or pony.hoof_hold.active():
		# Player hand owns the body; resume safe return once released.
		_end_loop()
		pony.velocity = Vector3.ZERO
		return
	if state in ["takeoff", "cruise", "landing", "catching"] and _loop_angle < 0.0:
		_progress_for += delta
		if pony.global_position.distance_squared_to(_progress_at) > .25 * pony.body_scale * pony.body_scale:
			_progress_at = pony.global_position; _progress_for = 0.0
		elif _progress_for > PROGRESS_SECONDS:
			# Held still by a native follower HOLD, a corner or a refused last metre: land now.
			print("[pony] %s flight made no progress for %.0f s (%s); landing" % [pony.name, _progress_for, state])
			_progress_for = 0.0; _must_land = true
			land(); return
	else: _progress_for = 0.0
	if _must_land or state in ["recovery_hover", "settle"]: _stall += delta
	else: _stall = 0.0
	if state == "settle":
		_update_settle(delta)
		return
	if _stall > RESCUE_SECONDS and state != "rescue_hover":
		_end_loop(); _native_clear(); loops = 0; _boost = 1.0
		_route.clear(); state = "settle"; _settle_for = 0.0
		reason = "Settling down"
		print("[pony] %s settling down after %.0f s without a landing" % [pony.name, _stall])
		_update_settle(delta)
		return
	if state == "recovery_hover":
		if _separate_contact(delta):
			_recovery_retry = minf(_recovery_retry, .1)
		_recovery_retry -= delta
		if _recovery_retry <= 0.0: land()
		_animate(delta, "hover")
		return
	if _man_t >= 0.0:
		_update_figure(delta)
		_animate(delta, "fly")
		return
	if state == "hover" and not _show.is_empty():
		# Between figures she hangs at the show point; the next starts once she is back there.
		hover_seconds = maxf(hover_seconds, 5.0)
		if not _show_point.is_finite():
			# A short hop never climbs: the show point is SHOW_ALTITUDE over the ground beneath her
			# (or above her, if a roof or tree is lower), and she rises there before the first figure.
			var here: Vector3 = _hover_at if _hover_at.is_finite() else pony.global_position
			var q := PhysicsRayQueryParameters3D.create(here + Vector3.UP * 2.0, here - Vector3.UP * 60.0, pony.floor_mask | WATER_MASK, _own_rids())
			var below := pony.get_world_3d().direct_space_state.intersect_ray(q)
			var ground_y: float = (below.position as Vector3).y if not below.is_empty() else here.y - 2.0
			var want := Vector3(here.x, ground_y + SHOW_ALTITUDE * pony.body_scale, here.z)
			var up := PhysicsRayQueryParameters3D.create(here + Vector3.UP * 0.5, want + Vector3.UP * 2.0, pony.floor_mask, _own_rids())
			var ceiling := pony.get_world_3d().direct_space_state.intersect_ray(up)
			if not ceiling.is_empty(): want.y = (ceiling.position as Vector3).y - 2.5 * pony.body_scale
			_show_point = want; _hover_at = want
		if pony.global_position.distance_to(_show_point) < 1.5 * pony.body_scale and pony.velocity.length() < 4.0 * pony.body_scale:
			_next_figure()
			if _man_t >= 0.0: return
	elif state == "hover" and _show_point.is_finite() and _show.is_empty() and _man_t < 0.0:
		# The show is over: down to the landing beside the audience.
		_show_point = Vector3.INF; hover_seconds = minf(hover_seconds, 0.3)
	if _loop_angle >= 0.0:
		match _trick:
			"barrel_roll": _update_roll(delta)
			"circle": _update_circle(delta)
			_: _update_loop(delta)
		_animate(delta, "glide" if _trick == "circle" else "fly")
		return
	if _native_leg and state in ["takeoff", "cruise"] and _route.size() == 3:
		_native_fly(delta)
		return
	var goal: Vector3
	if state == "rescue_hover":
		goal = destination
	elif state == "hover":
		hover_seconds -= delta
		if not _hover_at.is_finite(): _hover_at = pony.global_position
		goal = _hover_at
		# The hover ends: this tick already aims at the ground. Aiming at the hover point she is at
		# counted as "landed" and snapped her down metres in one frame.
		if hover_seconds <= 0.0: state = "landing"; goal = destination
	elif state == "landing": goal = destination
	else: goal = _route[0]
	var offset := goal - pony.global_position
	# Brake for what is left of the whole route, not for every waypoint on it.
	var remaining := offset.length()
	# A sharp turn ahead (over 60 degrees) is braked into: the distance to brake over ends there,
	# with a corner speed she can turn at. Otherwise the whole rest of the route counts.
	var corner_speed := 0.0
	if state in ["takeoff", "cruise", "catching"]:
		var from := pony.global_position
		for i in range(0, _route.size() - 1):
			var into := _route[i] - from
			var out := _route[i + 1] - _route[i]
			if into.length() > .5 and out.length() > .5 and into.angle_to(out) > deg_to_rad(60.0):
				corner_speed = 8.0 * pony.body_scale
				break
			remaining += out.length()
			from = _route[i]
	var speed: float = minf(_top(), sqrt(corner_speed * corner_speed + 2.0 * _brake() * remaining))
	# Gentle near the ground; once clear of it a long climb speeds up.
	var near_ground: bool = state == "landing" or pony.global_position.y - home.y < 4.0 * pony.body_scale
	if state in ["takeoff","landing"] and near_ground: speed = minf(speed,1.8 * pony.body_scale)
	elif state == "takeoff": speed = minf(speed,maxf(3.5 * pony.body_scale, _top() * 0.25))
	if state == "landing" and not _provisional and not landing_surface(destination).is_finite():
		pony.velocity = Vector3.ZERO; state = "hover"; hover_seconds = 2.0
		reason = "Landing surface unavailable; holding altitude"
		land(); return
	var wanted := offset.normalized() * speed if offset.length() > .02 else Vector3.ZERO
	var next := pony.velocity.move_toward(wanted,_accel() * delta)
	if not clear_segment(pony.global_position,pony.global_position + next * delta):
		pony.velocity = Vector3.ZERO; _blocked += delta
		reason = "Obstacle ahead; holding position"
		if _blocked > 2.0:
			_separate_contact(delta)
			land(); return
	else:
		_blocked = 0.0; pony.velocity = next; pony.move_and_slide()
	pony.actual_speed = Vector2(pony.velocity.x,pony.velocity.z).length()
	if pony.actual_speed > .15:
		var yaw := atan2(-pony.velocity.x,-pony.velocity.z)
		pony.rotation.y = lerp_angle(pony.rotation.y,yaw,1.0-exp(-delta*4.0))
	# A waypoint is passed once within a frame's travel of it or behind her (at hundreds of m/s
	# she never comes within a few centimetres of it).
	var step: float = pony.velocity.length() * delta * 1.5
	# Beyond the waypoint along her leg to it (from where she was when it became her waypoint),
	# not merely behind her velocity: right after a hairpin the next waypoint is behind her
	# velocity but still ahead along its leg, and skipping it sent her crawling home in landing.
	if not _leg_goal.is_equal_approx(goal): _leg_goal = goal; _leg_from = pony.global_position
	var overshot: bool = (pony.global_position - goal).dot(goal - _leg_from) > 0.0
	var passed: bool = offset.length() < maxf(.12, step) or (state != "landing" and pony.velocity.length() > 3.0 and overshot)
	if passed:
		if state == "landing":
			_finish(); return
		elif state not in ["hover","rescue_hover"]:
			_route.pop_front()
			if _route.size() >= 2: state = "cruise"
			elif _route.size() == 1: state = "hover" if hover_seconds > 0.0 else "landing"
	if state == "cruise" and loops > 0 and _trick == "circle":
		# Circling starts as soon as she is close to whoever she circles, however short the hop.
		_try_trick()
	elif state == "cruise" and loops > 0:
		if not _cruise_start.is_finite(): _cruise_start = pony.global_position
		if pony.global_position.distance_to(_cruise_start) > 6.0 * pony.body_scale and offset.length() > 12.0 * pony.body_scale:
			if not _try_trick(): _cruise_start = pony.global_position
	var clip := "hover"
	if state == "catching": clip = "glide"
	if state == "cruise" and pony.velocity.length() > 1.5:
		clip = "glide" if pony.velocity.length() > 4.5 and (offset.length() > 8.0 or pony.velocity.y < -0.5) else "fly"
	_animate(delta, clip)
	_dash_effects()

## Bounded way down: straight down at a gentle hover sink, moved by move_and_slide so the real
## capsule (not the larger corridor sphere that kept refusing the last metre) meets the floor.
## Lands where she touches; with no floor below in time, placement recovery's rescue hover.
func _update_settle(delta: float) -> void:
	_settle_for += delta
	pony.velocity = Vector3.DOWN * (1.5 * pony.body_scale)
	pony.move_and_slide()
	pony.actual_speed = 0.0
	if pony.is_on_floor():
		destination = pony.global_position
		_finish(); return
	if _settle_for > SETTLE_SECONDS:
		destination = pony.global_position; pony.velocity = Vector3.ZERO
		state = "rescue_hover"; _must_land = true
		reason = "Nothing to land on below"
	_animate(delta, "hover")

## Rainbow Dash: her rainbow trail when she is really moving, and a sonic rainboom the moment she
## passes the speed of sound.
func _dash_effects() -> void:
	if not _is_dash(): return
	var speed: float = pony.velocity.length()
	if _trail == null or not is_instance_valid(_trail):
		if speed < 18.0: return
		_trail = TRAIL.new()
		var scene: Node = pony.get_tree().current_scene if pony.get_tree().current_scene != null else pony.get_tree().root
		scene.add_child(_trail)
	_trail.feed(pony.global_position + Vector3.UP * 0.55 * pony.body_scale, pony.velocity, speed > 18.0 * pony.body_scale, pony.body_scale)
	if speed > SOUND_BARRIER and not _boomed:
		_boomed = true
		_trail.rainboom(pony.global_position + Vector3.UP * 0.55 * pony.body_scale, pony.velocity)

func _animate(delta: float, clip: String) -> void:
	# Slow vertical flapping uses the authored hanging-leg hover. Retain player
	# glides between beats; posing must not invent a wingbeat or spend stamina.
	if _loop_angle < 0.0 and (clip == "fly" or (clip == "glide" and state != "piloted")):
		var motion: Vector3 = pony.velocity / pony.body_scale
		var hover_limit := 2.4 if pose.clip == "hover" else 1.6
		var descent_limit := -10.0 if pose.clip == "hover" else -8.0
		if motion.is_finite() and Vector2(motion.x,motion.z).length() < hover_limit and motion.y > descent_limit:
			clip = "hover"
	if pose.clip != clip:
		_previous = pony.corrected_pose.duplicate(); _blend = 0.0; pose.choose(clip)
	if state == "piloted" and pilot_model != null and (clip == "fly" or clip == "hover"):
		pose.seek(pilot_model.phase * float(pose.clips[clip].length))
	else:
		pose.playing = true
		pose.advance(delta)
	_blend = minf(1.0,_blend+delta/.3)
	if _blend < 1.0:
		var weight := smoothstep(0.0, 1.0, _blend)
		for i in pony.corrected_pose.size():
			pony.corrected_pose[i] = _previous[i].interpolate_with(pony.corrected_pose[i], weight)
	pony.modifier.prepared = pony.corrected_pose
	_apply_direction_pose(delta)
	pony._apply_body_scale()

## Flight pose sampling clears the visual pivot. Slow vertical flight stays level;
## forward flight follows its path, with steep pitch reserved for fast dives.
## Physics/camera yaw and grounded hoof leveling retain their existing ownership.
func _apply_direction_pose(delta: float) -> void:
	if _loop_angle >= 0.0:
		# Authored tricks already rotate the actor's full basis.
		_visual_pitch = 0.0
		return
	var velocity: Vector3 = pony.velocity / pony.body_scale
	var wanted := 0.0
	if velocity.is_finite() and velocity.length_squared() > .25:
		var horizontal := Vector2(velocity.x,velocity.z).length()
		var inclination := smoothstep(2.0,6.0,horizontal)
		if pose.clip == "glide":
			inclination = maxf(inclination,smoothstep(8.0,16.0,-velocity.y))
		wanted = clampf(atan2(velocity.y,horizontal),deg_to_rad(-75.0),deg_to_rad(35.0)) * inclination
	_visual_pitch = lerp_angle(_visual_pitch,wanted,1.0-exp(-maxf(delta,0.0)*10.0))
	var bank: float = pilot_model.bank_angle if state == "piloted" and pilot_model != null else 0.0
	pony.pivot.basis = Basis(Vector3.RIGHT,_visual_pitch) * Basis(Vector3.FORWARD,bank)

func _finish() -> void:
	if state == "piloted" and pilot_model != null: pilot_model.finish()
	_native_clear()
	_boost = 1.0
	_must_land = false; _stall = 0.0; _progress_for = 0.0; _progress_at = Vector3.INF
	state = "grounded"; wings.set_open(false)
	if _trail != null and is_instance_valid(_trail): _trail.feed(pony.global_position, Vector3.ZERO, false, pony.body_scale)
	pony.floor_snap_length = .3 * pony.body_scale
	pony.velocity = Vector3.ZERO
	pony.reset_motion(Transform3D(pony.global_basis,destination+Vector3.UP*.02))
	reason = "Landed"
