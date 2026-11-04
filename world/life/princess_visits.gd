extends Node
## Princess visits (dev 2026-09-25). Canterlot is not built yet, so the princesses come to you:
## - Celestia on 10 % of days, some time between 09:00 and 17:00;
## - Luna on 20 % of nights, between 21:00 and 02:00, only while the player is awake.
## She either arrives on hoof from out of sight, or glides down from the sky in front of the
## player so he notices her. She comes up to him and speaks first, stays while they talk, then
## checks up on a few nearby ponies ("they like to check up on their subjects") and flies off.
## She is spawned only for the visit; pony_population skips her meanwhile (`visiting`).
## F12 starts a visit now (Celestia by day, Luna by night), for testing.

const CONFIG := preload("res://world/population/pony_population_config.gd")
const HOUSE := preload("res://world/buildings/house_interior.gd")
const OWNER := "visit:"
const DAY_CHANCE := 0.10
const NIGHT_CHANCE := 0.20
const DAY_WINDOW := Vector2(9.0, 17.0)
## Night hours past midnight count on from 24 (26 = 02:00).
const NIGHT_WINDOW := Vector2(21.0, 26.0)
const MIN_WITH_PLAYER := 20.0
const MAX_WITH_PLAYER := 240.0
const QUIET_BEFORE_LEAVING := 30.0
const GREETING_RETRY_SECONDS := 2.0
const SUBJECTS := 3
## A whole chance visit, however often he walks off and she follows: after this she says goodbye.
const MAX_VISIT := 420.0
const GREETING := {
	"celestia": "[Observed situation, not player speech] You have come down from Canterlot and have just reached the player for a visit. Greet them warmly as yourself, matching the actual first-meeting and name knowledge in your context. Do not invent earlier visits or familiarity. If you have not met, introduce yourself; otherwise use what you actually remember. One or two short sentences; no action tags needed.",
	"luna": "[Observed situation, not player speech] It is late at night and Anon is still awake. You have come down from the night sky to visit him, and you have just reached him. Greet him as yourself: perhaps remark on him being up so late, on the night or the stars. One or two short sentences; no action tags needed.",
}
const FAREWELL := {
	"celestia": "You want to look in on a few of your subjects nearby before you return to Canterlot.",
	"luna": "You want to look in on a few of your subjects nearby before you return to the night sky.",
}

var game: Node
var _rolled := {}          # "day:12" / "night:12" -> hour of the visit (INF: none or done)
var visit: Dictionary = {} # the visit in progress
var _tick := 0.0
var _visit_generation := 0

func setup(host: Node) -> void:
	game = host

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F12 and visit.is_empty() and preload("res://world/dev_tools.gd").enabled():
		var clock := get_node_or_null("/root/TimeOfDay")
		start("luna" if clock != null and clock.is_night() else "celestia")

func _process(delta: float) -> void:
	_tick += delta
	if _tick < 0.5: return
	var dt := _tick; _tick = 0.0
	if not visit.is_empty():
		if _cut_short(): return
		_advance(dt); return
	if game == null or game.get_node_or_null("LoadingCover") != null: return
	# No chance visits during the arrival story (dev 2026-10-01: Celestia walked up to him in the
	# Everfree while Twilight was finding him). The story calls her itself at Town Hall.
	var arrival: Variant = game.get("arrival")
	if arrival is Node and is_instance_valid(arrival) and (arrival as Node).has_method("stage") and str((arrival as Node).call("stage")) != "done": return
	var clock := get_node_or_null("/root/TimeOfDay")
	if clock == null: return
	var h := float(clock.hours)
	if h >= DAY_WINDOW.x and h < DAY_WINDOW.y:
		var key := "day:%d" % int(clock.day)
		if h >= _roll(key, DAY_CHANCE, DAY_WINDOW) and start("celestia"): _mark_done(key)
	var late := h if h >= 12.0 else h + 24.0
	var night_of := int(clock.day) if h >= 12.0 else int(clock.day) - 1
	if late >= NIGHT_WINDOW.x and late < NIGHT_WINDOW.y and _player_awake():
		var key := "night:%d" % night_of
		if late >= _roll(key, NIGHT_CHANCE, NIGHT_WINDOW) and start("luna"): _mark_done(key)

## The same world and day always roll the same way, so reloading does not reroll, and a visit
## that already happened is kept in the world state so a reload does not send her again
## (dev 2026-10-18: Luna came once per load of the same night).
func _roll(key: String, chance: float, window: Vector2) -> float:
	if _rolled.has(key): return _rolled[key]
	if _done().has(key):
		_rolled[key] = INF
		return INF
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(game.population.config_path) + key)
	var at := rng.randf_range(window.x, window.y) if rng.randf() < chance else INF
	_rolled[key] = at
	return at

func _done() -> Dictionary:
	var context: Node = game.get("world_context") if game != null else null
	if context == null: return {}
	return context.state.get("princess_visits", {}).get("done", {})

func _mark_done(key: String) -> void:
	_rolled[key] = INF
	var context: Node = game.get("world_context")
	if context == null or context.get("_read_only") == true: return
	var record: Dictionary = context.state.get("princess_visits", {})
	var done: Dictionary = record.get("done", {})
	done[key] = true
	# Only recent nights matter for rerolls; keep the record small.
	if done.size() > 30: done.erase(done.keys()[0])
	record["done"] = done
	context.state["princess_visits"] = record
	if context.has_method("_changed"): context._changed()

func _player_awake() -> bool:
	if game == null: return true
	return not bool(game.get("player_sleeping"))

## Ends a chance visit that no longer makes sense (dev 2026-10-18: Luna arrived as he went to
## bed, waited through the night and greeted him at noon, then stayed). While he sleeps she
## simply goes; Luna out in daylight takes her leave; and a visit that ran past MAX_VISIT
## (he kept walking off, she kept following) says goodbye. Story visits are never cut short.
## True when the visit ended this tick.
func _cut_short() -> bool:
	if bool(visit.get("story", false)): return false
	var runtime: Node = get_tree().get_first_node_in_group("encounters")
	if runtime != null and runtime.claimed(str(visit.id)): return false
	# Mid-spawn the actor is not ours to free yet; the next tick has her.
	if visit.phase == "spawning": return false
	if not _player_awake():
		_finish(); return true
	if visit.phase in ["subjects", "leaving"]: return false
	var clock := get_node_or_null("/root/TimeOfDay")
	var daylight: bool = visit.id == "luna" and clock != null and not clock.is_night()
	visit.total = float(visit.get("total", 0.0)) + 0.5
	if not daylight and float(visit.total) < MAX_VISIT: return false
	if visit.phase in ["loading", "spawning", "arriving"] or not bool(visit.get("greeted", false)):
		# Not with him yet: leave without a word.
		if visit.phase == "loading" or not is_instance_valid(visit.get("actor")): _finish(); return true
		_set_phase("leaving"); return false
	if game.director != null: game.director.request_farewell(str(visit.id), FAREWELL.get(visit.id, ""))
	visit.subjects = []
	_set_phase("leaving")
	return false

func _camera() -> Node3D:
	return game._find_camera(game.player) if game != null and is_instance_valid(game.player) else null

## Starts a visit now. False (try again later) while the player is indoors, a visit is already
## on, or she is already out in the world.
## `greeting`: what she comes to say (the arrival story's welcome, world/life/arrival_story.gd);
## `min_stay`: seconds she stays with the player before moving on. `fly_in`: always arrive
## from the sky, landing in front of him (the arrival story: a walk-in from 55 m behind can
## stall among the houses before she reaches him).
func start(id: String, greeting := "", min_stay := MIN_WITH_PLAYER, fly_in := false, story := false) -> bool:
	var camera := _camera()
	var population: Node = game.population if game != null else null
	if camera == null or population == null or not visit.is_empty(): return false
	if population.live.has(id) and not story: return false
	if HOUSE.at(get_tree(), camera.global_position) != null and not story: return false
	var path: String = CONFIG.PRINCESSES.get(id, "")
	if path == "": return false
	var existing: Node3D = population.live.get(id, {}).get("actor") if story else null
	if not is_instance_valid(existing) and ResourceLoader.load_threaded_request(path, "PackedScene") != OK: return false
	_visit_generation += 1
	population.visiting[id] = true
	visit = {"id": id, "path": path, "phase": "loading", "time": 0.0, "fly": fly_in or randf() < 0.5,
		"subjects": [], "subject": null, "greeted": false, "greeting": greeting, "min_stay": min_stay, "story": story}
	if is_instance_valid(existing):
		visit.actor = existing
		visit.fly = false
		var nav: Node = existing.get_node_or_null("Navigator")
		if nav != null: nav.command_owner = OWNER + id; nav.wander_enabled = false
		_set_phase("approach")
	print("[visit] %s is coming (%s)" % [id, "flying in" if visit.fly else "on hoof"])
	return true

func _advance(dt: float) -> void:
	visit.time += dt
	var id: String = visit.id
	var actor: Node3D = visit.get("actor")
	if visit.phase not in ["loading", "spawning"] and not is_instance_valid(actor):
		_finish(); return
	match visit.phase:
		"loading":
			var state := ResourceLoader.load_threaded_get_status(visit.path)
			if state == ResourceLoader.THREAD_LOAD_LOADED:
				visit.phase = "spawning"
				_spawn(ResourceLoader.load_threaded_get(visit.path) as PackedScene)
			elif state != ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				_finish()
		"arriving":
			if actor.get("flight") != null and actor.flight.active():
				# A landing that cannot finish (glide blocked, no landing surface; seen over Town
				# Hall's square in the arrival lab, 2026-09-30): after 15 s glide down ahead,
				# after 30 s set her on the ground where she meant to land.
				if visit.time > 15.0 and not visit.get("land_asked", false):
					visit.land_asked = true; actor.flight.land()
				if visit.time < 30.0: return
				actor.flight.cancel()
				var at: Vector3 = visit.get("landing", actor.global_position)
				var ground: float = WorldTerrain.instance.height_at(at) if is_instance_valid(WorldTerrain.instance) else NAN
				if is_finite(ground): at.y = ground + 0.05
				actor.global_position = at; actor.velocity = Vector3.ZERO
				print("[visit] %s could not land; set down where she meant to" % id)
			_set_phase("approach")
		"approach":
			_approach(actor)
		"with_player":
			_with_player(actor)
		"subjects":
			_subjects(actor)
		"leaving":
			_leaving(actor)

## A landing a flying visitor can actually glide into near the player: flat, roofless ground
## with a clear corridor from the sky and a clear final drop (dev saw Celestia circle over Town
## Hall's square until the 30 s fallback set her down). Empty when no candidate passes.
func _fly_plan(actor: Node3D, eye: Vector3, forward: Vector3) -> Dictionary:
	if not actor.has_method("_ensure_flight"): return {}
	actor.call("_ensure_flight")
	var flight: RefCounted = actor.get("flight")
	if flight == null: return {}
	var scale: float = float(actor.get("body_scale"))
	var space := actor.get_world_3d().direct_space_state
	var mask: int = int(actor.get("floor_mask"))
	for distance: float in [6.0, 9.0, 4.5, 12.0]:
		for turn: float in [0.0, 0.5, -0.5, 1.0, -1.0]:
			var way := forward.rotated(Vector3.UP, turn)
			var probe := eye + way * distance
			var ray := PhysicsRayQueryParameters3D.create(probe + Vector3.UP * 4.0, probe - Vector3.UP * 30.0, mask, [actor.get_rid()])
			var hit := space.intersect_ray(ray)
			if hit.is_empty(): continue
			var spot: Vector3 = flight.landing_surface(hit.position)
			if not spot.is_finite(): continue
			var air := eye + way * (distance + 28.0) + Vector3.UP * 22.0
			var flare := spot + Vector3.UP * (1.5 * scale)
			if flight.clear_segment(air, flare) and flight.clear_segment(flare, spot):
				return {"landing": spot, "air": air}
	return {}

func _set_phase(phase: String) -> void:
	visit.phase = phase; visit.time = 0.0
	visit.erase("greeting_retry_at")

func _spawn(packed: PackedScene) -> void:
	var camera := _camera()
	if packed == null or camera == null: _finish(); return
	var region := str(WorldLayout.nearest(camera.global_position).get("id", ""))
	var forward := -camera.global_basis.z; forward.y = 0.0
	forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
	var id: String = visit.id
	var generation := _visit_generation
	var context: Node = game.get("world_context")
	var epoch: int = int(context.get("epoch")) if context != null else -1
	var actor: Node3D = null
	# Story visitors use a real exterior entrance and walk through the door. A flight
	# landing picked from an indoor camera would otherwise start in the roof or loft.
	if bool(visit.get("story", false)):
		var home: Node3D = HOUSE.at(get_tree(), camera.global_position)
		var entry: Vector3 = home.outside() if home != null else camera.global_position - forward * 8.0
		actor = await game._spawn_resident(id, region, entry, packed, region)
		if not _spawn_current(generation, context, epoch): return
		if actor == null:
			print("[visit] story approach pending: ", game.spawn_failure)
			_finish(); return
		visit.fly = false
		var nav: Node = actor.get_node_or_null("Navigator")
		if nav != null: nav.command_owner = OWNER + id; nav.wander_enabled = false
		visit.actor = actor
		_set_phase("approach")
		return
	if not visit.fly:
		# On hoof: from behind the player, well out of sight.
		var behind := (-forward).rotated(Vector3.UP, randf_range(-1.0, 1.0))
		actor = await game._spawn_resident(id, region, camera.global_position + behind * 55.0, packed, region)
		if not _spawn_current(generation, context, epoch): return
		if actor == null: visit.fly = true
	if actor == null:
		# From the sky: she lands six metres in front of the player, gliding in from well
		# ahead and above so she is in view the whole way down.
		actor = await game._spawn_resident(id, region, camera.global_position + forward * 6.0, packed, region)
		if not _spawn_current(generation, context, epoch): return
		if actor == null:
			print("[visit] %s could not arrive: %s" % [id, game.spawn_failure]); _finish(); return
		var landing := actor.global_position
		var air := Vector3(camera.global_position.x, camera.global_position.y, camera.global_position.z) + forward * 34.0 + Vector3.UP * 22.0
		# Prefer a spot she can provably glide into; the fixed spot ahead stays the fallback.
		var plan := _fly_plan(actor, camera.global_position, forward)
		if not plan.is_empty():
			landing = plan.landing; air = plan.air
		visit.landing = landing
		var toward := landing - air; toward.y = 0.0
		actor.global_position = air
		actor.rotation.y = atan2(-toward.x, -toward.z)
		if not actor.has_method("request_arrival") or not actor.request_arrival(landing):
			actor.global_position = landing
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav != null:
		nav.command_owner = OWNER + id; nav.wander_enabled = false
	visit.actor = actor
	_set_phase("arriving")

func _spawn_current(generation: int, context: Node, epoch: int) -> bool:
	return is_inside_tree() and not is_queued_for_deletion() and is_instance_valid(game) and generation == _visit_generation and (epoch < 0 or (is_instance_valid(context) and int(context.get("epoch")) == epoch))

## How far from him a visitor of ordinary size stops; a bigger pony (Celestia) stops further out.
const PERSONAL_GAP := 2.2
## Per re-aim (every half second), the most her goal turns round him toward where he looks (40 degrees: the
## straight walk between two such goals stays above 0.94 of the gap from him).
const MAX_AIM_TURN := PI * 2.0 / 9.0
## She greets once she is within this angle of where he is looking (or after VIEW_WAIT seconds).
const VIEW_HALF_ANGLE := PI / 3.0
const VIEW_WAIT := 30.0

## Her stopping distance: PERSONAL_GAP for an ordinary mare, scaled by her height (profile
## clearance, which already carries body_scale), never less.
static func personal_gap(actor: Node) -> float:
	var profile: Variant = actor.get("profile") if is_instance_valid(actor) else null
	var clearance: float = float((profile as Object).get("clearance")) if profile is Object and (profile as Object).get("clearance") != null else 1.2
	return PERSONAL_GAP * maxf(1.0, clearance / 1.2)

## Where she walks to greet him (thread 43671981: Celestia walked up from behind and stopped over
## his shoulder, filling the screen): on the side she comes from, turned at most MAX_AIM_TURN toward
## where he is looking, halfway in from where she is to `gap` metres from him. Re-aimed every tick,
## the goal spirals round him into his view instead of cutting past him (tools/test_visit_arrival_spot.gd:
## never nearer than ~0.89 of the gap on the way).
static func greeting_spot(player: Vector3, look: Vector3, from: Vector3, gap: float) -> Vector3:
	var away := Vector3(from.x - player.x, 0.0, from.z - player.z)
	var radius := gap + maxf(0.0, away.length() - gap) * 0.5
	var ahead := Vector3(look.x, 0.0, look.z)
	if ahead.length() < 0.01: ahead = away if away.length() >= 0.01 else Vector3.FORWARD
	if away.length() < 0.01: away = ahead
	away = away.normalized(); ahead = ahead.normalized()
	var turn := clampf(away.signed_angle_to(ahead, Vector3.UP), -MAX_AIM_TURN, MAX_AIM_TURN)
	return player + away.rotated(Vector3.UP, turn) * radius

## True when `from` lies within VIEW_HALF_ANGLE of the flat direction `look` from `player`.
static func in_view(player: Vector3, look: Vector3, from: Vector3) -> bool:
	var away := Vector3(from.x - player.x, 0.0, from.z - player.z)
	var ahead := Vector3(look.x, 0.0, look.z)
	if away.length() < 0.01 or ahead.length() < 0.01: return true
	return away.normalized().dot(ahead.normalized()) >= cos(VIEW_HALF_ANGLE)

## Walk up to the player, round into his view, and stop outside his personal space
## (personal_gap); greet once there.
func _approach(actor: Node3D) -> void:
	var camera := _camera()
	var nav: Node = actor.get_node_or_null("Navigator")
	if camera == null or nav == null: _set_phase("leaving"); return
	var runtime: Node = get_tree().get_first_node_in_group("encounters")
	var claimed: bool = runtime != null and runtime.claimed(str(visit.id))
	var required: bool = claimed or bool(visit.get("story", false))
	var offset := actor.global_position - camera.global_position; offset.y = 0.0
	# Flown in, she has landed a few metres in front of him to greet him: greet from there
	# (the arrival lab, 2026-09-30: the last steps to 3 m could stall past the 60 s limit).
	var gap := personal_gap(actor)
	var reach := maxf(7.0 if bool(visit.get("fly", false)) else 3.0, gap + 1.5)
	var same_room: bool = HOUSE.at(get_tree(), actor.global_position) == HOUSE.at(get_tree(), camera.global_position)
	var look := -camera.global_basis.z
	var player_home: Node3D = HOUSE.at(get_tree(), camera.global_position)
	# Outdoors she greets where he can see her; indoors (small rooms, doors) as before.
	var seen: bool = player_home != null or visit.time > VIEW_WAIT or in_view(camera.global_position, look, actor.global_position)
	if offset.length() < reach and seen and absf(actor.global_position.y - camera.global_position.y) < 3.0 and same_room and nav.command_target_visible(camera):
		nav.stay()
		if offset.length() > 0.1 and actor.has_method("face_direction"): actor.face_direction(-offset.normalized())
		# Back beside him after he walked off: she already greeted him; no second greeting (an
		# unfinished welcome resumes through its encounter instead).
		if bool(visit.get("greeted", false)): _set_phase("with_player"); return
		# Required greetings can be rejected while another turn owns the director. Stay
		# physically beside the listener and retry at a bounded cadence; elapsed approach
		# time is not a greeting acceptance or speech-delivery receipt.
		if required and visit.time < float(visit.get("greeting_retry_at", 0.0)): return
		var greeting: String = str(visit.get("greeting", "")) if str(visit.get("greeting", "")) != "" else GREETING.get(visit.id, "")
		# Without the AI (--no-ai) there is no director: she has simply arrived.
		if game.director == null or game.director.begin_player_greeting(visit.id, greeting):
			# The turn that carries her greeting: a story encounter counts it as delivered only
			# when it is spoken to its end (world/ai/encounters/encounter_runtime.gd).
			visit.greeted = true; visit.greeting_turn = int(game.director._turn_id) if game.director != null else -1
			_set_phase("with_player")
		elif required: visit.greeting_retry_at = visit.time + GREETING_RETRY_SECONDS
		elif visit.time > 70.0: _set_phase("with_player")
		return
	if visit.time > 60.0 and not claimed and not bool(visit.get("story", false)): _set_phase("subjects"); return
	var spot: Vector3 = greeting_spot(camera.global_position, look, actor.global_position, gap) if player_home == null else camera.global_position + offset.normalized() * gap
	var aim: Vector3 = nav.command_follow_goal(spot, camera.global_position)
	# Indoor travel owns its floor/door waypoints; an outdoor grid cannot resolve a loft.
	var goal: Vector3 = aim if player_home != null else nav.command_support(aim)
	if player_home != null: goal.y = nav.command_target_floor(camera.global_position).y
	if goal.is_finite(): nav.command_destination(goal, "trot" if offset.length() > 12.0 else "walk", visit.time > 0.6)

## Stay while they talk; leave after a quiet spell, or when the player walks off.
func _with_player(actor: Node3D) -> void:
	var camera := _camera()
	var director: Node = game.director
	var id: String = visit.id
	if camera == null: _set_phase("subjects"); return
	var runtime: Node = get_tree().get_first_node_in_group("encounters")
	var claimed: bool = runtime != null and runtime.claimed(id)
	if director == null:
		if claimed:
			if actor.global_position.distance_to(camera.global_position) > 5.0 or HOUSE.at(get_tree(), actor.global_position) != HOUSE.at(get_tree(), camera.global_position): _set_phase("approach")
		elif visit.time >= float(visit.get("min_stay", MIN_WITH_PLAYER)): _set_phase("subjects")
		return
	var away := Vector2(actor.global_position.x - camera.global_position.x, actor.global_position.z - camera.global_position.z).length()
	if (away > (5.0 if claimed else 14.0) or (claimed and HOUSE.at(get_tree(), actor.global_position) != HOUSE.at(get_tree(), camera.global_position))) and (claimed or visit.time < MAX_WITH_PLAYER):
		_set_phase("approach"); return
	var last_chat := float(director.characters.get(id, {}).get("chat_last", -1e9))
	var quiet: float = director._now() - last_chat
	if visit.time < float(visit.get("min_stay", MIN_WITH_PLAYER)) or (director.engaged(id) and quiet < QUIET_BEFORE_LEAVING and visit.time < MAX_WITH_PLAYER): return
	# A story encounter still needs her (the arrival welcome): no visit timer sends her off.
	if claimed: return
	director.request_farewell(id, FAREWELL.get(id, ""))
	visit.subjects = _pick_subjects(actor)
	_set_phase("subjects")

## Up to three ponies near her, outdoors and not busy with the player; nearest first.
func _pick_subjects(actor: Node3D) -> Array:
	var found: Array = []
	for pony in game.mares:
		if not is_instance_valid(pony) or pony == actor or not pony.is_inside_tree(): continue
		if pony.get("identity") == null or str(pony.identity.id) in CONFIG.PRINCESSES: continue
		if pony.global_position.distance_to(actor.global_position) > 90.0: continue
		if HOUSE.at(get_tree(), pony.global_position) != null: continue
		if pony.has_method("is_held") and pony.is_held(): continue
		found.append(pony)
	found.sort_custom(func(a, b): return a.global_position.distance_to(actor.global_position) < b.global_position.distance_to(actor.global_position))
	return found.slice(0, SUBJECTS)

## Walk to each subject, look at her and have a few words (an ambient group exchange).
func _subjects(actor: Node3D) -> void:
	var nav: Node = actor.get_node_or_null("Navigator")
	var subject: Node3D = visit.subject
	if not is_instance_valid(subject):
		if visit.subjects.is_empty() or nav == null: _set_phase("leaving"); return
		visit.subject = visit.subjects.pop_front(); visit.time = 0.0; visit.chatted = false
		return
	var offset := actor.global_position - subject.global_position; offset.y = 0.0
	if offset.length() > 2.8:
		if visit.time > 45.0: visit.subject = null; return
		var goal: Vector3 = nav.command_support(subject.global_position + offset.normalized() * 2.0)
		if goal.is_finite(): nav.command_destination(goal, "walk", visit.time > 0.6)
		return
	nav.stay()
	if actor.has_method("set_action_gaze"): actor.set_action_gaze(subject)
	var director: Node = game.director
	if director == null: visit.chatted = true
	elif not visit.get("chatted", false) and director.state == "idle" and not director.group.active() and director.has_method("_begin_group"):
		var ids: Array[String] = [str(visit.id), str(subject.identity.id)]
		if director.characters.has(ids[1]): director._begin_group(ids, true)
		visit.chatted = true
	if visit.time > 25.0 and (director == null or not (director.group.active() and str(visit.id) in director.group.members)):
		if actor.has_method("set_action_gaze"): actor.set_action_gaze(null)
		visit.subject = null

## Fly off toward Canterlot (walk if there is no room to take off); gone once out of sight.
func _leaving(actor: Node3D) -> void:
	var camera := _camera()
	if not visit.get("departed", false):
		visit.departed = true
		var home := WorldLayout.center("canterlot")
		var direction := Vector3(home.x - actor.global_position.x, 0.0, home.z - actor.global_position.z).normalized()
		if direction.length() < 0.1: direction = Vector3.FORWARD
		var flying: bool = actor.has_method("request_flight") and actor.request_flight(actor.global_position + direction * 350.0, 0.0, true)
		if not flying:
			var nav: Node = actor.get_node_or_null("Navigator")
			if nav != null: nav.command_destination(actor.global_position + direction * 120.0, "walk")
		return
	if camera == null: _finish(); return
	var distance := actor.global_position.distance_to(camera.global_position)
	var seen: bool = camera is Camera3D and (camera as Camera3D).is_position_in_frustum(actor.global_position + Vector3.UP)
	if (distance > 120.0 and not seen) or distance > 320.0 or (visit.time > 150.0 and not seen):
		_finish()

func _finish() -> void:
	_visit_generation += 1
	var id: String = visit.get("id", "")
	var actor: Node3D = visit.get("actor")
	if is_instance_valid(actor):
		var nav: Node = actor.get_node_or_null("Navigator")
		if nav != null: nav.command_owner = ""
		game._despawn_resident(id, actor)
	if game != null and game.population != null: game.population.visiting.erase(id)
	if id != "": print("[visit] %s left" % id)
	visit = {}
