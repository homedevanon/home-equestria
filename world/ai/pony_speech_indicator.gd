extends MeshInstance3D
## One reused, two-triangle indicator for the director's active speaker. No viewport.
const SHADER := preload("res://world/ai/pony_speech_indicator.gdshader")
var actor: Node3D
var viewer: Node3D
var mode := "hidden"
var _material: ShaderMaterial
var _opacity := 0.0

func _init() -> void:
	name = "PonySpeechIndicator"
	var quad := QuadMesh.new()
	quad.size = Vector2(.36, .225)
	mesh = quad
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.set_shader_parameter("opacity", 0.0)
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ignore_occlusion_culling = false
	extra_cull_margin = .02
	visible = false
	set_process(false)

func show_for(pony: Node3D, camera: Node3D, state := "thinking") -> void:
	actor = pony
	viewer = camera
	mode = state
	visible = true
	set_process(true)
	_update_pose()

func hide_indicator() -> void:
	mode = "hidden"
	visible = false
	_opacity = 0.0
	_material.set_shader_parameter("opacity", 0.0)
	actor = null
	viewer = null
	set_process(false)

func _process(delta: float) -> void:
	if not is_instance_valid(actor) or not actor.is_inside_tree() or not is_instance_valid(viewer) or not viewer.is_inside_tree():
		hide_indicator(); return
	visible = actor.is_visible_in_tree() and actor.global_position.distance_to(viewer.global_position) < 24.0
	_opacity = move_toward(_opacity, 1.0, delta * 8.0)
	_material.set_shader_parameter("opacity", _opacity)
	_update_pose()

func _update_pose() -> void:
	if not is_inside_tree() or not is_instance_valid(actor) or not actor.is_inside_tree(): return
	global_position = actor.speech_indicator_point() if actor.has_method("speech_indicator_point") else (actor.listen_point() if actor.has_method("listen_point") else actor.global_position) + Vector3.UP * .4
	if is_instance_valid(viewer) and viewer.is_inside_tree():
		# One physical orientation shared by both VR eyes, no per-eye spinning billboard. It grows
		# with a pony bigger than canon (size setting), so it still clears her ears and mane
		# (thread 43671981); canon and smaller keep the canon size.
		global_basis = viewer.global_basis.orthonormalized().scaled(Vector3.ONE * bubble_scale(actor))

## The bubble's size for `pony`: her body scale when above canon, else 1.
static func bubble_scale(pony: Node) -> float:
	var value: Variant = pony.get("body_scale") if is_instance_valid(pony) else null
	return maxf(1.0, float(value)) if value is float else 1.0
