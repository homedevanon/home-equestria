extends RefCounted
## Distant trees as one quad each: pictures of the full tree from 16 directions
## (tools/impostors/bake_trees.gd), lit by the scene like the tree. painted_tree_batches.gd
## draws a far tile's trees as their far mesh up to `from` metres and as impostors beyond it,
## with a FADE-wide dithered crossfade between the two (the far mesh gets fade-aware copies of
## its materials; both use the same screen dither so each pixel shows one or the other).
## dev: people see far, so trees are never dropped at distance, only drawn more cheaply.
const DIRECTORY := "res://world/foliage/impostors/trees/"
const SHADER := preload("res://world/foliage/impostors/tree_impostor.gdshader")
const FAR_BARK := preload("res://world/foliage/impostors/far_bark_fade.gdshader")
const FAR_CROWN := "far_crown.gdshader"
## Camera-to-root distance where impostors take over (the centre of the crossfade).
const FROM := 500.0
const FADE := 40.0
## The Everfree hands over much sooner (dev 2026-10-01: "the everfree is so thick that we wouldnt
## even need to see trees that are too far away"): its own crowded trunks hide the difference.
const EVERFREE_FROM := 80.0
static var from := FROM
static var _manifest: Dictionary = {}
static var _meshes: Dictionary = {}
static var _fading: Dictionary = {}
static var _materials: Array = []   # [ShaderMaterial, tree id]

## Crossfade band in metres from the camera to a tree root.
static func band() -> Vector2:
	return Vector2(from - FADE * 0.5, from + FADE * 0.5)

## The hand-over for one tree species: the quality tier's, or the Everfree's when nearer.
static func from_for(id: String) -> float:
	return minf(from, EVERFREE_FROM) if id.begins_with("everfree_") else from

static func band_for(id: String) -> Vector2:
	var at := from_for(id)
	return Vector2(at - FADE * 0.5, at + FADE * 0.5)

## Moves the hand-over (a very large value keeps every tree a far mesh). Callers re-sync tiles.
static func set_from(distance: float) -> void:
	from = distance
	for row: Array in _materials: (row[0] as ShaderMaterial).set_shader_parameter("impostor_fade", band_for(str(row[1])))

## The impostor quad of a baked tree, or null.
static func mesh(id: String) -> Mesh:
	if _meshes.has(id): return _meshes[id]
	if _manifest.is_empty() and FileAccess.file_exists(DIRECTORY + "manifest.json"):
		_manifest = JSON.parse_string(FileAccess.get_file_as_string(DIRECTORY + "manifest.json"))
	var result: Mesh = null
	if _manifest.has(id) and ResourceLoader.exists(DIRECTORY + id + "_albedo.res"):
		var spec: Dictionary = _manifest[id]
		var material := ShaderMaterial.new(); material.shader = SHADER
		material.set_shader_parameter("albedo_atlas", load(DIRECTORY + id + "_albedo.res"))
		material.set_shader_parameter("normal_atlas", load(DIRECTORY + id + "_normal.res"))
		for key in ["frames", "grid", "quad_size", "quad_centre_y", "max_lod"]:
			material.set_shader_parameter(key, float(spec[key]))
		# The sakura impostor blossoms with its tree (W2-SEAS-D H2).
		if preload("res://world/foliage/vegetation_materials.gd").is_blossom(id): material.set_shader_parameter("blossom_tree", 1.0)
		_register(material, id)
		var side := float(spec.quad_size); var centre := float(spec.quad_centre_y)
		var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
		# The shader places the corners from UV; these positions only give sane bounds.
		var half := side * 0.5
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-half, centre + half, 0), Vector3(half, centre + half, 0),
			Vector3(half, centre - half, 0), Vector3(-half, centre - half, 0)])
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK])
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
		var quad := ArrayMesh.new()
		quad.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		quad.surface_set_material(0, material)
		# The quad turns about Y around the root.
		quad.custom_aabb = AABB(Vector3(-half, centre - half, -half), Vector3.ONE * side)
		result = quad
	_meshes[id] = result
	return result

## A copy of a far mesh whose materials dissolve into the impostor inside the crossfade band.
static func fading(source: Mesh, id := "") -> Mesh:
	if _fading.has(source): return _fading[source]
	var copy := source.duplicate() as Mesh
	for s in copy.get_surface_count():
		var original := copy.surface_get_material(s)
		var material: ShaderMaterial = null
		if original is ShaderMaterial and (original as ShaderMaterial).shader.resource_path.ends_with(FAR_CROWN):
			material = original.duplicate()
		elif original is BaseMaterial3D:
			material = ShaderMaterial.new(); material.shader = FAR_BARK
			material.set_shader_parameter("albedo_texture", (original as BaseMaterial3D).albedo_texture)
			material.set_shader_parameter("albedo_color", (original as BaseMaterial3D).albedo_color)
		elif original is ShaderMaterial:
			# any other tree shader (the Grassy Fields leaves and trunks): a copy that dissolves too
			var shader := _fade_shader((original as ShaderMaterial).shader)
			if shader != null:
				material = original.duplicate(); material.shader = shader
		if material == null:
			push_warning("impostors: far surface %d keeps its material without crossfade" % s); continue
		_register(material, id)
		copy.surface_set_material(s, material)
	_fading[source] = copy
	return copy

static var _fade_shaders: Dictionary = {}

## A copy of `source` with the impostor crossfade: the same screen dither as the impostor, so
## inside the band each pixel shows either the mesh or the impostor (dev 2026-09-26: the normal
## forest gets impostors like the Everfree).
static func _fade_shader(source: Shader) -> Shader:
	if source == null: return null
	if _fade_shaders.has(source): return _fade_shaders[source]
	var code := source.code
	var result: Shader = null
	if code.contains("impostor_fade_amount"):
		result = source
	elif code.contains("void fragment()"):
		var lines := code.split("\n")
		var out := PackedStringArray()
		var included := false
		for line in lines:
			out.append(line)
			if not included and (line.begins_with("render_mode") or (line.begins_with("shader_type") and not code.contains("render_mode"))):
				out.append('#include "res://world/foliage/impostors/impostor_fade.gdshaderinc"')
				out.append("varying float impostor_fade_t;")
				included = true
		code = "\n".join(out)
		var eye := "impostor_fade_t = impostor_fade_amount(MAIN_CAM_INV_VIEW_MATRIX[3].xyz, MODEL_MATRIX[3].xyz);"
		if code.contains("void vertex() {"):
			code = code.replace("void vertex() {", "void vertex() {\n\t" + eye)
		else:
			code += "\nvoid vertex() {\n\t" + eye + "\n}\n"
		code = code.replace("void fragment() {", "void fragment() {\n\tif (impostor_dither(FRAGCOORD.xy) < impostor_fade_t) { discard; }")
		if included:
			result = Shader.new(); result.code = code
	_fade_shaders[source] = result
	return result

static func _register(material: ShaderMaterial, id: String) -> void:
	material.set_shader_parameter("impostor_fade", band_for(id))
	_materials.append([material, id])
