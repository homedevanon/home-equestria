extends Node3D
## Motes in the air (dev 2026-11-10: "little dust motes and lights ... LIFE"). Two small particle
## clouds that stay around the camera, in the world (not on the screen):
##   - pollen and dust drifting in the sun on dry days from spring to autumn, brightest when the
##     sun is low and they catch the light;
##   - ice glints in the air on a clear winter day (and faintly under a bright moon).
## Night has the fireflies (world/life); snow and rain have their own particles (weather.gd).
## Textures are real assets (Kenney particle pack, CC0), placeholders dev may swap.
##
## Cost: two GPUParticles3D (MOTES and GLINTS particles), one draw each, no script per particle; a
## 2 Hz step moves the clouds with the camera and sets how many are alive. Off indoors.
## Rollback: ENABLED = false.

const ENABLED := true
const PLAYER_VIEW := preload("res://world/player_view.gd")
const MOTE_TEXTURE := preload("res://world/vfx/textures/soft_dot.png")
const GLINT_TEXTURE := preload("res://world/vfx/textures/glint_sharp.png")
const MOTES := 240
const GLINTS := 90
const STEP := 0.5
const BOX := Vector3(16.0, 4.5, 16.0)

var _motes: GPUParticles3D
var _glints: GPUParticles3D
var _mote_material: StandardMaterial3D
var _glint_material: StandardMaterial3D
var _timer := 0.0


func _ready() -> void:
	if not ENABLED:
		set_process(false)
		return
	_mote_material = _material(MOTE_TEXTURE)
	_glint_material = _material(GLINT_TEXTURE)
	_motes = _cloud(MOTES, 11.0, Vector2(0.018, 0.04), _mote_material, 0.35, 0.02)
	_glints = _cloud(GLINTS, 2.4, Vector2(0.05, 0.11), _glint_material, 0.1, -0.05)


func _material(texture: Texture2D) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.albedo_texture = texture
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.billboard_keep_scale = true
	material.vertex_color_use_as_albedo = true
	material.disable_receive_shadows = true
	material.disable_fog = true
	return material


func _cloud(amount: int, lifetime: float, size: Vector2, material: StandardMaterial3D, turbulence: float, rise: float) -> GPUParticles3D:
	var cloud := GPUParticles3D.new()
	cloud.amount = amount
	cloud.lifetime = lifetime
	cloud.preprocess = lifetime
	cloud.local_coords = false
	cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cloud.visibility_aabb = AABB(-BOX * 1.5, BOX * 3.0)
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = BOX
	process.direction = Vector3(1.0, 0.0, 0.3)
	process.spread = 180.0
	process.initial_velocity_min = 0.02; process.initial_velocity_max = 0.12
	process.gravity = Vector3(0.0, rise, 0.0)
	process.scale_min = size.x; process.scale_max = size.y
	process.turbulence_enabled = turbulence > 0.0
	process.turbulence_noise_strength = turbulence
	process.turbulence_noise_scale = 2.5
	# Each mote fades in and out, so none pops.
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0.0)); fade.set_color(1, Color(1, 1, 1, 0.0))
	fade.add_point(0.3, Color(1, 1, 1, 1.0)); fade.add_point(0.7, Color(1, 1, 1, 1.0))
	var fade_texture := GradientTexture1D.new(); fade_texture.gradient = fade
	process.color_ramp = fade_texture
	cloud.process_material = process
	var quad := QuadMesh.new(); quad.size = Vector2.ONE; quad.material = material
	cloud.draw_pass_1 = quad
	cloud.emitting = false
	add_child(cloud)
	return cloud


func _process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0: return
	_timer = STEP
	var camera := PLAYER_VIEW.camera(self)
	if camera == null: return
	var tree := get_tree()
	var clock: Node = get_node_or_null("/root/TimeOfDay")
	var daylight: float = float(clock.call("daylight")) if clock != null else 1.0
	var golden: float = float(clock.call("golden_amount")) if clock != null else 0.0
	var seasons: Node = tree.get_first_node_in_group("season_state")
	var season: String = str(seasons.call("season")) if seasons != null else "summer"
	var weather: Node = tree.get_first_node_in_group("weather")
	var params: Dictionary = weather.get("params") if weather != null and weather.get("params") is Dictionary else {}
	var dry := float(params.get("rain", 0.0)) < 0.05 and float(params.get("snow", 0.0)) < 0.05
	var sun := float(params.get("sun", 1.0))
	var ambience: Node = get_parent().get_node_or_null("Ambience") if get_parent() != null else null
	var outdoors := ambience == null or not is_instance_valid(ambience.get("room"))
	var winter := season == "winter"
	# Motes show most when the sun is low and they are lit from the side.
	var motes := 0.0
	if outdoors and dry and not winter:
		motes = daylight * sun * (0.3 + 0.7 * golden)
	var glints := 0.0
	if outdoors and dry and winter:
		glints = maxf(daylight * sun * 0.9, 0.0)
	_apply(_motes, _mote_material, motes, Color(1.0, 0.93, 0.72).lerp(Color(1.0, 0.72, 0.4), golden), 0.5, camera)
	_apply(_glints, _glint_material, glints, Color(0.86, 0.94, 1.0), 0.75, camera)


func _apply(cloud: GPUParticles3D, material: StandardMaterial3D, amount: float, color: Color, alpha: float, camera: Camera3D) -> void:
	var on := amount > 0.03
	if on:
		# The cloud is centred a little ahead of the eye, so most motes are in view.
		var ahead := -camera.global_basis.z
		ahead.y = 0.0
		cloud.global_position = camera.global_position + ahead.normalized() * BOX.x * 0.45 + Vector3(0.0, 1.0, 0.0)
		cloud.amount_ratio = clampf(amount, 0.05, 1.0)
		color.a = alpha
		if not material.albedo_color.is_equal_approx(color): material.albedo_color = color
	if cloud.emitting != on: cloud.emitting = on
