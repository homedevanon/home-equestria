extends Node
## Seasonal decorations put up by town calendar events (W2-SEAS-I 2026-11-08; design
## captures/overhaul-2026-11-08/seasons/AUDIT_AND_DESIGN.md 6.6). A row of
## world/mechanics/data/events.json with a "decor" list (Hearth's Warming) puts its pieces up for
## every day of its window (town_calendar.today_events) and takes them down when the window ends.
## Child "SeasonalDecor" of SeasonState (world/seasons/season_state.gd FEATURES): it checks once
## after setup and on each SeasonState.day_stepped, so outside a decorated event there are no
## decor nodes, no timers and no per-frame work. Pieces are town-local (the RNLScenery frame) and
## hang under one holder node per event under the town root:
## - {"id", "scene", "at": [x, y, z], "yaw", "scale", "ground": [[x, z], ...]}: one prop. y drops
##   to the lowest terrain under its model-local ground points (the arch's two posts).
## - {"id", "scene", "spots": [[x, y, z, yaw], ...], "scale", "clear", "height", "trunk", "range"}:
##   the first spot whose cylinder (radius clear, height) touches no collider and whose ground is
##   level within LEVEL_TOLERANCE; "trunk" adds a cylinder collider, "range" a visibility range.
## - {"id", "kind": "door_lanterns"}: a second kit wall lantern on the other side of every house
##   door that has one (mirrored across the doorway; furnish_lamps.gd mount check and its window
##   rule), a few houses per LANTERN_PERIOD. Skipped when Seasonal effects is Off.
const KIT_LAMP := preload("res://world/props/lamps/kit_lamp.gd")
const FURNISH_LAMPS := preload("res://world/interiors/furnish_lamps.gd")
const FURNITURE_ASSETS := preload("res://world/interiors/furniture_assets.gd")
const GROUP := "seasonal_decor"
const RETRY_SECONDS := 2.0
const RETRIES := 30
const LANTERN_BATCH := 3
const LANTERN_PERIOD := 0.1
## Passes over a house whose door lantern the furnisher has not placed yet (houses furnish 0.2 s apart).
const LANTERN_TRIES := 20
const LANTERN_RANGE := 70.0
const WINDOW_MARGIN := 0.08
const LEVEL_TOLERANCE := 0.5

var seasons: Node
## Test hooks: a calendar and a town root used instead of the tree's groups.
var calendar_override: Node
var town_override: Node3D
var _up: Dictionary = {}          # event id -> holder Node3D
var _queue: Array = []            # [holder, home, tries] lanterns still to hang
var _timer: Timer
var _retries := 0
var _retry_pending := false

func _init() -> void:
	add_to_group(GROUP)

func setup(host: Node) -> void:
	seasons = host
	if host != null and host.has_signal("day_stepped") and not host.is_connected("day_stepped", _on_day):
		host.connect("day_stepped", _on_day)
	refresh.call_deferred()

func _on_day(_day: int) -> void:
	refresh()

func is_up(event_id: String) -> bool:
	return _up.has(event_id) and is_instance_valid(_up[event_id])

## The placed pieces of an event (tests): its holder's children.
func pieces(event_id: String) -> Array[Node]:
	var found: Array[Node] = []
	if is_up(event_id): found.assign((_up[event_id] as Node).get_children())
	return found

func lanterns_pending() -> int:
	return _queue.size()

func _calendar() -> Node:
	if calendar_override != null and is_instance_valid(calendar_override): return calendar_override
	return get_tree().get_first_node_in_group("town_calendar") if is_inside_tree() else null

func _town() -> Node3D:
	if town_override != null and is_instance_valid(town_override): return town_override
	if not is_inside_tree(): return null
	for node: Node in get_tree().get_nodes_in_group("town_roots"):
		if node is Node3D and node.is_inside_tree(): return node
	return null

## Puts up the decor of decorated events in their window today and takes down the rest.
func refresh() -> void:
	var cal := _calendar()
	var wanted := {}
	if cal != null and cal.has_method("today_events"):
		for value: Variant in cal.call("today_events"):
			if value is Dictionary and (value as Dictionary).get("decor") is Array: wanted[str((value as Dictionary).get("id", ""))] = value
	for id: String in _up.keys():
		if not wanted.has(id): take_down(id)
	if wanted.is_empty(): return
	var town := _town()
	if town == null:
		_retry()
		return
	for id: String in wanted:
		if not is_up(id): _put_up(wanted[id], town)

func _retry() -> void:
	if _retry_pending or _retries >= RETRIES or not is_inside_tree(): return
	_retries += 1
	_retry_pending = true
	get_tree().create_timer(RETRY_SECONDS).timeout.connect(_retry_now)

func _retry_now() -> void:
	_retry_pending = false
	refresh()

func take_down(event_id: String) -> void:
	var holder: Variant = _up.get(event_id)
	_up.erase(event_id)
	if not holder is Node or not is_instance_valid(holder): return
	_queue = _queue.filter(func(entry: Array) -> bool: return entry[0] != holder)
	if _queue.is_empty() and _timer != null: _timer.stop()
	(holder as Node).queue_free()
	print("[decor] %s down" % event_id)

func _put_up(event: Dictionary, town: Node3D) -> void:
	var id := str(event.get("id", ""))
	var holder := Node3D.new()
	holder.name = "SeasonalDecor_" + id
	town.add_child(holder)
	_up[id] = holder
	for value: Variant in event.decor:
		if not value is Dictionary: continue
		var piece: Dictionary = value
		if str(piece.get("kind", "scene")) == "door_lanterns":
			if _effects_level() > 0: _queue_lanterns(holder)
		else:
			_place_scene(holder, town, piece)
	print("[decor] %s up: %d pieces, %d door lanterns queued" % [id, holder.get_child_count(), _queue.size()])

func _effects_level() -> int:
	return int(seasons.call("effects_level")) if seasons != null and is_instance_valid(seasons) and seasons.has_method("effects_level") else 2

# ------------------------------------------------------------------ props

## Lowest terrain height (town-local y) under the given town-local xz points; NAN without terrain.
func _ground_y(town: Node3D, points: Array[Vector2]) -> Array:
	var terrain: Variant = WorldTerrain.instance if is_instance_valid(WorldTerrain.instance) else null
	var low := INF; var high := -INF
	if terrain == null: return [NAN, NAN]
	for p: Vector2 in points:
		var world: Vector3 = town.to_global(Vector3(p.x, 0.0, p.y))
		var height: float = (terrain as WorldTerrain).height_at(world)
		if not is_finite(height): return [NAN, NAN]
		var local_y: float = town.to_local(Vector3(world.x, height, world.z)).y
		low = minf(low, local_y); high = maxf(high, local_y)
	return [low, high]

static func _vec2s(value: Variant) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if value is Array:
		for p: Variant in value:
			if p is Array and (p as Array).size() >= 2: out.append(Vector2(float(p[0]), float(p[1])))
	return out

func _place_scene(holder: Node3D, town: Node3D, piece: Dictionary) -> void:
	var path := str(piece.get("scene", ""))
	var packed: PackedScene = load(path) as PackedScene if not path.is_empty() and ResourceLoader.exists(path) else null
	if packed == null:
		push_warning("seasonal_decor: no scene %s for %s" % [path, str(piece.get("id", ""))]); return
	var scale := maxf(0.01, float(piece.get("scale", 1.0)))
	var clear := float(piece.get("clear", 0.0))
	var candidates: Array = []
	if piece.get("at") is Array and (piece.at as Array).size() >= 3:
		candidates.append([float(piece.at[0]), float(piece.at[1]), float(piece.at[2]), float(piece.get("yaw", 0.0))])
	if piece.get("spots") is Array:
		for spot: Variant in piece.spots:
			if spot is Array and (spot as Array).size() >= 4: candidates.append([float(spot[0]), float(spot[1]), float(spot[2]), float(spot[3])])
	var ground := _vec2s(piece.get("ground"))
	if ground.is_empty():
		ground.append(Vector2.ZERO)
		if clear > 0.0:
			for k in 4: ground.append(Vector2.RIGHT.rotated(k * PI * 0.5) * clear / scale)
	for spot: Array in candidates:
		var basis := Basis(Vector3.UP, float(spot[3])).scaled(Vector3.ONE * scale)
		var origin := Vector3(spot[0], spot[1], spot[2])
		var points: Array[Vector2] = []
		for g: Vector2 in ground:
			var at: Vector3 = origin + basis * Vector3(g.x, 0.0, g.y)
			points.append(Vector2(at.x, at.z))
		var heights := _ground_y(town, points)
		if is_finite(float(heights[0])):
			if clear > 0.0 and float(heights[1]) - float(heights[0]) > LEVEL_TOLERANCE: continue
			origin.y = float(heights[0])
		if clear > 0.0 and _blocked(holder, Transform3D(basis.orthonormalized(), origin), clear, float(piece.get("height", 3.0))): continue
		var node := packed.instantiate() as Node3D
		if node == null: return
		node.name = str(piece.get("id", "piece"))
		# Bodies keep the scale they enter the tree with: transform first, then add_child.
		node.transform = Transform3D(basis, origin)
		holder.add_child(node)
		if piece.has("range"):
			for mesh: GeometryInstance3D in node.find_children("*", "GeometryInstance3D", true, false):
				mesh.visibility_range_end = float(piece.range)
				mesh.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		if float(piece.get("trunk", 0.0)) > 0.0: _add_trunk(holder, node.name, origin, float(piece.trunk))
		return
	print("[decor] %s: no clear spot" % str(piece.get("id", "")))

## A collider other than the ground inside the cylinder standing on `at` (0.4 m up, so the
## terrain under it does not count).
func _blocked(holder: Node3D, at: Transform3D, radius: float, height: float) -> bool:
	var world := holder.get_world_3d()
	if world == null: return false
	var shape := CylinderShape3D.new(); shape.radius = radius; shape.height = height
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 1
	query.transform = Transform3D(Basis.IDENTITY, holder.global_transform * (at.origin + Vector3.UP * (0.4 + height * 0.5)))
	return not world.direct_space_state.intersect_shape(query, 1).is_empty()

func _add_trunk(holder: Node3D, piece_name: String, origin: Vector3, radius: float) -> void:
	var body := StaticBody3D.new(); body.name = piece_name + "_trunk"; body.collision_mask = 0
	var shape := CylinderShape3D.new(); shape.radius = radius; shape.height = 3.0
	var col := CollisionShape3D.new(); col.shape = shape; col.position = Vector3.UP * 1.5
	body.add_child(col)
	body.transform = Transform3D(Basis.IDENTITY, origin)
	holder.add_child(body)

# ------------------------------------------------------------------ door lanterns

func _queue_lanterns(holder: Node3D) -> void:
	for home: Node in get_tree().get_nodes_in_group("house_interiors"):
		if home is Node3D: _queue.append([holder, home, 0])
	if _queue.is_empty(): return
	if _timer == null:
		_timer = Timer.new(); _timer.name = "LanternTick"; _timer.wait_time = LANTERN_PERIOD
		_timer.timeout.connect(_lantern_tick)
		add_child(_timer)
	_timer.start()

## A few houses per tick; a house whose door lantern is not there yet goes to the back of the line.
func _lantern_tick() -> void:
	for i in mini(LANTERN_BATCH, _queue.size()):
		var entry: Array = _queue.pop_front()
		if not is_instance_valid(entry[0]) or not is_instance_valid(entry[1]): continue
		if not hang_lantern(entry[0], entry[1]) and int(entry[2]) < LANTERN_TRIES:
			_queue.append([entry[0], entry[1], int(entry[2]) + 1])
	if _queue.is_empty() and _timer != null: _timer.stop()

## The house's own door lantern (furnish_lamps.spawn_outdoor names it Furniture_<id>_door).
static func door_lantern(home: Node) -> Node3D:
	for child: Node in home.get_children():
		if child is Node3D and str(child.name).begins_with("Furniture_") and str(child.name).ends_with("_door"): return child
	return null

## Hangs the mirror of the house's door lantern under holder. False while the house has no door
## lantern yet (try again later); true when done, placed or not.
func hang_lantern(holder: Node3D, home: Node3D) -> bool:
	if not home.is_inside_tree(): return true
	var existing := door_lantern(home)
	if existing == null: return false
	var doorway: Variant = home.get("doorway")
	if not doorway is Vector3: return true
	var at: Vector3 = existing.position
	var size := _lantern_size(existing)
	var basis: Basis = home.global_basis.orthonormalized()
	var centre: Vector3 = home.to_global(Vector3(2.0 * (doorway as Vector3).x - at.x, at.y, (doorway as Vector3).z))
	var mount: Variant = FURNISH_LAMPS._lantern_mount(home.get_world_3d().direct_space_state, centre, basis, size)
	if not mount is Vector3: return true
	var wall: Vector3 = mount
	if _over_window(home, wall, basis, size): return true
	var kind_value: Variant = existing.get("kind")
	var kind := str(kind_value) if kind_value is String and not str(kind_value).is_empty() else "wall_lantern"
	var lamp: Node3D = KIT_LAMP.create(kind)
	# Every home node is called HouseInterior: name the lantern after its house.
	lamp.name = "Lantern_%s" % str(home.get_parent().name if home.get_parent() != null else home.name)
	lamp.transform = holder.global_transform.affine_inverse() * Transform3D(existing.global_basis.orthonormalized(), wall)
	holder.add_child(lamp, true)
	for mesh: MeshInstance3D in lamp.find_children("*", "MeshInstance3D", true, false):
		mesh.visibility_range_end = LANTERN_RANGE
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return true

## The lantern's modelled size (its meshes in its own unscaled frame).
static func _lantern_size(lamp: Node3D) -> Vector3:
	var box := AABB(); var first := true
	var inverse := lamp.global_transform.orthonormalized().affine_inverse()
	for mesh: MeshInstance3D in lamp.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null: continue
		var b: AABB = (inverse * mesh.global_transform) * mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return Vector3(0.2, 0.5, 0.4) if first or box.size.length() < 0.05 else box.size

## furnish_lamps._over_window without the furnisher: the lantern's box near a window's glass or trim.
static func _over_window(home: Node3D, wall: Vector3, basis: Basis, size: Vector3) -> bool:
	var house := home.get_parent() as Node3D
	if house == null: return false
	var lantern := Transform3D(basis, wall + basis.z * (size.z * 0.5) + Vector3.UP * -0.095) * AABB(-size * 0.5, size)
	for fact: Dictionary in FURNITURE_ASSETS._source_windows(house):
		for key: String in ["frame", "glass"]:
			if fact.has(key) and (house.global_transform * (fact[key] as AABB)).grow(WINDOW_MARGIN).intersects(lantern): return true
	return false
