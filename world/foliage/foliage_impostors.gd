extends RefCounted
## Offline views of the original meshes. Two triangles for a whole distant tree/bush.
const DIRECTORY := "res://world/foliage/impostors/"
const SHADER := preload("res://world/foliage/foliage_impostor.gdshader")
static var _manifest: Dictionary = {}
static var _parts: Dictionary = {}
static func parts(entry: Dictionary) -> Array:
	var id := str(entry.id)
	if _parts.has(id): return _parts[id]
	if _manifest.is_empty():
		_manifest = JSON.parse_string(FileAccess.get_file_as_string(DIRECTORY + "manifest.json"))
	if not _manifest.has(id): return []
	var spec: Dictionary = _manifest[id]
	var material := ShaderMaterial.new();material.shader=SHADER
	material.set_shader_parameter("atlas",load(DIRECTORY+id+".res"))
	# The older sakura foliage impostor blossoms too (W2-SEAS-D H3).
	if preload("res://world/foliage/vegetation_materials.gd").is_blossom(id):material.set_shader_parameter("blossom_tree",1.0)
	var mesh := QuadMesh.new();mesh.size=Vector2.ONE*float(spec.diameter);mesh.material=material
	# Conservative bounds for a camera-facing quad, including overhead views.
	mesh.custom_aabb=AABB(-Vector3.ONE*float(spec.diameter)*.5,Vector3.ONE*float(spec.diameter))
	var centre := Vector3(spec.centre[0],spec.centre[1],spec.centre[2])
	_parts[id]=[[mesh,Transform3D(Basis.IDENTITY,centre)]]
	return _parts[id]
