extends RefCounted
## A free pony's own outings (split from pony_navigator.gd, 2026-10-13): wander destinations,
## rests between them, company visits, the rare visit to the player and the occasional glance.
## State stays on the navigator; calls back into it go through `nav.` so overrides still apply.

const DAILY := preload("res://world/ai/pony_daily_activity.gd")
const REST_PLACEMENT := preload("res://world/navigation/rest_placement.gd")


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


static func pick_wander_point(nav: Node, _map: RID) -> void:
	if nav._wander_request >= 0: return
	nav._idle_time = nav._ordinary_rest()
	var pony: CharacterBody3D = nav.pony
	var service: WalkGridService = nav._service
	if nav._may_approach_player():
		var attention: Node3D = nav.attention_target
		var to_player := attention.global_position - pony.global_position; to_player.y = 0.0
		var destination := attention.global_position - to_player.normalized() * 2.0
		destination.y = pony.global_position.y
		var snapped := service.closest(destination, pony.profile, 1.5)
		if snapped.is_finite() and absf(snapped.y - pony.global_position.y) < pony.profile.hip_height:
			nav.go_to(snapped, nav.Gait.WALK)
			nav._approaching_player = true; nav._wandering = true
			nav._wander_intent = "Visiting you"
			nav._wander_time = randf_range(24.0, 36.0)
			nav._approach_cooldown = randf_range(60.0, 120.0)
			return
	if nav._try_company_visit(): return
	var heading := -pony.global_basis.z
	nav._wander_request = service.request_wander(pony.global_position, nav.outgoing_radius(), pony.profile, Callable(nav, "_wander_ready"), nav._spot, nav._home, nav.outgoing_leash(),
		{"heading": heading, "recent": nav._recent_wanders, "intent": nav._wander_intent})


static func wander_ready(nav: Node, result: Dictionary, request_id: int, completed_revision: int) -> void:
	if request_id != nav._wander_request: return
	nav._wander_request = -1
	if not nav.wander_enabled: return
	if result.get("stale", false) or completed_revision != nav._service.revision:
		nav._idle_time = 2.0
		return
	var destination: Vector3 = result.get("destination", Vector3.INF)
	if not destination.is_finite():
		# Cold ground is not a completed outing followed by a long rest.
		nav._idle_time = 2.0
		return
	var pony: CharacterBody3D = nav.pony
	if REST_PLACEMENT.passage(nav.get_tree(), destination, pony.profile.radius):
		nav._idle_time = 1.0
		return
	nav._wander_intent = str(result.get("intent", "Exploring somewhere new"))
	var recent: Array[Vector3] = nav._recent_wanders
	recent.push_front(destination)
	if recent.size() > 6: recent.pop_back()
	# Pegasi sometimes fly instead of walking, and now and then just for fun, loops included.
	var owner: String = nav.command_owner
	if (owner.is_empty() or owner.begins_with("life:")) and pony.has_method("request_flight") and pony.identity != null and pony.identity.has_wings():
		var joyride: bool = randf() < .1 * lerpf(.3, 1.0, nav.daytime_activity()) and pony.has_method("request_fun_flight") and pony.request_fun_flight()
		if joyride or (pony.global_position.distance_to(destination) > 18.0 and randf() < .2 and pony.request_flight(destination)):
			nav._cancel_queries(); nav._has_target = false; nav._wandering = false; nav.path = PackedVector3Array()
			nav.state = nav.State.IDLE; nav.reason = "Flying for fun" if joyride else "Flying there"
			nav._idle_time = 12.0
			return
	nav.go_to(destination, nav.Gait.TROT if randf() < nav.wander_trot_share * lerpf(.2, 1.0, nav.daytime_activity()) else nav.Gait.WALK)
	nav._wandering = true
	nav._pick_pace()
	var seconds: Vector2 = nav.wander_seconds
	nav._wander_time = randf_range(seconds.x, seconds.y)


static func begin_rest(nav: Node, duration: float) -> void:
	nav._cancel_queries()
	nav._has_target = false
	nav._needs_path = false
	nav._wandering = false
	nav.path = PackedVector3Array()
	nav._idle_time = duration if duration >= 0.0 else nav._ordinary_rest()
	var pony: CharacterBody3D = nav.pony
	var tree: SceneTree = nav.get_tree()
	if REST_PLACEMENT.passage(tree, pony.global_position, pony.profile.radius):
		nav._idle_time = 0.0
		nav._rest_sit_pending = false
		nav.state = nav.State.IDLE
		nav.reason = "Finding somewhere clear of the entrance"
		nav._reset_lookahead()
		nav._halt()
		return
	nav._rest_sit_pending = randf() < DAILY.rest_probability(nav.sit_chance, nav.daytime_activity())
	nav._rest_posture = DAILY.rest_kind(randf())
	if nav._rest_sit_pending and duration < 0.0:
		var span := DAILY.seated_span(nav.daytime_activity())
		nav._idle_time = randf_range(span.x, span.y)
		# A bench, picnic table or stump close by beats sitting in the grass.
		var seating: Node = tree.get_first_node_in_group("pony_seating")
		if nav._rest_posture == "sit" and seating != null and randf() < 0.7 and seating.sit(pony, 18.0):
			nav._rest_sit_pending = false
			nav._idle_time += 15.0
			nav.state = nav.State.WAITING; nav.reason = "Going to sit on a bench"
			return
	nav.state = nav.State.IDLE
	nav.reason = "Resting"
	nav._approaching_player = false
	nav._reset_lookahead()
	nav._halt()


static func may_approach_player(nav: Node) -> bool:
	var attention: Variant = nav.attention_target
	if nav._approach_cooldown > 0.0 or not is_instance_valid(attention) or randf() >= nav.approach_player_chance:
		return false
	var pony: CharacterBody3D = nav.pony
	var distance := _flat(pony.global_position, attention.global_position)
	var approaching := 0
	for navigator in nav.get_tree().get_nodes_in_group("pony_navigators"):
		if navigator != nav and bool(navigator.get("_approaching_player")): approaching += 1
	# The attention target is normally the player's HMD, about 1.7 m above their
	# floor. Destination snapping below remains the ground/reachability authority.
	if approaching >= 2 or distance <= 3.0 or distance >= 12.0 \
		or absf(attention.global_position.y - pony.global_position.y) >= 2.5:
		return false
	return not player_in_conversation(nav)


## True while Anon is talking with any pony (the director's engaged(): she is speaking or thinking
## now, or he talked with her lately and she still hears him). No pony walks up to stand beside him
## then (player board #55: during a long chat these visits gathered an audience of a dozen ponies).
## The director's own greeting walk-ups already wait for a chat in the same way
## (pony_player_approaches.gd). Asked only when a visit would otherwise start, which is rare.
static func player_in_conversation(nav: Node) -> bool:
	if not nav.is_inside_tree(): return false
	var director: Node = nav.get_tree().get_first_node_in_group("conversation_director")
	if director == null or not director.has_method("engaged"): return false
	var characters: Variant = director.get("characters")
	if not characters is Dictionary: return false
	for id: Variant in (characters as Dictionary):
		if bool(director.call("engaged", str(id))): return true
	return false


static func try_company_visit(nav: Node) -> bool:
	if nav._company_cooldown > 0.0 or not String(nav.command_owner).is_empty(): return false
	nav._company_cooldown = randf_range(35.0, 65.0)
	if randf() > lerpf(.12, .65, nav.daytime_activity()): return false
	var pony: CharacterBody3D = nav.pony
	for social in nav.get_tree().get_nodes_in_group("pony_social_groups"):
		var offer: Dictionary = social.offer_visit(pony)
		if offer.is_empty(): continue
		nav.go_to(offer.position, nav.Gait.TROT)
		nav._wandering = true
		nav._wander_intent = "Going to meet " + str(offer.name)
		nav._pick_pace()
		nav._company_cooldown = randf_range(75.0, 120.0)
		return true
	return false


static func ordinary_rest(nav: Node) -> float:
	var span := DAILY.rest_span(nav.rest_seconds, nav.daytime_activity())
	return randf_range(span.x, span.y)


## The glance itself, once the navigator's glance timer has run out: if the player is near,
## she looks at them for a moment.
static func glance(nav: Node) -> void:
	var interval: Vector2 = nav.glance_interval
	nav._glance_timer = randf_range(interval.x, interval.y)
	var attention: Variant = nav.attention_target
	if attention == null or not is_instance_valid(attention) or randf() > nav.glance_chance:
		return
	var pony: CharacterBody3D = nav.pony
	var head_height: Vector3 = pony.global_position + Vector3.UP * float(pony.profile.hip_height) * 1.4
	var to_player: Vector3 = attention.global_position - head_height
	if to_player.length() > 12.0:
		return
	var local: Vector3 = pony.global_basis.inverse() * to_player
	var yaw := atan2(-local.x, -local.z)
	if absf(yaw) > deg_to_rad(70.0):
		return
	var pitch := atan2(local.y, Vector2(local.x, local.z).length())
	var angles := Vector3(clampf(pitch, deg_to_rad(-20.0), deg_to_rad(40.0)) * nav.look_pitch_sign,
		clampf(yaw, deg_to_rad(-45.0), deg_to_rad(45.0)) * nav.look_yaw_sign, 0.0)
	if pony.secondary != null and pony.secondary.has_method("look_toward"):
		pony.secondary.look_toward(angles, randf_range(1.5, 3.0))
