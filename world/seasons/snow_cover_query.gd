extends RefCounted
## CPU mirror of season_snow_on() in res://world/seasons/season.gdshaderinc (W1-SEAS-A
## 2026-11-08): how much snow lies at a world point, for snowball scooping and footsteps
## (W2-SEAS-F, W2-SEAS-J). Same drift formula, climate map and trail; keep the two identical.
## Cheap (twelve hashes and two image reads); call it on events or at a low rate, never per pony
## per frame.
const CLIMATE := preload("res://world/seasons/climate_map.gd")

## The season_state node (group "season_state"), or null.
static func seasons(tree: SceneTree) -> Node:
	return tree.get_first_node_in_group("season_state") if tree != null else null

## Snow cover 0..1 at `pos`. `normal` defaults to the terrain normal there (straight up without
## terrain). `cover` < 0 reads season_state's snow cover.
static func cover_at(tree: SceneTree, pos: Vector3, normal := Vector3.ZERO, cover := -1.0) -> float:
	if cover < 0.0:
		var state := seasons(tree)
		cover = float(state.call("snow_cover")) if state != null else 0.0
	if cover <= 0.001: return 0.0
	if normal == Vector3.ZERO:
		normal = WorldTerrain.instance.normal_at(pos) if is_instance_valid(WorldTerrain.instance) else Vector3.UP
	var amount := snow_on(normal, pos, cover, trail_at(tree, pos))
	# The shader's shelter (W2-SEAS-B): roads, forest and tree canopies keep less snow, so steps and
	# snowballs there match what is drawn (snow_trail.gd shelter_at; snow_at applies the same).
	var trail: Node = tree.get_first_node_in_group("snow_trail") if tree != null else null
	if amount > 0.0 and trail != null and trail.has_method("shelter_at"):
		amount *= 1.0 - clampf(float(trail.call("shelter_at", pos)), 0.0, 1.0)
	return amount

## The shader formula itself, for a known cover and trail amount.
static func snow_on(normal: Vector3, pos: Vector3, cover: float, trail := 0.0) -> float:
	if cover <= 0.001: return 0.0
	var s := cover * CLIMATE.sample(Vector2(pos.x, pos.z), 0)
	if s <= 0.001: return 0.0
	var drift := snow_drift(Vector2(pos.x, pos.z)) + normal.z * 0.35 * (1.0 - s)
	var amount := smoothstep(0.55, 0.85, normal.y) * smoothstep(1.0 - s, 1.0 - s + lerpf(0.1, 0.35, s), drift + s * 0.5)
	amount *= 1.0 - trail * 0.85
	return clampf(amount, 0.0, 1.0)

## season_snow_drift of the shader: where snow lies first and melts last, 0..1.
static func snow_drift(xz: Vector2) -> float:
	var a := Vector2(xz.x * 0.8 - xz.y * 0.6, xz.x * 0.6 + xz.y * 0.8)
	var b := Vector2(xz.x * 0.28 + xz.y * 0.96, xz.y * 0.28 - xz.x * 0.96)
	return _drift_noise(xz * 0.028) * 0.55 + _drift_noise(a * 0.083 + Vector2(31.0, 31.0)) * 0.3 \
		+ _drift_noise(b * 0.26 + Vector2(7.0, 7.0)) * 0.15

static func _drift_noise(p: Vector2) -> float:
	var i := p.floor()
	var f := p - i
	f = f * f * (Vector2(3.0, 3.0) - 2.0 * f)
	var x := int(i.x)
	var y := int(i.y)
	return lerpf(lerpf(_drift_cell(x, y), _drift_cell(x + 1, y), f.x), lerpf(_drift_cell(x, y + 1), _drift_cell(x + 1, y + 1), f.x), f.y)

## season_drift_cell of the shader, in 32-bit whole numbers.
static func _drift_cell(x: int, y: int) -> float:
	var h := (((x & 0xFFFFFFFF) * 73856093) & 0xFFFFFFFF) ^ (((y & 0xFFFFFFFF) * 19349663) & 0xFFFFFFFF)
	h ^= h >> 16
	h = (h * 0x7feb352d) & 0xFFFFFFFF
	h ^= h >> 15
	h = (h * 0x846ca68b) & 0xFFFFFFFF
	h ^= h >> 16
	return float(h >> 8) / 16777216.0

## Trodden amount from the snow trail node (group "snow_trail", method trail_at(Vector3)), 0 without.
static func trail_at(tree: SceneTree, pos: Vector3) -> float:
	var trail: Node = tree.get_first_node_in_group("snow_trail") if tree != null else null
	return clampf(float(trail.call("trail_at", pos)), 0.0, 1.0) if trail != null and trail.has_method("trail_at") else 0.0
