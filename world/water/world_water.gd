class_name WorldWater
extends Node3D
## The world's water: one sea plane at the layout's sea level, river ribbons and lake discs
## from the generator's world/water/*.json. All of it is static, shares the toon water shader
## (ocean parameters for the sea, river parameters for rivers), joins group `navigation_water`
## and carries a collision body on the navigation water layer (bit 16) so the walk grid reads
## depth. Created beside WorldTerrain by ZoneManager.setup.

const TOON_WATER := "res://addons/godotshaders/toon_water.gdshader"
const RIVERS := "res://world/water/rivers.json"
const LAKES := "res://world/water/lakes.json"
## Water in Ponyville's canal trenches, a height grid derived from the terrain
## (tools/terrain_fix/build_canal_water.py).
const CANALS := "res://world/water/ponyville_canals.json"
const WATER_MASK := 1 << 15
const RIVER_SUPPORT := preload("res://world/water/river_support.gd")
const SEA_SIZE := 26000.0
## The game and the ocean lab turn this on: the sea is then drawn by WorldOcean (FFT waves, shore
## surf) when Settings "video/ocean" is "fft" and a RenderingDevice exists. Off by default so the
## offline tools (aerial map, town bakes) keep photographing the flat toon sea.
static var use_fft_ocean := false
static var instance: WorldWater
var ocean: Node3D
var _sea: MeshInstance3D
var sea_level := -80.0
var river_audit: Dictionary = {}
## Seasons (W2-SEAS-G): the still water that can freeze over (lake discs, Ponyville canals) and every
## toon water material made here, read by res://world/seasons/ice_slabs.gd (walkable ice slabs, the
## ice look's ice_solid uniform, rain ripples). Shader ice_kind: 0 sea, 1 still, 2 river.
const ICE_NONE := 0
const ICE_STILL := 1
const ICE_RIVER := 2
var still_water: Array[MeshInstance3D] = []
var water_materials: Array[ShaderMaterial] = []


static func ensure(parent: Node) -> WorldWater:
	if is_instance_valid(instance) and instance.is_inside_tree():
		return instance
	var node := WorldWater.new()
	node.name = "WorldWater"
	parent.add_child(node)
	return node


func _ready() -> void:
	instance = self
	var lakes_doc: Variant = _load_json(LAKES)
	if lakes_doc is Dictionary:
		sea_level = float(lakes_doc.get("sea_level", WorldLayout.sea_level()))
	else:
		sea_level = WorldLayout.sea_level()
	_build_sea()
	if lakes_doc is Dictionary:
		for lake in lakes_doc.get("lakes", []):
			_build_lake(lake)
	var rivers_doc: Variant = _load_json(RIVERS)
	if rivers_doc is Dictionary:
		for river in rivers_doc.get("rivers", []):
			_build_river(river)
	var canals_doc: Variant = _load_json(CANALS)
	if canals_doc is Dictionary:
		_build_canals(canals_doc)


func _exit_tree() -> void:
	if instance == self:
		instance = null


static func _load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _material(sea: bool, ice_kind := ICE_NONE) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load(TOON_WATER)
	material.set_shader_parameter("ice_kind", ice_kind)
	water_materials.append(material)
	if sea:
		material.set_shader_parameter("wave_amplitude", 0.35)
		material.set_shader_parameter("wave_frequency", 0.12)
		material.set_shader_parameter("tile", Vector2(600.0, 600.0))
		material.set_shader_parameter("distortion_speed", 0.6)
		material.set_shader_parameter("water_transparency", 0.55)
		material.set_shader_parameter("water_depth_factor", 0.08)
		material.set_shader_parameter("foam_width", 1.2)
	else:
		material.set_shader_parameter("wave_amplitude", 0.03)
		material.set_shader_parameter("wave_frequency", 0.9)
		material.set_shader_parameter("tile", Vector2(18.0, 18.0))
		material.set_shader_parameter("distortion_speed", 1.2)
		material.set_shader_parameter("water_transparency", 0.75)
		material.set_shader_parameter("water_depth_factor", 0.35)
		material.set_shader_parameter("foam_width", 0.35)
	return material


func _add_water(mesh: Mesh, name: String, sea: bool, xform := Transform3D.IDENTITY, ice_kind := ICE_NONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = mesh
	mi.transform = xform
	mi.material_override = _material(sea, ice_kind)
	if ice_kind == ICE_STILL: still_water.append(mi)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.add_to_group("navigation_water")
	add_child(mi)
	var body := StaticBody3D.new()
	body.name = name + "Depth"
	body.collision_layer = WATER_MASK
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	shape.shape = mesh.create_trimesh_shape()
	body.add_child(shape)
	mi.add_child(body)
	return mi


func _build_sea() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(SEA_SIZE, SEA_SIZE)
	plane.subdivide_width = 64
	plane.subdivide_depth = 64
	var centre := Vector3(500.0, sea_level, -500.0)
	_sea = _add_water(plane, "Sea", true, Transform3D(Basis.IDENTITY, centre))
	var settings := get_node_or_null("/root/Settings")
	if settings != null and not settings.changed.is_connected(_on_setting_changed):
		settings.changed.connect(_on_setting_changed)
	var quality := get_node_or_null("/root/Quality")
	if quality != null and not quality.preset_changed.is_connected(_on_quality_changed):
		quality.preset_changed.connect(_on_quality_changed)
	_apply_ocean_setting()


## The sea's look: FFT ocean or the classic toon plane. The plane keeps its collision either way.
func _apply_ocean_setting() -> void:
	var settings := get_node_or_null("/root/Settings")
	var quality := get_node_or_null("/root/Quality")
	# Settings "Ocean": Follow preset (quality.gd ocean, classic on Very Low), or forced fft / classic.
	var choice := str(settings.get_value("video/ocean")) if settings != null else "preset"
	if choice == "preset": choice = str(quality.get_value("ocean", "fft")) if quality != null else "fft"
	var wanted: bool = use_fft_ocean and preload("res://world/water/ocean/ocean_fft.gd").available() and choice == "fft"
	# A tier change with a different cascade count rebuilds the FFT ocean.
	if wanted and is_instance_valid(ocean) and quality != null and ocean.fft != null and ocean.fft.cascades != mini(int(quality.get_value("ocean_cascades", 4)), 3 if preload("res://world/player_view.gd").viewport(self).use_xr else 4):
		ocean.queue_free(); ocean = null
	if wanted and not is_instance_valid(ocean):
		ocean = preload("res://world/water/ocean/world_ocean.gd").new()
		ocean.name = "Ocean"
		ocean.setup(sea_level)
		add_child(ocean)
	elif not wanted and is_instance_valid(ocean):
		ocean.queue_free()
		ocean = null
	if is_instance_valid(_sea): _sea.visible = not wanted


func _on_setting_changed(key: String) -> void:
	if key == "video/ocean": _apply_ocean_setting()


func _on_quality_changed(_preset: int) -> void:
	_apply_ocean_setting()


func _build_lake(lake: Dictionary) -> void:
	var c: Array = lake.center
	var disc := CylinderMesh.new()
	disc.top_radius = float(lake.radius)
	disc.bottom_radius = float(lake.radius)
	disc.height = 0.02
	disc.radial_segments = 48
	disc.rings = 1
	_add_water(disc, "Lake_" + String(lake.id), false, Transform3D(Basis.IDENTITY, Vector3(float(c[0]), float(c[1]), float(c[2]))), ICE_STILL)


## A ribbon along the river's surface polyline (points carry the surface height).
func _build_river(river: Dictionary) -> void:
	var points: Array = river.points
	if points.size() < 2:
		return
	var half := float(river.get("width", 16.0)) * 0.5
	var strips: Array = [points]
	if is_instance_valid(WorldTerrain.instance):
		var result := RIVER_SUPPORT.sections(points, half, WorldTerrain.instance.height_at)
		strips = result.strips
		river_audit[river.id] = {"accepted_segments": result.accepted, "unsupported_segments": result.rejected}
		if result.rejected > 0:
			print("[water] ", river.id, ": ", result.rejected, " unsupported generated segments excluded; ", result.accepted, " supported segments retained")
	for i in strips.size():
		var serial: Array = []
		for p in strips[i]: serial.append([p.x, p.y, p.z] if p is Vector3 else p)
		_build_ribbon(serial, half, "River_%s_%d" % [river.id, i])


func _build_ribbon(points: Array, half: float, name: String) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := points.size()
	var left := PackedVector3Array()
	var right := PackedVector3Array()
	for i in n:
		var p := Vector3(float(points[i][0]), float(points[i][1]), float(points[i][2]))
		var prev := p if i == 0 else Vector3(float(points[i - 1][0]), float(points[i - 1][1]), float(points[i - 1][2]))
		var next := p if i == n - 1 else Vector3(float(points[i + 1][0]), float(points[i + 1][1]), float(points[i + 1][2]))
		var dir := Vector3(next.x - prev.x, 0.0, next.z - prev.z).normalized()
		var side := Vector3(-dir.z, 0.0, dir.x) * half
		left.append(p + side)
		right.append(p - side)
	for i in n - 1:
		var uv0 := float(i) / float(n - 1)
		var uv1 := float(i + 1) / float(n - 1)
		st.set_uv(Vector2(0.0, uv0)); st.add_vertex(left[i])
		st.set_uv(Vector2(1.0, uv0)); st.add_vertex(right[i])
		st.set_uv(Vector2(1.0, uv1)); st.add_vertex(right[i + 1])
		st.set_uv(Vector2(0.0, uv0)); st.add_vertex(left[i])
		st.set_uv(Vector2(1.0, uv1)); st.add_vertex(right[i + 1])
		st.set_uv(Vector2(0.0, uv1)); st.add_vertex(left[i + 1])
	st.generate_normals()
	_add_water(st.commit(), name, false, Transform3D.IDENTITY, ICE_RIVER)


## A surface over a height grid (NaN = dry), meshed every `STRIDE` samples. Triangles need
## all three corners wet; the grid already reaches a few metres under the banks.
func _build_canals(doc: Dictionary) -> void:
	const STRIDE := 2
	var w := int(doc.width)
	var d := int(doc.depth)
	var cell := float(doc.cell)
	var heights := Marshalls.base64_to_raw(String(doc.heights)).to_float32_array()
	if heights.size() != w * d:
		push_warning("[water] canal grid size mismatch; canals skipped")
		return
	var ox := float(doc.origin[0])
	var oz := float(doc.origin[1])
	var cols := (w - 1) / STRIDE + 1
	var rows := (d - 1) / STRIDE + 1
	var index := PackedInt32Array()
	index.resize(cols * rows)
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	for r in rows:
		for c in cols:
			var y := heights[r * STRIDE * w + c * STRIDE]
			if is_nan(y):
				index[r * cols + c] = -1
				continue
			index[r * cols + c] = verts.size()
			verts.append(Vector3(ox + c * STRIDE * cell, y, oz + r * STRIDE * cell))
			uvs.append(Vector2(float(c * STRIDE) / float(w), float(r * STRIDE) / float(d)))
	var tris := PackedInt32Array()
	for r in rows - 1:
		for c in cols - 1:
			var a := index[r * cols + c]
			var b := index[r * cols + c + 1]
			var e := index[(r + 1) * cols + c]
			var f := index[(r + 1) * cols + c + 1]
			if a >= 0 and b >= 0 and f >= 0: tris.append_array([a, b, f])
			if a >= 0 and f >= 0 and e >= 0: tris.append_array([a, f, e])
			elif a < 0 and b >= 0 and f >= 0 and e >= 0: tris.append_array([b, f, e])
			if a >= 0 and b >= 0 and e >= 0 and f < 0: tris.append_array([a, b, e])
	if tris.is_empty():
		return
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	normals.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = tris
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_add_water(mesh, "PonyvilleCanals", false, Transform3D.IDENTITY, ICE_STILL)
	print("[water] Ponyville canals: ", tris.size() / 3, " triangles")
