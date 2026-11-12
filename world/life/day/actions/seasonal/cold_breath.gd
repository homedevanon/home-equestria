extends RefCounted
## Cold breath (M-SEA-19, design 6.6): on cold winter mornings a soft puff leaves a HERO pony's nose
## every few seconds, and Anon's own in front of the camera. One GPUParticles3D of 16 particles
## each, made only while it is cold and freed when it warms up; pony_wardrobe.gd turns them on and
## off on its 4 s dressing beat (never per frame). The puffs live in world space and fade as they
## rise. Shared mesh and materials; no texture file (a radial gradient made once).
const NAME := "ColdBreath"
const AMOUNT := 16
const LIFETIME := 3.2
## In front of and just below Anon's eyes.
const CAMERA_OFFSET := Vector3(0.0, -0.16, -0.3)
static var _mesh: QuadMesh
static var _process: ParticleProcessMaterial

static func _shared() -> void:
	if _mesh != null: return
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 1.0])
	gradient.colors = PackedColorArray([Color(1, 1, 1, 0.55), Color(1, 1, 1, 0.0)])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5); texture.fill_to = Vector2(0.5, 0.0)
	texture.width = 32; texture.height = 32
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = texture
	material.albedo_color = Color(0.92, 0.94, 0.97, 1.0)
	material.roughness = 1.0
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	_mesh = QuadMesh.new(); _mesh.size = Vector2(0.14, 0.14); _mesh.material = material
	_process = ParticleProcessMaterial.new()
	_process.direction = Vector3(0, 0.3, -1)
	_process.spread = 25.0
	_process.initial_velocity_min = 0.12; _process.initial_velocity_max = 0.25
	_process.gravity = Vector3(0, 0.05, 0)
	_process.damping_min = 0.1; _process.damping_max = 0.2
	_process.scale_min = 0.6; _process.scale_max = 1.0
	var grow := Curve.new(); grow.add_point(Vector2(0, 0.4)); grow.add_point(Vector2(1, 2.2))
	var grow_texture := CurveTexture.new(); grow_texture.curve = grow
	_process.scale_curve = grow_texture
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.15, 1.0])
	fade.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.7), Color(1, 1, 1, 0.0)])
	var fade_texture := GradientTexture1D.new(); fade_texture.gradient = fade
	_process.color_ramp = fade_texture

static func make() -> GPUParticles3D:
	_shared()
	var puffs := GPUParticles3D.new()
	puffs.name = NAME
	puffs.amount = AMOUNT
	puffs.lifetime = LIFETIME
	# A breath every LIFETIME seconds: most of the 16 leave together.
	puffs.explosiveness = 0.75
	puffs.randomness = 0.3
	puffs.local_coords = false
	puffs.draw_pass_1 = _mesh
	puffs.process_material = _process
	puffs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	puffs.visibility_aabb = AABB(Vector3(-1, -1, -1.5), Vector3(2, 2.5, 3))
	return puffs

## Her nose: the boop snoot that follows the head (hybrid_boop.gd), else her own node.
static func _anchor(pony: Node3D) -> Node3D:
	var boop: Variant = pony.get("boop_node")
	if boop is Object and is_instance_valid(boop):
		var snoot: Variant = (boop as Object).get("snoot")
		if snoot is Node3D and is_instance_valid(snoot): return snoot
	return null

static func set_on(pony: Node3D, on: bool) -> void:
	var anchor := _anchor(pony)
	if anchor == null: return
	var puffs := anchor.get_node_or_null(NAME) as GPUParticles3D
	if on and puffs == null:
		anchor.add_child(make())
	elif not on and puffs != null:
		anchor.remove_child(puffs)
		puffs.queue_free()

## Anon's breath on the active camera.
static func set_camera(from: Node, on: bool) -> void:
	var camera: Camera3D = preload("res://world/player_view.gd").camera(from)
	if camera == null: return
	var puffs := camera.get_node_or_null(NAME) as GPUParticles3D
	if on and puffs == null:
		puffs = make()
		puffs.position = CAMERA_OFFSET
		camera.add_child(puffs)
	elif not on and puffs != null:
		camera.remove_child(puffs)
		puffs.queue_free()
