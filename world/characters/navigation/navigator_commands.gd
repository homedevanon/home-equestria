extends RefCounted
## AI command helpers of pony_navigator.gd (split 2026-10-13): destinations, contact steps,
## support and formation queries, indoor follow slots, place names and resolved locations.
## The navigator keeps every public name as a thin forward; state stays on the navigator, and
## calls back into it go through `nav.` so test doubles that override them still apply.

const HOUSE := preload("res://world/buildings/house_interior.gd")
const PLACES := preload("res://world/navigation/place_directory.gd")
const ROSTER_PLACEMENT := preload("res://world/navigation/roster_placement.gd")


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


static func go_to_spot(nav: Node, id: String) -> void:
	nav._spot = id
	var service: Variant = nav._service
	if not is_instance_valid(service): return
	var pony: CharacterBody3D = nav.pony
	var pos: Vector3 = service.hot_spot_world(id, pony.global_position.y)
	if not pos.is_finite(): return
	if nav._has_target and Vector3(nav.target).distance_to(pos) < .5: return
	if _flat(pony.global_position, pos) < 2.0: return
	nav.go_to(pos, nav.Gait.WALK)
	nav._spot_goal = true


## AI commands own intent only; route sampling, contact and acceleration stay in the navigator.
static func command_destination(nav: Node, destination: Vector3, requested_pace: String, refresh: bool) -> bool:
	if nav._movement_refused("command_destination"): return false
	nav._flight_shortcuts = false
	var chosen: int = nav.Gait.WALK if requested_pace == "walk" else nav.Gait.TROT
	if not refresh or not nav._has_target:
		var target_speed: float = nav.command_target_speed
		var target_velocity: Vector3 = nav.command_target_velocity
		nav.go_to(destination, chosen, false)
		# A tracking request is already moving on its first leg and after recovery.
		# Waiting for a second goal change parked followers of a stationary leader.
		nav._moving_goal = refresh
		if refresh:
			nav.command_target_speed = target_speed
			nav.command_target_velocity = target_velocity
	else:
		# A trip in legs (long, or over the river) keeps its legs: only its end moves. A goal
		# that jumped (a landmark resolved to its open ground) starts the trip afresh.
		var journey: Vector3 = nav._journey_goal
		if journey.is_finite():
			if _flat(destination, journey) < 6.0: nav._journey_goal = destination
			else: nav.go_to(destination, chosen, false)
			return true
		# Finish an outstanding query before refreshing. Moving targets must not
		# continually cancel the same build or reset physical stuck detection.
		nav._moving_goal = true
		nav._live_goal = destination
		if nav._request >= 0: return false
		nav.target = destination
		nav._needs_path = true
		if chosen != nav._route_gait:
			nav._route_gait = chosen
			nav._pick_pace()
	return true


static func command_target_visible(nav: Node, who: Node3D) -> bool:
	var pony: CharacterBody3D = nav.pony
	var from: Vector3 = pony.listen_point() if pony.has_method("listen_point") else pony.global_position + Vector3.UP
	var to: Vector3 = who.listen_point() if who.has_method("listen_point") else who.global_position
	var hit := pony.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, 1, [pony.get_rid()]))
	return hit.is_empty() or hit.position.distance_to(to) < .1 or who.is_ancestor_of(hit.collider) or who == hit.collider


static func command_target_floor(nav: Node, at: Vector3) -> Vector3:
	var pony: CharacterBody3D = nav.pony
	var query := PhysicsRayQueryParameters3D.create(at + Vector3.UP * .2, at - Vector3.UP * 4, 1)
	var hit := pony.get_world_3d().direct_space_state.intersect_ray(query)
	return hit.position if not hit.is_empty() else Vector3.INF


## Final sub-half-metre step after a supported activity route has arrived.
static func command_contact_approach(nav: Node, destination: Vector3) -> bool:
	if nav._movement_refused("command_contact_approach") or not destination.is_finite(): return false
	var pony: CharacterBody3D = nav.pony
	if not pony.grounded() or pony.global_position.distance_to(destination) > .5: return false
	var floor: Vector3 = nav.command_target_floor(destination + Vector3.UP)
	if not floor.is_finite() or absf(floor.y - pony.global_position.y) > float(pony.profile.step_height): return false
	var travel := floor - pony.global_position
	travel.y = 0.0
	if pony.test_move(pony.global_transform, travel): return false
	nav.stay()
	nav.target = floor; nav._live_goal = floor; nav._contact_approach = floor
	nav._has_target = true; nav._needs_path = false
	return true


static func command_support(nav: Node, at: Vector3) -> Vector3:
	var service: Variant = nav._service
	if not is_instance_valid(service): return Vector3.INF
	service.include_supported_ground(at)
	var floor: Vector3 = nav.command_target_floor(at + Vector3.UP)
	if floor.is_finite(): at = floor
	service.ensure_near(at, 1.5)
	return service.closest(at, nav.pony.profile, .8)


## A travelling group narrows to single file when side slots leave the road.
static func command_formation_support(nav: Node, at: Vector3, leader: Vector3) -> Vector3:
	var floor: Vector3 = nav.command_support(at)
	var service: Variant = nav._service
	if floor.is_finite() and service.trail_weight_at(leader) > .5 and service.trail_weight_at(floor) < .35:
		return Vector3.INF
	return floor


static func command_follow_goal(nav: Node, goal: Vector3, leader: Vector3) -> Vector3:
	if not goal.is_finite() or not leader.is_finite(): return Vector3.INF
	var now := Time.get_ticks_msec()
	var cache: Dictionary = nav._indoor_follow_cache
	if not cache.is_empty() and now - int(cache.time) < 500 \
			and goal.distance_squared_to(cache.goal) < .04 \
			and leader.distance_squared_to(cache.leader) < .04:
		return cache.result
	var home: Node3D = HOUSE.at(nav.get_tree(), leader)
	if home == null:
		cache.clear()
		return goal
	var pony: CharacterBody3D = nav.pony
	# contains() describes the room envelope, including its furniture and loft voids.
	# Use the same full-body standing certificate as placement, on the leader's floor.
	var floor: Vector3 = nav.command_target_floor(leader)
	var selected := Vector3.INF
	if floor.is_finite():
		var wanted := Vector3(goal.x, floor.y, goal.z)
		var candidates: Array[Vector3] = [wanted]
		var offset := Vector3(goal.x - leader.x, 0, goal.z - leader.z)
		var radius := clampf(offset.length(), 1.2, 3.0)
		var angle := atan2(offset.z, offset.x)
		for step: int in [1,-1,2,-2,3,-3,4,-4,5,-5,6]:
			var turn := angle + float(step) * TAU / 12.0
			candidates.append(Vector3(leader.x + cos(turn) * radius, floor.y, leader.z + sin(turn) * radius))
		for slot: Vector3 in home.slots():
			if absf(slot.y - floor.y) < .25 and _flat(slot, leader) <= radius + .5: candidates.append(slot)
		var inside: bool = home.contains(pony.global_position)
		var from: Vector3 = pony.global_position if inside else home.inside()
		var arrival: float = nav.arrival_distance
		for candidate: Vector3 in candidates:
			if not home.contains(candidate) or Vector2(candidate.x - leader.x, candidate.z - leader.z).length() < 1.0: continue
			var supported: Vector3 = nav._indoor_follow_support(home, candidate, floor.y)
			if not supported.is_finite(): continue
			# A free island behind furniture is not a usable follow destination.
			if inside:
				if not nav.house_travel.can_start(nav, home, supported): continue
			else:
				var next: Vector3 = nav.house_travel._waypoint(home, pony, from, supported)
				if from.distance_to(supported) > arrival and next.distance_to(from) < .05: continue
			selected = supported
			break
	nav._indoor_follow_cache = {"time": now, "goal": goal, "leader": leader, "result": selected}
	return selected


static func indoor_follow_support(nav: Node, home: Node3D, at: Vector3, floor_y: float) -> Vector3:
	var pony: CharacterBody3D = nav.pony
	var supported: Vector3 = ROSTER_PLACEMENT.support(
		pony.get_world_3d().direct_space_state, at, pony.profile, home, [pony.get_rid()])
	# No standing on a tabletop, dropping through a loft edge, or using another storey.
	return supported if supported.is_finite() and absf(supported.y - floor_y) < .20 else Vector3.INF


static func command_places(nav: Node) -> Array:
	var places: Array = []
	var service: Variant = nav._service
	if is_instance_valid(service) and service.layers != null:
		for spot: Dictionary in service.layers.hot_spots:
			places.append(str(spot.id))
	for place: Dictionary in PLACES.entries(nav.get_tree()): places.append(place.id)
	return places


## Lines for the prompt: nearest named places with labels and distances, then regions.
static func command_place_lines(nav: Node, local_limit: int) -> Array:
	var lines: Array = []
	var service: Variant = nav._service
	if is_instance_valid(service) and service.layers != null:
		for spot: Dictionary in service.layers.hot_spots: lines.append("%s = painted spot" % spot.id)
	var pony: CharacterBody3D = nav.pony
	return lines + PLACES.prompt_lines(nav.get_tree(), pony.global_position, local_limit)


static func command_location(nav: Node, id: String) -> Vector3:
	var pony: CharacterBody3D = nav.pony
	# A scripted story waypoint, "point:X,Z" (world/life/arrival_story.gd); never offered to the AI.
	if id.begins_with("point:"):
		var xz := id.trim_prefix("point:").split_floats(",")
		if xz.size() != 2: return Vector3.INF
		var at := Vector3(xz[0], pony.global_position.y, xz[1])
		var h: float = WorldTerrain.instance.height_at(at) if is_instance_valid(WorldTerrain.instance) else NAN
		if is_finite(h): at.y = h
		return at
	var service: Variant = nav._service
	var location_cache: Dictionary = nav._location_cache
	var tree: SceneTree = nav.get_tree()
	var place := PLACES.find(tree, id)
	if place.is_empty():
		location_cache.erase(id)
		return service.hot_spot_world(id, pony.global_position.y) if is_instance_valid(service) else Vector3.INF
	# A reloaded place can keep its id while its scene anchor and location change.
	var cached: Array = location_cache.get(id, [])
	if cached.size() == 3 and is_same(cached[2], place.get("node")) and Time.get_ticks_msec() - int(cached[1]) < 10000: return cached[0]
	var at := PLACES.resolve(tree, id)
	# Authored outdoor meeting points already name their walkable aisle. Sampling
	# a partially loaded grid must not move them 14 m away, then restart the trip
	# when more cells arrive. Route planning still validates support and obstacles.
	if place.kind == PLACES.HOUSE_KIND or place.get("interior_goal", false) or not at.is_finite(): return at
	if place.get("open_ground", false):
		location_cache[id] = [at, Time.get_ticks_msec(), place.get("node")]
		return at
	# A landmark that is a home (Fluttershy's cottage) means meeting at its front door, outside
	# (2026-10-24 tester: "her cottage" resolved to a cell just inside her door, so a lead from
	# indoors walked out, turned back in and jammed in the doorway; tools/fluttershy/route_probe.gd).
	var home := _landmark_home(tree, place)
	if home != null:
		var front: Vector3 = home.outside()
		location_cache[id] = [front, Time.get_ticks_msec(), place.get("node")]
		return front
	# A landmark's origin is usually inside its walls: stand on open ground beside it. Town
	# Hall's lies so deep inside that every route to it ran out of search budget
	# (tools/navigation/probe_river_paths.gd, 2026-09-30); its open ground is up to 14 m out,
	# so the grid is sampled that far before searching.
	if is_instance_valid(service) and _flat(at, pony.global_position) < 250.0:
		service.ensure_near(at, 20.0)
		# Walk out from it toward her: the first walkable cell at ground level (not a ledge,
		# porch rail or roof beside it: the nearest cell to Town Hall's point was one, and
		# every route to it failed, river_trips.gd 2026-09-30).
		var side := pony.global_position - at; side.y = 0.0
		var outward := side.normalized() if side.length() > .1 else Vector3.FORWARD
		for radius: float in [3.0, 8.0, 14.0, 18.0]:
			var probe := at + outward * radius
			var h: float = WorldTerrain.instance.height_at(probe) if is_instance_valid(WorldTerrain.instance) else NAN
			if is_finite(h): probe.y = h
			var ground: Vector3 = service.closest(probe, pony.profile, 2.0)
			if ground.is_finite() and (not is_finite(h) or absf(ground.y - h) < .6) and not _inside_home(tree, ground):
				location_cache[id] = [ground, Time.get_ticks_msec(), place.get("node")]
				return ground
		for radius in [3.0, 8.0, 14.0]:
			var ground: Vector3 = service.closest(at, pony.profile, radius)
			if ground.is_finite() and not _inside_home(tree, ground):
				location_cache[id] = [ground, Time.get_ticks_msec(), place.get("node")]
				return ground
		# Not sampled yet: aim at her side of it, clear of a building's walls, until it is.
		if side.length() > 16.0:
			var front := at + outward * 14.0
			var fh: float = WorldTerrain.instance.height_at(front) if is_instance_valid(WorldTerrain.instance) else NAN
			if is_finite(fh): front.y = fh
			return front
	return at


## The house interior inside a landmark's scene node (a building with a usable home), else null.
static func _landmark_home(tree: SceneTree, place: Dictionary) -> Node3D:
	var node: Node = place.get("node") if is_instance_valid(place.get("node")) else null
	if node == null or place.get("kind", "") == PLACES.HOUSE_KIND: return null
	for home: Node in tree.get_nodes_in_group("house_interiors"):
		if home is Node3D and home.has_method("outside") and node.is_ancestor_of(home): return home
	return null

## Whether an outdoor goal candidate lies inside any house (a walk-grid floor cell indoors).
static func _inside_home(tree: SceneTree, at: Vector3) -> bool:
	for home: Node in tree.get_nodes_in_group("house_interiors"):
		if home is Node3D and home.has_method("contains") and home.contains(at): return true
	return false


static func awareness_places(nav: Node) -> Array:
	var pony: Variant = nav.pony
	var service: Variant = nav._service
	var places: Array = service.nearby_places(pony.global_position) if is_instance_valid(service) and is_instance_valid(pony) else []
	var tree: SceneTree = nav.get_tree()
	var population: Node = tree.get_first_node_in_group("pony_populations")
	var me: String = str(pony.identity.id) if pony.get("identity") != null else ""
	for place: Dictionary in PLACES.entries(tree):
		if place.kind.begins_with("region"): continue
		# Other ponies' houses are not talking points; her own home is.
		if place.kind == PLACES.HOUSE_KIND:
			if population == null or not population.has_method("residents_of") or me not in population.residents_of(place.id): continue
			place = place.duplicate(); place.label = "your home"
		var distance: float = pony.global_position.distance_to(place.position)
		if distance < (30.0 if place.kind == PLACES.HOUSE_KIND else 45.0):
			places.append({"id": place.id, "name": place.label, "kind": "HOUSE" if place.kind == PLACES.HOUSE_KIND else "LANDMARK", "distance": distance})
	places.sort_custom(func(a, b): return a.distance < b.distance)
	return places.slice(0, 6)
