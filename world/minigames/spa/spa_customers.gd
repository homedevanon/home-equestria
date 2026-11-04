extends Node
## Ponyville Day Spa controller (docs/SPA_PLAN_2026_10_29.md steps 7-10, wave 1). Live population
## clients only: the navigator stays the movement writer, and the claim/release logic is a COPY of
## world/minigames/hayburger/hayburger_customers.gd (not shared, so the Hayburger never changes).
##
## Flow per client: lobby -> footbath (soak, the player files both front hooves) -> single-file rub
## line -> massage table (one at a time: she hops up and lies down, the player rubs each back hoof
## slowly, she hops down) -> wing cushion (pegasi:
## massage, preening, stray feathers) -> SPA_DOOR_IN -> SPA_DOOR_OUT -> released to her normal life.
## The player's hands are in spa_hands.gd; it, or a fixture, reports progress through file_stroke(),
## rub(), wing_massage(), preen_stroke() and pluck(). Pay goes to the existing wallet
## (inventory_store.credit_bits) only for a real, present client who finished the step.
##
## Markers (venue-local Transform3D, -Z = the way she or the player faces; see marker_names()):
## setup(game, venue, markers) or venue.spa_markers(). SPA_RUB_TABLE is her root lying on the
## massage table's pad; SPA_RUB_SPOT is the floor at the table's foot, where she hops up and down.
##
## Romance firewall: every client carries set_meta("spa_client", true) while claimed; wave 2 makes
## the pony/relationship side read it. Nothing here calls relationship or AI code.
## TODO(wave 2) items are marked in place and listed in the spa report.
signal client_arrived(pony_id: String, display_name: String)
signal service_finished(pony_id: String, service: String, bits: int)
signal bits_paid(pony_id: String, amount: int, at: Vector3, what: String)
signal client_left(pony_id: String, reason: String)
signal reaction(pony_id: String, kind: String)

const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const COVER := preload("res://world/ui/sleep_cover.gd")
const FEATHERS := preload("res://world/minigames/spa/spa_feathers.gd")
const WINGS := preload("res://world/characters/hybrid_mare/hybrid_open_wings.gd")
const ROSTER := preload("res://world/navigation/roster_placement.gd")
const KIT_SPOTS := preload("res://world/props/ponyville_kit/kit_spots.gd")
const LEDGER := preload("res://world/mechanics/ledger.gd")
const FACTS := preload("res://world/mechanics/facts.gd")
const LEGACY := preload("res://world/mechanics/legacy.gd")
const QUEUE := preload("res://world/mechanics/jobs/customer_queue.gd")
const JOBS := preload("res://world/mechanics/jobs/jobs.gd")

const OPEN_HOUR := 9.0
const CLOSE_HOUR := 19.0
const MAX_CLIENTS := 3
const CHECK_SECONDS := 0.25
const VISIT_RADIUS := 180.0
const COOLDOWN_SECONDS := 240.0
const FAILED_VISIT_COOLDOWN := 8.0
## The Hayburger's 120 s: a pony from the edge of VISIT_RADIUS walking at ~1 m/s still arrives.
const TRAVEL_TIMEOUT := 120.0
## No service progress for this long at a station and she leaves (no pay for what is left).
const PATIENCE := 300.0
## Leaving: no 0.3 m of progress for STUCK_SECONDS (or LEAVE_TIMEOUT in all) and she is released
## and placed on the street out of view, so nobody stays trapped inside.
const STUCK_SECONDS := 20.0
const LEAVE_TIMEOUT := 90.0
const LOBBY_PAUSE := 2.5
const SERVICES: Array[String] = ["file", "rub", "wings"]
## Pay (plan section 8: decided). Same for fillies. The footbath files both front hooves; the
## table files and then massages both back hooves (dev 2026-10-29: "massage AND file their front
## AND rear hooves", then "remove massaging from the forehooves": a raised hoof cannot be rubbed up
## the leg). Each station keeps its price.
const PAY := {"file": 10, "rub": 10, "wings": 4}
const PAY_FEATHER := 1
## Filing: strokes per front hoof, how near the player is when she lifts it, and how long one
## raise() holds (spa body lab: raise() holds as long as asked; 30 s measured).
const FILE_STROKES := 12
const PLAYER_NEAR := 1.8
const RAISE_SECONDS := 60.0
## Rub (plan 3.B): seconds of good slow rubbing per back hoof.
const RUB_SECONDS := 25.0
## The tail swings this far aside (radians, hybrid_tail_motion.aside_goal) off the back hoof
## being worked on, so it is not in the way.
const TAIL_ASIDE := 0.55
## Massage table (dev 2026-10-29: "the backhoof massage needs to happen on a table"; it replaced
## the rub block and its scripted hind-hoof hold). She walks to the table's side, hops up in an
## arc (cradle_rest.gd's bed hop) and lies stretched out like a lifesize plush (lie style "stretch",
## pony_posture.gd), back hooves straight back at the table's foot where the player stands
## (tools/spa/spa_table_lab.gd). Then she stands and hops back down.
const HOP_SECONDS := 0.7
## An adult's back hooves lie this far behind her root in the "stretch" lie style.
const HIND_REACH := 0.72
## Arc height over the straight line, x size: clears the pad's edge (0.62 m) halfway along.
const HOP_ARC := 0.45
const CLIMB_PAUSE := 0.6
## Stalled this near the table's foot spot, she hops up from where she is.
const CLIMB_REACH := 1.4
## Stalled this near any other station for STALL_SECONDS, she takes it from there.
const STALL_REACH := 1.2
const STALL_SECONDS := 2.5
## Lying down or standing up on the table: settled within this, or she leaves.
const SETTLE_TIMEOUT := 8.0
## Wings (plan 3.C).
const WING_SECONDS := 20.0
## The wing hold (hybrid_open_wings.hold_at): 1 = the Blender-posed half-open spread. As the
## massage goes on she relaxes them a little wider, down to WING_HOLD_WIDEST.
const WING_HOLD := 1.0
const WING_HOLD_WIDEST := 0.75
const PREEN_CREDIT := 1.0
const FEATHERS_MIN := 2
const FEATHERS_MAX := 4
const BASKET_REACH := 0.3
const BLOCK_CLEAR := 0.9
const STAFF: Array[String] = ["aloe", "lotus_blossom"]
## Clients waiting their turn may chat with each other (dev 2026-10-29: "have a chance they'll talk
## to eachother"). pony_ambient_chatter.gd reads meta "spa_company" as her company (they are
## preferred, like friends on an outing); a client being served carries none and is left out, so a
## chat never pauses the player's work on her.
const CHAT_PHASES: Array[String] = ["lobby", "queued", "line", "wing_wait"]

var hours_override := -1.0
## Fixtures (and a future pony-form player) may stand in for the player's head.
var player_override: Node3D

var _game: Node
var _venue: Node3D
var _markers: Dictionary = {}
var _visits: Dictionary = {}
var _cooldowns: Dictionary = {}
var _rub_queue: Array[String] = []
var _rub_owner := ""
var _wing_owner := ""
var _clock := 0.0
var _check := 0.0
var _transition := false
var _rng := RandomNumberGenerator.new()
var _last_reason := ""
var earned_bits := 0
## The jobs core's shared lease bookkeeping (world/mechanics/jobs/customer_queue.gd); `-- --old-jobs`
## keeps the copied code. It shares this node's cooldowns.
var _leases: RefCounted


static func marker_names() -> Array[String]:
	var names: Array[String] = ["SPA_DOOR_OUT", "SPA_DOOR_IN", "SPA_COUNTER", "SPA_BELL", "SPA_RUB_TABLE", "SPA_RUB_SPOT",
		"SPA_WING_CUSHION", "SPA_FEATHER_BASKET", "SPA_PLAYER_FILE", "SPA_PLAYER_RUB", "SPA_PLAYER_WING"]
	for n in range(1, 4):
		names.append("SPA_LOBBY_WAIT_%d" % n); names.append("SPA_BATH_%d" % n); names.append("SPA_RUB_LINE_%d" % n)
	return names


func setup(game: Node, venue: Node3D, markers: Dictionary = {}) -> void:
	release_all()
	_game = game
	_venue = venue
	_markers.clear()
	var source: Dictionary = markers
	if source.is_empty() and is_instance_valid(venue) and venue.has_method("spa_markers"): source = venue.spa_markers()
	for key: Variant in source:
		if source[key] is Transform3D: _markers[str(key)] = source[key]
	_rng.randomize()
	process_mode = Node.PROCESS_MODE_PAUSABLE
	# After the navigators (-10), before the pony bodies (0), like pony_affection.gd.
	process_physics_priority = -5
	set_physics_process(true)


func has_marker(marker_name: String) -> bool:
	return _markers.has(marker_name)


## World transform of a marker (venue-local in the contract).
func marker(marker_name: String) -> Transform3D:
	var local: Transform3D = _markers.get(marker_name, Transform3D(Basis(), Vector3.INF))
	if not local.origin.is_finite(): return local
	return venue_transform() * local


func venue_transform() -> Transform3D:
	return _venue.global_transform if is_instance_valid(_venue) and _venue.is_inside_tree() else Transform3D.IDENTITY


static func facing(xf: Transform3D) -> Vector3:
	var forward := -xf.basis.z
	forward.y = 0.0
	return forward.normalized() if forward.length() > 0.001 else Vector3.FORWARD


func is_open_now() -> bool:
	var hours := hours_override
	if hours < 0.0:
		var clock: Node = get_node_or_null("/root/TimeOfDay")
		hours = float(clock.get("hours")) if clock != null else 12.0
	return hours >= OPEN_HOUR and hours < CLOSE_HOUR


func is_client(pony_id: String) -> bool:
	return _visits.has(pony_id)


func clients() -> Array:
	return _visits.keys()


func visit_phase(pony_id: String) -> String:
	return str(_visits.get(pony_id, {}).get("phase", ""))


func report() -> Dictionary:
	var rows := []
	for id: String in _visits:
		var visit: Dictionary = _visits[id]
		rows.append({"id": id, "name": visit.display_name, "phase": visit.phase, "services": visit.services.duplicate(),
			"file": visit.file_strokes.duplicate(), "rub": [snappedf(visit.rub_good[0], .1), snappedf(visit.rub_good[1], .1)],
			"stage": visit.stage, "rear_file": visit.rear_strokes.duplicate(),
			"wings": snappedf(visit.wing_good, .1), "feathers": "%d/%d" % [visit.plucked, visit.feathers_total], "paid": visit.paid})
	return {"open": is_open_now(), "clients": rows, "rub_queue": _rub_queue.duplicate(), "rub_owner": _rub_owner,
		"wing_owner": _wing_owner, "earned_bits": earned_bits, "last_reason": _last_reason}


# ------------------------------------------------------------------ opening: the bell

## Ringing the counter bell during opening hours books the 3 nearest free ponies into the lobby
## waiting spots, all during ONE fade (no second fade). Ring again once the spa is empty.
## In the same fade every other pony inside goes to a random public spot in town (a bench, well
## or stump), so the room is not crowded (dev 2026-10-29: "it kicks everypony who's in it").
## Returns the booked ids (empty when closed, busy or nobody is free).
func ring_bell() -> Array[String]:
	var booked: Array[String] = []
	if _transition or not is_open_now() or not _visits.is_empty(): return booked
	_transition = true
	var cover := _cover()
	if cover != null:
		_lock_player(true)
		await cover.close_eyes()
		if not _still_here(cover): return booked
	clear_room()
	booked = book_group(MAX_CLIENTS)
	if cover != null:
		if not await SHUTDOWN.seconds(self, 0.5) or not _still_here(cover): return booked
		await cover.open_eyes()
		if not _still_here(cover): return booked
		cover.finish()
		_lock_player(false)
	_transition = false
	return booked


## Every pony inside the spa that is not a client, staff, held or following the player goes to a
## random public kit spot in town (or the street spot outside when none has ground under it).
## Call it while the screen is dark. Returns how many were moved.
func clear_room() -> int:
	var population := _population()
	if not is_instance_valid(population) or not is_instance_valid(_venue) or not _venue.has_method("is_inside"): return 0
	var moved := 0
	var live: Dictionary = population.get("live")
	for key: Variant in live.keys():
		var id := str(key)
		var actor: Node3D = live[key].get("actor") as Node3D
		if not is_instance_valid(actor) or not actor.is_inside_tree() or _visits.has(id) or id in STAFF: continue
		if not _venue.is_inside(actor.global_position): continue
		if actor.get_meta("active_follow", false) or (actor.has_method("is_held") and actor.is_held()): continue
		var nav: Node = actor.get_node_or_null("Navigator")
		if nav == null or is_instance_valid(nav.get("_follow_target")): continue
		var point := _town_spot(actor)
		if not point.is_finite(): point = _supported(actor, marker("SPA_DOOR_OUT").origin, false)
		if not point.is_finite(): continue
		nav.stay()
		if nav.has_method("_native_clear"): nav._native_clear()
		if actor.get("sleeping") == true: actor.set("sleeping", false)
		actor.request_posture("stand")
		var away := Vector3(_rng.randf_range(-1.0, 1.0), 0.0, _rng.randf_range(-1.0, 1.0))
		var basis := Basis.looking_at(away.normalized() if away.length() > .1 else Vector3.FORWARD, Vector3.UP)
		if actor.has_method("reset_motion"): actor.reset_motion(Transform3D(basis, point))
		else: actor.global_transform = Transform3D(basis, point)
		_reissue_life_goal(id)
		moved += 1
	return moved


## A random public kit spot's approach point with ground under it, or INF.
func _town_spot(actor: Node3D) -> Vector3:
	KIT_SPOTS._index()
	var ids: Array = []
	for kind: String in KIT_SPOTS.PUBLIC: ids.append_array(KIT_SPOTS._by_kind.get(kind, []))
	if ids.is_empty() or actor.get("profile") == null: return Vector3.INF
	var space := actor.get_world_3d().direct_space_state
	var exclude: Array[RID] = []
	if actor is CollisionObject3D: exclude.append(actor.get_rid())
	for attempt in 16:
		var record := KIT_SPOTS.by_id(str(ids[_rng.randi() % ids.size()]))
		var approach: Vector3 = record.get("approach", Vector3.INF)
		if not approach.is_finite() or (is_instance_valid(_venue) and _venue.is_inside(approach)): continue
		var point := ROSTER.support(space, approach, actor.profile, null, exclude)
		if point.is_finite(): return point
	return Vector3.INF


## Nearest eligible residents (any distance), placed straight onto the lobby spots. Call it while
## the screen is dark (ring_bell does). Fillies are welcome; pegasi also get the wing service.
func book_group(count: int) -> Array[String]:
	var booked: Array[String] = []
	var population := _population()
	if not is_open_now() or not is_instance_valid(population) or not _stations_ready(): return booked
	var live: Dictionary = population.get("live")
	var ranked: Array = []
	var centre := marker("SPA_DOOR_IN").origin
	var door_service := _door_service()
	for key: Variant in live.keys():
		var id := str(key)
		var actor: Node3D = live[key].get("actor") as Node3D
		if not is_instance_valid(actor): continue
		var reason := _eligibility_reason(id, actor)
		if not reason.is_empty() and reason != "outside visit radius": continue
		# Far ponies only from the walk grid that covers the spa: a pony from another zone keeps
		# that zone's grid, and her navigator would refuse every route inside the spa.
		if reason == "outside visit radius" and (door_service == null or actor.get_node("Navigator").get("_service") != door_service): continue
		ranked.append([actor.global_position.distance_squared_to(centre), id, actor])
	ranked.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var wanted := mini(count, MAX_CLIENTS - _visits.size())
	for entry: Array in ranked:
		if booked.size() >= wanted: break
		var id := str(entry[1])
		var actor: Node3D = entry[2]
		var origin: Transform3D = actor.global_transform
		var slot := _free_slot()
		if slot < 0: break
		var spot := marker("SPA_LOBBY_WAIT_%d" % (slot + 1))
		var point := _supported(actor, spot.origin, false)
		if not point.is_finite(): continue
		if not _claim(id, actor, _full_services(actor), slot, "lobby"):
			continue
		var nav: Node = actor.get_node("Navigator")
		nav.stay()
		if nav.has_method("_native_clear"): nav._native_clear()
		var basis := Basis.looking_at(facing(spot), Vector3.UP)
		if actor.has_method("reset_motion"): actor.reset_motion(Transform3D(basis, point))
		else: actor.global_transform = Transform3D(basis, point)
		var visit: Dictionary = _visits[id]
		visit.until = _clock + LOBBY_PAUSE + slot * 1.5
		if not _owned(visit):
			_release(id, "Lost navigation while booking")
			_send_back(id, actor, origin)
			continue
		booked.append(id)
		client_arrived.emit(id, visit.display_name)
	return booked


## For the letters/appointments team: send one loaded, free pony for a service ("file", "rub",
## "wings" or "full"). She walks in from wherever she is. False when closed, full, ineligible or
## the service does not suit her (wings need a pegasus).
func request_service(pony_id: String, service: String) -> bool:
	if not is_open_now() or _visits.size() >= MAX_CLIENTS or not _stations_ready(): return false
	var population := _population()
	if not is_instance_valid(population): return false
	var actor: Node3D = population.live.get(pony_id, {}).get("actor") as Node3D
	if not is_instance_valid(actor) or not _eligibility_reason(pony_id, actor).is_empty(): return false
	var services: Array[String] = []
	if service == "full": services = _full_services(actor)
	elif service in SERVICES: services.append(service)
	else: return false
	if services.has("wings") and not _pegasus(actor): return false
	var slot := _free_slot()
	if slot < 0: return false
	if not _claim(pony_id, actor, services, slot, "arriving"): return false
	_route(_visits[pony_id], "arriving", marker("SPA_DOOR_OUT").origin)
	return _visits.has(pony_id)


func _full_services(actor: Node3D) -> Array[String]:
	var services: Array[String] = ["file", "rub"]
	if _pegasus(actor): services.append("wings")
	return services


## Pegasi only; princess (alicorn) wings rest differently and come later.
static func _pegasus(actor: Node3D) -> bool:
	var identity: Resource = actor.get("identity")
	return identity != null and int(identity.get("race")) == 1


func _stations_ready() -> bool:
	for name: String in ["SPA_DOOR_OUT", "SPA_DOOR_IN", "SPA_RUB_TABLE", "SPA_RUB_SPOT", "SPA_WING_CUSHION",
			"SPA_LOBBY_WAIT_1", "SPA_LOBBY_WAIT_2", "SPA_LOBBY_WAIT_3", "SPA_BATH_1", "SPA_BATH_2", "SPA_BATH_3",
			"SPA_RUB_LINE_1", "SPA_RUB_LINE_2", "SPA_RUB_LINE_3"]:
		if not _markers.has(name): return false
	return true


func _free_slot() -> int:
	var used := []
	for visit: Dictionary in _visits.values(): used.append(int(visit.slot))
	for slot in MAX_CLIENTS:
		if not slot in used: return slot
	return -1


# ------------------------------------------------------------------ claim and release (copied)

func _population() -> Node:
	return _game.get("population") as Node if is_instance_valid(_game) else null


## Reasons that end a visit at once: picked up, asleep, following, flying, gone, or taken over.
func _hard_interrupt(actor: Node3D) -> String:
	if not is_instance_valid(actor) or not actor.is_inside_tree(): return "gone"
	if actor.get("sleeping") == true: return "asleep"
	if actor.get_meta("active_follow", false): return "following"
	if actor.has_method("is_held") and actor.is_held(): return "picked up"
	if is_instance_valid(actor.get("flight")) and actor.flight.active(): return "flying"
	var nav := actor.get_node_or_null("Navigator")
	if nav == null or is_instance_valid(nav.get("_follow_target")): return "following"
	return ""


## Reasons that only pause her (she waits and resumes): talking, petting, a paused body.
## `talking` false: a client already visiting chats with Anon without her visit stopping; talk
## used to freeze the bath, filing and massage until the chat ended (player report 2026-10-30).
func _soft_busy(actor: Node3D, talking := true) -> bool:
	if actor.get("motion_paused") == true: return true
	if talking and is_instance_valid(actor.get("conversation_target")): return true
	if talking and is_instance_valid(_game) and _game.has_method("_population_busy") and _game._population_busy(actor): return true
	var nav := actor.get_node_or_null("Navigator")
	return talking and nav != null and is_instance_valid(nav.get("_conversation_target"))


## Hayburger's eligibility, copied: free, loaded, awake, not held/following/talking/in a group.
func _eligibility_reason(id: String, actor: Node3D) -> String:
	if _visits.has(id): return "already visiting"
	if id in STAFF: return "spa staff"
	if float(_cooldowns.get(id, 0.0)) > _clock: return "cooldown"
	if actor.get("hoof_hold") == null or actor.get("profile") == null or actor.get("identity") == null: return "unsupported body"
	# Mares and fillies only (dev 2026-10-29: "no stallions at the spa"); colts carry the flag too.
	if bool((actor.get("identity") as Resource).get("stallion")): return "stallion"
	# Spike's hoof_hold is a stub (spike_parts.gd) with no grab_count or gesture_left: no lift.
	var hold: Object = actor.get("hoof_hold") as Object
	var feet: Variant = actor.get("feet")
	if hold == null or not ("grab_count" in hold) or not ("gesture_left" in hold) or not (feet is Array and (feet as Array).size() == 4): return "unsupported body"
	if not _hard_interrupt(actor).is_empty() or _soft_busy(actor): return "interaction, sleep or unsupported"
	if actor.has_method("action_interruption_reason") and not str(actor.action_interruption_reason()).is_empty(): return "interaction"
	if actor.get_meta("seating", false) or actor.get_meta("hayburger_customer", "") != "": return "busy elsewhere"
	if not actor.global_position.is_finite(): return "unsupported body"
	var nav := actor.get_node_or_null("Navigator")
	var owner := str(nav.get("command_owner"))
	if not (owner.is_empty() or owner == "life:" + id): return "owned by " + owner.get_slice(":", 0)
	if actor.has_meta("social_group"):
		var group: Variant = actor.get_meta("social_group")
		if group is Dictionary and (group as Dictionary).get("members", []).size() > 1: return "group outing"
	if owner.is_empty() and (not nav.wander_enabled or (nav.get("_has_target") == true and nav.get("_wandering") != true)): return "unowned player command"
	var life: Node = _game.get("life") as Node
	if is_instance_valid(life) and life.get("core") != null:
		var resident: Dictionary = life.core.state.residents.get(id, {})
		if resident.get("paused", false): return "living world paused"
		var activity: Dictionary = life.core.state.activities.get(resident.get("activity", ""), {})
		if activity.get("members", []).size() > 1: return "group activity"
	if not nav.has_method("command_destination") or not is_instance_valid(nav.get("_service")): return "navigation unavailable"
	# Last on purpose: book_group accepts this one reason, so every check above still runs for her.
	if actor.global_position.distance_to(marker("SPA_DOOR_OUT").origin) > VISIT_RADIUS: return "outside visit radius"
	return ""


## The walk grid that covers SPA_DOOR_IN (the smallest service whose bounds hold it, the way
## roster_placement.select_service picks), or null.
func _door_service() -> Node:
	if not is_inside_tree(): return null
	var door := marker("SPA_DOOR_IN").origin
	if not door.is_finite(): return null
	return ROSTER.select_service(get_tree().get_nodes_in_group("pony_navigation"), door)


func _claim(id: String, actor: Node3D, services: Array[String], slot: int, phase: String) -> bool:
	var nav := actor.get_node("Navigator")
	var identity: Resource = actor.get("identity")
	var display_name := str(identity.get("display_name")) if identity != null else id.capitalize()
	if display_name.is_empty(): display_name = id.capitalize()
	var size := float(actor.get("body_scale")) if actor.get("body_scale") != null else 1.0
	var visit := {"id": id, "display_name": display_name, "actor": actor, "nav": nav,
		"owner": "leisure:spa:%d:%s" % [get_instance_id(), id], "slot": slot,
		"previous_owner": nav.command_owner, "previous_wander": nav.wander_enabled,
		"previous_speed": nav.command_speed_limit, "previous_pace": nav.command_pace_target,
		"previous_face": nav.get("face_point") if nav.get("face_point") is Vector3 else Vector3.INF,
		"phase": phase, "since": _clock, "goal": Vector3.INF, "deadline": _clock + TRAVEL_TIMEOUT,
		"settle_until": -1.0, "until": _clock, "on_table": false, "hopping": false, "patience": _clock + PATIENCE,
		"progress_at": _clock, "progress_pos": actor.global_position,
		"services": services.duplicate(), "size": size, "filly": identity != null and identity.get("filly") == true,
		"pegasus": _pegasus(actor), "paid": 0, "line_index": -1,
		"file_side": 0, "file_strokes": [0, 0], "raised_leg": -1,
		"rub_side": 0, "rub_good": [0.0, 0.0], "rear_strokes": [0, 0], "stage": "file",
		"wing_good": 0.0, "wing_lines": [], "feathers": [], "feathers_total": 0, "plucked": 0, "sat": false, "wings": null,
		"relaxed": 0.0, "seat": null, "seat_state": "", "stand_since": 0.0, "lie_after": -1.0}
	if not is_instance_valid(nav) or not nav.has_method("command_destination"): return false
	_visits[id] = visit
	if not LEGACY.old_jobs():
		# The shared lease: stay, take the owner (refused -> no visit), wander off, speed INF, pace -1,
		# and the metas. The wave-2 romance firewall reads "spa_client" (plan section 3).
		if not _lease_queue().claim(id, actor, {"spa_client": true, "spa_visit": visit.owner},
				{"owner": visit.owner, "wander": false, "gate": "spa_visit", "clear": ["spa_company"]}):
			_visits.erase(id)
			_cooldowns[id] = _clock + FAILED_VISIT_COOLDOWN
			return false
		return true
	nav.stay()
	nav.command_owner = visit.owner
	if nav.command_owner != visit.owner:
		_visits.erase(id)
		_cooldowns[id] = _clock + FAILED_VISIT_COOLDOWN
		return false
	nav.wander_enabled = false
	nav.command_speed_limit = INF
	nav.command_pace_target = -1.0
	# The wave-2 romance firewall reads this flag (plan section 3: keeping spa touch out of romance).
	actor.set_meta("spa_client", true)
	actor.set_meta("spa_visit", visit.owner)
	return true


func _lease_queue() -> RefCounted:
	if _leases == null:
		_leases = QUEUE.new()
		_leases.owner_prefix = "leisure:spa:%d:" % get_instance_id()
		_leases.max_customers = MAX_CLIENTS
		_leases.cooldown_s = COOLDOWN_SECONDS
		_leases.radius = VISIT_RADIUS
		_leases.exclude = PackedStringArray(STAFF)
	_leases.cooldowns = _cooldowns
	_leases.clock = _clock
	_leases.population = _population()
	_leases.life = _game.get("life") as Node if is_instance_valid(_game) else null
	return _leases


## The running jobs core when it serves this game's world (none in fixtures without the hub).
func _jobs() -> Node:
	var jobs: Node = JOBS.of(get_tree()) if is_inside_tree() else null
	return jobs if jobs != null and is_instance_valid(_game) and jobs.get("context") == _game.get("world_context") else null


func _owned(visit: Dictionary) -> bool:
	return is_instance_valid(visit.actor) and is_instance_valid(visit.nav) and visit.nav.command_owner == visit.owner


func release_all() -> void:
	for id: String in _visits.keys(): _release(id, "Spa released")


func _release(id: String, reason: String) -> void:
	if not _visits.has(id): return
	var visit: Dictionary = _visits[id]
	_visits.erase(id)
	_rub_queue.erase(id)
	if _rub_owner == id: _rub_owner = ""
	if _wing_owner == id: _wing_owner = ""
	_cooldowns[id] = _clock + (COOLDOWN_SECONDS if int(visit.paid) > 0 else FAILED_VISIT_COOLDOWN)
	_last_reason = reason
	var actor: Node3D = visit.actor
	if is_instance_valid(actor):
		_end_body_work(visit)
		var expressions: Variant = actor.get("expressions")
		if expressions != null and expressions.has_method("release_touch"): expressions.release_touch("spa")
	if not LEGACY.old_jobs():
		# The shared lease restores the navigation fields, reissues her goal and removes the spa
		# metas while it still owns her; face and posture stay spa business.
		if _lease_queue().release(id, reason, -1.0):
			if visit.nav.get("face_point") is Vector3: visit.nav.face_point = visit.previous_face
			if visit.sat and actor.get("sleeping") != true and _hard_interrupt(actor).is_empty(): actor.request_posture("stand")
	elif _owned(visit):
		visit.nav.stay()
		visit.nav.command_owner = visit.previous_owner
		visit.nav.wander_enabled = visit.previous_wander
		visit.nav.command_speed_limit = visit.previous_speed
		visit.nav.command_pace_target = visit.previous_pace
		if visit.nav.get("face_point") is Vector3: visit.nav.face_point = visit.previous_face
		if visit.sat and actor.get("sleeping") != true and _hard_interrupt(actor).is_empty(): actor.request_posture("stand")
		_reissue_life_goal(id)
	if is_instance_valid(actor):
		if actor.get_meta("spa_visit", "") == visit.owner:
			actor.remove_meta("spa_visit")
			if actor.has_meta("spa_client"): actor.remove_meta("spa_client")
			if actor.has_meta("spa_company"): actor.remove_meta("spa_company")
	client_left.emit(id, reason)


## Meta "spa_company" on each waiting client: the ids of every waiting client, her own included.
func _update_company() -> void:
	var waiting: Array = []
	for visit: Dictionary in _visits.values():
		if visit.phase in CHAT_PHASES and _owned(visit): waiting.append(visit.id)
	for visit: Dictionary in _visits.values():
		if not is_instance_valid(visit.actor): continue
		if waiting.size() > 1 and waiting.has(visit.id): visit.actor.set_meta("spa_company", waiting.duplicate())
		elif visit.actor.has_meta("spa_company"): visit.actor.remove_meta("spa_company")


## Undo everything the spa did to her body: hoof holds it started, sitting, open wings, strays.
func _end_body_work(visit: Dictionary) -> void:
	var actor: Node3D = visit.actor
	var hold: Variant = actor.get("hoof_hold")
	if hold != null and int(hold.leg_index) >= 0 and int(hold.leg_index) == int(visit.raised_leg) and float(hold.gesture_left) > 0.0:
		hold.release()
	visit.raised_leg = -1
	_leave_seat_now(visit)
	if actor.has_meta("lie_style"): actor.remove_meta("lie_style")
	# Off the table at once (a hop is for the normal way down): standing at its foot.
	if visit.on_table and is_instance_valid(actor) and not (actor.has_method("is_held") and actor.is_held()):
		actor.set("motion_paused", false)
		if actor.get("sleeping") != true: actor.request_posture("stand")
		var spot := marker("SPA_RUB_SPOT")
		if spot.origin.is_finite() and actor.has_method("reset_motion"):
			actor.reset_motion(Transform3D(Basis.looking_at(-facing(spot), Vector3.UP), spot.origin))
	visit.on_table = false
	_tail_aside(visit, 0.0)
	_close_wings(visit)
	FEATHERS.clear(actor)
	visit.feathers = []


func _send_back(id: String, actor: Node3D, origin: Transform3D) -> void:
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav != null: nav.stay()
	if actor.has_method("reset_motion"): actor.reset_motion(origin)
	else: actor.global_transform = origin
	_reissue_life_goal(id)


func _reissue_life_goal(id: String) -> void:
	var life: Node = _game.get("life") as Node if is_instance_valid(_game) else null
	if is_instance_valid(life) and life.get("actors") is Dictionary and life.actors.has(id): life.actors[id].goal = Vector3.INF


# ------------------------------------------------------------------ placement and routes

## A floor point under `wanted` (copied from the Hayburger). `strict` also asks for a clear body
## cylinder; station spots beside decks, rims and the rub block use the floor ray only, and the
## navigator still certifies every step.
func _supported(actor: Node3D, wanted: Vector3, strict := true) -> Vector3:
	if not wanted.is_finite() or not is_instance_valid(actor) or not actor.is_inside_tree(): return Vector3.INF
	var profile: Resource = actor.get("profile")
	var space := actor.get_world_3d().direct_space_state
	var excludes: Array[RID] = []
	if actor is CollisionObject3D: excludes.append(actor.get_rid())
	var radius := float(profile.radius) if strict else 0.0
	var offsets: Array[Vector3] = [Vector3.ZERO]
	if strict: offsets.append_array([Vector3.RIGHT * radius, Vector3.LEFT * radius, Vector3.FORWARD * radius, Vector3.BACK * radius])
	var center := Vector3.INF
	for offset: Vector3 in offsets:
		var start := wanted + offset + Vector3.UP * 0.5
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(start, wanted + offset - Vector3.UP * 0.75, 1, excludes))
		if hit.is_empty() or Vector3(hit.normal).y < cos(deg_to_rad(profile.max_slope_degrees)): return Vector3.INF
		if not center.is_finite(): center = hit.position
		if absf(float(hit.position.y) - center.y) > float(profile.step_height): return Vector3.INF
	if strict:
		var shape := CylinderShape3D.new()
		shape.radius = radius
		shape.height = profile.clearance
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = shape
		query.transform.origin = center + Vector3.UP * (shape.height * .5 + .06)
		query.collision_mask = 1 | 2 | 2048
		query.exclude = excludes
		if not space.intersect_shape(query, 1).is_empty(): return Vector3.INF
	return center + Vector3.UP * .03


func _route(visit: Dictionary, phase: String, target: Vector3, pace := "walk") -> void:
	if not _owned(visit): _release(visit.id, "Navigation ownership changed"); return
	visit.phase = phase
	visit.since = _clock
	visit.settle_until = -1.0
	visit.progress_at = _clock
	visit.progress_pos = visit.actor.global_position
	visit.deadline = _clock + TRAVEL_TIMEOUT
	if visit.nav.get("face_point") is Vector3: visit.nav.face_point = Vector3.INF
	var goal := _supported(visit.actor, target, false)
	if not goal.is_finite(): goal = target
	visit.goal = goal
	if _at_position(visit, goal, 0.3): return
	if not visit.nav.command_destination(goal, pace):
		if phase in ["to_door_in", "to_door_out"]: _place_outside(visit, "Navigator refused the way out")
		else: _leave(visit, "Navigator refused destination")


## SPA_DOOR_OUT, or the nearest free spot beside it along the street (a client released a moment
## ago may still stand on it; the Hayburger's DeparturePoint does the same).
func _street_spot(visit: Dictionary) -> Vector3:
	var door := marker("SPA_DOOR_OUT")
	var side := facing(door).cross(Vector3.UP).normalized()
	var spacing := 1.2
	var others: Array[Vector3] = []
	var population := _population()
	if is_instance_valid(population):
		for entry: Variant in (population.get("live") as Dictionary).values():
			var other: Node3D = (entry as Dictionary).get("actor") as Node3D
			if is_instance_valid(other) and other != visit.actor: others.append(other.global_position)
	for offset: float in [0.0, spacing, -spacing, spacing * 2.0, -spacing * 2.0]:
		var spot := _supported(visit.actor, door.origin + side * offset, false)
		if not spot.is_finite(): continue
		var free := true
		for other: Vector3 in others:
			if Vector2(other.x - spot.x, other.z - spot.z).length() < 0.9: free = false; break
		if free: return spot
	return door.origin


func _at_position(visit: Dictionary, position: Vector3, reach := 0.55) -> bool:
	var actor: Node3D = visit.actor
	var difference: Vector3 = actor.global_position - position
	return Vector2(difference.x, difference.z).length() <= reach and absf(difference.y) <= .5 and actor.has_method("grounded") and actor.grounded()


## Arrived and, for a station, settled within 0.27 m with the navigator's short contact approach.
func _arrived(visit: Dictionary, precise: bool) -> bool:
	if not _at_position(visit, visit.goal): return false
	if not precise or _at_position(visit, visit.goal, 0.27): return true
	if visit.settle_until < 0.0:
		visit.settle_until = _clock + 3.0
		if visit.nav.has_method("command_contact_approach"): visit.nav.command_contact_approach(visit.goal)
		return false
	return _clock >= float(visit.settle_until) and visit.nav.state != visit.nav.State.MOVING


## Stopped short of a station (a grown mare where only a filly fits, a neighbour in the way) and
## not moving for STALL_SECONDS: she takes it from there instead of waiting out TRAVEL_TIMEOUT and
## leaving, which ended in the out-of-view placement players saw as ponies vanishing near the door
## (player board #42).
func _stalled_near(visit: Dictionary, reach := STALL_REACH) -> bool:
	return _at_position(visit, visit.goal, reach) and _clock - float(visit.progress_at) > STALL_SECONDS


func _face(visit: Dictionary, direction: Vector3) -> void:
	visit.nav.stay()
	if visit.nav.get("face_point") is Vector3: visit.nav.face_point = visit.actor.global_position + direction * 3.0
	elif visit.actor.has_method("face_direction"): visit.actor.face_direction(direction)


func _player_point() -> Vector3:
	if is_instance_valid(player_override): return player_override.global_position
	var inventory: Node = _game.get("inventory") as Node if is_instance_valid(_game) else null
	var camera: Node3D = inventory.get("camera") as Node3D if is_instance_valid(inventory) else null
	return camera.global_position if is_instance_valid(camera) else Vector3.INF


func _camera() -> Camera3D:
	var inventory: Node = _game.get("inventory") as Node if is_instance_valid(_game) else null
	var camera: Camera3D = inventory.get("camera") as Camera3D if is_instance_valid(inventory) else null
	if is_instance_valid(camera): return camera
	return get_viewport().get_camera_3d() if is_inside_tree() else null


## The stuck rule: release her and place her on the street beside SPA_DOOR_OUT, somewhere the
## player's camera does not see, so nobody stays trapped inside.
func _place_outside(visit: Dictionary, reason: String) -> void:
	var id: String = visit.id
	var actor: Node3D = visit.actor
	var door := marker("SPA_DOOR_OUT")
	var out := facing(door)
	var side := out.cross(Vector3.UP).normalized()
	var camera := _camera()
	var chosen := Vector3.INF
	var fallback := Vector3.INF
	for ahead: float in [4.0, 6.0, 8.0, 3.0]:
		for across: float in [-3.5, 3.5, -6.0, 6.0, 0.0]:
			var point := _supported(actor, door.origin + out * ahead + side * across, true)
			if not point.is_finite(): continue
			if not fallback.is_finite(): fallback = point
			var seen: bool = camera != null and camera.is_position_in_frustum(point + Vector3.UP * 0.6) and camera.global_position.distance_to(point) < 80.0
			if not seen: chosen = point; break
		if chosen.is_finite(): break
	if not chosen.is_finite(): chosen = fallback
	_release(id, reason)
	if chosen.is_finite() and is_instance_valid(actor) and actor.is_inside_tree():
		var nav: Node = actor.get_node_or_null("Navigator")
		if nav != null: nav.stay()
		if actor.has_method("reset_motion"): actor.reset_motion(Transform3D(Basis.looking_at(out, Vector3.UP), chosen))
		_reissue_life_goal(id)


# ------------------------------------------------------------------ the tick

func _physics_process(delta: float) -> void:
	_clock += delta
	_check += delta
	if _check < CHECK_SECONDS: return
	_check = 0.0
	if not is_instance_valid(_game):
		release_all()
		return
	for id: String in _visits.keys(): _advance(id)
	_update_rub_line()
	_update_company()
	for id in _cooldowns.keys():
		if float(_cooldowns[id]) <= _clock: _cooldowns.erase(id)


func _advance(id: String) -> void:
	if not _visits.has(id): return
	var visit: Dictionary = _visits[id]
	var population := _population()
	# A client's own [approach], [sit] or [stay] reply tag while Anon chats with her took her
	# navigator and ended the visit (board #307, thread 2026-11-01): the lease takes it back
	# (customer_queue.gd reclaim_from_model) and a walk to a station carries on.
	if is_instance_valid(visit.actor) and QUEUE.reclaim_from_model(visit.nav, visit.owner):
		print("[spa] client %s keeps her visit: a reply tag had taken her navigation" % id)
		if (_travelling(visit) or visit.phase in ["to_door_in", "to_door_out"]) and visit.goal is Vector3 and (visit.goal as Vector3).is_finite() and not _at_position(visit, visit.goal, 0.3):
			if not visit.nav.command_destination(visit.goal, "walk"): _leave(visit, "Navigator refused destination"); return
	if not _owned(visit) or not is_instance_valid(population) or population.live.get(id, {}).get("actor") != visit.actor:
		_release(id, "Resident or navigation ownership changed"); return
	var hard := _hard_interrupt(visit.actor)
	if not hard.is_empty(): _release(id, "Interrupted: " + hard); return
	if _soft_busy(visit.actor, false):
		# Being petted pauses her; every clock waits with her.
		for key: String in ["deadline", "patience", "progress_at", "until"]: visit[key] = float(visit[key]) + CHECK_SECONDS
		return
	var leaving: bool = visit.phase in ["to_door_in", "to_door_out"]
	var nav: Node = visit.nav
	if visit.actor.global_position.distance_to(visit.progress_pos) > 0.3:
		visit.progress_pos = visit.actor.global_position
		visit.progress_at = _clock
	if leaving:
		if _clock - float(visit.progress_at) > STUCK_SECONDS or _clock - float(visit.since) > LEAVE_TIMEOUT or nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]:
			_place_outside(visit, "Stuck on the way out"); return
	elif _travelling(visit):
		if _clock >= float(visit.deadline) or nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]:
			_leave(visit, "No way to the station: " + str(nav.get("reason"))); return
	elif _clock >= float(visit.patience):
		_leave(visit, "Waited too long"); return
	match visit.phase:
		"arriving":
			if _arrived(visit, false): _route(visit, "entering", marker("SPA_DOOR_IN").origin)
		"entering":
			if _arrived(visit, false):
				client_arrived.emit(id, visit.display_name)
				_next_station(visit)
		"lobby":
			if _clock >= float(visit.until): _next_station(visit)
		"to_bath":
			if _arrived(visit, true) or _stalled_near(visit):
				visit.phase = "bath"; visit.since = _clock
				_face(visit, facing(marker("SPA_BATH_%d" % (int(visit.slot) + 1))))
				_relax(visit, 0.2)
		"bath":
			_tick_filing(visit)
		"to_line":
			if _arrived(visit, true) or _stalled_near(visit):
				visit.phase = "line"
				if visit.seat != null: _sit_on_seat(visit)
				else: _face(visit, facing(marker("SPA_RUB_LINE_%d" % (int(visit.line_index) + 1))))
		"line":
			_keep_sitting(visit)
		"to_rub":
			# A grown mare cannot squeeze onto the floor spot at the table's foot and stalled a metre
			# short until she gave up (player board #42: fillies got on the table, grown ponies did
			# not). Stopped close enough, she hops up from where she stands; the arc lands her on
			# the pad all the same.
			if _arrived(visit, true) or _stalled_near(visit, CLIMB_REACH):
				visit.nav.stay()
				_face(visit, facing(marker("SPA_RUB_SPOT")))
				visit.phase = "rub_climb"; visit.since = _clock
		"rub_climb":
			if not visit.hopping and _clock - float(visit.since) >= CLIMB_PAUSE: _climb_on(visit)
		"rub_lying":
			_tick_lying(visit)
		"rub":
			_tick_rub(visit)
		"rub_off":
			_tick_getting_off(visit)
		"wing_wait":
			if _wing_owner.is_empty() or _wing_owner == id:
				if _off_seat(visit):
					_wing_owner = id
					_route(visit, "to_wing", marker("SPA_WING_CUSHION").origin)
			else:
				_wait_on_bench(visit, "lobby")
		"to_wing":
			if _arrived(visit, true) or _stalled_near(visit):
				visit.phase = "wing_sit"; visit.since = _clock
				_face(visit, facing(marker("SPA_WING_CUSHION")))
		"wing_sit":
			_tick_wing_sit(visit)
		"wing":
			_tick_wings(visit)
		"to_door_in":
			if _arrived(visit, false) or _at_position(visit, visit.goal, 1.0): _route(visit, "to_door_out", _street_spot(visit))
		"to_door_out":
			# The street spot only lines her up; a pony released before may stand near it.
			if _arrived(visit, false) or _at_position(visit, visit.goal, 1.0): _release(id, "Back to the daily routine")


func _travelling(visit: Dictionary) -> bool:
	return visit.phase in ["arriving", "entering", "to_bath", "to_line", "to_rub", "to_wing"]


## Next service on her list, or the way out.
func _next_station(visit: Dictionary) -> void:
	visit.patience = _clock + PATIENCE
	while not visit.services.is_empty():
		var service: String = visit.services[0]
		if service == "wings" and not visit.pegasus:
			visit.services.pop_front()
			continue
		match service:
			"file":
				_route(visit, "to_bath", marker("SPA_BATH_%d" % (int(visit.slot) + 1)).origin)
			"rub":
				if not _rub_queue.has(visit.id): _rub_queue.append(visit.id)
				visit.phase = "queued"; visit.line_index = -1
				_update_rub_line()
			"wings":
				visit.phase = "wing_wait"
				# Nook busy: step off the rub spot to her own lobby spot (each slot has one), so the
				# rub line is not held up behind her while she waits.
				# With the lobby bench she waits sitting on it instead (the tick seats her).
				if not _wing_owner.is_empty() and _wing_owner != visit.id and _free_seat("lobby", visit) == null:
					_route(visit, "wing_wait", marker("SPA_LOBBY_WAIT_%d" % (int(visit.slot) + 1)).origin)
		return
	_leave(visit, "All done")


func _leave(visit: Dictionary, reason: String) -> void:
	_last_reason = reason
	if not _visits.has(visit.id): return
	# Still on her way in (request_service): she never entered, so no walk to SPA_DOOR_IN.
	if visit.phase == "arriving":
		_release(visit.id, reason)
		return
	_rub_queue.erase(visit.id)
	if _wing_owner == visit.id: _wing_owner = ""
	_end_body_work(visit)
	if visit.sat and _owned(visit): visit.actor.request_posture("stand"); visit.sat = false
	visit.services.clear()
	_route(visit, "to_door_in", marker("SPA_DOOR_IN").origin)


func _done(visit: Dictionary, service: String) -> void:
	var bits: int = int(PAY.get(service, 0))
	if _pay(visit, bits, service):
		service_finished.emit(visit.id, service, bits)
		# Facts stream (world/mechanics/facts.gd): counters only, no new memory. With the jobs core,
		# pay_unit already added "worked" (ref "spa") with the payment.
		if LEGACY.old_jobs() or _jobs() == null:
			FACTS.note(self, "worked", {"actor": "player", "target": str(visit.id), "ref": "spa:" + service, "amount": bits})
	visit.services.erase(service)
	_next_station(visit)


## Bits only for a real client still here and still ours. True when the wallet took them.
func _pay(visit: Dictionary, amount: int, what: String) -> bool:
	if amount <= 0 or not _owned(visit) or not _hard_interrupt(visit.actor).is_empty(): return false
	var population := _population()
	if not is_instance_valid(population) or population.live.get(visit.id, {}).get("actor") != visit.actor: return false
	var inventory: Node = _game.get("inventory") as Node if is_instance_valid(_game) else null
	var store: Variant = inventory.get("inventory") if is_instance_valid(inventory) else null
	if store == null or not store.has_method("credit_bits"): return false
	var jobs := _jobs()
	if LEGACY.old_jobs() or jobs == null:
		# One pay path (world/mechanics/ledger.gd); the town pays (`-- --old-jobs`, fixtures).
		if not LEDGER.transfer(_game, "town", "player", amount, "service").is_empty(): return false
	elif not jobs.pay_unit("spa", "player", "", str(visit.id), amount, {"kind": what, "reason": "service", "extra": what == "feather"}).is_empty():
		# The jobs core's unit pay: the client pays from her purse, then Aloe, then the town.
		return false
	visit.paid = int(visit.paid) + amount
	earned_bits += amount
	bits_paid.emit(visit.id, amount, visit.actor.global_position + Vector3.UP * 0.9 * float(visit.size), what)
	return true


## A relaxed face: eyes closing by `amount`, a small smile, never a blush.
func _relax(visit: Dictionary, amount: float) -> void:
	visit.relaxed = clampf(amount, 0.0, 1.0)
	var expressions: Variant = visit.actor.get("expressions")
	if expressions != null and expressions.has_method("touch"):
		expressions.touch("spa", 0.55, lerpf(0.2, 0.85, float(visit.relaxed)))


# ------------------------------------------------------------------ rub line (single file)

func _update_rub_line() -> void:
	# The block is free once its client has fully stepped away from it.
	if not _rub_owner.is_empty():
		var owner: Dictionary = _visits.get(_rub_owner, {})
		var busy: bool = not owner.is_empty() and (owner.phase in ["to_rub", "rub_climb", "rub_lying", "rub", "rub_off"] \
			or owner.actor.global_position.distance_to(_rub_stand(owner)) < BLOCK_CLEAR)
		if not busy: _rub_owner = ""
	if _rub_owner.is_empty() and not _rub_queue.is_empty():
		var front: Dictionary = _visits.get(_rub_queue[0], {})
		if not front.is_empty() and front.phase in ["queued", "line", "to_line"] and _off_seat(front):
			_rub_queue.pop_front()
			_rub_owner = front.id
			front.line_index = -1
			_route(front, "to_rub", _rub_stand(front))
	for index in _rub_queue.size():
		var visit: Dictionary = _visits.get(_rub_queue[index], {})
		if visit.is_empty() or visit.seat != null: continue
		# The line waits sitting on the hoof room bench while it has a free seat; she keeps her
		# seat until the table is hers.
		var seat := _free_seat("hoof", visit)
		if seat != null:
			_take_seat(visit, seat)
			visit.line_index = -1
			_route(visit, "to_line", _seat_front(visit))
			continue
		if int(visit.line_index) == mini(index, 2): continue
		visit.line_index = mini(index, 2)
		_route(visit, "to_line", marker("SPA_RUB_LINE_%d" % (int(visit.line_index) + 1)).origin)


# ------------------------------------------------------------------ waiting benches

## A free seat on the venue's bench "hoof" or "lobby" (spa_venue.gd), or null; a fixture without
## benches keeps the standing line spots.
func _free_seat(bench: String, visit: Dictionary) -> Node3D:
	if not is_instance_valid(_venue) or not _venue.has_method("bench_seats"): return null
	for seat: Node3D in _venue.bench_seats(bench):
		if is_instance_valid(seat) and seat.free_for(visit.actor): return seat
	return null


func _take_seat(visit: Dictionary, seat: Node3D) -> void:
	visit.seat = seat
	visit.seat_state = ""
	seat.set_meta("occupant", visit.actor)


## The floor in front of her seat, where she hops up from and lands.
func _seat_front(visit: Dictionary) -> Vector3:
	var seat: Node3D = visit.seat
	var at: Vector3 = seat.global_position - seat.global_basis.orthonormalized().z * (float(seat.get("depth")) * .5 + .55)
	var ground := _supported(visit.actor, at, false)
	return ground if ground.is_finite() else at


## Not on a seat yet: walk to one on `bench` when free, and hop up once there.
func _wait_on_bench(visit: Dictionary, bench: String) -> void:
	if visit.seat == null:
		var seat := _free_seat(bench, visit)
		if seat == null: return
		_take_seat(visit, seat)
		_route(visit, visit.phase, _seat_front(visit))
	elif str(visit.seat_state) == "" and _arrived(visit, true):
		_sit_on_seat(visit)
	else:
		_keep_sitting(visit)


## At her seat's front: hop up and sit, with no drifting into a lie-down while she waits
## (seating.gd does the same on town benches).
func _sit_on_seat(visit: Dictionary) -> void:
	var seat: Node3D = visit.seat
	if not is_instance_valid(seat): _clear_seat(visit); return
	visit.seat_state = "hopping"
	visit.nav.stay()
	_hop(visit, Transform3D(seat.global_basis.orthonormalized(), seat.global_position + Vector3.UP * 0.02), func():
		visit.actor.set_meta("seated", true)
		var posture: Variant = visit.actor.get("posture")
		if posture != null and float(visit.lie_after) < 0.0:
			visit.lie_after = float(posture.lie_after_seconds)
			posture.lie_after_seconds = 1e9
		visit.actor.request_posture("sit")
		visit.seat_state = "sitting")


## A chat or a pet that stood her up on the seat: sit again.
func _keep_sitting(visit: Dictionary) -> void:
	if str(visit.seat_state) != "sitting": return
	var status: Dictionary = visit.actor.posture_status()
	if str(status.get("kind", "")) != "sit" and str(status.get("requested", "")) != "sit": visit.actor.request_posture("sit")


## True once she is on the floor, free to walk; otherwise starts or continues getting off her seat
## (stand on it, then hop down to its front).
func _off_seat(visit: Dictionary) -> bool:
	if visit.seat == null: return true
	match str(visit.seat_state):
		"":
			_clear_seat(visit)
			return true
		"sitting":
			visit.actor.request_posture("stand")
			visit.stand_since = _clock
			visit.seat_state = "standing"
		"standing":
			var status: Dictionary = visit.actor.posture_status()
			var standing: bool = str(status.get("kind", "stand")) in ["stand", ""] and bool(status.get("settled", true))
			if not standing and _clock - float(visit.stand_since) < SETTLE_TIMEOUT: return false
			visit.seat_state = "leaving"
			_hop(visit, Transform3D(Basis(visit.actor.global_basis.get_rotation_quaternion()), _seat_front(visit) + Vector3.UP * 0.02),
				func(): _clear_seat(visit))
	return false


## Off her seat at once (the visit ends): standing at its front.
func _leave_seat_now(visit: Dictionary) -> void:
	if visit.seat == null: return
	var actor: Node3D = visit.actor
	if str(visit.seat_state) != "" and is_instance_valid(actor) and is_instance_valid(visit.seat) \
			and not (actor.has_method("is_held") and actor.is_held()):
		actor.set("motion_paused", false)
		if actor.get("sleeping") != true: actor.request_posture("stand")
		if actor.has_method("reset_motion"):
			actor.reset_motion(Transform3D(Basis(actor.global_basis.get_rotation_quaternion()), _seat_front(visit) + Vector3.UP * 0.02))
	_clear_seat(visit)


func _clear_seat(visit: Dictionary) -> void:
	var seat: Variant = visit.seat
	var actor: Variant = visit.actor
	if is_instance_valid(seat) and (seat as Node3D).has_meta("occupant") and (seat as Node3D).get_meta("occupant") == actor:
		(seat as Node3D).remove_meta("occupant")
	visit.seat = null
	visit.seat_state = ""
	if is_instance_valid(actor):
		if (actor as Node3D).has_meta("seated"): (actor as Node3D).remove_meta("seated")
		var posture: Variant = (actor as Node3D).get("posture")
		if posture != null and float(visit.lie_after) >= 0.0: posture.lie_after_seconds = float(visit.lie_after)
	visit.lie_after = -1.0


## The table's foot: where she walks to, hops up from and lands back on.
func _rub_stand(_visit: Dictionary) -> Vector3:
	return marker("SPA_RUB_SPOT").origin


# ------------------------------------------------------------------ filing (front hooves)

func _leg(actor: Node3D, leg_name: String) -> int:
	var profile: Resource = actor.get("profile")
	for i in profile.legs.size():
		if String(profile.legs[i].name) == leg_name: return i
	return -1


## Her raise() lift, which holds as long as asked. pony_hoof_hold.gd never counts her own lifts
## (or any spa client's) as "the player held your hoof".
func _raise(visit: Dictionary, side: int) -> bool:
	var hold: Variant = visit.actor.get("hoof_hold")
	if hold == null or int(hold.leg_index) >= 0: return false
	var ok: bool = hold.raise(side, RAISE_SECONDS)
	if ok: visit.raised_leg = _leg(visit.actor, "FL" if side == 0 else "FR")
	return ok


func hoof_raised(pony_id: String) -> bool:
	var visit: Dictionary = _visits.get(pony_id, {})
	if visit.is_empty() or visit.phase != "bath" or not is_instance_valid(visit.actor): return false
	var hold: Variant = visit.actor.get("hoof_hold")
	return hold != null and int(hold.leg_index) == int(visit.raised_leg) and int(visit.raised_leg) >= 0 and hold.active()


func _tick_filing(visit: Dictionary) -> void:
	if hoof_raised(visit.id): return
	var player := _player_point()
	var gap: Vector3 = player - (visit.actor as Node3D).global_position
	if player.is_finite() and Vector2(gap.x, gap.z).length() <= PLAYER_NEAR:
		if _raise(visit, int(visit.file_side)):
			visit.erase("raise_blocked")
			return
		# Player board #42: "Sometimes ponies won't raise their other hoof". A filed hoof going
		# down finishes its release only on the solver tier; one left half-released holds the
		# leg slot and every later raise() is refused. After a second of refusals the hold is
		# cleared, so the next tick lifts the other hoof.
		if not visit.has("raise_blocked"): visit.raise_blocked = _clock
		var hold: Variant = visit.actor.get("hoof_hold")
		if _clock - float(visit.raise_blocked) > 1.0 and hold != null and int(hold.leg_index) >= 0 and not hold.active():
			var feet: Variant = visit.actor.get("feet")
			if feet is Array and int(hold.leg_index) < (feet as Array).size():
				feet[int(hold.leg_index)].planted = false; feet[int(hold.leg_index)].offset = Vector3.ZERO
			hold.reset()
			visit.raise_blocked = _clock


## Hooves ready for the file near `point`: a raised front hoof at the footbath, or the back hoof
## being worked on at the table. [{id, tip (hoof, world), across (her side axis), strokes, needed}].
func filing_targets(point: Vector3, reach := 0.6) -> Array:
	var out := []
	for id: String in _visits:
		var visit: Dictionary = _visits[id]
		if not is_instance_valid(visit.actor) or str(visit.stage) != "file": continue
		var leg := -1
		var strokes := 0
		if hoof_raised(id):
			leg = int(visit.raised_leg); strokes = int(visit.file_strokes[int(visit.file_side)])
		elif visit.phase == "rub":
			leg = _leg(visit.actor, "RL" if int(visit.rub_side) == 0 else "RR"); strokes = int(visit.rear_strokes[int(visit.rub_side)])
		if leg < 0: continue
		var tip := hoof_tip(visit.actor, leg)
		if not tip.is_finite() or (point.is_finite() and tip.distance_to(point) > reach): continue
		out.append({"id": id, "tip": tip, "across": visit.actor.global_basis.x.normalized(),
			"strokes": strokes, "needed": FILE_STROKES})
	return out


static func hoof_tip(actor: Node3D, leg_index: int) -> Vector3:
	if not is_instance_valid(actor): return Vector3.INF
	var hold: Variant = actor.get("hoof_hold")
	if hold == null or leg_index < 0: return Vector3.INF
	var fk: Array[Transform3D] = hold.globals()
	return fk[int(actor.profile.legs[leg_index].end)].origin


## One valid file stroke on the hoof filing_targets() offers. A filed front hoof goes down and she
## lifts the other (both done: the footbath is paid); a filed back hoof is massaged next
## (rub_targets) and stays where it is.
func file_stroke(pony_id: String) -> bool:
	var visit: Dictionary = _visits.get(pony_id, {})
	if visit.is_empty() or str(visit.stage) != "file": return false
	var done := false
	if hoof_raised(pony_id):
		var side := int(visit.file_side)
		visit.file_strokes[side] = int(visit.file_strokes[side]) + 1
		_relax(visit, 0.2 + 0.4 * (int(visit.file_strokes[0]) + int(visit.file_strokes[1])) / float(FILE_STROKES * 2))
		visit.patience = _clock + PATIENCE
		if int(visit.file_strokes[side]) < FILE_STROKES: return true
		var hold: Variant = visit.actor.get("hoof_hold")
		hold.release()
		visit.raised_leg = -1
		if side == 0: visit.file_side = 1
		else: _done(visit, "file")
		return true
	elif visit.phase == "rub":
		var side := int(visit.rub_side)
		visit.rear_strokes[side] = int(visit.rear_strokes[side]) + 1
		done = int(visit.rear_strokes[side]) >= FILE_STROKES
	else:
		return false
	visit.patience = _clock + PATIENCE
	if done: visit.stage = "rub"
	return true


# ------------------------------------------------------------------ back-hoof rub (massage table)

## One hop in an arc (cradle_rest.gd _hop_down): her body is paused, carried along, then put down
## at `to`. `done` runs only if she is still this visit's client.
func _hop(visit: Dictionary, to: Transform3D, done: Callable) -> void:
	var actor: Node3D = visit.actor
	var from := actor.global_position
	var arc := HOP_ARC * float(visit.size)
	visit.hopping = true
	actor.set("motion_paused", true)
	actor.global_basis = to.basis
	var tween := create_tween().bind_node(actor)
	tween.tween_method(func(t: float):
		if is_instance_valid(actor): actor.global_position = from.lerp(to.origin, t) + Vector3.UP * sin(PI * t) * arc, 0.0, 1.0, HOP_SECONDS)
	tween.tween_callback(func():
		visit.hopping = false
		if not is_instance_valid(actor): return
		actor.set("motion_paused", false)
		if not is_same(_visits.get(visit.id), visit): return
		actor.reset_motion(to)
		done.call())


func _climb_on(visit: Dictionary) -> void:
	var table := marker("SPA_RUB_TABLE")
	visit.on_table = true
	# Stretched out like a lifesize plush, back hooves at the table's foot (pony_posture.gd).
	visit.actor.set_meta("lie_style", "stretch")
	# SPA_RUB_TABLE is an adult's root; a smaller pony lies further toward the foot so her back
	# hooves still end at the player's end (an adult's reach 0.72 m behind her root).
	var root: Vector3 = table.origin - facing(table) * HIND_REACH * (1.0 - float(visit.size)) + Vector3.UP * 0.02
	_hop(visit, Transform3D(Basis.looking_at(facing(table), Vector3.UP), root), func():
		visit.nav.stay()
		visit.actor.request_posture("lie_down")
		visit.phase = "rub_lying"; visit.since = _clock)


func _lying(actor: Node3D) -> bool:
	var status: Dictionary = actor.posture_status()
	return bool(status.get("settled", false)) and str(status.get("kind", "")) == "lie_down"


func _tick_lying(visit: Dictionary) -> void:
	if _lying(visit.actor):
		visit.phase = "rub"; visit.since = _clock
		visit.stage = "file"
		_relax(visit, 0.3)
		return
	# The first request right after the hop can be refused (no floor contact yet on the pad, still
	# settling): ask again until she is down. Asked only once, grown mares gave up on the table
	# and left (player board #42: "Fillies are able to get on the table. But grown ponies aren't").
	var status: Dictionary = visit.actor.posture_status()
	if str(status.get("requested", "")) != "lie_down": visit.actor.request_posture("lie_down")
	if _clock - float(visit.since) > SETTLE_TIMEOUT:
		_leave(visit, "Could not lie down on the table (%s)" % str(visit.actor.posture_status().get("refusal", "")))


## Lying still; a chat or a pet that sat her up is followed by lying down again.
func _tick_rub(visit: Dictionary) -> void:
	_tail_aside(visit, TAIL_ASIDE if int(visit.rub_side) == 0 else -TAIL_ASIDE)
	if not _lying(visit.actor) and str(visit.actor.posture_status().get("kind", "")) != "lie_down":
		visit.actor.request_posture("lie_down")


func _tick_getting_off(visit: Dictionary) -> void:
	if visit.hopping: return
	var status: Dictionary = visit.actor.posture_status()
	var standing: bool = str(status.get("kind", "stand")) in ["stand", ""] or not visit.actor.get("posture").active()
	if not standing and _clock - float(visit.since) < SETTLE_TIMEOUT: return
	_tail_aside(visit, 0.0)
	var spot := marker("SPA_RUB_SPOT")
	_hop(visit, Transform3D(Basis.looking_at(-facing(spot), Vector3.UP), spot.origin + Vector3.UP * 0.02), func():
		visit.on_table = false
		reaction.emit(visit.id, "stretch")
		_done(visit, "rub"))


## Hooves ready for the massage: the back hoof being worked on (stretched out toward the table's
## foot) or a raised front hoof at the footbath, once filed.
## [{id, upper (hip or shoulder), top (hock or knee), bottom (hoof), radius, progress, side}]: the
## hand may rub anywhere from the hoof up the leg (dev 2026-10-29: up her thigh).
func rub_targets(point: Vector3, reach := 0.5) -> Array:
	var out := []
	for id: String in _visits:
		var visit: Dictionary = _visits[id]
		if not is_instance_valid(visit.actor) or str(visit.stage) != "rub": continue
		var index := -1
		var progress := 0.0
		var side := 0
		if visit.phase == "rub":
			side = int(visit.rub_side)
			index = _leg(visit.actor, "RL" if side == 0 else "RR")
			progress = float(visit.rub_good[side]) / RUB_SECONDS
		if index < 0: continue
		var leg: Dictionary = visit.actor.profile.legs[index]
		var fk: Array[Transform3D] = visit.actor.get("hoof_hold").globals()
		var upper: Vector3 = fk[int(leg.root)].origin
		var top: Vector3 = fk[int(leg.middle)].origin
		var bottom: Vector3 = fk[int(leg.end)].origin
		if point.is_finite() and minf(Geometry3D.get_closest_point_to_segment(point, top, bottom).distance_to(point),
				Geometry3D.get_closest_point_to_segment(point, upper, top).distance_to(point)) > reach: continue
		out.append({"id": id, "upper": upper, "top": top, "bottom": bottom, "radius": 0.045 * float(visit.size),
			"upper_radius": 0.075 * float(visit.size), "progress": progress, "side": side})
	return out


## Good slow rubbing credited by the detector (seconds) under `pressure` 0..1. `push` is kept for
## the input adapters; a hoof does not yield yet.
func rub(pony_id: String, seconds: float, _pressure: float, _push := Vector3.ZERO) -> bool:
	var visit: Dictionary = _visits.get(pony_id, {})
	if visit.is_empty() or not is_instance_valid(visit.actor) or str(visit.stage) != "rub": return false
	if visit.phase != "rub": return false
	if seconds <= 0.0: return true
	var side := int(visit.rub_side)
	visit.rub_good[side] = float(visit.rub_good[side]) + seconds
	visit.patience = _clock + PATIENCE
	# Her response builds slowly: eyes closing over both hooves.
	_relax(visit, 0.3 + 0.6 * (float(visit.rub_good[0]) + float(visit.rub_good[1])) / (RUB_SECONDS * 2.0))
	if float(visit.rub_good[side]) < RUB_SECONDS: return true
	if side == 0:
		visit.rub_side = 1
		visit.stage = "file"
		return true
	visit.phase = "rub_off"; visit.since = _clock
	visit.actor.remove_meta("lie_style")
	visit.actor.request_posture("stand")
	return true


## Her tail swung `angle` aside (hybrid_tail_motion.gd), 0 back to normal.
func _tail_aside(visit: Dictionary, angle: float) -> void:
	var tail: Variant = visit.actor.get("tail_motion") if is_instance_valid(visit.actor) else null
	if tail != null and "aside_goal" in tail: tail.aside_goal = angle


## Rubbing too fast just pauses progress, and she flicks an ear.
func rub_too_fast(pony_id: String) -> void:
	if _visits.has(pony_id): reaction.emit(pony_id, "ear_flick")  # TODO(wave 2): a real ear flick on her rig.


# ------------------------------------------------------------------ wings (pegasi)

func _tick_wing_sit(visit: Dictionary) -> void:
	var actor: Node3D = visit.actor
	if not visit.sat:
		visit.sat = bool(actor.request_posture("sit"))
		if not visit.sat and _clock - float(visit.since) > 5.0: _leave(visit, "Could not sit on the cushion")
		return
	var status: Dictionary = actor.posture_status()
	if not (bool(status.get("settled", false)) and str(status.get("kind", "")) == "sit"):
		if _clock - float(visit.since) > 8.0: _leave(visit, "Could not settle on the cushion")
		return
	if not _open_wings(visit):
		_leave(visit, "Wings unavailable"); return
	# Strays go on once the wings have settled half open (their feathers are where they rest).
	if float(visit.wings.tuck) > 0.01 or absf(float(visit.wings.half) - float(visit.wings.hold_goal)) > 0.01:
		if _clock - float(visit.since) > 10.0: _leave(visit, "Wings did not open")
		return
	var count := _rng.randi_range(FEATHERS_MIN, FEATHERS_MAX)
	var skeleton: Skeleton3D = actor.get("skeleton") as Skeleton3D
	visit.wing_lines = FEATHERS.wing_lines(skeleton, visit.wings.meshes)
	visit.feathers = FEATHERS.spawn(actor, count, _rng, visit.wings.meshes)
	visit.feathers_total = (visit.feathers as Array).size()
	visit.phase = "wing"; visit.since = _clock
	visit.patience = _clock + PATIENCE
	_relax(visit, 0.3)


## Her flight's open-wing meshes, made the way excitement.gd makes them (one set per pony), held
## half open by the spa (hybrid_open_wings.hold_at): excitement and flight cannot open or fold
## them until _close_wings() releases the hold.
func _open_wings(visit: Dictionary) -> bool:
	var actor: Node3D = visit.actor
	if actor.has_method("_ensure_flight"): actor.call("_ensure_flight")
	var flight: Variant = actor.get("flight")
	if flight == null: return false
	if flight.wings == null:
		var made: Node = WINGS.new()
		actor.add_child(made)
		if not made.bind(actor): made.queue_free(); return false
		flight.wings = made
	visit.wings = flight.wings
	return bool(flight.wings.hold_at(_wing_hold_owner(visit), _wing_hold_value(visit)))


## Releases the spa's hold: the wings go back to what her flight or excitement last asked for
## (folded, normally).
func _close_wings(visit: Dictionary) -> void:
	var wings: Variant = visit.get("wings")
	if wings != null and is_instance_valid(wings): wings.release_hold(_wing_hold_owner(visit))
	visit.wings = null


func _wing_hold_owner(visit: Dictionary) -> String:
	return "spa:" + str(visit.id)


func _wing_hold_value(visit: Dictionary) -> float:
	return lerpf(WING_HOLD, WING_HOLD_WIDEST, clampf(float(visit.wing_good) / WING_SECONDS, 0.0, 1.0))


func _tick_wings(visit: Dictionary) -> void:
	var wings: Variant = visit.wings
	if wings == null or not is_instance_valid(wings): _leave(visit, "Wings gone"); return
	if not bool(wings.hold_at(_wing_hold_owner(visit), _wing_hold_value(visit))): _leave(visit, "Wings unavailable"); return
	var status: Dictionary = visit.actor.posture_status()
	if str(status.get("kind", "")) != "sit" and str(status.get("requested", "")) != "sit": visit.actor.request_posture("sit")
	_check_wings_done(visit)


func _check_wings_done(visit: Dictionary) -> void:
	if visit.phase != "wing": return
	if float(visit.wing_good) < WING_SECONDS or int(visit.plucked) < int(visit.feathers_total): return
	reaction.emit(visit.id, "stretch")
	_close_wings(visit)
	FEATHERS.clear(visit.actor)
	visit.feathers = []
	if visit.sat: visit.actor.request_posture("stand"); visit.sat = false
	if _wing_owner == visit.id: _wing_owner = ""
	_done(visit, "wings")


## Clients on the cushion near `point`: [{id, wings: [[base, tip], ...], feathers: [Node3D]}].
func wing_targets(point: Vector3, reach := 0.9) -> Array:
	var out := []
	for id: String in _visits:
		var visit: Dictionary = _visits[id]
		if not is_instance_valid(visit.actor) or visit.phase != "wing": continue
		if point.is_finite() and visit.actor.global_position.distance_to(point) > reach + 0.6 * float(visit.size): continue
		var skeleton: Skeleton3D = visit.actor.get("skeleton") as Skeleton3D
		var segments := FEATHERS.lines_world(skeleton, visit.wing_lines) if skeleton != null else []
		var feathers := []
		for feather: Variant in visit.feathers:
			if is_instance_valid(feather): feathers.append(feather)
		out.append({"id": id, "wings": segments, "feathers": feathers, "progress": float(visit.wing_good) / WING_SECONDS})
	return out


func wing_massage(pony_id: String, seconds: float) -> bool:
	var visit: Dictionary = _visits.get(pony_id, {})
	if visit.is_empty() or not is_instance_valid(visit.actor) or visit.phase != "wing" or seconds <= 0.0: return false
	visit.wing_good = float(visit.wing_good) + seconds
	visit.patience = _clock + PATIENCE
	_relax(visit, 0.3 + 0.55 * clampf(float(visit.wing_good) / WING_SECONDS, 0.0, 1.0))
	_check_wings_done(visit)
	return true


## A base-to-tip preening stroke smooths her feathers and counts toward the massage.
func preen_stroke(pony_id: String) -> bool:
	return wing_massage(pony_id, PREEN_CREDIT)


## A stray feather popped free (spa_strokes.FeatherPull said "pop"). Pays 1 bit, detaches it as a
## loose feather under `world` and returns it (null if this was not her stray).
func pluck(pony_id: String, feather: Node3D, world: Node) -> Node3D:
	var visit: Dictionary = _visits.get(pony_id, {})
	if visit.is_empty() or not is_instance_valid(visit.actor) or visit.phase != "wing" or not is_instance_valid(feather): return null
	if not (visit.feathers as Array).has(feather): return null
	(visit.feathers as Array).erase(feather)
	visit.plucked = int(visit.plucked) + 1
	visit.patience = _clock + PATIENCE
	reaction.emit(pony_id, "wince")
	_pay(visit, PAY_FEATHER, "feather")
	var loose: Node3D = FEATHERS.detach(feather, world if is_instance_valid(world) else get_tree().current_scene)
	_check_wings_done(visit)
	return loose


func basket_point() -> Vector3:
	return marker("SPA_FEATHER_BASKET").origin if _markers.has("SPA_FEATHER_BASKET") else Vector3.INF


## A loose feather let go here: into the basket when near it.
func drop_feather(loose: Node3D) -> bool:
	if not is_instance_valid(loose): return false
	var basket := basket_point()
	if basket.is_finite() and loose.global_position.distance_to(basket) <= BASKET_REACH:
		loose.call("into_basket", basket + Vector3(_rng.randf_range(-.05, .05), .04, _rng.randf_range(-.05, .05)))
		return true
	loose.call("drop")
	return false


# ------------------------------------------------------------------ fade (Hayburger pattern)

func _cover() -> Node:
	if not is_instance_valid(_game) or not _game.has_method("_find_camera") or _game.get("player") == null: return null
	var cover: Node = COVER.new(); cover.name = "SpaCover"; _game.add_child(cover); cover.setup(_game)
	return cover


func _lock_player(locked: bool) -> void:
	if not is_instance_valid(_game) or not is_instance_valid(_game.get("inventory")): return
	var body: Node = _game.inventory.get("player_body")
	if is_instance_valid(body) and "controls_locked" in body: body.controls_locked = locked


func _still_here(cover: Node) -> bool:
	if not SHUTDOWN.active and is_inside_tree() and not is_queued_for_deletion(): return true
	if is_instance_valid(cover): cover.queue_free()
	_lock_player(false)
	_transition = false
	return false


func _exit_tree() -> void:
	release_all()
