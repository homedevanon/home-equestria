extends Node3D
## Falling autumn leaves and spring petals (W2-SEAS-E 2026-11-08, M-SEA-12 / M-SEA-18; design
## captures/overhaul-2026-11-08/seasons/AUDIT_AND_DESIGN.md 6.3). Child "SeasonParticles" of the
## season state (world/seasons/season_state.gd FEATURES), which calls setup(state).
##
## One GPUParticles3D, 1200 particles at High scaled by the season_particle_scale quality key and the
## Seasonal effects setting (Reduced halves, Off none). The particles fall from the crowns of the
## trees within 35 m of the camera (world/seasons/tree_query.gd: public foliage data only), drift
## with the weather's wind and gusts, flutter and tumble, land on the ground (a small height map
## around the camera; on roofs and porches through the weather's precipitation heightfield while
## it follows the camera, i.e. while something falls) and dissolve there.
## - Autumn: leaves from every non-evergreen crown, more as the season's leaf drop rises, coloured
##   along the season (green-gold, orange-red, brown).
## - Spring: petals from blossom trees while season_blossom is up.
## - Summer and winter, or Seasonal effects Off: no particle node and no timer at all.
##
## Cost: one particle draw (draw_pass_1 with world/terrain/kits/grassy_fields/falling_leaf.gdshader),
## all motion in the particle shader below. GDScript runs on a 2 Hz timer only while active: the
## emission points and ground map are rebuilt when the camera has moved 10 m, wind and amount are
## written only when they change.
const TREE_QUERY := preload("res://world/seasons/tree_query.gd")
const PLAYER_VIEW := preload("res://world/player_view.gd")
const HOUSE_INTERIOR := preload("res://world/buildings/house_interior.gd")
const LEAF_SHADER := preload("res://world/terrain/kits/grassy_fields/falling_leaf.gdshader")
const LEAF_MASK := preload("res://world/foliage/everfree_trees/leaf_mask.res")
const LEAF_ATLAS := preload("res://world/vfx/textures/leaf_atlas.png")
const AMOUNT_HIGH := 1200
const LIFETIME := 18.0
## 35 m until 2026-11-10: in town the nearest trees stand 30 to 45 m from the street.
const TREE_RADIUS := 55.0
const REBUILD_DISTANCE := 10.0
const MAX_POINTS := 256
## Ground height map around the build centre: GROUND_CELLS x GROUND_CELLS at GROUND_STEP m.
const GROUND_CELLS := 32
const GROUND_STEP := 4.0
const POLL := 0.5
## Leaves per second per crown at full rate; AMOUNT/LIFETIME is the most the emitter can give.
const PER_TREE_RATE := 2.5
## Above this height over the ground (flying) nothing is emitted.
const MAX_EYE_HEIGHT := 45.0
## Wind direction shared with weather.gd's rain and snow push.
const WIND_DIR := Vector3(1.0, 0.0, 0.35)
## Default season_particle_scale per quality preset (Very Low .. Ultra) when the key is missing.
const TIER_SCALE := [0.25, 0.5, 0.75, 1.0, 1.0]

const PROCESS_CODE := """shader_type particles;
// Falling leaves / petals (world/seasons/season_particles.gd). CUSTOM: x seed, y age, z landed
// age (-1 while falling), w size.
uniform sampler2D points : filter_nearest, repeat_disable;
uniform int point_count = 0;
uniform sampler2D ground_map : filter_linear, repeat_disable;
uniform vec4 ground_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec3 wind = vec3(0.3, 0.0, 0.1);
uniform float gust = 0.0;
uniform float fall_speed = 0.9;
uniform float sway = 0.7;
uniform float land_seconds = 5.0;
uniform float roof_collision = 0.0;
uniform vec2 size_range = vec2(0.09, 0.14);
uniform vec4 tint_a : source_color = vec4(0.95, 0.6, 0.15, 1.0);
uniform vec4 tint_b : source_color = vec4(0.75, 0.25, 0.08, 1.0);

float rand_from_seed(inout uint seed) {
	int k;
	int s = int(seed);
	if (s == 0) { s = 305420679; }
	k = s / 127773;
	s = 16807 * (s - k * 127773) - 2836 * k;
	if (s < 0) { s += 2147483647; }
	seed = uint(s);
	return float(seed % uint(65536)) / 65535.0;
}

uint hash(uint x) {
	x = ((x >> uint(16)) ^ x) * uint(73244475);
	x = ((x >> uint(16)) ^ x) * uint(73244475);
	x = (x >> uint(16)) ^ x;
	return x;
}

mat3 rot_axis(vec3 a, float ang) {
	float s = sin(ang);
	float c = cos(ang);
	float oc = 1.0 - c;
	return mat3(vec3(oc * a.x * a.x + c, oc * a.x * a.y + a.z * s, oc * a.z * a.x - a.y * s),
		vec3(oc * a.x * a.y - a.z * s, oc * a.y * a.y + c, oc * a.y * a.z + a.x * s),
		vec3(oc * a.z * a.x + a.y * s, oc * a.y * a.z - a.x * s, oc * a.z * a.z + c));
}

float ground_at(vec2 xz) {
	vec2 uv = clamp((xz - ground_rect.xy) / ground_rect.zw, vec2(0.0), vec2(1.0));
	return textureLod(ground_map, uv, 0.0).r;
}

void start() {
	uint seed = hash(NUMBER + uint(1) + RANDOM_SEED);
	if (point_count <= 0) {
		ACTIVE = false;
	} else {
		int i = min(int(rand_from_seed(seed) * float(point_count)), point_count - 1);
		vec4 p = texelFetch(points, ivec2(i, 0), 0);
		float a = rand_from_seed(seed) * 6.2831853;
		float r = sqrt(rand_from_seed(seed)) * p.w;
		vec3 pos = p.xyz + vec3(cos(a) * r, (rand_from_seed(seed) - 0.35) * p.w * 0.7, sin(a) * r);
		float size = mix(size_range.x, size_range.y, rand_from_seed(seed));
		TRANSFORM = mat4(vec4(size, 0.0, 0.0, 0.0), vec4(0.0, size, 0.0, 0.0), vec4(0.0, 0.0, size, 0.0), vec4(pos, 1.0));
		VELOCITY = vec3(0.0);
		float shade = mix(0.85, 1.1, rand_from_seed(seed));
		COLOR = vec4(mix(tint_a.rgb, tint_b.rgb, rand_from_seed(seed)) * shade, 1.0);
		CUSTOM = vec4(rand_from_seed(seed), 0.0, -1.0, size);
	}
}

void process() {
	float seed = CUSTOM.x;
	CUSTOM.y += DELTA;
	float age = CUSTOM.y;
	float size = CUSTOM.w;
	vec3 pos = TRANSFORM[3].xyz;
	float phase = seed * 37.0;
	if (CUSTOM.z < 0.0) {
		float s = sin(age * mix(2.2, 4.0, fract(seed * 7.3)) + phase);
		vec3 side = vec3(cos(phase), 0.0, sin(phase));
		float g = gust * (0.6 + 0.4 * sin(TIME * 0.9 + pos.x * 0.07 + pos.z * 0.05));
		vec3 drift = wind * (0.35 + g * 1.8);
		float fall = fall_speed * mix(0.75, 1.25, fract(seed * 13.1)) * (1.0 - 0.45 * abs(s));
		VELOCITY = side * s * sway + drift + vec3(0.0, -fall, 0.0);
		vec3 axis = normalize(vec3(sin(phase), 0.6, cos(phase * 1.3)));
		mat3 rot = rot_axis(axis, age * mix(1.5, 4.0, fract(seed * 3.7)) + phase);
		TRANSFORM[0] = vec4(rot[0] * size, 0.0);
		TRANSFORM[1] = vec4(rot[1] * size, 0.0);
		TRANSFORM[2] = vec4(rot[2] * size, 0.0);
		float ground = ground_at(pos.xz);
		bool on_roof = roof_collision > 0.5 && COLLIDED;
		if (pos.y <= ground + 0.02 || on_roof) {
			CUSTOM.z = 0.0;
			VELOCITY = vec3(0.0);
			if (!on_roof) { TRANSFORM[3].y = ground + 0.02; }
			float c = cos(phase);
			float sn = sin(phase);
			TRANSFORM[0] = vec4(vec3(c, 0.0, sn) * size, 0.0);
			TRANSFORM[1] = vec4(vec3(sn, 0.0, -c) * size, 0.0);
			TRANSFORM[2] = vec4(vec3(0.0, size, 0.0), 0.0);
		}
	} else {
		CUSTOM.z += DELTA;
		VELOCITY = vec3(0.0);
	}
	float landed = CUSTOM.z < 0.0 ? 1.0 : 1.0 - clamp(CUSTOM.z / land_seconds, 0.0, 1.0);
	COLOR.a = min(landed, 1.0 - smoothstep(LIFETIME - 1.5, LIFETIME, age));
	if (COLOR.a <= 0.0) { ACTIVE = false; }
}
"""

var state: Node
## Test hooks: a fixed camera point (Vector3.INF: the real camera) and a fixed tree list.
var eye_override := Vector3.INF
var trees_override: Array = []
var use_trees_override := false
## What the emitter shows now: "" (nothing), "leaves" or "petals".
var mode := ""
var point_count := 0
var ground_rect := Rect2()

var _particles: GPUParticles3D
var _process_material: ShaderMaterial
var _draw_material: ShaderMaterial
var _points_image: Image
var _points_texture: ImageTexture
var _ground_image: Image
var _ground_texture: ImageTexture
var _timer: Timer
var _centre := Vector3.INF
var _scale := 0.0
var _rate := 0.0
var _written: Dictionary = {}
var _process_shader: Shader

func setup(season: Node) -> void:
	state = season
	if state == null: return
	for pair: Array in [["season_changed", _on_season_signal], ["day_stepped", _on_season_signal], ["effects_changed", _on_season_signal]]:
		if state.has_signal(pair[0]) and not state.is_connected(pair[0], pair[1]): state.connect(pair[0], pair[1])
	var quality: Node = get_node_or_null("/root/Quality")
	if quality != null and quality.has_signal("preset_changed") and not quality.is_connected("preset_changed", _on_quality):
		quality.connect("preset_changed", _on_quality)
	refresh()

func _on_season_signal(_value: Variant = null) -> void: refresh()
func _on_quality(_preset: int) -> void: refresh(true)

## What the season asks for now: ["" | "leaves" | "petals", intensity 0..1].
func wanted() -> Array:
	if state == null: return ["", 0.0]
	var season := str(state.call("season"))
	if season == "autumn":
		# Full crowns all autumn (dev 2026-11-09): a light drift of leaves, more as they turn; none
		# after the Running of the Leaves has stripped the trees.
		if state.has_method("leaves_have_run") and bool(state.call("leaves_have_run")): return ["", 0.0]
		var turn := float(state.call("leaf_turn")) if state.has_method("leaf_turn") else 0.5
		# dev 2026-11-10: "no leaves falling". A steady fall from the first day, thick by the brown end.
		return ["leaves", clampf(0.4 + turn * 0.6, 0.0, 1.0)]
	if season == "spring":
		# Petals come down from every flowering tree: a few in full bloom, thick as it goes over.
		var blossom := float(state.call("petal_fall")) if state.has_method("petal_fall") else float(state.call("blossom"))
		if blossom > 0.02: return ["petals", clampf(blossom, 0.0, 1.0)]
	return ["", 0.0]

## Particle scale: the quality key (or its tier default) times the Seasonal effects setting.
func particle_scale() -> float:
	var level := int(state.call("effects_level")) if state != null and state.has_method("effects_level") else 2
	if level <= 0: return 0.0
	var tier := 1.0
	var quality: Node = get_node_or_null("/root/Quality")
	if quality != null:
		var preset := clampi(int(quality.get("preset")), 0, TIER_SCALE.size() - 1)
		var value: Variant = quality.call("get_value", "season_particle_scale", TIER_SCALE[preset])
		tier = clampf(float(value), 0.0, 1.0) if value is float or value is int else float(TIER_SCALE[preset])
	return tier * (0.5 if level == 1 else 1.0)

## Re-reads season, intensity and scale; builds or frees the emitter. force rebuilds the node
## (quality change: a new particle amount restarts the emitter anyway).
func refresh(force := false) -> void:
	var want := wanted()
	var amount_scale := particle_scale()
	var next_mode: String = want[0]
	if next_mode == "" or amount_scale <= 0.0:
		_stop(); return
	if force or not is_instance_valid(_particles) or not is_equal_approx(amount_scale, _scale):
		_stop(); _scale = amount_scale; _build()
	if next_mode != mode:
		mode = next_mode
		_centre = Vector3.INF   # rebuild the points for the new kind of tree
	_rate = float(want[1])
	_apply_palette()
	poll()

func _stop() -> void:
	mode = ""; point_count = 0; _centre = Vector3.INF; _written.clear()
	if is_instance_valid(_timer): _timer.queue_free()
	if is_instance_valid(_particles): _particles.queue_free()
	_timer = null; _particles = null

func _build() -> void:
	if _process_shader == null:
		_process_shader = Shader.new(); _process_shader.code = PROCESS_CODE
	_points_image = Image.create(MAX_POINTS, 1, false, Image.FORMAT_RGBAF)
	_points_texture = ImageTexture.create_from_image(_points_image)
	_ground_image = Image.create(GROUND_CELLS, GROUND_CELLS, false, Image.FORMAT_RF)
	_ground_texture = ImageTexture.create_from_image(_ground_image)
	_process_material = ShaderMaterial.new(); _process_material.shader = _process_shader
	_process_material.set_shader_parameter("points", _points_texture)
	_process_material.set_shader_parameter("ground_map", _ground_texture)
	_draw_material = ShaderMaterial.new(); _draw_material.shader = LEAF_SHADER
	_draw_material.set_shader_parameter("leaf_texture", LEAF_MASK)
	var quad := QuadMesh.new(); quad.size = Vector2.ONE; quad.material = _draw_material
	_particles = GPUParticles3D.new(); _particles.name = "FallingLeaves"
	_particles.amount = maxi(16, int(round(AMOUNT_HIGH * _scale)))
	_particles.lifetime = LIFETIME
	_particles.local_coords = false
	_particles.emitting = false
	_particles.amount_ratio = 0.0
	_particles.visibility_aabb = AABB(Vector3(-72, -40, -72), Vector3(144, 75, 144))
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_particles.process_material = _process_material
	_particles.draw_pass_1 = quad
	add_child(_particles)
	_timer = Timer.new(); _timer.name = "LeafPoll"; _timer.wait_time = POLL; _timer.autostart = true
	_timer.timeout.connect(poll)
	add_child(_timer)

func _apply_palette() -> void:
	if not is_instance_valid(_process_material): return
	var colours := palette(mode, float(state.call("progress")) if state != null and state.has_method("progress") else 0.5)
	_set_param("tint_a", colours[0]); _set_param("tint_b", colours[1])
	_set_param("size_range", Vector2(0.05, 0.075) if mode == "petals" else Vector2(0.12, 0.19))
	# Autumn leaves are real leaf shapes; petals keep the leaf mask.
	if is_instance_valid(_draw_material):
		_draw_material.set_shader_parameter("leaf_atlas", LEAF_ATLAS)
		_draw_material.set_shader_parameter("atlas_cells", 0 if mode == "petals" else 4)
	_set_param("fall_speed", 0.55 if mode == "petals" else 0.9)
	_set_param("sway", 0.9 if mode == "petals" else 0.7)

## Two colours the particles mix between: petals pink to white; leaves along the autumn
## (green-gold early, orange-red mid, brown late).
static func palette(which: String, progress: float) -> Array:
	if which == "petals": return [Color(1.0, 0.78, 0.86), Color(1.0, 0.94, 0.96)]
	var p := clampf(progress, 0.0, 1.0)
	var early := [Color(0.92, 0.74, 0.2), Color(0.62, 0.62, 0.18)]
	var mid := [Color(0.95, 0.45, 0.1), Color(0.78, 0.2, 0.08)]
	var late := [Color(0.52, 0.31, 0.12), Color(0.74, 0.42, 0.13)]
	if p < 0.5:
		var t := smoothstep(0.15, 0.5, p)
		return [(early[0] as Color).lerp(mid[0], t), (early[1] as Color).lerp(mid[1], t)]
	var u := smoothstep(0.5, 0.9, p)
	return [(mid[0] as Color).lerp(late[0], u), (mid[1] as Color).lerp(late[1], u)]

func _set_param(param: String, value: Variant) -> void:
	if not is_instance_valid(_process_material): return
	var last: Variant = _written.get(param)
	if last != null and typeof(last) == typeof(value) and last == value: return
	_written[param] = value
	_process_material.set_shader_parameter(param, value)

func _eye() -> Vector3:
	if eye_override.is_finite(): return eye_override
	var cam := PLAYER_VIEW.camera(self)
	return cam.global_position if cam != null else Vector3.INF

func _weather() -> Node:
	return get_tree().get_first_node_in_group("weather") if is_inside_tree() else null

## The 2 Hz tick while active: rebuild after 10 m, wind, roof collision and the emission amount.
func poll() -> void:
	if not is_instance_valid(_particles): return
	var eye := _eye()
	if not eye.is_finite():
		_particles.emitting = false; return
	# Nothing can fall high above the trees or indoors: no tree query and no ground map there
	# (fast flight rebuilt both several times a second for nothing). The first tick back rebuilds.
	var ground := _ground_y(eye)
	var high := is_finite(ground) and eye.y - ground > MAX_EYE_HEIGHT
	var indoors := is_inside_tree() and HOUSE_INTERIOR.at(get_tree(), eye - Vector3.UP * 1.2) != null
	if high or indoors:
		if _particles.emitting: _particles.emitting = false
		return
	if not _centre.is_finite() or Vector2(eye.x - _centre.x, eye.z - _centre.z).length() > REBUILD_DISTANCE:
		rebuild(eye)
	var weather := _weather()
	var params: Dictionary = weather.get("params") if weather != null and weather.get("params") is Dictionary else {}
	var gust := snappedf(float(params.get("gust", 0.0)), 0.05)
	var falling := float(params.get("rain", 0.0)) > 0.01 or float(params.get("snow", 0.0)) > 0.01 or float(params.get("hail", 0.0)) > 0.01
	_set_param("gust", gust)
	_set_param("wind", WIND_DIR.normalized() * (0.4 + gust * 1.4))
	# The weather's roof heightfield follows the camera only while rain, snow or hail falls.
	_set_param("roof_collision", 1.0 if falling else 0.0)
	var ratio := emission_ratio(point_count, _rate, gust, _particles.amount)
	var emit := ratio > 0.0
	var snapped_ratio := snappedf(ratio, 0.02)
	if not is_equal_approx(_particles.amount_ratio, snapped_ratio): _particles.amount_ratio = snapped_ratio
	if _particles.emitting != emit: _particles.emitting = emit

## Share of the emitter used: PER_TREE_RATE leaves a second per crown at full intensity (a few
## trees give a few leaves, a park many), more in a gust, never above the whole emitter.
static func emission_ratio(crowns: int, intensity: float, gust: float, amount: int) -> float:
	if crowns <= 0 or intensity <= 0.0 or amount <= 0: return 0.0
	var per_second := float(crowns) * PER_TREE_RATE * intensity * (1.0 + gust * 0.6)
	return clampf(per_second / (float(amount) / LIFETIME), 0.0, 1.0)

## Emission points from the crowns around eye and the ground map under them.
func rebuild(eye: Vector3) -> void:
	_centre = eye
	# The particles live in world space (start() ignores EMISSION_TRANSFORM), so moving the node only
	# moves its visibility box along with the camera.
	if is_instance_valid(_particles): _particles.position = eye
	var trees: Array = trees_override if use_trees_override else TREE_QUERY.canopies(get_tree() if is_inside_tree() else null, eye, TREE_RADIUS)
	set_points(TREE_QUERY.emission_points(trees, mode, eye, MAX_POINTS, not use_trees_override))
	_build_ground(eye)

## Writes the emission points (Vector4 crown centre + radius) into the points texture.
func set_points(points: PackedVector4Array) -> void:
	point_count = mini(points.size(), MAX_POINTS)
	if _points_image == null: return
	for i in point_count:
		var p: Vector4 = points[i]
		_points_image.set_pixel(i, 0, Color(p.x, p.y, p.z, p.w))
	_points_texture.update(_points_image)
	_written.erase("point_count")
	_set_param("point_count", point_count)

## Point i as written to the texture (tests).
func point(i: int) -> Vector4:
	if _points_image == null or i < 0 or i >= point_count: return Vector4.ZERO
	var c := _points_image.get_pixel(i, 0)
	return Vector4(c.r, c.g, c.b, c.a)

func _ground_y(at: Vector3) -> float:
	var terrain: WorldTerrain = WorldTerrain.instance if is_instance_valid(WorldTerrain.instance) else null
	return terrain.height_at(at) if terrain != null else NAN

## GROUND_CELLS^2 terrain heights around eye (400 reads per 10 m walked). Where there is no
## terrain (tests, the sea) the lowest crown point minus 6 m stands in.
func _build_ground(eye: Vector3) -> void:
	if _ground_image == null: return
	var span := GROUND_STEP * float(GROUND_CELLS - 1)
	var origin := Vector2(eye.x, eye.z) - Vector2.ONE * span * 0.5
	var fallback := eye.y - 1.7
	for i in point_count:
		fallback = minf(fallback, point(i).y - 6.0)
	var terrain: WorldTerrain = WorldTerrain.instance if is_instance_valid(WorldTerrain.instance) else null
	for z in GROUND_CELLS:
		for x in GROUND_CELLS:
			var h := NAN
			if terrain != null: h = terrain.height_at(Vector3(origin.x + x * GROUND_STEP, eye.y, origin.y + z * GROUND_STEP))
			_ground_image.set_pixel(x, z, Color(h if is_finite(h) else fallback, 0, 0))
	_ground_texture.update(_ground_image)
	# Texel centres sit on the samples: the rect spans half a step beyond them on each side.
	ground_rect = Rect2(origin - Vector2.ONE * GROUND_STEP * 0.5, Vector2.ONE * GROUND_STEP * GROUND_CELLS)
	_set_param("ground_rect", Vector4(ground_rect.position.x, ground_rect.position.y, ground_rect.size.x, ground_rect.size.y))

## Live particle node (tests and the bench).
func emitter() -> GPUParticles3D:
	return _particles if is_instance_valid(_particles) else null
