extends RefCounted
## Walk-grid ceilings for the town houses (interiors_nav, 2026-11-19; thread reports since 0.3.0 and
## modChad's pathfinding-fix note: "the roof, attic and porch roof hid the ground floor").
##
## The walk grid keeps at most WalkGrid.SPANS (2) upward-facing floor spans per 25 cm column, taken
## from the top down (walk_grid_service.gd _sample_column and the native pony_column_sampler.cpp).
## A town house's shell is one two-sided trimesh (Exterior_col) holding the floor, the walls, the
## ceiling, the attic floor and the roof. Over the room the roof top and the ceiling's back (or the
## attic floor) used both spans, so the room's own floor was never sampled: no walkable cell inside
## any house C, and only 120 of 800 in house H; under porch roofs the stoop and doorway were missing
## too (tools/interiors_nav/audit_house_grid.gd). Routes to the door ended short, spots in the room
## were "not walkable", and a pony's nearest grid cell indoors was the roof.
##
## After the house has made its own collision edits (shell repairs, wing cut, two-sided faces, ramp
## clearing), every triangle whose lowest corner lies more than ABOVE_FLOOR metres above the room's
## floor, and every small shape wholly above it, moves into one StaticBody3D per house tagged
## `navigation_ceiling` (the tag the Hayburger, spa and overhead lamps already use). Same triangles,
## same layer and mask, same physics material: collision is unchanged, so walking, throwing, roof
## rescue and the camera behave as before. The grid excludes a tagged body from its floor rays after
## the first hit and still measures headroom against it. Door leaves and anything scripted are left
## alone; furniture is added later and never touched.
## Rollback: --house-nav-ceilings=off (or ENABLED = false before houses load).
static var ENABLED: bool = not ("--house-nav-ceilings=off" in OS.get_cmdline_user_args() or "--house-nav-ceilings=off" in OS.get_cmdline_args())
## Metres above the room floor (floor_y). Raised rooms, thresholds and stoops stand up to 0.56 m
## over floor_y, and the motor's ground probes start up to about 1.1 m above where she stands; the
## lowest porch roof, ceiling or attic floor that hid a floor is 2.8 m or more up. A 1.6 m cut (the
## pathfinding-fix mod's) stalled a real mare on house H's threshold that she crosses without it
## (tools/interiors_nav/test_town_house_door.gd); 2.4 m and 3.0 m let her through, and 2.4 m still
## uncovers the rooms and porches (audit table in docs/THREAD_FIX_INTERIORS_NAV_2026_11_19.md).
const ABOVE_FLOOR := 2.4
## Fixtures may change it before houses load (tools/interiors_nav).
static var above_floor := ABOVE_FLOOR
const BODY_NAME := "HouseNavigationCeiling"
## [shape, world basis (snapped), cut above the shape's origin (snapped)] -> [low shape or null, high shape
## or null, high bounds in the shape's frame]. Houses of one design whose shell was not copied (no
## ramp triangles dropped) share the split and its shapes, as they shared the source shape.
static var _splits: Dictionary = {}
const SPLITS_KEPT := 64

## Called deferred by house_interior.gd _ready (the house root is still adding its children
## there). Returns the world AABB of what moved (size zero when nothing did).
static func apply(interior: Node3D) -> AABB:
	if not ENABLED or not is_instance_valid(interior) or not interior.is_inside_tree(): return AABB()
	var house := interior.get_parent() as Node3D
	if house == null or house.has_node(BODY_NAME): return AABB()
	var started := Time.get_ticks_usec()
	var to_house := house.global_transform.affine_inverse()
	var floor_world: float = interior.to_global(Vector3(0, float(interior.floor_y), 0)).y
	# One ceiling body per source layer, mask and physics material (in practice one per house).
	var ceilings := {}
	var bounds := AABB()
	var moved := 0
	for body: StaticBody3D in house.find_children("*", "StaticBody3D", true, false):
		if body.get_class() != "StaticBody3D" or not (body.collision_layer & 1) or body.get_meta("navigation_ceiling", false): continue
		if _scripted_between(body, house): continue
		for child: Node in body.get_children():
			var holder := child as CollisionShape3D
			if holder == null or holder.disabled or holder.shape == null: continue
			var high: Shape3D
			var high_box := AABB()
			var xf: Transform3D = holder.global_transform
			if holder.shape is ConcavePolygonShape3D:
				# The split depends only on each corner's world height (the shape's world y row and the
				# cut measured from its origin) and on the world size of each triangle.
				var key := [holder.shape, [xf.basis.x.snapped(Vector3.ONE * .00001), xf.basis.y.snapped(Vector3.ONE * .00001), xf.basis.z.snapped(Vector3.ONE * .00001)], snappedf(floor_world + above_floor - xf.origin.y, .0001)]
				# Bounded: a reloaded world brings new shapes; old entries must not pin old ones.
				if _splits.size() > SPLITS_KEPT and not _splits.has(key): _splits.clear()
				if not _splits.has(key): _splits[key] = _split(holder.shape as ConcavePolygonShape3D, xf, floor_world + above_floor)
				var parts: Array = _splits[key]
				if parts[1] == null: continue
				high = parts[1]
				high_box = xf * (parts[2] as AABB)
				if parts[0] == null: holder.disabled = true
				else: holder.shape = parts[0]
			else:
				var box: AABB = xf * _local_bounds(holder.shape)
				if box.position.y <= floor_world + above_floor: continue
				high = holder.shape
				high_box = box
				holder.disabled = true
			var group := [body.collision_layer, body.collision_mask, body.physics_material_override]
			var ceiling := ceilings.get(group) as StaticBody3D
			if ceiling == null:
				ceiling = StaticBody3D.new()
				ceiling.name = BODY_NAME if ceilings.is_empty() else BODY_NAME + str(ceilings.size() + 1)
				ceiling.collision_layer = body.collision_layer
				ceiling.collision_mask = body.collision_mask
				ceiling.physics_material_override = body.physics_material_override
				ceiling.set_meta("navigation_ceiling", true)
				ceilings[group] = ceiling
			var copy := CollisionShape3D.new()
			copy.shape = high
			# Transform before the body enters the tree (Jolt keeps the scale it entered with).
			copy.transform = to_house * xf
			ceiling.add_child(copy)
			bounds = high_box if moved == 0 else bounds.merge(high_box)
			moved += 1
	for ceiling: StaticBody3D in ceilings.values(): house.add_child(ceiling)
	spent_usec += Time.get_ticks_usec() - started
	return bounds
## Main-thread time spent splitting, all houses (tools/interiors_nav/audit_house_grid.gd prints it).
static var spent_usec := 0

## A body under a door leaf or any other scripted node moves with it: never split it.
static func _scripted_between(body: Node, house: Node) -> bool:
	var node: Node = body
	while node != null and node != house:
		if node.get_script() != null: return true
		node = node.get_parent()
	return false

## Faces split by whether their lowest corner (world) is above `limit`: [low shape or null, high
## shape or null, high bounds (shape frame)].
static func _split(shape: ConcavePolygonShape3D, xf: Transform3D, limit: float) -> Array:
	var faces := shape.get_faces()
	var low := PackedVector3Array()
	var high := PackedVector3Array()
	var slivers := PackedVector3Array()
	# Only the world height of a corner matters: y = row . p + origin.y.
	var row := Vector3(xf.basis.x.y, xf.basis.y.y, xf.basis.z.y)
	var cut := limit - xf.origin.y
	for i in range(0, faces.size() - 2, 3):
		var a := faces[i]; var b := faces[i + 1]; var c := faces[i + 2]
		# Jolt welds corners closer than 1e-4 and drops what collapses; a shape made only of such
		# triangles is refused. They stay together with real triangles (below).
		if _sliver(a, b, c): slivers.append(a); slivers.append(b); slivers.append(c)
		elif minf(row.dot(a), minf(row.dot(b), row.dot(c))) > cut: high.append(a); high.append(b); high.append(c)
		else: low.append(a); low.append(b); low.append(c)
	if high.is_empty(): return [null, null, AABB()]
	if low.is_empty() and slivers.is_empty(): return [null, _shape(high, shape.backface_collision), _bounds(high)]
	var box := _bounds(high)
	if low.is_empty(): high.append_array(slivers)
	else: low.append_array(slivers)
	return [_shape(low, shape.backface_collision), _shape(high, shape.backface_collision), box]

static func _sliver(a: Vector3, b: Vector3, c: Vector3) -> bool:
	const WELD := 4e-8 # (2e-4)^2: twice Jolt's weld distance, squared
	return a.distance_squared_to(b) < WELD or b.distance_squared_to(c) < WELD or c.distance_squared_to(a) < WELD \
		or (b - a).cross(c - a).length_squared() < 1e-12

static func _bounds(faces: PackedVector3Array) -> AABB:
	var box := AABB(faces[0], Vector3.ZERO)
	for p: Vector3 in faces: box = box.expand(p)
	return box

## A shape's bounds in its own frame, without building a debug mesh.
static func _local_bounds(shape: Shape3D) -> AABB:
	if shape is BoxShape3D: return AABB(-(shape as BoxShape3D).size * .5, (shape as BoxShape3D).size)
	if shape is ConvexPolygonShape3D:
		var points := (shape as ConvexPolygonShape3D).points
		if points.is_empty(): return AABB()
		var box := AABB(points[0], Vector3.ZERO)
		for p: Vector3 in points: box = box.expand(p)
		return box
	if shape is SphereShape3D:
		var radius := (shape as SphereShape3D).radius
		return AABB(-Vector3.ONE * radius, Vector3.ONE * radius * 2.0)
	if shape is CapsuleShape3D or shape is CylinderShape3D:
		var r: float = shape.get("radius"); var h: float = shape.get("height")
		return AABB(Vector3(-r, -h * .5, -r), Vector3(r * 2.0, h, r * 2.0))
	# Anything else (height maps, world boundaries) stays where it is.
	return AABB(Vector3(0, -1e9, 0), Vector3.ZERO)

static func _shape(faces: PackedVector3Array, two_sided: bool) -> ConcavePolygonShape3D:
	if faces.is_empty(): return null
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = two_sided
	shape.set_faces(faces)
	return shape
