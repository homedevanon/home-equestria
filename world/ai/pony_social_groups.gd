extends Node
## Low-frequency shared intentions. Navigator retains steering, feet and avoidance.
const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
const DAILY := preload("res://world/ai/pony_daily_activity.gd")
const MAX_MEMBERS := 3
const JOIN_DISTANCE := 16.0
const OWNER_PREFIX := "social:"
var actors: Dictionary = {}
var groups: Dictionary = {}
var membership: Dictionary = {}
var cooldowns: Dictionary = {}
var visits: Dictionary = {}
var _next_visit_offer := 0.0
var world_context:Node
var director: Node
var enabled := true
var rng := RandomNumberGenerator.new()
var statistics := {"candidate_checks": 0, "discovery_rays": 0, "group_updates": 0, "route_requests": 0}
var _serial := 0
var _clock := 0.0
var _discover_at := 6.0
var _cursor := 0
var _discovery_cursor := 0

func _ready() -> void:
	rng.randomize()
	add_to_group("pony_social_groups")

func register_actor(id: String, actor: Node3D) -> void:
	actors[id] = actor

func forget(id: String) -> void:
	leave(id)
	actors.erase(id)
	cooldowns.erase(id)
	visits.erase(id)
	for recipient: String in visits.keys():
		if visits[recipient].visitor == id: visits.erase(recipient)

func _nav(id: String) -> Node:
	var actor: Node = actors.get(id)
	return actor.get_node_or_null("Navigator") if is_instance_valid(actor) else null

func _busy(id: String) -> bool:
	var actor: Node = actors.get(id)
	if not is_instance_valid(actor): return true
	return actor.has_method("action_interruption_reason") and actor.action_interruption_reason() != ""

func _eligible(id: String) -> bool:
	if is_instance_valid(actors.get(id)) and actors[id].get_meta("living_world", false): return false
	var nav := _nav(id)
	var flight: Variant = actors[id].get("flight") if is_instance_valid(actors.get(id)) else null
	if flight != null and flight.active(): return false
	return nav != null and nav.command_owner == "" and not membership.has(id) and not _busy(id) and float(cooldowns.get(id, 0.0)) <= _clock and not _talking(id)

func _talking(id: String) -> bool:
	return is_instance_valid(director) and director.has_method("engaged") and director.engaged(id)

func _physics_process(delta: float) -> void:
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_physics_step(delta)
	if started > 0: CPU_PROFILE.record("social_groups", started)

func _physics_step(delta: float) -> void:
	_clock += delta
	if not enabled:
		for id in membership.keys(): leave(id)
		return
	if _clock >= _discover_at:
		_discover_at = _clock + rng.randf_range(4.0, 7.0)
		discover()
	# At most one group per frame; each group receives decisions at 2 Hz.
	var keys := groups.keys()
	if keys.is_empty(): return
	_cursor %= keys.size()
	var group_id: String = keys[_cursor]
	_cursor += 1
	if _clock >= groups[group_id].next_tick:
		groups[group_id].next_tick = _clock + .5
		_tick(group_id)

func discover() -> void:
	var buckets := {}
	var rays := 0
	for id: String in actors.keys():
		if not is_instance_valid(actors[id]): forget(id); continue
		var p: Vector3 = actors[id].global_position
		var cell := Vector2i(floori(p.x / JOIN_DISTANCE), floori(p.z / JOIN_DISTANCE))
		if not buckets.has(cell): buckets[cell] = []
		buckets[cell].append(id)
	var seeds := actors.keys()
	# Rotate discovery so a crowded cell does not always prefer the same names.
	if not seeds.is_empty():
		_discovery_cursor = (_discovery_cursor + 8) % seeds.size()
		seeds = seeds.slice(_discovery_cursor) + seeds.slice(0, _discovery_cursor)
	for id: String in seeds:
		if not _eligible(id): continue
		var at: Vector3 = actors[id].global_position
		var cell := Vector2i(floori(at.x / JOIN_DISTANCE), floori(at.z / JOIN_DISTANCE))
		var checked := 0
		var offers:Array=[]
		for dx in range(-1,2):
			for dz in range(-1,2):
				for other:String in buckets.get(cell+Vector2i(dx,dz),[]):
					if checked>=12 or other==id:continue
					checked+=1;statistics.candidate_checks+=1
					if not membership.has(other) and not _eligible(other):continue
					if membership.has(other) and (groups[membership[other]].members.size()>=MAX_MEMBERS or groups[membership[other]].state!="resting"):continue
					var distance:=at.distance_to(actors[other].global_position)
					if distance>JOIN_DISTANCE:continue
					var score:=float(checked)
					if is_instance_valid(world_context):
						var weight:float=world_context.companion_weight(id,other,distance,float(actors[id].get_meta("social_mood",0.)))
						score=-log(maxf(rng.randf(),.000001))/weight
					offers.append({"id":other,"score":score})
		offers.sort_custom(func(a,b):return a.score<b.score)
		for offer:Dictionary in offers:
			var other:String=offer.id
			if is_instance_valid(world_context):
				var preference:float=world_context.relationship(other,id).preference
				if rng.randf()>clampf(.85+preference*.15,.25,1.):continue
			if rays>=24:return
			rays+=1;statistics.discovery_rays+=1
			if not _nav(id).command_target_visible(actors[other]):continue
			if membership.has(other):_join(membership[other],id)
			elif _eligible(other):form([other,id])
			break

func form(ids: Array) -> String:
	var chosen: Array = []
	for id: String in ids:
		if _eligible(id) and id not in chosen: chosen.append(id)
	if chosen.size() < 2: return ""
	_serial += 1
	var gid := OWNER_PREFIX + str(_serial)
	groups[gid] = {"members": [], "leader": chosen[0], "state": "resting", "destination": Vector3.INF,
		"intent": "Taking a break together", "until": _clock + rng.randf_range(4.0, 10.0),
		"expires": _clock + rng.randf_range(150.0, 300.0), "next_tick": 0.0,
		"request": -1, "service": null, "generation": 0, "paused": false,
		"lag_since": -1.0, "goals": {}, "recent": [], "sit_members": [], "rest_postures": {}, "trail": [], "legs_left": 2}
	for id: String in chosen.slice(0, MAX_MEMBERS): _join(gid, id)
	return gid

func _join(gid: String, id: String) -> void:
	visits.erase(id)
	for recipient: String in visits.keys():
		if visits[recipient].visitor == id: visits.erase(recipient)
	groups[gid].members.append(id)
	membership[id] = gid
	var nav := _nav(id)
	nav.command_owner = gid
	nav.stay()
	_publish(gid)

func leave(id: String) -> void:
	if not membership.has(id): return
	var gid: String = membership[id]
	membership.erase(id)
	cooldowns[id] = _clock + rng.randf_range(35.0, 75.0)
	var actor: Node = actors.get(id)
	if is_instance_valid(actor): actor.remove_meta("social_group")
	if _nav(id) != null: _nav(id).face_point = Vector3.INF
	var nav := _nav(id)
	# Never cancel a newer explicit command during the ownership handoff.
	if nav != null and nav.command_owner == gid:
		nav.stay(); nav.command_owner = ""; nav.command_speed_limit = INF
		nav.command_pace_target = -1.0
		nav.wander_enabled = true
		if "_idle_time" in nav: nav._idle_time = rng.randf_range(6.0, 14.0)
	if not groups.has(gid): return
	var g: Dictionary = groups[gid]
	g.members.erase(id)
	g.sit_members.erase(id); g.rest_postures.erase(id); g.goals.erase(id)
	if g.members.size() < 2:
		_cancel(g)
		for remaining: String in g.members.duplicate(): leave(remaining)
		groups.erase(gid)
	elif g.leader == id:
		_cancel(g); g.leader = g.members[0]
		g.trail.clear()
		_rest(gid, 4.0)
	else: _publish(gid)

func _cancel(g: Dictionary) -> void:
	if is_instance_valid(g.service) and g.request >= 0: g.service.cancel_request(g.request)
	g.request = -1; g.generation += 1

func _rest(gid: String, duration: float) -> void:
	var g: Dictionary = groups[gid]
	_cancel(g)
	g.state = "resting"; g.intent = "Taking a break together"
	g.sit_members.clear(); g.rest_postures.clear()
	g.until = _clock + duration; g.goals.clear(); g.lag_since = -1.0; g.rest_since = _clock
	for id: String in g.members:
		var nav := _nav(id)
		if nav != null and nav.command_owner == gid: nav.stay()
	_publish(gid)

func _tick(gid: String) -> void:
	statistics.group_updates += 1
	var g: Dictionary = groups[gid]
	for id: String in g.members.duplicate():
		var nav := _nav(id)
		if nav == null or nav.command_owner != gid or _busy(id): leave(id)
	if not groups.has(gid): return
	if _clock >= g.expires:
		for id: String in g.members.duplicate(): leave(id)
		return
	var talking := false
	for id: String in g.members:
		talking = talking or (_talking(id) and not _walking_dialogue(id, g))
	if talking:
		if not g.paused:
			_cancel(g)
			for id: String in g.members: _nav(id).stay()
			g.paused = true; g.goals.clear(); _publish(gid)
		return
	if g.paused:
		g.paused = false; _rest(gid, rng.randf_range(3.0, 8.0))
	if g.state == "resting":
		# Sit facing one another: each turns toward the members' centroid first (12 s at most; a half turn takes ~7 s).
		var centre := Vector3.ZERO
		for id: String in g.members: centre += actors[id].global_position
		centre /= maxf(1.0, g.members.size())
		for id: String in g.sit_members.duplicate():
			var nav := _nav(id)
			if g.members.size() >= 2 and nav != null: nav.face_point = centre
			var to: Vector3 = centre - actors[id].global_position; to.y = 0.0
			var off := absf(angle_difference(actors[id].rotation.y, atan2(-to.x, -to.z)))
			if g.members.size() >= 2 and to.length() > .25 and off > deg_to_rad(12.0) and _clock - float(g.get("rest_since", _clock)) < 12.0: continue
			if actors[id].request_posture(g.rest_postures.get(id,"sit")): g.sit_members.erase(id)
		if _clock >= g.until: _choose_destination(gid)
		return
	if g.state == "planning":
		if _clock >= g.until: _rest(gid, 8.0)
		return
	var leader: Node3D = actors[g.leader]
	var leader_nav := _nav(g.leader)
	if g.trail.is_empty() or leader.global_position.distance_to(g.trail[0]) > .3:
		g.trail.push_front(leader.global_position)
		if g.trail.size() > 64: g.trail.pop_back()
	var laggers: Array = []
	for id: String in g.members:
		if id != g.leader and leader.global_position.distance_to(actors[id].global_position) > 6.0: laggers.append(id)
	if not laggers.is_empty():
		if g.lag_since < 0.0: g.lag_since = _clock; leader_nav.stay(); g.goals.erase(g.leader)
		g.state = "waiting"; g.intent = "Waiting for the others to catch up"
		if _clock - g.lag_since > 22.0:
			for id: String in laggers: leave(id)
			if not groups.has(gid): return
	else:
		g.lag_since = -1.0; g.state = "walking"; g.intent = g.get("outing", "Taking a walk together")
		_route(g, g.leader, g.destination, _outing_speed(g.leader))
	var all_near := leader.global_position.distance_to(g.destination) < 1.2
	var heading := Vector3(leader.velocity.x, 0, leader.velocity.z) if leader is CharacterBody3D else Vector3.ZERO
	if heading.length() > .15: g.formation_heading = heading.normalized()
	var frame := leader.global_transform
	if g.get("formation_heading", Vector3.ZERO).length_squared() > .5:
		frame.basis = Basis.looking_at(g.formation_heading, Vector3.UP)
	# A narrow street needs one consistent queue. Mixing one side slot with one
	# trailing slot made companions cross each other at bends and return legs.
	var single_file := false
	if leader_nav.has_method("command_formation_support"):
		for i in range(1, g.members.size()):
			if not leader_nav.command_formation_support(formation_point(frame, i), leader.global_position).is_finite(): single_file = true
	for i in range(1, g.members.size()):
		var id: String = g.members[i]
		var actor: Node3D = actors[id]
		var nav := _nav(id)
		var raw := formation_point(frame, i)
		var goal: Vector3 = nav.command_formation_support(raw, leader.global_position) if nav.has_method("command_formation_support") else nav.command_support(raw)
		if single_file or not goal.is_finite() or not nav.command_target_visible(leader):
			var behind := trail_slot(g.trail, 1.7 * i)
			if not behind.is_finite(): behind = leader.global_position + frame.basis.z * (1.7 * i)
			goal = nav.command_support(behind)
		if not goal.is_finite():
			all_near = false
			continue # No teleport or unsupported direct velocity.
		var gap := actor.global_position.distance_to(goal)
		all_near = all_near and gap < 1.0
		var leader_speed := Vector2(leader.velocity.x, leader.velocity.z).length() if leader is CharacterBody3D else 0.0
		if gap < .65 and leader_speed < .1:
			if g.goals.has(id): nav.stay(); g.goals.erase(id)
		else:
			if "command_target_speed" in nav: nav.command_target_speed = leader_speed
			if "command_target_velocity" in nav: nav.command_target_velocity = Vector3(leader.velocity.x, 0, leader.velocity.z)
			_route(g, id, goal, clampf(leader_speed + maxf(0.0, gap-.3) * .8, .15, _band(id, "trot_speed").y))
	if all_near or _clock >= g.until or leader_nav.state in [leader_nav.State.UNREACHABLE, leader_nav.State.BLOCKED]:
		if all_near and is_instance_valid(world_context) and g.has("outing_event") and leader.global_position.distance_to(g.departure)>2.:
			world_context.shared_event("shared_outing",g.members,g.outing_event,"You completed a walk together with "+", ".join(g.members)+".")
		# A local route endpoint is usually the next stretch of the outing, not a
		# reason to sit down. Chain a few stretches before taking a proper break.
		if all_near and daytime_activity() > .5 and g.legs_left > 1:
			g.legs_left -= 1
			_rest(gid, rng.randf_range(.5, 1.0))
			return
		g.legs_left = rng.randi_range(2, 3)
		var span := Vector2(20, 40).lerp(Vector2(3, 7), daytime_activity())
		_rest(gid, rng.randf_range(span.x, span.y))
		# Decide once for the company. Three independent rolls made nearly every
		# daytime arrival a long seated stop even at a modest per-pony probability.
		var settle := rng.randf() < DAILY.rest_probability(.75, daytime_activity())
		for id: String in g.members:
			if settle and actors[id].has_method("request_posture"):
				g.sit_members.append(id)
				g.rest_postures[id]=DAILY.rest_kind(rng.randf())
				if g.rest_postures[id]=="lie_down" and DAILY.sunny(actors[id]): g.intent="Resting together in the sunshine"
		if not g.sit_members.is_empty():
			var settled_span:=DAILY.seated_span(daytime_activity())
			g.until=_clock+rng.randf_range(settled_span.x,settled_span.y)
	_publish(gid)

## Walking together: mostly the everyday stroll (the baked trot clip, dev's "walk"), and in
## company a pony dawdles far more often than alone, easing down to the slow trot (trot_slow) for
## stretches and back up again (dev 2026-10-31: slow "if they're with somepony ... vary their
## speeds NATURALLY"). A smooth per-leader mood drifts over a minute or two, never a step; lazy
## hours dawdle more. The four-beat walk remains for final approaches.
const OUTING_STROLL := Vector2(1.2, 1.8)
const OUTING_DAWDLE := 0.85
func _outing_speed(id: String) -> float:
	var body: float = _band(id, "trot_speed").x / 2.2
	var activity: float = daytime_activity()
	var stroll: Vector2 = DAILY.walk_band(OUTING_STROLL * body, activity)
	var t := _clock * 0.045 + float(absi(hash(id)) % 997)
	var mood := sin(t) * 0.6 + sin(t * 2.3 + 1.7) * 0.4
	# Below the threshold they amble at the slow trot: about half the time in a lazy hour, a
	# third in a busy one.
	var amble := 1.0 - smoothstep(-0.25, 0.15, mood - lerpf(0.05, -0.3, activity))
	var cruise := lerpf(stroll.x, stroll.y, 0.5 + 0.5 * sin(t * 3.7 + 0.4))
	return lerpf(cruise, OUTING_DAWDLE * body * (1.0 + 0.1 * sin(t * 5.1)), amble)

func _band(id: String, name: String) -> Vector2:
	var actor: Node = actors.get(id)
	if actor != null and "profile" in actor and actor.profile != null and name in actor.profile:
		return actor.profile.get(name)
	return Vector2(.3, .5) if name == "walk_speed" else Vector2(2.2, 3.1)

static func formation_point(frame: Transform3D, slot: int) -> Vector3:
	var forward := -frame.basis.z; forward.y = 0.0; forward = forward.normalized()
	var side := forward.cross(Vector3.UP)
	return frame.origin - forward * 1.3 + side * (1.15 if slot % 2 == 1 else -1.15)


## Single-file slots follow the leader's travelled curve around street corners.
static func trail_slot(trail: Array, distance: float) -> Vector3:
	for i in range(1, trail.size()):
		var length: float = trail[i-1].distance_to(trail[i])
		if length >= distance: return Vector3(trail[i-1]).lerp(trail[i], distance / maxf(length, .001))
		distance -= length
	return Vector3.INF

func _route(g: Dictionary, id: String, goal: Vector3, speed: float) -> void:
	var nav := _nav(id)
	if actors[id].has_method("posture_status"):
		var posture: Dictionary = actors[id].posture_status()
		if posture.kind != "stand" or not posture.settled:
			actors[id].request_posture("stand"); return
	nav.command_speed_limit = speed
	nav.command_pace_target = speed
	var failed: bool = nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]
	if not failed and g.goals.has(id) and (g.goals[id] as Vector3).distance_to(goal) < .3: return
	if nav.command_destination(goal, "trot" if speed > _band(id, "walk_speed").y else "walk", id != g.leader):
		g.goals[id] = goal; statistics.route_requests += 1

func _choose_destination(gid: String) -> void:
	var g: Dictionary = groups[gid]
	for id: String in g.members:
		if _nav(id) != null: _nav(id).face_point = Vector3.INF
	var leader: Node3D = actors[g.leader]
	var nav := _nav(g.leader)
	var service: Node = nav.get("_service")
	if not is_instance_valid(service) or not service.ready_for_paths:
		g.until = _clock + 5.0; return
	g.service = service; g.state = "planning"; g.until = _clock + 30.0
	var generation: int = g.generation
	g.request = service.request_wander(leader.global_position, lerpf(25.0, 55.0, daytime_activity()), leader.profile,
		_destination_ready.bind(gid, generation), "", nav._home, nav.outgoing_leash() if nav.has_method("outgoing_leash") else 45.0,
		{"heading": -leader.global_basis.z, "recent": g.recent, "intent": "Taking a walk together"})

func _destination_ready(result: Dictionary, request_id: int, revision: int, gid: String, generation: int) -> void:
	if not groups.has(gid): return
	var g: Dictionary = groups[gid]
	if generation != g.generation or request_id != g.request: return
	g.request = -1
	var goal: Vector3 = result.get("destination", Vector3.INF)
	if not is_instance_valid(g.service) or revision != g.service.revision or result.get("stale", false) or not goal.is_finite():
		_rest(gid, 8.0); return
	# On a return leg the last pony is now in front. Let her lead instead of
	# asking the old leader to push through companions in a narrow street.
	g.members.sort_custom(func(a, b): return actors[a].global_position.distance_squared_to(goal) < actors[b].global_position.distance_squared_to(goal))
	g.leader = g.members[0]
	g.trail.clear()
	for id: String in g.members: g.trail.append(actors[id].global_position)
	var heading: Vector3 = goal - actors[g.leader].global_position; heading.y = 0.0
	g.formation_heading = heading.normalized()
	g.goals.clear()
	g.destination = goal; g.state = "walking"; g.until = _clock + 75.0
	g.departure=actors[g.leader].global_position
	g.outing_event="outing-"+Crypto.new().generate_random_bytes(12).hex_encode()
	g.outing = str(result.get("intent", "Taking a walk together")); g.intent = g.outing
	g.recent.push_front(goal); g.recent.resize(mini(6, g.recent.size()))
	_publish(gid)

func _publish(gid: String) -> void:
	if not groups.has(gid): return
	var g: Dictionary = groups[gid]
	for id: String in g.members:
		if is_instance_valid(actors.get(id)):
			actors[id].set_meta("social_group", {"id": gid, "members": g.members.duplicate(), "leader": g.leader,
				"state": "chatting" if g.paused else g.state, "intention": g.intent})

func companions(id: String) -> Array:
	if membership.has(id): return groups[membership[id]].members.duplicate()
	var actor: Node = actors.get(id)
	return actor.get_meta("social_group", {}).get("members", []).duplicate() if is_instance_valid(actor) else []

func _walking_dialogue(id: String, g: Dictionary) -> bool:
	return g.state == "walking" and is_instance_valid(director) and director.has_method("movement_dialogue_allowed") and director.movement_dialogue_allowed(id)

func pause_for_dialogue(id: String) -> void:
	if not membership.has(id): return
	var gid: String = membership[id]
	var g: Dictionary = groups[gid]
	if g.paused or _walking_dialogue(id, g): return
	_cancel(g); g.paused = true; g.goals.clear()
	for member: String in g.members:
		var nav := _nav(member)
		if nav != null and nav.command_owner == gid: nav.stay()
	_publish(gid)


func daytime_activity() -> float:
	var clock := get_node_or_null("/root/TimeOfDay")
	return DAILY.daylight(float(clock.hours)) if clock != null else 1.0

## One nearby visible, available companion. Snapshot destination, no tracking/chasing,
## loading distant residents, claimed friendship, or language-model calls.
func offer_visit(actor: Node3D) -> Dictionary:
	if not enabled or _clock < _next_visit_offer: return {}
	_next_visit_offer = _clock + 2.0
	for recipient: String in visits.keys():
		if visits[recipient].until <= _clock or not _eligible(recipient): visits.erase(recipient)
	var key: Variant = actors.find_key(actor)
	var id := str(key) if key != null else ""
	if not _eligible(id) or visits.has(id): return {}
	var nav := _nav(id)
	if not nav.wander_enabled: return {}
	var candidates: Array = []
	for other: String in actors:
		if other == id or visits.has(other) or not _eligible(other): continue
		var other_nav := _nav(other)
		if not other_nav.wander_enabled or nav.get("_service") != other_nav.get("_service"): continue
		var distance := actor.global_position.distance_to(actors[other].global_position)
		if distance < 10.0 or distance > lerpf(35.0, 72.0, daytime_activity()): continue
		candidates.append({"id":other,"distance":distance})
	candidates.sort_custom(func(a,b): return a.distance < b.distance)
	var shortlist := candidates.slice(0, 6)
	# Varied nearby destinations; at most three visibility rays per offer and
	# one offer every two seconds across the entire population.
	for attempt in mini(3, shortlist.size()):
		var index := rng.randi_range(0, shortlist.size()-1)
		var other: String = shortlist[index].id; shortlist.remove_at(index)
		if not nav.command_target_visible(actors[other]): continue
		var toward: Vector3 = actor.global_position-actors[other].global_position; toward.y=0.0
		var goal: Vector3 = actors[other].global_position+toward.normalized()*3.5
		visits[other] = {"visitor":id,"until":_clock+100.0}
		# Give the visitor a chance to arrive. Both ponies previously picked unrelated
		# routes while the visitor walked toward an already abandoned snapshot.
		var recipient_nav := _nav(other)
		if recipient_nav.has_method("_begin_rest"):
			var seconds := actor.global_position.distance_to(actors[other].global_position) / maxf(_band(id, "trot_speed").x, .5)
			recipient_nav._begin_rest(clampf(seconds + 10.0, 12.0, 40.0))
			recipient_nav.reason = "Waiting for company"
		var display_name := other.replace("_", " ")
		if "identity" in actors[other] and actors[other].identity != null: display_name = actors[other].identity.display_name
		return {"position":goal,"name":display_name,"id":other}
	return {}
