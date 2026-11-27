extends Node3D
## Fireflies (dev 2026-09-25): swarms of small glowing specks that wander and blink softly at
## night. Common in the Everfree, less common in towns ("it's a city"), in between elsewhere.
## No fireflies in winter, fewer in spring and autumn, none while it rains, snows or hails.
##
## Swarms appear around the camera one at a time (outdoors, on open ground, 12-90 m away),
## live a few minutes, then fade out; a new one takes their place while the night lasts.
## Each swarm is one MultiMeshInstance3D; all motion and blinking run in firefly.gdshader.

## Rollback (2026-11-18): false runs the full frame by day again. Measured before: 8 µs a frame by
## day with no swarms (script profiler, town street, ~470 FPS). By day with no swarm left, the spawn
## timer already run out and the density reading already dropped, a frame returns after the night
## test: nothing else in _process can change then (see _process).
const FRAME_TRIM := true
const SHADER := preload("res://world/life/firefly.gdshader")
const MAX_SWARMS := 10
const SPAWN_MIN := 12.0
const SPAWN_MAX := 90.0
const RELEASE_DISTANCE := 130.0
const FADE_SECONDS := 4.0
## Seasons (weather.gd): how many fireflies there are relative to summer.
const SEASON_SHARE := {"spring": 0.55, "summer": 1.0, "autumn": 0.35, "winter": 0.0}

var camera_source: Callable
var _material: ShaderMaterial
var _quad: QuadMesh
var _swarms: Array[Dictionary] = []   # {node, age, life, fading_out}
var _spawn_in := 1.0
var _rng := RandomNumberGenerator.new()
const DENSITY_CACHE := true
const DENSITY_STEP := 1.0
const DENSITY_SECONDS := 2.0
var _density_eye := Vector3.INF
var _density_value := 0.0
var _density_age := 0.0
## Perf 0.1.0: the clock, quality and weather nodes are looked up once (again only if freed), a
## swarm's fade parameter is written only when it changes (it holds at 1 for minutes), and the
## finished-swarm sweep allocates nothing on frames where no swarm finished.
var _clock: Node
var _quality: Node
var _weather: Node

func _ready() -> void:
	_rng.randomize()
	_material = ShaderMaterial.new(); _material.shader = SHADER
	_quad = QuadMesh.new(); _quad.size = Vector2.ONE; _quad.material = _material

func _process(delta: float) -> void:
	# FRAME_TRIM (2026-11-18): _night() 0 makes share 0 whatever the other factors (0 * inf or NaN
	# is NaN, also not > 0), so the full path would only decrement a spawn timer already <= 0 (it is
	# only ever compared with <= 0 and then reset), walk no swarm and set _density_eye to INF. The
	# night test runs every frame as before, so the first dusk frame is the same frame. Until
	# _density_eye is INF the full path runs (it sets INF only with a camera, as before).
	if FRAME_TRIM and _swarms.is_empty() and _spawn_in <= 0.0 and _density_eye == Vector3.INF and _night() <= 0.0:
		return
	var camera := _camera()
	if camera == null: return
	var eye := camera.global_position
	if not is_instance_valid(_quality): _quality = get_node_or_null("/root/Quality")
	var quality := _quality
	var tier_scale: float = float(quality.get_value("firefly_scale", 1.0)) if quality != null else 1.0
	# dev 2026-10-20 perf pass: the place density (biome weights, terrain height and a walk over
	# every world region) ran every frame, also by day when the target is zero anyway. It is now
	# worked out only when hour, season and weather allow swarms (exact), and then reused until
	# the eye moves DENSITY_STEP or DENSITY_SECONDS pass (DENSITY_CACHE false: every frame again).
	var share: float = MAX_SWARMS * tier_scale * _night() * _season() * _dry()
	var target := 0
	if share > 0.0: target = int(round(share * _place_density(eye, delta)))
	else: _density_eye = Vector3.INF   # the next evening starts from a fresh reading
	var finished := false
	for swarm in _swarms:
		swarm.age += delta
		var node: MultiMeshInstance3D = swarm.node
		var far := node.global_position.distance_to(eye) > RELEASE_DISTANCE
		if not swarm.fading_out and (swarm.age > swarm.life or far or _swarms.size() > target):
			swarm.fading_out = true; swarm.age = 0.0
		var fade := clampf(swarm.age / FADE_SECONDS, 0.0, 1.0)
		var shown: float = 1.0 - fade if swarm.fading_out else fade
		if shown != float(swarm.get("shown", -1.0)):
			swarm.shown = shown
			node.set_instance_shader_parameter("fade", shown)
		if swarm.fading_out and swarm.age >= FADE_SECONDS: finished = true
	if finished:
		for swarm in _swarms.filter(func(s): return s.fading_out and s.age >= FADE_SECONDS):
			(swarm.node as Node).queue_free(); _swarms.erase(swarm)
	_spawn_in -= delta
	if _spawn_in <= 0.0 and _live() < target:
		_spawn_in = _rng.randf_range(2.0, 6.0)
		_try_spawn(camera)

func _live() -> int:
	var live := 0
	for swarm in _swarms:
		if not swarm.fading_out: live += 1
	return live

func _camera() -> Camera3D:
	if camera_source.is_valid():
		var c: Variant = camera_source.call()
		if c is Camera3D: return c
	return preload("res://world/player_view.gd").camera(self)

## 0 by day, 1 from about 20:30 to 04:30, ramping at dusk and dawn.
func _night() -> float:
	if not is_instance_valid(_clock): _clock = get_node_or_null("/root/TimeOfDay")
	if _clock == null: return 0.0
	var h := float(_clock.hours)
	return maxf(smoothstep(19.0, 20.5, h), 1.0 - smoothstep(4.5, 5.5, h))

func _weather_node() -> Node:
	if not is_instance_valid(_weather) or not _weather.is_inside_tree() or _weather.get_parent() != get_parent():
		_weather = get_parent().get_node_or_null("Weather")
	return _weather

func _season() -> float:
	var weather := _weather_node()
	return float(SEASON_SHARE.get(str(weather.season), 1.0)) if weather != null else 1.0

func _dry() -> float:
	var weather := _weather_node()
	if weather == null or not (weather.params is Dictionary): return 1.0
	var p: Dictionary = weather.params
	var wet := maxf(float(p.get("rain", 0.0)), maxf(float(p.get("snow", 0.0)), float(p.get("hail", 0.0))))
	return 1.0 - smoothstep(0.05, 0.2, wet)

func _place_density(eye: Vector3, delta: float) -> float:
	_density_age += delta
	if not DENSITY_CACHE or _density_age >= DENSITY_SECONDS or not _density_eye.is_finite() \
			or _density_eye.distance_squared_to(eye) > DENSITY_STEP * DENSITY_STEP:
		_density_eye = eye; _density_age = 0.0; _density_value = _density(eye)
	return _density_value

## Everfree (dark forest) 1, towns and cities 0.25, everywhere else 0.55.
func _density(pos: Vector3) -> float:
	var forest := preload("res://world/life/everfree_habitat.gd").strength(pos)
	if forest > 0.5: return lerpf(0.55, 1.0, forest)
	var region := WorldLayout.nearest(pos)
	if region.is_empty() or WorldLayout.distance_to(region, pos) > 0.0: return 0.55
	if str(region.get("biome", "")) == "dark_forest": return 1.0
	if str(region.get("kind", "")) in ["town", "city", "sky_city"]: return 0.25
	return 0.55

func _try_spawn(camera: Camera3D) -> void:
	var eye := camera.global_position
	for attempt in 6:
		var angle := _rng.randf() * TAU
		var r := _rng.randf_range(SPAWN_MIN, SPAWN_MAX)
		var at := Vector3(eye.x + cos(angle) * r, eye.y, eye.z + sin(angle) * r)
		# Denser places keep more of their candidates.
		if _rng.randf() > _density(at) / 1.0: continue
		var ground := _open_ground(at)
		if not ground.is_finite(): continue
		_spawn(ground)
		return

## The terrain point under `at`, or INF when it is under a roof, a prop, or water.
func _open_ground(at: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 60.0, at + Vector3.DOWN * 120.0, 1)
	var hit := space.intersect_ray(query)
	var y := NAN
	if not hit.is_empty():
		if not (hit.collider is Terrain3D): return Vector3.INF
		y = (hit.position as Vector3).y
	elif is_instance_valid(WorldTerrain.instance):
		y = WorldTerrain.instance.height_at(at)
	if not is_finite(y) or y < WorldLayout.sea_level() + 0.5: return Vector3.INF
	return Vector3(at.x, y, at.z)

func _spawn(ground: Vector3) -> void:
	var count := _rng.randi_range(14, 36)
	var radius := _rng.randf_range(3.0, 6.5)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D; mm.use_custom_data = true
	mm.mesh = _quad; mm.instance_count = count
	for i in count:
		var dir := Vector3(_rng.randfn(), 0.0, _rng.randfn()).normalized() * sqrt(_rng.randf()) * radius
		dir.y = _rng.randf_range(0.3, 2.6)
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, dir))
		mm.set_instance_custom_data(i, Color(_rng.randf(), _rng.randf(), _rng.randf(), _rng.randf_range(2.5, 7.0)))
	mm.custom_aabb = AABB(Vector3(-radius - 3.0, -1.0, -radius - 3.0), Vector3(radius * 2.0 + 6.0, 6.0, radius * 2.0 + 6.0))
	var node := MultiMeshInstance3D.new(); node.name = "Swarm"; node.multimesh = mm
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node); node.global_position = ground
	node.set_instance_shader_parameter("fade", 0.0)
	_swarms.append({"node": node, "age": 0.0, "life": _rng.randf_range(90.0, 240.0), "fading_out": false})
