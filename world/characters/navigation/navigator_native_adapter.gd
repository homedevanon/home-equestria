extends RefCounted
## The less frequent half of pony_navigator.gd's native follower adapter (split 2026-10-13):
## registering her native actor, its limits, sending a new corridor, clearing it, diagnostics and
## the follower's low-frequency events. The per-tick half (_native_tick, _native_apply) stays in
## the navigator, beside the state the batch driver reads from it by name.

const NATIVE_BACKEND := preload("res://world/navigation/native_navigation_backend.gd")


## The native actor for this pony in its service's native world (shared with its route searches);
## the navigator's _native_ready() calls this only when the handle is missing or stale.
static func register(nav: Node) -> bool:
	if nav._native_active: nav._native_clear()
	var service: Variant = nav._service
	var pony: CharacterBody3D = nav.pony
	var handle: PackedInt64Array = service.native_follow_actor(nav, pony.profile) if is_instance_valid(service) else PackedInt64Array()
	nav._native_handle = handle
	nav._native_service = service
	if handle.size() != 2:
		# Loud, once per navigator, and never a silent stop: this pony keeps the legacy steering.
		var message := "%s: the native follower could not register her; using the GDScript steering" % pony.name
		push_error(message)
		printerr(message)
		nav.native_follow = false
		return false
	nav._configure_native_limits()
	return true


static func configure_limits(nav: Node) -> void:
	# follow_configure replaces all limits; keep the complete original setup
	# when a leased activity changes its arrival distance on an existing actor.
	var native: RefCounted = NATIVE_BACKEND.instance()
	var pony: CharacterBody3D = nav.pony
	var locomotion: Resource = pony.profile
	var handle: PackedInt64Array = nav._native_handle
	var body_scale: float = float(pony.get("body_scale")) if pony.get("body_scale") != null else 1.0
	native.follow_configure(handle[0], handle[1], {
		"accel": float(locomotion.acceleration), "braking": float(locomotion.braking),
		"yaw_rate_max": float(pony.get("steer_turn_rate")), "lateral_accel": float(locomotion.lateral_acceleration),
		"step_turn_rate": float(locomotion.stepping_turn_rate), "walk_speed": float(locomotion.walk_speed.y),
		"approach_distance": nav.approach_distance, "arrival_radius": nav.arrival_distance,
		"capsule_radius": 0.19 * body_scale, "body_radius": float(locomotion.radius)})


static func send_corridor(nav: Node, terminal: bool) -> void:
	var native: RefCounted = NATIVE_BACKEND.instance()
	var pony: CharacterBody3D = nav.pony
	nav._native_route += 1
	var authored: bool = nav._native_authored
	var options := {"route": nav._native_route, "intent": nav._native_intent, "terminal": terminal, "authored": authored}
	nav._native_sent_authored = authored
	if terminal: options["goal"] = nav._live_goal
	var velocity: Vector3 = pony.get("_ground_velocity") if pony.get("_ground_velocity") is Vector3 else pony.velocity
	var handle: PackedInt64Array = nav._native_handle
	var path: PackedVector3Array = nav.path
	var reply: Dictionary = native.follow_set_corridor(handle[0], handle[1], path, options,
		pony.global_position, pony.rotation.y, velocity)
	nav._native_serial = nav._path_serial
	nav._native_terminal = terminal
	nav._native_active = bool(reply.get("accepted", false))
	if not nav._native_active:
		nav._halt()
		nav.state = nav.State.WAITING
		nav.reason = "Route corridor refused: %s" % str(reply.get("reason", "?"))
		nav._needs_path = true
		return
	# Godot 4.5 only forwards avoidance velocity after a target is submitted.
	# Indoor/direct corridors bypass _path_ready(), so they otherwise receive zero
	# answers forever and crawl at the native follower's missing-avoidance speed.
	# Set once per accepted corridor; native paths still own all route following.
	nav.agent.target_position = path[-1]
	# Arrival that cannot reach the requested spot is told apart up front.
	if terminal and bool(reply.get("alternative", false)): nav.arrival_alternative = true


## Diagnostics for traces and labs (a Dictionary per call: not for every tick of normal play).
static func follow_state(nav: Node) -> Dictionary:
	var native: RefCounted = NATIVE_BACKEND.instance()
	var handle: PackedInt64Array = nav._native_handle
	if native == null or handle.size() != 2: return {"live": false}
	return native.follow_state(handle[0], handle[1])


static func clear(nav: Node) -> void:
	nav._native_active = false
	nav._native_serial = -1
	nav._native_wait = ""
	var native: RefCounted = NATIVE_BACKEND.instance()
	var handle: PackedInt64Array = nav._native_handle
	if native != null and handle.size() == 2:
		native.follow_clear(handle[0], handle[1])


## Low-frequency follower events for this pony's current intent.
static func on_event(nav: Node, event: Dictionary) -> void:
	if int(event.get("intent", -1)) != nav._native_intent or not nav._has_target: return
	match int(event.get("kind", 0)):
		1: # arrived
			# At a bridge entry point (navigator_routes.gd ENTRY_REACH): only that leg is done.
			var via: Array = nav._journey_via
			if nav._journey_goal.is_finite() and via.size() > 1 and Vector2(nav.target.x - via[0].x, nav.target.z - via[0].z).length() < .5:
				via.pop_front()
				nav._next_leg()
				return
			nav.arrival_alternative = nav.arrival_alternative or bool(event.get("alternative", false))
			nav._has_target = false
			nav._journey_goal = Vector3.INF
			nav._journey_via = []
			nav._approaching_player = false
			nav.state = nav.State.ARRIVED
			nav.reason = "Arrived near the destination" if nav.arrival_alternative else "Arrived"
			if nav._wandering:
				nav._begin_rest()
			nav.arrived.emit()
			nav._halt()
		3, 4: # replan / alternate route around the obstruction evidence
			var blocked: PackedFloat32Array = event.get("blocked", PackedFloat32Array())
			nav._native_blocked = blocked
			# Held by ponies: the search also goes round the ones standing on her way (fresh discs
			# only; the native evidence above never carries ponies).
			var peers: PackedFloat32Array = event.get("peer_blocked", PackedFloat32Array())
			if not peers.is_empty():
				nav._peer_discs = peers
				nav._peer_discs_msec = Time.get_ticks_msec()
			nav._cancel_queries()
			nav._needs_path = true
			nav.reason = str(event.get("reason", "Replanning"))
		5: # one terminal failure
			if nav._wandering:
				# A wanderer has no stake in that spot: rest, then go somewhere else.
				nav._has_target = false
				nav._approaching_player = false
				nav.path = PackedVector3Array()
				nav._idle_time = randf_range(8.0, 16.0)
				nav.state = nav.State.IDLE
				nav.reason = "Blocked; picking another destination"
				nav._halt()
				return
			nav._fail(str(event.get("reason", "Blocked")), nav.State.BLOCKED)
		6: # off the corridor
			nav._cancel_queries()
			nav._needs_path = true
			nav.reason = "Replanning from where she is"
