extends Node
## Resident streaming: one asynchronous spawn at a time. Only the body streams: an unloaded
## resident lives on as her living-world record (world/life/essence.gd), and spawns where it is.
const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
const CONFIG = preload("res://world/population/pony_population_config.gd")
const DISTRIBUTION = preload("res://world/population/population_distribution.gd")
const ACTIVATE_DISTANCE := 240.0
const RELEASE_DISTANCE := 360.0
const BACKGROUND_SCRIPT := "res://world/characters/background/background_pony.gd"
## Spawned first, in this order, before everypony else in range (dev 2026-09-24: Rainbow Dash
## lives in the sky, has no house in town and used to come out last or never).
const FIRST := ["rainbow_dash", "twilight_sparkle", "fluttershy", "pinkie_pie", "applejack", "rarity"]
const NIGHT_REST := preload("res://world/life/night_rest.gd")
## A sky home (Rainbow Dash's Cloudominium) sits ~330 m east of the town centre: she comes out
## and stays out from farther than the ground residents.
const SKY_ACTIVATE_DISTANCE := 700.0
const SKY_RELEASE_DISTANCE := 900.0
var _sky_started := {}   # sky-home residents already placed at home once this session
## Loading screen (game.gd _load_everything): every resident in range is spawned before the
## player gets control. Their scenes load serially; failed placements retry every second,
## up to STARTUP_TRIES times, instead of every 20 s.
const STARTUP_TRIES := 10
var _startup := false
var _startup_began := 0
var _startup_failures := {}
var _startup_scripts: Array[Script] = [] # Retain compiled bases while loader threads use them.
var _prefetch := {}   # scene path -> threaded load already requested
var _spawn_loading: Dictionary = {} # Requests owned by the current asynchronous spawn.
var _closing := false
signal _spawn_frame_ready
var config := CONFIG.new()
var config_path := CONFIG.LIVE_PATH
var live: Dictionary = {}
## Residents away on a visit (world/life/princess_visits.gd owns them meanwhile): never
## spawned or released here.
var visiting: Dictionary = {}
## Temporary Ponyville stays; original roster homes and house ownership never change.
var overnight_visitors: Node
## Streamed-out positions, plus rows a loaded save restored (game_saves.gd restore_residents).
## A row with "resume" was out in the world at save time: see resuming().
var saved: Dictionary = {}
## Today's day-plan progress from the loaded save (game_saves.gd), taken once by DayRunner.
var resumed_plans: Dictionary = {}
## Sky-home afternoon trips already taken on that day ({id: day}) from the loaded save
## (game_saves.gd), read by NightRest so a load does not roll the trip again.
var resumed_sky_visits: Dictionary = {}
var _resumes_settled := false
var retry_at: Dictionary = {}
var status: Dictionary = {}
var host: Node
var life: Node
var anchor: Node3D
var available := {}
var _timer := 0.0
var _reload_timer := 0.0
var _stamp := ""
var _clock := 0.0
var _generation := 0
var _spawning := ""
var _homes := {}
var _home_signature := 0
## Ponyville residents each own one of the town's houses (dev, 2026-09-22). Kept in homes.json
## beside the world's population config, so adding or removing a pony never moves anyone else.
const HOME_REGION := "ponyville"
var houses: Dictionary = {} # resident id -> HouseInterior.place_id()
var _houses_loaded := false
var _house_signature := 0

func _ready() -> void:
	add_to_group("pony_populations")

func _exit_tree() -> void:
	_closing = true
	# Unwind the worker while its locals (scene and rig dependencies) can still be released.
	_spawn_frame_ready.emit()
	# Collect scenes still requested for the loading screen (quit or reload mid-load).
	var pending: Dictionary = _prefetch.duplicate()
	pending.merge(_spawn_loading)
	for path: String in pending:
		var state := ResourceLoader.load_threaded_get_status(path)
		if state == ResourceLoader.THREAD_LOAD_IN_PROGRESS or state == ResourceLoader.THREAD_LOAD_LOADED:
			ResourceLoader.load_threaded_get(path)
	_prefetch.clear()
	_spawn_loading.clear()
	_spawning = ""

func _wake_spawn_frame() -> void:
	_spawn_frame_ready.emit()

## Unlike SceneTree.process_frame, this wait also finishes during world shutdown.
func _wait_spawn_frame() -> bool:
	if _closing or not is_inside_tree() or is_queued_for_deletion(): return false
	var tree: SceneTree = get_tree()
	tree.process_frame.connect(_wake_spawn_frame, CONNECT_ONE_SHOT)
	await _spawn_frame_ready
	if tree.process_frame.is_connected(_wake_spawn_frame): tree.process_frame.disconnect(_wake_spawn_frame)
	return not _closing and is_inside_tree() and not is_queued_for_deletion()

func _refresh_homes() -> void:
	var signature := hash(config.assignments)
	if signature == _home_signature and not _homes.is_empty(): return
	_home_signature = signature
	_homes.clear()
	var regions := {}
	for id in config.assignments:
		var region_id: String = config.assignments[id]
		if not regions.has(region_id): regions[region_id] = []
		regions[region_id].append(id)
	for region_id in regions:
		_homes.merge(DISTRIBUTION.plan(WorldLayout.region(region_id), regions[region_id]))

func setup(game: Node, camera: Node3D) -> void:
	host = game; anchor = camera; available = CONFIG.catalogue()
	if "world_context" in game and is_instance_valid(game.world_context):
		config_path = game.world_context.path.get_base_dir().path_join("population.json")
		if not FileAccess.file_exists(config_path):
			var initial := CONFIG.new()
			if initial.load_file(CONFIG.LIVE_PATH):
				initial.save_file(config_path)
	config.defaults(); reload_config()
	overnight_visitors = preload("res://world/life/overnight_visitors.gd").new()
	overnight_visitors.name = "OvernightVisitors"
	add_child(overnight_visitors); overnight_visitors.setup(self)

func reload_config() -> bool:
	var candidate := CONFIG.new()
	if not candidate.load_file(config_path):
		status["settings"] = candidate.error; return false
	config = candidate; _generation += 1; retry_at.clear()
	_stamp = _signature(); status.erase("settings")
	if is_instance_valid(host) and "social" in host and is_instance_valid(host.social): host.social.enabled = config.social_groups
	return true

func _signature() -> String:
	return FileAccess.get_sha256(config_path) if FileAccess.file_exists(config_path) else "default"

func _physics_process(delta: float) -> void:
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_physics_step(delta)
	if started > 0: CPU_PROFILE.record("population", started)

func _physics_step(delta: float) -> void:
	_clock += delta; _timer -= delta; _reload_timer -= delta
	if not is_instance_valid(host) or not is_instance_valid(anchor): return
	if _reload_timer <= 0.0:
		_reload_timer = 3.0
		if _signature() != _stamp: reload_config()
	if _timer > 0.0: return
	_timer = 1.0
	reconcile()

## Current town for simulation/streaming, distinct from the permanent roster home.
func residence_region(id: String) -> String:
	return HOME_REGION if is_overnight_visitor(id) else str(config.assignments.get(id, ""))

func is_overnight_visitor(id: String) -> bool:
	return is_instance_valid(overnight_visitors) and overnight_visitors.active(id)

## The resident's assigned home, including dedicated homes outside Ponyville.
func home_house(id: String) -> Node3D:
	if is_overnight_visitor(id): return null
	if not config.assignments.has(id) or not is_inside_tree(): return null
	_assign_houses()
	var place: String = houses.get(id, "")
	var known: Variant = _house_by_place.get(place) if ASSIGN_ONCE_PER_FRAME else null
	if is_instance_valid(known) and (known as Node3D).is_inside_tree() and (known as Node3D).call(&"place_id") == place: return known as Node3D
	for house: Node3D in get_tree().get_nodes_in_group("house_interiors"):
		if house.place_id() == place:
			_house_by_place[place] = house
			return house
	return null

## Residents who live in a house, by its place id.
func residents_of(place_id: String) -> Array:
	var result := []
	for id in houses:
		if houses[id] == place_id and config.assignments.has(id): result.append(id)
	result.sort()
	return result

## 0.1.0 perf pass: home_house() runs _assign_houses for every caller (about 15 per beat at night),
## and each pass reconfigured every house. Its inputs only change between frames (houses is
## written here alone; the town group changes on load/stream), so one pass per frame serves all
## callers of that frame. Rollback: ASSIGN_ONCE_PER_FRAME = false.
const ASSIGN_ONCE_PER_FRAME := true
var _assign_frame := -1
var _house_by_place := {}

## A house reservation changed this frame (arrival_story.gd grant_home: the player's new home):
## the once-per-frame pass already ran, so assign again now. Residents who lived there move out
## in the same frame and the map, beds and place directory see one consistent town.
func reassign_houses() -> void:
	_house_signature = 0
	_assign_frame = -1
	_assign_houses()

func _assign_houses() -> void:
	if ASSIGN_ONCE_PER_FRAME and _houses_loaded:
		var frame := Engine.get_process_frames()
		if frame == _assign_frame: return
		_assign_frame = frame
	var town: Array = get_tree().get_nodes_in_group("house_interiors")
	var path := config_path.get_base_dir().path_join("homes.json")
	if not _houses_loaded:
		_houses_loaded = true
		var stored: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
		if stored is Dictionary: houses = stored; _houses_version += 1
	if town.is_empty(): return
	# Dedicated homes choose reservation only after this world's saved addresses load.
	if not CONFIGURE_ON_CHANGE or not _configured_for(town):
		_configure_always.clear()
		for house: Node3D in town:
			if CONFIGURE_ON_CHANGE and not house.tree_exiting.is_connected(_on_house_exiting):
				house.tree_exiting.connect(_on_house_exiting, CONNECT_ONE_SHOT)
			if house.has_method("configure_owner"):
				house.configure_owner(houses)
				if house.has_method(&"_adopt_legacy_move_in"): _configure_always.append(house)
	else:
		for house: Node3D in _configure_always:
			if is_instance_valid(house): house.configure_owner(houses)
	var ids: Array = config.residents(HOME_REGION)
	# Authored homes outside Ponyville (Zecora's hut) participate in the same
	# bed/house assignment service without moving their residents into town.
	for house:Node3D in town:
		var owner:String=str(house.get_meta("reserved_for",""))
		if owner!="" and config.assignments.has(owner) and owner not in ids:ids.append(owner)
	var signature := hash([ids, town.size()])
	if signature == _house_signature: return
	_house_signature = signature
	var occupants := {}
	var reserved := {}   # place id -> the one resident it belongs to (Trixie's wagon)
	for house: Node3D in town:
		if house.has_meta("reserved_for"): reserved[house.place_id()] = str(house.get_meta("reserved_for"))
		else: occupants[house.place_id()] = 0
	var changed := false
	for place in reserved:
		var owner: String = reserved[place]
		if owner in ids and houses.get(owner, "") != place: houses[owner] = place; changed = true
	for id in houses.keys():
		if reserved.has(houses[id]) and reserved[houses[id]] == id: continue
		# Sky homes (Rainbow Dash's Cloudominium) take nopony's house on the ground; her walk-in
		# Cloudominium (world/buildings/cloudominium/home.gd) is reserved for her just above.
		if preload("res://world/life/night_rest.gd").SKY_HOMES.has(id): houses.erase(id); changed = true; continue
		if not id in ids or not occupants.has(houses[id]): houses.erase(id); changed = true
		else: occupants[houses[id]] += 1
	var places: Array = occupants.keys(); places.sort()
	if places.is_empty(): return
	ids.sort()
	for id in ids:
		if houses.has(id) or preload("res://world/life/night_rest.gd").SKY_HOMES.has(id): continue
		# Fill the emptiest house first; place-id order keeps it deterministic.
		var best: String = places[0]
		for place in places:
			if occupants[place] < occupants[best]: best = place
		houses[id] = best; occupants[best] += 1; changed = true
	# Keep the first family member's existing address; bring family into that house.
	var freed := []
	for family: Array in CONFIG.HOUSEHOLDS.FAMILIES:
		var home := ""
		for id: String in family:
			if id in ids and houses.has(id): home = houses[id]; break
		if home.is_empty(): continue
		for id: String in family:
			if id in ids and houses.get(id, "") != home:
				if houses.has(id): freed.append(houses[id])
				houses[id] = home; changed = true
	# Joining families frees some of the earlier individual houses. Use those for
	# fillies with no assigned guardian, rather than leaving them with a random family.
	for place in occupants: occupants[place] = 0
	for id in ids:
		if occupants.has(houses.get(id, "")): occupants[houses[id]] += 1
	# A pony who is not family but was filled into a family's house moves to a free one
	# (dev 2026-10-25: Aloe shared Vinyl's house; once Octavia moved in with Vinyl, Aloe takes
	# Octavia's old house).
	var family_homes := {}
	for family: Array in CONFIG.HOUSEHOLDS.FAMILIES:
		for id: String in family:
			if id in ids and houses.has(id): family_homes[houses[id]] = true
	for id in ids:
		if CONFIG.HOUSEHOLDS.members(id).size() > 1 or not family_homes.has(houses.get(id, "")): continue
		for place: String in freed + places:
			if int(occupants.get(place, -1)) != 0: continue
			if occupants.has(houses[id]): occupants[houses[id]] -= 1
			houses[id] = place; occupants[place] += 1; changed = true
			break
	for id: String in CONFIG.FILLIES:
		if not id in ids or CONFIG.HOUSEHOLDS.members(id).size() > 1 or not houses.has(id): continue
		var old: String = houses[id]
		if int(occupants.get(old, 0)) <= 1: continue
		for place: String in places:
			if occupants[place] != 0: continue
			houses[id] = place; occupants[place] += 1; occupants[old] -= 1; changed = true
			break
	for house: Node3D in town:
		if house.has_method("set_sleepers"): house.set_sleepers(residents_of(house.place_id()))
	if changed:
		_houses_version += 1
		preload("res://world/save_file.gd").write(path, houses)

## 0.1.0 perf pass: configure_owner() sets each dedicated home's reserved_for from the saved
## addresses alone (Golden Oak, the cottage, the tower, the boutique), so it is re-run only when
## those inputs change: the houses dictionary (changed here, replaced, or resized) or the set of
## houses in town (its size, or any configured house leaving the tree, which also covers one
## leaving while another arrives). Homes whose configure_owner also does timed work (the
## Cloudominium's legacy move-in check, itself throttled to 5 s) are still called every pass.
## Same metadata, same timing. Rollback: CONFIGURE_ON_CHANGE = false reconfigures every house on
## every pass.
const CONFIGURE_ON_CHANGE := true
var _houses_version := 0
var _configured_stamp: Array = []
var _configure_always: Array[Node3D] = []
var _town_left := false

func _on_house_exiting() -> void:
	_town_left = true

func _configured_for(town: Array) -> bool:
	var same := not _town_left and _configured_stamp.size() == 5 and is_same(_configured_stamp[0], houses) \
		and int(_configured_stamp[1]) == houses.size() and int(_configured_stamp[2]) == _houses_version \
		and int(_configured_stamp[3]) == _house_signature and int(_configured_stamp[4]) == town.size()
	if not same:
		_configured_stamp = [houses, houses.size(), _houses_version, _house_signature, town.size()]
		_town_left = false
	return same

## `ground`: for a sky-home pony (Rainbow Dash) her place down in town instead of her cloud:
## where she spends the day and where the morning flight lands (dev 2026-09-25: she never left
## the Cloudominium because "coming down" flew her to home_position, which was the cloud).
func home_position(id: String, ground := false) -> Vector3:
	if is_overnight_visitor(id): return overnight_visitors.lodging(id)
	var region_id: String = config.assignments.get(id, "")
	if region_id == "": return Vector3.INF
	# Rainbow Dash lives in the Cloudominium: at its front door on the cloud, or an open spot on
	# its cloud floor (NightRest finds them once the building is loaded; until then she waits
	# instead of starting on the ground).
	if not ground and NIGHT_REST.SKY_HOMES.has(id) and region_id == HOME_REGION:
		var rest: Node = host.get_node_or_null("NightRest") if is_instance_valid(host) else null
		return rest.sky_spawn(id) if rest != null else Vector3.INF
	# A Ponyville resident starts at her own front door; the planner sends her home to rest.
	# A sky-home pony's town place is never her door up on the cloud.
	var house: Node3D = null if NIGHT_REST.SKY_HOMES.has(id) else home_house(id)
	if house != null: return house.outside()
	_refresh_homes()
	# Authored map spawns/hot spots override automatic neighbourhoods when their
	# zone is available. Saved live positions still win in candidate_position().
	if is_instance_valid(host) and host.has_method("_resident_authored_home"):
		var ids := _sorted_residents(region_id)
		var authored: Vector3 = host._resident_authored_home(id, region_id, ids.find(id))
		if authored.is_finite(): return authored
	return _homes.get(id, Vector3.INF)

## 0.1.0 perf pass: home_position() listed and sorted every region's residents per call (~29 us of
## a 29 us lookup for ponies without a house). The sorted list is kept per region while
## config.assignments hashes the same (_refresh_homes, run just before, keeps _home_signature
## equal to that hash). Read only by callers. Rollback: REGION_IDS_CACHE = false.
const REGION_IDS_CACHE := true
var _region_ids := {}
var _region_ids_for := 0
var _region_ids_config: RefCounted

func _sorted_residents(region_id: String) -> Array:
	if not REGION_IDS_CACHE:
		var fresh := config.residents(region_id); fresh.sort()
		return fresh
	if _region_ids_for != _home_signature or _region_ids_config != config:
		_region_ids = {}; _region_ids_for = _home_signature; _region_ids_config = config
	var ids: Variant = _region_ids.get(region_id)
	if ids == null:
		var listed := config.residents(region_id); listed.sort()
		_region_ids[region_id] = listed
		return listed
	return ids as Array

func candidate_position(id: String) -> Vector3:
	if "balloon" in host and is_instance_valid(host.balloon) and host.balloon.owns(id):return host.balloon.position_for(id)
	if "railway" in host and is_instance_valid(host.railway) and host.railway.owns(id): return host.railway.position_for(id)
	# Out in the world when the loaded game was saved: right where she was (tester: Dash saved
	# beside the player came back at her cloud home).
	if resuming(id): return saved[id].position
	# First appearance of the session: at home in the Cloudominium, wherever the life
	# simulation last had her (older saves have her on a placeholder spot in town).
	if NIGHT_REST.SKY_HOMES.has(id) and not _sky_started.has(id): return home_position(id)
	if is_instance_valid(life):
		var current: Vector3 = life.position_for(id)
		if current.is_finite(): return current
	if saved.has(id) and saved[id].get("region", "") == residence_region(id):
		return saved[id].position
	return home_position(id)

## Her body was out when the loaded checkpoint was saved (game_saves.gd restore_residents): she
## spawns at that spot and picks up what she was doing (_resume). Her essence waits for her body
## meanwhile (essence.gd unloaded). Ends when she spawns, fails to after loading, or is out of
## range once play starts (_settle_resumes). Older saves never set it.
func resuming(id: String) -> bool:
	return saved.has(id) and saved[id].has("resume") and saved[id].get("region", "") == residence_region(id)

## The loading screen has finished and the player is in the world (not at the title view).
func _playing() -> bool:
	return _startup_began > 0 and not _startup and host.get("title_active") != true

func _settle_resumes() -> void:
	if _resumes_settled or not _playing(): return
	_resumes_settled = true
	for id: String in saved:
		if saved[id].has("resume") and not live.has(id) and (not resuming(id) or flat_distance(saved[id].position, anchor.global_position) >= activate_distance(id)):
			saved[id].erase("resume")

## Picks up a follow or a rest the player or her AI had asked for (game_saves.gd _resident_state),
## through her action executor as the AI's own request would. Other activities come back on their
## own: bedtime (NightRest), today's plan step (DayRunner, resumed_plans), outings (living world).
func _resume(id: String, actor: Node3D, resume: Dictionary) -> void:
	var director: Node = host.get("director")
	if not is_instance_valid(director) or director.get("actions") == null: return
	var found: Variant = director.actions.executors.get(id)
	if not is_instance_valid(found): return
	var executor: Node = found
	var turn := int(director.get("_turn_id"))
	if resume.get("follow") is Dictionary:
		var player: Variant = director.get("player_head")
		if not is_instance_valid(player): return
		var follow: Dictionary = resume.follow
		executor.submit([{"id": "resume_follow:" + id, "type": "follow", "target_id": "player",
			"formation": str(follow.get("formation", "right")), "distance_m": float(follow.get("distance_m", 1.5))}], {"player": player}, turn)
	elif str(resume.get("rest", "")) in ["sit", "lie_down", "seat"]:
		var kind := "sit_on_seat" if str(resume.rest) == "seat" else str(resume.rest)
		executor.submit([{"id": "resume_rest:" + id, "type": kind}], {}, turn)
	elif resume.get("move") is Dictionary:
		# A go_to, lead or approach still under way at save time (game_saves.gd _saved_move).
		var move: Dictionary = (resume.move as Dictionary).duplicate()
		var origin := bool(move.get("ai", false))
		move.erase("ai")
		move["id"] = "resume_move:" + id
		var targets := {}
		var player: Variant = director.get("player_head")
		if is_instance_valid(player): targets["player"] = player
		elif move.has("target_id"): return
		executor.submit([move], targets, turn, origin)

func activate_distance(id: String) -> float:
	return SKY_ACTIVATE_DISTANCE if NIGHT_REST.SKY_HOMES.has(id) else ACTIVATE_DISTANCE

func release_distance(id: String) -> float:
	return SKY_RELEASE_DISTANCE if NIGHT_REST.SKY_HOMES.has(id) else RELEASE_DISTANCE

func begin_startup() -> void:
	_startup = true
	_startup_began = Time.get_ticks_msec()
	_startup_failures.clear()
	_timer = 0.0
	var paths: Array[String] = []
	for id: String in startup_candidates():
		var path: String = available.get(id, "")
		if path != "" and not _prefetch.has(path) and not path in paths: paths.append(path)
	# Compile every script those scenes use here on the main thread first: GDScript loaded by
	# several loader threads at once fails ("Could not resolve class pony_locomotion.gd") and
	# every pony came out without her script (2026-09-24).
	for script_path: String in _scripts_of(paths):
		var script: Script = load(script_path) as Script
		if script != null and script not in _startup_scripts: _startup_scripts.append(script)
	# Packed scene imports share embedded meshes/materials. Let _spawn request one
	# scene at a time in both development and exports: resuming a populated town can
	# race body.glb material registrations when every resident is prefetched together.

## Every .gd a scene references, directly or through its .tres sub-resources (identity).
static func _scripts_of(scenes: Array[String]) -> Array[String]:
	var scripts: Array[String] = []
	var seen := {}
	var queue: Array[String] = scenes.duplicate()
	while not queue.is_empty():
		var file: String = queue.pop_back()
		if seen.has(file) or not ResourceLoader.exists(file): continue
		seen[file] = true
		# Exported scenes are binary/remapped: text regexes see no references.
		# Dependency metadata works with both source resources and packed exports.
		for dependency: String in ResourceLoader.get_dependencies(file):
			var fields: PackedStringArray = dependency.split("::")
			var ref: String = fields[fields.size()-1]
			if ref.ends_with(".gd") or ref.ends_with(".gdc"):
				if ref not in scripts: scripts.append(ref)
			elif ref.get_extension() in ["tscn","scn","tres","res"]: queue.append(ref)
	return scripts

func end_startup() -> void:
	_startup = false

## Residents the loading screen still waits for: in range, not out yet, not given up on.
## A sky home that has not loaded yet counts for its first 20 s.
func startup_candidates() -> Array[String]:
	var ids: Array[String] = []
	var cap := nearby_limit()
	for id: String in config.assignments:
		if live.has(id) or visiting.has(id) or int(_startup_failures.get(id, 0)) >= STARTUP_TRIES: continue
		var rider: bool = "railway" in host and is_instance_valid(host.railway) and host.railway.owns(id)
		if cap > 0 and live.size() >= cap and not rider: continue
		var pos := candidate_position(id)
		if not pos.is_finite():
			if NIGHT_REST.SKY_HOMES.has(id) and Time.get_ticks_msec() - _startup_began < 20000: ids.append(id)
			continue
		if flat_distance(pos, anchor.global_position) < activate_distance(id): ids.append(id)
	return ids

static func flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

func pinned(actor: Node3D) -> bool:
	if actor.get("flight") != null and actor.flight.active(): return true
	if actor.has_method("action_interruption_reason"):
		var interruption: String = actor.action_interruption_reason()
		# Streamed-away floor is not a player interaction and must not keep a
		# falling offscreen actor alive forever.
		if interruption != "" and interruption != "Waiting for safe ground support": return true
	var nav := actor.get_node_or_null("Navigator")
	# Reserved by a story encounter (crucial-moment presence): never streamed away mid-scene.
	if nav != null and str(nav.get("reserved_by")) != "" and nav.get("reserved_by") != null: return true
	if nav != null and nav.command_owner != "" and not str(nav.command_owner).begins_with("social:") and not str(nav.command_owner).begins_with("life:") and not str(nav.command_owner).begins_with("rail:"): return true
	return host.has_method("_population_busy") and host._population_busy(actor)

func reconcile() -> void:
	if is_instance_valid(overnight_visitors) and overnight_visitors.preparing: return
	if not _resumes_settled: _settle_resumes()
	for id: String in live.keys():
		var entry: Dictionary = live[id]
		var actor: Node3D = entry.actor
		if not is_instance_valid(actor): live.erase(id); continue
		var changed: bool = residence_region(id) != entry.region
		var distant := flat_distance(actor.global_position, anchor.global_position) > release_distance(id)
		var visible := anchor is Camera3D and (anchor as Camera3D).is_position_in_frustum(actor.global_position + Vector3.UP * .6)
		if anchor is Camera3D and "pivot" in actor:
			visible=not actor.get_meta("crowd_hidden",false)
		# Edits wait until she is out of sight, including while held or speaking.
		if ((distant and not visible) or (changed and not visible and flat_distance(actor.global_position, anchor.global_position) > 30.0)) and not pinned(actor):
			saved[id] = {"region": entry.region, "position": actor.global_position, "rotation": actor.rotation}
			host._despawn_resident(id, actor); live.erase(id)
	if _spawning != "": return
	var candidates: Array = []
	# Loop invariants, read once per reconcile instead of once per resident (W2 perf pass).
	var railway: Node = host.railway if "railway" in host and is_instance_valid(host.railway) else null
	var cap := nearby_limit()
	for id: String in config.assignments:
		if live.has(id) or visiting.has(id) or _clock < float(retry_at.get(id, 0.0)): continue
		var rider: bool = railway != null and railway.owns(id)
		if cap > 0 and live.size() >= cap and not rider: continue
		var pos := candidate_position(id)
		var distance := flat_distance(pos, anchor.global_position)
		if distance < activate_distance(id): candidates.append({"id": id, "distance": distance, "position": pos})
	candidates.sort_custom(func(a, b):
		var ra: int = FIRST.find(a.id); var rb: int = FIRST.find(b.id)
		if ra != rb: return ra >= 0 and (rb < 0 or ra < rb)
		return a.distance < b.distance
	)
	if not candidates.is_empty(): _spawn(candidates[0])

## No cap by default: every resident within ACTIVATE_DISTANCE comes out and PonyCrowd's
## distance tiers (HERO/NEAR/FAR mesh) keep her cheap (dev 2026-09-24: "make infinite nearby
## ponies allowed just LoD them"). Settings → Max nearby ponies can still set a cap; 0 means
## unlimited. Lowering it stops new spawns; ponies already out stay until they stream away.
## The roster's own nearby_limit is kept in the file for old saves but no longer caps.
func nearby_limit() -> int:
	var settings := get_node_or_null("/root/Settings")
	return int(settings.nearby_limit(config.nearby_limit)) if settings != null else 0

func _spawn(candidate: Dictionary) -> void:
	if _closing or not is_inside_tree() or is_queued_for_deletion(): return
	var id: String = candidate.id
	_spawning = id
	var generation := _generation
	var region_id: String = residence_region(id)
	var path: String = available[id]
	var loaded: PackedScene
	var err := OK if _prefetch.has(path) else ResourceLoader.load_threaded_request(path, "PackedScene")
	_prefetch.erase(path)
	if err == OK:
		_spawn_loading[path] = true
		var deadline := Time.get_ticks_msec() + 90000
		while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS and Time.get_ticks_msec() < deadline:
			if not await _wait_spawn_frame():
				_spawning = ""; return
		if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED:
			loaded = ResourceLoader.load_threaded_get(path)
			_spawn_loading.erase(path)
	if loaded == null:
		status[id] = "Asset loading failed"; retry_at[id] = _clock + 30.0; _spawning = ""; _timer = 0.0
		_startup_failures[id] = STARTUP_TRIES
		return
	# The rig's _ready load()s these on the main thread. Loaded here on worker threads and held
	# until she is added, they are already in the resource cache when it asks.
	var held: Array[Resource] = []
	for dependency in _rig_dependencies(loaded):
		# Body, filly variants and hair may share imported sub-resources.
		# Finish each background load before requesting the next one.
		if ResourceLoader.load_threaded_request(dependency) != OK: continue
		_spawn_loading[dependency] = true
		var wait_until := Time.get_ticks_msec() + 90000
		while ResourceLoader.load_threaded_get_status(dependency) == ResourceLoader.THREAD_LOAD_IN_PROGRESS and Time.get_ticks_msec() < wait_until:
			if not await _wait_spawn_frame():
				_spawning = ""; return
		if ResourceLoader.load_threaded_get_status(dependency) != ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			var resource := ResourceLoader.load_threaded_get(dependency)
			_spawn_loading.erase(dependency)
			if resource != null: held.append(resource)
	var from_save := resuming(id)
	candidate.position = candidate_position(id)
	if generation != _generation or flat_distance(candidate.position, anchor.global_position) >= activate_distance(id):
		_spawning = ""; _timer = 0.0; return
	var actor: Node3D = await host._spawn_resident(id, region_id, candidate.position, loaded, "", self)
	if _closing or not is_inside_tree() or is_queued_for_deletion(): return
	if is_instance_valid(actor):
		if generation != _generation or flat_distance(actor.global_position, anchor.global_position) >= activate_distance(id) + 20.0:
			host._despawn_resident(id, actor)
		else:
			live[id] = {"actor": actor, "region": region_id}
			_sky_started[id] = true
			status.erase(id)
			if saved.has(id) and saved[id].region == region_id: actor.rotation = saved[id].rotation
			if from_save: _step_off_prop(actor)
			if is_instance_valid(life) and not ("railway" in host and is_instance_valid(host.railway) and host.railway.owns(id)): life.attach(id, actor)
			if saved.has(id) and saved[id].has("resume"):
				var resume: Dictionary = saved[id].resume
				saved[id].erase("resume")
				_resume(id, actor, resume)
	else:
		status[id] = "Waiting for safe ground / loaded terrain"
		if _playing() and saved.has(id): saved[id].erase("resume")
		retry_at[id] = _clock + (1.0 if _startup else 20.0)
		if _startup: _startup_failures[id] = int(_startup_failures.get(id, 0)) + 1
		if not _startup or int(_startup_failures[id]) == STARTUP_TRIES:
			print("[population] could not place %s near %s yet (%s), retrying in 20 s" % [id, candidate.position, host.get("spawn_failure")])
	_spawning = ""
	# Next one straight away instead of waiting for the 1 s reconcile tick.
	_timer = 0.0

## A saved spot on top of a prop solid (W1-LIFE-BEDS: Octavia saved standing on flowerbed_22, an
## island with no route anywhere): onto the walkable ground right beside it, once, at spawn. The
## walk grid's escape_point only answers when her spot is not walkable, the ground is within a
## couple of cells and a short step down (< 0.4 m) reaches it; otherwise she stays where she was.
func _step_off_prop(actor: Node3D) -> void:
	if not actor.is_inside_tree() or actor.get("profile") == null or not actor.has_method("reset_motion"): return
	var service: Node = get_tree().get_first_node_in_group("pony_navigation")
	if service == null or not service.has_method("escape_point"): return
	var spot: Vector3 = service.escape_point(actor.global_position, actor.get("profile"))
	if not spot.is_finite() or spot.distance_to(actor.global_position) > 3.0: return
	print("[population] %s was saved on top of a prop; set down beside it at %s" % [actor.name, spot.round()])
	actor.reset_motion(Transform3D(actor.global_basis, spot))

## What the new rig's _ready loads synchronously: her hair scene, and for background mares
## the anchored tail meshes background_pony.gd reads from support/.
static func _rig_dependencies(scene: PackedScene) -> Array[String]:
	var paths: Array[String] = []
	var state := scene.get_state()
	if state.get_node_count() == 0: return paths
	var identity: Resource
	var rig_script: Script
	for i in state.get_node_property_count(0):
		var property := state.get_node_property_name(0, i)
		if property == &"identity": identity = state.get_node_property_value(0, i)
		elif property == &"script": rig_script = state.get_node_property_value(0, i)
	if identity == null: return paths
	var hair: Variant = identity.get("hair_scene")
	if hair is String and hair != "" and ResourceLoader.exists(hair): paths.append(hair)
	while rig_script != null and rig_script.resource_path != BACKGROUND_SCRIPT: rig_script = rig_script.get_base_script()
	if rig_script != null:
		for suffix in ["", "LOD1"]:
			var path := "res://world/characters/background/support/%s%s.res" % [identity.get("id"), suffix]
			if ResourceLoader.exists(path): paths.append(path)
	return paths
