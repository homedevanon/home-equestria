extends Node3D
## Small flocks of birds over the valley (dev 2026-11-10: "small details and liveliness"). The sky
## had birdsong (world/ambience.gd) and nothing to sing it. A few loose flocks circle and drift
## over the land around the player by day, high enough and far enough to stay small: each bird is
## one card with a wing-beat sprite (a real CC0 asset, replaceable: world/vfx/textures/
## bird_fly_sheet.png), turned to fly beak first.
## Fewer in winter, none in rain, heavy snow or at night (they fade out with the light).
##
## Cost: one MultiMesh draw; BIRDS transforms written per frame from a few sines. No physics,
## no navigation, nothing saved.
## Rollback: ENABLED = false.

const ENABLED := true
const PLAYER_VIEW := preload("res://world/player_view.gd")
const SHADER := preload("res://world/vfx/bird_flock.gdshader")
const SHEET := preload("res://world/vfx/textures/bird_fly_sheet.png")
const FLOCKS := 3
const BIRDS_PER_FLOCK := 7
## Wing span on screen: the card's width in metres (the sprite cell is 3:2).
const SIZE := 0.8
## A flock circles a point this far from the player (metres), on a circle this wide, this high
## above the ground there, at this speed (metres per second). [least, most]
const AWAY := Vector2(30.0, 95.0)
const CIRCLE := Vector2(22.0, 55.0)
const HEIGHT := Vector2(10.0, 22.0)
const SPEED := Vector2(6.5, 9.0)
## A flock whose circle is further than this from the player fades out (at that range a bird is a
## speck) and takes a new place around them, where it fades in. A flock that only followed stayed
## a speck at the leash's end for good after a fast travel (seen in the shot tool, 2026-11-10).
const LEASH := 150.0
const FADE := 0.4

var _flocks: Array = []
var _birds: MultiMesh
var _instance: MultiMeshInstance3D
var _shown := 0.0
var _rng := RandomNumberGenerator.new()


const PLACE_RATE := 120.0
var _place_delta := 0.0

func _ready() -> void:
	if not ENABLED:
		set_process(false)
		return
	# Placed every drawn frame, not on physics ticks.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_rng.randomize()
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("sheet", SHEET)
	var card := QuadMesh.new()
	card.size = Vector2(SIZE, SIZE * 2.0 / 3.0)
	card.material = material
	_birds = MultiMesh.new()
	_birds.transform_format = MultiMesh.TRANSFORM_3D
	_birds.use_custom_data = true
	_birds.mesh = card
	_birds.instance_count = FLOCKS * BIRDS_PER_FLOCK
	for index: int in _birds.instance_count:
		_birds.set_instance_transform(index, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3.ZERO))
		_birds.set_instance_custom_data(index, Color(0.0, 0.0, 0.0, 0.0))
	_instance = MultiMeshInstance3D.new()
	_instance.multimesh = _birds
	_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_instance.custom_aabb = AABB(Vector3(-400.0, -100.0, -400.0), Vector3(800.0, 300.0, 800.0))
	_instance.visible = false
	add_child(_instance)
	for flock: int in FLOCKS:
		var members: Array = []
		for bird: int in BIRDS_PER_FLOCK:
			# Behind the leader along the circle (radians), out from it and above or below it
			# (metres), its own wing rhythm and bob.
			members.append({"lag": _rng.randf_range(0.0, 0.5), "out": _rng.randf_range(-3.5, 3.5), "up": _rng.randf_range(-1.6, 1.6),
				"beat": _rng.randf(), "bob": _rng.randf_range(0.0, TAU)})
		_flocks.append({"centre": Vector3.INF, "radius": _rng.randf_range(CIRCLE.x, CIRCLE.y), "height": _rng.randf_range(HEIGHT.x, HEIGHT.y),
			"speed": _rng.randf_range(SPEED.x, SPEED.y), "angle": _rng.randf_range(0.0, TAU), "turn": 1.0 if _rng.randf() < 0.5 else -1.0,
			"members": members, "ground": 0.0, "fade": 0.0})


var _clock: Node
var _weather: Node
var _winter := false
var _lookup_in := 0.0

func _process(delta: float) -> void:
	# Small silhouettes 30 m and more away: placed at most PLACE_RATE times a second on a flat
	# screen (a step is then a pixel or two at the nearest). The headset places them every frame.
	_place_delta += delta
	if _place_delta < 1.0 / PLACE_RATE and not get_viewport().use_xr: return
	delta = _place_delta
	_place_delta = 0.0
	var camera := PLAYER_VIEW.camera(self)
	if camera == null: return
	var eye := camera.global_position
	if not eye.is_finite(): return
	# The helpers and the season are looked up once a second, not every frame.
	_lookup_in -= delta
	if _lookup_in <= 0.0 or not is_instance_valid(_clock):
		_lookup_in = 1.0
		_clock = get_node_or_null("/root/TimeOfDay")
		var tree := get_tree()
		_weather = tree.get_first_node_in_group("weather")
		var seasons: Node = tree.get_first_node_in_group("season_state")
		_winter = seasons != null and str(seasons.call("season")) == "winter"
	var clock := _clock
	var daylight: float = float(clock.call("daylight")) if clock != null else 1.0
	var weather: Node = _weather if is_instance_valid(_weather) else null
	var params: Dictionary = weather.get("params") if weather != null and weather.get("params") is Dictionary else {}
	var winter := _winter
	var fair := float(params.get("rain", 0.0)) < 0.2 and float(params.get("snow", 0.0)) < 0.5 and float(params.get("gust", 0.0)) < 0.8
	var want := smoothstep(0.25, 0.5, daylight) if fair else 0.0
	_shown = move_toward(_shown, want, delta * 0.25)
	var on := _shown > 0.01
	if _instance.visible != on: _instance.visible = on
	if not on: return
	var flocks_out := 1 if winter else FLOCKS
	var seconds := Time.get_ticks_msec() * 0.001
	var index := 0
	for number: int in _flocks.size():
		var flock: Dictionary = _flocks[number]
		var centre: Vector3 = flock.centre
		var far := not centre.is_finite() or Vector2(centre.x - eye.x, centre.z - eye.z).length() > LEASH
		var fade: float = move_toward(float(flock.fade), 0.0 if far else 1.0, delta * FADE)
		if far and fade <= 0.0:
			# First time, or the player has left it behind: a new place somewhere around them.
			var bearing := _rng.randf_range(0.0, TAU)
			centre = eye + Vector3(cos(bearing), 0.0, sin(bearing)) * _rng.randf_range(AWAY.x, AWAY.y)
			flock.ground = _ground(centre, eye.y)
		flock.fade = fade
		centre.y = float(flock.ground) + float(flock.height)
		flock.centre = centre
		var radius: float = flock.radius
		var turn: float = flock.turn
		flock.angle = float(flock.angle) + turn * float(flock.speed) / radius * delta
		var visible_flock := 1.0 if number < flocks_out else 0.0
		for member: Dictionary in flock.members:
			var angle: float = float(flock.angle) - turn * float(member.lag)
			var reach: float = radius + float(member.out)
			var bob: float = sin(seconds * 1.3 + float(member.bob)) * 0.5
			var at := centre + Vector3(cos(angle) * reach, float(member.up) + bob, sin(angle) * reach)
			# Beak along the way it flies; the card turns about that line to face the eye.
			var forward := Vector3(-sin(angle), cos(seconds * 1.3 + float(member.bob)) * 0.06, cos(angle)) * turn
			forward = forward.normalized()
			var to_eye := eye - at
			var normal := to_eye - forward * to_eye.dot(forward)
			normal = normal.normalized() if normal.length_squared() > 0.0001 else Vector3.UP
			var up := normal.cross(forward)
			# Seen from its other side the bird is mirrored, never upside down.
			if up.y < 0.0: up = -up
			_birds.set_instance_transform(index, Transform3D(Basis(forward, up, forward.cross(up)), at))
			_birds.set_instance_custom_data(index, Color(float(member.beat), _shown * visible_flock * fade, 0.0, 0.0))
			index += 1


func _ground(at: Vector3, fallback: float) -> float:
	if not is_instance_valid(WorldTerrain.instance): return fallback
	var height: float = WorldTerrain.instance.height_at(at)
	return height if is_finite(height) else fallback
