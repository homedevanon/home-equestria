extends Node
## Bedtime. Residents go home, climb into bed and get up again in the morning.
## Family households share a regular bedtime; other adults can be night owls.
## Those who can't get home (no house, no bed, no route) curl up where they are.
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
	var h := float(clock.hours)
	var bed := float(entry.bed_time); var wake := float(entry.wake_time)
	if bed > wake: return h >= bed or h < wake   # evening to morning
	return h >= bed and h < wake                  # after midnight to the afternoon

func _physics_process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0 or population == null or clock == null: return
	_timer = CHECK_SECONDS
	_house_count = get_tree().get_node_count_in_group(&"house_interiors")
	var night := _night_key()
	var hours: float = float(clock.hours)
	if hours > 7.5 and hours < 20.0: _bring_down_unloaded()
	_sky_visits(hours)
	if not _bed_requests.is_empty(): _bed_request_step(night)
	if not _outbound.is_empty(): _outbound_step()
	_essence_nights(night)
	for id: String in population.live.keys():
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

## Unloaded residents keep their nights (dev 2026-09-26: the model unloads, the essence lives
## on; world/life/essence.gd): at her bedtime her essence leaves any outing, heads home (a
## pegasus with a sky home flies up to it) and sleeps there until her wake-up time. `asleep` on
## her living-world record keeps the day plan and the outings off her meanwhile. A pony who
## streams in at night is tucked into bed by the loop above while nopony watches.
func _essence_nights(night: int) -> void:
	var core: RefCounted = ESSENCE.core(population)
	if core == null: return
	for id: String in core.state.residents:
		var resident: Dictionary = core.state.residents[id]
		var times := _bedtime(id, night)
		var sleeping := _is_night({"bed_time": times.x, "wake_time": times.y})
		if not sleeping:
			if resident.get("asleep", false): resident.erase("asleep")
			continue
		if not ESSENCE.unloaded(population, id): continue
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
		if not home.is_finite(): continue   # nowhere known: she curls up where she is
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
	if entry.phase in ["", "going"] and _talking(id):
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
	entry["shared_bed"] = house != null and house.bed_shared(id)
	var bed_ok: bool = house != null and house.has_method("ensure_bed") and house.ensure_bed(id) != null
	# A save/streamed actor can already be on her mattress. Sending her to the floor-side
	# marker makes her try to walk off the bed indefinitely (its height is outside the
	# approach's arrival tolerance). The same applies if she steps onto it on the way in.
	if bed_ok and entry.phase in ["", "going"] and house.on_mattress(actor.global_position, id):
		_nav(actor).command_owner = OWNER + id
		_tuck_in(id, entry, actor, house)
		return
	match entry.phase:
		"":
			var nav := _nav(actor)
			nav.stay(); nav.command_owner = OWNER + id
			if not bed_ok:
				if house != null: return
				_sleep_here(entry, actor); return
			if not _seen(actor) and actor.global_position.distance_to(house.bed_side(id)) > 3.0:
				# Nobody is watching: skip the walk, she is already tucked in.
				_tuck_in(id, entry, actor, house); return
			nav.go_to(house.bed_side(id), nav.Gait.WALK)
			entry.phase = "going"; entry.until = Time.get_ticks_msec() * .001 + 300.0
		"going":
			var nav := _nav(actor)
			if not bed_ok:
				if house == null: _sleep_here(entry, actor)
				return
			if not nav.command_owner.begins_with(OWNER):
				nav.stay(); nav.command_owner = OWNER + id; nav.go_to(house.bed_side(id), nav.Gait.WALK)
			var side: Vector3 = house.bed_side(id)
			# dev 2026-09-25: "standing at their bed but cannot get in". The walk often ends a little
			# short of the exact side marker (a bed against a wall, the grid's nearest cell), and the
			# old 0.7 m target left her standing there re-requesting the same walk forever. Climb in
			# from anywhere reasonably near the bed, and whenever the walk has stopped close to it.
			var rest_at: Vector3 = house.bed_rest(id).origin
			var here := actor.global_position
			var to_side := Vector2(here.x - side.x, here.z - side.z).length()
			var to_bed := Vector2(here.x - rest_at.x, here.z - rest_at.z).length()
			var level := absf(here.y - side.y) < .8
			var stopped: bool = not nav._has_target or nav.state in [nav.State.ARRIVED, nav.State.UNREACHABLE, nav.State.BLOCKED, nav.State.IDLE]
			var stuck_walk: bool = nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]
			if level and (to_side < 1.3 or to_bed < 1.8 or (stopped and (to_side < 2.6 or to_bed < 3.0))):
				_climb(id, entry, actor, house)
			elif stuck_walk and Time.get_ticks_msec() * .001 < float(entry.get("retry_at", 0.0)):
				pass
			elif stuck_walk or Time.get_ticks_msec() * .001 > float(entry.until):
				# No sleeping on the ground outside while she has a bed: keep trying, and the
				# moment nobody is near to watch, she is simply home in bed.
				entry.retries += 1
				entry["retry_at"] = Time.get_ticks_msec() * .001 + RETRY_SECONDS
				print("[night] %s cannot reach her bed (navigator state %d, try %d): %s" % [id, int(nav.state), entry.retries, nav.reason])
				if not _seen(actor): _tuck_in(id, entry, actor, house)
				# Watched in her own house (player bug board #19: Fluttershy sat on the floor for
				# hours beside an unreachable bed): after two failed walks she hops in from here.
				elif entry.retries >= 2 and level and house.contains(here): _climb(id, entry, actor, house)
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
