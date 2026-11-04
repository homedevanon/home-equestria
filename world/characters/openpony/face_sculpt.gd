extends RefCounted
## Blender-authored facial shape channels, shared by skin, sclera and lash ring.
## Expressions supply named weights, not vertex edits. Add matching shape keys to the
## authored meshes to extend the vocabulary; L/R channels also support asymmetry.
## Head and sclera preserve the original topology. Liner and brow assets retain
## native skin binds; each runtime instance owns only expression weights.

const MESHES := {
	"Head": preload("res://world/characters/openpony/face_sculpt/head.res"),
	"Eyelashes": preload("res://world/characters/openpony/face_sculpt/eyelashes.res"),
	"Eye": preload("res://world/characters/openpony/face_sculpt/eye.res"),
	"Eyebrows": preload("res://world/characters/openpony/face_sculpt/eyebrows.res"),
}
var _meshes: Array[MeshInstance3D] = []
var _weights: Dictionary = {}
var _closure := 0.0
var _lid_materials: Array[ShaderMaterial] = []
var _permanent_eyeshadow := false
var _lid_projection := Transform3D.IDENTITY

## Called after the head's normal coat dressing, including a later quality re-dress.
func set_lid_color(color: Color, permanent: bool) -> void:
	_lid_materials.clear()
	_permanent_eyeshadow = permanent
	for mesh in _meshes:
		if mesh.name != "Head" or not mesh.mesh.get_meta("lid_color_mask", false): continue
		for surface in mesh.mesh.get_surface_count():
			var material := mesh.get_active_material(surface) as ShaderMaterial
			if material == null: continue
			material.set_shader_parameter("eyelid_color", color)
			material.set_shader_parameter("eyelid_rest_from_pose", _lid_projection)
			_lid_materials.append(material)
	_apply_lid_color()

## Applejack's six freckles in the sculpted head's UV space (x, y = UV centre, z = radius,
## w = vertical UV stretch there, so they render round).
## The left and right head halves share one mirrored UV layout, so three spots paint three
## freckles under each eye. Placed from rest positions (tools/face_reference/dump_head_uv.gd);
## painted by lid_color.gdshaderinc freckled() (dev 2026-11-03).
const FRECKLE_SPOTS: Array[Vector4] = [
	Vector4(0.5542, 0.8269, 0.0055, 1.8), Vector4(0.5733, 0.8127, 0.0055, 1.8),
	Vector4(0.5762, 0.8304, 0.0055, 1.8), Vector4(0, 0, 0, 0), Vector4(0, 0, 0, 0), Vector4(0, 0, 0, 0),
]

## Called after set_lid_color on the same head materials; alpha 0 clears them.
func set_freckles(color: Color) -> void:
	for material in _lid_materials:
		material.set_shader_parameter("freckle_color", color)
		material.set_shader_parameter("freckle_spots", PackedVector4Array(FRECKLE_SPOTS))

## Share the existing head-motion correction used by the iris projection.
func set_lid_projection(unpose: Transform3D) -> void:
	_lid_projection = unpose
	for material in _lid_materials:
		material.set_shader_parameter("eyelid_rest_from_pose", unpose)

func _apply_lid_color() -> void:
	var amount := Vector2.ONE
	if not _permanent_eyeshadow:
		var visible := 1.0 - smoothstep(0.0, .85, _closure)
		for side in 2:
			var suffix := "_L" if side == 0 else "_R"
			var upper := maxf(float(_weights.get("lid_flat" + suffix, 0.0)), float(_weights.get("upper" + suffix, 0.0)))
			upper = maxf(upper, float(_weights.get("eye_smile" + suffix, 0.0)) * .5)
			amount[side] = maxf(clampf(_closure,0.0,1.0), clampf(upper,0.0,1.0) * visible)
	for material in _lid_materials: material.set_shader_parameter("eyelid_weights", amount)

func bind(model: Node) -> void:
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if MESHES.has(String(mesh.name)):
			mesh.mesh = MESHES[String(mesh.name)]
			_meshes.append(mesh)

func set_weights(weights: Dictionary) -> void:
	if weights == _weights: return
	_weights = weights.duplicate()
	_apply()

func set_closure(closure: float) -> void:
	if is_equal_approx(closure, _closure): return
	_closure = closure
	_apply()

func _apply() -> void:
	_apply_lid_color()
	# Native blinks/boops own full closure. Yield the sculpt as those bones close,
	# avoiding applying a second squint on top of a shut eyelid.
	var visible := 1.0 - smoothstep(0.0, .85, _closure)
	for mesh in _meshes:
		for i in mesh.mesh.get_blend_shape_count():
			var channel: StringName = mesh.mesh.get_blend_shape_name(i)
			if channel == &"Lid clearance": continue
			# The fan follows the same closure clock while keeping its authored
			# width. These are motion correctives, independent of expression weights.
			if String(channel).begins_with("blink_follow_"):
				mesh.set_blend_shape_value(i, clampf(_closure, 0.0, 1.0))
				continue
			mesh.set_blend_shape_value(i, clampf(float(_weights.get(channel, 0.0)), 0.0, 1.0) * visible)
