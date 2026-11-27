extends RefCounted
## The crowd at a Trixie show (dev 2026-10-16): no seats or rows. Each pony picks her own spot
## on the ground in a fan in front of the stage, walks there, sits and watches. Every show draws
## a different number of ponies; each one decides for herself whether to come, ponies keep
## trickling in while it runs and some leave early. Ponies are moved through their navigator
## under owner "show:<id>", which the day planner and living world leave alone.
## The crowd is real wherever Anon is (dev 2026-10-16): a resident with no body loaded walks to
## her spot and sits as her essence (essence.gd), paused in the living world and held from her
## day plan; when Anon comes near, the population spawns her body there and she carries on
## watching, so arriving late finds the show and its crowd in progress.

const ESSENCE := preload("res://world/life/essence.gd")
const OWNER := "show:"
## An unloaded pony heading for the show trots (m/s; ESSENCE.WALK_SPEED is a stroll).
const ESSENCE_PACE := 2.8
const SPOT_GAP := 1.15            # metres between two watchers
const FAN_NEAR := 3.5             # metres in front of the stage edge
const FAN_FAR := 15.0
const FAN_HALF_ANGLE := deg_to_rad(55.0)
const RECRUIT_RANGE := 350.0      # ponies further away do not hear about it (most of Ponyville)
## Personal interest in a Trixie show, 0..1; everypony else rolls BASE_INTEREST (foals more).
## Raised 2026-10-17 (dev: "three is really sad lol! up the chances a pony wants to come").
const BASE_INTEREST := 0.8
const FOAL_INTEREST := 0.95
const INTEREST := {"twilight_sparkle": 0.6, "starlight_glimmer": 0.9, "pinkie_pie": 0.95, "snips": 1.0,
	"snails": 1.0, "rarity": 0.65, "applejack": 0.6, "rainbow_dash": 0.65, "fluttershy": 0.75}

var tree: SceneTree
var stage_front := Vector3.ZERO   # ground point at the middle of the stage's front edge
var facing := Vector3.FORWARD     # horizontal, from the stage toward the audience
var rng := RandomNumberGenerator.new()
var target := 0                   # crowd size this show
var members: Dictionary = {}      # id -> {actor, essence, spot, phase, stay, tries, t}
var population: Node
var day_runner: Node
var declined: Dictionary = {}     # ids that decided not to come this show
var willing: Dictionary = {}      # ids that decided to come (waiting their turn to set out)
var _next_recruit := 0.0
var _clock := 0.0
var ended := false
## Labs print why nopony came (show_runtime sets it from the --show-debug user arg).
var debug := false
var last_busy := ""
var gone_why := {}   # labs: why recruits were lost (--show-debug)

func begin(t: SceneTree, front: Vector3, toward_audience: Vector3, seed_value: int, people: Node = null, runner: Node = null) -> void:
	tree = t
	population = people
	day_runner = runner
	stage_front = front
	facing = Vector3(toward_audience.x, 0.0, toward_audience.z).normalized()
	rng.seed = seed_value
	# Every show draws a different crowd, from a modest gathering to most of the town.
	# 15-30 watchers (dev 2026-10-28).
	target = int(round(lerpf(15.0, 30.0, pow(rng.randf(), 0.8))))

## Called about twice a second while the show is on. `open` is false once the finale started:
## nopony new sets out then, the ones on their way still arrive.
func tick(dt: float, open: bool) -> void:
	if ended: return
	_clock += dt
	if open and _clock >= _next_recruit and _active_count() < target:
		_recruit_one()
		# Arrivals spread out: a few right away, the rest over the show.
		_next_recruit = _clock + (rng.randf_range(0.5, 2.0) if members.size() < 6 else rng.randf_range(2.0, 7.0))
	for id: String in members.keys():
		_step(id, dt)

func _active_count() -> int:
	var n := 0
	for m: Dictionary in members.values():
		if m.phase in ["walking", "settling", "watching"]: n += 1
	return n

func _recruit_one() -> void:
	var stage := stage_front
	var best: Node3D = null
	var best_id := ""
	var best_d := INF
	var seen := {"ponies": 0, "far": 0, "busy": 0, "declined": 0}
	for actor: Node in tree.get_nodes_in_group("sim_ponies"):
		if not actor is Node3D or actor.get("identity") == null: continue
		var id := str(actor.identity.id)
		if id == "trixie" or members.has(id) or declined.has(id): continue
		seen.ponies += 1
		var d := (actor as Node3D).global_position.distance_to(stage)
		if d > RECRUIT_RANGE: seen.far += 1; continue
		if not can_join(actor as Node3D): seen.busy += 1; last_busy = busy_reason(actor as Node3D); continue
		# Each pony decides once per show whether a Trixie show is her thing (rolled once: a pony
		# re-rolled every recruit tick ended up declining after a few ticks, 2026-10-17).
		if not _decide(id, interest(actor as Node3D)):
			seen.declined += 1
			continue
		if d < best_d: best = actor; best_id = id; best_d = d
	# Residents with no body loaded (Anon is elsewhere) hear about it too.
	for id: String in _essence_ids():
		if id == "trixie" or members.has(id) or declined.has(id): continue
		var resident := ESSENCE.record(population, id)
		if resident.is_empty(): continue
		seen.ponies += 1
		var at := ESSENCE.position(resident)
		var d := Vector2(at.x - stage.x, at.z - stage.z).length()
		if not is_finite(d) or d > RECRUIT_RANGE: seen.far += 1; continue
		if bool(resident.get("asleep", false)) or bool(resident.get("paused", false)): seen.busy += 1; continue
		if not _decide(id, interest_of(id, false)):
			seen.declined += 1
			continue
		if d < best_d: best = null; best_id = id; best_d = d
	if best_id == "":
		if debug:
			var phases := {}
			for m: Dictionary in members.values(): phases[m.phase] = int(phases.get(m.phase, 0)) + 1
			print("[show] nopony to recruit: ", seen, " members: ", phases, " declined: ", declined.size(), " gone why: ", gone_why, " last busy: ", last_busy)
		return
	var spot := _pick_spot()
	if not spot.is_finite(): return
	# Some stay for the whole show, some wander off after a trick or two.
	var stay_for := INF if rng.randf() < 0.8 else rng.randf_range(60.0, 180.0)
	if best == null:
		_recruit_essence(best_id, spot, stay_for)
		return
	var id := best_id
	var nav: Node = best.get_node_or_null("Navigator")
	nav.stay()
	nav.command_owner = OWNER + id
	nav.wander_enabled = false
	nav.go_to(spot, nav.Gait.TROT if best_d > 40.0 else nav.Gait.WALK)
	members[id] = {"actor": best, "essence": false, "held": false, "spot": spot, "phase": "walking", "stay": stay_for, "tries": 0, "t": 0.0}

## Residents out of range of Anon: no body, only their living-world record.
func _essence_ids() -> Array[String]:
	var out: Array[String] = []
	if not is_instance_valid(population) or population.get("config") == null: return out
	for id: String in population.config.assignments:
		if ESSENCE.unloaded(population, id): out.append(id)
	return out

## She sets out as her essence: off any outing, paused in the living world and held from her
## day plan until she is let go.
func _recruit_essence(id: String, spot: Vector3, stay_for: float) -> void:
	var was_paused := bool(ESSENCE.record(population, id).get("paused", false))
	var was_held: Variant = day_runner.held.get(id) if is_instance_valid(day_runner) else null
	ESSENCE.leave_outing(population, id, "Off to watch Trixie's show")
	var core: RefCounted = ESSENCE.core(population)
	if core != null: core.pause_resident(id, true, "Watching Trixie's show")
	if is_instance_valid(day_runner): day_runner.held[id] = true
	members[id] = {"actor": null, "essence": true, "held": true, "was_paused": was_paused, "was_held": was_held, "spot": spot, "phase": "walking", "stay": stay_for, "tries": 0, "t": 0.0}

## Her one decision this show: true (willing, kept) or false (declined, never asked again).
func _decide(id: String, chance: float) -> bool:
	if willing.has(id): return true
	if rng.randf() > chance:
		declined[id] = true
		return false
	willing[id] = true
	return true

func interest(actor: Node3D) -> float:
	return interest_of(str(actor.identity.id), bool(actor.identity.get("filly")))

func interest_of(id: String, filly: bool) -> float:
	if INTEREST.has(id): return float(INTEREST[id])
	return FOAL_INTEREST if filly else BASE_INTEREST

## A pony we may ask along: awake, on her own feet, not with the player, not in a story, and
## only doing her ordinary day (a day-plan, living-world or social step may be interrupted).
## Why can_join refuses a pony (labs and logs).
static func busy_reason(actor: Node3D) -> String:
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav == null: return "no navigator"
	if str(nav.reserved_by) != "": return "reserved by " + str(nav.reserved_by)
	var owner := str(nav.command_owner)
	if owner != "" and not (owner.begins_with("day:") or owner.begins_with("life:") or owner.begins_with("social:") or owner == "rest_after_command"): return "owner " + owner
	if is_instance_valid(nav.get("_follow_target")): return "following"
	if bool(actor.get("sleeping")): return "sleeping"
	if bool(actor.get("motion_paused")): return "paused"
	if actor.is_held(): return "held"
	var flight: Variant = actor.get("flight")
	if flight is Node and (flight as Node).has_method("active") and bool((flight as Node).call("active")): return "flying"
	if bool(actor.get_meta("cuddle_active", false)): return "cuddling"
	if bool(actor.get_meta("affection_active", false)): return "affection"
	if is_instance_valid(actor.get("conversation_target")): return "talking to " + str(actor.get("conversation_target"))
	if actor.has_method("is_speaking") and actor.is_speaking(): return "speaking"
	return "busy"

static func can_join(actor: Node3D) -> bool:
	if not is_instance_valid(actor) or not actor.is_inside_tree(): return false
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav == null or str(nav.reserved_by) != "": return false
	var owner := str(nav.command_owner)
	if owner != "" and not (owner.begins_with("day:") or owner.begins_with("life:") or owner.begins_with("social:") or owner == "rest_after_command"): return false
	if is_instance_valid(nav.get("_follow_target")): return false
	if bool(actor.get("sleeping")) or bool(actor.get("motion_paused")) or actor.is_held(): return false
	if bool(actor.get_meta("cuddle_active", false)) or bool(actor.get_meta("affection_active", false)): return false
	if is_instance_valid(actor.get("conversation_target")) or (actor.has_method("is_speaking") and actor.is_speaking()): return false
	# Far ponies run on clip tiers (not physically grounded); only a pony in flight waits.
	var flight: Variant = actor.get("flight")
	return not (flight is Node and (flight as Node).has_method("active") and bool((flight as Node).call("active")))

## A random point in the fan in front of the stage, at least SPOT_GAP from every other watcher.
func _pick_spot() -> Vector3:
	var side := facing.cross(Vector3.UP)
	for attempt in 40:
		var angle := rng.randf_range(-FAN_HALF_ANGLE, FAN_HALF_ANGLE)
		# Area-even radius, so the back of the fan is not emptier than the front.
		var r := sqrt(rng.randf_range(FAN_NEAR * FAN_NEAR, FAN_FAR * FAN_FAR))
		var dir := facing * cos(angle) + side * sin(angle)
		var p := stage_front + dir * r
		var ok := true
		for m: Dictionary in members.values():
			if m.phase != "gone" and Vector2(p.x - m.spot.x, p.z - m.spot.z).length() < SPOT_GAP: ok = false; break
		if not ok: continue
		p.y = _ground(p)
		return p
	return Vector3.INF

func _ground(p: Vector3) -> float:
	if WorldTerrain.instance != null: return float(WorldTerrain.instance.height_at(p))
	return stage_front.y

func _step(id: String, dt: float) -> void:
	var m: Dictionary = members[id]
	if m.phase == "gone": return
	if bool(m.essence):
		_step_essence(id, m, dt); return
	var actor: Node3D = m.actor
	if not is_instance_valid(actor):
		_gone(id); return
	var nav: Node = actor.get_node_or_null("Navigator")
	# Taken by the player, a story or her own needs: she is no longer ours.
	if nav == null or str(nav.command_owner) != OWNER + id:
		_gone(id); return
	m.t += dt
	match m.phase:
		"walking":
			var here := actor.global_position
			if Vector2(here.x - m.spot.x, here.z - m.spot.z).length() < 1.2 or nav.state == nav.State.ARRIVED:
				nav.stay()
				nav.face_point = stage_front - facing * 2.0
				m.phase = "settling"; m.t = 0.0
			elif nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED] or (not nav._has_target and m.t > 3.0):
				m.tries += 1
				if m.tries > 2 or m.t > 120.0:
					_let_go(id); return
				m.spot = _pick_spot()
				if not m.spot.is_finite(): _let_go(id); return
				nav.go_to(m.spot, nav.Gait.WALK)
		"settling":
			# She turns to the stage first and sits once she faces it (a seated pony does not turn,
			# dev 2026-10-28: "they don't actually... face the stage"); a stuck turn sits anyway.
			nav.face_point = stage_front - facing * 2.0
			if _facing_stage(actor) or m.t > SETTLE_SECONDS:
				_sit(id, actor)
				_tell(actor)
				m.phase = "watching"; m.t = 0.0
		"watching":
			nav.face_point = stage_front - facing * 2.0
			# The posture refuses while she is still moving ("Wait until stopped"): ask again until
			# she has stopped and sits.
			if actor.has_method("posture_status") and str(actor.posture_status().get("requested", "")) != "sit": actor.request_posture("sit")
			if m.t >= float(m.stay): _let_go(id)

## Her essence walks to her spot at walking pace and sits there. Once Anon is near enough for
## the population to spawn her body (where the essence has got to), the body takes over.
func _step_essence(id: String, m: Dictionary, dt: float) -> void:
	var live: Dictionary = population.live.get(id, {}) if is_instance_valid(population) else {}
	var body: Node3D = live.get("actor") if live.get("actor") is Node3D else null
	if is_instance_valid(body) and body.is_inside_tree():
		_adopt(id, m, body); return
	var resident := ESSENCE.record(population, id)
	if resident.is_empty() or bool(resident.get("asleep", false)) or not ESSENCE.unloaded(population, id):
		_let_go(id); return
	m.t += dt
	match m.phase:
		"walking":
			if ESSENCE.walk(resident, m.spot, ESSENCE_PACE, dt):
				m.phase = "watching"; m.t = 0.0
			elif m.t > 300.0:
				_let_go(id)
		"watching":
			if m.t >= float(m.stay): _let_go(id)

## Her body has just come out: she goes on from where her essence was.
func _adopt(id: String, m: Dictionary, body: Node3D) -> void:
	var nav: Node = body.get_node_or_null("Navigator")
	# Streaming and this twice-a-second update are separate steps. In between,
	# the player or a story may have taken her; never replace that new command.
	if not can_join(body):
		_let_go(id); return
	m.essence = false
	m.actor = body
	nav.stay()
	nav.command_owner = OWNER + id
	nav.wander_enabled = false
	var here := body.global_position
	if m.phase == "watching" or Vector2(here.x - m.spot.x, here.z - m.spot.z).length() < 1.2:
		nav.face_point = stage_front - facing * 2.0
		m.phase = "settling"; m.t = 0.0
	else:
		nav.go_to(m.spot, nav.Gait.WALK)
		m.t = 0.0

## Turning to the stage before she sits takes at most this long.
const SETTLE_SECONDS := 12.0
const FACING_TOLERANCE := deg_to_rad(15.0)

func _facing_stage(actor: Node3D) -> bool:
	var to := stage_front - facing * 2.0 - actor.global_position; to.y = 0.0
	var forward := -actor.global_basis.z; forward.y = 0.0
	if to.length() < 0.2 or forward.length() < 0.01: return true
	return forward.angle_to(to) < FACING_TOLERANCE

## Sits on the grass facing the stage (labs log a refusal with --show-debug). Her automatic
## lie-down after 30 s is off while she watches: the watch step asks for "sit" again, so lying
## down meant standing up and sitting again every half minute (seating.gd does the same).
func _sit(id: String, actor: Node3D) -> void:
	var ok: Variant = actor.request_posture("sit")
	var posture: Variant = actor.get("posture")
	if posture is RefCounted and "lie_after_seconds" in posture and not members[id].has("lie_after"):
		members[id].lie_after = float(posture.lie_after_seconds)
		posture.lie_after_seconds = 1e9
	if debug:
		var status: Dictionary = actor.posture_status() if actor.has_method("posture_status") else {}
		print("[show] %s sits: %s %s" % [id, ok, status])

## Lost to something else (the player, a story, streaming): only the hold is given back.
func _gone(id: String) -> void:
	if debug:
		var actor: Variant = members[id].get("actor")
		var nav: Node = (actor as Node3D).get_node_or_null("Navigator") if actor is Node3D and is_instance_valid(actor) else null
		var why := "freed" if nav == null else "owner " + str(nav.command_owner)
		gone_why[why] = int(gone_why.get(why, 0)) + 1
	members[id].phase = "gone"
	_restore(id)
	_unhold(id)

func _unhold(id: String) -> void:
	var m: Dictionary = members[id]
	if not bool(m.get("held", false)): return
	m.held = false
	if is_instance_valid(day_runner):
		if m.get("was_held") != null: day_runner.held[id] = m.was_held
		else: day_runner.held.erase(id)
	var core: RefCounted = ESSENCE.core(population)
	if core != null: core.pause_resident(id, bool(m.get("was_paused", false)))

## She gets up and goes back to her day.
func _let_go(id: String) -> void:
	var m: Dictionary = members[id]
	m.phase = "gone"
	_restore(id)
	_unhold(id)
	var actor: Node3D = m.actor
	if bool(m.essence) or not is_instance_valid(actor): return
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav != null and str(nav.command_owner) == OWNER + id:
		actor.request_posture("stand")
		nav.face_point = Vector3.INF
		nav.stay()
		nav.command_owner = ""
		nav.wander_enabled = true

## What a watcher with a body gets back: her own lie-down timing, and no show line in her prompt.
func _restore(id: String) -> void:
	var m: Dictionary = members[id]
	var actor: Variant = m.get("actor")
	if not (actor is Node3D and is_instance_valid(actor)): return
	(actor as Node3D).remove_meta("show_watching")
	var posture: Variant = (actor as Node3D).get("posture")
	if m.has("lie_after") and posture is RefCounted and "lie_after_seconds" in posture:
		posture.lie_after_seconds = float(m.lie_after)
	m.erase("lie_after")

## What is happening on stage now, for the prompt of a watcher Anon talks to
## (director_prompts.gd reads the "show_watching" meta).
var moment := ""
func set_moment(text: String) -> void:
	moment = text
	for m: Dictionary in members.values():
		if m.phase == "watching" and not bool(m.essence) and is_instance_valid(m.actor):
			_tell(m.actor as Node3D)

func _tell(actor: Node3D) -> void:
	if moment.is_empty(): return
	actor.set_meta("show_watching", "- You're in the crowd watching Trixie's magic show at the schoolhouse stage. Right now on stage: %s. Since the show is going on, keep your eyes up front and only answer in a brief whisper." % moment)

## Watchers with a body (faces, applause, the picked card).
func watchers() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for m: Dictionary in members.values():
		if m.phase == "watching" and not bool(m.essence) and is_instance_valid(m.actor): out.append(m.actor)
	return out

## Everypony sitting in the crowd now, bodies and essences.
func watching_ids() -> Array[String]:
	var out: Array[String] = []
	for id: String in members:
		if members[id].phase == "watching": out.append(id)
	return out

func release_all() -> void:
	ended = true
	for id: String in members.keys():
		if members[id].phase != "gone": _let_go(id)
