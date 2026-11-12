extends Node
## Bedtime. Residents go home, climb into bed and get up again in the morning.
## Family households share a regular bedtime; other adults can be night owls.
## Those with no house of their own (overnight visitors, ponies from towns with no houses yet) take
## the free bed of a vacant house nearby, else a grass spot off the roads and paths (M-LIF-01).
## Those who can't get to bed otherwise (no bed, no route) curl up where they are.
## The living world pauses while the "sleep:" owner holds her navigator.
## Share of nights a pony goes to bed at her usual time; the rest stay up late and sleep in
## until early afternoon (dev 2026-09-23: "ponies need their beauty sleep"). Nopony skips sleep.
const SLEEP_CHANCE := .7
## Nights she stays up 1-3 h past her after-sundown bedtime.
const STAY_UP_CHANCE := .4
const HOUSEHOLDS = preload("res://world/population/pony_households.gd")
const FILLIES = preload("res://world/population/pony_population_config.gd").FILLIES
const OWNER := "sleep:"
const ESSENCE := preload("res://world/life/essence.gd")
const CHECK_SECONDS := 1.0
## Ponies who live up on a cloud (dev 2026-09-23: Rainbow Dash lives in the Cloudominium):
## resident id -> scenery node of her home. With its walk-in interior built (dev 2026-09-28:
## world/buildings/cloudominium/home.gd) that is her ordinary house: at bedtime she flies to its
## door, walks in, climbs the stairs and sleeps in her own bed. Without it she sleeps out on the
## cloud as before.
const SKY_HOMES := {"rainbow_dash": "cloudominium_01"}
const CLOUD_LAYER := 1 << 18
var _sky_spots := {}
var _outbound := {}   # id -> deadline (s): walking out of her Cloudominium to fly down (_come_down)
var _sky_candidates := {}   # id -> every open, dry cloud spot _sky_spot() found
const WATER_MASK := 1 << 15   # walk_grid_service.WATER_MASK: query-only water colliders
var population: Node
var clock: Node
var _state: Dictionary = {}   # id -> {night, chosen, phase, actor, bed_time, wake_time, retries, until}
var _timer := 0.0
## Perf 0.1.0: population.home_house() re-runs the house assignment over every house on each call
## (65-150 us). Bedtime asked it for every resident once a second, a 3-6 ms tick at night. A found
## house is reused while it is still in the tree and still her assigned address; each pony's lookup
## refreshes every HOME_CACHE_SECONDS to twice that (staggered), and every unloaded essence's home
## also when a house streams in or out. A missing house is never cached. 0.0 = ask every time.
const HOME_CACHE_SECONDS := 6.0
var _home_cache := {}          # id -> [house, refresh at (ms)]
var _essence_home_cache := {}  # id -> [home point, refresh at (ms), house count]
var _bedtimes := {}            # id -> [night, bedtime(id, night)]: fixed for that night
var _house_count := -1

func setup(people: Node) -> void:
	add_to_group("night_rest")
	population = people
	clock = get_node_or_null("/root/TimeOfDay")

func _night_key() -> int:
	# A night runs until 16:00 the next day, so a late sleeper's entry lasts until she wakes.
	return int(clock.day) - (1 if float(clock.hours) < 16.0 else 0)

func _is_night(entry: Dictionary) -> bool:
	return _is_night_between(float(entry.bed_time), float(entry.wake_time))

func _is_night_between(bed: float, wake: float) -> bool:
	var h := float(clock.hours)
	if bed > wake: return h >= bed or h < wake   # evening to morning
	return h >= bed and h < wake                  # after midnight to the afternoon

## The once-a-second pass over the live ponies (below) is spread over NIGHT_SLICE_TICKS physics
## ticks (W2 perf pass: up to ~1.3 ms in one tick at bedtime). Each pony is still stepped once a
## second, in the same order. Driven by hand (physics processing off, as the tests do) a call
## still runs the whole pass. Rollback: NIGHT_SLICE_TICKS = 1.
const NIGHT_SLICE_TICKS := 6
var _pass_ids: Array = []
var _pass_at := 0
var _pass_chunk := 1
var _pass_night := 0
## The unloaded residents' essence nights, sliced the same way (126 residents at the bench spot).
var _essence_ids: Array = []
var _essence_at := 0
var _essence_chunk := 1

func _physics_process(delta: float) -> void:
	if _essence_at < _essence_ids.size(): _step_essences(_essence_chunk)
	if _pass_at < _pass_ids.size(): _step_pass(_pass_chunk)
	_timer -= delta
	if _timer > 0.0 or population == null or clock == null: return
	_timer = CHECK_SECONDS
	# A pass still unfinished (only with very long ticks) completes before the next begins.
	if _essence_at < _essence_ids.size(): _step_essences(_essence_ids.size())
	if _pass_at < _pass_ids.size(): _step_pass(_pass_ids.size())
	_house_count = get_tree().get_node_count_in_group(&"house_interiors")
	var night := _night_key()
	var hours: float = float(clock.hours)
	if hours > 7.5 and hours < 20.0: _bring_down_unloaded()
	_sky_visits(hours)
	if not _bed_requests.is_empty(): _bed_request_step(night)
	if not _outbound.is_empty(): _outbound_step()
	var slices := maxi(NIGHT_SLICE_TICKS, 1) if is_physics_processing() else 1
	var core: RefCounted = ESSENCE.core(population)
	_essence_ids = core.state.residents.keys() if core != null else []
	_essence_at = 0
	_essence_chunk = ceili(float(_essence_ids.size()) / float(slices))
	_pass_ids = population.live.keys()
	_pass_at = 0
	_pass_night = night
	_pass_chunk = ceili(float(_pass_ids.size()) / float(slices))
	_step_essences(_essence_chunk)
	_step_pass(_pass_chunk)

func _step_pass(count: int) -> void:
	var end := mini(_pass_at + maxi(count, 1), _pass_ids.size())
	var night := _pass_night
	for index in range(_pass_at, end):
		var id: String = _pass_ids[index]
		if not population.live.has(id): continue
		var actor: Node3D = population.live[id].get("actor")
		if not is_instance_valid(actor) or not actor.is_inside_tree(): continue
		var entry: Dictionary = _state.get(id, {})
		if not entry.is_empty() and int(entry.night) != night and entry.phase in ["asleep", "settling", "going", "climbing", "outside", "sky_flying"]:
			# The clock jumped (debug time, a loaded save) past her wake-up: wake her properly
			# first, or she lay asleep for good (Rainbow Dash stayed on her cloud).
			_wake(id, entry, actor)
		if entry.is_empty() or int(entry.night) != night:
			var times := _bedtime(id, night)
			entry = {"night": night, "chosen": false, "decided": false, "phase": "", "actor": actor,
				"bed_time": times.x, "wake_time": times.y, "retries": 0, "until": 0.0}
			_state[id] = entry
		if entry.actor != actor:
			# Streamed back in: a sleeper out of the player's sight goes straight to bed.
			entry.actor = actor
			if entry.phase in ["asleep", "settling", "climbing", "going"]: entry.phase = "going"
		# An AI go_to_bed owns her until she gets up (_bed_request_step).
		if _bed_requests.has(id): continue
		_step(id, entry, actor)
	_pass_at = end

## Unloaded residents keep their nights (dev 2026-09-26: the model unloads, the essence lives
## on; world/life/essence.gd): at her bedtime her essence leaves any outing, heads home (a
## pegasus with a sky home flies up to it) and sleeps there until her wake-up time. `asleep` on
## her living-world record keeps the day plan and the outings off her meanwhile. A pony who
## streams in at night is tucked into bed by the loop above while nopony watches.
func _essence_nights(night: int) -> void:
	var core: RefCounted = ESSENCE.core(population)
	if core == null: return
	for id: String in core.state.residents:
		_essence_night(core.state.residents[id], id, night)

## The next `count` residents of the current essence pass (_physics_process).
func _step_essences(count: int) -> void:
	var end := mini(_essence_at + maxi(count, 1), _essence_ids.size())
	var core: RefCounted = ESSENCE.core(population)
	if core != null:
		var residents: Dictionary = core.state.residents
		for index in range(_essence_at, end):
			var id: String = _essence_ids[index]
			var value: Variant = residents.get(id)
			if value is Dictionary: _essence_night(value as Dictionary, id, _pass_night)
	_essence_at = end

func _essence_night(resident: Dictionary, id: String, night: int) -> void:
	var times := _bedtime(id, night)
	var sleeping := _is_night_between(times.x, times.y)
	if not sleeping:
		if resident.get("asleep", false): resident.erase("asleep")
		return
	if not ESSENCE.unloaded(population, id): return
	if not resident.get("asleep", false):
		resident["asleep"] = true
		ESSENCE.leave_outing(population, id, "Going home to bed")
		resident.last_reason = "Asleep at home"
	# Only a cloud spot already found: _sky_spot() searches the whole tree while it is unloaded.
	# A walk-in Cloudominium is an ordinary home (ESSENCE.home: inside its door).
	var cloud := SKY_HOMES.has(id) and _sky_house(id) == null
	var home: Vector3 = _sky_spots.get(id, Vector3.INF) if cloud else Vector3.INF
	if home.is_finite(): ESSENCE.remember(population, "home:" + id, home)
	elif cloud: home = ESSENCE.known(population, "home:" + id)
	if not home.is_finite(): home = _essence_home(id)
	if not home.is_finite(): return   # nowhere known: she curls up where she is
	var speed: float = ESSENCE.FLY_SPEED if SKY_HOMES.has(id) else ESSENCE.WALK_SPEED
	ESSENCE.walk(resident, home, speed, CHECK_SECONDS)

func _bedtime(id: String, night: int) -> Vector2:
	var row: Array = _bedtimes.get(id, [])
	if row.is_empty() or int(row[0]) != night:
		row = [night, bedtime(id, night)]
		_bedtimes[id] = row
	return row[1]

func _cache_until(id: String) -> int:
	return Time.get_ticks_msec() + int(HOME_CACHE_SECONDS * 1000.0 * (1.0 + float(absi(hash(id)) % 1000) / 1000.0))

## For other once-a-few-seconds readers (house_lamps.gd): the same cached lookups.
func cached_home_house(id: String) -> Node3D:
	return _home_house(id) if population != null and population.has_method("home_house") else null

func cached_essence_home(id: String) -> Vector3:
	return _essence_home(id) if population != null else Vector3.INF

## population.home_house(id) through the cache above.
func _home_house(id: String) -> Node3D:
	var row: Array = _home_cache.get(id, [])
	if HOME_CACHE_SECONDS > 0.0 and not row.is_empty() and Time.get_ticks_msec() < int(row[1]):
		var cached: Variant = row[0]
		var houses: Variant = population.get("houses")
		if is_instance_valid(cached) and (cached as Node).is_inside_tree() and houses is Dictionary \
				and str((houses as Dictionary).get(id, "")) == str(cached.place_id()) \
				and not (population.has_method("is_overnight_visitor") and population.is_overnight_visitor(id)):
			return cached
	var house: Node3D = population.home_house(id)
	if house != null: _home_cache[id] = [house, _cache_until(id)]
	else: _home_cache.erase(id)
	return house

## ESSENCE.home(population, id) through the cache above (an unloaded pony: nopony sees her walk).
func _essence_home(id: String) -> Vector3:
	var row: Array = _essence_home_cache.get(id, [])
	if HOME_CACHE_SECONDS > 0.0 and not row.is_empty() and Time.get_ticks_msec() < int(row[1]) and int(row[2]) == _house_count:
		return row[0]
	var at: Vector3 = ESSENCE.home(population, id)
	_essence_home_cache[id] = [at, _cache_until(id), _house_count]
	return at

## One schedule per family, so a filly does not get an independent 03:00 bedtime.
static func bedtime(id: String, night: int) -> Vector2:
	var key := HOUSEHOLDS.bedtime_key(id)
	var jitter := float(absi(hash(key + str(night))) % 1000) / 1000.0
	var owl := float(absi(hash(key + "owl" + str(night))) % 1000) / 1000.0
	if not FILLIES.has(id) and HOUSEHOLDS.members(id).size() == 1 and owl >= SLEEP_CHANCE:
		return Vector2(1.5 + jitter * 2.0, 12.0 + fmod(jitter * 5.0, 1.0) * 3.0)
	# Bed soon after sundown (18:00), so most are home before the moon is up; some nights she
	# stays up a few more hours to enjoy the night (dev 2026-10-14).
	var bed := 18.75 + jitter * 1.0
	var late := float(absi(hash(key + "late" + str(night))) % 1000) / 1000.0
	var foals := false
	for member in HOUSEHOLDS.members(id): foals = foals or FILLIES.has(str(member))
	if late < STAY_UP_CHANCE and not foals and not FILLIES.has(id): bed += 1.0 + fmod(late * 13.0, 1.0) * 2.0
	return Vector2(bed, 6.0 + fmod(jitter * 7.0, 1.0) * 1.4)

func _nav(actor: Node3D) -> Node: return actor.get_node_or_null("Navigator")

## Between tries at an unreachable bed she stands still instead of replanning every second.
const RETRY_SECONDS := 20.0
func _talking(id: String) -> bool:
	var director: Variant = get_parent().get("director") if get_parent() != null else null
	return is_instance_valid(director) and director is Node and (director as Node).has_method("holds_in_place") \
		and bool((director as Node).call("holds_in_place", id))

func _busy(actor: Node3D) -> bool:
	if actor.get("water_escape") != null and actor.water_escape.active: return true
	if actor.get("_held") or (actor.get("hoof_hold") != null and actor.hoof_hold.active()): return true
	if actor.get("flight") != null and actor.flight.active(): return true
	var nav := _nav(actor)
	if nav == null: return true
	var owner: String = nav.command_owner
	# Player and AI commands win; our own and the living world's routines do not.
	# Day-plan steps (world/life/day) give way to bedtime too.
	return not (owner.is_empty() or owner.begins_with("life:") or owner.begins_with("social:") or owner.begins_with("weather:") or owner.begins_with("day:") or owner.begins_with(OWNER))

func _step(id: String, entry: Dictionary, actor: Node3D) -> void:
	var night := _is_night(entry)
	if not night:
		if entry.phase in ["asleep", "settling", "going", "climbing", "outside", "sky_flying"]: _wake(id, entry, actor)
		return
	if not entry.decided:
		entry.decided = true
		entry.chosen = true
	# Woken by her own choice (wake_up()): after a while, if it is still night, back to bed.
	if entry.phase == "done" and entry.has("resleep_at") and Time.get_ticks_msec() * .001 > float(entry.resleep_at):
		entry.erase("resleep_at"); entry.phase = ""; entry.retries = 0
	if not entry.chosen or entry.phase == "done": return
	# Once accepted, sleep owns the posture until wake-up. Routine steering cannot
	# steal it between our one-second checks. Being picked up explicitly wakes her.
	if entry.phase == "asleep" and actor.sleeping and not actor.get("_held") and not (actor.get("water_escape") != null and actor.water_escape.active):
		var sleep_nav := _nav(actor)
		if sleep_nav != null:
			sleep_nav.stay()
			sleep_nav.command_owner = OWNER + id
		if actor.posture_status().requested != "lie_down": _begin_sleep(entry, actor)
		return
	# Her own flight up to the cloud is not an interruption.
	if _busy(actor) and entry.phase != "sky_flying":
		if entry.has("climb_tween"):
			var climbing: Tween = entry.climb_tween
			if climbing != null and climbing.is_valid(): climbing.kill()
			entry.erase("climb_tween")
			actor.motion_paused = false
		if entry.phase in ["asleep", "settling", "outside"]: _release(entry, actor, false)
		entry.phase = ""
		return
	# A chat comes first, as for a day step (dev 2026-11-04: "she keeps trying to leave even if she's
	# like ok i wont leave"). Bed can wait until the chat ends or he walks off.
	if entry.phase in ["", "going", "outside"] and _talking(id):
		var chat_nav := _nav(actor)
		if entry.phase == "going" and chat_nav.command_owner.begins_with(OWNER):
			chat_nav.stay()
			chat_nav.command_owner = ""
		entry.phase = ""
		return
	if entry.phase == "settling":
		_begin_sleep(entry, actor)
		return
	# Her walk-in Cloudominium takes the ordinary house path below; house travel flies her up to
	# its door (world/characters/navigation/house_travel.gd sky_trip).
	if SKY_HOMES.has(id) and _sky_house(id) == null and _sky_step(id, entry, actor): return
	var house: Node3D = _home_house(id) if population.has_method("home_house") else null
	# Her bed in that house: her own (her id), or a guest's whole free bed ("") in a vacant house.
	var bed_key := id
	if house == null and not SKY_HOMES.has(id):
		house = _guest_house(id, entry, actor)
		if house != null: bed_key = ""
	elif house != null and entry.has("guest_house"):
		# Her own house streamed in after she took a guest bed: hers wins, and _wake must not read
		# the guest house's bed as hers.
		_drop_guest_house(entry)
	entry["shared_bed"] = house != null and house.bed_shared(bed_key)
	var bed_ok: bool = house != null and house.has_method("ensure_bed") and house.ensure_bed(bed_key) != null
	if not bed_ok and bed_key.is_empty():
		_drop_guest_house(entry)
		house = null
	# A save/streamed actor can already be on her mattress. Sending her to the floor-side
	# marker makes her try to walk off the bed indefinitely (its height is outside the
	# approach's arrival tolerance). The same applies if she steps onto it on the way in.
	if bed_ok and entry.phase in ["", "going"] and house.on_mattress(actor.global_position, bed_key):
		_nav(actor).command_owner = OWNER + id
		_tuck_in(bed_key, entry, actor, house)
		return
	# M-AI-19: Anon already lies in her bed at her bedtime. She joins him there (the bed's cuddle rest;
	# bedtime takes her again when he gets up), and never climbs into the lane he lies in.
	if bed_ok and entry.phase in ["", "going"] and _anon_in_bed(id, entry, actor, house, bed_key): return
	match entry.phase:
		"":
			var nav := _nav(actor)
			nav.stay(); nav.command_owner = OWNER + id
			if not bed_ok:
				if house != null: return
				_sleep_out(id, entry, actor); return
			if not _seen(actor) and actor.global_position.distance_to(house.bed_side(bed_key)) > 3.0:
				# Nobody is watching: skip the walk, she is already tucked in.
				_tuck_in(bed_key, entry, actor, house); return
			nav.go_to(house.bed_side(bed_key), nav.Gait.WALK)
			entry.phase = "going"; entry.until = Time.get_ticks_msec() * .001 + 300.0
		"outside":
			_grass_walk(id, entry, actor)
		"going":
			var nav := _nav(actor)
			if not bed_ok:
				if house == null: _sleep_out(id, entry, actor)
				return
			if not nav.command_owner.begins_with(OWNER):
				nav.stay(); nav.command_owner = OWNER + id; nav.go_to(house.bed_side(bed_key), nav.Gait.WALK)
			var side: Vector3 = house.bed_side(bed_key)
			# dev 2026-09-25: "standing at their bed but cannot get in". The walk often ends a little
			# short of the exact side marker (a bed against a wall, the grid's nearest cell), and the
			# old 0.7 m target left her standing there re-requesting the same walk forever. Climb in
			# from anywhere reasonably near the bed, and whenever the walk has stopped close to it.
			var rest_at: Vector3 = house.bed_rest(bed_key).origin
			var here := actor.global_position
			var to_side := Vector2(here.x - side.x, here.z - side.z).length()
			var to_bed := Vector2(here.x - rest_at.x, here.z - rest_at.z).length()
			var level := absf(here.y - side.y) < .8
			var stopped: bool = not nav._has_target or nav.state in [nav.State.ARRIVED, nav.State.UNREACHABLE, nav.State.BLOCKED, nav.State.IDLE]
			var stuck_walk: bool = nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]
			if level and (to_side < 1.3 or to_bed < 1.8 or (stopped and (to_side < 2.6 or to_bed < 3.0))):
				_climb(bed_key, entry, actor, house)
			elif stuck_walk and Time.get_ticks_msec() * .001 < float(entry.get("retry_at", 0.0)):
				# M-LIF-03 (logs Nov 4-7: Octavia, stranded on a flowerbed outside Vinyl's house, retried
				# "Destination is disconnected" 24 times while Anon was within 45 m): after two failed
				# walks she is in bed the moment she is out of his sight, not only once he is 45 m away.
				if int(entry.retries) >= 2 and not _in_view(actor): _tuck_in(bed_key, entry, actor, house)
			elif stuck_walk or Time.get_ticks_msec() * .001 > float(entry.until):
				# No sleeping on the ground outside while she has a bed: keep trying, and the
				# moment nobody is near to watch, she is simply home in bed.
				entry.retries += 1
				entry["retry_at"] = Time.get_ticks_msec() * .001 + RETRY_SECONDS
				if int(entry.retries) <= 3 or int(entry.retries) % 10 == 0:
					print("[night] %s cannot reach her bed (navigator state %d, try %d): %s" % [id, int(nav.state), entry.retries, nav.reason])
				if not _seen(actor) or (int(entry.retries) >= 2 and not _in_view(actor)): _tuck_in(bed_key, entry, actor, house)
				# Watched in her own house (player bug board #19: Fluttershy sat on the floor for
				# hours beside an unreachable bed): after two failed walks she hops in from here.
				elif entry.retries >= 2 and level and house.contains(here): _climb(bed_key, entry, actor, house)
				else: nav.go_to(side, nav.Gait.WALK); entry.until = Time.get_ticks_msec() * .001 + 60.0
			elif not nav._has_target and not stuck_walk: nav.go_to(side, nav.Gait.WALK)
		"asleep":
			_begin_sleep(entry, actor)

## Day plans (world/life/day/actions/visit.gd): is this sky-home pony up on her cloud now?
## Indoors in her Cloudominium she is not: guests walk in through her door like any house.
func at_sky_home(id: String) -> bool:
	if not SKY_HOMES.has(id) or not population.live.has(id): return false
	var actor: Node3D = population.live[id].get("actor")
	if not is_instance_valid(actor): return false
	var house := _sky_house(id)
	if house != null and house.contains(actor.global_position): return false
	var spot := _sky_spot(id)
	return spot.is_finite() and actor.global_position.distance_to(spot) < 25.0

## A free spot on her cloud for a visiting pegasus: another of the cloud's open spots, near her
## but not on top of her, chosen the same way for the same guest.
func sky_guest_spot(host: String, guest: String) -> Vector3:
	if not SKY_HOMES.has(host): return Vector3.INF
	var spot := _sky_spot(host)
	if not spot.is_finite(): return Vector3.INF
	var actor: Node3D = population.live.get(host, {}).get("actor")
	var near: Vector3 = actor.global_position if is_instance_valid(actor) else spot
	var options: Array = _sky_candidates.get(host, [])
	var best := Vector3.INF
	var best_score := INF
	for p: Vector3 in options:
		var d := p.distance_to(near)
		if d < 1.8: continue
		var score := absf(d - 2.5) + float(absi(hash(guest + str(p))) % 100) / 400.0
		if score < best_score: best = p; best_score = score
	return best if best.is_finite() else spot + Vector3(2.0, 0, 0)

func _seen(actor: Node3D) -> bool:
	var camera := preload("res://world/player_view.gd").camera(self)
	if camera == null: return false
	return camera.global_position.distance_to(actor.global_position) < 45.0

## Stricter than _seen, for a pony whose bed walk keeps failing: within 45 m, on screen and not
## behind a wall (one ray to her chest). Used only after failed walks, once a second at most.
func _in_view(actor: Node3D) -> bool:
	var camera := preload("res://world/player_view.gd").camera(self)
	if camera == null or not camera.is_inside_tree(): return false
	var scale: Variant = actor.get("body_scale")
	var chest := actor.global_position + Vector3.UP * .6 * (float(scale) if scale != null else 1.0)
	if camera.global_position.distance_to(chest) > 45.0 or not camera.is_position_in_frustum(chest): return false
	var skip: Array[RID] = []
	if actor is CollisionObject3D: skip.append((actor as CollisionObject3D).get_rid())
	var query := PhysicsRayQueryParameters3D.create(camera.global_position, chest, 1, skip)
	return actor.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

## A short hop onto the mattress, then lie down.
func _climb(id: String, entry: Dictionary, actor: Node3D, house: Node3D) -> void:
	entry.phase = "climbing"
	_nav(actor).stay()
	actor.motion_paused = true
	var rest: Transform3D = house.bed_rest(id)
	var start := actor.global_position
	var turn_from := actor.global_basis.get_rotation_quaternion()
	var turn_to := rest.basis.get_rotation_quaternion()
	var tween := create_tween().bind_node(actor)
	entry["climb_tween"] = tween
	# From farther out (up to ~3 m now) the hop takes a little longer instead of teleporting.
	var hop := clampf(.7 + .25 * maxf(0.0, start.distance_to(rest.origin) - .8), .7, 1.3)
	tween.tween_method(func(t: float):
		if actor.get("_held"): return
		actor.global_position = start.lerp(rest.origin, t) + Vector3.UP * sin(PI * t) * .45 * actor.body_scale
		actor.global_basis = Basis(turn_from.slerp(turn_to, t)), 0.0, 1.0, hop)
	tween.tween_callback(func(): _settle(entry, actor, rest))

func _tuck_in(id: String, entry: Dictionary, actor: Node3D, house: Node3D) -> void:
	_settle(entry, actor, house.bed_rest(id))


## A refused lie-down (still held, carry blend, falling) is not sleep. Retry after
## she settles; manual placement alone never calls this outside her bedtime.
func _begin_sleep(entry: Dictionary, actor: Node3D) -> void:
	var nav := _nav(actor)
	if nav != null: nav.stay()
	if actor.request_posture("lie_down"):
		# An AI go_to_bed by day lies there awake ("sleep" false); bedtime always sleeps.
		actor.sleeping = bool(entry.get("sleep", true))
		entry.phase = "asleep"
	else:
		actor.sleeping = false
		entry.phase = "settling"

func _style(actor: Node3D) -> void:
	# Two ways to sleep, picked each night: curled with the head down, or flat on her side.
	if "sleep_style" in actor: actor.sleep_style = "side" if randf() < .5 else "head_down"

func _settle(entry: Dictionary, actor: Node3D, rest: Transform3D) -> void:
	entry.erase("climb_tween")
	if actor.get("_held"):
		actor.motion_paused = false; entry.phase = ""; return
	_style(actor)
	# Keep limbs within each mattress lane when sharing with family.
	if entry.get("shared_bed", false) and "sleep_style" in actor: actor.sleep_style = "head_down"
	# Tucked in from the "going" walk: that walk to the bed side was still running, so she
	# stood up each tick and lay down the next, jittering halfway down on the bed.
	var nav := _nav(actor)
	if nav != null: nav.stay()
	actor.motion_paused = false
	actor.reset_motion(rest)
	_begin_sleep(entry, actor)

## No bed to reach: lie down and sleep on the spot.
## Bedtime on her cloud: fly up if somepony is watching, otherwise she is already there.
## Returns false (normal bedtime) when the cloud home is not loaded or has no cloud to lie on.
func _sky_step(id: String, entry: Dictionary, actor: Node3D) -> bool:
	if not _sky_spot(id).is_finite(): return false
	var spot := _sky_sleep_spot(id)
	var nav := _nav(actor)
	match entry.phase:
		"":
			nav.stay(); nav.command_owner = OWNER + id
			_style(actor)
			var watched := _seen(actor)
			if not watched or actor.global_position.distance_to(spot) < 2.5 or not actor.has_method("request_flight") or not actor.request_flight(spot, 0.0, true):
				if watched and actor.get("flight") != null: print("[night] %s cannot fly home: %s" % [id, actor.flight.reason])
				_cloud_sleep(entry, actor, spot)
			else:
				# Long enough for the whole trip (about 420 m from town), not a fixed 90 s: she was
				# snapped onto the cloud mid-flight once out of the player's 45 m "watched" range.
				entry.phase = "sky_flying"; entry.until = Time.get_ticks_msec() * .001 + 90.0 + actor.global_position.distance_to(spot) / 2.5
		"sky_flying":
			var flying: bool = actor.get("flight") != null and actor.flight.active()
			if not flying and actor.global_position.distance_to(spot) < 3.0:
				_begin_sleep(entry, actor)
			elif not flying or Time.get_ticks_msec() * .001 > float(entry.until):
				if not _seen(actor) or not actor.request_flight(spot, 0.0, true): _cloud_sleep(entry, actor, spot)
				else: entry.until = Time.get_ticks_msec() * .001 + 90.0 + actor.global_position.distance_to(spot) / 2.5
		"asleep":
			_begin_sleep(entry, actor)
	return true

func _cloud_sleep(entry: Dictionary, actor: Node3D, spot: Vector3) -> void:
	if _nav(actor) != null: _nav(actor).stay()
	actor.reset_motion(Transform3D(actor.global_basis, spot + Vector3.UP * .05))
	_begin_sleep(entry, actor)

## A flat, open patch of cloud floor on her home, found once: rays down around the
## building (not onto its roof) that land on the pegasus-only cloud layer with room above.
func _sky_spot(id: String) -> Vector3:
	if _sky_spots.has(id): return _sky_spots[id]
	var home: Node3D = get_tree().root.find_child(SKY_HOMES[id], true, false)
	if home == null: return Vector3.INF   # not streamed in yet: ask again next check
	var space := home.get_world_3d().direct_space_state
	var box := AABB()
	for mi: MeshInstance3D in home.find_children("*", "MeshInstance3D", true, false):
		var b := mi.global_transform * mi.get_aabb()
		box = b if box.size == Vector3.ZERO else box.merge(b)
	var centre := box.get_center()
	var best := Vector3.INF; var best_score := -INF
	var candidates: Array[Vector3] = []
	for ring in [0.3, 0.45, 0.6, 0.75]:
		for k in 16:
			var off: Vector2 = Vector2.from_angle(TAU * k / 16.0) * Vector2(box.size.x, box.size.z) * ring * 0.5
			var from := Vector3(centre.x + off.x, box.end.y + 5.0, centre.z + off.y)
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * (box.size.y + 30.0), 1 | CLOUD_LAYER))
			if hit.is_empty() or hit.normal.y < .9: continue
			var body := hit.collider as CollisionObject3D
			if body == null or not (body.collision_layer & CLOUD_LAYER): continue
			var up := space.intersect_ray(PhysicsRayQueryParameters3D.create(hit.position + Vector3.UP * .1, hit.position + Vector3.UP * 2.5, 1 | CLOUD_LAYER))
			if not up.is_empty(): continue   # under an overhang or inside the house
			# Not in the rainbow pool (dev 2026-09-25: she stood in it all day): no water on the
			# water query layer over this spot, and not a collider named like a pool or fall.
			var wet := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, hit.position + Vector3.DOWN * .5, WATER_MASK))
			if not wet.is_empty() or _watery(body): continue
			candidates.append(hit.position)
			# Prefer the most open, flattest spot near the house.
			var score: float = hit.normal.y - ring * .2
			if score > best_score: best_score = score; best = hit.position
	_sky_spots[id] = best
	_sky_candidates[id] = candidates
	if not best.is_finite(): push_warning("[night] no open cloud to sleep on at %s" % SKY_HOMES[id])
	return best

## Tonight's bed on the cloud: a different open spot each night (dev 2026-09-25: "sleep in a
## random position on her cloudominium"), stable within the night.
func _sky_sleep_spot(id: String) -> Vector3:
	var fallback := _sky_spot(id)
	var candidates: Array = _sky_candidates.get(id, [])
	if candidates.is_empty(): return fallback
	var night := int(clock.day) if is_instance_valid(clock) else 0
	return candidates[absi(hash(id + "sleep" + str(night))) % candidates.size()]

## Her walk-in Cloudominium (world/buildings/cloudominium/home.gd) once it is built and hers.
func _sky_house(id: String) -> Node3D:
	if not SKY_HOMES.has(id) or population == null or not population.has_method("home_house"): return null
	var house: Node3D = _home_house(id)
	return house if house != null and house.has_method("sky_home") else null

## Up at her sky home: inside the Cloudominium, near its door, or on its cloud.
func _at_sky_home(id: String, point: Vector3) -> bool:
	if not point.is_finite(): return false
	var house := _sky_house(id)
	if house != null and (house.contains(point) or point.distance_to(house.outside()) < 25.0): return true
	var spot := _sky_spot(id)
	return spot.is_finite() and point.distance_to(spot) < 25.0

## Where she appears at home (pony_population.home_position): her front door on the cloud once
## the walk-in Cloudominium is built, else the open cloud spot beside it.
func sky_spawn(id: String) -> Vector3:
	var house := _sky_house(id)
	return house.outside() if house != null else _sky_spot(id)

## game.gd's spawn at `at`: up at her sky home the ground rays do not see the cloud layer (and it
## may be past their reach), so she stands at her door, or on the cloud spot. INF anywhere else.
func sky_spawn_at(id: String, at: Vector3) -> Vector3:
	if not SKY_HOMES.has(id) or not at.is_finite(): return Vector3.INF
	var house := _sky_house(id)
	if house != null:
		var door_at: Vector3 = house.outside()
		if house.contains(at) or Vector2(at.x - door_at.x, at.z - door_at.z).length() < 2.0: return door_at
	var spot := _sky_spot(id)
	return spot if spot.is_finite() and Vector2(spot.x - at.x, spot.z - at.z).length() < 2.0 else Vector3.INF

static func _watery(body: Node) -> bool:
	var n := body
	for i in 4:
		if n == null: break
		var name := String(n.name).to_lower()
		for word in ["water", "pool", "fall", "rainbow", "fountain"]:
			if word in name: return true
		if n.is_in_group("navigation_water"): return true
		n = n.get_parent()
	return false

func _sleep_here(entry: Dictionary, actor: Node3D) -> void:
	_style(actor)
	_nav(actor).stay()
	_begin_sleep(entry, actor)

## M-LIF-01 (thread 43693759/43693788: Blueblood and Cloudy Quartz asleep in the middle of the road).
## A pony with no house of her own takes the whole free bed of a vacant house nearby: no residents,
## not reserved (the player's home, Trixie's wagon, the cottage, the hut), one guest each, the bed
## key "" (house_beds.gd: the house's first bed, no lane). Looked for once a night; kept while the
## house stays vacant. No inn: none is built (art).
const GUEST_HOUSE_RANGE := 120.0
var _guest_claims := {}   # house instance id -> guest id, for tonight

func _guest_house(id: String, entry: Dictionary, actor: Node3D) -> Node3D:
	var held: Variant = entry.get("guest_house")
	if is_instance_valid(held) and _vacant(held as Node3D, id): return held as Node3D
	if entry.has("guest_house"): _drop_guest_house(entry)
	if entry.get("guest_checked", false): return null
	entry["guest_checked"] = true
	var options: Array = []
	for node: Node in get_tree().get_nodes_in_group("house_interiors"):
		var house := node as Node3D
		if house == null or not _vacant(house, id): continue
		var d := house.global_position.distance_to(actor.global_position)
		if d <= GUEST_HOUSE_RANGE: options.append([d, house])
	options.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	for row: Array in options.slice(0, 3):
		var house: Node3D = row[1]
		if house.ensure_bed("") == null or not house.bed_side("").is_finite(): continue
		_guest_claims[house.get_instance_id()] = id
		entry["guest_house"] = house; entry["house"] = house; entry["bed"] = ""
		print("[night] %s has no house here: sleeping in the vacant %s" % [id, str(house.label()) if house.has_method("label") else str(house.name)])
		return house
	return null

## For an AI [go_to_bed] by a pony with no house of her own (pony_action_executor.gd _bed_for, hook
## for W3): tonight's guest house (bed key ""), found the same way as at bedtime; null when none.
func guest_house_for(id: String) -> Node3D:
	if population == null or not population.live.has(id): return null
	var actor: Variant = population.live[id].get("actor")
	if not is_instance_valid(actor): return null
	var entry: Dictionary = _state.get(id, {})
	if entry.is_empty():
		entry = {"night": _night_key(), "phase": "", "decided": false, "chosen": false}
		var times := _bedtime(id, int(entry.night))
		entry.merge({"actor": actor, "bed_time": times.x, "wake_time": times.y, "retries": 0, "until": 0.0})
		_state[id] = entry
	return _guest_house(id, entry, actor as Node3D)

func _vacant(house: Node3D, guest: String) -> bool:
	if not house.is_inside_tree() or not house.has_method("ensure_bed") or not house.has_method("bed_side"): return false
	if house.has_meta("reserved_for") or bool(house.get_meta("shared_player_home", false)): return false
	if house.get("furnish") == false: return false
	var sleepers: Variant = house.get("_sleepers")
	if not sleepers is Array or not (sleepers as Array).is_empty(): return false
	# The address book too: a house that streamed in a moment ago may not have its sleepers yet.
	if population != null and population.has_method("residents_of") and house.has_method("place_id") \
			and not (population.residents_of(house.place_id()) as Array).is_empty(): return false
	var claimed := str(_guest_claims.get(house.get_instance_id(), ""))
	if claimed.is_empty() or claimed == guest: return true
	# Another guest's claim lasts while her night entry still holds this house.
	var other: Dictionary = _state.get(claimed, {})
	return other.get("guest_house") != house

func _drop_guest_house(entry: Dictionary) -> void:
	var held: Variant = entry.get("guest_house")
	if is_instance_valid(held): _guest_claims.erase((held as Node).get_instance_id())
	for key: String in ["guest_house", "house", "bed"]: entry.erase(key)

## No bed for her anywhere: a grass spot off the roads and paths nearby (the walk grid's trail
## weights, as navigation reads them), on natural ground, out of houses and water, with room for her
## lying body; she walks there (or is simply there, unwatched) and sleeps. No spot: where she is.
const GRASS_RINGS := [2.5, 4.0, 6.0, 9.0, 13.0, 18.0]
const GRASS_DIRECTIONS := 12
const GRASS_TRAIL_MAX := 0.1
const GRASS_APART := 1.6

func _sleep_out(id: String, entry: Dictionary, actor: Node3D) -> void:
	if not entry.has("grass"): entry["grass"] = _grass_spot(id, actor)
	var spot: Vector3 = entry.grass
	var here := actor.global_position
	if not spot.is_finite() or Vector2(spot.x - here.x, spot.z - here.z).length() < .8:
		_sleep_here(entry, actor); return
	if not _seen(actor):
		actor.reset_motion(Transform3D(actor.global_basis, spot + Vector3.UP * .05))
		_sleep_here(entry, actor); return
	var nav := _nav(actor)
	nav.stay(); nav.command_owner = OWNER + id
	nav.go_to(spot, nav.Gait.WALK)
	entry.phase = "outside"; entry.until = Time.get_ticks_msec() * .001 + 120.0

func _grass_walk(id: String, entry: Dictionary, actor: Node3D) -> void:
	var nav := _nav(actor)
	var spot: Vector3 = entry.get("grass", Vector3.INF)
	if not spot.is_finite(): _sleep_here(entry, actor); return
	if not nav.command_owner.begins_with(OWNER):
		nav.stay(); nav.command_owner = OWNER + id; nav.go_to(spot, nav.Gait.WALK)
	var here := actor.global_position
	var near := Vector2(spot.x - here.x, spot.z - here.z).length() < 1.0
	var stuck: bool = nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]
	if near or nav.state == nav.State.ARRIVED:
		_sleep_here(entry, actor)
	elif stuck or Time.get_ticks_msec() * .001 > float(entry.until):
		# Unwatched she is simply there; watched, she curls up where the walk ended (as before).
		if not _in_view(actor): actor.reset_motion(Transform3D(actor.global_basis, spot + Vector3.UP * .05))
		_sleep_here(entry, actor)
	elif not nav._has_target: nav.go_to(spot, nav.Gait.WALK)

func _grass_spot(id: String, actor: Node3D) -> Vector3:
	if not actor.is_inside_tree(): return Vector3.INF
	var service: Variant = _walk_service(actor)
	var space := actor.get_world_3d().direct_space_state
	var skip: Array[RID] = []
	if actor is CollisionObject3D: skip.append((actor as CollisionObject3D).get_rid())
	var scale: Variant = actor.get("body_scale")
	var size := float(scale) if scale != null else 1.0
	var room := BoxShape3D.new(); room.size = Vector3(.5, .5, .9) * size
	var query := PhysicsShapeQueryParameters3D.new(); query.shape = room; query.collision_mask = 1; query.exclude = skip
	var taken: Array[Vector3] = []
	for other: String in _state:
		if other != id and _state[other].has("grass"): taken.append(_state[other].grass)
	var here := actor.global_position
	for ring: float in GRASS_RINGS:
		for k in GRASS_DIRECTIONS:
			var p := here + Vector3.FORWARD.rotated(Vector3.UP, TAU * (float(k) + ring * .37) / GRASS_DIRECTIONS) * ring
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 3.0, p + Vector3.DOWN * 6.0, 1, skip))
			if hit.is_empty() or (hit.normal as Vector3).y < .9 or not _natural(hit.collider): continue
			var at: Vector3 = hit.position
			if absf(at.y - here.y) > 3.0 or preload("res://world/buildings/house_interior.gd").at(get_tree(), at) != null: continue
			if not space.intersect_ray(PhysicsRayQueryParameters3D.create(at + Vector3.UP * 3.0, at + Vector3.DOWN * .3, WATER_MASK)).is_empty(): continue
			var apart := true
			for other: Vector3 in taken: apart = apart and other.distance_to(at) >= GRASS_APART
			if not apart: continue
			if service != null:
				var off_path := true
				for d: Vector3 in [Vector3.ZERO, Vector3(.8, 0, 0), Vector3(-.8, 0, 0), Vector3(0, 0, .8), Vector3(0, 0, -.8)]:
					if float(service.trail_weight_at(at + d)) > GRASS_TRAIL_MAX: off_path = false; break
				if not off_path or (actor.get("profile") != null and not bool(service.is_walkable(at, actor.profile))): continue
			query.transform = Transform3D(actor.global_basis.orthonormalized(), at + Vector3.UP * (.06 + room.size.y * .5))
			if not space.intersect_shape(query, 1).is_empty(): continue
			return at
	return Vector3.INF

## The walk grid her navigator plans on (its trail weights are the road and path masks); null when
## none is ready. Fixtures override it.
func _walk_service(actor: Node3D) -> Object:
	var nav := _nav(actor)
	var service: Variant = nav.get("_service") if nav != null else null
	if not is_instance_valid(service) or not (service as Object).has_method("trail_weight_at"): return null
	return service as Object

## Grass, not a road, plaza, flowerbed or roof: the terrain itself (shared_nap_grass.gd's rule).
static func _natural(collider: Variant) -> bool:
	if not is_instance_valid(collider) or not collider is Node: return false
	var node := collider as Node
	return node.is_class("Terrain3D") or "terrain" in String(node.name).to_lower() or bool(node.get_meta("nap_ground", false))

## Her AI chose to get up (wake_up(), pony_action_executor.gd). True when she was asleep or on
## her way to bed tonight; she may turn in again ten minutes later if it is still night.
func wake_up(id: String) -> bool:
	if _bed_requests.has(id):
		var request: Dictionary = _bed_requests[id]
		_bed_requests.erase(id)
		var body: Variant = population.live.get(id, {}).get("actor")
		if is_instance_valid(body): _wake(id, request, body)
		return true
	var entry: Dictionary = _state.get(id, {})
	var actor: Variant = entry.get("actor")
	if entry.is_empty() or not is_instance_valid(actor): return false
	if entry.phase not in ["asleep", "settling", "going", "climbing", "outside", "sky_flying"]: return false
	_wake(id, entry, actor)
	entry.resleep_at = Time.get_ticks_msec() * .001 + 600.0
	return true

func _wake(id: String, entry: Dictionary, actor: Node3D) -> void:
	if entry.has("climb_tween"):
		var climbing: Tween = entry.climb_tween
		if climbing != null and climbing.is_valid(): climbing.kill()
		entry.erase("climb_tween")
		actor.motion_paused = false
	# Asleep out on her cloud (no walk-in interior, or no way in last night): back down to town.
	# In her own bed indoors she climbs out below like everypony, and home_idle sends her down.
	var cloud_house := _sky_house(id)
	var indoors: bool = cloud_house != null and cloud_house.contains(actor.global_position)
	if SKY_HOMES.has(id) and not indoors and _sky_spot(id).is_finite() and actor.global_position.distance_to(_sky_spot(id)) < 25.0:
		_come_down(id, entry, actor); return
	var house: Node3D = population.home_house(id) if population.has_method("home_house") else null
	# An AI go_to_bed names its own house and bed (send_to_bed); bedtime is her own.
	var bed_key := id
	if entry.has("bed") and is_instance_valid(entry.get("house")):
		house = entry.house; bed_key = str(entry.bed)
	var in_bed: bool = entry.phase == "asleep" and house != null and (is_instance_valid(house.get("bed")) or entry.has("bed")) \
		and actor.global_position.distance_to(house.bed_rest(bed_key).origin) < 1.2
	actor.sleeping = false
	actor.request_posture("stand")
	if in_bed:
		# Stand up on the mattress, then hop back down beside the bed.
		var side: Vector3 = house.bed_side(bed_key)
		var from := [Vector3.ZERO]
		var tween := create_tween().bind_node(actor)
		tween.tween_interval(1.6)
		tween.tween_callback(func(): actor.motion_paused = true; from[0] = actor.global_position)
		tween.tween_method(func(t: float):
			actor.global_position = (from[0] as Vector3).lerp(side, t) + Vector3.UP * sin(PI * t) * .35 * actor.body_scale, 0.0, 1.0, .6)
		tween.tween_callback(func():
			actor.motion_paused = false
			actor.reset_motion(Transform3D(actor.global_basis, side + Vector3.UP * .02))
			_release(entry, actor, true))
	else:
		_release(entry, actor, true)
	entry.phase = "done"

## Morning on the cloud: she flies back down to town (watched) or is simply there (unwatched).
## Nothing else can walk her off a cloud; she stayed up there for good (dev 2026-09-23).
func _come_down(id: String, entry: Dictionary, actor: Node3D) -> void:
	actor.sleeping = false
	actor.request_posture("stand")
	var town: Vector3 = _ground(population.home_position(id, true) if population.has_method("home_position") else Vector3.INF)
	entry.phase = "done"
	if not town.is_finite(): _release(entry, actor, true); return
	_release(entry, actor, true)
	var house := _sky_house(id)
	var nav := _nav(actor)
	if house != null and house.contains(actor.global_position) and _seen(actor) and nav != null:
		# Down her stairs and out of the front door; house travel flies her down off the cloud. The
		# living world waits meanwhile (_outbound_step frees her once she is off her cloud).
		nav.go_to(town, nav.Gait.WALK)
		nav.command_owner = OWNER + id
		_outbound[id] = Time.get_ticks_msec() * .001 + 240.0
		return
	if _seen(actor) and actor.has_method("request_flight") and actor.request_flight(town, 0.0, true): return
	actor.reset_motion(Transform3D(actor.global_basis, town + Vector3.UP * .05))

## Daytime visits home (dev 2026-09-23: "Rainbow Dash hasn't been going to her house"): most
## afternoons a sky-home pony flies up to it (or is simply there, unwatched), naps on the cloud
## for a couple of minutes, then comes back down to town.
var _visits: Dictionary = {}
func _sky_visits(hours: float) -> void:
	for id: String in SKY_HOMES:
		if not population.live.has(id) or _bed_requests.has(id): continue
		var actor: Node3D = population.live[id].get("actor")
		if not is_instance_valid(actor) or not actor.is_inside_tree(): continue
		var night_entry: Dictionary = _state.get(id, {})
		if not night_entry.is_empty() and night_entry.phase not in ["", "done"]: continue
		var day := int(clock.day)
		var visit: Dictionary = _visits.get(id, {})
		if visit.get("day", -1) != day:
			var roll := float(absi(hash(id + "visit" + str(day))) % 1000) / 1000.0
			visit = {"day": day, "go": roll < .75, "at": 13.0 + roll * 3.5, "phase": ""}
			# A loaded save already holds today's visit (M-SAV-03, game_saves.gd sky_visits): she
			# does not go up a second time on the same day.
			var resumed: Variant = population.get("resumed_sky_visits")
			if resumed is Dictionary and int((resumed as Dictionary).get(id, -1)) == day:
				visit.phase = "done"; visit.go = false
			_visits[id] = visit
		var nav := _nav(actor)
		var spot := _sky_spot(id)
		var house := _sky_house(id)
		if nav == null or (not spot.is_finite() and house == null): continue
		var now := Time.get_ticks_msec() * .001
		# Up on her cloud in the day with nothing to do: a session loaded in the day starts her at
		# home, after the morning flight down already happened. She flies down to town after a
		# little while (dev 2026-09-25: "make rainbow dash fly down to ponyville every day").
		var home_idle: bool = visit.phase in ["", "done"] and hours > 7.5 and hours < 19.0 and not _busy(actor) \
			and _at_sky_home(id, actor.global_position) and (night_entry.is_empty() or night_entry.phase in ["", "done"]) \
			and not _outbound.has(id)
		if home_idle:
			if not visit.has("down_at"): visit.down_at = now + randf_range(20.0, 90.0)
			elif now > float(visit.down_at):
				visit.erase("down_at")
				_come_down(id, {"phase": "asleep"}, actor)
			continue
		visit.erase("down_at")
		match visit.phase:
			"":
				if not visit.go or hours < float(visit.at) or hours > 18.5 or _busy(actor): continue
				nav.stay(); nav.command_owner = OWNER + id
				actor.request_posture("stand")
				if house != null:
					# Home through her own door, and a nap in her own bed upstairs.
					visit["shared_bed"] = house.bed_shared(id)
					visit.until = now + 180.0 + actor.global_position.distance_to(house.outside()) / 2.5
					if not _seen(actor): _tuck_in(id, visit, actor, house)
					else:
						visit.phase = "going"
						nav.go_to(house.bed_side(id), nav.Gait.WALK)
					continue
				visit.phase = "flying"; visit.until = now + 90.0
				if not _seen(actor) or not actor.request_flight(spot, 0.0, true):
					actor.reset_motion(Transform3D(actor.global_basis, spot + Vector3.UP * .05))
			"flying":
				var flying: bool = actor.get("flight") != null and actor.flight.active()
				if not flying and (actor.global_position.distance_to(spot) < 4.0 or now > float(visit.until)):
					if actor.global_position.distance_to(spot) >= 4.0: actor.reset_motion(Transform3D(actor.global_basis, spot + Vector3.UP * .05))
					actor.request_posture("lie_down")
					visit.phase = "napping"; visit.until = now + float(visit.get("nap", randf_range(90.0, 150.0)))
			"napping":
				if now > float(visit.until) or hours > 19.0:
					visit.phase = "done"
					var fake := {"phase": "asleep"}
					_come_down(id, fake, actor)
					if nav.command_owner == OWNER + id: nav.command_owner = ""
			"going", "climbing", "settling", "asleep":
				if house != null: _home_nap(id, visit, actor, house, hours, now)
				else:
					_release(visit, actor, false); visit.phase = "done"

## An afternoon nap at home in the Cloudominium: in through her door and up the stairs to her own
## bed (the bedtime climb), then out of it again; home_idle sends her back down to town after.
func _home_nap(id: String, visit: Dictionary, actor: Node3D, house: Node3D, hours: float, now: float) -> void:
	var nav := _nav(actor)
	var flying: bool = actor.get("flight") != null and actor.flight.active()
	if not flying and _busy(actor):
		# Picked up, or somepony else's command: the nap is off.
		if visit.has("climb_tween"):
			var climbing: Tween = visit.climb_tween
			if climbing != null and climbing.is_valid(): climbing.kill()
			visit.erase("climb_tween")
		_release(visit, actor, false)
		visit.phase = "done"
		return
	match str(visit.phase):
		"going":
			if flying: return
			var side: Vector3 = house.bed_side(id)
			if not side.is_finite():
				_release(visit, actor, false); visit.phase = "done"; return
			if house.on_mattress(actor.global_position, id):
				_tuck_in(id, visit, actor, house); return
			var here := actor.global_position
			var rest_at: Vector3 = house.bed_rest(id).origin
			var near_side := Vector2(here.x - side.x, here.z - side.z).length() < 1.3
			var near_bed := Vector2(here.x - rest_at.x, here.z - rest_at.z).length() < 1.8
			if absf(here.y - side.y) < .8 and (near_side or near_bed): _climb(id, visit, actor, house)
			elif not _seen(actor): _tuck_in(id, visit, actor, house)
			elif now > float(visit.until) or nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]:
				_release(visit, actor, false); visit.phase = "done"
			elif not nav._has_target: nav.go_to(side, nav.Gait.WALK)
		"settling":
			_begin_sleep(visit, actor)
		"asleep":
			if not visit.has("wake_at"): visit.wake_at = now + float(visit.get("nap", randf_range(90.0, 150.0)))
			if now > float(visit.wake_at) or hours > 19.0: _wake(id, visit, actor)
			elif actor.posture_status().requested != "lie_down": _begin_sleep(visit, actor)

## On her way out of the Cloudominium (_come_down): released once she is off her cloud, has
## stopped trying, or runs out of time (then, unwatched, she is simply down in town).
func _outbound_step() -> void:
	var now := Time.get_ticks_msec() * .001
	for id: String in _outbound.keys():
		var live: Dictionary = population.live.get(id, {})
		var actor: Node3D = live.get("actor")
		var nav := _nav(actor) if is_instance_valid(actor) else null
		# Bedtime or an afternoon nap took her over: those own her now.
		var night_entry: Dictionary = _state.get(id, {})
		var napping: bool = str(_visits.get(id, {}).get("phase", "")) in ["going", "climbing", "settling", "asleep"]
		if nav == null or not str(nav.command_owner).begins_with(OWNER) or napping \
				or (not night_entry.is_empty() and night_entry.phase not in ["", "done"]):
			_outbound.erase(id); continue
		if actor.get("flight") != null and actor.flight.active(): continue
		var home := _at_sky_home(id, actor.global_position)
		if home and nav._has_target and now < float(_outbound[id]): continue
		_outbound.erase(id)
		if home and not _seen(actor):
			var town: Vector3 = _ground(population.home_position(id, true) if population.has_method("home_position") else Vector3.INF)
			if town.is_finite(): actor.reset_motion(Transform3D(actor.global_basis, town + Vector3.UP * .05))
		_release({}, actor, false)

## An AI [go_to_bed] (world/ai/pony_action_executor.gd; thread report 2026-11-03: "lay down in your
## bed" got "Fine, five minutes" and she never moved). She walks to the bed, climbs in (the bedtime
## climb) and lies there: awake by day, asleep in her night. She gets up on [wake_up], when picked up
## or given another command, by day after BED_REQUEST_SECONDS, and in the morning after a night
## there. `bed` is the bed key in `house`: her id for her own bed, "" for the house's first bed.
const BED_REQUEST_SECONDS := 600.0
var _bed_requests := {}   # id -> {house, bed, phase, until, retries, sleep, shared_bed, wake_at, climb_tween}

func send_to_bed(id: String, house: Node3D, bed: String) -> bool:
	if population == null or not population.live.has(id) or not is_instance_valid(house) or not house.has_method("bed_side"): return false
	var actor: Node3D = population.live[id].get("actor")
	var nav := _nav(actor) if is_instance_valid(actor) else null
	if nav == null or house.ensure_bed(bed) == null: return false
	var side: Vector3 = house.bed_side(bed)
	if not side.is_finite(): return false
	# M-AI-19 (thread 43686931: "she doesn't realise I'm already in bed"): Anon lies in that very bed.
	# Getting in is joining him (the bed's cuddle rest, shared_bed.gd accept), never climbing into a
	# lane he lies in. If she cannot join him there (unwilling, too far, no room), the request fails.
	var rest := _player_rest_on(house.ensure_bed(bed))
	if rest != null:
		var before := str(nav.command_owner)
		nav.stay(); nav.command_owner = ""
		if rest.has_method("accept") and bool(rest.call("accept", actor)):
			print("[night] %s joins Anon in bed (%s)" % [id, "own bed" if bed == id else "bed in " + str(house.name)])
			return true
		nav.command_owner = before
		return false
	var now := Time.get_ticks_msec() * .001
	var times := _bedtime(id, _night_key())
	var request := {"house": house, "bed": bed, "phase": "going", "retries": 0, "until": now + 90.0 + actor.global_position.distance_to(side) / 1.2,
		"sleep": _is_night({"bed_time": times.x, "wake_time": times.y}), "shared_bed": not bed.is_empty() and house.bed_shared(bed)}
	_bed_requests[id] = request
	nav.stay(); nav.command_owner = OWNER + id
	actor.request_posture("stand")
	if house.on_mattress(actor.global_position, bed) or not _seen(actor): _tuck_in(bed, request, actor, house)
	else: nav.go_to(side, nav.Gait.WALK)
	print("[night] %s going to bed (%s)" % [id, "own bed" if bed == id else "bed in " + str(house.name)])
	return true

## True while Anon lies in her bed and this tick is handled: she joined him, walks over, or waits
## beside the bed (an offer every few seconds) instead of climbing in on top of him.
func _anon_in_bed(id: String, entry: Dictionary, actor: Node3D, house: Node3D, bed_key: String) -> bool:
	var rest := _player_rest_on(house.ensure_bed(bed_key))
	if rest == null: return false
	var nav := _nav(actor)
	var now := Time.get_ticks_msec() * .001
	var side: Vector3 = house.bed_side(bed_key)
	var away := Vector2(actor.global_position.x - side.x, actor.global_position.z - side.z).length()
	# The bed's cuddle accepts only from nearby (shared_bed.gd eligible, 8 m): no stop-and-ask on the way.
	if away < 8.0 and now >= float(entry.get("join_try", 0.0)):
		entry["join_try"] = now + 5.0
		var before := str(nav.command_owner)
		nav.stay(); nav.command_owner = ""
		if rest.has_method("accept") and bool(rest.call("accept", actor)):
			entry.phase = ""
			print("[night] %s joins Anon in her bed" % id)
			return true
		nav.command_owner = before if not before.is_empty() else OWNER + id
	if away > 3.0:
		# She walks over. Never tucked in here while he lies in this bed (unwatched, or after failed
		# walks, bedtime puts her straight on the mattress: on top of him); a walk that fails waits.
		var stuck: bool = nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]
		if entry.phase == "" or not nav.command_owner.begins_with(OWNER) or (not nav._has_target and not stuck):
			nav.stay(); nav.command_owner = OWNER + id; nav.go_to(side, nav.Gait.WALK)
			entry.phase = "going"; entry.until = now + 300.0
		return true
	nav.stay(); nav.command_owner = OWNER + id
	entry.phase = ""
	return true

## The bed's cuddle rest (shared_bed.gd, installed on first use) while Anon lies on it; else null.
func _player_rest_on(bed_node: Node3D) -> Node:
	if bed_node == null or not bed_node.has_meta("bed_rest"): return null
	var rest: Variant = bed_node.get_meta("bed_rest")
	if not is_instance_valid(rest): return null
	var seats: Variant = (rest as Object).get("seats")
	if not seats is Array or (seats as Array).is_empty() or not is_instance_valid((seats as Array)[0]): return null
	var seat: Node = (seats as Array)[0]
	var who: Variant = seat.get_meta("occupant") if seat.has_meta("occupant") else null
	if not is_instance_valid(who) or not bool((who as Node).get_meta("couch_sleeping", false)): return null
	return rest as Node

func _bed_request_step(night: int) -> void:
	var now := Time.get_ticks_msec() * .001
	for id: String in _bed_requests.keys():
		var request: Dictionary = _bed_requests[id]
		var body: Variant = population.live.get(id, {}).get("actor")
		var house_ref: Variant = request.get("house")
		if not is_instance_valid(body) or not (body as Node3D).is_inside_tree() or not is_instance_valid(house_ref):
			if is_instance_valid(body): _release(request, body, false)
			_bed_requests.erase(id); continue
		var actor: Node3D = body
		var house: Node3D = house_ref
		var bed := str(request.bed)
		var nav := _nav(actor)
		var flying: bool = actor.get("flight") != null and actor.flight.active()
		if nav == null or (not flying and _busy(actor)):
			# Picked up, or another command (hers or the player's): she is up again.
			if request.has("climb_tween"):
				var climbing: Tween = request.climb_tween
				if climbing != null and climbing.is_valid(): climbing.kill()
				request.erase("climb_tween")
			_release(request, actor, false)
			_bed_requests.erase(id); continue
		var times := _bedtime(id, night)
		var night_now := _is_night({"bed_time": times.x, "wake_time": times.y})
		match str(request.phase):
			"going":
				if flying: continue
				var side: Vector3 = house.bed_side(bed)
				if not side.is_finite():
					_release(request, actor, false); _bed_requests.erase(id); continue
				var here := actor.global_position
				if house.on_mattress(here, bed): _tuck_in(bed, request, actor, house); continue
				var rest_at: Vector3 = house.bed_rest(bed).origin
				var to_side := Vector2(here.x - side.x, here.z - side.z).length()
				var to_bed := Vector2(here.x - rest_at.x, here.z - rest_at.z).length()
				var level := absf(here.y - side.y) < .8
				var stopped: bool = not nav._has_target or nav.state in [nav.State.ARRIVED, nav.State.UNREACHABLE, nav.State.BLOCKED, nav.State.IDLE]
				if level and (to_side < 1.3 or to_bed < 1.8 or (stopped and (to_side < 2.6 or to_bed < 3.0))):
					_climb(bed, request, actor, house)
				elif not _seen(actor): _tuck_in(bed, request, actor, house)
				elif nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED] or now > float(request.until):
					request.retries = int(request.retries) + 1
					print("[night] %s cannot reach the bed she was asked to (navigator state %d, try %d)" % [id, int(nav.state), int(request.retries)])
					# Same as bedtime (bug board #19): in that house and level with it, she hops in from here.
					if int(request.retries) >= 2 and level and house.contains(here): _climb(bed, request, actor, house)
					elif int(request.retries) >= 3:
						_release(request, actor, false); _bed_requests.erase(id)
					else:
						nav.go_to(side, nav.Gait.WALK); request.until = now + 60.0
				elif not nav._has_target: nav.go_to(side, nav.Gait.WALK)
			"settling":
				_begin_sleep(request, actor)
			"asleep":
				if not request.has("wake_at"): request.wake_at = now + BED_REQUEST_SECONDS
				# Night fell while she lay there: she sleeps on; morning wakes her.
				if night_now != bool(request.sleep):
					request.sleep = night_now
					actor.sleeping = night_now
				if not night_now and (now > float(request.wake_at) or bool(request.get("slept", false))):
					_bed_requests.erase(id)
					_wake(id, request, actor)
				elif actor.posture_status().requested != "lie_down": _begin_sleep(request, actor)
				if night_now: request.slept = true

## An AI "go_home" (world/ai/pony_action_executor.gd): fly up to her cloud home now and rest there
## a few minutes, then come back down like after an afternoon visit. False when she cannot.
func send_home(id: String) -> bool:
	if not SKY_HOMES.has(id) or not population.live.has(id): return false
	var actor: Node3D = population.live[id].get("actor")
	var nav := _nav(actor) if is_instance_valid(actor) else null
	var spot := _sky_spot(id)
	if nav == null or not spot.is_finite(): return false
	var now := Time.get_ticks_msec() * .001
	nav.stay(); nav.command_owner = OWNER + id
	actor.request_posture("stand")
	_visits[id] = {"day": int(clock.day), "go": true, "at": 0.0, "phase": "flying", "until": now + 90.0,
		"nap": randf_range(180.0, 360.0)}
	if not _seen(actor) or not actor.request_flight(spot, 0.0, true):
		actor.reset_motion(Transform3D(actor.global_basis, spot + Vector3.UP * .05))
	return true

## Unloaded sky sleepers: in the day, move their saved/simulated position from the cloud back to
## town, or they never come back in range to be spawned again.
func _bring_down_unloaded() -> void:
	if not is_instance_valid(population): return
	for id: String in SKY_HOMES:
		if "live" in population and population.live.has(id): continue
		# A loaded save had her up there with the player: she comes back right there.
		if population.has_method("resuming") and population.resuming(id): continue
		if not _sky_spot(id).is_finite() and _sky_house(id) == null: continue
		var town: Vector3 = _ground(population.home_position(id, true) if population.has_method("home_position") else Vector3.INF)
		if not town.is_finite(): continue
		var life: Node = population.get("life")
		if is_instance_valid(life) and "core" in life and life.core.state.get("residents", {}).has(id):
			var resident: Dictionary = life.core.state.residents[id]
			var at := Vector3(resident.position[0], resident.position[1], resident.position[2])
			if _at_sky_home(id, at) and resident.activity.is_empty():
				resident.position = [town.x, town.y, town.z]
		if "saved" in population and population.saved.has(id) and _at_sky_home(id, population.saved[id].position as Vector3):
			population.saved[id].position = town

## A resident's home spot can be a flat XZ with y = 0 (Dash floated 19 m over town): put it
## on whatever is actually underneath, else the terrain height.
func _ground(p: Vector3) -> Vector3:
	if not p.is_finite() or not is_inside_tree(): return p
	var hit := get_viewport().get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 150.0, p - Vector3.UP * 150.0, 1))
	if not hit.is_empty(): return hit.position
	if WorldTerrain.instance != null:
		var h: float = WorldTerrain.instance.height_at(p)
		if is_finite(h): return Vector3(p.x, h, p.z)
	return p

func _release(entry: Dictionary, actor: Node3D, morning: bool) -> void:
	actor.sleeping = false
	actor.motion_paused = false
	var nav := _nav(actor)
	if nav != null and nav.command_owner.begins_with(OWNER):
		nav.stay()
		nav.command_owner = ""
		# Out of the living world the ordinary wander routine takes her again.
		if not actor.has_meta("living_world"): nav.wander_enabled = true
	if morning: entry.phase = "done"

## Asleep right now (for awareness and chatter).
func is_asleep(id: String) -> bool:
	return str(_state.get(id, {}).get("phase", "")) == "asleep"

## A rescue must cancel a bed-climb tween before moving the body elsewhere.
func release_for_recovery(id: String, actor: Node3D) -> void:
	var entry: Dictionary = _state.get(id,{})
	if entry.has("climb_tween"):
		var tween: Tween = entry.climb_tween
		if tween != null and tween.is_valid(): tween.kill()
	_release(entry,actor,false)
	_state.erase(id)
