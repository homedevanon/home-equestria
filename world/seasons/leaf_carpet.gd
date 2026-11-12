extends Node3D
## Fallen leaves lying under the trees (dev 2026-11-10: "why are there no leaves on the floor").
## Child "LeafCarpet" of the season state (season_state.gd FEATURES), which calls setup(state).
##
## Why this and not the ground shader's leaf litter (world/terrain/gaea_fragment.gdshaderinc):
## that litter is paint on the terrain, and the ground grass stands on top of the terrain and
## hides it, so in a meadow or a town garden nothing showed. These are leaves, cut to the shapes
## of real leaves: handfuls of about a dozen on one quad (world/vfx/textures/leaf_litter.png)
## resting on the grass tops, and single leaves (leaf_atlas.png) among them and flat on the paths.
## Thick under the crown and thinning outward, a little down the wind. Each tree's leaves have that tree's own colours
## (world/foliage/vegetation_color.gdshaderinc vegetation_autumn_tree) and are browner than the
## ones still on it.
##
## Why handfuls: single leaves at about four to the square metre sat down in the 0.3 m grass and
## read as a few specks (shots of 2026-11-10). A carpet needs ten times that; a handful per quad
## gives it for the same number of quads.
##
## How many: the season's leaf litter (season_state.gd leaf_litter(): few on the first day, many by
## the brown end, most after the Running of the Leaves) times PER_TREE handfuls and SINGLES single leaves for each broadleaf crown
## within REACH of the eye, nearest first, at most MAX_LEAVES in all. Where a tree's leaves lie is
## fixed by the tree, so they are in the same place every time they come back into reach.
##
## Cost: one MultiMesh draw of alpha-cut quads without shadows. GDScript runs on a 2 Hz timer
## only while there is litter: it lays at most TREES_PER_POLL new trees per tick (a height
## lookup per leaf) and rewrites the buffer only when the set of trees changed. Nothing exists
## outside autumn and early winter, or with Seasonal effects off.
## Spring (dev 2026-11-10): the same carpet lies as fallen petals under the trees that flower
## (tree_query.gd flowers()), in each tree's blossom colour: handfuls of small petals
## (world/vfx/textures/petal_litter.png) on the grass tops and flat on the paths, by the season's
## petal_litter(): a few from full bloom, most while the blossom goes over, gone by summer.
## Limits: leaves do not move when walked through and do not avoid house floors.
## Rollback: ENABLED = false.

const ENABLED := true
const TREE_QUERY := preload("res://world/seasons/tree_query.gd")
const TERRAIN_PATHS := preload("res://world/navigation/terrain_paths.gd")
const CLIMATE := preload("res://world/seasons/climate_map.gd")
const PLAYER_VIEW := preload("res://world/player_view.gd")
const SHADER := preload("res://world/seasons/leaf_carpet.gdshader")
const LEAF_ATLAS := preload("res://world/vfx/textures/leaf_atlas.png")
const LEAF_LITTER := preload("res://world/vfx/textures/leaf_litter.png")
const PETAL_LITTER := preload("res://world/vfx/textures/petal_litter.png")
## Petal handfuls under one flowering tree of 2.5 m crown radius at full petal litter.
const PETALS_PER_TREE := 520
const REACH := 48.0
## Handfuls and single leaves under one tree of 2.5 m crown radius at full litter.
const PER_TREE := 600
const SINGLES := 500
## Most quads drawn in all (a handful is one quad).
const MAX_LEAVES := 20000
const POLL := 0.5
const MOVE_STEP := 6.0
const TREES_PER_POLL := 1
## While trees wait to be laid the tick runs at this pace: the same two trees a POLL as before,
## one per frame instead of both in one (a tree is up to about 2,000 leaves of script work).
const POLL_LAYING := 0.25
## Leaf length in metres [least, most], and the side of a handful (its leaves are about a third of it).
const SIZE := Vector2(0.13, 0.21)
const HANDFUL := Vector2(0.5, 0.75)
## The carpet reaches this many crown radii out, plus a margin (metres), and lies this far down
## the wind (metres; the wind direction of world/weather/weather.gd).
const SPREAD := 1.5
const MARGIN := 2.0
const DOWNWIND := Vector3(1.0, 0.0, 0.35)
## A leaf rests this high above the ground: on a path, a single leaf among the grass [least,
## most], and a handful on the grass tops: under the crown, where the grass lies pressed down by
## the litter (ground_grass.gdshader LOOK_LEAF_PRESS, 0.12 to 0.2 m), and outside it (0.27 to 0.45 m).
const ON_PATH := 0.015
const IN_GRASS := Vector2(0.04, 0.2)
const ON_PRESSED := Vector2(0.09, 0.17)
const ON_GRASS := Vector2(0.16, 0.27)
const MIN_DECIDUOUS := 0.5
## Share of the leaves per quality preset (Very Low .. Ultra).
const TIER_SCALE := [0.3, 0.5, 0.75, 1.0, 1.0]
const FLOATS := 16      # per leaf: 12 of the transform, 4 of custom data

var state: Node
## Leaves drawn now (read by tools/look/baseline_shots.gd).
var leaves := 0
var _instance: MultiMeshInstance3D
var _mesh: MultiMesh
var _timer: Timer
var _trees: Dictionary = {}       # tree key -> PackedFloat32Array of its leaves
var _shown: Array = []            # keys in the buffer now
var _centre := Vector3.INF
var _litter := -1.0
var _petals := false          # spring: petals under flowering trees instead of leaves
var _paths: RefCounted


func setup(season: Node) -> void:
	state = season
	if state == null or not ENABLED: return
	for pair: Array in [["season_changed", _on_season_signal], ["day_stepped", _on_season_signal], ["effects_changed", _on_season_signal], ["leaves_ran", _on_season_signal]]:
		if state.has_signal(pair[0]) and not state.is_connected(pair[0], pair[1]): state.connect(pair[0], pair[1])
	var quality: Node = get_node_or_null("/root/Quality")
	if quality != null and quality.has_signal("preset_changed") and not quality.is_connected("preset_changed", _on_season_signal):
		quality.connect("preset_changed", _on_season_signal)
	refresh()


func _on_season_signal(_value: Variant = null) -> void: refresh()


## How much litter the season asks for, 0 when there is to be no carpet at all.
func wanted() -> float:
	if state == null or not ENABLED: return 0.0
	var season := str(state.call("season"))
	if state.has_method("effects_level") and int(state.call("effects_level")) <= 0: return 0.0
	if season == "spring": return float(state.call("petal_litter")) if state.has_method("petal_litter") else 0.0
	if season != "autumn" and season != "winter": return 0.0
	return float(state.call("leaf_litter"))


func refresh() -> void:
	var litter := wanted()
	if litter <= 0.02:
		_stop(); return
	if _instance == null: _build()
	# The count under every tree follows the litter: lay them again when it has moved.
	var petals := state != null and str(state.call("season")) == "spring"
	if absf(litter - _litter) > 0.02 or petals != _petals:
		_litter = litter
		_petals = petals
		_trees.clear(); _centre = Vector3.INF
	poll()


func _stop() -> void:
	if is_instance_valid(_timer): _timer.queue_free()
	if is_instance_valid(_instance): _instance.queue_free()
	_timer = null; _instance = null; _mesh = null
	_trees.clear(); _shown.clear(); _centre = Vector3.INF; _litter = -1.0; leaves = 0


func _build() -> void:
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("leaf_atlas", LEAF_ATLAS)
	material.set_shader_parameter("leaf_litter", LEAF_LITTER)
	material.set_shader_parameter("petal_litter", PETAL_LITTER)
	material.set_shader_parameter("fade_from", REACH - 10.0)
	material.set_shader_parameter("fade_to", REACH)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.material = material
	_mesh = MultiMesh.new()
	_mesh.transform_format = MultiMesh.TRANSFORM_3D
	_mesh.use_custom_data = true
	_mesh.mesh = quad
	_instance = MultiMeshInstance3D.new()
	_instance.name = "Leaves"
	_instance.multimesh = _mesh
	_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_instance.visible = false
	# Leaves are placed in world space; the node stays at the origin.
	_instance.custom_aabb = AABB(Vector3(-100000.0, -2000.0, -100000.0), Vector3(200000.0, 6000.0, 200000.0))
	add_child(_instance)
	_timer = Timer.new(); _timer.name = "CarpetPoll"; _timer.wait_time = POLL; _timer.autostart = true
	_timer.timeout.connect(poll)
	add_child(_timer)


## The 2 Hz step: which trees are in reach, lay a few new ones, rewrite the buffer if the set changed.
func poll() -> void:
	if _instance == null: return
	var camera := PLAYER_VIEW.camera(self)
	if camera == null: return
	var eye := camera.global_position
	if not eye.is_finite(): return
	if _centre.is_finite() and eye.distance_to(_centre) < MOVE_STEP: return
	var rows: Array = []
	for row: Dictionary in TREE_QUERY.canopies(get_tree() if is_inside_tree() else null, eye, REACH):
		if _petals:
			if not TREE_QUERY.flowers(row): continue
		elif int(row.kind) != TREE_QUERY.BROADLEAF: continue
		var at: Vector3 = row.position
		if CLIMATE.sample(Vector2(at.x, at.z), 1) < MIN_DECIDUOUS: continue
		rows.append(row)
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return (a.position as Vector3).distance_squared_to(eye) < (b.position as Vector3).distance_squared_to(eye))
	var keys: Array = []
	var in_reach := {}
	var laid := 0
	var total := 0
	var waiting := false
	for row: Dictionary in rows: in_reach[_key(row.position)] = true
	for row: Dictionary in rows:
		var key := _key(row.position)
		if not _trees.has(key):
			if laid >= TREES_PER_POLL:
				waiting = true
				continue
			_trees[key] = _lay(row)
			laid += 1
		var count := (_trees[key] as PackedFloat32Array).size() / FLOATS
		if total + count > MAX_LEAVES: break
		total += count
		keys.append(key)
	# Trees that fell out of reach are forgotten (they are laid the same way on return). A tree in
	# reach that did not fit under MAX_LEAVES keeps its leaves: forgetting it laid it again on
	# every move.
	for key: Variant in _trees.keys():
		if not in_reach.has(key): _trees.erase(key)
	# While trees still wait to be laid, the next tick carries on from here.
	_centre = Vector3.INF if waiting else eye
	var pace := POLL_LAYING if waiting else POLL
	if is_instance_valid(_timer) and not is_equal_approx(_timer.wait_time, pace): _timer.wait_time = pace
	if keys != _shown: _write(keys)


func _write(keys: Array) -> void:
	_shown = keys
	var buffer := PackedFloat32Array()
	for key: Variant in keys: buffer.append_array(_trees[key])
	leaves = buffer.size() / FLOATS
	_instance.visible = leaves > 0
	if leaves == 0: return
	# The count first, then the whole buffer at once: a MultiMesh whose buffer was never written
	# crashed the engine on the first frame drawn (world/weather/snow_field.gd).
	_mesh.instance_count = leaves
	_mesh.buffer = buffer


func _key(at: Vector3) -> String:
	return "%d_%d" % [roundi(at.x * 2.0), roundi(at.z * 2.0)]


## The leaves under one tree, as MultiMesh buffer rows. Fixed by the tree's place.
func _lay(row: Dictionary) -> PackedFloat32Array:
	var crown: Vector3 = row.position
	var radius := float(row.radius)
	var root: Vector3 = row.get("root", Vector3(crown.x, 0.0, crown.z))
	var kind := autumn_tree(root)
	if _petals: return _lay_petals(row)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(_key(crown))
	var fallen := _litter > 0.9     # after the Running: every leaf is down, and lies wider
	var reach := radius * SPREAD * (1.3 if fallen else 1.0) + MARGIN
	var share := _litter * _scale() * clampf(radius / 2.5, 0.6, 2.0)
	var handfuls := int(round(PER_TREE * share))
	var count := handfuls + int(round(SINGLES * share))
	var out := PackedFloat32Array()
	out.resize(count * FLOATS)
	var drift := DOWNWIND.normalized() * reach * 0.25
	var terrain := is_instance_valid(WorldTerrain.instance)
	for index: int in count:
		var angle := rng.randf() * TAU
		var away := reach * pow(rng.randf(), 0.75)
		var at := Vector3(crown.x + cos(angle) * away + drift.x, crown.y, crown.z + sin(angle) * away + drift.z)
		var ground := crown.y - 4.0
		if terrain:
			var height: float = WorldTerrain.instance.height_at(at)
			if is_finite(height): ground = height
		# On a path only single leaves, flat: a handful there would lie as one flat card.
		var path := _path_weight(at) > 0.3
		var handful := index < handfuls and not path
		var tip := 0.45
		if path: at.y = ground + ON_PATH
		elif handful:
			# The crown's shelter (world/seasons/snow_trail.gd: full to 1.5 m inside its edge, none 0.5 m past it).
			var open := smoothstep(radius - 1.5, radius + 0.5, Vector2(at.x - crown.x, at.z - crown.z).length())
			at.y = ground + rng.randf_range(lerpf(ON_PRESSED.x, ON_GRASS.x, open), lerpf(ON_PRESSED.y, ON_GRASS.y, open)); tip = 0.16
		else: at.y = ground + rng.randf_range(IN_GRASS.x, IN_GRASS.y)
		var size := rng.randf_range(HANDFUL.x, HANDFUL.y) if handful else rng.randf_range(SIZE.x, SIZE.y)
		# Lying on its back, turned any way round, tipped a little as it rests on the grass.
		var basis := Basis(Vector3.UP, rng.randf() * TAU) * Basis(Vector3.RIGHT, -PI * 0.5 + rng.randf_range(-tip, tip)) * Basis.from_scale(Vector3.ONE * size)
		var slot := index * FLOATS
		out[slot] = basis.x.x; out[slot + 1] = basis.y.x; out[slot + 2] = basis.z.x; out[slot + 3] = at.x
		out[slot + 4] = basis.x.y; out[slot + 5] = basis.y.y; out[slot + 6] = basis.z.y; out[slot + 7] = at.y
		out[slot + 8] = basis.x.z; out[slot + 9] = basis.y.z; out[slot + 10] = basis.z.z; out[slot + 11] = at.z
		out[slot + 12] = kind.x; out[slot + 13] = kind.y; out[slot + 14] = rng.randf(); out[slot + 15] = 1.0 if handful else 0.0
	return out


## The fallen petals under one flowering tree, as MultiMesh buffer rows: handfuls only (custom w
## = 2), custom y = the tree's blossom kind. Fixed by the tree's place.
func _lay_petals(row: Dictionary) -> PackedFloat32Array:
	var crown: Vector3 = row.position
	var radius := float(row.radius)
	var blossom := TREE_QUERY.blossom_kind(row)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(_key(crown)) + 7
	var reach := radius * SPREAD + MARGIN
	var count := int(round(PETALS_PER_TREE * _litter * _scale() * clampf(radius / 2.5, 0.6, 2.0)))
	var out := PackedFloat32Array()
	out.resize(count * FLOATS)
	var drift := DOWNWIND.normalized() * reach * 0.25
	var terrain := is_instance_valid(WorldTerrain.instance)
	for index: int in count:
		var angle := rng.randf() * TAU
		var away := reach * pow(rng.randf(), 0.75)
		var at := Vector3(crown.x + cos(angle) * away + drift.x, crown.y, crown.z + sin(angle) * away + drift.z)
		var ground := crown.y - 4.0
		if terrain:
			var height: float = WorldTerrain.instance.height_at(at)
			if is_finite(height): ground = height
		var path := _path_weight(at) > 0.3
		at.y = ground + (ON_PATH + rng.randf() * 0.01 if path else rng.randf_range(ON_GRASS.x, ON_GRASS.y))
		var size := rng.randf_range(HANDFUL.x, HANDFUL.y)
		var tip := 0.02 if path else 0.16
		var basis := Basis(Vector3.UP, rng.randf() * TAU) * Basis(Vector3.RIGHT, -PI * 0.5 + rng.randf_range(-tip, tip)) * Basis.from_scale(Vector3.ONE * size)
		var slot := index * FLOATS
		out[slot] = basis.x.x; out[slot + 1] = basis.y.x; out[slot + 2] = basis.z.x; out[slot + 3] = at.x
		out[slot + 4] = basis.x.y; out[slot + 5] = basis.y.y; out[slot + 6] = basis.z.y; out[slot + 7] = at.y
		out[slot + 8] = basis.x.z; out[slot + 9] = basis.y.z; out[slot + 10] = basis.z.z; out[slot + 11] = at.z
		out[slot + 12] = 0.0; out[slot + 13] = blossom; out[slot + 14] = rng.randf(); out[slot + 15] = 2.0
	return out


## The tree's autumn as the leaf shaders work it out (world/seasons/tree_query.gd autumn_tree).
static func autumn_tree(root: Vector3) -> Vector2:
	return TREE_QUERY.autumn_tree(root)


func _scale() -> float:
	var tier := 1.0
	var quality: Node = get_node_or_null("/root/Quality")
	if quality != null: tier = float(TIER_SCALE[clampi(int(quality.get("preset")), 0, TIER_SCALE.size() - 1)])
	var level := int(state.call("effects_level")) if state != null and state.has_method("effects_level") else 2
	return tier * (0.5 if level == 1 else 1.0)


## 0 on grass .. 1 in the middle of a trodden path (the painted trails the navigation reads).
func _path_weight(at: Vector3) -> float:
	if _paths == null and is_instance_valid(WorldTerrain.instance) and WorldTerrain.instance.terrain != null:
		var data: Variant = WorldTerrain.instance.terrain.get("data")
		if data is Object and is_instance_valid(data):
			var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(WorldTerrain.TEXTURES))
			var rows: Array = (doc as Dictionary).get("textures", []) if doc is Dictionary else []
			_paths = TERRAIN_PATHS.new()
			_paths.call("bind", data, rows)
	return float(_paths.call("weight_at", at)) if _paths != null else 0.0
