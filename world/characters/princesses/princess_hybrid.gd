extends "res://world/characters/hybrid_mare/hybrid_mare.gd"
## Reference-fitted native body, native OpenPony face, original princess accessories.
const NATIVE_BODY := preload("res://world/characters/hybrid_mare/body.glb")
static var _native_positions: Dictionary = {}
static var _native_trot: Animation

func _ready() -> void:
	if _native_positions.is_empty():
		var native := NATIVE_BODY.instantiate()
		var sk: Skeleton3D = native.find_children("*", "Skeleton3D", true, false)[0]
		for b in sk.get_bone_count(): _native_positions[sk.get_bone_name(b)] = sk.get_bone_rest(b).origin
		var player: AnimationPlayer = native.find_children("*", "AnimationPlayer", true, false)[0]
		_native_trot = player.get_animation("trot")
		native.free()
	profile.native_rest_positions = _native_positions
	profile.native_trot = _native_trot
	set_meta("open_wing_scene", "res://world/characters/princesses/"+identity.id+"_wings.glb")
	super._ready()
	# These exports already wear a fitted horn and native tail root.
	for mi in head.model.find_children("Unicorn Horn", "MeshInstance3D", true, false): mi.hide()
	var dock := find_child("OpenPonyDock", true, false)
	if dock != null: dock.hide()
	profile.clearance = 1.95 if identity.character() == "celestia" else 1.45
	_update_capsule()

func _attach_devkit_hair() -> void:
	# Mane, tail and regalia are weighted into the fitted body export.
	pass

func _dress_body_for_race() -> void:
	# Marks are fitted offline alongside the coat; the standard mare patch fit
	# would move them back to the ordinary mare's rump.
	pass

func _apply_show_shading(model: Node) -> void:
	super._apply_show_shading(model)
	var body := model.find_child("MareBody", true, false) as MeshInstance3D
	if body == null: return
	var source := body.get_meta("source_material_0", null) as StandardMaterial3D
	var mat := body.get_active_material(0) as ShaderMaterial
	if source != null and mat != null:
		mat.set_shader_parameter("base_texture", source.albedo_texture)
		mat.set_shader_parameter("color", Color.WHITE)
		# The texture already contains the coat color. Apply only its shade ratio;
		# retaining the flat-coat shadow color tints it twice and turns Luna black.
		var shadow: Color = mat.get_shader_parameter("shadow_color")
		if shadow.a > 0.0:
			mat.set_shader_parameter("shadow_color", _shade_of(Color.WHITE))

func set_body_scale(value: float) -> void:
	super.set_body_scale(value)
	_update_capsule()

func _update_capsule() -> void:
	if _collision == null: return
	var shape := _collision.shape.duplicate() as CapsuleShape3D
	shape.height = (1.25 if identity.character() == "celestia" else .95) * body_scale
	shape.radius = .21 * body_scale
	_collision.shape = shape
	_collision.position.y = shape.height * .5
