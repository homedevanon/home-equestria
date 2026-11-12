extends Node
## Two local, idle residents may borrow the real dock rods while Anon fishes.
## Navigator/locomotion own every pony transform and native pose. This controller
## only moves a held prop, and uses the same cast/hook/reel path as player hands.
## Day plans (world/life/day/actions/fish_at_dock.gd, M-ACT-01): invite_day takes a resident
## who came to fish on her own, with or without Anon, under her day owner ("day:<id>"), through the
## same rack, carry, cast, hook and reel steps; her lease stays when Anon stops fishing and ends
## with release_day. Day and company leases share the two spots and rods.
const OWNER := "leisure:fishing:"
const NEARBY := 24.0
const MAX_COMPANIONS := 2
## A day lease fishes at most this long; the day step normally ends it first (seconds).
const DAY_FISHING_LIMIT := 3600.0
var game: Node
var dock: Node3D
var hands: Node
var leases: Array[Dictionary] = []
var autonomous := true
var trace := false
var clock := 0.0
var _scan := 0.0
var _cooldown: Dictionary = {}
var _day_fished: Dictionary = {}   # resident id -> she reached her spot and fished (day leases)

func setup(host: Node, place: Node3D, player_hands: Node) -> void:
	release_all()
	game = host
	dock = place
	hands = player_hands
	process_physics_priority = -5

func _physics_process(delta: float) -> void:
	clock += delta
	var fishing := _player_fishing()
	if not fishing:
		# Only with leases left: nothing is copied on the usual idle tick. Anon's company goes
		# when he stops; residents on a day-plan lease fish on.
		if leases.is_empty(): return
		for lease: Dictionary in leases.duplicate():
			if not bool(lease.get("day", false)): _release(lease, "player fishing ended or activity unloaded")
		if leases.is_empty(): return
	for lease: Dictionary in leases.duplicate():
		if not _owned(lease):
			_release(lease, "navigation ownership changed")
			continue
		if not _resident_current(lease):
			_release(lease, "resident registry changed")
			continue
		if _interrupted(lease.actor, not lease.follow.is_empty()):
			_release(lease, "physical interaction or competing activity")
			continue
		if _same_follow(lease.follow) and lease.follow.executor.is_physics_processing():
			_release(lease, "new executor command reactivated follow")
			continue
		_step(lease, delta)
	if not fishing: return
	_scan -= delta
	if autonomous and _scan <= 0.0:
		_scan = 6.0
		_choose_company()

func _player_fishing() -> bool:
	if not is_instance_valid(game) or not is_instance_valid(dock) or not is_instance_valid(hands): return false
	var rod: Node3D = hands.get("rod") as Node3D
	return is_instance_valid(rod) and rod in dock.rods and rod.holder == "player" \
		and rod.global_position.distance_to(dock.global_position) <= 16.0

func _residents() -> Dictionary:
	if not is_instance_valid(game): return {}
	var population: Node = game.get("population") as Node
	if not is_instance_valid(population) or not population.get("live") is Dictionary: return {}
	return population.get("live")

func _resident_current(lease: Dictionary) -> bool:
	return _residents().get(lease.id, {}).get("actor") == lease.actor

func _interrupted(actor: Node3D, allow_follow := false) -> bool:
	if not is_instance_valid(actor): return true
	var nav: Node = actor.get_node_or_null("Navigator")
	if not is_instance_valid(nav): return true
	if actor.get("sleeping") == true or actor.get("_held") == true or actor.get("motion_paused") == true: return true
	if actor.has_method("action_interruption_reason") and not str(actor.action_interruption_reason()).is_empty(): return true
	if actor.has_meta("seating"): return true
	if actor.get_meta("active_follow", false) and not allow_follow: return true
	if actor.get("conversing") == true or is_instance_valid(actor.get("conversation_target")): return true
	if is_instance_valid(nav.get("_follow_target")) and not allow_follow: return true
	var flight: Variant = actor.get("flight")
	if is_instance_valid(flight) and flight.active(): return true
	var group: Variant = actor.get_meta("social_group", {})
	if group is Dictionary and group.get("members", []).size() > 1: return true
	return game.has_method("_population_busy") and game._population_busy(actor)

func eligible(actor: Node3D) -> bool:
	if not _player_fishing() or not is_instance_valid(actor): return false
	var follow: Dictionary = _follow_intent(actor)
	if _interrupted(actor, not follow.is_empty()): return false
	if not is_instance_valid(dock.approach): return false
	if actor.global_position.distance_to(dock.approach.global_position) > NEARBY: return false
	if actor.has_meta("fishing_companion") or float(_cooldown.get(actor.get_instance_id(), 0.0)) > clock: return false
	var nav: Node = actor.get_node("Navigator")
	var owner: String = str(nav.command_owner)
	# Even a routine-owned actor is unavailable while travelling to a goal.
	return not follow.is_empty() or ((owner.is_empty() or owner.begins_with("life:")) and nav.get("_has_target") != true)

## Follow has two existing APIs: desktop Navigator.follow and spoken executor intentions.
## Only a target belonging to the actual player qualifies; arbitrary player commands do not.
func _player_target(target: Node3D) -> bool:
	if not is_instance_valid(target) or not is_instance_valid(game): return false
	var player: Node3D = game.get("player") as Node3D
	return is_instance_valid(player) and (target == player or player.is_ancestor_of(target))

func _follow_intent(actor: Node3D) -> Dictionary:
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav == null: return {}
	var director: Node = game.get("director") as Node
	if is_instance_valid(director):
		var actions: Node = director.get("actions") as Node
		if is_instance_valid(actions) and actions.get("executors") is Dictionary:
			for executor: Node in actions.executors.values():
				if not is_instance_valid(executor) or executor.actor != actor: continue
				var movement: Dictionary = executor.movement
				if movement.is_empty(): break
				if not executor.gaze.is_empty(): return {}
				if movement.get("type") != "follow" or nav.command_owner != movement.get("id"): return {}
				var target: Node3D = movement.target.get_ref() as Node3D
				if not _player_target(target): return {}
				return {"target":target, "executor":executor, "action_id":movement.id,
					"processing":executor.is_physics_processing()}
	var target: Node3D = nav.get("_follow_target") as Node3D
	return {"target":target, "executor":null} if _player_target(target) else {}

func _same_follow(follow: Dictionary) -> bool:
	if follow.is_empty() or not is_instance_valid(follow.get("executor")): return false
	var movement: Dictionary = follow.executor.movement
	return movement.get("type") == "follow" and movement.get("id") == follow.action_id \
		and movement.target.get_ref() == follow.target

func _choose_company() -> void:
	if leases.size() >= MAX_COMPANIONS: return
	var nearest: Node3D
	var identity := ""
	var distance := INF
	var residents := _residents()
	for key: Variant in residents:
		var actor: Node3D = residents[key].get("actor") as Node3D
		if not eligible(actor): continue
		var gap: float = actor.global_position.distance_squared_to(dock.approach.global_position)
		if gap < distance:
			nearest = actor
			identity = str(key)
			distance = gap
	if nearest != null: invite(identity, nearest)

## A free companion spot index, or -1.
func _free_slot() -> int:
	if not is_instance_valid(dock): return -1
	for index: int in mini(MAX_COMPANIONS, dock.companion_spots.size()):
		var used := false
		for lease: Dictionary in leases:
			if lease.slot == index: used = true
		if not used: return index
	return -1

## A rack rod nopony holds or has leased (never the one in Anon's hand), or null.
func _free_rod() -> Node3D:
	if not is_instance_valid(dock): return null
	var player_rod: Variant = hands.get("rod") if is_instance_valid(hands) else null
	for index: int in range(dock.rods.size() - 1, -1, -1):
		var candidate: Node3D = dock.rods[index]
		if not is_instance_valid(candidate) or candidate == player_rod or not candidate.holder.is_empty(): continue
		var used := false
		for lease: Dictionary in leases:
			if lease.rod == candidate: used = true
		if not used: return candidate
	return null

## A spot and a rod are free for one more resident (fish_at_dock.gd asks before walking over).
func day_spot_free() -> bool:
	return leases.size() < MAX_COMPANIONS and _free_slot() >= 0 and _free_rod() != null

func has_day_lease(identity: String) -> bool:
	for lease: Dictionary in leases:
		if bool(lease.get("day", false)) and str(lease.id) == identity: return true
	return false

## She got to her spot and fished during her latest day lease (it may have ended since).
func day_fished(identity: String) -> bool:
	return bool(_day_fished.get(identity, false))

func release_day(identity: String, cause := "day step ended") -> void:
	for lease: Dictionary in leases.duplicate():
		if bool(lease.get("day", false)) and str(lease.id) == identity: _release(lease, cause)

## A resident fishing on her day plan: `owner` is her day owner, already on her navigator; the
## lease keeps it (the day runner sees its step) and restores it when it ends. She must stand near
## the dock's bank end, free of chats, company and carrying. False when no spot or rod is free.
func invite_day(identity: String, actor: Node3D, owner: String) -> bool:
	if leases.size() >= MAX_COMPANIONS or not is_instance_valid(actor) or not is_instance_valid(dock) or not is_instance_valid(dock.approach): return false
	if has_day_lease(identity) or actor.has_meta("fishing_companion") or _residents().get(identity, {}).get("actor") != actor: return false
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav == null or owner.is_empty() or str(nav.command_owner) != owner or _interrupted(actor): return false
	if actor.global_position.distance_to(dock.approach.global_position) > NEARBY: return false
	var slot := _free_slot()
	var rod := _free_rod()
	if slot < 0 or rod == null: return false
	var lease := {"id":identity, "actor":actor, "nav":nav, "rod":rod, "slot":slot, "owner":owner, "day":true,
		"previous":nav.command_owner, "wander":nav.wander_enabled, "speed":nav.command_speed_limit,
		"pace":nav.command_pace_target, "gaze":nav.face_point, "phase":"bank", "deadline":clock + 90.0,
		"wait":0.0, "hold_time":0.0, "lift":0.0, "bite_time":0.0, "casts":0,
		"prop_start":rod.global_transform, "excludes":rod.player_excludes.duplicate(), "follow":{}}
	nav.stay()
	nav.command_speed_limit = INF
	nav.command_pace_target = -1.0
	nav.face_point = Vector3.INF
	actor.set_meta("fishing_companion", owner)
	leases.append(lease)
	_day_fished[identity] = false
	if not _travel(lease, dock.approach.global_position, 0.7):
		_release(lease, "bank support refused")
		return false
	return true

## Public for deterministic fixtures; still enforces all live admission rules.
func invite(identity: String, actor: Node3D) -> bool:
	if leases.size() >= MAX_COMPANIONS or not eligible(actor): return false
	if _residents().get(identity, {}).get("actor") != actor: return false
	var slot := _free_slot()
	# Player holds one of the three; never take it or all remaining rack rods.
	var rod := _free_rod()
	if slot < 0 or rod == null: return false
	var nav: Node = actor.get_node("Navigator")
	var token := OWNER + str(get_instance_id()) + ":" + identity
	var lease := {"id":identity, "actor":actor, "nav":nav, "rod":rod, "slot":slot, "owner":token,
		"previous":nav.command_owner, "wander":nav.wander_enabled, "speed":nav.command_speed_limit,
		"pace":nav.command_pace_target, "gaze":nav.face_point, "phase":"bank", "deadline":clock + 90.0,
		"wait":0.0, "hold_time":0.0, "lift":0.0, "bite_time":0.0, "casts":0,
		"prop_start":rod.global_transform, "excludes":rod.player_excludes.duplicate(), "follow":_follow_intent(actor)}
	if is_instance_valid(lease.follow.get("executor")):
		lease.follow.executor.set_physics_process(false)
	nav.stay()
	nav.command_owner = token
	nav.command_speed_limit = INF
	nav.command_pace_target = -1.0
	nav.face_point = Vector3.INF
	actor.set_meta("fishing_companion", token)
	leases.append(lease)
	if not _travel(lease, dock.approach.global_position, 0.7):
		_release(lease, "bank support refused")
		return false
	return true

func _owned(lease: Dictionary) -> bool:
	return is_instance_valid(lease.actor) and is_instance_valid(lease.nav) and lease.nav.command_owner == lease.owner

func _travel(lease: Dictionary, at: Vector3, tolerance: float) -> bool:
	var goal: Vector3 = lease.nav.command_support(at)
	if not goal.is_finite() or goal.distance_to(at) > tolerance:
		if trace: print("[fishing-route] support refused phase=", lease.phase, " requested=", at, " support=", goal)
		return false
	lease.goal = goal
	lease.deadline = clock + 90.0
	lease.nav.face_point = Vector3.INF
	return lease.nav.command_destination(goal, "walk")

func _arrived(lease: Dictionary, tolerance: float = 0.55) -> bool:
	return lease.actor.global_position.distance_to(lease.goal) <= tolerance and lease.actor.grounded()

func _rack_goal(lease: Dictionary) -> Vector3:
	var rod: Node3D = lease.rod
	var at: Vector3 = rod.global_position
	# Approach from the open side of the rack; do not target its solid leg.
	return Vector3(at.x, dock.global_position.y, at.z) - dock.water_direction() * 0.70

func _step(lease: Dictionary, delta: float) -> void:
	if not is_instance_valid(lease.rod):
		_release(lease, "rod removed")
		return
	var rod: Node3D = lease.rod
	var actor: Node3D = lease.actor
	var nav: Node = lease.nav
	if lease.slot >= dock.companion_spots.size() or not is_instance_valid(dock.companion_spots[lease.slot]):
		_release(lease, "dock spot removed")
		return
	if clock >= lease.deadline or nav.state in [nav.State.BLOCKED, nav.State.UNREACHABLE]:
		_release(lease, "deadline or failed navigation")
		return
	if not rod.holder.is_empty() and rod.holder != lease.owner:
		_release(lease, "rod taken by another holder") # Player can take a rod while a pony is still approaching it.
		return
	if lease.phase in ["carry", "rack_exit", "line_up", "spot", "fishing"]:
		if rod.holder != lease.owner:
			_release(lease, "held rod ownership lost")
			return
		_hold(lease, delta)
	match lease.phase:
		"bank":
			if not _arrived(lease): return
			lease.phase = "rack"
			if not _travel(lease, _rack_goal(lease), 0.40): _release(lease, "rack support refused")
		"rack":
			if not _arrived(lease, 0.45): return
			var mouth: Vector3 = actor.listen_point()
			if mouth.distance_to(rod.global_position) > 1.20 or not _visible(actor, mouth, rod.global_position):
				if nav.get("_has_target") == true: return
				if trace: print("[fishing-route] pickup refused mouth=", mouth, " rod=", rod.global_position, " distance=", mouth.distance_to(rod.global_position))
				_release(lease, "pickup reach or occlusion refused after arrival")
				return
			nav.stay()
			if not rod.take(lease.owner):
				_release(lease, "local rod take refused")
				return
			lease.prop_start = rod.global_transform
			rod.player_excludes.clear()
			if actor is CollisionObject3D: rod.player_excludes.append(actor.get_rid())
			lease.phase = "carry"
			lease.wait = 0.65
		"carry":
			lease.wait -= delta
			if lease.wait > 0.0: return
			# Clear the rack's bank-side corner before following the riverward aisle.
			# A single distant goal cuts this turn too early in the native lookahead.
			lease.phase = "rack_exit"
			if not _travel(lease, dock.to_global(Vector3(0.90, 0.0, 2.40)), 0.40): _release(lease, "rack exit support refused")
		"rack_exit":
			if not _arrived(lease, 0.28): return
			lease.phase = "line_up"
			var approach: Vector3 = dock.companion_spots[lease.slot].global_position - dock.water_direction() * 1.40
			if not _travel(lease, approach, 0.45): _release(lease, "fishing approach support refused")
		"line_up":
			if not _arrived(lease, 0.28): return
			# Clip-tier locomotion does not turn on stationary face_direction requests.
			# Walk the final leg toward the water through the actual navigator instead.
			lease.phase = "spot"
			if not _travel(lease, dock.companion_spots[lease.slot].global_position, 0.45): _release(lease, "fishing spot support refused")
		"spot":
			if not _arrived(lease, 0.28): return
			nav.stay()
			nav.face_point = actor.global_position + dock.water_direction() * 6.0
			lease.phase = "fishing"
			lease.deadline = clock + (DAY_FISHING_LIMIT if bool(lease.get("day", false)) else 180.0)
			lease.wait = 1.2
			if bool(lease.get("day", false)): _day_fished[str(lease.id)] = true
		"fishing":
			if actor.global_position.distance_to(dock.companion_spots[lease.slot].global_position) > 0.9:
				_release(lease, "left fishing spot")
				return
			lease.wait -= delta
			match str(rod.line.state):
				"ready":
					lease.bite_time = 0.0
					if lease.wait > 0.0: return
					if (-actor.global_basis.z.normalized()).dot(dock.water_direction()) < 0.9: return
					# A failed cast/solid hit waits before trying again; never award a fish here.
					if rod.cast(dock.water_direction(), 0.85):
						lease.casts += 1
						lease.lift = 0.20
					lease.wait = 3.0
				"bite":
					lease.bite_time += delta
					if lease.bite_time >= 0.28:
						lease.lift = 0.32
						rod.line.hook()
				"hooked":
					rod.reel(delta * 0.95)
					lease.wait = 2.5
				"waiting": lease.bite_time = 0.0

func _hold(lease: Dictionary, delta: float) -> void:
	var actor: Node3D = lease.actor
	var forward: Vector3 = -actor.global_basis.z.normalized()
	forward.y = 0.0
	if forward.length_squared() < 0.01: forward = dock.water_direction()
	forward = forward.normalized()
	lease.hold_time += delta
	lease.lift = move_toward(lease.lift, 0.0, delta * 0.35)
	var along: Vector3 = (forward * 0.91 + Vector3.UP * (0.42 + lease.lift)).normalized()
	var right: Vector3 = forward.cross(Vector3.UP).normalized()
	var frame := Transform3D(Basis(right, along, right.cross(along).normalized()), actor.listen_point())
	# Move only the prop: mouth grip follows the accepted native head pose.
	lease.rod.global_transform = lease.prop_start.interpolate_with(frame, smoothstep(0.0, 0.60, lease.hold_time))

func _visible(actor: Node3D, from: Vector3, to: Vector3) -> bool:
	var excludes: Array[RID] = []
	if actor is CollisionObject3D: excludes.append(actor.get_rid())
	var ray := PhysicsRayQueryParameters3D.create(from, to, 1, excludes)
	var hit: Dictionary = actor.get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty(): return true
	if trace: print("[fishing-pickup] hit=", hit.collider.name, " distance=", Vector3(hit.position).distance_to(to))
	# Authored grips rest inside the top centimetre of the crossbar. Its endpoint
	# contact is intentional support; no other body or earlier blockage is exempt.
	return hit.collider == dock.get_node_or_null("Rod rack") and Vector3(hit.position).distance_to(to) <= 0.15

## The day-plan resident fishing with this rod, or "" (fishing_runtime.gd: her catch is a fact
## only, no loose fish for Anon, unless he is fishing too).
func day_angler(rod: Node3D) -> String:
	for lease: Dictionary in leases:
		if lease.rod == rod and bool(lease.get("day", false)) and _owned(lease): return str(lease.id)
	return ""

## For main's existing dock fish_landed callback: attribute, never duplicate payout.
func actor_for_rod(rod: Node3D) -> Node3D:
	if not is_instance_valid(rod): return null
	for lease: Dictionary in leases:
		if lease.rod == rod and _owned(lease) and _resident_current(lease) and rod.holder == lease.owner: return lease.actor
	return null

func _release(lease: Dictionary, cause := "explicit release") -> void:
	if trace and is_instance_valid(lease.actor) and is_instance_valid(lease.nav):
		print("[fishing-route] release cause=", cause, " owned=", _owned(lease), " resident_current=", _resident_current(lease), " player_fishing=", _player_fishing(), " phase=", lease.phase, " position=", lease.actor.global_position, " goal=", lease.get("goal"), " state=", lease.nav.state, " reason=", lease.nav.reason, " clock=", clock, " deadline=", lease.deadline, " owner=", lease.nav.command_owner, " interruption=", lease.actor.action_interruption_reason(), " grounded=", lease.actor.grounded())
	var was_owned: bool = _owned(lease)
	var rod: Variant = lease.rod
	if is_instance_valid(rod) and rod.holder == lease.owner:
		rod.put_back()
		rod.player_excludes = lease.excludes
	# A new player command owns its route, pace and gaze. Never restore over it.
	if was_owned:
		var nav: Node = lease.nav
		nav.stay()
		nav.command_owner = lease.previous
		nav.wander_enabled = lease.wander
		nav.command_speed_limit = lease.speed
		nav.command_pace_target = lease.pace
		nav.face_point = lease.gaze
		var life: Node = game.get("life") as Node if is_instance_valid(game) else null
		if is_instance_valid(life) and life.get("actors") is Dictionary and life.actors.has(lease.id):
			life.actors[lease.id].goal = Vector3.INF
	var follow: Dictionary = lease.follow
	if not follow.is_empty():
		if _same_follow(follow):
			var executor: Node = follow.executor
			if was_owned and is_instance_valid(follow.target):
				executor._last_goal = Vector3.INF
				executor._last_target = Vector3.INF
				executor.set_physics_process(follow.processing)
			else:
				# A direct command superseded our suspended intention. Ending it via
				# executor._end_move would stop the new route, so discard only this old action.
				executor.movement = {}
				executor.set_physics_process(not executor.gaze.is_empty())
				if is_instance_valid(lease.actor): lease.actor.remove_meta("active_follow")
		elif not is_instance_valid(follow.get("executor")) and was_owned and is_instance_valid(follow.target):
			lease.nav.follow(follow.target)
	if is_instance_valid(lease.actor):
		_cooldown[lease.actor.get_instance_id()] = clock + 30.0
		if lease.actor.get_meta("fishing_companion", "") == lease.owner: lease.actor.remove_meta("fishing_companion")
	leases.erase(lease)

func release_all(cause := "explicit release or teardown") -> void:
	for lease: Dictionary in leases.duplicate(): _release(lease, cause)

func _exit_tree() -> void:
	release_all()
