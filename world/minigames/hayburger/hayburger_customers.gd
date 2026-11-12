extends Node
## Live population customers. The navigator remains the only movement writer.
## Parent: customer_arrived -> shift.add_customer(id, name), then immediately
## sync_orders(shift.snapshot().orders) in that same callback. Also sync queue changes.
## The parent's reward_sink must check can_serve(front_order.id) before crediting;
## served(order_id) runs ONLY after a correct serve. No currency is changed here.
signal customer_arrived(pony_id: String, display_name: String)
signal customer_departed(pony_id: String)
signal order_assignment(order_id: String, pony_id: String, display_name: String)
signal self_serve_completed(pony_id: String, display_name: String)

const MAX_VISITORS := 3
const CHECK_SECONDS := 0.5
const RECRUIT_SECONDS := 4.0
const OFF_SHIFT_INTERVAL := Vector2(25.0, 45.0)
const OFF_SHIFT_CHANCE := 0.18
# A missed random roll must not suppress ordinary visitors indefinitely. Once
# due, keep the invitation pending until a real eligible resident can take it.
const OFF_SHIFT_MAX_WAIT := 90.0
const COOLDOWN_SECONDS := 45.0
const FAILED_VISIT_COOLDOWN := 8.0
const TRAVEL_TIMEOUT := 120.0
const COUNTER_TIMEOUT := 150.0
const VISIT_RADIUS := 180.0
const CANDIDATE_BUDGET := 16
## Room-local street rows where a booked shift group waits outside the door, nearest first,
## either side of the incoming lane.
const GROUP_ROWS: Array[float] = [9.6, 11.0, 12.4, 13.8]
const GROUP_COLUMNS: Array[float] = [-1.6, 1.6, -3.0, 3.0, -4.4, 4.4]
## One-way doorway (thread reports 0.0.8-0.0.9.1: two customers wedged the one-pony door from
## both sides and the rest turned round outside). A customer coming in waits this far (metres)
## from the door point while one is walking out; a fed customer stays at the counter while one
## is still on her way in, until she is this far inside (room-local z).
const DOOR_APPROACH := 5.0
const DOOR_INSIDE_Z := 2.0
## Ponies are collision layer 2: a spot taken by a pony is waited out, not a reason to leave.
const PONY_LAYER := 2
const LEGACY := preload("res://world/mechanics/legacy.gd")
const QUEUE := preload("res://world/mechanics/jobs/customer_queue.gd")

var _game: Node
## The jobs core's shared lease bookkeeping (world/mechanics/jobs/customer_queue.gd); `-- --old-jobs`
## keeps the copied code below. It shares this node's cooldowns.
var _leases: RefCounted
var _restaurant: Node3D
var _markers: Dictionary = {}
var _visitors: Dictionary = {}
var _cooldowns: Dictionary = {}
var _orders: Array = []
var _working := false
var _open := true
var _clock := 0.0
var _check := 0.0
var _recruit_at := 0.0
var _off_shift_at := 0.0
var _off_shift_due := 0.0
var _off_shift_pending := false
var _last_recruit: Dictionary = {}
var _cursor := 0
var _rng := RandomNumberGenerator.new()
var _last_reason := ""

func setup(game: Node, restaurant: Node3D) -> void:
	release_all()
	# Day plans find the restaurant's customers here (world/life/day/actions/eat_at_hayburger.gd).
	add_to_group("hayburger_customers")
	_game = game
	_restaurant = restaurant
	_markers.clear()
	_rng.randomize()
	if is_instance_valid(restaurant):
		for key: String in ["EntrySpawn", "CustomerPoint", "SelfServePoint", "ExitPoint", "EntryClearance", "DeparturePoint"]:
			_markers[key] = restaurant.find_child(key, true, false) as Node3D
	_schedule_self_service()
	process_mode = Node.PROCESS_MODE_PAUSABLE
	set_physics_process(true)

func set_open(value: bool) -> void:
	if _open == value: return
	_open = value
	if value:
		_schedule_self_service()
		_recruit_at = _clock
		return
	_working = false
	_orders.clear()
	_off_shift_pending = false
	for id: String in _visitors.keys():
		if not _visitors.has(id): continue
		var visit: Dictionary = _visitors[id]
		_clear_priority(visit)
		if visit.phase in ["exiting", "leaving"]: continue
		if not is_instance_valid(visit.actor) or _restaurant.to_local(visit.actor.global_position).z > 5.2:
			_release(id, "Restaurant closed")
		else:
			_leave(visit, "Closing time")

func set_working(value: bool) -> void:
	if value and not _open: return
	if value == _working: return
	_working = value
	_recruit_at = _clock
	# Clocking out sends current staffed customers to the kiosk. Their cancelled
	# orders cannot become rewards, and an unattended visit never creates an order.
	if not value:
		_schedule_self_service()
		_orders.clear()
		for id: String in _visitors.keys():
			if not _visitors.has(id): continue
			var visit: Dictionary = _visitors[id]
			if visit.self_service or visit.phase in ["eating", "exiting", "leaving"]: continue
			_clear_priority(visit)
			visit.self_service = true
			visit.order_id = ""
			_withdraw(visit)
			if not _visitors.has(id): continue
			if not _owned(visit) or _interrupted(visit.actor, true):
				_release(id, "Interaction took priority")
			elif visit.phase != "entry":
				_route(visit, "service", "SelfServePoint")

func sync_orders(orders: Array) -> void:
	_orders = orders.duplicate(true)
	var assigned := {}
	for id: String in _visitors.keys():
		if not _visitors.has(id): continue
		var visit: Dictionary = _visitors[id]
		if visit.self_service or visit.phase != "counter": continue
		var match_id := ""
		for value in _orders:
			if not value is Dictionary: continue
			var order: Dictionary = value
			var key := str(order.get("id", ""))
			if key.is_empty() or assigned.has(key): continue
			var customer_id := str(order.get("customer_id", order.get("pony_id", "")))
			var customer_name := str(order.get("customer", order.get("customer_name", order.get("name", ""))))
			if (not customer_id.is_empty() and customer_id == id) or (customer_id.is_empty() and customer_name == visit.display_name):
				match_id = key
				break
		if match_id.is_empty():
			if not str(visit.order_id).is_empty(): _leave(visit, "Order removed")
			continue
		assigned[match_id] = id
		if visit.order_id == match_id: continue
		# One immutable order assignment per customer; a replacement is a new visit.
		if not str(visit.order_id).is_empty(): continue
		visit.order_id = match_id
		order_assignment.emit(match_id, id, visit.display_name)

func can_serve(order_id: Variant) -> bool:
	if not _open or not _working: return false
	var key := str(order_id)
	var population := _population()
	if key.is_empty() or not is_instance_valid(population): return false
	for id: String in _visitors:
		var visit: Dictionary = _visitors[id]
		if visit.phase != "counter" or visit.self_service or visit.order_id != key: continue
		return _owned(visit) and population.live.get(id, {}).get("actor") == visit.actor \
			and not _interrupted(visit.actor, true) and _at_goal(visit)
	return false

func served(order_id: Variant) -> void:
	if not can_serve(order_id): return
	for visit: Dictionary in _visitors.values():
		if visit.order_id == str(order_id):
			_eat(visit)
			return

func on_order_served(order: Dictionary, _reward: int = 0) -> void:
	served(order.get("id", ""))

# --- Day-plan meals (M-ACT-01, board #348) ----------------------------------------------------

## A resident's day step "eat at the Hayburger" (world/life/day/actions/eat_at_hayburger.gd): she
## comes in as an ordinary customer (the counter while Anon works a shift, else the kiosk) whose
## visit keeps `owner` (her "day:<id>") on her navigator, then eats in a booth for `eat_seconds`.
## "" when the visit started, else why not (closed, full, busy).
func request_day_visit(id: String, actor: Node3D, owner: String, eat_seconds: float) -> String:
	if not _open: return "The Hayburger is closed"
	if not is_instance_valid(_restaurant) or not _restaurant.is_inside_tree(): return "No Hayburger here"
	if _visitors.size() >= MAX_VISITORS: return "The Hayburger is full"
	var why := _eligibility_reason(id, actor, owner)
	if not why.is_empty(): return why
	if not _claim(id, actor, not _working, owner): return _last_reason if not _last_reason.is_empty() else "No room inside"
	var visit: Dictionary = _visitors[id]
	visit.day = true
	visit.eat_seconds = maxf(10.0, eat_seconds)
	return ""

func has_visit(id: String) -> bool:
	return _visitors.has(id)

func visit_phase(id: String) -> String:
	return str(_visitors.get(id, {}).get("phase", ""))

## Her day step was cut short: the visit ends where she is (whoever took her moves her on).
func end_day_visit(id: String, reason: String) -> void:
	if _visitors.has(id): _release(id, reason)

## A free booth seat (seating.gd booth_seats) nearest her, taken through the shared seating
## service with the visit's owner. True when she is on her way to it.
func _take_booth(visit: Dictionary) -> bool:
	var seating: Node = get_tree().get_first_node_in_group("pony_seating") if is_inside_tree() else null
	if seating == null or not seating.has_method("booth_seats") or not is_instance_valid(_restaurant): return false
	var actor: Node3D = visit.actor
	var best: Node3D = null
	var best_d := INF
	for seat: Variant in seating.call("booth_seats", _restaurant):
		if not is_instance_valid(seat) or not seat is Node3D: continue
		var who: Variant = (seat as Node3D).get_meta("occupant") if (seat as Node3D).has_meta("occupant") else null
		if is_instance_valid(who) and who != actor: continue
		var d := actor.global_position.distance_squared_to((seat as Node3D).global_position)
		if d < best_d: best = seat; best_d = d
	if best == null: return false
	var front: Variant = best.get_meta("front", null) if best.has_meta("front") else null
	var rest := {"owner": visit.owner}
	if front is Vector3: rest["front"] = front
	actor.set_meta("hayburger_booth", visit.owner)
	if not bool(seating.call("sit", actor, 0.0, best, rest)):
		actor.remove_meta("hayburger_booth")
		return false
	visit.booth = best
	visit.sat = true
	return true

## On a booth seat (or on her way to or off it) for this visit.
func _in_booth(visit: Dictionary) -> bool:
	return is_instance_valid(visit.get("booth")) and is_instance_valid(visit.actor) and visit.actor.get_meta("hayburger_booth", "") == visit.owner

func _seating_phase(actor: Node3D) -> String:
	var seating: Node = get_tree().get_first_node_in_group("pony_seating") if is_inside_tree() else null
	return str(seating.call("phase", actor)) if seating != null and seating.has_method("phase") and is_instance_valid(actor) else ""

func _left_booth(visit: Dictionary) -> void:
	visit.erase("booth")
	visit.sat = false
	if is_instance_valid(visit.actor) and visit.actor.get_meta("hayburger_booth", "") == visit.owner: visit.actor.remove_meta("hayburger_booth")

func release_all() -> void:
	_working = false
	_orders.clear()
	for id: String in _visitors.keys(): _release(id, "Restaurant released")

func visitor_report() -> Dictionary:
	var visitors := []
	var names := []
	var assignments := {}
	for id: String in _visitors:
		var visit: Dictionary = _visitors[id]
		visitors.append({"id": id, "name": visit.display_name, "phase": visit.phase,
			"self_service": visit.self_service, "order_id": visit.order_id})
		if visit.phase == "counter" and not visit.self_service:
			names.append(visit.display_name)
			if not str(visit.order_id).is_empty(): assignments[visit.order_id] = id
	return {"working": _working, "count": visitors.size(), "visitors": visitors,
		"customer_names": names, "assignments": assignments, "last_reason": _last_reason,
		"recruitment": _last_recruit.duplicate(true), "self_service_pending": _off_shift_pending}

func _physics_process(delta: float) -> void:
	_clock += delta
	_check += delta
	if _check < CHECK_SECONDS: return
	_check = 0.0
	if not is_instance_valid(_game) or not is_instance_valid(_restaurant) or not _restaurant.is_inside_tree():
		release_all()
		return
	for id: String in _visitors.keys(): _advance(id)
	if not _open: return
	if _working and _clock >= _recruit_at:
		var recruited: bool = _recruit(false)
		# Finish the bounded live-population sweep promptly when this batch has
		# no candidate, instead of waiting four seconds between failed batches.
		_recruit_at = _clock + (RECRUIT_SECONDS if recruited or _visitors.size() >= MAX_VISITORS else CHECK_SECONDS)
	elif not _working and _clock >= _off_shift_at:
		_off_shift_pending = _off_shift_pending or _clock >= _off_shift_due or _rng.randf() < OFF_SHIFT_CHANCE
		if _off_shift_pending and _visitors.is_empty():
			if _recruit(true): _schedule_self_service()
			else: _off_shift_at = _clock + CHECK_SECONDS
		else:
			_off_shift_at = minf(_clock + _rng.randf_range(OFF_SHIFT_INTERVAL.x, OFF_SHIFT_INTERVAL.y), _off_shift_due)
			if _off_shift_pending: _off_shift_at = _clock + RECRUIT_SECONDS
	for id in _cooldowns.keys():
		if float(_cooldowns[id]) <= _clock: _cooldowns.erase(id)

func _schedule_self_service() -> void:
	_off_shift_pending = false
	_off_shift_due = _clock + OFF_SHIFT_MAX_WAIT
	_off_shift_at = _clock + _rng.randf_range(OFF_SHIFT_INTERVAL.x, OFF_SHIFT_INTERVAL.y)

func _population() -> Node:
	return _game.get("population") as Node if is_instance_valid(_game) else null

## `visiting`: a customer already in the shop may talk with Anon; only a new one must be free of
## talk. Answering a customer used to release her and cancel her order (player report 2026-10-30).
func _interrupted(actor: Node3D, visiting := false) -> bool:
	if not is_instance_valid(actor) or not actor.is_inside_tree(): return true
	# Seated in a booth by this visit (_take_booth): the seat hop pauses her motion and the seating
	# service owns her posture; that is the meal, not an interruption.
	var booth := visiting and str(actor.get_meta("hayburger_booth", "")) != ""
	if actor.get("sleeping") == true or (actor.get("motion_paused") == true and not booth): return true
	if actor.get_meta("active_follow", false) or (actor.get_meta("seating", false) and not booth): return true
	if actor.has_method("is_held") and actor.is_held(): return true
	if actor.has_method("action_interruption_reason") and not booth:
		var why := str(actor.action_interruption_reason())
		# A hoof off the ground for a frame (the door sill) is no interaction: once a visit's 0.5 s
		# check landed on that frame and sent the customer home (2026-10-31, test_doorway_traffic.gd).
		# The navigator waits for support itself; the leg's deadline still bounds a real fall.
		if not why.is_empty() and not (visiting and why == "Waiting for safe ground support"): return true
	if not is_instance_valid(_game): return true
	# _population_busy is mostly "in a chat with Anon" (director engaged()).
	if not visiting and _game.has_method("_population_busy") and _game._population_busy(actor): return true
	if not visiting and is_instance_valid(actor.get("conversation_target")): return true
	var nav := actor.get_node_or_null("Navigator")
	return nav == null or is_instance_valid(nav.get("_follow_target")) or (not visiting and is_instance_valid(nav.get("_conversation_target")))

func _eligible(id: String, actor: Node3D) -> bool:
	return _eligibility_reason(id, actor).is_empty()

## `day_owner`: her own day step's owner ("day:<id>", request_day_visit) counts as free.
func _eligibility_reason(id: String, actor: Node3D, day_owner := "") -> String:
	if _visitors.has(id): return "already visiting"
	if float(_cooldowns.get(id, 0.0)) > _clock: return "cooldown"
	if _interrupted(actor): return "interaction, sleep or unsupported"
	if not actor.global_position.is_finite() or actor.global_position.distance_to(_restaurant.global_position) > VISIT_RADIUS: return "outside visit radius"
	var nav := actor.get_node_or_null("Navigator")
	var owner := str(nav.get("command_owner"))
	if not (owner.is_empty() or owner == "life:" + id or (not day_owner.is_empty() and owner == day_owner)): return "owned by " + owner.get_slice(":", 0)
	if is_instance_valid(actor.get("flight")) and actor.flight.active(): return "flying"
	if actor.has_meta("social_group"):
		var group: Variant = actor.get_meta("social_group")
		if group is Dictionary and group.get("members", []).size() > 1: return "group outing"
	# A bare go_to/stay may not have an owner (desktop commands). Only known
	# wandering or a living-world lease may be borrowed.
	if owner.is_empty() and (not nav.wander_enabled or (nav.get("_has_target") == true and nav.get("_wandering") != true)): return "unowned player command"
	var life: Node = _game.get("life") as Node
	if is_instance_valid(life) and life.get("core") != null:
		var resident: Dictionary = life.core.state.residents.get(id, {})
		if resident.get("paused", false): return "living world paused"
		var activity: Dictionary = life.core.state.activities.get(resident.get("activity", ""), {})
		if activity.get("members", []).size() > 1: return "group activity"
	if not nav.has_method("command_destination") or not is_instance_valid(nav.get("_service")): return "navigation unavailable"
	return ""

func _recruit(self_service: bool) -> bool:
	if not _open: return false
	_last_recruit = {"time": _clock, "live": 0, "scanned": 0, "rejected": {}, "result": "full"}
	if _visitors.size() >= MAX_VISITORS: return false
	var population := _population()
	if not is_instance_valid(population):
		_last_recruit.result = "population unavailable"
		return false
	var live: Dictionary = population.get("live")
	var ids: Array = live.keys()
	_last_recruit.live = ids.size()
	_last_recruit.result = "no eligible resident"
	if ids.is_empty(): return false
	var candidate := ""
	var nearest := INF
	for n in mini(CANDIDATE_BUDGET, ids.size()):
		var id := str(ids[(_cursor + n) % ids.size()])
		var actor: Node3D = live[id].get("actor") as Node3D
		_last_recruit.scanned += 1
		var rejection: String = _eligibility_reason(id, actor)
		if not rejection.is_empty():
			_last_recruit.rejected[rejection] = int(_last_recruit.rejected.get(rejection, 0)) + 1
			continue
		var distance := actor.global_position.distance_squared_to(_restaurant.global_position)
		if distance < nearest: candidate = id; nearest = distance
	_cursor = (_cursor + CANDIDATE_BUDGET) % ids.size()
	if candidate.is_empty(): return false
	return _claim(candidate, live[candidate].actor, self_service)

## Takes this resident's navigator for one visit, after checking both restaurant markers.
func _claim(candidate: String, actor: Node3D, self_service: bool, owner := "") -> bool:
	var nav := actor.get_node("Navigator")
	var occupied := []
	for visit: Dictionary in _visitors.values(): occupied.append(visit.slot)
	var identity: Resource = actor.get("identity")
	var display_name := str(identity.get("display_name")) if identity != null else candidate.capitalize()
	if display_name.is_empty(): display_name = candidate.capitalize()
	var visit := {"id": candidate, "display_name": display_name, "actor": actor, "nav": nav,
		"owner": owner if not owner.is_empty() else "leisure:hayburger:%d:%s" % [get_instance_id(), candidate], "slot": 0,
		"previous_owner": nav.command_owner, "previous_wander": nav.wander_enabled,
		"previous_speed": nav.command_speed_limit, "previous_pace": nav.command_pace_target,
		"phase": "", "self_service": self_service, "order_id": "", "announced": false,
		"goal": Vector3.INF, "deadline": _clock + TRAVEL_TIMEOUT, "sat": false, "meal": false,
		"pending": "", "pending_phase": "", "door_hold": false}
	# Destination checks happen before claiming anything. No actor is instantiated.
	var found_slot := false
	for slot in MAX_VISITORS:
		if slot in occupied: continue
		visit.slot = slot
		if _destination(visit, "EntrySpawn").is_finite() and _destination(visit, "SelfServePoint" if self_service else "CustomerPoint").is_finite():
			found_slot = true
			break
	if not found_slot:
		_cooldowns[candidate] = _clock + FAILED_VISIT_COOLDOWN
		_last_reason = "Restaurant markers need supported, clear floor"
		_last_recruit.result = _last_reason
		return false
	_visitors[candidate] = visit
	if LEGACY.old_jobs():
		nav.stay()
		nav.command_owner = visit.owner
		nav.command_speed_limit = INF
		nav.command_pace_target = -1.0
		if not self_service: nav.set_meta("player_waiting_route",visit.owner)
		actor.set_meta("hayburger_customer", visit.owner)
	else:
		var opts := {"owner": visit.owner}
		if not self_service: opts["nav_metas"] = {"player_waiting_route": visit.owner}
		# A refused owner leaves the visit unowned; _route then releases it.
		_lease_queue().claim(candidate, actor, {"hayburger_customer": visit.owner}, opts)
	_route(visit, "entry", "EntrySpawn")
	if not _last_recruit.is_empty(): _last_recruit.result = "recruited " + candidate if _visitors.has(candidate) else _last_reason
	return _visitors.has(candidate)

## The confirmed counter shift's customers (board #110): up to `count` eligible residents of the
## loaded town, nearest first, are brought to the street outside the door while the screen is
## dark (the caller's fade), then walk in and queue for the counter. Returns the booked ids.
func book_group(count: int) -> Array[String]:
	var booked: Array[String] = []
	var population := _population()
	if not _open or not _working or not is_instance_valid(population) or not is_instance_valid(_restaurant): return booked
	var live: Dictionary = population.get("live")
	var ranked: Array = []
	for key: Variant in live.keys():
		var id := str(key)
		var actor: Node3D = live[key].get("actor") as Node3D
		if not is_instance_valid(actor): continue
		var reason := _eligibility_reason(id, actor)
		# Distance does not matter here: the whole group is brought to the door.
		if not reason.is_empty() and reason != "outside visit radius": continue
		ranked.append([actor.global_position.distance_squared_to(_restaurant.global_position), id, actor])
	ranked.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var spot := 0
	var wanted_count := mini(count, MAX_VISITORS - _visitors.size())
	for entry: Array in ranked:
		if booked.size() >= wanted_count: break
		var actor: Node3D = entry[2]
		var origin: Transform3D = actor.global_transform
		# Street spots in a row before the door, either side of the incoming lane.
		var placed := false
		while spot < GROUP_ROWS.size() * GROUP_COLUMNS.size() and not placed:
			var wanted: Vector3 = _restaurant.to_global(Vector3(GROUP_COLUMNS[spot % GROUP_COLUMNS.size()], -.04, GROUP_ROWS[spot / GROUP_COLUMNS.size()]))
			spot += 1
			var point := _supported(actor, wanted, .1)
			if not point.is_finite(): continue
			var nav: Node = actor.get_node("Navigator")
			nav.stay()
			if nav.has_method("_native_clear"): nav._native_clear()
			var facing := _restaurant.global_position - point; facing.y = 0.0
			var basis := Basis.looking_at(facing.normalized(), Vector3.UP) if facing.length() > .1 else actor.global_basis
			if actor.has_method("reset_motion"): actor.reset_motion(Transform3D(basis, point))
			else: actor.global_position = point
			placed = true
		if not placed: break
		# A booking that fails puts her straight back (2026-10-25 player report: each bell press
		# left the failed ones standing in the street, and Ponyville emptied).
		if _claim(str(entry[1]), actor, false):
			booked.append(str(entry[1]))
		else:
			_send_back(str(entry[1]), actor, origin)
	_recruit_at = _clock + RECRUIT_SECONDS
	return booked

func _destination(visit: Dictionary, marker_name: String, ponies := true) -> Vector3:
	var marker: Node3D = _markers.get(marker_name)
	if not is_instance_valid(marker) or not marker.is_inside_tree(): return Vector3.INF
	var actor: Node3D = visit.actor
	var profile: Resource = actor.get("profile")
	if profile == null: return Vector3.INF
	var spacing := maxf(1.4, float(profile.radius) * 2.0 + 0.3)
	var side := [0.0, -1.0, 1.0][int(visit.slot)] as float
	var wanted := marker.global_position + marker.global_basis.x.normalized() * side * spacing
	if marker_name == "DeparturePoint":
		# A previous visitor may still be beside the door. Pick a supported free
		# spot on either side, always outside the central incoming lane.
		for offset: float in [0.0, spacing, spacing * 2.0, -6.0, -6.0 - spacing]:
			var candidate: Vector3 = marker.global_position + marker.global_basis.x.normalized() * offset
			var supported: Vector3 = _supported(actor, candidate, .2, ponies)
			if supported.is_finite(): return supported
		return Vector3.INF
	var supported := _supported(actor, wanted, 0.0, ponies)
	# The street beside the door is narrow: a group lines up through the doorway's centre
	# instead (the navigator's peer passage handles the queue), each keeping its counter slot.
	if marker_name == "EntrySpawn" and not supported.is_finite() and side != 0.0:
		supported = _supported(actor, marker.global_position, 0.0, ponies)
	return supported

## `ponies` false ignores other ponies' bodies: only floor, walls and furniture count.
func _supported(actor: Node3D, wanted: Vector3, extra_radius := 0.0, ponies := true) -> Vector3:
	if not wanted.is_finite(): return Vector3.INF
	var profile: Resource = actor.get("profile")
	var space := actor.get_world_3d().direct_space_state
	var excludes: Array[RID] = []
	if actor is CollisionObject3D: excludes.append(actor.get_rid())
	var center := Vector3.INF
	var radius := float(profile.radius) + extra_radius
	for offset: Vector3 in [Vector3.ZERO, Vector3.RIGHT * radius, Vector3.LEFT * radius, Vector3.FORWARD * radius, Vector3.BACK * radius]:
		var start := wanted + offset + Vector3.UP * 0.5
		var finish := wanted + offset - Vector3.UP * 0.75
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(start, finish, 1, excludes))
		if hit.is_empty() or hit.normal.y < cos(deg_to_rad(profile.max_slope_degrees)): return Vector3.INF
		if not center.is_finite(): center = hit.position
		if absf(hit.position.y - center.y) > float(profile.step_height): return Vector3.INF
		if not space.intersect_ray(PhysicsRayQueryParameters3D.create(start, hit.position + Vector3.DOWN * .02, 1 << 15, excludes)).is_empty(): return Vector3.INF
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = profile.clearance
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform.origin = center + Vector3.UP * (shape.height * .5 + .06)
	query.collision_mask = 1 | 2048 | (PONY_LAYER if ponies else 0)
	query.exclude = excludes
	if not space.intersect_shape(query, 1).is_empty(): return Vector3.INF
	return center + Vector3.UP * .03

func _owned(visit: Dictionary) -> bool:
	return is_instance_valid(visit.actor) and is_instance_valid(visit.nav) and visit.nav.command_owner == visit.owner

## Chatting with a customer (board #307, thread 2026-11-01): her reply's [approach], [sit] or [stay]
## tag took her navigator and the visit ended as if she had left, cancelling her order. The lease
## takes it back (customer_queue.gd reclaim_from_model) and she resumes this leg; moved off the
## counter or kiosk spot, she walks back to it and is served once she is there again.
func _reclaim(visit: Dictionary) -> void:
	if not is_instance_valid(visit.actor) or not QUEUE.reclaim_from_model(visit.nav, visit.owner): return
	print("[hayburger] customer %s keeps her visit: a reply tag had taken her navigation" % visit.id)
	if not str(visit.pending).is_empty() or visit.get("door_hold", false) or visit.phase in ["eating", "rising"]: return
	var via: Vector3 = visit.get("via", Vector3.INF)
	var goal: Vector3 = via if via.is_finite() else visit.goal
	if not goal.is_finite() or _at_position(visit, goal): return
	if visit.phase in ["counter", "kiosk"]: visit.returning = true
	if not visit.nav.command_destination(goal, "trot"): _release(visit.id, "Navigator refused destination")

func _route(visit: Dictionary, phase: String, marker: String) -> void:
	if not _owned(visit): _release(visit.id, "Navigation ownership changed"); return
	# One way through the door at a time: walking out waits for whoever is still coming in.
	if phase == "exiting" and _crossing(visit, true):
		_wait(visit, phase, marker, true); return
	var target: Vector3 = _destination(visit, marker)
	if not target.is_finite():
		# Only a pony stands there: wait for her to move on instead of turning round. Once
		# outside, a crowded departure spot just ends the visit there (she is out of the lane).
		if phase != "leaving" and _destination(visit, marker, false).is_finite(): _wait(visit, phase, marker, false); return
		_release(visit.id, "Destination is obstructed or unsupported"); return
	visit.pending = ""
	visit.phase = phase
	visit.goal = target
	visit.deadline = _clock + TRAVEL_TIMEOUT
	visit.via = Vector3.INF
	# The kiosk is beside the door. A straight approach from outside cuts the
	# jamb clearance and waits for a town-wide queued detour. Walk through the
	# centre aisle first, in both directions; the navigator still certifies every
	# step and owns motion. Self-service keeps ordinary route priority.
	var doorway: Node3D = _markers.get("ExitPoint")
	var kiosk: Node3D = _markers.get("SelfServePoint")
	var actor: Node3D = visit.actor
	if is_instance_valid(doorway) and is_instance_valid(kiosk):
		var inside: Vector3 = _restaurant.to_local(doorway.global_position)
		var kiosk_local: Vector3 = _restaurant.to_local(kiosk.global_position)
		inside.y = kiosk_local.y
		# Leave turning room in front of the kiosk's projecting counter edge.
		inside.z = kiosk_local.z - .8
		var actor_local: Vector3 = _restaurant.to_local(actor.global_position)
		if (marker == "SelfServePoint" and actor_local.z > inside.z + .55) or phase == "exiting":
			var via: Vector3 = _supported(actor, _restaurant.to_global(inside))
			if not via.is_finite() and _supported(actor, _restaurant.to_global(inside), 0.0, false).is_finite():
				_wait(visit, phase, marker, false); return
			if not via.is_finite(): _release(visit.id, "Doorway aisle is obstructed or unsupported"); return
			if not _at_position(visit, via): visit.via = via
	var next_goal: Vector3 = visit.via if visit.via.is_finite() else target
	if not visit.nav.command_destination(next_goal, "trot"):
		_release(visit.id, "Navigator refused destination")

## Stands still and retries this leg every check. A door wait is not a failure and never runs
## out by itself (whoever she waits for has her own deadline); a pony on the spot gets one leg's time.
func _wait(visit: Dictionary, phase: String, marker: String, door: bool) -> void:
	if str(visit.get("pending", "")).is_empty() or door: visit.deadline = _clock + TRAVEL_TIMEOUT
	visit.pending = marker
	visit.pending_phase = phase
	visit.phase = phase
	visit.goal = Vector3.INF
	visit.via = Vector3.INF
	visit.nav.stay()

## Another customer using the doorway the other way. `inward` asks about customers coming in:
## walking from near the street door towards the counter or kiosk, until well inside. Otherwise
## it asks about customers on their way out (a waiting one does not count).
func _crossing(visit: Dictionary, inward: bool) -> bool:
	for other: Dictionary in _visitors.values():
		if other == visit or not is_instance_valid(other.actor) or not str(other.get("pending", "")).is_empty(): continue
		if not inward:
			if other.phase == "exiting": return true
			continue
		var local: Vector3 = _restaurant.to_local((other.actor as Node3D).global_position)
		if other.phase == "service" and local.z > DOOR_INSIDE_Z: return true
		if other.phase == "entry" and not other.get("door_hold", false) and other.goal.is_finite() and _near(other, other.goal, DOOR_APPROACH): return true
	return false

## The navigator stopped her short of this leg's spot because a pony stands on it (its arrival at
## the nearest reachable spot). Nothing moves her on from there: before 2026-10-31 she parked in
## the walkway until the visit timed out (tools/hayburger/test_doorway_traffic.gd). Callers ask
## for the leg again, which picks a free spot or waits for this one (_route).
func _stopped_short(visit: Dictionary) -> bool:
	var nav: Node = visit.nav
	return nav.state == nav.State.ARRIVED and bool(nav.arrival_alternative)

func _at_goal(visit: Dictionary) -> bool:
	return _at_position(visit, visit.goal)

func _near(visit: Dictionary, position: Vector3, reach: float) -> bool:
	var actor: Node3D = visit.actor
	var difference: Vector3 = actor.global_position - position
	return Vector2(difference.x, difference.z).length() <= reach and absf(difference.y) <= .5

func _at_position(visit: Dictionary, position: Vector3) -> bool:
	var actor: Node3D = visit.actor
	var difference: Vector3 = actor.global_position - position
	return Vector2(difference.x, difference.z).length() <= .55 and absf(difference.y) <= .5 and actor.has_method("grounded") and actor.grounded()

func _advance(id: String) -> void:
	if not _visitors.has(id): return
	var visit: Dictionary = _visitors[id]
	var population := _population()
	_reclaim(visit)
	if not _owned(visit) or not is_instance_valid(population) or population.live.get(id, {}).get("actor") != visit.actor:
		_release(id, "Resident or navigation ownership changed"); return
	if _interrupted(visit.actor, true): _release(id, "Player interaction or sleep took priority"); return
	if _clock >= float(visit.deadline):
		if visit.phase == "counter": _leave(visit, "Counter wait expired")
		else: _release(id, "Visit timed out")
		return
	var nav: Node = visit.nav
	if nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]: _release(id, "No safe route: " + str(nav.reason)); return
	# Waiting for the doorway or for a pony on her spot: try the leg again.
	if not str(visit.pending).is_empty():
		_route(visit, str(visit.pending_phase), str(visit.pending)); return
	var via: Vector3 = visit.get("via", Vector3.INF)
	if via.is_finite():
		# The aisle point only lines the doorway up: stopped beside a pony standing on it (the
		# navigator's arrival at the nearest reachable spot), she walks on to the leg's goal.
		if not _at_position(visit, via) and not _stopped_short(visit): return
		visit.via = Vector3.INF
		if not nav.command_destination(visit.goal, "trot"):
			_release(id, "Navigator refused destination")
		return
	match visit.phase:
		"entry":
			# Someone is walking out: wait short of the door instead of meeting her in it.
			if _near(visit, visit.goal, DOOR_APPROACH) and _crossing(visit, false):
				if not visit.door_hold:
					visit.door_hold = true
					nav.stay()
				visit.deadline = _clock + TRAVEL_TIMEOUT
				return
			if visit.door_hold:
				visit.door_hold = false
				if not nav.command_destination(visit.goal, "trot"): _release(id, "Navigator refused destination"); return
			# The doorway point only lines the approach up; another customer may stand on it.
			if _at_goal(visit) or _near(visit, visit.goal, 1.2): _route(visit, "service", "SelfServePoint" if visit.self_service else "CustomerPoint")
			elif _stopped_short(visit): _route(visit, "entry", "EntrySpawn")
		"service":
			if not _at_goal(visit):
				if _stopped_short(visit): _route(visit, "service", "SelfServePoint" if visit.self_service else "CustomerPoint")
				return
			nav.stay()
			if visit.self_service:
				visit.phase = "kiosk"
				visit.until = _clock + _rng.randf_range(3.0, 6.0)
			else:
				visit.phase = "counter"
				visit.deadline = _clock + COUNTER_TIMEOUT
				visit.announced = true
				customer_arrived.emit(id, visit.display_name)
		"counter":
			# Walking back after a reply tag moved her (_reclaim): the counter deadline bounds it.
			if _at_goal(visit): visit.returning = false
			elif not visit.get("returning", false): _release(id, "Left the counter")
		"kiosk":
			if _at_goal(visit): visit.returning = false
			elif not visit.get("returning", false): _release(id, "Left the kiosk"); return
			else: return
			if _clock >= float(visit.until): _eat(visit)
		"eating":
			if _clock >= float(visit.until):
				# Stay seated while a customer is still on her way in through the door.
				if _crossing(visit, true):
					visit.until = _clock + CHECK_SECONDS
					visit.deadline = float(visit.until) + 5.0
					return
				if _in_booth(visit):
					# Up from the booth first: the seating service hops her down to the aisle.
					visit.actor.request_posture("stand")
					visit.phase = "rising"
					visit.deadline = _clock + 15.0
					return
				var self_service: bool = visit.self_service
				_leave(visit, "Finished meal")
				if self_service: self_serve_completed.emit(id, visit.display_name)
		"rising":
			if not _seating_phase(visit.actor).is_empty(): return
			_left_booth(visit)
			var was_self_service: bool = visit.self_service
			_leave(visit, "Finished meal")
			if was_self_service: self_serve_completed.emit(id, visit.display_name)
		"exiting":
			# A metre from the clearance point is well outside the door: no need to squeeze
			# onto the exact spot past ponies standing in front of the restaurant.
			if _at_goal(visit) or _near(visit, visit.goal, 1.0):
				if is_instance_valid(_markers.get("DeparturePoint")): _route(visit, "leaving", "DeparturePoint")
				else: _release(id, "Back to the daily routine")
			elif _stopped_short(visit): _route(visit, "exiting", "EntryClearance" if is_instance_valid(_markers.get("EntryClearance")) else "EntrySpawn")
		"leaving":
			if _at_goal(visit) or _near(visit, visit.goal, 1.2): _release(id, "Back to the daily routine")
			elif _stopped_short(visit): _route(visit, "leaving", "DeparturePoint")

func _eat(visit: Dictionary) -> void:
	_clear_priority(visit)
	visit.meal = true
	visit.phase = "eating"
	# Long enough to chat with the customer you just served (player bug board #29); a day-plan
	# meal lasts its step's minutes.
	visit.until = _clock + (float(visit.eat_seconds) if visit.has("eat_seconds") else _rng.randf_range(20.0, 40.0))
	visit.deadline = float(visit.until) + 5.0
	visit.nav.stay()
	var actor: Node3D = visit.actor
	# A booth seat at a table (board #348) when one is free; else she sits where she stands.
	if _take_booth(visit):
		# The walk to the seat and the hop take a while; the meal clock waits for them.
		visit.until = float(visit.until) + 8.0
		visit.deadline = float(visit.until) + 20.0
	elif actor.has_method("request_posture") and _supported(actor, actor.global_position, .2).is_finite():
		visit.sat = actor.request_posture("sit")
	_withdraw(visit)

func _withdraw(visit: Dictionary) -> void:
	if not visit.announced: return
	visit.announced = false
	customer_departed.emit(visit.id)

func _leave(visit: Dictionary, reason: String) -> void:
	_last_reason = reason
	visit.phase = "leaving"
	_withdraw(visit)
	if not _visitors.has(visit.id): return
	if visit.sat and _owned(visit): visit.actor.request_posture("stand"); visit.sat = false
	_route(visit, "exiting", "EntryClearance" if is_instance_valid(_markers.get("EntryClearance")) else "EntrySpawn")

func _release(id: String, reason: String) -> void:
	if not _visitors.has(id): return
	var visit: Dictionary = _visitors[id]
	_visitors.erase(id)
	if _in_booth(visit) and is_instance_valid(visit.actor) and visit.actor.get("sleeping") != true: visit.actor.request_posture("stand")
	_left_booth(visit)
	_clear_priority(visit)
	# A failed route never served a meal. Give navigation/geometry time to
	# recover, without banning that resident for the rest of a three-minute shift.
	_cooldowns[id] = _clock + (COOLDOWN_SECONDS if visit.get("meal", false) else FAILED_VISIT_COOLDOWN)
	_last_reason = reason
	# One line per ended visit, so a player log shows why customers turned back at the door.
	if not visit.get("meal", false): print("[hayburger] customer %s gave up in %s: %s" % [id, str(visit.get("phase", "")), reason])
	if not LEGACY.old_jobs():
		# The shared lease restores the four navigation fields, removes its metas and reissues the
		# living world's goal while it still owns her; the cooldown was set above.
		if _lease_queue().release(id, reason, -1.0) and visit.sat and visit.actor.get("sleeping") != true and not _interrupted(visit.actor, true):
			visit.actor.request_posture("stand")
	elif _owned(visit):
		visit.nav.stay()
		visit.nav.command_owner = visit.previous_owner
		visit.nav.wander_enabled = visit.previous_wander
		visit.nav.command_speed_limit = visit.previous_speed
		visit.nav.command_pace_target = visit.previous_pace
		if visit.sat and visit.actor.get("sleeping") != true and not _interrupted(visit.actor, true): visit.actor.request_posture("stand")
		# Invalidate the living-world cached goal even when acquired/released within
		# its observation interval; it must reissue the paused outing's route.
		_reissue_life_goal(id)
	if is_instance_valid(visit.actor) and visit.actor.get_meta("hayburger_customer", "") == visit.owner:
		visit.actor.remove_meta("hayburger_customer")
	_withdraw(visit)

func _send_back(id: String, actor: Node3D, origin: Transform3D) -> void:
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav != null: nav.stay()
	if actor.has_method("reset_motion"): actor.reset_motion(origin)
	else: actor.global_transform = origin
	_reissue_life_goal(id)

func _lease_queue() -> RefCounted:
	if _leases == null:
		_leases = QUEUE.new()
		_leases.owner_prefix = "leisure:hayburger:%d:" % get_instance_id()
		_leases.max_customers = MAX_VISITORS
		_leases.cooldown_s = COOLDOWN_SECONDS
		_leases.radius = VISIT_RADIUS
	_leases.cooldowns = _cooldowns
	_leases.clock = _clock
	_leases.population = _population()
	_leases.life = _game.get("life") as Node if is_instance_valid(_game) else null
	return _leases

## The living world caches each pony's goal; clearing it makes it reissue her paused outing's route.
func _reissue_life_goal(id: String) -> void:
	var life: Node = _game.get("life") as Node if is_instance_valid(_game) else null
	if is_instance_valid(life) and life.get("actors") is Dictionary and life.actors.has(id): life.actors[id].goal = Vector3.INF

func _clear_priority(visit: Dictionary) -> void:
	if is_instance_valid(visit.nav) and visit.nav.get_meta("player_waiting_route", "") == visit.owner:
		visit.nav.remove_meta("player_waiting_route")

func _exit_tree() -> void:
	release_all()
