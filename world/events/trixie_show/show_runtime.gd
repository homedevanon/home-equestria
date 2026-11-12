extends Node
## Trixie's stage shows at the schoolhouse stage (dev 2026-10-16, docs/TRIXIE_SHOW_2026_10_16.md).
## A show happens on 3 % of days, never within 7 days of the last one, some time between 16:30
## and 19:00, after the opening story and not in rain. Trixie walks to the stage, ponies gather
## and sit on the ground in front of it (show_audience.gd) and she performs a few acts drawn at
## random from show_acts.gd, so seeing every trick takes several shows. Only props and effects
## move; Trixie walks, turns, lights her horn and talks. The show really happens wherever Anon
## is (dev 2026-10-16): the stage set and effects run, the crowd walks over and sits (bodies, or
## essences for residents out of range), and Trixie is held at the stage. While Anon is out of
## pony range her body stays unloaded (`population.visiting`); once he comes within it she comes
## out on stage, so walking over mid-show finds it in progress. Her lines are only generated
## while he is in earshot. Console: `show` starts one now, `show tomorrow` books one.

const AUDIENCE := preload("res://world/events/trixie_show/show_audience.gd")
const PROGRAM := preload("res://world/events/trixie_show/show_program.gd")
const PATTER := preload("res://world/events/trixie_show/show_patter.gd")
const CATALOGUE := preload("res://world/population/pony_population_config.gd")
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const MAGIC := preload("res://world/characters/magic/unicorn_magic.gd")
const FX := preload("res://world/events/trixie_show/show_fx.gd")
const AURA := preload("res://world/characters/magic/magic_aura.gd")
const ESSENCE := preload("res://world/life/essence.gd")
const LIFE_CORE := preload("res://world/life/living_world.gd")
const LEGACY := preload("res://world/mechanics/legacy.gd")
const OWNER := "show:"
const TRIXIE := "trixie"
const STATE_KEY := "town_events"
const CHANCE := 0.03
const COOLDOWN_DAYS := 7
const WINDOW := Vector2(16.5, 19.0)
## The schoolhouse stage (scenery json schoolhouse_theatre_01): centre, middle of the front edge of
## its footprint (toward the audience and its door point), stage floor height.
const STAGE_CENTRE := Vector3(10.584, -16.584, -85.118)
const STAGE_FRONT := Vector2(6.585, -79.615)
const STAGE_FLOOR := -14.96
const STAGE_GROUND := -16.18
## Those four are the stage as authored (scenery yaw STAGE_YAW). A show reads the live stage node
## (ai_id STAGE_ID) when it starts and moves them with it, so a stage moved by a mod or a layout
## change gets the show on its boards, not behind it (M-MEC-02, 2026-11-08); no node keeps these.
const STAGE_ID := "schoolhouse_theatre_01"
const STAGE_YAW := -2.19911
var stage_centre := STAGE_CENTRE
var stage_front_xz := STAGE_FRONT
var stage_floor := STAGE_FLOOR
var stage_ground := STAGE_GROUND
## Trixie's body comes out on stage once Anon is this close (the population's own pony range).
const SPAWN_RANGE := 240.0
## Her patter is only generated while Anon could hear it; "Anon watched" needs this close.
const EARSHOT := 45.0
const GATHER_SECONDS := 75.0
## Before Trixie is even on her way (dev 2026-10-17: "the great and powerful trixie captures
## ponyville's audience with her magic! ponies start walking BEFORE trixie arrives"): her magic
## flares over the stage and the town starts walking over for this long first. About three
## minutes from the first firework to the curtain with the gathering (dev 2026-10-28), so a player
## who sees the fireworks or the flashing map icon has time to get there.
const BUZZ_SECONDS := 150.0
## Fireworks go up over the stage this often until the curtain.
const FIREWORK_EVERY := 12.0
## What Anon pays Trixie for a show of his own (bit_payments.gd, dev 2026-10-28). Paid shows play
## on any day within WINDOW and out of the rain (own_show_block, 2026-11-08); the daily roll still
## books its own.
const SHOW_PRICE := 50
const MARKER_ID := "activity:trixie_show"

var game: Node
var show: Dictionary = {}
var audience: RefCounted
var program: Node
var patter: RefCounted
var _tick := 0.0
var _rolled := {}
var _loading: Dictionary = {} # Spawn requester -> threaded resource request still to collect.

func setup(host: Node) -> void:
	game = host
	add_to_group("hush_zones")
	# asks.gd asks event drivers whether an invitation still makes sense (invite_block).
	add_to_group("event_drivers")

## Ponies this close to the stage start no chats of their own and walk up to nopony while
## Trixie performs (dev 2026-10-28: "make everypony by the stage shut the fuck up").
const HUSH_RADIUS := 28.0
func hushes(at: Vector3) -> bool:
	if show.is_empty() or str(show.get("phase", "")) not in ["perform", "bows"]: return false
	return Vector2(at.x - stage_front_xz.x, at.z - stage_front_xz.y).length() < HUSH_RADIUS

func facing() -> Vector3:
	var f := Vector3(stage_front_xz.x - stage_centre.x, 0.0, stage_front_xz.y - stage_centre.z)
	return f.normalized()

## Ground point at the middle of the stage's front edge.
func stage_front() -> Vector3:
	return Vector3(stage_front_xz.x, stage_ground, stage_front_xz.y)

## Where Trixie stands to perform, on the stage floor a little behind the front edge. The deck's
## real height comes from a ray (the scenery door height sits below the boards).
func stage_mark() -> Vector3:
	var p := stage_front() - facing() * 2.2
	return Vector3(p.x, deck_height(p), p.z)

var _deck_cache := {}
func deck_height(at: Vector3) -> float:
	var key := Vector2i(roundi(at.x * 4.0), roundi(at.z * 4.0))
	if _deck_cache.has(key): return _deck_cache[key]
	var y := stage_floor
	if is_inside_tree():
		var ray := PhysicsRayQueryParameters3D.create(Vector3(at.x, stage_ground + 8.0, at.z), Vector3(at.x, stage_ground - 2.0, at.z))
		ray.collision_mask = 1
		var hit := get_viewport().world_3d.direct_space_state.intersect_ray(ray)
		if not hit.is_empty() and not (hit.collider is CharacterBody3D):
			y = float(hit.position.y)
			_deck_cache[key] = y
	return y

## Moves the stage points with the live stage node (ai_id STAGE_ID), or back to the authored
## values when there is none. Once per show start; the deck cache follows. The node's yaw and
## position against STAGE_YAW/STAGE_CENTRE give the move; only a turn about up is followed. In the
## vanilla world the stage node (rnl_scenery.scn) stands 1.77 m above STAGE_CENTRE.y, the scenery
## json's height (same x/z and yaw), so floor and ground follow it up; the deck ray (deck_height) finds the boards either way.
func locate_stage(node: Node3D = null) -> void:
	if node == null: node = _stage_node()
	stage_centre = STAGE_CENTRE; stage_front_xz = STAGE_FRONT; stage_floor = STAGE_FLOOR; stage_ground = STAGE_GROUND
	_deck_cache.clear()
	if node == null or not node.global_transform.is_finite(): return
	var yaw := node.global_basis.orthonormalized().get_euler().y
	var authored := Transform3D(Basis(Vector3.UP, STAGE_YAW), STAGE_CENTRE)
	var live := Transform3D(Basis(Vector3.UP, yaw), node.global_position)
	var moved := live * authored.affine_inverse()
	if moved.origin.length() < 0.01 and absf(angle_difference(yaw, STAGE_YAW)) < 0.001: return
	stage_centre = node.global_position
	var front := moved * Vector3(STAGE_FRONT.x, STAGE_GROUND, STAGE_FRONT.y)
	stage_front_xz = Vector2(front.x, front.z)
	stage_floor = STAGE_FLOOR + moved.origin.y
	stage_ground = STAGE_GROUND + moved.origin.y
	# The ground at the front edge is the terrain's own (the shipped stage stands 1.77 m above the
	# authored height; tools/mechanics/probe_trixie_ground.gd measured it).
	if WorldTerrain.instance != null:
		var ground: float = WorldTerrain.instance.height_at(Vector3(front.x, stage_ground, front.z))
		if is_finite(ground) and absf(ground - stage_ground) < 3.0: stage_ground = ground
	# Only a stage moved across the ground is news (a mod or a layout change), not a height fit.
	if Vector2(moved.origin.x, moved.origin.z).length() > 0.05 or absf(angle_difference(yaw, STAGE_YAW)) > 0.001:
		print("[show] the stage stands %.1f m and %.0f degrees from its authored place; the show follows it" % [node.global_position.distance_to(STAGE_CENTRE), rad_to_deg(angle_difference(STAGE_YAW, yaw))])

func _stage_node() -> Node3D:
	if not is_inside_tree(): return null
	for node: Node in get_tree().get_nodes_in_group("ai_observable"):
		if node is Node3D and node.is_inside_tree() and str(node.get_meta("ai_id", "")) == STAGE_ID: return node as Node3D
	return null

func _state() -> Dictionary:
	var context: Node = game.get("world_context") if game != null else null
	if context == null: return {}
	if not context.state.has(STATE_KEY): context.state[STATE_KEY] = {}
	var events: Dictionary = context.state[STATE_KEY]
	if not events.has("trixie_show"): events["trixie_show"] = {"last_day": -1000, "seen_acts": [], "shows": 0}
	return events["trixie_show"]

func _save() -> void:
	var context: Node = game.get("world_context") if game != null else null
	if context != null and not bool(context.get("_read_only")): context._changed()

func _process(delta: float) -> void:
	_tick += delta
	if _tick < 0.5: return
	var dt := _tick; _tick = 0.0
	if not show.is_empty():
		_advance(dt); return
	if game == null or game.get_node_or_null("LoadingCover") != null: return
	var arrival: Variant = game.get("arrival")
	if arrival is Node and is_instance_valid(arrival) and (arrival as Node).has_method("stage") and str((arrival as Node).call("stage")) != "done": return
	var clock := get_node_or_null("/root/TimeOfDay")
	if clock == null: return
	var h := float(clock.hours)
	if h < WINDOW.x or h >= WINDOW.y: return
	var day := int(clock.day)
	var state := _state()
	if state.is_empty(): return
	# Debug: a show booked for today (Support > "Trixie show tomorrow", console `show tomorrow`)
	# skips the chance, the cooldown and the weather, at FORCED_HOUR.
	if int(state.get("forced_day", -1)) == day:
		if h >= FORCED_HOUR:
			state.erase("forced_day")
			start()
		return
	if h >= scheduled_hour(day) and not _raining(): start()

## The hour today's town show starts, or INF (cooldown, or the day's roll missed). The town
## calendar (world/mechanics/calendar/town_calendar.gd, events.json "trixie_show") owns the roll
## since 2026-11-01, with the same seed, chance, cooldown and window, so the same days fire.
## `-- --old-events`, or no calendar (fixtures), keeps this runtime's own roll.
func scheduled_hour(day: int) -> float:
	var calendar: Node = get_tree().get_first_node_in_group("town_calendar") if is_inside_tree() and not LEGACY.old_events() else null
	if calendar != null and calendar.has_method("due_hour"): return float(calendar.call("due_hour", "trixie_show", day))
	return _roll(day) if off_cooldown(day, int(_state().get("last_day", -1000))) else INF

const FORCED_HOUR := 17.0
## Books a show for the next game day at FORCED_HOUR, whatever the roll, cooldown or weather.
func force_next_day() -> String:
	var clock := get_node_or_null("/root/TimeOfDay")
	var state := _state()
	if clock == null or state.is_empty(): return "The show schedule is not ready."
	var day := int(clock.day) + 1
	state.forced_day = day
	_save()
	print("[show] debug: Trixie's show booked for day %d at %02d:00" % [day, int(FORCED_HOUR)])
	return "Trixie's show is booked for tomorrow at 17:00 at the schoolhouse stage."

static func off_cooldown(day: int, last_day: int) -> bool:
	return day - last_day >= COOLDOWN_DAYS

## The same world and day always roll the same way, so reloading does not reroll.
func _roll(day: int) -> float:
	if _rolled.has(day): return _rolled[day]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(game.population.config_path) + "trixie_show:%d" % day)
	var at := rng.randf_range(WINDOW.x, WINDOW.y - 0.5) if rng.randf() < CHANCE else INF
	_rolled[day] = at
	return at

func _raining() -> bool:
	var weather: Node = game.get_node_or_null("Weather") if game != null else null
	if weather == null: return false
	var p: Dictionary = weather.get("params") if weather.get("params") is Dictionary else {}
	return float(p.get("rain", 0.0)) > 0.1 or float(p.get("snow", 0.0)) > 0.1 or float(p.get("hail", 0.0)) > 0.1

func _camera() -> Node3D:
	return game._find_camera(game.player) if game != null and is_instance_valid(game.player) else null

## Starts a show now (the schedule, the console). False while one is already on. Every show
## plays on stage wherever Anon is; `_watched` is kept for the console and labs that pass it.
func start(_watched := false) -> bool:
	if not show.is_empty() or game == null: return false
	locate_stage()
	var clock := get_node_or_null("/root/TimeOfDay")
	var day := int(clock.day) if clock != null else 0
	var state := _state()
	state.last_day = day
	state.shows = int(state.get("shows", 0)) + 1
	_save()
	var seed_value := hash(str(game.population.config_path) + "trixie_show_program:%d:%d" % [day, int(state.shows)])
	show = {"day": day, "phase": "buzz", "time": 0.0, "seed": seed_value, "spawned": false, "offstage": false, "player_saw": false, "fx_clock": 0.0}
	audience = AUDIENCE.new()
	audience.begin(get_tree(), stage_front(), facing(), seed_value, game.population, game.get_node_or_null("DayRunner"))
	audience.debug = "--show-debug" in preload("res://world/dev_tools.gd").user_args()
	patter = PATTER.new(self)
	program = PROGRAM.new()
	program.name = "TrixieShowProgram"
	add_child(program)
	program.prepare(self, seed_value, state.get("seen_acts", []))
	print("[show] Trixie's show begins (day %d, acts %s)" % [day, str(program.acts)])
	_beacon()
	return true

## Bits Anon has paid Trixie (bit_payments.gd). She keeps them toward a show; once they cover
## SHOW_PRICE and he asks for one, it starts. Returns the note she hears.
func paid_show(paid: int, asked: bool) -> String:
	var state := _state()
	var context: Node = game.get("world_context") if game != null else null
	if state.is_empty() or context == null or bool(context.get("_read_only")): return ""
	var credit := int(state.get("paid_bits", 0)) + maxi(0, paid)
	state.paid_bits = credit
	_save()
	if active(): return "[Your stage show is already on at the schoolhouse.]"
	if credit < SHOW_PRICE: return "[A stage show costs %d bits; Anon has paid you %d toward one so far.]" % [SHOW_PRICE, credit]
	if not asked: return "[That covers a stage show (%d bits) whenever Anon asks for one.]" % SHOW_PRICE
	var blocked := own_show_block()
	if not blocked.is_empty(): return "[No show right now: %s. His bits stay toward a later one.]" % blocked
	if not _start_paid(): return "[You cannot put on a show right now.]"
	state.paid_bits = credit - SHOW_PRICE
	_save()
	return "[Paid! Your stage show at the schoolhouse stage starts in about three minutes; your magic is already calling Ponyville over. Tell Anon to come watch, then head for the stage.]"

## Trixie's own [magic_show] tag (pony_action_executor.gd, dev 2026-10-28): a show Anon paid for
## spends SHOW_PRICE of her credit; without one she may still call a show once the week's cooldown
## has passed. check_only answers whether she could, starting nothing.
func ai_start(check_only := false) -> bool:
	if active() or game == null: return false
	var state := _state()
	if state.is_empty() or not own_show_block().is_empty(): return false
	var clock := get_node_or_null("/root/TimeOfDay")
	var paid := int(state.get("paid_bits", 0)) >= SHOW_PRICE
	if not paid and not off_cooldown(int(clock.day) if clock != null else 0, int(state.get("last_day", -1000))): return false
	if check_only: return true
	if not (_start_paid() if paid else start()): return false
	if paid:
		state.paid_bits = int(state.paid_bits) - SHOW_PRICE
		_save()
	return true

## Why Trixie cannot put on a show of her own now, "" when she can: like the town's shows, hers
## play between 16:30 and 19:00 (WINDOW) and never in rain, snow or hail (M-MEC-03, 2026-11-08).
func own_show_block() -> String:
	var clock := get_node_or_null("/root/TimeOfDay")
	if clock != null:
		var h := float(clock.hours)
		if h < WINDOW.x or h >= WINDOW.y: return "your shows are only between half past four and seven in the evening"
	if _raining(): return "not in this weather"
	return ""

## Trixie's invitations (asks.gd invite, town_calendar invitable): none to her show on a day the
## weather spoils it (raining now, or a wet day by weather.gd's daily roll) unless it is already on.
func invite_block(event_id: String) -> String:
	if event_id != "trixie_show" or active(): return ""
	if _raining(): return "Trixie's show is off in this weather"
	var weather: Node = game.get_node_or_null("Weather") if game != null else null
	if weather != null and weather.has_method("wet_day") and bool(weather.call("wet_day")): return "Rain is due today; Trixie's show may not go on"
	return ""

## A paid show leaves the weekly cooldown alone, so the town's own shows still come.
func _start_paid() -> bool:
	var state := _state()
	var last := int(state.get("last_day", -1000))
	if not start(): return false
	state.last_day = last
	_save()
	return true

## The show's flashing map icon (Trixie's own map mark), every half second while it is on.
func _publish_marker(on: bool) -> void:
	if not is_inside_tree(): return
	var markers: Array[Dictionary] = []
	if on:
		markers.append({"id": MARKER_ID, "name": "Trixie's show", "kind": "activity", "activity": "trixie_show", "icon_id": TRIXIE,
			"flash": int(float(show.get("time", 0.0)) * 2.0) % 2 == 0, "position": Vector2(stage_centre.x, stage_centre.z)})
	for map_view: Node in get_tree().get_nodes_in_group("world_map_views"):
		map_view.set_activity_markers("trixie_show", markers)

## Trixie's magic over the stage, seen across town: the call that sets the crowd walking.
func _beacon() -> void:
	var colour := Color(0.35, 0.55, 1.0)
	var from := stage_mark() - facing() * 3.0
	for i in 3:
		var apex := from + Vector3.UP * (22.0 + 4.0 * i) + facing().cross(Vector3.UP) * (i - 1) * 5.0
		FX.firework(game, from, apex, colour.lerp(Color(0.8, 0.45, 1.0), i * 0.5), _camera())
	MAGIC.burst(game, stage_mark() + Vector3.UP * 1.0, colour, 2.0, 0.8)

func _near_stage(range_m: float) -> bool:
	var camera := _camera()
	return camera != null and camera.global_position.distance_to(stage_centre) < range_m

func trixie() -> Node3D:
	var actor: Variant = show.get("trixie")
	return actor if actor is Node3D and is_instance_valid(actor) and actor.is_inside_tree() and not actor.is_queued_for_deletion() else null

## Async work belongs to one particular show, including a same-day restart.
func owns_show(session: Dictionary) -> bool:
	return is_inside_tree() and not is_queued_for_deletion() and not session.is_empty() and not bool(session.get("ending", false)) and is_same(show, session)

func _bring_trixie() -> void:
	var population: Node = game.population
	var live: Dictionary = population.live.get(TRIXIE, {})
	var actor: Node3D = live.get("actor") if live.get("actor") is Node3D else null
	if is_instance_valid(actor):
		_hold(actor); return
	if not _near_stage(SPAWN_RANGE):
		_offstage(); return
	_spawn_trixie()

## Anon is out of pony range: no body, but she is at the stage all the same. The population
## leaves her to the show (`visiting`) until he comes near and she comes out (_advance).
func _offstage() -> void:
	var population: Node = game.population
	population.visiting[TRIXIE] = show
	show.offstage = true
	var resident := ESSENCE.record(population, TRIXIE)
	if not resident.is_empty():
		# `visiting` reserves the body, not her living-world outing. End that outing
		# and hold her essence too, or its next step walks her away from the stage.
		if not show.has("essence_was_paused"):
			show.essence_was_paused = bool(resident.get("paused", false))
		ESSENCE.leave_outing(population, TRIXIE, "Putting on her magic show")
		var core: RefCounted = ESSENCE.core(population)
		if core != null: core.pause_resident(TRIXIE, true, "Putting on her magic show")
		var at := stage_front() + facing() * 1.5
		at.y = WorldTerrain.instance.height_at(at) if WorldTerrain.instance != null else stage_ground
		resident.position = LIFE_CORE.vector(at)
		resident.last_reason = "Putting on her magic show at the schoolhouse stage"

## Once her body takes over, its show owner/encounter supplies the hold. On cancellation
## give back only the pause acquired by the show, preserving a pre-existing pause.
func _release_essence() -> void:
	if not show.has("essence_was_paused"): return
	var core: RefCounted = ESSENCE.core(game.population)
	if core != null: core.pause_resident(TRIXIE, bool(show.essence_was_paused))
	show.erase("essence_was_paused")

## Spawns her body: from behind the schoolhouse before the curtain, straight onto the boards
## once the show is on.
func _spawn_trixie() -> void:
	if not owns_show(show) or bool(show.get("spawning", false)): return
	var session := show
	show.spawning = true
	var population: Node = game.population
	var requester := Node.new()
	requester.name = "ShowSpawn"
	add_child(requester)
	session.spawn_requester = requester
	var path: String = CATALOGUE.catalogue().get(TRIXIE, "")
	if path == "" or ResourceLoader.load_threaded_request(path, "PackedScene") != OK:
		_end("trixie scene missing"); return
	_loading[requester] = path
	population.visiting[TRIXIE] = session
	while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		if not await SHUTDOWN.seconds(self, .1): return
	if not _loading.has(requester): return # Tree exit already collected the request.
	var packed := ResourceLoader.load_threaded_get(path) as PackedScene
	_loading.erase(requester)
	if not owns_show(session): return
	if packed == null: _end("trixie scene missing"); return
	var on_stage: bool = show.phase in ["perform", "bows"]
	var at := stage_mark() if on_stage else stage_centre - facing() * 9.0
	if not on_stage: at.y = WorldTerrain.instance.height_at(at) if WorldTerrain.instance != null else stage_ground
	var region := "ponyville"
	var actor: Node3D = await game._spawn_resident(TRIXIE, str(population.config.assignments.get(TRIXIE, region)), at, packed, region, requester)
	if not owns_show(session):
		if is_instance_valid(actor) and is_instance_valid(game) and game.is_inside_tree(): game._despawn_resident(TRIXIE, actor)
		return
	requester.queue_free()
	session.erase("spawn_requester")
	_release_visiting(session)
	if is_instance_valid(actor):
		population.live[TRIXIE] = {"actor": actor, "region": str(population.config.assignments.get(TRIXIE, region))}
		if is_instance_valid(game.get("life")):
			game.life.detach(TRIXIE); game.life._sync_roster(); game.life.attach(TRIXIE, actor, true)
	show.spawning = false
	if not is_instance_valid(actor): _end("trixie could not spawn"); return
	show.spawned = true
	show.offstage = false
	_hold(actor)
	if show.phase in ["perform", "bows"]: teleport(actor, stage_mark())

func _hold(actor: Node3D) -> void:
	show.trixie = actor
	# The stage is raised: stranded-pony recovery must not hop her off it mid-show.
	actor.set_meta("event_placed", true)
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav != null:
		nav.stay(); nav.command_owner = OWNER + TRIXIE; nav.wander_enabled = false
		if show.phase in ["call", "gather"]:
			var foot := stage_front() + facing() * 1.5 + facing().cross(Vector3.UP) * 3.0
			nav.go_to(foot, nav.Gait.TROT)
	var encounters: Node = game.get("encounters")
	if encounters != null:
		encounters.begin("trixie_show:%d" % int(show.day), {
			"title": "performing a Great and Powerful magic show", "place": "Schoolhouse stage",
			"participants": [TRIXIE], "movers": {TRIXIE: [OWNER]}, "hold": true,
			"knows": {TRIXIE: ["You are putting on one of your magic shows on the schoolhouse stage. Ponies are gathering to watch."]},
			"commitment": {TRIXIE: "Perform your show with flair; react to the audience; stay on stage until it is over."},
			"allowed": "You stay on your stage until the show is over, whatever anypony says. If Anon talks to you mid-show, answer in one short in-character line and get on with the show; a request to leave, follow, sit or go somewhere waits until after the show.",
			"beats": []})
	_release_essence()

func _advance(dt: float) -> void:
	show.time += dt
	var actor := trixie()
	var offstage: bool = show.offstage
	# Anon came within pony range: she comes out where the show has got to.
	if offstage and _near_stage(SPAWN_RANGE): _spawn_trixie()
	if show.phase not in ["buzz", "call"] and actor == null and not offstage and not bool(show.get("spawning", false)):
		_end("trixie gone"); return
	if show.phase in ["perform", "bows"] and _near_stage(EARSHOT): show.player_saw = true
	audience.tick(dt, show.phase in ["buzz", "call", "gather", "perform"])
	_publish_marker(true)
	if show.phase in ["buzz", "call", "gather"]:
		show.fx_clock = float(show.get("fx_clock", 0.0)) + dt
		if show.fx_clock >= FIREWORK_EVERY:
			show.fx_clock = 0.0
			_beacon()
	match show.phase:
		"buzz":
			if show.time >= BUZZ_SECONDS:
				show.phase = "call"; show.time = 0.0
				_bring_trixie()
		"call":
			if actor == null and not offstage:
				if show.time > 60.0: _end("trixie never arrived")
				return
			show.phase = "gather"; show.time = 0.0
		"gather":
			var nav: Node = actor.get_node_or_null("Navigator") if actor != null else null
			var arrived: bool = offstage or (nav != null and (nav.state == nav.State.ARRIVED or not nav._has_target) and show.time > 2.0)
			# Curtain once she is there and a few watchers sit (or nopony is coming), at the latest
			# after GATHER_SECONDS.
			var seated: int = audience.watching_ids().size()
			var enough: bool = seated >= mini(3, audience.target) or (show.time > 30.0 and audience.members.is_empty())
			if (arrived and show.time > 12.0 and enough) or show.time > GATHER_SECONDS:
				if actor != null: _onto_stage(actor)
				show.phase = "perform"; show.time = 0.0
				program.begin()
		"perform":
			if program.finished:
				show.phase = "bows"; show.time = 0.0
				show.closing_said = not line("closing", "", _closing_done.bind(show))
		"bows":
			# She takes her bow and her closing line finishes before the crowd gets up.
			if (show.time > 8.0 and bool(show.get("closing_said", true))) or show.time > 30.0: _end("done")

func _closing_done(session: Dictionary) -> void:
	if is_same(show, session): show.closing_said = true

## She floats herself up onto the stage in her own magic (dev 2026-10-17: nothing just appears).
func _onto_stage(actor: Node3D) -> void:
	levitate(actor, stage_mark(), 1.8)

## Floats her to `to` along a low arc in her own magic aura, horn lit; she lands facing the crowd.
## Her own motion waits meanwhile (the balloon climb pattern), so nothing snaps or clips.
func levitate(actor: Node3D, to: Vector3, seconds := 1.6) -> void:
	if not is_instance_valid(actor) or not actor.is_inside_tree(): return
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav != null: nav.stay(); nav._native_clear()
	var colour: Color = MAGIC.color_for(actor.identity) if actor.get("identity") != null else Color(0.4, 0.6, 1.0)
	var aura: Node = AURA.create(actor, colour, 1.0, -1.0, true)
	if actor.has_method("cast_magic"): actor.cast_magic(seconds + 0.4)
	actor.motion_paused = true
	var from := actor.global_position
	var tween := actor.create_tween()
	tween.tween_method(func(t: float) -> void:
		if not is_instance_valid(actor): return
		var p := from.lerp(to, t)
		p.y += 0.6 * 4.0 * t * (1.0 - t)
		actor.global_position = p, 0.0, 1.0, seconds).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_callback(func() -> void:
		if is_instance_valid(aura): aura.call("release")
		if not is_instance_valid(actor): return
		actor.motion_paused = false
		actor.reset_motion(Transform3D(Basis.looking_at(facing(), Vector3.UP), to))
		if nav != null and is_instance_valid(nav): nav.face_point = to + facing() * 5.0)

func teleport(actor: Node3D, at: Vector3) -> void:
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav != null: nav.stay(); nav._native_clear()
	var look := -facing()
	actor.reset_motion(Transform3D(Basis.looking_at(-look, Vector3.UP), at))
	if nav != null: nav.face_point = at + facing() * 5.0
	var colour: Color = MAGIC.color_for(actor.identity) if actor.get("identity") != null else Color(0.4, 0.6, 1.0)
	MAGIC.burst(game, at + Vector3.UP * 0.6, colour, 1.2, 0.5)

func _end(reason: String) -> void:
	if show.is_empty() or bool(show.get("ending", false)): return
	show.ending = true
	print("[show] Trixie's show ends: ", reason)
	var day := int(show.day)
	var watchers: Array = [TRIXIE]
	if audience != null:
		watchers.append_array(audience.watching_ids())
		audience.release_all()
	_release_essence()
	_release_visiting(show)
	var requester: Node = show.get("spawn_requester")
	if is_instance_valid(requester): requester.queue_free()
	if is_instance_valid(program):
		var state := _state()
		var seen: Array = state.get("seen_acts", [])
		for act: String in program.performed:
			if act not in seen: seen.append(act)
		state.seen_acts = seen
		_save()
		program.teardown(reason == "done") # Completed shows let the doves fly off.
	var context: Node = game.get("world_context")
	if context != null and reason == "done":
		var player_saw := " Anon watched too." if bool(show.get("player_saw", false)) else ""
		context.record("trixie_show", "Trixie put on a magic show at the schoolhouse stage: %s.%s" % [", ".join(PackedStringArray(program.performed) if is_instance_valid(program) else PackedStringArray()), player_saw], watchers, [TRIXIE], "trixie_show:%d" % day, "Schoolhouse stage")
	var held: Variant = show.get("trixie")
	if held is Node and is_instance_valid(held): (held as Node).remove_meta("event_placed")
	var actor := trixie()
	if actor != null:
		# Down off the stage the same way she came up, then back to her day.
		var down := stage_front() + facing() * 1.5
		down.y = WorldTerrain.instance.height_at(down) if WorldTerrain.instance != null else stage_ground
		if reason == "done": levitate(actor, down, 1.6)
		var nav: Node = actor.get_node_or_null("Navigator")
		if nav != null and str(nav.command_owner).begins_with(OWNER):
			nav.face_point = Vector3.INF; nav.stay(); nav.command_owner = ""; nav.wander_enabled = true
	var encounters: Node = game.get("encounters")
	if encounters != null: encounters.complete("trixie_show:%d" % day)
	show = {}
	_publish_marker(false)
	audience = null
	program = null
	patter = null

func _release_visiting(session: Dictionary) -> void:
	if not is_instance_valid(game) or not is_instance_valid(game.population): return
	if is_same(game.population.visiting.get(TRIXIE), session): game.population.visiting.erase(TRIXIE)

func _exit_tree() -> void:
	_end("scene exit")
	# ResourceLoader has no cancellation; collect only requests this runtime still owns.
	for path: String in _loading.values(): ResourceLoader.load_threaded_get(path)
	_loading.clear()

## Trixie's patter for a moment of the show (show_patter.gd; nothing until the AI is set up).
## True when a line was queued; `finished` runs once it was spoken to the end.
func line(key: String, detail := "", finished := Callable()) -> bool:
	return patter != null and patter.say(key, detail, finished)

## For tests and the console.
func active() -> bool:
	return not show.is_empty()
