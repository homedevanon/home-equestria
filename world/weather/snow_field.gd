extends Node3D
## Falling snow as a field of flakes around the eye (weather.gd owns one; LOOK_SNOW there).
##
## Why a field and not particle emitters (dev 2026-11-10: the flakes "float in a cloud up above,
## they never actually FALL down", "come from like maybe 10 feet up", "WAY too big"): an emitter
## above the camera fills a tall column evenly, so nine flakes in ten are above eye level and seen
## only against the sky; none stand between the eye and the street, and the place they are born is
## in plain view. Measured on shots: about 20 flakes within 5 m, each under 3 px, darker than the
## snow on the ground.
##
## Here every flake has a fixed path through the world and the boxes below are windows onto those
## paths that move with the eye. A flake that leaves a box on one side enters on the other, faded
## at the faces, so the air is evenly full in every direction, nothing is born in view, and the
## fall is there the moment snow starts, after fast travel, and on stepping out of a door.
## Three windows give depth without waste: many flakes close by, where each is seen as a flake;
## fewer further out, where one stands for the many around it (snow_flake.gdshader min_angle).
##
## The kind of fall follows the wind: still air gives big, slow, soft tufts well apart; wind gives
## fine grain, fast, dense and leaning, drawn as dashes.
##
## Cost: three MultiMesh draws, no simulation; one _process that moves three boxes and writes two
## shader values each. Flakes are lit by the scene (see the shader), so street lamps and windows
## light them with no extra work.
## Limit: flakes do not stop on roofs. Walls and roofs hide them from outside, and the field is
## hidden while the player is indoors, but they do fall through an open porch or a market awning.

const SHADER := preload("res://world/weather/snow_flake.gdshader")
const TEXTURE := preload("res://world/vfx/textures/soft_dot.png")
const PLAYER_VIEW := preload("res://world/player_view.gd")
## One row per window: half size of the box in metres, how far its centre sits above the eye,
## flakes, width of the flake quad in metres (the soft sprite's visible core is 0.4 of it),
## opacity, and how much of the wind's dash it shows.
const LAYERS := [
	{"half": Vector3(6.0, 6.0, 6.0), "lift": 2.0, "flakes": 5200, "quad": 0.024, "opacity": 0.95, "streak": 1.0},
	{"half": Vector3(20.0, 14.0, 20.0), "lift": 8.0, "flakes": 14000, "quad": 0.036, "opacity": 0.9, "streak": 1.0},
	{"half": Vector3(60.0, 26.0, 60.0), "lift": 16.0, "flakes": 9000, "quad": 0.080, "opacity": 0.6, "streak": 0.9},
]
const SLANT := 1.5                    # sideways metres per metre fallen at full gale
## [still air, gale] for each quantity.
const SPEED := Vector2(0.95, 2.6)     # metres per second
const GRAIN := Vector2(1.25, 0.6)     # scale on the flake size
const STREAK := Vector2(1.25, 3.2)    # dash length over width
const FLUTTER := Vector2(0.13, 0.03)  # sideways sway in metres
const DENSITY := Vector2(0.55, 1.0)   # share of the flakes shown

var _layers: Array = []               # [MultiMeshInstance3D, ShaderMaterial, row]
var _travel := Vector3.ZERO
var _velocity := Vector3.DOWN
var _amount := 0.0


func _ready() -> void:
	# The boxes move with the eye every drawn frame, not on physics ticks.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	for row: Dictionary in LAYERS:
		var material := ShaderMaterial.new()
		material.shader = SHADER
		material.set_shader_parameter("flake", TEXTURE)
		material.set_shader_parameter("quad", float(row.quad))
		material.set_shader_parameter("opacity", float(row.opacity))
		material.set_shader_parameter("box_half", row.half)
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE
		quad.material = material
		var flakes := MultiMesh.new()
		flakes.transform_format = MultiMesh.TRANSFORM_3D
		flakes.mesh = quad
		flakes.instance_count = int(row.flakes)
		# Every flake is placed by the shader from its number; the transforms only have to exist
		# (a MultiMesh whose buffer was never written crashed the engine on the first frame drawn).
		var identity := PackedFloat32Array([1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0])
		var buffer := PackedFloat32Array()
		for index: int in int(row.flakes): buffer.append_array(identity)
		flakes.buffer = buffer
		flakes.visible_instance_count = 0
		var instance := MultiMeshInstance3D.new()
		instance.multimesh = flakes
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var half: Vector3 = row.half
		instance.custom_aabb = AABB(-half * 1.1, half * 2.2)
		instance.visible = false
		add_child(instance)
		_layers.append([instance, material, row])
	set_process(false)


## amount 0..1: how hard it snows here. wind 0..1 with its direction in push (length = wind).
## hidden: the player is under a roof; the fall carries on unseen.
func set_fall(amount: float, wind: float, push: Vector3, hidden: bool) -> void:
	_amount = amount
	var on := amount > 0.01
	wind = clampf(wind, 0.0, 1.0)
	var line := (Vector3.DOWN + Vector3(push.x, 0.0, push.z) * SLANT).normalized()
	_velocity = line * lerpf(SPEED.x, SPEED.y, wind)
	var shown := clampf(amount * lerpf(DENSITY.x, DENSITY.y, wind), 0.0, 1.0)
	for layer: Array in _layers:
		var instance := layer[0] as MultiMeshInstance3D
		var material := layer[1] as ShaderMaterial
		var row: Dictionary = layer[2]
		instance.visible = on and not hidden
		instance.multimesh.visible_instance_count = int(round(shown * float(row.flakes)))
		material.set_shader_parameter("fall_direction", line)
		material.set_shader_parameter("grain", lerpf(GRAIN.x, GRAIN.y, wind))
		material.set_shader_parameter("streak", lerpf(STREAK.x, STREAK.y, wind) * float(row.streak))
		material.set_shader_parameter("flutter", lerpf(FLUTTER.x, FLUTTER.y, wind))
	if not on: _travel = Vector3.ZERO
	set_process(on)
	if on: _place()


## The sky's light a flake carries on top of what a surface gets.
func set_sky_light(glow: Color) -> void:
	for layer: Array in _layers:
		(layer[1] as ShaderMaterial).set_shader_parameter("sky_glow", glow)


func _process(delta: float) -> void:
	_travel += _velocity * delta
	_place()


func _place() -> void:
	var camera := PLAYER_VIEW.camera(self)
	if camera == null: return
	var eye := camera.global_position
	for layer: Array in _layers:
		var instance := layer[0] as MultiMeshInstance3D
		var material := layer[1] as ShaderMaterial
		var centre := eye + Vector3.UP * float((layer[2] as Dictionary).lift)
		instance.global_position = centre
		material.set_shader_parameter("box_centre", centre)
		material.set_shader_parameter("travel", _travel)
