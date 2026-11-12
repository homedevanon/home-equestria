extends Node3D
## Rare, non-combat watchers. Spawn behind cover; stalk unseen, flee when noticed.
const ACTOR := preload("res://world/creatures/timberwolf_actor.gd")
const HABITAT := preload("res://world/life/everfree_habitat.gd")
const PLACEMENT := preload("res://world/navigation/roster_placement.gd")
const MODEL := "res://world/characters/timberwolf/timberwolf.tscn"
const MAX_WOLVES := 2
const MIN_DISTANCE := 26.0
var camera_source: Callable
var habitat_source: Callable
var daylight_source: Callable
var rng := RandomNumberGenerator.new()
var wolves: Array[CharacterBody3D] = []
var _scene: PackedScene
var _loading := false
var _spawn_in := 25.0
var _think_in := 0.0
var _cursor := 0
var _lights: Array[Node] = []
var _light_in := 0.0
var _profile: Resource
var _capsule := CapsuleShape3D.new()
var spawn_attempts := 0

func _ready() -> void:
	rng.randomize(); _spawn_in = rng.randf_range(20.0, 45.0)
	_profile = preload("res://world/characters/locomotion/pony_gait_profile.gd").new()
	_profile.radius = 0.65; _profile.clearance = 1.4
	_profile.step_height = 0.3; _profile.max_slope_degrees = 30.0
	_capsule.radius = 0.42; _capsule.height = 1.3

## Claim every owned request even if the player leaves the forest before it completes.
func _collect_model() -> void:
	if not _loading:return
	var state:=ResourceLoader.load_threaded_get_status(MODEL)
	if state==ResourceLoader.THREAD_LOAD_IN_PROGRESS:return
	if state!=ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		_scene=ResourceLoader.load_threaded_get(MODEL) as PackedScene
	_loading=false

func _exit_tree() -> void:
	if not _loading:return
	if ResourceLoader.load_threaded_get_status(MODEL)!=ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		ResourceLoader.load_threaded_get(MODEL)
	_loading=false

func _camera() -> Camera3D:
	if camera_source.is_valid(): return camera_source.call() as Camera3D
	return preload("res://world/player_view.gd").camera(self)

func habitat(at: Vector3) -> float:
	return float(habitat_source.call(at)) if habitat_source.is_valid() else HABITAT.strength(at)

func _physics_process(delta: float) -> void:
	_collect_model()
	var camera := _camera()
	if camera == null: return
	_light_in -= delta
	var eye := camera.global_position
	for wolf in wolves: wolf.observer = eye
	_think_in -= delta
	_spawn_in -= delta
	if _think_in > 0.0: return
	_think_in = 0.25
	var inside := habitat(eye) > 0.5
	# The light list is read only by think() and try_spawn() (via dark/bright), so it is gathered
	# only when one of them can run: no group scan every second in town. Still at most 1 s old.
	if _light_in <= 0.0 and (inside or not wolves.is_empty()):
		_light_in = 1.0
		_lights = get_tree().get_nodes_in_group("night_lights")
		for light in get_tree().get_nodes_in_group("creature_repelling_lights"):
			if not _lights.has(light): _lights.append(light)
	if not wolves.is_empty():
		_cursor %= wolves.size()
		var wolf: CharacterBody3D = wolves[_cursor]; _cursor += 1
		think(wolf, camera, inside)
	if not inside: return
	if _scene == null:
		if not _loading:
			_loading = ResourceLoader.load_threaded_request(MODEL) == OK
		return
	if _spawn_in <= 0.0:
		_spawn_in = rng.randf_range(40.0, 100.0)
		if wolves.size() < MAX_WOLVES and rng.randf() < 0.65: try_spawn(camera)

func ground(at: Vector3) -> Vector3:
	var wanted := at
	if is_instance_valid(WorldTerrain.instance):
		var height: float = WorldTerrain.instance.height_at(at)
		if not is_finite(height): return Vector3.INF
		wanted.y = height + 0.25
	else:
		var hit := _ray(at + Vector3.UP * 4.0, at + Vector3.DOWN * 15.0)
		if hit.is_empty(): return Vector3.INF
		wanted.y = float(hit.position.y) + 0.25
	return PLACEMENT.support(get_world_3d().direct_space_state, wanted, _profile)

func _ray(a: Vector3, b: Vector3) -> Dictionary:
	return get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(a, b, 1))

func covered(at: Vector3, eye: Vector3) -> bool:
	var sideways := Vector3(at.z - eye.z, 0.0, eye.x - at.x).normalized() * 0.65
	for offset in [Vector3.UP * 1.2, Vector3.UP * 0.55 + sideways, Vector3.UP * 0.55 - sideways]:
		if _ray(eye, at + offset).is_empty(): return false
	return true

func exposed(at: Vector3, camera: Camera3D) -> bool:
	for height in [0.55, 1.2]:
		var point: Vector3 = at + Vector3.UP * float(height)
		if camera.is_position_in_frustum(point) and _ray(camera.global_position, point).is_empty(): return true
	return false

func noticed(at: Vector3, camera: Camera3D) -> bool:
	var target := at + Vector3.UP * 0.9 - camera.global_position
	return (-camera.global_basis.z).dot(target.normalized()) > cos(deg_to_rad(24.0)) and exposed(at, camera)

func bright(at: Vector3) -> bool:
	for node in _lights:
		if not is_instance_valid(node) or not node is Light3D: continue
		var light := node as Light3D
		if not light.is_visible_in_tree() or light.light_energy < 0.12: continue
		var range_m := 0.0
		if light is OmniLight3D: range_m = (light as OmniLight3D).omni_range * 0.75
		elif light is SpotLight3D:
			var spot := light as SpotLight3D
			range_m = spot.spot_range * 0.8
			if (-spot.global_basis.z).dot((at - spot.global_position).normalized()) < cos(deg_to_rad(spot.spot_angle)): continue
		if light.global_position.distance_to(at) < range_m and _ray(light.global_position, at + Vector3.UP * 0.8).is_empty(): return true
	return false

func dark(at: Vector3) -> bool:
	if bright(at): return false
	var clock := get_node_or_null("/root/TimeOfDay")
	var daylight: float = float(daylight_source.call()) if daylight_source.is_valid() else (float(clock.call("daylight")) if clock != null else 1.0)
	if daylight < 0.3: return true
	# Physical overhead cover can also make a daytime hiding place.
	var sun_direction: Vector3 = clock.call("sun_direction") if clock != null else Vector3.UP
	if sun_direction.y <= 0.02: return false
	return not _ray(at + Vector3.UP * 1.1, at + Vector3.UP * 1.1 + sun_direction * 35.0).is_empty()

func try_spawn(camera: Camera3D) -> bool:
	if _scene == null or wolves.size() >= MAX_WOLVES or habitat(camera.global_position) <= 0.5: return false
	for attempt in 4:
		spawn_attempts += 1
		var angle := rng.randf() * TAU
		var at := camera.global_position + Vector3(cos(angle), 0, sin(angle)) * rng.randf_range(45.0, 80.0)
		if habitat(at) < 0.65: continue
		at = ground(at)
		if not at.is_finite() or not covered(at, camera.global_position): continue
		if bright(at): continue
		var crowded := false
		for wolf in wolves:
			if wolf.global_position.distance_to(at) < 20.0: crowded = true
		if crowded: continue
		spawn_at(at)
		return true
	return false

func spawn_at(at: Vector3) -> CharacterBody3D:
	var wolf := ACTOR.new()
	wolf.name = "Timberwolf"; wolf.setup(_scene)
	add_child(wolf); wolf.global_position = at; wolf.destination = at
	wolf.desired_distance = rng.randf_range(34.0, 52.0)
	wolf.side = -1.0 if rng.randf() < 0.5 else 1.0
	wolf.reconsider_at = rng.randf_range(3.0, 9.0)
	wolves.append(wolf)
	return wolf

func think(wolf: CharacterBody3D, camera: Camera3D, inside: bool) -> void:
	var at := wolf.global_position
	var eye := camera.global_position
	var distance := Vector2(at.x - eye.x, at.z - eye.z).length()
	var visible := exposed(at, camera)
	if (distance > 145.0 or wolf.age > 300.0 or not inside or wolf.age > wolf.retreat_until + 12.0 and wolf.state == "retreating") and not visible:
		wolves.erase(wolf); wolf.queue_free(); return
	var alarm := distance < MIN_DISTANCE or noticed(at, camera) or bright(at) or not inside
	if alarm:
		wolf.retreat_until = wolf.age + rng.randf_range(8.0, 16.0)
		wolf.state = "retreating"
	wolf.retreating = wolf.age < wolf.retreat_until or not inside
	if wolf.retreating:
		wolf.requested_speed = 0.0
		move_hidden(wolf, camera, true)
		return
	if not dark(at):
		wolf.requested_speed = 0.0
		# Daytime encounter: leave, rather than exhibiting a monster in full light.
		wolf.state = "retreating"; wolf.retreat_until = wolf.age + 12.0; wolf.retreating = true
		move_hidden(wolf, camera, true)
		return
	if wolf.age < wolf.reconsider_at: return
	wolf.requested_speed = 0.0
	wolf.reconsider_at = wolf.age + rng.randf_range(0.8, 2.3)
	if visible or rng.randf() < 0.23:
		wolf.state = "lurking"
		return
	wolf.state = "stalking"
	move_hidden(wolf, camera, false)

func move_hidden(wolf: CharacterBody3D, camera: Camera3D, flee: bool) -> void:
	var away := wolf.global_position - camera.global_position; away.y = 0.0
	away = away.normalized() if away.length() > 0.01 else Vector3.RIGHT
	var distance := Vector2(wolf.global_position.x - camera.global_position.x, wolf.global_position.z - camera.global_position.z).length()
	var heading := away
	if not flee:
		var tangent: Vector3 = Vector3(-away.z, 0.0, away.x) * float(wolf.side)
		heading = (tangent * 0.65 + away * clampf((wolf.desired_distance - distance) / 10.0, -1.0, 1.0)).normalized()
	for angle in [0.0, 0.65, -0.65, 1.15, -1.15]:
		var direction := heading.rotated(Vector3.UP, float(angle))
		if flee and direction.dot(away) < 0.1: continue
		var end := safe_step(wolf.global_position, direction * (2.0 if flee else 1.0))
		if not end.is_finite(): continue
		if Vector2(end.x - camera.global_position.x, end.z - camera.global_position.z).length() < MIN_DISTANCE and not flee: continue
		if not flee and (not covered(end, camera.global_position) or bright(end)): continue
		wolf.destination = end
		wolf.requested_speed = 2.6 if flee else (0.43 if distance < 48.0 else 1.0)
		return

func safe_step(start: Vector3, motion: Vector3) -> Vector3:
	var end := start + motion
	if habitat(end) < 0.55: return Vector3.INF
	# Midpoint prevents crossing a narrow stream or ditch between safe endpoints.
	var previous := start
	for fraction in [0.5, 1.0]:
		var point := ground(start + motion * float(fraction))
		if not point.is_finite() or absf(point.y - previous.y) > 0.4: return Vector3.INF
		previous = point
	end = previous
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _capsule; query.collision_mask = 1
	query.transform.origin = start + Vector3.UP * 0.78
	query.motion = end - start
	var cast: PackedFloat32Array = get_world_3d().direct_space_state.cast_motion(query)
	if cast.size() != 2 or cast[0] < 0.99: return Vector3.INF
	return end
