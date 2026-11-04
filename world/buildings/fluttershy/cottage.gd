extends Node3D
## Source-led cottage shell with baked vault, fitted foundation and authored rooms.
const SOURCE_ID := "snazzys_fluttershy_cottage_01"
const DATA_PATH := "res://world/buildings/fluttershy/geometry.json"
const SOURCE := preload("res://world/props/rnl/rnl_snazzys_fluttershy_cottage/mesh_0.res")
const SHELL := preload("res://world/buildings/fluttershy/shell.res")
## The show-accurate interior (dev 2026-10-17: "port this to our fluttershys cabin"): Discopears'
## Fluttershy's Cottage set (CC BY-SA 4.0, credited in the credits page), imported with the
## official Blender MCP. The complete room keeps its 0.85 scale; its fitted position and
## authored foyer join the unchanged exterior doorway without cutting holes in the rooms.
## INTERIOR_FIT maps the set's own frame (its glb) into this cottage's local frame.
const SHOW_INTERIOR := preload("res://world/buildings/fluttershy/interior/cottage_interior.glb")
const INTERIOR_DIR := "res://world/buildings/fluttershy/interior/"
const INTERIOR_FIT := Transform3D(Basis(Vector3(0, 0, -0.85), Vector3(0, 0.85, 0), Vector3(0.85, 0, 0)), Vector3(-1.2781, 0.816, 4.4703))
## Visible set boards are at 0.0534 m; 0.04 buried rugs and prop feet.
const SET_FLOOR := 0.054
## Set triangles smaller than this (m², upright) are trim, not collision.
const TRIM_AREA := 0.03
const HOME := preload("res://world/buildings/fluttershy/cottage_home.gd")
const DOOR := preload("res://world/buildings/hinged_door.gd")
const BED := preload("res://world/props/ponyville/pony_bed.scn")
const KITCHEN := preload("res://world/props/household/compact-kitchen.scn")
const FURNISHER := preload("res://world/interiors/interior_furnisher.gd")
const HOUSE := preload("res://world/buildings/house_interior.gd")
const LAMP := preload("res://world/props/lamps/kit_lamp.gd")
var data: Dictionary
var home: Node3D
var frame: Node3D
var kitchen: Node3D
var complete := false

static func attach(existing: Node3D) -> Node3D:
	assert(existing != null and str(existing.name) == SOURCE_ID)
	var installed := existing.get_node_or_null("UsableCottage")
	if installed != null: return installed
	var original_mesh: MeshInstance3D
	for mesh: MeshInstance3D in existing.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh.resource_path == SOURCE.resource_path: original_mesh = mesh; break
	assert(original_mesh != null, "Original cottage mesh must exist")
	assert(original_mesh.transform.is_equal_approx(Transform3D.IDENTITY), "Re-measure changed source transform")
	var old_colliders := existing.find_children("*", "CollisionObject3D", true, false)
	var cottage := load("res://world/buildings/fluttershy/cottage.gd").new() as Node3D
	cottage.name = "UsableCottage"
	existing.add_child(cottage)
	assert(cottage.complete)
	# Duplicate preserves the other surfaces' artwork, UVs and generated LODs.
	var shell: ArrayMesh = SHELL.duplicate()
	# Only architectural walls need an inward face. In particular, preserve the
	# original leaf/roof culling: double-sided foliage fills the room with planes.
	# JSON numbers are floats; normalize IDs before Array membership checks.
	var inward: Array[int] = []
	for index: float in cottage.data.interior_surfaces: inward.append(int(index))
	for s in shell.get_surface_count():
		shell.surface_set_material(s, SOURCE.surface_get_material(s))
		if s not in inward: continue
		var material := shell.surface_get_material(s) as BaseMaterial3D
		assert(material != null, "Measured cottage structural surface requires BaseMaterial3D: " + str(s))
		material = material.duplicate()
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		shell.surface_set_material(s, material)
	shell.surface_remove(int(cottage.data.door_surface))
	original_mesh.mesh = shell
	for collider: CollisionObject3D in old_colliders:
		collider.collision_layer = 0; collider.collision_mask = 0
	existing.set_meta("fluttershy_interior", true)
	return cottage

func _ready() -> void:
	data = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
	assert(FileAccess.get_sha256(SOURCE.resource_path) == str(data.baked_mesh_sha256), "Cottage source changed: remeasure first")
	var center := _v3(data.door_center)
	var outward := _v3(data.door_outward)
	frame = Node3D.new(); frame.name = "RoomFrame"
	frame.transform = Transform3D(Basis(Vector3.UP.cross(outward), Vector3.UP, outward), center)
	add_child(frame)
	_build_shell_collision()
	_build_floor()
	_build_interior()
	_build_foundation()
	_build_door()
	home = HOME.new(); home.name = "HouseInterior"; home.scale = Vector3.ONE * 10.0
	home.floor_y = float(data.floor_y) / 10.0
	home._ceiling_y = 5.45 / 10.0
	home.doorway = Vector3(0, home.floor_y, 0)
	home.door_width = float(data.door_width) / 10.0
	var length := float(data.threshold_length)
	var approach_y := lerpf(float(data.floor_y), float(data.threshold_toe_y), 1.2 / length)
	home.approach = Vector3(0, approach_y / 10.0, .12)
	var polygon := PackedVector2Array()
	for point: Array in data.floor_frame_boundary: polygon.append(Vector2(point[0], point[1]) / 10.0)
	home.boundary = polygon
	var bounds := Rect2(polygon[0], Vector2.ZERO)
	for point in polygon: bounds = bounds.expand(point)
	home.floors.append(bounds)
	frame.add_child(home)
	# The show interior's main room: its middle, and the point just past the entrance alcove.
	home.room_center = home.to_local(to_global(_set_point(Vector2(2.6, -1.4))))
	# Clear the original swinging leaf before taking the authored foyer bend.
	home.inside_at = Vector3(0, home.floor_y, -.075)
	_build_furniture()
	# Passage anchors are independent of the number of decorative props: entrance hall, main
	# room, both sides of the kitchen doorway and the kitchen (the set's own plan, metres).
	home.waypoints.clear()
	for plan: Vector2 in [Vector2(9.45, -1.65), Vector2(7.6, .55), Vector2(6.2, .55), Vector2(5.3, 0.6), Vector2(2.6, -0.9), Vector2(1.3, -2.9), Vector2(4.1, -2.5), Vector2(2.6, -4.7),
			Vector2(-0.3, -3.5), Vector2(-1.55, -3.5), Vector2(-1.55, -1.0), Vector2(-2.9, -2.6), Vector2(-3.0, -4.0)]:
		home.waypoints.append(home.to_local(to_global(_set_point(plan))))
	complete = true

## A point on the set's floor, from its plan (x right, y up the plan), in this cottage's frame.
func _set_point(plan: Vector2, lift := 0.0) -> Vector3:
	return INTERIOR_FIT * Vector3(plan.x, SET_FLOOR + lift, -plan.y)

## A yaw in the set's frame turned into this cottage's frame (the set is turned a quarter).
static func _set_yaw(yaw: float) -> float:
	return yaw + PI * 0.5

func _build_shell_collision() -> void:
	var mesh := ArrayMesh.new()
	for surface: float in data.collision_surfaces:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, SOURCE.surface_get_arrays(int(surface)))
	var shape := mesh.create_trimesh_shape(); shape.backface_collision = true
	_collision(self, "SourceWalls", shape)

func _build_floor() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_texture = preload("res://world/buildings/house_a/textures/floorboards_albedo.png")
	material.albedo_color = Color("b4a28a"); material.roughness = .95
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var surface := SurfaceTool.new(); surface.begin(Mesh.PRIMITIVE_TRIANGLES); surface.set_material(material)
	var seed := Vector3(data.floor_seed[0], data.floor_y, data.floor_seed[1])
	var boundary: Array = data.floor_boundary
	for i in boundary.size():
		var a: Array = boundary[i]; var b: Array = boundary[(i + 1) % boundary.size()]
		for point: Vector3 in [seed, Vector3(a[0], data.floor_y, a[1]), Vector3(b[0], data.floor_y, b[1])]:
			surface.set_normal(Vector3.UP); surface.set_uv(Vector2(point.x, point.z) * .28); surface.add_vertex(point)
	var view := MeshInstance3D.new(); view.name = "FittedFloor"; view.mesh = surface.commit(); add_child(view)
	var shape := view.mesh.create_trimesh_shape(); shape.backface_collision = true
	_collision(view, "FloorSolid", shape)

## The set's rooms (walls, floors, ceiling, loft, stairs, kitchen counter) with one static
## collider built from its own triangles. The fitted foundation floor remains just below
## the set boards and closes the small perimeter between the foyer and exterior threshold.
func _build_interior() -> void:
	var interior := SHOW_INTERIOR.instantiate() as Node3D
	interior.name = "ShowInterior"
	interior.transform = INTERIOR_FIT
	add_child(interior)
	# Walls, floors, counters and stairs collide; the set's small trim (the critters' little ramps
	# and stairs by the walls, hooks, frames) is left out so it does not snag ponies.
	var faces := PackedVector3Array()
	for mesh: MeshInstance3D in interior.find_children("*", "MeshInstance3D", true, false):
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var to_cottage := interior.transform * _relative(interior, mesh)
		var source := mesh.mesh.get_faces()
		for i in range(0, source.size(), 3):
			var a := to_cottage * source[i]; var b := to_cottage * source[i + 1]; var c := to_cottage * source[i + 2]
			var cross := (b - a).cross(c - a)
			var area := cross.length() * 0.5
			# Small level faces count only at floor height (the floor's own tiles), not the
			# little ramps' and steps' plank tops.
			var floor_level := area > 0.0 and absf(cross.normalized().y) > 0.9 and absf(a.y - float(data.floor_y)) < 0.06
			if area < TRIM_AREA and not floor_level: continue
			faces.append(a); faces.append(b); faces.append(c)
	faces.append_array(_stair_ramp_faces())
	var shape := ConcavePolygonShape3D.new(); shape.set_faces(faces); shape.backface_collision = true
	_collision(self, "InteriorSolid", shape)
	# The cut doorway perimeter lacks boards. Its existing fitted floor follows
	# the outer shell and remains behind the set's slightly higher floor.
	var floor_view := get_node_or_null("FittedFloor") as MeshInstance3D
	if floor_view != null: floor_view.visible = true

## Invisible stair brush over the main flight, like Golden Oak's continuous stair ramp: one
## plane across the 26 nosings, so bodies and ledge probes see a steady 34-degree slope
## instead of quantized risers (the player pony stopped at the loft edge on the way down).
## Measured from the real treads (tools/fluttershy/probe_stair_profile.gd), in plan metres
## and set heights: first nosing (-2.195, 0.1811), last at the loft edge (2.4925, 3.3463),
## between the stair cheeks. The plane sits STAIR_CLEAR above every nosing: a plane through
## the nosing edges gave the capsule a 48-degree edge normal and stalled the pony at the
## toe. The toe and a gentle run onto the loft continue under the boards.
const STAIR_X := Vector2(-0.84, 0.48)
const STAIR_TOE := Vector2(-2.3825, 0.0534)
const STAIR_HEAD := Vector2(2.4925, 3.3463)
const STAIR_CLEAR := 0.02

func _stair_ramp_faces() -> PackedVector3Array:
	var rise := (STAIR_HEAD.y - STAIR_TOE.y) / (STAIR_HEAD.x - STAIR_TOE.x)
	var toe := STAIR_TOE.x - STAIR_CLEAR / rise
	var along: Array[Vector2] = [Vector2(toe - .08, STAIR_TOE.y - .08 * rise), Vector2(toe, STAIR_TOE.y),
		Vector2(STAIR_HEAD.x, STAIR_HEAD.y + STAIR_CLEAR), Vector2(STAIR_HEAD.x + .2, STAIR_HEAD.y),
		Vector2(STAIR_HEAD.x + .3, STAIR_HEAD.y - .01)]
	var faces := PackedVector3Array()
	for i in along.size() - 1:
		var a := _set_point(Vector2(STAIR_X.x, along[i].x), along[i].y - SET_FLOOR)
		var b := _set_point(Vector2(STAIR_X.y, along[i].x), along[i].y - SET_FLOOR)
		var c := _set_point(Vector2(STAIR_X.y, along[i + 1].x), along[i + 1].y - SET_FLOOR)
		var d := _set_point(Vector2(STAIR_X.x, along[i + 1].x), along[i + 1].y - SET_FLOOR)
		faces.append_array([a, b, c, a, c, d])
	return faces

static func _relative(root: Node3D, node: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var at: Node = node
	while at != root and at is Node3D:
		t = (at as Node3D).transform * t
		at = at.get_parent()
	return t

func _build_foundation() -> void:
	# A low skirt closes the downhill gap after moving the cottage onto a slope.
	# Only authored static geometry; collision remains owned by the fitted floor.
	var bottom := float(data.get("foundation_base_y", -.12))
	var top := float(data.floor_y) - .025
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("aa9b81");material.roughness = 1.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var surface := SurfaceTool.new();surface.begin(Mesh.PRIMITIVE_TRIANGLES);surface.set_material(material)
	var boundary: Array = data.floor_boundary
	for i in boundary.size():
		var a: Array = boundary[i];var b: Array = boundary[(i+1)%boundary.size()]
		for point: Vector3 in [Vector3(a[0],bottom,a[1]),Vector3(b[0],bottom,b[1]),Vector3(b[0],top,b[1]),Vector3(a[0],bottom,a[1]),Vector3(b[0],top,b[1]),Vector3(a[0],top,a[1])]:surface.add_vertex(point)
	surface.generate_normals()
	var view := MeshInstance3D.new();view.name = "FittedFoundation";view.mesh = surface.commit();add_child(view)

func _build_door() -> void:
	var width := float(data.door_width)
	var hinge := Vector3(-width * .5, data.floor_y, 0)
	var door := DOOR.new(); door.name = "FrontDoor"; door.position = hinge
	door.handle = Vector3(width - .22, 1.10, .02)
	# Past 76 degrees the leaf passes into the foyer's side wall, which has no collision to stop it
	# (player bug board #33, 2026-10-28; tools/board_fixes/door_swing_views.gd renders).
	door.max_open = deg_to_rad(76.0)
	door.navigation_box = AABB(Vector3(0, 0, -.09), Vector3(width, float(data.door_top) - float(data.floor_y), .18))
	var artwork := MeshInstance3D.new(); artwork.name = "OriginalDoorArtwork"
	# Bake only the leaf's change of frame into its vertices. A rotated source AABB
	# would make the shared handle builder think this flat leaf is metres thick.
	var leaf_frame := Transform3D(Basis.IDENTITY, hinge).affine_inverse() * frame.transform.affine_inverse()
	var leaf_arrays: Array = SOURCE.surface_get_arrays(int(data.door_surface)).duplicate(true)
	var vertices: PackedVector3Array = leaf_arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = leaf_arrays[Mesh.ARRAY_NORMAL]
	for i in vertices.size():
		vertices[i] = leaf_frame * vertices[i]
		if i < normals.size(): normals[i] = (leaf_frame.basis * normals[i]).normalized()
	leaf_arrays[Mesh.ARRAY_VERTEX] = vertices; leaf_arrays[Mesh.ARRAY_NORMAL] = normals
	if leaf_arrays[Mesh.ARRAY_TANGENT] != null:
		var tangents: PackedFloat32Array = leaf_arrays[Mesh.ARRAY_TANGENT]
		for i in range(0, tangents.size(), 4):
			var tangent := leaf_frame.basis * Vector3(tangents[i], tangents[i+1], tangents[i+2])
			tangents[i] = tangent.x; tangents[i+1] = tangent.y; tangents[i+2] = tangent.z
		leaf_arrays[Mesh.ARRAY_TANGENT] = tangents
	var mesh := ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, leaf_arrays)
	var material := SOURCE.surface_get_material(int(data.door_surface)).duplicate() as BaseMaterial3D
	material.cull_mode = BaseMaterial3D.CULL_DISABLED; mesh.surface_set_material(0, material)
	artwork.mesh = mesh
	door.add_child(artwork)
	# The original leaf is a plane. Give its visible arched contour a solid wooden back.
	var contour := PackedVector2Array()
	var arrays: Array = mesh.surface_get_arrays(0)
	for vertex: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
		var point := artwork.transform * vertex
		contour.append(Vector2(point.x, maxf(.015, point.y)))
	contour = Geometry2D.convex_hull(contour)
	if contour[0].is_equal_approx(contour[-1]): contour.resize(contour.size() - 1)
	var points := PackedVector3Array()
	for point in contour:
		points.append(Vector3(point.x, point.y, 0)); points.append(Vector3(point.x, point.y, -.055))
	var shape := ConvexPolygonShape3D.new(); shape.points = points; shape.margin = .001
	var holder := CollisionShape3D.new(); holder.name = "LeafCollision"; holder.shape = shape; door.add_child(holder)
	var wood := StandardMaterial3D.new(); wood.albedo_color = Color("804d37"); wood.roughness = .9; wood.cull_mode = BaseMaterial3D.CULL_DISABLED
	var surface := SurfaceTool.new(); surface.begin(Mesh.PRIMITIVE_TRIANGLES); surface.set_material(wood)
	var triangles := Geometry2D.triangulate_polygon(contour)
	for index in triangles: surface.add_vertex(Vector3(contour[index].x, contour[index].y, -.055))
	for i in contour.size():
		var a := contour[i]; var b := contour[(i + 1) % contour.size()]
		for point: Vector3 in [Vector3(a.x,a.y,0),Vector3(b.x,b.y,0),Vector3(b.x,b.y,-.055),Vector3(a.x,a.y,0),Vector3(b.x,b.y,-.055),Vector3(a.x,a.y,-.055)]: surface.add_vertex(point)
	surface.generate_normals()
	var back := MeshInstance3D.new(); back.name = "InsideArtwork"; back.mesh = surface.commit(); door.add_child(back)
	frame.add_child(door)

func _build_furniture() -> void:
	var bed: Node3D = BED.instantiate(); bed.name = "CottageBed"
	# Fluttershy's bed lengthwise along the main room's back wall, its side to the room.
	bed.position = _set_point(BED_PLAN); bed.position.y = data.floor_y; bed.rotation.y = _set_yaw(BED_YAW)
	bed.set_meta("house", home); bed.set_meta("side_local", _v3(data.bed.side_local)); bed.set_meta("slot", "cottage_rear")
	# BED owns its accepted mattress height and dimensions; do not replace packed metadata.
	var bed_size: Vector3 = bed.get_meta("bed_size", HOME.BED_SIZE)
	add_child(bed); home.bed = bed; home.set_sleepers(["fluttershy"])
	bed.add_to_group("house_furniture"); bed.set_meta("furniture", "pony-bed")
	kitchen = Node3D.new(); kitchen.name = "Kitchen"
	# The working stove (cooking contract) against the kitchen's front wall, facing in.
	kitchen.position = _set_point(KITCHEN_PLAN); kitchen.position.y = data.floor_y; kitchen.rotation.y = _set_yaw(KITCHEN_YAW)
	kitchen.add_child(KITCHEN.instantiate()); add_child(kitchen)
	kitchen.add_to_group("house_furniture"); kitchen.set_meta("furniture", "compact-kitchen"); kitchen.set_meta("kitchen", true); kitchen.set_meta("house", home)
	var shape := BoxShape3D.new(); shape.size = _v3(data.kitchen.size)
	_collision(kitchen, "KitchenSolid", shape, Vector3(0, shape.size.y * .5, 0))
	preload("res://world/cooking/cooking_fit.gd").attach(kitchen, home, "compact-kitchen")
	var spot := Marker3D.new(); spot.name = "CounterAccess"; spot.position = Vector3(0, 0, 1.4); kitchen.add_child(spot)
	spot.add_to_group("house_activity_spots"); spot.set_meta("activity", "cook"); spot.set_meta("house", home)
	# Metre-sized prop bounds + pony clearance, transformed into the home's 10 cm frame.
	for prop: Node3D in [bed, kitchen]:
		var size: Vector3 = bed_size if prop == bed else _v3(data.kitchen.size)
		for x: float in [-1., 1.]:
			for z: float in [-1., 1.]:
				home.waypoints.append(home.to_local(prop.to_global(Vector3(x * (size.x * .5 + .50), 0, z * (size.z * .5 + .50)))))
	home.waypoints.append(home.to_local(home.bed_side("fluttershy")))
	home.waypoints.append(home.to_local(spot.global_position))
	_build_decor()
	# Indoor props use the shared furnishing visibility range.
	var props: Array[Node] = get_children()
	# Perf 0.1.0 (geometry): the set's own furniture (sofa, armchair, desk, chest, tables, rugs,
	# cage, lamp...) stands under ShowInterior, so the loop above never reached it and it drew from
	# any distance (65 surfaces still in range 265 m away, 2026-10-23 inventory). It now fades out
	# at the same PROP_RANGE as every other indoor prop. false = set furniture without a range.
	var show_set := get_node_or_null("ShowInterior")
	if RANGE_SET_PROPS and show_set != null: props.append_array(show_set.get_children())
	for prop: Node in props:
		if prop.is_in_group("house_furniture"): HOUSE.limit_range(prop, HOUSE.PROP_RANGE, true)

const RANGE_SET_PROPS := true

## Plan spots (the set's metres) for the bed and stove, and the set's own furniture.
const BED_PLAN := Vector2(2.45, 1.55)
const BED_YAW := -PI * 0.5
const KITCHEN_PLAN := Vector2(-3.0, -5.75)
## The readable bookcase, and where a pony stands to browse it.
const READING_SHELF := Vector2(0.55, -6.3)
const READING_SPOT := Vector2(0.6, -5.15)
const KITCHEN_YAW := PI
## [model, plan x, plan y, yaw (set frame), lift, solid]
const SET_PROPS := [
	["rug_round", 2.6, -3.4, 0.0, 0.003, false], ["small_table", 2.6, -3.5, 0.0, 0.0, true],
	["sofa_long", 2.95, -6.0, PI * 0.5, 0.0, true], ["armchair", 4.9, -4.0, PI, 0.0, true],
	["standing_lamp", 5.3, -2.6, 0.0, 0.0, true], ["bird_cage", 5.3, 2.0, 0.0, 0.0, true],
	["pet_bed", 1.5, -1.2, 0.0, 0.0, false], ["desk", 5.2, -6.2, PI, 0.0, true],
	["chest", 4.15, 2.05, -PI * 0.5, 0.0, true], ["rug_rectangle", 2.45, -0.2, 0.0, 0.003, false],
	["kitchen_table", -2.9, -0.6, PI * 0.5, 0.0, true], ["kitchen_bench", -3.75, -0.6, PI * 0.5, 0.0, false],
	["salad_bowl", -2.9, -0.6, 0.0, 0.7292, false], ["pitcher", -2.75, -1.2, 0.0, 0.7267, false]]
## Real seats on the set's sofa, armchair and kitchen bench (thread 43671981, 2026-11-03: "there's
## no actual seats in her cottage other than her bed"). Same shape as interior_kit.json "seating"
## (metres, from the model's bottom centre, the sitter facing +Z) and built by the shared
## FURNISHER._add_seating, so ponies (Seating) and Anon (E / trigger) sit on them like on kit
## furniture. The sofa and armchair face their model +X (backs on -X, tools/fluttershy/
## probe_set_seats.gd), so their seat frame is turned a quarter; the bench faces the table on +Z.
## Seat tops: sofa and armchair cushions 0.29 m, bench 0.26 m (set heights x 0.85).
const SET_SEATING := {
	"sofa_long": {"turn": PI * 0.5, "couch": true, "seating": {
		"seats": [[-0.62, 0.29, 0.12], [0.0, 0.29, 0.12], [0.62, 0.29, 0.12]], "depth": 0.5,
		"solid": [[[0.0, 0.145, 0.0], [1.9, 0.29, 0.8]]],
		"upper": [[[0.0, 0.62, -0.32], [2.0, 0.66, 0.22]]]}},
	"armchair": {"turn": PI * 0.5, "couch": false, "seating": {
		"seats": [[0.0, 0.29, 0.1]], "depth": 0.5,
		"solid": [[[0.0, 0.145, 0.05], [0.8, 0.29, 0.75]]],
		"upper": [[[0.0, 0.75, -0.36], [0.95, 0.9, 0.16]], [[-0.42, 0.42, 0.0], [0.14, 0.26, 0.7]], [[0.42, 0.42, 0.0], [0.14, 0.26, 0.7]]]}},
	"kitchen_bench": {"turn": 0.0, "couch": false, "seating": {
		"seats": [[-0.36, 0.26, 0.0], [0.36, 0.26, 0.0]], "depth": 0.35,
		"solid": [[[0.0, 0.13, 0.0], [1.42, 0.26, 0.35]]], "upper": []}},
}

## Seat frame for one set prop (SET_SEATING): turned so its +Z is the sitter's facing, at the
## model's world scale so the specs stay in metres. Replaces the prop's whole-box solid.
func _add_set_seating(model: Node3D, box: AABB, spec: Dictionary) -> void:
	var turn := Node3D.new(); turn.name = "SeatTurn"; turn.rotation.y = float(spec.turn)
	model.add_child(turn)
	var k: float = model.global_basis.get_scale().x
	FURNISHER._add_seating(turn, spec.seating, turn.transform.affine_inverse() * box, k, bool(spec.couch))

func _build_decor() -> void:
	# The set's own furniture, at its own scale under the set node.
	var interior := get_node("ShowInterior") as Node3D
	for index in SET_PROPS.size():
		var row: Array = SET_PROPS[index]
		var model := (load(INTERIOR_DIR + str(row[0]) + ".glb") as PackedScene).instantiate() as Node3D
		model.name = "Set_%s_%d" % [row[0], index]
		model.position = Vector3(row[1], SET_FLOOR + float(row[4]), -float(row[2]))
		model.rotation.y = float(row[3])
		interior.add_child(model)
		model.add_to_group("house_furniture"); model.set_meta("house", home); model.set_meta("furniture", str(row[0]))
		var box := _model_box(model)
		# The set's standing lamp was only a model: windows glowed at night over a dark room (player
		# bug board #33, 2026-10-28). The kit lamp runtime lights it at night and lets Anon switch it.
		if str(row[0]) == "standing_lamp":
			var lamp := LAMP.attach(model, "cone_lamp")
			var bulb := lamp.get_node_or_null("LampLight") as Node3D
			if bulb is OmniLight3D:
				# The one lamp lights the sitting room and the kitchen end, not just its corner.
				bulb.position = Vector3(box.get_center().x, box.end.y - .25, box.get_center().z)
				(bulb as OmniLight3D).omni_range = 6.5
		if SET_SEATING.has(str(row[0])):
			_add_set_seating(model, box, SET_SEATING[str(row[0])])
		elif bool(row[5]):
			var solid := BoxShape3D.new(); solid.size = box.size
			var body := StaticBody3D.new(); body.name = "FurnitureSolid"; body.collision_mask = 0
			var holder := CollisionShape3D.new(); holder.shape = solid; holder.position = box.get_center()
			body.add_child(holder); model.add_child(body)
		if bool(row[5]):
			for x: float in [-1., 1.]:
				for z: float in [-1., 1.]:
					var corner := box.get_center() + Vector3(x * (box.size.x * .5 + .55), -box.size.y * .5, z * (box.size.z * .5 + .55))
					home.waypoints.append(home.to_local(model.to_global(corner)))
	# The readable shelf books (shared shelf API) on one bookcase against the main room's front
	# wall, between the kitchen wall and the sofa.
	data.furnishings = [{"id": "bookshelf", "position": _set_point(READING_SHELF), "yaw": _set_yaw(PI), "flat": false}]
	# Reuse the household kit's metre sizing and physical stool seats, without
	# invoking its procedural room layout or modifying any shared asset/resource.
	FURNISHER.load_kit()
	for index in data.furnishings.size():
		var spec: Dictionary = data.furnishings[index]
		var id := str(spec.id)
		var model := FURNISHER._scene(id).instantiate() as Node3D
		var box: AABB = FURNISHER._model_box(id, model)
		var suggested: Vector3 = FURNISHER._sizes[id]
		var k := suggested[suggested.max_axis_index()] / box.size[box.size.max_axis_index()]
		var size: Vector3 = box.size * k
		model.scale = Vector3.ONE * k
		model.position = -Vector3(box.get_center().x, box.position.y, box.get_center().z) * k
		var prop := Node3D.new(); prop.name = "Furnishing_%s_%d" % [id, index]
		prop.position = spec.position; prop.position.y = data.floor_y; prop.rotation.y = spec.yaw
		prop.set_meta("house", home); prop.set_meta("furniture", id)
		prop.set_meta("decor_size", size); prop.set_meta("flat", bool(spec.flat))
		prop.add_to_group("house_furniture"); prop.add_to_group("fluttershy_furnishings")
		var kit: Dictionary = FURNISHER._kit.props[id]
		var seating: Dictionary = kit.get("seating", {})
		if not seating.is_empty(): FURNISHER._add_seating(model, seating, box, k)
		elif not spec.flat:
			var solid := BoxShape3D.new(); solid.size = size
			_collision(prop, "FurnitureSolid", solid, Vector3.UP * size.y * .5)
		prop.add_child(model); add_child(prop)
		if id == "bookshelf":
			var shelf := Node3D.new(); shelf.name = "Books"; prop.add_child(shelf)
			var shelf_rng := RandomNumberGenerator.new(); shelf_rng.seed = hash("books:%s:%d" % [home.place_id(), index])
			FURNISHER.SHELF_BOOKS.fill(shelf, FURNISHER._kit.shelves[id], shelf_rng, "%s:%d" % [home.place_id(), index], 1.0)
		if not spec.flat:
			for x: float in [-1., 1.]:
				for z: float in [-1., 1.]:
					home.waypoints.append(home.to_local(prop.to_global(Vector3(x * (size.x * .5 + .50), 0, z * (size.z * .5 + .50)))))

## A model's mesh bounds in its own frame.
static func _model_box(model: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		var b := _relative(model, mesh) * mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box

func _collision(parent: Node3D, label_text: String, shape: Shape3D, at := Vector3.ZERO) -> void:
	var body := StaticBody3D.new(); body.name = label_text; body.collision_mask = 0
	# Roof rays must not become outdoor resident spawn support. The floor remains
	# available through HouseInterior.contains(), including recovery from below it.
	if label_text in ["SourceWalls", "CeilingSolid"]: body.set_meta("building_design", "fluttershy_cottage")
	var holder := CollisionShape3D.new(); holder.shape = shape; holder.position = at
	body.add_child(holder); parent.add_child(body)

static func _v3(value: Array) -> Vector3: return Vector3(value[0], value[1], value[2])
