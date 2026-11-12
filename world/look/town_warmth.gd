extends Node3D
## Town warmth (dev 2026-11-10, look overhaul stage 2: "warm windows at dusk", "there's no glow in
## the windows"). For the houses near the camera whose household has a lamp on
## (world/life/house_lamps.gd -> window_glow.gd _lit_places):
##   - a pool of warm light on the ground outside each ground-floor window (Decal nodes: projected
##     in the world, so the headset sees them like any lit surface; nothing is drawn on the screen);
##   - smoke rising from the roof top, drifting with the weather's wind.
## Textures are real assets (Kenney particle pack, CC0; sources in the private
## archive), placeholders dev may swap by replacing the files under world/vfx/textures/.
##
## Cost: a 0.5 Hz step that re-picks the nearest lit houses; a fixed pool of POOLS decals and
## SMOKES particle emitters (SMOKE_PUFFS wisps each), hidden when unused. The roof top of each house
## design is measured once from its meshes and cached.
## Rollback: ENABLED = false (or POOLS = 0 / SMOKES = 0 for one half).

const ENABLED := true
const GLOW := preload("res://world/buildings/window_glow/window_glow.gd")
const PLAYER_VIEW := preload("res://world/player_view.gd")
## A soft pool with an uneven heart. The hard-cored dot tried first (2026-11-10) drew three
## stage spotlights on the snow, each standing free of its wall.
const POOL_TEXTURE := preload("res://world/vfx/textures/pool_light.png")
## One soft wisp, many overlapping and faint. The 4x4 puff sheet tried first (2026-11-10) has
## hard cartoon edges with a dark fringe: a column of it read as grey stamps on the sky.
const SMOKE_TEXTURE := preload("res://world/vfx/textures/smoke_soft_a.png")
const SMOKE_PUFFS := 30
const STEP := 2.0
const POOLS := 40
const SMOKES := 6
const POOL_RANGE := 110.0
const SMOKE_RANGE := 130.0
const POOL_COLOR := Color(1.0, 0.70, 0.36)
## Light on the ground at full night; scaled down with daylight.
const POOL_ENERGY := 0.85
## A window counts as ground floor below this height above the house's floor, in metres.
const GROUND_FLOOR_M := 3.4
const POOL_SIZE := Vector3(4.4, 3.0, 5.6)
## The pool's brightest point sits this far out from the wall, in metres; the pool reaches back
## under the wall, so the light starts at the wall's foot.
const POOL_OUT := 1.3

var _pools: Array[Decal] = []
var _smokes: Array[GPUParticles3D] = []
var _smoke_material: StandardMaterial3D
var _timer := 0.0
var _energy := -1.0
var _report := ""
var _seen_houses := 0
## scene path -> roof top in the house's own space (Vector3), measured once.
static var _roof_tops: Dictionary = {}


func _ready() -> void:
	if not ENABLED:
		set_process(false)
		return
	for i in POOLS:
		var pool := Decal.new()
		pool.texture_emission = POOL_TEXTURE
		pool.size = POOL_SIZE
		pool.modulate = POOL_COLOR
		pool.albedo_mix = 0.0
		pool.emission_energy = 0.0
		pool.upper_fade = 0.6; pool.lower_fade = 0.6
		pool.normal_fade = 0.3
		pool.distance_fade_enabled = true
		pool.distance_fade_begin = POOL_RANGE * 0.7; pool.distance_fade_length = POOL_RANGE * 0.3
		pool.visible = false
		add_child(pool)
		_pools.append(pool)
	_smoke_material = StandardMaterial3D.new()
	_smoke_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_smoke_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_smoke_material.albedo_texture = SMOKE_TEXTURE
	_smoke_material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	_smoke_material.billboard_keep_scale = true
	_smoke_material.vertex_color_use_as_albedo = true
	_smoke_material.disable_receive_shadows = true
	for i in SMOKES:
		var smoke := GPUParticles3D.new()
		smoke.amount = SMOKE_PUFFS
		smoke.lifetime = 12.0
		smoke.preprocess = 12.0
		smoke.local_coords = false
		smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		smoke.visibility_aabb = AABB(Vector3(-14, -2, -14), Vector3(28, 26, 28))
		var process := ParticleProcessMaterial.new()
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		process.emission_sphere_radius = 0.12
		process.direction = Vector3.UP
		process.spread = 9.0
		process.initial_velocity_min = 0.55; process.initial_velocity_max = 0.85
		process.gravity = Vector3(0.25, 0.12, 0.1)
		process.damping_min = 0.05; process.damping_max = 0.12
		process.angle_min = 0.0; process.angle_max = 360.0
		process.angular_velocity_min = -8.0; process.angular_velocity_max = 8.0
		process.scale_min = 0.9; process.scale_max = 1.3
		var grow := Curve.new()
		grow.add_point(Vector2(0.0, 0.14)); grow.add_point(Vector2(0.3, 0.5)); grow.add_point(Vector2(1.0, 1.0))
		var grow_texture := CurveTexture.new(); grow_texture.curve = grow
		process.scale_curve = grow_texture
		var fade := Gradient.new()
		fade.set_color(0, Color(1, 1, 1, 0.0)); fade.set_color(1, Color(1, 1, 1, 0.0))
		fade.add_point(0.08, Color(1, 1, 1, 0.34)); fade.add_point(0.55, Color(1, 1, 1, 0.16))
		var fade_texture := GradientTexture1D.new(); fade_texture.gradient = fade
		process.color_ramp = fade_texture
		smoke.process_material = process
		var quad := QuadMesh.new(); quad.size = Vector2(3.4, 3.4); quad.material = _smoke_material
		smoke.draw_pass_1 = quad
		smoke.emitting = false; smoke.visible = false
		add_child(smoke)
		_smokes.append(smoke)


func _process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0: return
	_timer = STEP
	var camera := PLAYER_VIEW.camera(self)
	if camera == null: return
	var eye := camera.global_position
	var clock: Node = get_node_or_null("/root/TimeOfDay")
	var daylight: float = float(clock.call("daylight")) if clock != null else 1.0
	var energy := POOL_ENERGY * (1.0 - smoothstep(0.05, 0.55, daylight))
	# The nearest lit houses.
	var lit: Array = []
	_seen_houses = 0
	for glow: Node in get_tree().get_nodes_in_group("window_glow"):
		var houses: Variant = glow.get("_houses")
		if not houses is Array: continue
		for entry: Variant in houses:
			var house := entry as Node3D
			if not is_instance_valid(house) or not house.is_inside_tree(): continue
			_seen_houses += 1
			var d := house.global_position.distance_to(eye)
			if d > SMOKE_RANGE: continue
			if not GLOW._lit_places.has(GLOW._place_of(house)): continue
			lit.append([d, house])
	lit.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var report := "lit=%d houses=%d places=%d" % [lit.size(), _seen_houses, GLOW._lit_places.size()]
	if report != _report:
		_report = report
		print("[warmth] ", report)
	_place_pools(lit, energy)
	_place_smoke(lit, daylight)


## One pool per ground-floor window of the nearest lit houses, until the decals run out.
func _place_pools(lit: Array, energy: float) -> void:
	var used := 0
	if energy > 0.02:
		var designs: Dictionary = GLOW._load_panes()
		for row: Array in lit:
			if float(row[0]) > POOL_RANGE or used >= _pools.size(): break
			var house: Node3D = row[1]
			var design := house.scene_file_path.get_file().get_basename()
			if not designs.has(design): continue
			var data: Dictionary = designs[design]
			var to_world := house.global_transform
			var metres := maxf(to_world.basis.get_scale().y, 0.001)
			var floor_y: float = float((data.centre as Array)[1])
			for pane: Dictionary in data.panes:
				if used >= _pools.size(): break
				var centre := GLOW._vec(pane.c)
				if (centre.y - floor_y) * metres > GROUND_FLOOR_M: continue
				var normal := (to_world.basis * GLOW._vec(pane.n))
				normal.y = 0.0
				if normal.length_squared() < 0.0001: continue
				normal = normal.normalized()
				var at := to_world * centre + normal * POOL_OUT
				if is_instance_valid(WorldTerrain.instance):
					var ground: float = WorldTerrain.instance.height_at(at)
					if is_finite(ground): at.y = ground
				var pool := _pools[used]
				used += 1
				# The decal projects down its own -Y; its long side runs away from the wall.
				pool.global_transform = Transform3D(Basis(Vector3.UP.cross(normal).normalized(), Vector3.UP, normal), at + Vector3(0.0, 0.4, 0.0))
				pool.emission_energy = energy
				pool.visible = true
	for i in range(used, _pools.size()):
		_pools[i].visible = false


func _place_smoke(lit: Array, daylight: float) -> void:
	var weather: Node = get_tree().get_first_node_in_group("weather")
	var gust := 0.0
	if weather != null and weather.get("params") is Dictionary: gust = float((weather.get("params") as Dictionary).get("gust", 0.0))
	# Smoke takes the light of the hour: pale by day; after dark it stays a little lighter than
	# the sky behind it (it holds the last light and the glow of the town), never a dark blot.
	var tint := Color(0.46, 0.48, 0.62).lerp(Color(0.93, 0.93, 0.95), daylight)
	_smoke_material.albedo_color = tint
	for i in _smokes.size():
		var smoke := _smokes[i]
		if i >= lit.size():
			smoke.emitting = false
			if smoke.visible and not smoke.has_meta("fading"):
				smoke.set_meta("fading", true)
			continue
		var house: Node3D = (lit[i] as Array)[1]
		var top := house.global_transform * _roof_top(house)
		if smoke.global_position.distance_squared_to(top) > 0.25:
			smoke.global_position = top
			smoke.restart()
		(smoke.process_material as ParticleProcessMaterial).gravity = Vector3(0.25 + gust * 1.6, 0.12, 0.1 + gust * 0.55)
		smoke.remove_meta("fading")
		smoke.visible = true
		smoke.emitting = true


## The top of the house's roof in its own space: the chimney when the highest geometry is a small
## cluster, else a point on the ridge. Measured once per house design.
static func _roof_top(house: Node3D) -> Vector3:
	var key := house.scene_file_path
	if _roof_tops.has(key): return _roof_tops[key]
	var inverse := house.global_transform.affine_inverse()
	var points: PackedVector3Array = []
	# Box corners first: they bound every vertex, so they alone fix the height range. Triangles
	# are then read only from meshes that reach the top band (the roof), once per mesh; reading
	# every shell mesh twice stalled the first evening in town.
	var shells: Array = []
	var floor_y := INF; var roof_y := -INF
	for node: Node in house.find_children("*", "MeshInstance3D", true, false):
		var instance := node as MeshInstance3D
		if instance.mesh == null or not instance.is_visible_in_tree(): continue
		# The shell only: rooms, linings and furniture sit under the interior node.
		var inside := false
		var parent := instance.get_parent()
		while parent != null and parent != house:
			if parent.is_in_group("house_interiors"): inside = true; break
			parent = parent.get_parent()
		if inside: continue
		var to_house := inverse * instance.global_transform
		var box := instance.mesh.get_aabb()
		var reach := -INF
		for corner in 8:
			var at: Vector3 = to_house * box.get_endpoint(corner)
			points.append(at)
			floor_y = minf(floor_y, at.y); roof_y = maxf(roof_y, at.y); reach = maxf(reach, at.y)
		shells.append([instance, to_house, reach])
	var top_band := roof_y - (roof_y - floor_y) * 0.05
	for shell: Array in shells:
		if float(shell[2]) < top_band: continue
		var faces: PackedVector3Array = (shell[0] as MeshInstance3D).mesh.get_faces()
		if faces.size() > 60000: continue
		var to_house: Transform3D = shell[1]
		for vertex: Vector3 in faces:
			points.append(to_house * vertex)
	var top := Vector3(0.0, 1.0, 0.0)
	if not points.is_empty():
		var low := INF; var high := -INF
		var bounds := AABB(points[0], Vector3.ZERO)
		for point: Vector3 in points:
			low = minf(low, point.y); high = maxf(high, point.y)
			bounds = bounds.expand(point)
		var band := high - (high - low) * 0.05
		var sum := Vector3.ZERO; var count := 0
		var cap := AABB(Vector3(0, high, 0), Vector3.ZERO); var first := true
		for point: Vector3 in points:
			if point.y < band: continue
			sum += point; count += 1
			if first: cap = AABB(point, Vector3.ZERO); first = false
			else: cap = cap.expand(point)
		top = sum / float(maxi(count, 1))
		top.y = high
		# A long cap is a roof ridge, not a chimney: stand a third of the way along it.
		if cap.size.x > bounds.size.x * 0.35 or cap.size.z > bounds.size.z * 0.35:
			top = Vector3(cap.position.x + cap.size.x * 0.3, high, cap.position.z + cap.size.z * 0.3)
	_roof_tops[key] = top
	return top
