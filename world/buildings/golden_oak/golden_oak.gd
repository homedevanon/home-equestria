extends Node3D
## Existing Golden Oak exterior, doubled once, with a walk-in library and sleeping loft.
const SHELL := preload("res://world/buildings/golden_oak/shell.gd")
const INTERIOR := preload("res://world/buildings/golden_oak/interior.gd")
const HOME := preload("res://world/buildings/golden_oak/home.gd")
const WINDOWS := preload("res://world/buildings/golden_oak/windows.gd")
const STATIC_MERGE := preload("res://world/buildings/static_mesh_merge.gd")
const TRY := preload("res://world/perf/try_switch.gd")
var home: Node3D
var interior: Node3D

static func attach(existing: Node3D) -> Node3D:
	var installed := existing.get_node_or_null("UsableLibrary") as Node3D
	if installed != null: return installed
	var prepared: Dictionary = SHELL.prepare(existing)
	var runtime := load("res://world/buildings/golden_oak/golden_oak.gd").new() as Node3D
	runtime.name = "UsableLibrary"
	runtime.top_level = true
	existing.add_child(runtime)
	runtime.global_transform = prepared.frame
	runtime.interior = INTERIOR.new()
	runtime.interior.name = "LibraryInterior"
	runtime.add_child(runtime.interior)
	runtime.interior.build(prepared.layout)
	# Perf 0.1.0 (geometry): the shell's still pieces (lining, floor, ceiling, window trims,
	# mullions, curtains) as one mesh per look, like the furnishings (interior.gd MERGE_STATIC).
	if INTERIOR.MERGE_STATIC:
		STATIC_MERGE.merge(prepared.frame_node, [], [preload("res://world/buildings/golden_oak/reference_surface.gdshader")], "MergedShell",
			STATIC_MERGE.town_shadow_floor(existing))
	preload("res://world/props/candles/candles.gd").scatter(runtime.interior, "golden_oak")
	runtime.home = HOME.new()
	runtime.home.name = "HouseInterior"
	runtime.add_child(runtime.home)
	runtime.home.configure(prepared.layout, runtime.interior, prepared.door)
	if OCCLUDE_ROOM: runtime.add_child(_room_occluder())
	# Doorway plug (perf trial of 2026-11-24, default since 2026-11-25; off for one launch with
	# --try=no_library_door_occluder): see entrance_occluder.gd.
	if OCCLUDE_ROOM and not TRY.off("library_door_occluder"): runtime.add_child(preload("res://world/buildings/golden_oak/entrance_occluder.gd").create(runtime.home, prepared.door, OCCLUDER_RADIUS, OCCLUDER_TOP, OCCLUDER_OPEN))
	existing.set_meta("golden_oak_interior", true)
	return runtime

## Perf 0.1.0 (geometry): the library's round wall and ceiling as an occluder, like the Hayburger
## room's (2026-10-23). Inside, the town behind the trunk stopped drawing nothing: the bench view
## at the door drew 0.95 M triangles for a 0.1 M-triangle room. Outside, the furnished room (~350
## draws before merging) drew whenever the trunk was in view within 45 m. The occluder sits just
## behind everything in the room (shelf recess backs reach 5.40 m, the lining 5.01 m) and inside
## the bark (5.5 m and more). The entrance sector and both oval windows stay open, cut wider than
## the real openings (window size x1.25 + 0.35 m; entrance -27..31 degrees, full height), so
## nothing visible through them can be culled. The ceiling disc stops inside the real ceiling.
## Room frame metres (the runtime frame). false = no occluder (rollback / A-B).
const OCCLUDE_ROOM := true
const OCCLUDER_RADIUS := 5.45
const OCCLUDER_TOP := 7.30
const OCCLUDER_CEILING_RADIUS := 5.1
const OCCLUDER_OPEN := Vector2(-27.0, 31.0)

static func _room_occluder() -> OccluderInstance3D:
	var holes: Array[Rect2] = []   # x: angle (radians, 0..TAU), y: height
	for window: Dictionary in WINDOWS.definitions():
		var centre: Vector3 = window.centre
		var angle := fposmod(atan2(centre.x, centre.z), TAU)
		var half := Vector2((float(window.w) * 1.25 + .35) / OCCLUDER_RADIUS, float(window.h) * 1.25 + .35)
		holes.append(Rect2(Vector2(angle, centre.y) - half, half * 2.0))
	var first := deg_to_rad(OCCLUDER_OPEN.y)
	var last := TAU + deg_to_rad(OCCLUDER_OPEN.x)
	var angles: Array[float] = []
	for i in 81: angles.append(lerpf(first, last, i / 80.0))
	var heights: Array[float] = [0.0, OCCLUDER_TOP]
	for hole: Rect2 in holes:
		for edge: float in [hole.position.x, hole.end.x]:
			if edge > first and edge < last: angles.append(edge)
		for edge: float in [hole.position.y, hole.end.y]:
			if edge > 0.0 and edge < OCCLUDER_TOP: heights.append(edge)
	angles.sort(); heights.sort()
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	for i in angles.size() - 1:
		var middle := (angles[i] + angles[i + 1]) * .5
		for j in heights.size() - 1:
			var cell := Vector2(middle, (heights[j] + heights[j + 1]) * .5)
			var open := false
			for hole: Rect2 in holes:
				if hole.has_point(cell): open = true; break
			if open: continue
			var base := vertices.size()
			for corner: Vector2 in [Vector2(angles[i], heights[j]), Vector2(angles[i + 1], heights[j]), Vector2(angles[i + 1], heights[j + 1]), Vector2(angles[i], heights[j + 1])]:
				vertices.append(Vector3(sin(corner.x) * OCCLUDER_RADIUS, corner.y, cos(corner.x) * OCCLUDER_RADIUS))
			indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var centre := vertices.size()
	vertices.append(Vector3(0, OCCLUDER_TOP, 0))
	for i in 49:
		var angle := TAU * i / 48.0
		vertices.append(Vector3(sin(angle) * OCCLUDER_CEILING_RADIUS, OCCLUDER_TOP, cos(angle) * OCCLUDER_CEILING_RADIUS))
		if i > 0: indices.append_array([centre, centre + i, centre + i + 1])
	var shape := ArrayOccluder3D.new()
	shape.set_arrays(vertices, indices)
	var occluder := OccluderInstance3D.new()
	occluder.name = "RoomOccluder"
	occluder.occluder = shape
	return occluder
