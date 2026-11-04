extends Node
## Borrow only an available live Applejack. Navigation owns her body; activity owns
## one mouth-carried apple. Player/day/sleep ownership always wins.
var activity: Node3D
var actor: Node3D
var nav: Node
var lease: Dictionary = {}
var target: RigidBody3D
var phase: String = ""
var deadline: float = 0.0
var clock: float = 0.0
var pause_until: float = 0.0
var _check: float = 0.0
var _carried_from: Vector3 = Vector3.ZERO
var _lift_time: float = 0.0
var _old_gaze: Vector3 = Vector3.INF
var _gaze_target: Node3D
var _mouth_pose: RefCounted
var approach_goal: Vector3 = Vector3.INF
var _basket_close: bool = false
const GATHER_POSE := preload("res://world/minigames/apple_bucking/gather_mouth_pose.gd")
const MOUTH_CONTACT: float = .18
const LEGACY := preload("res://world/mechanics/legacy.gd")
const QUEUE := preload("res://world/mechanics/jobs/customer_queue.gd")
## The jobs core's shared lease bookkeeping (world/mechanics/jobs/customer_queue.gd); `-- --old-jobs`
## keeps the copied code below.
var _leases: RefCounted = QUEUE.new()
## How the last carried apple left her mouth: "deposit", "deposit_drop" or "released:<phase>".
var last_release := ""

func setup(owner_activity: Node3D) -> void:
	activity = owner_activity
	_gaze_target = Node3D.new(); _gaze_target.name = "HarvestGazeTarget"
	add_child(_gaze_target)

## Same measured upper-lip anchor that physical hand feeding uses; listen_point
## is the nose and must not make an apple float above Applejack's mouth.
func mouth_point() -> Vector3:
	if not is_instance_valid(actor): return Vector3.INF
	var affection: Node = actor.get_node_or_null("Affection")
	return affection.mouth_point() if affection != null and affection.has_method("mouth_point") else Vector3.INF

func _aim_at(point: Vector3) -> void:
	if not point.is_finite() or not is_instance_valid(_gaze_target): return
	_gaze_target.global_position = point
	if actor.has_method("set_action_gaze"): actor.set_action_gaze(_gaze_target)

func _face_settled(point: Vector3) -> bool:
	var toward: Vector3 = point - actor.global_position
	toward.y = 0.0
	if toward.length_squared() < .0001: return true
	var forward: Vector3 = -actor.global_basis.z
	forward.y = 0.0
	return forward.normalized().dot(toward.normalized()) >= .99 and absf(float(actor.get("_yaw_rate"))) <= .08

func _hold_heading() -> void:
	# Navigator rotates the upright actor to face_point. Once lowered, the
	# planted bow keeps that heading instead of turning its support anchors.
	nav.face_point = Vector3.INF
	if actor.has_method("face_direction"): actor.face_direction(Vector3.ZERO)

func _approach_arrived() -> bool:
	if not approach_goal.is_finite(): return false
	var offset: Vector3 = actor.global_position - approach_goal
	offset.y = 0.0
	return offset.length() <= float(nav.arrival_distance) + .02

func _deposit_point(tree_id: String) -> Vector3:
	var basket: Node3D = activity.baskets.get(tree_id) as Node3D
	if basket == null: return Vector3.INF
	# Aim above the centre for a deliberate gravity drop. A near-rim, low
	# target folds the neck back and leaves the actual mouth outside the rim.
	return basket.to_global(Vector3(0.0, .62, 0.0))

func _physics_process(delta: float) -> void:
	clock += delta
	if not is_instance_valid(activity): return
	if not lease.is_empty() and (not _owned() or _interrupted()): release(); return
	if is_instance_valid(target) and phase not in ["apple", "lower"] and activity.claim_owner(target) != self:
		target = null; phase = ""
	if is_instance_valid(target) and phase in ["lift", "basket"]:
		_lift_time += delta
		var mouth: Vector3 = mouth_point()
		if not mouth.is_finite(): release(); return
		target.global_position = mouth
	elif is_instance_valid(target) and phase == "deposit":
		_lift_time += delta
		var basket: Vector3 = _deposit_point(str(target.get_meta("tree_id")))
		if _mouth_pose == null: release(); return
		_mouth_pose.reach_to(basket, str(lease.owner))
		var mouth: Vector3 = mouth_point()
		if not mouth.is_finite(): release(); return
		target.global_position = mouth
	_check -= delta
	if _check > 0: return
	_check = .25
	if not activity.player_near_orchard(45.0): release(); return
	if clock < pause_until: return
	if lease.is_empty():
		if not _claim(): return
	if not is_instance_valid(target):
		target = activity.next_apple(actor.global_position)
		if target == null: release(); return
		phase = "apple"
		if not _travel(_pickup_goal(target.global_position)):
			release(); return
	if clock >= deadline or nav.state in [nav.State.BLOCKED, nav.State.UNREACHABLE]:
		release(); return
	match phase:
		"apple", "lower":
			if not activity.apple_available(target):
				if _mouth_pose != null: _mouth_pose.release(str(lease.owner))
				target = null; phase = ""; return
			_aim_at(target.global_position)
			# The old activity lifted fruit from any point within 1.15m. A real
			# mouth must finish its supported approach before lowering to contact.
			if nav.get("_has_target") == true: return
			if not _approach_arrived():
				_retry_approach(target.global_position); return
			if actor.global_position.distance_to(target.global_position) > 1.15 or not _visible(target.global_position):
				_retry_approach(target.global_position); return
			if not actor.grounded(): return
			if target.linear_velocity.length() > .5 or not _visible(target.global_position): return
			if phase == "apple":
				# Upright alignment also needs the supported locomotion solver.
				# Action gaze alone stops pinning it beyond conversation range.
				if _mouth_pose == null or not _mouth_pose.renew_support(str(lease.owner)): return
				nav.face_point = target.global_position
				if not _face_settled(target.global_position): return
				nav.stay(); _hold_heading()
			phase = "lower"
			if _mouth_pose == null or not _mouth_pose.reach_to(target.global_position, str(lease.owner)): return
			var mouth: Vector3 = mouth_point()
			if not mouth.is_finite() or mouth.distance_to(target.global_position) > MOUTH_CONTACT: return
			_carried_from = target.global_position
			if not activity.claim_apple(target, self): target = null; phase = ""; return
			_mouth_pose.release(str(lease.owner))
			_lift_time = 0.0
			phase = "lift"
			deadline = clock + 10.0
		"lift":
			if _lift_time < .65: return
			if _mouth_pose != null and float(_mouth_pose.crouch_amount) > .01: return
			phase = "basket"
			_basket_close = false
			var basket: Vector3 = activity.basket_for(str(target.get_meta("tree_id")))
			nav.face_point = basket
			if not _travel(_pickup_goal(basket, 1.3), true): release()
		"basket":
			var tree_id: String = str(target.get_meta("tree_id"))
			var basket: Vector3 = activity.basket_for(tree_id)
			_aim_at(basket)
			if nav.get("_has_target") == true: return
			if not _approach_arrived():
				if _basket_close: release(); return
				_retry_approach(basket, 1.3); return
			if actor.global_position.distance_to(basket) > 1.3 or not _visible(basket):
				_retry_approach(basket, 1.3); return
			if not actor.grounded(): return
			if not _basket_close:
				# Align while her feet are still clear of the basket. Turning
				# after stepping close swings a planted forehoof into its rim.
				if _mouth_pose == null or not _mouth_pose.renew_support(str(lease.owner)): return
				nav.face_point = basket
				if not _face_settled(basket): return
				# The outdoor grid keeps the body farther from a low basket than
				# physical contact requires. Finish only this short, swept step
				# with the navigator's existing doorway motor and support checks.
				var away: Vector3 = actor.global_position - basket
				away.y = 0.0
				if away.length_squared() < .0001: release(); return
				var close: Vector3 = basket + away.normalized() * .54
				close.y = actor.global_position.y
				nav.arrival_distance = .05
				nav.command_speed_limit = .25
				if not nav.command_contact_approach(close): release(); return
				approach_goal = nav.target
				_basket_close = true
				deadline = clock + 15.0
				return
			if _mouth_pose == null or not _mouth_pose.renew_support(str(lease.owner)): return
			nav.face_point = basket
			if not _face_settled(basket): return
			nav.stay(); _hold_heading()
			_carried_from = target.global_position
			_lift_time = 0.0
			phase = "deposit"
			deadline = clock + 10.0
		"deposit":
			if _lift_time < .55: return
			if activity.deposit(target, self):
				_mouth_pose.release(str(lease.owner))
				last_release = "deposit"
				target = null; phase = ""
			elif _over_opening(target):
				# Her mouth is over the open basket: she lets go on purpose and the apple drops
				# in (the basket counts it as it lands). Not the timeout release.
				var apple: RigidBody3D = target
				apple.set_meta("deposit_drop", clock)
				if activity.release_apple(apple, self):
					_mouth_pose.release(str(lease.owner))
					last_release = "deposit_drop"
					target = null; phase = ""

## The held apple is inside the rim's footprint, a little above the opening: a straight drop
## lands inside (apple_bucking.gd _basket_contains is the interior, .275 x .215, up to .43).
func _over_opening(apple: Node3D) -> bool:
	var basket: Node3D = activity.baskets.get(str(apple.get_meta("tree_id", ""))) as Node3D
	if basket == null: return false
	var local: Vector3 = basket.to_local(apple.global_position)
	return absf(local.x) <= .2 and absf(local.z) <= .15 and local.y >= .43 and local.y <= .8

func _pickup_goal(at: Vector3, reach: float = 1.15) -> Vector3:
	var away: Vector3 = actor.global_position - at
	away.y = 0
	if away.length_squared() < .01: away = Vector3.RIGHT
	var best: Vector3 = Vector3.INF
	var distance: float = INF
	# command_support snaps to a walk-grid cell. Reject a snapped point outside
	# reach, allowing the navigator's arrival tolerance, and try around obstacles.
	# Pickups end near the mouth, rather than stopping at the former distant
	# lifting range. Basket goals still stay outside its registered solid rim.
	var approach: float = .25 if reach < 1.2 else .50
	for step: int in 8:
		var direction: Vector3 = away.normalized().rotated(Vector3.UP, step * TAU / 8.0)
		var point: Vector3 = nav.command_support(at + direction * approach)
		if not point.is_finite() or point.distance_to(at) > reach - float(nav.arrival_distance) - .02: continue
		if not _line_visible(point + Vector3.UP * .65, at): continue
		var weight: float = 1000.0 if reach >= 1.2 else 4.0
		var gap: float = point.distance_squared_to(at) * weight + actor.global_position.distance_squared_to(point)
		if gap < distance: best = point; distance = gap
	return best

func _retry_approach(at: Vector3, reach: float = 1.15) -> void:
	# Fruit may roll after selecting it. Never cancel a pending route each tick.
	if nav.get("_has_target") == true: return
	if not _travel(_pickup_goal(at, reach), reach >= 1.2): release()

func _travel(point: Vector3, precise: bool = false) -> bool:
	if not point.is_finite() or not _owned(): return false
	approach_goal = point
	nav.command_speed_limit = INF
	nav.arrival_distance = minf(float(lease.arrival), .06) if precise else float(lease.arrival)
	deadline = clock + 90.0
	return nav.command_destination(point, "trot")

func _claim() -> bool:
	var population: Node = activity.host.get("population") as Node
	if not is_instance_valid(population): return false
	var live: Dictionary = population.get("live")
	var resident: Dictionary = live.get("applejack", {})
	actor = resident.get("actor") as Node3D
	if not is_instance_valid(actor): return false
	nav = actor.get_node_or_null("Navigator")
	if nav == null or _interrupted(): return false
	if not mouth_point().is_finite(): return false
	if actor.global_position.distance_to(activity.player_position()) > 180.0: return false
	var previous: String = str(nav.command_owner)
	if not (previous == "life:applejack" or (previous.is_empty() and nav.wander_enabled)): return false
	var first: RigidBody3D = activity.next_apple(actor.global_position)
	if first == null: return false
	if LEGACY.old_jobs():
		lease = {"owner":"leisure:apple_bucking:%d" % get_instance_id(), "previous":previous,
			"wander":nav.wander_enabled, "speed":nav.command_speed_limit, "pace":nav.command_pace_target,
			"arrival":nav.arrival_distance}
		_old_gaze = nav.face_point
		nav.stay()
		nav.command_owner = lease.owner
		nav.command_speed_limit = INF
		nav.command_pace_target = -1.0
		actor.set_meta("apple_bucking", lease.owner)
	else:
		# The shared lease saves and later restores the four navigation fields plus her arrival
		# distance and gaze, and sets the meta. A refused owner leaves her unowned (_owned false).
		var owner := "leisure:apple_bucking:%d" % get_instance_id()
		_old_gaze = nav.face_point
		_leases.life = activity.host.get("life") as Node
		_leases.claim("applejack", actor, {"apple_bucking": owner}, {"owner": owner, "fields": ["arrival_distance", "face_point"]})
		var saved: Dictionary = _leases.previous("applejack")
		lease = {"owner": owner, "previous": previous, "wander": saved.get("wander", nav.wander_enabled),
			"speed": saved.get("speed", nav.command_speed_limit), "pace": saved.get("pace", nav.command_pace_target),
			"arrival": saved.get("arrival_distance", nav.arrival_distance)}
	var existing: RefCounted = actor.get("activity_mouth_pose") as RefCounted
	if existing != null and existing != _mouth_pose:
		release(); return false
	if _mouth_pose == null or _mouth_pose.actor != actor:
		_mouth_pose = GATHER_POSE.new(); _mouth_pose.actor = actor
	actor.set("activity_mouth_pose", _mouth_pose)
	return true

func _owned() -> bool:
	if not is_instance_valid(activity) or not is_instance_valid(activity.host): return false
	if not is_instance_valid(actor) or not is_instance_valid(nav) or lease.is_empty() or nav.command_owner != lease.owner: return false
	var population: Node = activity.host.get("population") as Node
	return is_instance_valid(population) and population.live.get("applejack", {}).get("actor") == actor

func _interrupted() -> bool:
	if not is_instance_valid(actor) or nav == null: return true
	if actor.get("sleeping") == true or actor.get("motion_paused") == true: return true
	if actor.has_method("action_interruption_reason") and not str(actor.action_interruption_reason()).is_empty(): return true
	if actor.get_meta("active_follow", false) or actor.get_meta("seating", false): return true
	if is_instance_valid(actor.get("flight")) and actor.flight.active(): return true
	if is_instance_valid(actor.get("conversation_target")) or is_instance_valid(nav.get("_follow_target")): return true
	var gaze: Node3D = actor.get("action_gaze_target") as Node3D
	if is_instance_valid(gaze) and gaze != _gaze_target: return true
	var group: Variant = actor.get_meta("social_group", {})
	if group is Dictionary and group.get("members", []).size() > 1: return true
	if activity.host.has_method("_population_busy") and activity.host._population_busy(actor): return true
	return false

func _visible(at: Vector3) -> bool:
	var from: Vector3 = mouth_point()
	if not from.is_finite(): return false
	return _line_visible(from, at)

func _line_visible(from: Vector3, at: Vector3) -> bool:
	var excludes: Array[RID] = []
	if actor is CollisionObject3D: excludes.append(actor.get_rid())
	if is_instance_valid(target): excludes.append(target.get_rid())
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, at, 1, excludes)
	var hit: Dictionary = actor.get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty() or Vector3(hit.position).distance_to(at) < .15

func release() -> void:
	if is_instance_valid(activity) and is_instance_valid(target):
		# Recovery, never a deposit: the apple falls wherever she is.
		last_release = "released:" + phase
		activity.release_apple(target, self)
	if _mouth_pose != null: _mouth_pose.release(str(lease.get("owner", "")))
	if is_instance_valid(actor) and actor.get("action_gaze_target") == _gaze_target and actor.has_method("set_action_gaze"):
		actor.set_action_gaze(null)
	if not LEGACY.old_jobs():
		# Restores (while still hers) the fields saved at claim, reissues her goal, removes the meta.
		if is_instance_valid(activity) and is_instance_valid(activity.host): _leases.life = activity.host.get("life") as Node
		_leases.release("applejack", "released", -1.0, _owned())
	elif _owned():
		nav.stay()
		nav.command_owner = lease.previous
		nav.wander_enabled = lease.wander
		nav.command_speed_limit = lease.speed
		nav.command_pace_target = lease.pace
		nav.arrival_distance = lease.arrival
		nav.face_point = _old_gaze
		var life: Node = activity.host.get("life") as Node
		if is_instance_valid(life) and life.get("actors") is Dictionary and life.actors.has("applejack"):
			life.actors.applejack.goal = Vector3.INF
	if is_instance_valid(actor) and actor.get_meta("apple_bucking", "") == lease.get("owner", "missing"):
		actor.remove_meta("apple_bucking")
	lease.clear(); target = null; phase = ""; approach_goal = Vector3.INF
	pause_until = clock + 2.0

func _exit_tree() -> void:
	release()
