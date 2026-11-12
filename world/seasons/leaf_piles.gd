extends Node3D
## Kickable autumn leaf piles (W2-SEAS-E 2026-11-08, M-SEA-12; design captures/overhaul-2026-11-08/
## seasons/AUDIT_AND_DESIGN.md 6.3). Child "LeafPiles" of the season state (season_state.gd FEATURES),
## which calls setup(state). Group "leaf_piles".
##
## Where: 8-20 piles per km of town path (the edge of the painted Terrain3D trails, the same
## controls the navigation reads through world/navigation/terrain_paths.gd) and under some park
## trees (world/seasons/tree_query.gd), only in and around towns and where the climate map says
## the trees are deciduous. Placement is a pure function of the season seed (seasons since day 0)
## and the 64 m tile, so a pile is in the same place every time it streams in, and a new autumn
## lays new piles.
##
## What: each pile is one MultiMeshInstance3D of LEAVES leaf quads with world/seasons/leaf_pile.gdshader
## (the mound, the kick flight and the scattered patch are all in the vertex shader; one shared
## MultiMesh and material). Hidden beyond 40 m (visibility range); at most max_live() piles are
## live, the nearest first (quality key leaf_piles_max / leaf_piles, default Very Low 4, Low 8,
## Medium 16, High 24, Ultra 32; the Seasonal effects setting halves it on Reduced, none on Off).
##
## Kick: a 10 Hz distance check of the player and nearby ponies (group ai_characters) against the
## live pile centres (no Area3D per pile), running only while a pile is live. Walking through
## kicks a pile, a trot or gallop throws it further, jumping into it throws the most. Ponies kick
## only at a trot or faster (they step around piles at a walk). The pile scatters into a patch that
## stays for the rest of the season: saved per pile in world_context.state.seasons.leaf_piles
## through the season state's block(). A rake (WP-F) calls rake() to pull a patch back into a pile.
## signal kicked(position, strength, jumped) is for the leaf rustle sound (W2-SEAS-J).
##
## Outside autumn, or with no piles allowed, there are no pile nodes and no timers.
signal kicked(position: Vector3, strength: float, jumped: bool)
signal raked_back(position: Vector3)

const GROUP := "leaf_piles"
const STATE_KEY := "leaf_piles"
const SEASON_STATE := preload("res://world/seasons/season_state.gd")
const TREE_QUERY := preload("res://world/seasons/tree_query.gd")
const TERRAIN_PATHS := preload("res://world/navigation/terrain_paths.gd")
const CLIMATE := preload("res://world/seasons/climate_map.gd")
const PLAYER_VIEW := preload("res://world/player_view.gd")
const SHADER := preload("res://world/seasons/leaf_pile.gdshader")
const LEAF_MASK := preload("res://world/foliage/everfree_trees/leaf_mask.res")
const LEAVES := 180
const TILE := 64.0
## Piles closer than LIVE_RADIUS may be live; the visibility range hides them past VISIBLE.
const VISIBLE := 40.0
const LIVE_RADIUS := 44.0
## Tiles and tree piles further than this from the camera are forgotten (made again on return).
const FORGET := 256.0
const MOVE_STEP := 8.0
## Piles per km of path, drawn per tile from the season seed.
const PER_KM := Vector2(8.0, 20.0)
## A path edge is about this many metres of edge band per metre of path (both sides).
const PATH_BAND := 2.0
## Trail weight between these is the edge of a path (0 grass, 1 the middle of the path).
const PATH_EDGE := Vector2(0.15, 0.65)
const MIN_GAP := 4.0
const TOWN_KINDS := ["town", "village", "city", "hamlet"]
const TOWN_MARGIN := 80.0
## Deciduous share (climate map G) needed for piles.
const MIN_DECIDUOUS := 0.5
const TREE_RADIUS := 45.0
const TREE_PILE_CHANCE := 0.3
const TREE_PILE_OFFSET := Vector2(1.2, 2.8)
## Kick check.
const CHECK := 0.1
const REFRESH := 0.5
const KICK_RADIUS := 1.0
const KICK_HEIGHT := 1.6
const ENTITY_RADIUS := 40.0
## Only bodies this close to a live pile are checked at 10 Hz (a gallop covers 3.5 m between refreshes).
const NEAR_PILE := 10.0
const PLAYER_MIN_SPEED := 0.4
const PONY_MIN_SPEED := 1.8
const JUMP_DROP := 0.12
const JUMP_HEIGHT := 0.35
const JUMP_STRENGTH := 1.6
const FLIGHT_SECONDS := 2.4
const MOUND_RADIUS := 0.8
## A kicked pile's settled patch reaches about this far from its centre (leaf_pile.gdshader).
const PATCH_REACH := 2.6
## Footstep sound providers (ground_contact_audio.gd LEAF_GROUP).
const LEAF_GROUND_GROUP := "leaf_ground"
const MAX_SAVED := 512
const TIER_MAX := [4, 8, 16, 24, 32]
const KICK_T := ":instance_shader_parameters/kick_t"

var state: Node
## Test hooks: a fixed camera point, tree list, path weight (Callable(Vector3) -> float), town test
## (Callable(Vector3) -> bool), entity list and season seed (-1: from the season state).
var eye_override := Vector3.INF
var trees_override: Array = []
var use_trees_override := false
var path_weight_override: Callable
var town_override: Callable
var entities_override: Array = []
var use_entities_override := false
var season_seed_override := -1
var auto_timers := true

## Season seed the piles were laid with (-1: inactive).
var season_seed := -1
var _tiles: Dictionary = {}        # Vector2i -> Array[pile]
var _tree_piles: Dictionary = {}   # id -> pile
var _piles: Dictionary = {}        # id -> pile (every known pile)
var _kicked: Dictionary = {}       # id -> [from_x, from_z, strength, raked]
var _live: Dictionary = {}         # id -> MultiMeshInstance3D
var _pool: Array[MultiMeshInstance3D] = []
var _entities: Array = []
var _prev: Dictionary = {}         # instance id -> Vector3
var _gathered_at := Vector3.INF
var _paths: RefCounted
var _multimesh: MultiMesh
var _material: ShaderMaterial
var _refresh_timer: Timer
var _check_timer: Timer
var _palette_progress := -1.0

func _init() -> void:
	add_to_group(GROUP)
	add_to_group(LEAF_GROUND_GROUP)

func setup(season: Node) -> void:
	state = season
	if state == null: return
	for pair: Array in [["season_changed", _on_season_signal], ["day_stepped", _on_season_signal], ["effects_changed", _on_season_signal]]:
		if state.has_signal(pair[0]) and not state.is_connected(pair[0], pair[1]): state.connect(pair[0], pair[1])
	var quality: Node = get_node_or_null("/root/Quality")
	if quality != null and quality.has_signal("preset_changed") and not quality.is_connected("preset_changed", _on_quality):
		quality.connect("preset_changed", _on_quality)
	var context: Variant = state.get("context")
	if context is Node and is_instance_valid(context) and (context as Node).has_signal("reopened") and not (context as Node).is_connected("reopened", _on_reopened):
		(context as Node).connect("reopened", _on_reopened)
	refresh()

func _on_season_signal(_value: Variant = null) -> void: refresh()
func _on_quality(_preset: int) -> void: refresh()
## A save slot was loaded: the season state restores its block first (same signal, connected
## earlier); at the end of the frame (after the slot's clock) the piles are laid again for the
## slot's season and read its saved patches.
func _on_reopened(_world_id: String) -> void: _relay.call_deferred()

func _relay() -> void:
	_deactivate()
	refresh()

# ------------------------------------------------------------------ season and limits

func current_seed() -> int:
	if season_seed_override >= 0: return season_seed_override
	if state == null: return -1
	return SEASON_STATE.count_for(int(state.call("today")), int(state.call("season_days")), int(state.get("offset")))

## Most live piles: the quality key (or the tier default) and the Seasonal effects setting.
func max_live() -> int:
	var level := int(state.call("effects_level")) if state != null and state.has_method("effects_level") else 2
	if level <= 0: return 0
	var cap := 24
	var quality: Node = get_node_or_null("/root/Quality")
	if quality != null:
		var preset := clampi(int(quality.get("preset")), 0, TIER_MAX.size() - 1)
		var value: Variant = quality.call("get_value", "leaf_piles_max", null)
		if not (value is int or value is float): value = quality.call("get_value", "leaf_piles", TIER_MAX[preset])
		cap = maxi(0, int(value)) if value is int or value is float else int(TIER_MAX[preset])
	return int(ceil(cap * 0.5)) if level == 1 else cap

func is_active() -> bool:
	return season_seed >= 0

## Re-reads the season and limits: lays the season's piles in autumn, removes everything otherwise.
func refresh() -> void:
	var autumn := state != null and str(state.call("season")) == "autumn"
	if not autumn or max_live() <= 0:
		_deactivate(); return
	var now_seed := current_seed()
	if now_seed != season_seed:
		_deactivate()
		season_seed = now_seed
		reload_saved()
	_ensure_resources()
	_apply_palette()
	if auto_timers and not is_instance_valid(_refresh_timer):
		_refresh_timer = Timer.new(); _refresh_timer.name = "PileRefresh"; _refresh_timer.wait_time = REFRESH; _refresh_timer.autostart = true
		_refresh_timer.timeout.connect(refresh_live)
		add_child(_refresh_timer)
	refresh_live()

func _deactivate() -> void:
	season_seed = -1
	for node: MultiMeshInstance3D in _live.values():
		if is_instance_valid(node): node.queue_free()
	for node: MultiMeshInstance3D in _pool:
		if is_instance_valid(node): node.queue_free()
	_live.clear(); _pool.clear(); _tiles.clear(); _tree_piles.clear(); _piles.clear(); _kicked.clear()
	_entities.clear(); _prev.clear(); _gathered_at = Vector3.INF
	for timer: Timer in [_refresh_timer, _check_timer]:
		if is_instance_valid(timer): timer.queue_free()
	_refresh_timer = null; _check_timer = null

func _ensure_resources() -> void:
	if _multimesh != null: return
	_material = ShaderMaterial.new(); _material.shader = SHADER
	_material.set_shader_parameter("leaf_texture", LEAF_MASK)
	_material.set_shader_parameter("mound_radius", MOUND_RADIUS)
	var quad := QuadMesh.new(); quad.size = Vector2.ONE; quad.material = _material
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.mesh = quad
	_multimesh.instance_count = LEAVES
	for i in LEAVES: _multimesh.set_instance_transform(i, Transform3D.IDENTITY)
	# The shader moves every leaf: the bounds cover the mound, the flight and the patch.
	_multimesh.custom_aabb = AABB(Vector3(-3.6, -0.3, -3.6), Vector3(7.2, 2.6, 7.2))

## Leaf colours along the autumn (gold early, orange-red mid, more brown late).
func _apply_palette() -> void:
	if _material == null: return
	var progress := float(state.call("progress")) if state != null and state.has_method("progress") else 0.5
	if is_equal_approx(progress, _palette_progress): return
	_palette_progress = progress
	var late := smoothstep(0.4, 1.0, progress)
	_material.set_shader_parameter("colour_a", Color(0.93, 0.66, 0.18).lerp(Color(0.85, 0.5, 0.16), late))
	_material.set_shader_parameter("colour_b", Color(0.82, 0.3, 0.08).lerp(Color(0.66, 0.3, 0.1), late))
	_material.set_shader_parameter("colour_c", Color(0.56, 0.36, 0.14).lerp(Color(0.44, 0.28, 0.13), late))

# ------------------------------------------------------------------ placement

func _eye() -> Vector3:
	if eye_override.is_finite(): return eye_override
	var cam := PLAYER_VIEW.camera(self)
	return cam.global_position if cam != null else Vector3.INF

static func tile_of(at: Vector3) -> Vector2i:
	return Vector2i(floori(at.x / TILE), floori(at.z / TILE))

static func pile_id(at: Vector3) -> String:
	return "%d_%d" % [roundi(at.x * 2.0), roundi(at.z * 2.0)]

func _path_weight(at: Vector3) -> float:
	if path_weight_override.is_valid(): return float(path_weight_override.call(at))
	if _paths == null and is_instance_valid(WorldTerrain.instance) and WorldTerrain.instance.terrain != null:
		var data: Variant = WorldTerrain.instance.terrain.get("data")
		if data is Object and is_instance_valid(data):
			var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(WorldTerrain.TEXTURES))
			var rows: Array = (doc as Dictionary).get("textures", []) if doc is Dictionary else []
			_paths = TERRAIN_PATHS.new()
			_paths.call("bind", data, rows)
	return float(_paths.call("weight_at", at)) if _paths != null else 0.0

## A tile is laid (and cached) only once the terrain under it is there; before that it is tried again.
func _tile_ready(tile: Vector2i) -> bool:
	if path_weight_override.is_valid(): return true
	if not is_instance_valid(WorldTerrain.instance): return false
	return WorldTerrain.instance.has_ground(Vector3((tile.x + 0.5) * TILE, 0.0, (tile.y + 0.5) * TILE))

## Towns, villages and cities (and TOWN_MARGIN around them) where the trees are deciduous.
func _allowed(at: Vector3, slack := 0.0) -> bool:
	return _near_town(at, slack) and CLIMATE.sample(Vector2(at.x, at.z), 1) >= MIN_DECIDUOUS

## Within TOWN_MARGIN + slack of a town, village or city (the town half of _allowed()).
func _near_town(at: Vector3, slack := 0.0) -> bool:
	if town_override.is_valid(): return bool(town_override.call(at))
	var town: Dictionary = WorldLayout.nearest(at, TOWN_KINDS)
	return not town.is_empty() and WorldLayout.distance_to(town, at) <= TOWN_MARGIN + slack

func _ground(at: Vector3) -> Vector3:
	if is_instance_valid(WorldTerrain.instance):
		var h: float = WorldTerrain.instance.height_at(at)
		if is_finite(h): return Vector3(at.x, h, at.z)
	return at

func _normal(at: Vector3) -> Vector3:
	return WorldTerrain.instance.normal_at(at) if is_instance_valid(WorldTerrain.instance) else Vector3.UP

func _make_pile(at: Vector3, look: float) -> Dictionary:
	var ground := _ground(at)
	return {"id": pile_id(ground), "pos": ground, "normal": _normal(ground), "seed": look}

## The path piles of one tile for the current season seed (pure: same seed and tile, same piles).
func tile_piles(tile: Vector2i) -> Array:
	var result: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([season_seed, tile.x, tile.y, "leaf_piles"])
	var per_km := rng.randf_range(PER_KM.x, PER_KM.y)
	var candidates := roundi(per_km * TILE * TILE / (1000.0 * PATH_BAND))
	var centre := Vector3((tile.x + 0.5) * TILE, 0.0, (tile.y + 0.5) * TILE)
	# One town test for the whole tile (half its diagonal of slack), then per candidate below.
	if not _allowed(centre, TILE * 0.71): return result
	for i in candidates:
		var at := Vector3(tile.x * TILE + rng.randf() * TILE, 0.0, tile.y * TILE + rng.randf() * TILE)
		var look := rng.randf()
		var weight := _path_weight(at)
		if weight < PATH_EDGE.x or weight > PATH_EDGE.y: continue
		if not _allowed(at): continue
		if _crowded(result, at): continue
		result.append(_make_pile(at, look))
	return result

static func _crowded(piles: Array, at: Vector3) -> bool:
	for pile: Dictionary in piles:
		var p: Vector3 = pile.pos
		if Vector2(p.x - at.x, p.z - at.z).length_squared() < MIN_GAP * MIN_GAP: return true
	return false

## Piles under broadleaf park trees: a seeded share of the crowns gets one beside its trunk.
func tree_piles(trees: Array) -> Array:
	var result: Array = []
	for row: Variant in trees:
		if not row is Dictionary: continue
		var rec := TREE_QUERY.normalised(row)
		if int(rec.kind) == TREE_QUERY.EVERGREEN: continue
		var at: Vector3 = rec.position
		var rng := RandomNumberGenerator.new()
		rng.seed = hash([season_seed, roundi(at.x * 2.0), roundi(at.z * 2.0), "tree_pile"])
		if rng.randf() >= TREE_PILE_CHANCE: continue
		var angle := rng.randf() * TAU
		var spot := at + Vector3(cos(angle), 0.0, sin(angle)) * rng.randf_range(TREE_PILE_OFFSET.x, TREE_PILE_OFFSET.y)
		var look := rng.randf()
		if not _allowed(spot): continue
		if _crowded(result, spot): continue
		result.append(_make_pile(spot, look))
	return result

## Tiles and tree piles around eye (on the first call and after MOVE_STEP metres).
func gather(eye: Vector3) -> void:
	_gathered_at = eye
	var low := tile_of(eye - Vector3(LIVE_RADIUS, 0, LIVE_RADIUS))
	var high := tile_of(eye + Vector3(LIVE_RADIUS, 0, LIVE_RADIUS))
	for x in range(low.x, high.x + 1):
		for z in range(low.y, high.y + 1):
			var tile := Vector2i(x, z)
			if not _tiles.has(tile) and _tile_ready(tile): _tiles[tile] = tile_piles(tile)
	# Review 2026-11-08: no crown query (bird_perches over a 90 m box, every MOVE_STEP) away from
	# towns, where no tree pile can pass _allowed(): forests and open country cost nothing here.
	var trees: Array = trees_override if use_trees_override else []
	if not use_trees_override and _near_town(eye, TREE_RADIUS + TREE_PILE_OFFSET.y):
		trees = TREE_QUERY.canopies(get_tree() if is_inside_tree() else null, eye, TREE_RADIUS)
	for pile: Dictionary in tree_piles(trees):
		_tree_piles[pile.id] = pile
	# Forget what is far away (made again, identically, on return).
	for tile: Vector2i in _tiles.keys():
		var c := Vector2((tile.x + 0.5) * TILE, (tile.y + 0.5) * TILE)
		if c.distance_to(Vector2(eye.x, eye.z)) > FORGET: _tiles.erase(tile)
	for id: String in _tree_piles.keys():
		var p: Vector3 = (_tree_piles[id] as Dictionary).pos
		if Vector2(p.x - eye.x, p.z - eye.z).length() > FORGET: _tree_piles.erase(id)
	# The working set: piles within KEEP of the camera (live ones are within LIVE_RADIUS and the next
	# gather comes after MOVE_STEP). A tree pile too close to a path pile gives way, checked on a
	# MIN_GAP grid so the cost stays linear.
	_piles.clear()
	var keep := (LIVE_RADIUS + 2.0 * MOVE_STEP) ** 2
	var grid := {}
	for piles: Array in _tiles.values():
		for pile: Dictionary in piles:
			var p: Vector3 = pile.pos
			if Vector2(p.x - eye.x, p.z - eye.z).length_squared() > keep: continue
			_piles[pile.id] = pile
			grid[Vector2i(floori(p.x / MIN_GAP), floori(p.z / MIN_GAP))] = p
	var tree_ids: Array = _tree_piles.keys()
	tree_ids.sort()
	for id: String in tree_ids:
		var pile: Dictionary = _tree_piles[id]
		var p: Vector3 = pile.pos
		if _piles.has(id) or Vector2(p.x - eye.x, p.z - eye.z).length_squared() > keep: continue
		var cell := Vector2i(floori(p.x / MIN_GAP), floori(p.z / MIN_GAP))
		var clear := true
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var other: Variant = grid.get(cell + Vector2i(dx, dz))
				if other is Vector3 and Vector2((other as Vector3).x - p.x, (other as Vector3).z - p.z).length_squared() < MIN_GAP * MIN_GAP: clear = false
		if not clear: continue
		_piles[id] = pile
		grid[cell] = p

## Every pile known around the camera now (tests, W2-SEAS-H awareness): [{id, pos, scattered}].
func known_piles() -> Array:
	var result: Array = []
	for pile: Dictionary in _piles.values():
		result.append({"id": pile.id, "pos": pile.pos, "scattered": _kicked.has(pile.id)})
	return result

# ------------------------------------------------------------------ live piles

## The 2 Hz refresh: gather after moving, keep the nearest max_live() piles within LIVE_RADIUS live,
## find the ponies near the camera, run the 10 Hz kick check only while it can matter.
func refresh_live() -> void:
	if not is_active(): return
	var eye := _eye()
	if not eye.is_finite():
		_set_checking(false); return
	if not _gathered_at.is_finite() or Vector2(eye.x - _gathered_at.x, eye.z - _gathered_at.z).length() > MOVE_STEP:
		gather(eye)
	var near: Array = []
	for pile: Dictionary in _piles.values():
		var p: Vector3 = pile.pos
		var d := Vector2(p.x - eye.x, p.z - eye.z).length_squared()
		if d <= LIVE_RADIUS * LIVE_RADIUS: near.append([d, pile.id])
	near.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var wanted := {}
	for i in mini(near.size(), max_live()): wanted[near[i][1]] = true
	for id: String in _live.keys():
		if not wanted.has(id): _release(id)
	for id: String in wanted:
		if not _live.has(id): _show(id)
	if _live.is_empty():
		# No live pile: nobody to check (skips the pony scan at 2 Hz outside towns).
		_entities.clear(); _set_checking(false); return
	_gather_entities(eye)
	_keep_entities_near_piles()
	_set_checking(not _live.is_empty() and not _entities.is_empty())

func _show(id: String) -> void:
	if not _piles.has(id): return
	var pile: Dictionary = _piles[id]
	var node: MultiMeshInstance3D = _pool.pop_back() if not _pool.is_empty() else null
	if node == null:
		node = MultiMeshInstance3D.new()
		node.multimesh = _multimesh
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.visibility_range_end = VISIBLE
		node.visibility_range_end_margin = 4.0
		node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(node)
	node.name = "Pile_" + id.replace("-", "m")
	var up: Vector3 = pile.normal
	var lean := Basis(Quaternion(Vector3.UP, up.normalized())) if up.length_squared() > 0.5 and up.normalized().dot(Vector3.UP) < 0.9999 else Basis.IDENTITY
	# This node sits at the origin under the season state (a plain Node): local is world.
	node.transform = Transform3D(lean, pile.pos)
	node.set_instance_shader_parameter("pile_seed", float(pile.seed))
	_apply_kick(node, id, true)
	node.visible = true
	_live[id] = node

func _release(id: String) -> void:
	var node: MultiMeshInstance3D = _live.get(id)
	_live.erase(id)
	if not is_instance_valid(node): return
	node.visible = false
	_pool.append(node)

## Writes a pile's kick state to its node; settled shows the end of the flight at once.
func _apply_kick(node: MultiMeshInstance3D, id: String, settled: bool) -> void:
	var saved: Array = _kicked.get(id, [])
	if saved.size() < 4:
		node.set_instance_shader_parameter("kick", Vector4.ZERO)
		node.set_instance_shader_parameter("kick_t", 0.0)
		node.set_instance_shader_parameter("raked", 0.0)
		return
	node.set_instance_shader_parameter("kick", Vector4(float(saved[0]), float(saved[1]), float(saved[2]), 0.0))
	node.set_instance_shader_parameter("raked", float(saved[3]))
	if settled: node.set_instance_shader_parameter("kick_t", 1.0)

func live_count() -> int:
	return _live.size()

func live_node(id: String) -> MultiMeshInstance3D:
	return _live.get(id) as MultiMeshInstance3D

# ------------------------------------------------------------------ kicks

func _gather_entities(eye: Vector3) -> void:
	_entities.clear()
	if use_entities_override:
		# Node3D (the player) or [Node3D, is_player].
		for e: Variant in entities_override:
			if e is Node3D and is_instance_valid(e): _entities.append([e, true])
			elif e is Array and (e as Array).size() == 2 and (e as Array)[0] is Node3D: _entities.append([(e as Array)[0], bool((e as Array)[1])])
		return
	var game: Variant = state.get("game") if state != null else null
	var player: Variant = (game as Object).get("player") if game is Object and is_instance_valid(game) else null
	if player is Node3D and is_instance_valid(player):
		# Room-scale VR moves the rig's "Body" (xr_player_physics.tscn), not the rig root.
		var body: Node = (player as Node).get_node_or_null("Body")
		_entities.append([body if body is Node3D else player, true])
	if not is_inside_tree(): return
	for pony: Node in get_tree().get_nodes_in_group("ai_characters"):
		if not pony is Node3D or not (pony as Node3D).is_visible_in_tree(): continue
		var p := (pony as Node3D).global_position
		if Vector2(p.x - eye.x, p.z - eye.z).length() <= ENTITY_RADIUS: _entities.append([pony, false])

## Drops the bodies that are nowhere near a live pile (2 Hz), so the 10 Hz pass stays tiny and the
## check timer stops when nobody is near one.
func _keep_entities_near_piles() -> void:
	var kept: Array = []
	for pair: Array in _entities:
		var p := (pair[0] as Node3D).global_position
		for id: String in _live:
			var c: Vector3 = (_piles[id] as Dictionary).pos if _piles.has(id) else Vector3.INF
			if Vector2(p.x - c.x, p.z - c.z).length_squared() <= NEAR_PILE * NEAR_PILE:
				kept.append(pair); break
	_entities = kept

func _set_checking(on: bool) -> void:
	if not auto_timers: return
	if on and not is_instance_valid(_check_timer):
		_check_timer = Timer.new(); _check_timer.name = "PileKickCheck"; _check_timer.wait_time = CHECK; _check_timer.autostart = true
		_check_timer.timeout.connect(check_kicks)
		add_child(_check_timer)
	elif not on and is_instance_valid(_check_timer):
		_check_timer.queue_free(); _check_timer = null
		_prev.clear()

## One 10 Hz pass: who stepped or jumped into a live, untouched pile since the last pass.
func check_kicks() -> void:
	for pair: Array in _entities:
		var entity: Variant = pair[0]
		if not is_instance_valid(entity): continue
		var body: Node3D = entity
		var key := body.get_instance_id()
		var p := body.global_position
		var had := _prev.has(key)
		var prev: Vector3 = _prev.get(key, p)
		_prev[key] = p
		if not had: continue
		var is_player: bool = pair[1]
		for id: String in _live:
			if _kicked.has(id) or not _piles.has(id): continue
			var c: Vector3 = (_piles[id] as Dictionary).pos
			if Vector2(p.x - c.x, p.z - c.z).length_squared() > KICK_RADIUS * KICK_RADIUS: continue
			if absf(p.y - c.y) > KICK_HEIGHT: continue
			var speed := Vector2(p.x - prev.x, p.z - prev.z).length() / CHECK
			var jumped := prev.y - p.y > JUMP_DROP and prev.y - c.y > JUMP_HEIGHT
			if not jumped and speed < (PLAYER_MIN_SPEED if is_player else PONY_MIN_SPEED): continue
			kick(id, prev, kick_strength(speed, jumped), jumped)

## 0.35 at a walk up to 1 at a gallop; a jump into the pile throws the most.
static func kick_strength(speed: float, jumped: bool) -> float:
	if jumped: return JUMP_STRENGTH
	return clampf(speed / 3.5, 0.35, 1.0)

## Scatters a pile: the leaves fly away from `from` (a jump throws them every way) and settle.
func kick(id: String, from: Vector3, strength: float, jumped := false) -> bool:
	if not _piles.has(id) or _kicked.has(id): return false
	var pile: Dictionary = _piles[id]
	var c: Vector3 = pile.pos
	var local := Vector2(from.x - c.x, from.z - c.z)
	if jumped: local *= 0.15
	elif local.length() > MOUND_RADIUS * 1.2: local = local.normalized() * MOUND_RADIUS * 1.2
	_kicked[id] = [snappedf(local.x, 0.01), snappedf(local.y, 0.01), snappedf(strength, 0.01), 0.0]
	var node := live_node(id)
	if is_instance_valid(node):
		_apply_kick(node, id, false)
		node.set_instance_shader_parameter("kick_t", 0.0)
		if node.is_inside_tree():
			var tween := node.create_tween()
			tween.tween_property(node, NodePath(KICK_T), 1.0, FLIGHT_SECONDS)
	_save()
	# The rustle (W2-SEAS-E hook 2 / W2-SEAS-J): the real leaf recordings of environment_catalogue.gd
	# env_leaf_kick, louder with the kick. One event per kick, not per frame.
	var source: Node3D = node if is_instance_valid(node) and node.is_inside_tree() else self
	if source != null and source.is_inside_tree():
		preload("res://world/audio/interaction_sounds.gd").play_event(source, "env_leaf_kick", {"intensity": clampf(strength, 0.0, 1.0)}, c)
	kicked.emit(c, strength, jumped)
	return true

## WP-F rake: pulls the scattered patches within radius of point back towards their pile by
## amount (0..1 per call; a patch raked to 1 is a fresh pile again). Returns how many moved.
func rake(point: Vector3, radius: float, amount: float) -> int:
	var moved := 0
	for id: String in _kicked.keys():
		if not _piles.has(id): continue
		var c: Vector3 = (_piles[id] as Dictionary).pos
		if Vector2(point.x - c.x, point.z - c.z).length() > radius + MOUND_RADIUS + 2.0: continue
		var saved: Array = _kicked[id]
		var raked := clampf(float(saved[3]) + amount, 0.0, 1.0)
		moved += 1
		if raked >= 1.0:
			_kicked.erase(id)
			raked_back.emit(c)
		else: saved[3] = snappedf(raked, 0.01)
		var node := live_node(id)
		if is_instance_valid(node): _apply_kick(node, id, true)
	if moved > 0: _save()
	return moved

## Leaves underfoot at a world point (0..1) for footsteps (ground_contact_audio.gd, group
## leaf_ground; W2-SEAS-J hook): a mound is deep leaves, a scattered patch a thinner layer that a
## rake pulls back into a mound. Called on step events only; no piles outside autumn.
func leaves_at(point: Vector3) -> float:
	var best := 0.0
	for pile: Dictionary in _piles.values():
		var c: Vector3 = pile.pos
		if absf(point.y - c.y) > 1.5: continue
		var d := Vector2(point.x - c.x, point.z - c.z).length()
		if d > PATCH_REACH: continue
		var saved: Array = _kicked.get(pile.id, [])
		var raked := float(saved[3]) if saved.size() >= 4 else 1.0
		var reach := lerpf(PATCH_REACH, MOUND_RADIUS + 0.3, raked)
		best = maxf(best, lerpf(0.5, 1.0, raked) * (1.0 - smoothstep(reach - 0.4, reach, d)))
	return best

## Piles within radius of point (W2-SEAS-J footsteps, W2-SEAS-H awareness): [{id, pos, scattered, raked}].
func piles_near(point: Vector3, radius: float) -> Array:
	var result: Array = []
	for pile: Dictionary in _piles.values():
		var c: Vector3 = pile.pos
		if Vector2(point.x - c.x, point.z - c.z).length() > radius: continue
		var saved: Array = _kicked.get(pile.id, [])
		result.append({"id": pile.id, "pos": c, "scattered": not saved.is_empty(), "raked": float(saved[3]) if saved.size() >= 4 else 0.0})
	return result

func is_scattered(id: String) -> bool:
	return _kicked.has(id)

# ------------------------------------------------------------------ saves

## world_context.state.seasons.leaf_piles = {"season": seed, "kicked": {id: [from_x, from_z, strength, raked]}}.
func _save() -> void:
	if state == null or not state.has_method("block"): return
	var block: Variant = state.call("block")
	if not block is Dictionary or (block as Dictionary).is_empty(): return
	while _kicked.size() > MAX_SAVED: _kicked.erase(_kicked.keys()[0])
	var kicked_copy := {}
	for id: String in _kicked: kicked_copy[id] = (_kicked[id] as Array).duplicate()
	(block as Dictionary)[STATE_KEY] = {"season": season_seed, "kicked": kicked_copy}
	state.call("mark_changed")

## Reads the saved patches for this season's piles (a different season's are ignored).
func reload_saved() -> void:
	_kicked.clear()
	if state == null or not state.has_method("block") or season_seed < 0: return
	var block: Variant = state.call("block")
	var saved: Variant = (block as Dictionary).get(STATE_KEY) if block is Dictionary else null
	if saved is Dictionary and int((saved as Dictionary).get("season", -1)) == season_seed and (saved as Dictionary).get("kicked") is Dictionary:
		var rows: Dictionary = (saved as Dictionary).kicked
		for id: Variant in rows:
			var row: Variant = rows[id]
			if not (id is String and row is Array and (row as Array).size() >= 4): continue
			var values: Array = []
			for v: Variant in (row as Array).slice(0, 4):
				values.append(clampf(float(v), -4.0, 4.0) if (v is float or v is int) and is_finite(float(v)) else 0.0)
			values[3] = clampf(float(values[3]), 0.0, 1.0)
			_kicked[id] = values
	for id: String in _live:
		var node := live_node(id)
		if is_instance_valid(node): _apply_kick(node, id, true)
