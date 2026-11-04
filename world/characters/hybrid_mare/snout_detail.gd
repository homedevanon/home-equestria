extends RefCounted
## Attach rest-space coordinates to the native head, without changing shape,
## weights or UVs. Only its authored Snout surfaces use the shader detail.
## Source head mesh -> prepared copy. Every head of a model shares the source mesh, so the copy
## (a readback and re-upload of the whole 21k-triangle head) is built once instead of per spawn;
## nothing edits it afterwards (materials are per-instance overrides).
static var _prepared := {}

static func prepare(mi: MeshInstance3D) -> void:
	if mi.has_meta("snout_detail"): return
	if mi.mesh.has_meta("snout_detail"):
		mi.set_meta("snout_detail", true)
		return
	var source := mi.mesh as ArrayMesh
	var cached: ArrayMesh = _prepared.get(source)
	if cached != null:
		mi.mesh = cached
		mi.set_meta("snout_detail", true)
		return
	var result := ArrayMesh.new()
	result.blend_shape_mode = source.blend_shape_mode
	for i in source.get_blend_shape_count(): result.add_blend_shape(source.get_blend_shape_name(i))
	for i in source.get_surface_count():
		var arrays := source.surface_get_arrays(i)
		var flags := source.surface_get_format(i) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		var material := source.surface_get_material(i)
		if material != null and "snout" in material.resource_name.to_lower():
			var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var data := PackedFloat32Array()
			data.resize(points.size() * 4)
			for v in points.size():
				data[v*4] = points[v].x
				data[v*4+1] = points[v].y
				data[v*4+2] = points[v].z
				data[v*4+3] = smoothstep(0.852, 0.862, points[v].y) * smoothstep(0.35, 0.8, normals[v].y)
			arrays[Mesh.ARRAY_CUSTOM0] = data
			flags |= Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
		# Preserve the head's facial surface too: simplifying it independently
		# from the retained sclera/iris/lids can cover those close layers again.
		result.add_surface_from_arrays(source.surface_get_primitive_type(i), arrays,
			source.surface_get_blend_shape_arrays(i), {}, flags)
		result.surface_set_material(i, material)
	_prepared[source] = result
	mi.mesh = result
	mi.set_meta("snout_detail", true)


static func dress(mi: MeshInstance3D) -> void:
	for i in mi.mesh.get_surface_count():
		var source := mi.mesh.surface_get_material(i)
		if source != null and "snout" in source.resource_name.to_lower():
			var mat := mi.get_active_material(i) as ShaderMaterial
			if mat != null: mat.set_shader_parameter("native_snout_detail", true)
