extends RefCounted

## Repair only impossible saved falls, not normal basements or authored raised floors.
## This is a spawn hint: normal dry-ground/clearance checks still certify placement.
static func recover_saved_depth(point: Vector3) -> Vector3:
	if not is_instance_valid(WorldTerrain.instance): return point
	var height := WorldTerrain.instance.height_at(point)
	if is_finite(height) and point.y < height - 200.0: point.y = height + .02
	return point
## Spawn-only physics checks. Missing support returns INF, never a guessed y=0.
const PROFILE := preload("res://world/characters/locomotion/pony_gait_profile.gd")
const WATER := preload("res://world/water/water_contact.gd")

## 2026-11-18 perf (town street, 8 s: building 12 ms / 3619 calls, about 19 per support() call,
## whose nine floor rays and nine overhead rays mostly hit the same one or two colliders). The answer
## reads only the names and metas up the node's parent chain, which no counter tracks, so it is kept
## for the same physics step of the same main-loop iteration only, keyed by the node's instance id.
## Rollback: BUILDING_MEMO = false.
const BUILDING_MEMO := true
static var _building_known: Dictionary = {}
static var _building_physics := -1
static var _building_process := -1
static func building(node:Node)->bool:
	if not BUILDING_MEMO or not is_instance_valid(node): return _building_walk(node)
	var physics := Engine.get_physics_frames()
	var process := Engine.get_process_frames()
	if physics != _building_physics or process != _building_process:
		_building_known.clear()
		_building_physics = physics
		_building_process = process
	var id := node.get_instance_id()
	var known: Variant = _building_known.get(id)
	if known != null: return bool(known)
	var found := _building_walk(node)
	_building_known[id] = found
	return found

static func _building_walk(node:Node)->bool:
	while is_instance_valid(node):
		# Town houses are instanced as plot_NNNN under PonyvilleTown: their names never say
		# "house", so roofs passed as ground and residents spawned on them (2026-09-22).
		if node.has_meta("building_design") or node.has_meta("browser_source"):return true
		var name:=str(node.name).to_lower()
		if name.contains("bridge"):return false
		if name.contains("house") or name.contains("building") or name.contains("interior") or name.contains("roof") \
				or name.begins_with("tent_") or name.contains("circus") or name.begins_with("kiosk"):
			return true
		node=node.get_parent()
	return false

static func select_service(services: Array, at: Vector3, preferred_zone := "") -> Node3D:
	var selected: Node3D
	var smallest := INF
	for service in services:
		if not is_instance_valid(service): continue
		var box: AABB = service.bounds
		if at.x < box.position.x or at.z < box.position.z or at.x > box.end.x or at.z > box.end.z: continue
		if service.zone_id == preferred_zone: return service
		var area := box.size.x * box.size.z
		if area < smallest: selected = service; smallest = area
	return selected

static func separated(point: Vector3, others: Array[Vector3], spacing: float) -> bool:
	for other in others:
		if Vector2(point.x - other.x, point.z - other.z).length() < spacing: return false
	return true

static func support(space: PhysicsDirectSpaceState3D, wanted: Vector3, profile: Resource, home:Node3D=null, exclude:Array[RID]=[]) -> Vector3:
	var hits: Array[Vector3] = []
	for i in 9:
		var offset: Vector3 = Vector3.ZERO if i == 0 else Vector3(cos(i * TAU / 8), 0, sin(i * TAU / 8)) * profile.radius
		var query := PhysicsRayQueryParameters3D.create(wanted + offset + Vector3.UP * 0.5, wanted + offset - Vector3.UP * 3.0, 1)
		query.exclude = exclude
		var hit := space.intersect_ray(query)
		if hit.is_empty() or hit.normal.y < cos(deg_to_rad(profile.max_slope_degrees)): return Vector3.INF
		if building(hit.collider) and (not is_instance_valid(home) or not home.contains(hit.position)):return Vector3.INF
		var overhead:=space.intersect_ray(PhysicsRayQueryParameters3D.create(hit.position+Vector3.UP*.05,hit.position+Vector3.UP*30.0,1))
		if not overhead.is_empty() and building(overhead.collider) and not is_instance_valid(home):return Vector3.INF
		# Spawn on dry support across the whole footprint, even for wading profiles.
		if is_finite(WATER.surface_above(space, hit.position + Vector3.UP * .005)): return Vector3.INF
		hits.append(hit.position)
	var center := hits[0]
	for point in hits:
		if absf(point.y - center.y) > profile.step_height + profile.radius * tan(deg_to_rad(profile.max_slope_degrees)): return Vector3.INF
	# Keep the full standing body clear of walls, props and already spawned ponies.
	var shape := CylinderShape3D.new()
	shape.radius = profile.radius
	shape.height = profile.clearance
	var volume := PhysicsShapeQueryParameters3D.new()
	volume.shape = shape
	volume.transform.origin = center + Vector3.UP * (profile.clearance * .5 + .08)
	volume.collision_mask = 3
	volume.exclude = exclude
	if not space.intersect_shape(volume, 1).is_empty(): return Vector3.INF
	return center + Vector3.UP * .03

static func fallback(space: PhysicsDirectSpaceState3D, anchor: Vector3, taken: Array[Vector3], radius: float, spacing: float, profile: Resource) -> Vector3:
	# Bounded deterministic lattice; no overlapping emergency stack if this finds nothing.
	var reach := int(ceil(radius / spacing))
	for ring in range(reach + 1):
		for x in range(-ring, ring + 1):
			for z in range(-ring, ring + 1):
				if maxi(absi(x), absi(z)) != ring: continue
				var wanted := anchor + Vector3(x * spacing, 0, z * spacing)
				if Vector2(x * spacing, z * spacing).length() > radius or not separated(wanted, taken, spacing): continue
				var point := support(space, wanted, profile)
				if point.is_finite(): return point
	return Vector3.INF
