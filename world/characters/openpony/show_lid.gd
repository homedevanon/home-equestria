extends RefCounted
## Show lids (dev 2026-11-02): the expression's lid line is drawn ON the eye, like the show, where
## the line is the brow and everything above it is lid. The eye surface shader paints the lid and its
## line (show_eyes/iris.gdshader), and the lash ring hides the part of its outline the drawn lid
## covers (openpony_lashes.gdshader). Both work in one frame: the show-eye projection
## (tools/show_eyes/prepare.py), as "nose-x" (eye widths from the eye centre, + toward the nose)
## and v (eye heights, 0 at the top of the art, 1 at the bottom).
## A lid is [base, slant, saddle, line]: v = base + slant * x + saddle * x * x at nose-x x, and the
## line's thickness in v. A positive slant lowers the lid toward the nose; a positive saddle bends
## both ends down. The lower lid's fourth value at 1 opens the eye's nose end (no ring outline there).
## On the front view a constant v is level: the show-eye frame already accounts for the eye's turn.

const WIDTH := .110
const HEIGHT := .148
const CENTER_Y := .920
const CENTER_DEPTH := .357
const CENTER_X := .072
const TANGENT_SHIFT := .004

## Godot mesh space (the export's armature space) to the show-eye art UV, as prepare.py projects it.
static func eye_uv(p: Vector3) -> Vector2:
	var side := 1.0 if p.x > 0.0 else -1.0
	# prepare.py works in the source's Blender frame: (x, y, z) = (godot x, -godot z, godot y).
	var b := Vector3(p.x, -p.z, p.y)
	var tangent := Vector3(-side * .7071067812, .7071067812, 0.0)
	var center := Vector3(side * CENTER_X, CENTER_DEPTH, CENTER_Y) + tangent * TANGENT_SHIFT
	var u := (b - center).dot(tangent) / WIDTH + .5
	if side < 0.0: u = 1.0 - u
	return Vector2(u, .5 - (b.z - CENTER_Y) / HEIGHT)

## Nose-x and v of a mesh-space point.
static func lid_xy(p: Vector3) -> Vector2:
	var uv := eye_uv(p)
	return Vector2((uv.x - .5) * nose_sign(p.x), uv.y)

## +1 when the eye's nose side is toward +u (the eye on +x), -1 otherwise.
static func nose_sign(x: float) -> float:
	return 1.0 if x > 0.0 else -1.0

## The lash ring with each vertex's rest nose-x / v baked into CUSTOM0 (RG float): the ring judges its
## outline where it sits on the modelled, open eye, so the lid bones pulling it down onto a squeezed
## eye do not carry the upper outline into the drawn opening. One baked copy per source mesh.
static var _baked_rings := {}

static func baked_ring(mesh: Mesh) -> Mesh:
	if mesh.has_meta("show_lid_coordinates"): return mesh
	var source := mesh as ArrayMesh
	if source == null: return mesh
	if _baked_rings.has(source): return _baked_rings[source]
	var baked := ArrayMesh.new()
	baked.blend_shape_mode = source.blend_shape_mode
	for bi in source.get_blend_shape_count(): baked.add_blend_shape(source.get_blend_shape_name(bi))
	for si in source.get_surface_count():
		var arrays := source.surface_get_arrays(si)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var rest := PackedFloat32Array()
		rest.resize(verts.size() * 2)
		for i in verts.size():
			var xy := lid_xy(verts[i])
			rest[i * 2] = xy.x
			rest[i * 2 + 1] = xy.y
		arrays[Mesh.ARRAY_CUSTOM0] = rest
		var format := source.surface_get_format(si) & ~(Mesh.ARRAY_FORMAT_CUSTOM_MASK << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		format |= Mesh.ARRAY_CUSTOM_RG_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
		format &= Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS | Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE | Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES | (Mesh.ARRAY_FORMAT_CUSTOM_MASK << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		baked.add_surface_from_arrays(source.surface_get_primitive_type(si), arrays,
			source.surface_get_blend_shape_arrays(si), {}, format)
		baked.surface_set_material(si, source.surface_get_material(si))
		baked.surface_set_name(si, source.surface_get_name(si))
	baked.resource_name = source.resource_name
	_baked_rings[source] = baked
	return baked
