extends Node3D
## Restores the source's two painted leaves as actual hinged, grabbable doors.
const SHELL := preload("res://world/buildings/hayburger/hayburger_shell.gd")
const DOOR := preload("res://world/buildings/hayburger/hayburger_door.gd")
var building: Node3D
var report: Dictionary
var doors: Array[Node3D] = []
var business_open := false
var _notice: Label3D
var _materials: Dictionary = {}
## Door-window sign (dev 2026-10-14): "skibidi" in the daytime and "toilet" at night, like the
## restaurant in the town it comes from. Hangs on the right leaf's glass and swings with the door.
const SIGN_FONT := preload("res://world/ui/fonts/PonyvilleMedium.ttf")
const DAY_WORD := "SKIBIDI"
const NIGHT_WORD := "TOILET"
const PAINTED_SIGN := Vector3(0.993, 2.76, -4.056)
var daytime := true
var _door_words: Array[Label3D] = []

func _ready() -> void:
	var state: Dictionary = building.get_meta(SHELL.STATE)
	var source: ArrayMesh = state.mesh
	var view: MeshInstance3D = state.view
	# The details atlas includes the rooftop sign. Preserve its colours/UVs, but
	# remove baked self-illumination so sun, moon and actual lamps light it normally.
	for s: int in source.get_surface_count():
		var mat: Material = source.surface_get_material(s)
		if mat is BaseMaterial3D:
			var copy: BaseMaterial3D = mat.duplicate()
			copy.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			copy.emission_enabled = false
			view.set_surface_override_material(s, copy)
			_materials[s] = copy
	# The painted glass rebuilt around the street windows takes the same lit material.
	var surround: MeshInstance3D = building.get_node_or_null("StreetWindowSurround") as MeshInstance3D
	if surround != null:
		for s: int in _materials:
			if source.surface_get_material(s).resource_name == SHELL.GLASS: surround.material_override = _materials[s]
	for left: bool in [true, false]: _build_leaf(source, left)
	_build_notice()
	_build_door_sign()
	set_open(false)

func _build_leaf(source: ArrayMesh, left: bool) -> void:
	var envelope: AABB = report.leaf_envelope
	var centre: float = report.front_door_point.x
	var by_surface: Dictionary = {}
	var points := PackedVector3Array()
	for s: int in source.get_surface_count():
		var material: Material = source.surface_get_material(s)
		if material.resource_name not in [SHELL.DETAILS, SHELL.GLASS]: continue
		var arrays: Array = source.surface_get_arrays(s)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var selected := PackedInt32Array()
		for i: int in range(0, indices.size(), 3):
			var a: Vector3 = vertices[indices[i]]
			var b: Vector3 = vertices[indices[i+1]]
			var c: Vector3 = vertices[indices[i+2]]
			if not (SHELL._contains(envelope,a) and SHELL._contains(envelope,b) and SHELL._contains(envelope,c)): continue
			if ((a.x+b.x+c.x)/3.0 < centre) != left: continue
			selected.append_array([indices[i], indices[i+1], indices[i+2]])
			points.append_array([a,b,c])
		if not selected.is_empty(): by_surface[s] = selected
	if points.is_empty(): return
	var bounds: AABB = SHELL._bounds(points)
	var frame := Node3D.new()
	frame.name = "LeftJamb" if left else "RightJamb"
	frame.position = Vector3(bounds.position.x if left else bounds.end.x, report.floor_y, bounds.get_center().z)
	frame.rotation.y = 0.0 if left else PI
	add_child(frame)
	var inverse: Transform3D = frame.transform.affine_inverse()
	var door: AnimatableBody3D = DOOR.new()
	door.name = "LeftDoor" if left else "RightDoor"
	door.entrance = self
	# Both swing out towards the street, clear of the finished room's inner jambs.
	door.swing_direction = 1.0 if left else -1.0
	door.handle = Vector3(bounds.size.x - .20, 1.10, 0)
	var mesh := ArrayMesh.new()
	for s: int in by_surface:
		var arrays: Array = source.surface_get_arrays(s)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var tool := SurfaceTool.new(); tool.begin(Mesh.PRIMITIVE_TRIANGLES)
		var material: BaseMaterial3D = _materials[s].duplicate()
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		tool.set_material(material)
		for index: int in by_surface[s]:
			tool.set_normal(inverse.basis * normals[index])
			if not uvs.is_empty(): tool.set_uv(uvs[index])
			tool.add_vertex(inverse * vertices[index])
		tool.index(); tool.commit(mesh)
	var art := MeshInstance3D.new(); art.name = "OriginalDoorArtwork"; art.mesh = mesh; door.add_child(art)
	var shape := BoxShape3D.new(); shape.size = mesh.get_aabb().size.max(Vector3(.01,.01,.07))
	var collision := CollisionShape3D.new(); collision.name = "LeafCollision"
	collision.shape = shape; collision.position = mesh.get_aabb().get_center(); door.add_child(collision)
	door.navigation_box = AABB(Vector3(-.1,-.1,-bounds.size.x),Vector3(bounds.size.x+.2,bounds.size.y+.2,bounds.size.x*2))
	frame.add_child(door); doors.append(door)

func _build_notice() -> void:
	var at: Vector3 = report.front_door_point + Vector3(-2.18,1.65,-.16)
	var board := MeshInstance3D.new(); board.name = "OpeningHoursBoard"
	var mesh := BoxMesh.new(); mesh.size = Vector3(.85,.50,.04)
	var material := StandardMaterial3D.new(); material.albedo_color = Color("345448"); material.roughness = .9
	board.mesh = mesh; board.material_override = material; board.position = at; add_child(board)
	_notice = Label3D.new(); _notice.name = "OpeningHours"
	_notice.position = at + Vector3(0,0,-.024); _notice.rotation.y = PI
	_notice.font_size = 40; _notice.pixel_size = .0028; _notice.outline_size = 0
	_notice.modulate = Color("ffebba"); _notice.shaded = true
	add_child(_notice)

func _build_door_sign() -> void:
	if doors.size() < 2: return
	# The source glass paints a small "Skibidi" plaque on the right leaf (surveyed in Blender,
	# art-source/hayburger-2026-10-14): building-local centre below, 0.65 x 0.29 m.
	# The physical sign covers it exactly, so the word really changes at night.
	var door: Node3D = doors[1]
	var frame: Node3D = door.get_parent() as Node3D
	var to_leaf: Transform3D = frame.transform.affine_inverse()
	var outward: Vector3 = (to_leaf.basis * Vector3.FORWARD).normalized()
	var sign := Node3D.new(); sign.name = "DoorWindowSign"
	sign.transform = Transform3D(Basis.looking_at(-outward, Vector3.UP), to_leaf * PAINTED_SIGN + outward * .014)
	door.add_child(sign)
	var rim_paint := StandardMaterial3D.new(); rim_paint.albedo_color = Color("b0503d"); rim_paint.roughness = .8
	var paint := StandardMaterial3D.new(); paint.albedo_color = Color("fff0d2"); paint.roughness = .8
	for part: Array in [["SignRim", Vector3(.72, .34, .010), Vector3(0, 0, -.004), rim_paint], ["SignBoard", Vector3(.66, .28, .012), Vector3(0, 0, .004), paint]]:
		var board := MeshInstance3D.new(); board.name = part[0]
		var plate := BoxMesh.new(); plate.size = part[1]
		board.mesh = plate; board.material_override = part[3]; board.position = part[2]
		board.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sign.add_child(board)
	# Two short cords up to the glass frame.
	for side: float in [-1.0, 1.0]:
		var cord := MeshInstance3D.new(); cord.name = "SignCord"
		var cord_mesh := CylinderMesh.new(); cord_mesh.top_radius = .005; cord_mesh.bottom_radius = .005; cord_mesh.height = .18
		cord.mesh = cord_mesh; cord.material_override = rim_paint
		cord.position = Vector3(side * .14, .24, -.004); cord.rotation.z = -side * .5
		sign.add_child(cord)
	# Readable from the street (the sign's +Z) and, the same word, from inside the restaurant.
	for street: bool in [true, false]:
		var words := Label3D.new(); words.name = "SignWordOutside" if street else "SignWordInside"
		words.font = SIGN_FONT; words.font_size = 72; words.pixel_size = .0016
		words.modulate = Color("8c2f39"); words.outline_size = 0; words.shaded = true
		words.double_sided = false
		words.position.z = .0115 if street else -.0105
		if not street: words.rotation.y = PI
		sign.add_child(words); _door_words.append(words)
	set_daytime(daytime, true)

## Switches the door sign's word at sunrise and sunset.
func set_daytime(value: bool, force := false) -> void:
	if value == daytime and not force: return
	daytime = value
	for words: Label3D in _door_words:
		words.text = DAY_WORD if daytime else NIGHT_WORD

func door_sign_text() -> String:
	return _door_words[0].text if not _door_words.is_empty() else ""

func set_open(value: bool) -> void:
	business_open = value
	_notice.text = ("OPEN" if value else "CLOSED") + "\n8 am – 10 pm"
	for door: Node3D in doors:
		door.locked = not value
		door._close_after_passage = not value
		door._close_delay = 2.0 if not value else 0.0
		if not value: door._visitors.clear()
		if not is_instance_valid(door.holder): door.target = PI * .5 if value else 0.0

## Customers reach the counter on ordinary walk-grid routes through this doorway (the houses' doors
## are crossed on authored lines instead). The grid keeps whatever the leaves were doing when it
## sampled the doorway, and a door that opens never resamples it: sampled shut overnight, or in the
## first second after load before the leaves swing open, it kept a wall across the entrance all day
## and every customer turned back at the door with "No safe route: Search budget reached" (thread
## reports since 0.3.0; tools/interiors_nav/test_hayburger_overnight.gd). Once both leaves have come
## to rest open, the doorway is resampled; closing is resampled by hinged_door.gd already
## (door_settled_shut). Rollback: RESAMPLE_ON_OPEN = false.
const RESAMPLE_ON_OPEN := true
## A player swinging the leaves back and forth resamples at most this often (seconds).
const RESAMPLE_INTERVAL_MS := 5000
var _grid_open := false
var _grid_resampled_ms := -RESAMPLE_INTERVAL_MS

## Called by hayburger_runtime.gd every 0.25 s with the business-hours check.
func tend_navigation() -> void:
	if not RESAMPLE_ON_OPEN or doors.is_empty() or not is_inside_tree(): return
	var open := true
	for door: Node3D in doors:
		var limit: float = door.open_limit()
		if is_instance_valid(door.holder) or absf(door.opening_angle() - limit) > .01 or absf(float(door.target) - limit) > .01: open = false
	if not open:
		_grid_open = false
		return
	if _grid_open: return
	var now := Time.get_ticks_msec()
	if now - _grid_resampled_ms < RESAMPLE_INTERVAL_MS: return
	_grid_open = true
	_grid_resampled_ms = now
	var box := AABB()
	for i in doors.size():
		var leaf: AABB = doors[i].navigation_world_box()
		box = leaf if i == 0 else box.merge(leaf)
	box = box.grow(.5)
	for service: Node in get_tree().get_nodes_in_group("pony_navigation"):
		if service.has_method("notify_geometry_changed"): service.notify_geometry_changed(box)

func is_inside(point: Vector3) -> bool:
	return building.to_local(point).z > float(report.front_door_point.z) + .015

func offer_passage(actor: Node3D) -> void:
	if not is_instance_valid(actor): return
	var at: Vector3 = building.to_local(actor.global_position)
	var entrance: Vector3 = report.front_door_point
	if absf(at.x-entrance.x) > 2.5 or absf(at.z-entrance.z) > 3.0 or absf(at.y-entrance.y) > 3.0: return
	for door: Node3D in doors: door.request_passage(actor)

## Finish existing visits before latching. No new customers are admitted at night.
func keep_exit_open() -> void:
	for door: Node3D in doors:
		if not is_instance_valid(door.holder):
			door.target = PI * .5
			door._close_delay = 1.0
