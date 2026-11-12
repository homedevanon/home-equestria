extends Node
## Ground seasons near the camera (W2-SEAS-B 2026-11-08; design captures/overhaul-2026-11-08/
## seasons/AUDIT_AND_DESIGN.md 6.2, 6.3, 6.5). season_state.gd adds this node (its FEATURES list)
## and calls setup(). The shader side is world/terrain/gaea_fragment.gdshaderinc and
## world/foliage/grass/ground_grass.gdshader.
##
## 1. Trodden snow: a size x size R8 image over SPAN metres round the camera, published as the
##    snow_trail_map / snow_trail_rect globals that season_snow_on() reads. The player and every
##    HERO/NEAR pony standing on the ground leave alternating hoofprints; the window scrolls in
##    whole texels when the camera moves STEP metres; falling snow (season_snow_fresh) fills the
##    prints again. Off on Low/Very Low (quality key snow_trails, read with a default) and with
##    Seasonal effects Off. Without snow it holds no image and the rect width is 0 (shader early-out).
## 2. Tree-crown shelter: a SHELTER_SIZE map over SHELTER_SPAN metres from the public tree records
##    (world/seasons/tree_query.gd canopies, else biome_foliage.bird_perches), rebuilt when the camera crosses a SHELTER_STEP grid line, only
##    while snow, leaf litter or wetness is on the ground. Bound on the terrain and grass materials
##    as season_shelter_map / season_shelter_rect.
## 3. Terrain switches: season_wet_surfaces and season_puddles from the quality tier (keys
##    wet_surfaces, puddles, read with defaults) and season_rain from the weather (puddle rings).
## No _process: one Timer, 10 Hz while trails are live, 1 Hz otherwise. One whole-image upload
## (64 KB at 256 px) at most per tick, and only after a print or a scroll.
const GROUP := "snow_trail"
const SPAN := 48.0
## Scroll step: a whole number of texels at every size (40 px at 256, 20 px at 128).
const STEP := 7.5
const PRINT_RADIUS := 0.13
const STRIDE := 0.45            # metres between prints
const PRINT_SIDE := 0.09        # left/right offset of alternating prints
const TELEPORT := 6.0           # a jump this long leaves no prints
const MAX_PRINTS := 8           # per walker per tick
const PLAYER_EYE_MAX := 2.6     # camera this high above the ground is not walking
const FOOT_MAX := 0.4           # pony origin this high above the ground is not walking
const FAST_TICK := 0.1
const SLOW_TICK := 1.0
const REFILL := 0.04            # share of a print filled per second while it snows
const CLEAR_BELOW := 0.06       # prints fainter than this are wiped
const MIN_COVER := 0.02
const SHELTER_SIZE := 128
const SHELTER_SPAN := 128.0
const SHELTER_STEP := 32.0
const CROWN_RADIUS := 3.5       # when the record gives none
const TREE_QUERY := "res://world/seasons/tree_query.gd"
const MEMBERS := &"sim_ponies"
const FAR_TIER := 2             # PonyCrowd.Tier.FAR
const PLAYER_KEY := -1
const BLACK := "res://world/seasons/baked/black_1x1.tres"
## Footstep leaf provider group (world/audio/ground_contact_audio.gd LEAF_GROUP).
const LEAF_GROUP := "leaf_ground"
const CLIMATE := preload("res://world/seasons/climate_map.gd")
const SNOW := preload("res://world/seasons/snow_cover_query.gd")

var season_state: Node
var auto_tick := true
## Trail resolution in use (0 = trails off).
var size := 0
var image: Image
var texture: ImageTexture
## World xz of the trail image's (0, 0) corner.
var origin := Vector2.ZERO
var shelter_image: Image
var shelter_texture: ImageTexture
var shelter_centre := Vector2(INF, INF)
var shelter_rect := Vector4.ZERO
## Counters for tests and the report.
var uploads := 0
var stamps := 0
var shelter_builds := 0
## Test hooks.
var camera_override: Node3D
var walkers_override: Array = []
var crowns_override: Variant = null       # PackedVector3Array of crowns (x, z, radius)
var materials_override: Array = []        # materials to bind instead of the terrain and grass
var quality_override: Variant = null      # {"preset": int, key: value}

var _dirty := false
var _peak := 0.0
var _refill_clock := 0.0
var _switch_clock := SLOW_TICK         # the first tick sets the switches at once
var _feet: Dictionary = {}                # walker key -> [Vector2 last print, side]
var _brushes: Dictionary = {}            # crown radius (whole metres) -> brush
var _bound: Dictionary = {}               # material instance id -> {param: value}
var _timer: Timer

func _init() -> void:
	add_to_group(GROUP)
	add_to_group(LEAF_GROUP)

func setup(state: Node) -> void:
	season_state = state
	if state != null and state.has_signal("effects_changed") and not state.is_connected("effects_changed", _on_changed):
		state.connect("effects_changed", _on_changed)
	var quality := get_node_or_null("/root/Quality")
	if quality != null and quality.has_signal("preset_changed") and not quality.is_connected("preset_changed", _on_changed):
		quality.connect("preset_changed", _on_changed)

func _ready() -> void:
	if not auto_tick: return
	_timer = Timer.new(); _timer.name = "GroundSeasonTick"; _timer.wait_time = SLOW_TICK; _timer.autostart = true
	_timer.timeout.connect(func() -> void: tick(_timer.wait_time))
	add_child(_timer)

func _exit_tree() -> void:
	if size > 0: RenderingServer.global_shader_parameter_set("snow_trail_rect", Vector4.ZERO)

func _on_changed(_value: Variant = null) -> void:
	_switch_clock = SLOW_TICK
	if is_inside_tree(): tick.call_deferred(0.0)

# ------------------------------------------------------------------ the tick

func tick(delta := FAST_TICK) -> void:
	var eye := _eye()
	if not eye.is_finite(): return
	var cover := _amount("snow_cover")
	_switch_clock += delta
	if _switch_clock >= SLOW_TICK:
		_switch_clock = 0.0
		_update_switches()
		_update_shelter(eye, cover > MIN_COVER or _amount("leaf_litter") > 0.01 or _amount("wetness") > 0.01)
	var want := trail_size() if cover > MIN_COVER else 0
	if want != size: resize(want, eye)
	if size > 0:
		scroll_to(eye)
		_stamp_walkers(eye)
		_refill(delta)
		if _dirty: _upload()
	if _timer != null: _timer.wait_time = FAST_TICK if size > 0 else SLOW_TICK

func _amount(getter: String) -> float:
	if season_state == null or not season_state.has_method(getter): return 0.0
	return float(season_state.call(getter))

func _eye() -> Vector3:
	if is_instance_valid(camera_override): return camera_override.global_position
	var camera := preload("res://world/player_view.gd").camera(self)
	return camera.global_position if camera != null else Vector3(INF, INF, INF)

# ------------------------------------------------------------------ quality

func _quality(key: String, fallback: Variant) -> Variant:
	if quality_override is Dictionary: return (quality_override as Dictionary).get(key, fallback)
	var quality := get_node_or_null("/root/Quality")
	return quality.call("get_value", key, fallback) if quality != null and quality.has_method("get_value") else fallback

func _preset() -> int:
	if quality_override is Dictionary: return int((quality_override as Dictionary).get("preset", 3))
	var quality := get_node_or_null("/root/Quality")
	return int(quality.get("preset")) if quality != null and "preset" in quality else 3

## Trail resolution for the current tier and the Seasonal effects setting (0 = off).
func trail_size() -> int:
	if season_state != null and season_state.has_method("effects_level") and int(season_state.call("effects_level")) == 0: return 0
	return size_for(_quality("snow_trails", null), _preset())

## The quality key snow_trails may be absent (default by tier: Very Low/Low off, Medium 128,
## High/Ultra 256), a bool, a pixel count or a word.
static func size_for(value: Variant, preset: int) -> int:
	if value == null: return 0 if preset <= 1 else (128 if preset == 2 else 256)
	if value is bool: return 256 if value else 0
	if value is int or value is float: return 256 if float(value) >= 192.0 else (128 if float(value) >= 64.0 else 0)
	var word := str(value).to_lower()
	if word.is_valid_float(): return size_for(word.to_float(), preset)
	return 0 if word in ["off", "false", "none", ""] else 256

static func _on(value: Variant) -> bool:
	if value is bool: return value
	if value is int or value is float: return float(value) > 0.0
	return str(value).to_lower() not in ["off", "false", "0", "none", ""]

# ------------------------------------------------------------------ trail image

func texel() -> float:
	return SPAN / float(size) if size > 0 else 0.0

## The trail window's corner for a camera position: the window centre snaps to the STEP grid.
static func window_origin(eye: Vector3) -> Vector2:
	return (Vector2(eye.x, eye.z) / STEP).round() * STEP - Vector2.ONE * SPAN * 0.5

func resize(pixels: int, eye: Vector3) -> void:
	size = pixels
	_feet.clear()
	_peak = 0.0
	if pixels <= 0:
		image = null; texture = null
		RenderingServer.global_shader_parameter_set("snow_trail_rect", Vector4.ZERO)
		if ResourceLoader.exists(BLACK): RenderingServer.global_shader_parameter_set("snow_trail_map", load(BLACK))
		return
	image = Image.create(pixels, pixels, false, Image.FORMAT_R8)
	texture = ImageTexture.create_from_image(image)
	origin = window_origin(eye)
	RenderingServer.global_shader_parameter_set("snow_trail_map", texture)
	_publish_rect()

func _publish_rect() -> void:
	RenderingServer.global_shader_parameter_set("snow_trail_rect", Vector4(origin.x, origin.y, SPAN, SPAN))

## Move the window with the camera; prints keep their world place (whole-texel shift).
func scroll_to(eye: Vector3) -> void:
	if image == null: return
	var target := window_origin(eye)
	if target == origin: return
	var shift := Vector2i(((target - origin) / texel()).round())
	origin = target
	if absi(shift.x) >= size or absi(shift.y) >= size or _peak <= 0.0:
		image.fill(Color(0, 0, 0))
	else:
		var moved := Image.create(size, size, false, Image.FORMAT_R8)
		moved.blit_rect(image, Rect2i(0, 0, size, size), -shift)
		image = moved
	_publish_rect()
	_dirty = true

## One hoofprint at a world xz (strength 0..1). False outside the window.
func stamp(xz: Vector2, strength := 1.0) -> bool:
	if image == null: return false
	var t := texel()
	var c := (xz - origin) / t
	var r := maxf(PRINT_RADIUS / t, 0.8)
	var lo := Vector2i((c - Vector2(r, r)).floor())
	var hi := Vector2i((c + Vector2(r, r)).floor())
	if hi.x < 0 or hi.y < 0 or lo.x >= size or lo.y >= size: return false
	for y in range(maxi(lo.y, 0), mini(hi.y, size - 1) + 1):
		for x in range(maxi(lo.x, 0), mini(hi.x, size - 1) + 1):
			var value := clampf(1.6 - Vector2(x + 0.5, y + 0.5).distance_to(c) / r, 0.0, 1.0) * strength
			if value > image.get_pixel(x, y).r: image.set_pixel(x, y, Color(value, 0, 0))
	stamps += 1
	_peak = 1.0
	_dirty = true
	return true

## Trodden amount at a world point (0 outside the window): snow_cover_query.gd trail_at().
func trail_at(pos: Vector3) -> float:
	if image == null: return 0.0
	var pixel := Vector2i(((Vector2(pos.x, pos.z) - origin) / texel()).floor())
	if pixel.x < 0 or pixel.y < 0 or pixel.x >= size or pixel.y >= size: return 0.0
	return image.get_pixel(pixel.x, pixel.y).r

## Walk a walker from its last print toward `feet`, leaving alternating prints every STRIDE.
func step(key: int, feet: Vector3) -> void:
	var at := Vector2(feet.x, feet.z)
	if not _feet.has(key):
		_feet[key] = [at, 1.0]
		return
	var last: Array = _feet[key]
	var from: Vector2 = last[0]
	var moved := at.distance_to(from)
	if moved < STRIDE: return
	if moved > TELEPORT:
		last[0] = at
		return
	var dir := (at - from) / moved
	var side := float(last[1])
	var prints := mini(int(moved / STRIDE), MAX_PRINTS)
	for i in prints:
		stamp(from + dir * STRIDE * (i + 1) + Vector2(-dir.y, dir.x) * PRINT_SIDE * side)
		side = -side
	last[0] = at if prints == MAX_PRINTS else from + dir * STRIDE * prints
	last[1] = side

func _ground(pos: Vector3) -> float:
	return WorldTerrain.instance.height_at(pos) if is_instance_valid(WorldTerrain.instance) else NAN

func _stamp_walkers(eye: Vector3) -> void:
	var seen := {}
	var half := SPAN * 0.5
	var centre := origin + Vector2.ONE * half
	# The player: the camera's ground point, while the camera is a walking height above it.
	var ground := _ground(eye)
	if not is_finite(ground) or eye.y - ground < PLAYER_EYE_MAX:
		seen[PLAYER_KEY] = true
		step(PLAYER_KEY, Vector3(eye.x, ground if is_finite(ground) else eye.y, eye.z))
	var walkers: Array = walkers_override if not walkers_override.is_empty() else get_tree().get_nodes_in_group(MEMBERS)
	for walker: Variant in walkers:
		if not is_instance_valid(walker) or not walker is Node3D: continue
		var pony: Node3D = walker
		if "sim_tier" in pony and int(pony.get("sim_tier")) == FAR_TIER: continue
		var pos := pony.global_position
		if absf(pos.x - centre.x) > half or absf(pos.z - centre.y) > half: continue
		var floor_y := _ground(pos)
		if is_finite(floor_y) and pos.y - floor_y > FOOT_MAX: continue
		var key := pony.get_instance_id()
		seen[key] = true
		step(key, pos)
	for key: int in _feet.keys():
		if not seen.has(key): _feet.erase(key)

## Falling snow fills the prints again (once a second, the whole image in C++).
func _refill(delta: float) -> void:
	_refill_clock += delta
	if _refill_clock < 1.0: return
	var seconds := _refill_clock
	_refill_clock = 0.0
	if _peak <= 0.0: return
	var rate := clampf((_amount("snow_fresh") - 0.5) * 2.0, 0.0, 1.0) * REFILL * seconds
	if rate <= 0.0: return
	_peak *= 1.0 - rate
	if _peak < CLEAR_BELOW:
		image.fill(Color(0, 0, 0)); _peak = 0.0
	else:
		image.adjust_bcs(1.0 - rate, 1.0, 1.0)
	_dirty = true

func _upload() -> void:
	_dirty = false
	if texture == null or image == null: return
	texture.update(image)
	uploads += 1

# ------------------------------------------------------------------ shelter map

## A soft disc: full shelter to 1.5 m inside the crown edge, none 0.5 m past it.
func _crown_brush(radius: float) -> Image:
	var key := clampi(roundi(radius), 1, 8)
	if _brushes.has(key): return _brushes[key]
	var t := SHELTER_SPAN / SHELTER_SIZE
	var half := int(ceil((key + 1.0) / t))
	var width := half * 2 + 1
	var brush := Image.create(width, width, false, Image.FORMAT_RGBA8)
	for y in width:
		for x in width:
			var d := Vector2(x - half, y - half).length() * t
			brush.set_pixel(x, y, Color(1, 1, 1, 1.0 - smoothstep(key - 1.5, key + 0.5, d)))
	_brushes[key] = brush
	return brush

## Crown shelter round `centre` from crowns (x, z, radius in metres).
func build_shelter(centre: Vector2, crowns: PackedVector3Array) -> void:
	if shelter_image == null: shelter_image = Image.create(SHELTER_SIZE, SHELTER_SIZE, false, Image.FORMAT_RGBA8)
	shelter_image.fill(Color(0, 0, 0, 1))
	var t := SHELTER_SPAN / SHELTER_SIZE
	var corner := centre - Vector2.ONE * SHELTER_SPAN * 0.5
	for crown: Vector3 in crowns:
		var brush := _crown_brush(crown.z)
		var half := brush.get_width() / 2
		var at := Vector2i(((Vector2(crown.x, crown.y) - corner) / t).floor()) - Vector2i(half, half)
		shelter_image.blend_rect(brush, Rect2i(Vector2i.ZERO, brush.get_size()), at)
	if shelter_texture == null: shelter_texture = ImageTexture.create_from_image(shelter_image)
	else: shelter_texture.update(shelter_image)
	shelter_centre = centre
	shelter_rect = Vector4(corner.x, corner.y, SHELTER_SPAN, SHELTER_SPAN)
	shelter_builds += 1

## Tree-crown shelter at a world point (0..1, faded at the window edge as in the shaders).
func canopy_at(pos: Vector3) -> float:
	if shelter_image == null or shelter_rect.z <= 0.0: return 0.0
	var uv := (Vector2(pos.x, pos.z) - Vector2(shelter_rect.x, shelter_rect.y)) / Vector2(shelter_rect.z, shelter_rect.w)
	var edge := minf(minf(uv.x, uv.y), minf(1.0 - uv.x, 1.0 - uv.y))
	if edge <= 0.0: return 0.0
	var pixel := Vector2i((uv * SHELTER_SIZE).floor()).clamp(Vector2i.ZERO, Vector2i.ONE * (SHELTER_SIZE - 1))
	return shelter_image.get_pixelv(pixel).r * smoothstep(0.0, 0.12, edge)

func _crowns(centre: Vector2, eye: Vector3) -> PackedVector3Array:
	if crowns_override != null: return crowns_override
	var result := PackedVector3Array()
	var origin := Vector3(centre.x, eye.y, centre.y)
	if ResourceLoader.exists(TREE_QUERY):
		var query: Variant = load(TREE_QUERY)
		if query is Script and (query as Script).can_instantiate():
			var rows: Variant = (query as GDScript).call("canopies", get_tree(), origin, SHELTER_SPAN * 0.71)
			if rows is Array:
				for row: Variant in rows:
					if row is Dictionary and (row as Dictionary).get("position") is Vector3:
						var at: Vector3 = (row as Dictionary).position
						result.append(Vector3(at.x, at.z, float((row as Dictionary).get("radius", CROWN_RADIUS))))
				return result
	for habitat: Node in get_tree().get_nodes_in_group("bird_habitats"):
		if not habitat.has_method("bird_perches"): continue
		var perches: Variant = habitat.call("bird_perches", origin, 0.0, SHELTER_SPAN * 0.71)
		if not perches is Array: continue
		for perch: Variant in perches:
			if perch is Dictionary and (perch as Dictionary).get("position") is Vector3:
				var at: Vector3 = (perch as Dictionary).position
				result.append(Vector3(at.x, at.z, CROWN_RADIUS))
	return result

func _update_shelter(eye: Vector3, active: bool) -> void:
	if not active:
		if shelter_rect.z > 0.0:
			shelter_rect = Vector4.ZERO
			shelter_centre = Vector2(INF, INF)
		_bind("season_shelter_rect", shelter_rect)
		return
	var centre := (Vector2(eye.x, eye.z) / SHELTER_STEP).round() * SHELTER_STEP
	if centre != shelter_centre:
		build_shelter(centre, _crowns(centre, eye))
		_bound.clear()   # rebind everything now and then, in case a material regenerated its shader
	_bind("season_shelter_map", shelter_texture)
	_bind("season_shelter_rect", shelter_rect)

# ------------------------------------------------------------------ material switches

func _update_switches() -> void:
	var preset := _preset()
	_bind("season_wet_surfaces", _on(_quality("wet_surfaces", preset >= 1)), true)
	_bind("season_puddles", _on(_quality("puddles", preset >= 2)), true)
	var rain := 0.0
	var weather: Node = get_tree().get_first_node_in_group("weather") if is_inside_tree() else null
	if weather != null and weather.get("params") is Dictionary:
		rain = snappedf(float((weather.get("params") as Dictionary).get("rain", 0.0)), 0.05)
	_bind("season_rain", rain, true)

## Every material that reads the ground-season inputs: the terrain's Terrain3D material and the
## ground grass ring materials (their materials live as long as the GroundGrass node).
func _targets(terrain_only: bool) -> Array:
	if not materials_override.is_empty(): return materials_override
	var result: Array = []
	if not is_instance_valid(WorldTerrain.instance): return result
	var terrain: Node = WorldTerrain.instance.get("terrain")
	var material: Variant = terrain.get("material") if terrain != null else null
	if material is Object and material != null: result.append(material)
	if terrain_only: return result
	var grass := WorldTerrain.instance.get_node_or_null("GroundGrass")
	var rings: Variant = grass.get("rings") if grass != null else null
	if rings is Array:
		for ring: Variant in rings:
			if ring is Dictionary and (ring as Dictionary).get("material") is ShaderMaterial and not ((ring as Dictionary).lod as Dictionary).has("shader"):
				result.append((ring as Dictionary).material)
	return result

func _bind(param: String, value: Variant, terrain_only := false) -> void:
	if value == null: return
	for material: Object in _targets(terrain_only):
		var key := material.get_instance_id()
		var known: Dictionary = _bound.get(key, {})
		if known.has(param) and typeof(known[param]) == typeof(value) and known[param] == value: continue
		known[param] = value
		_bound[key] = known
		if material.has_method("set_shader_param"): material.call("set_shader_param", param, value)
		elif material is ShaderMaterial: (material as ShaderMaterial).set_shader_parameter(param, value)

# ------------------------------------------------------------------ CPU mirror of the shelter

static func road_id(id: int) -> float:
	return 1.0 if id == 1 or id == 4 or id == 5 else 0.0

static func forest_id(id: int) -> float:
	return 0.8 if id == 11 else (0.45 if id == 10 else 0.0)

static func rock_id(id: int) -> float:
	return 1.0 if id in [6, 7, 12, 13, 14, 15, 21] else 0.0

## (road, forest, rock) shares of the control texel at `pos`.
static func _ids(data: Object, pos: Vector3) -> Vector3:
	var bits := int(data.call("get_control", pos))
	if bits == 0xffffffff: return Vector3.ZERO
	var base := (bits >> 27) & 31; var over := (bits >> 22) & 31; var blend := float((bits >> 14) & 255) / 255.0
	return Vector3(lerpf(road_id(base), road_id(over), blend), lerpf(forest_id(base), forest_id(over), blend), lerpf(rock_id(base), rock_id(over), blend))

func _terrain_data() -> Object:
	var terrain: Node = WorldTerrain.instance.get("terrain") if is_instance_valid(WorldTerrain.instance) else null
	return terrain.get("data") if terrain != null else null

## How much of the snow a point is spared (0..1), as gaea_fragment.gdshaderinc computes it:
## trodden roads (and 2 m past their edge), forest floor, tree crowns. Snow there =
## season_snow_on(...) x (1 - shelter_at). Nearest control texel instead of the shader's blend.
func shelter_at(pos: Vector3) -> float:
	var road := 0.0; var forest := 0.0
	var data := _terrain_data()
	if data != null:
		var here := _ids(data, pos)
		var wide := 0.0
		for offset: Vector3 in [Vector3(2, 0, 0), Vector3(-2, 0, 0), Vector3(0, 0, 2), Vector3(0, 0, -2)]:
			wide += _ids(data, pos + offset).x
		road = clampf(maxf(here.x, 0.5 * wide), 0.0, 1.0)
		forest = here.y
	return maxf(road * 0.85, maxf(forest, canopy_at(pos) * 0.85))

## Snow lying at a world point (0..1), shelter included: the terrain shader's snow, for snowballs
## and footsteps. snow_cover_query.cover_at() without shelter x (1 - shelter_at) is the same.
func snow_at(pos: Vector3, normal := Vector3.ZERO) -> float:
	var cover := _amount("snow_cover")
	if cover <= 0.001: return 0.0
	if normal == Vector3.ZERO:
		normal = WorldTerrain.instance.normal_at(pos) if is_instance_valid(WorldTerrain.instance) else Vector3.UP
	var amount := SNOW.snow_on(normal, pos, cover, trail_at(pos))
	return amount * (1.0 - shelter_at(pos)) if amount > 0.0 else 0.0

## Leaf litter at a world point (0..1) for footsteps (ground_contact_audio.gd, group leaf_ground):
## the terrain's litter amount (gaea_fragment.gdshaderinc l_amount) without its fleck pattern.
func leaves_at(pos: Vector3) -> float:
	var litter := _amount("leaf_litter")
	if litter <= 0.001: return 0.0
	var ids := Vector3.ZERO
	var data := _terrain_data()
	if data != null: ids = _ids(data, pos)
	var under := maxf(clampf(ids.y * 2.0, 0.0, 1.0), canopy_at(pos))
	var amount := litter * CLIMATE.sample(Vector2(pos.x, pos.z), 1) * lerpf(0.2, 1.0, under) * (1.0 - 0.8 * ids.x) * (1.0 - ids.z)
	if amount > 0.0 and _amount("snow_cover") > 0.001: amount *= 1.0 - snow_at(pos)
	return clampf(amount, 0.0, 1.0)
