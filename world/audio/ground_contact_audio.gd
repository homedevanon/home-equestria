extends RefCounted
## Query only reported contacts, after distance rejection. No frame-time scene or skeleton work.
## Seasons (W2-SEAS-J, 2026-11-08): a terrain step sounds like the ground the season shows there:
## snow only where the snow cover mirror (world/seasons/snow_cover_query.gd) says it lies, leaves
## on litter and piles, a splash in puddles, mud on wet dirt. Frozen slabs sound as ice. All of it
## runs on the step event only.
const HOUSE := preload("res://world/buildings/house_interior.gd")
const SNOW := preload("res://world/seasons/snow_cover_query.gd")
const WATER_MASK := 1 << 15
const FLOOR_MASK := 1 | (1 << 18)
const AUTHORED := ["grass", "stone", "wood", "dirt", "sand", "snow", "leaves", "mud", "gravel", "cloud", "cloth", "ice", "puddle"]
## Ice slabs (W2-SEAS-G) join this group or carry meta audio_material "ice".
const ICE_GROUP := "ice_slabs"
## Leaf piles, scattered patches and under-canopy litter (W2-SEAS-E): nodes in this group with
## leaves_at(position: Vector3) -> float (0 bare .. 1 deep leaves).
const LEAF_GROUP := "leaf_ground"
## Snow cover at which a step sounds as snow: the shader shows the ground mostly white from here.
const SNOW_STEP := .45
const LEAF_STEP := .35
const PUDDLE_STEP := .5
## Local wetness (season wetness x the biome's wet response) that turns dirt to mud.
const MUD_WET := .35


static func material(source: Node3D, at: Vector3, weather: Node = null) -> String:
	if not is_instance_valid(source) or not source.is_inside_tree() or not at.is_finite(): return ""
	var space := source.get_world_3d().direct_space_state
	if space == null: return ""
	var excluded: Array[RID] = []
	if source is CollisionObject3D: excluded.append(source.get_rid())
	var ray := PhysicsRayQueryParameters3D.create(at + Vector3.UP * .25,
		at - Vector3.UP * .65, FLOOR_MASK | WATER_MASK, excluded)
	ray.hit_back_faces = true
	var hit: Dictionary = space.intersect_ray(ray)
	if hit.is_empty() or Vector3(hit.normal).y < .45: return ""
	var collider: Node = hit.collider as Node
	if collider == null: return ""
	if collider is CollisionObject3D and (collider.collision_layer & WATER_MASK) != 0: return "water"
	var owner: Node = collider
	for i in 4:
		if owner == null: break
		if owner.has_meta("audio_material"):
			var authored := str(owner.get_meta("audio_material"))
			if authored in AUTHORED:
				return authored
		if owner.is_in_group(ICE_GROUP): return "ice"
		owner = owner.get_parent()
	var label := str(collider.name).to_lower()
	if (collider is CollisionObject3D and (collider.collision_layer & (1 << 18)) != 0) or "cloud" in label: return "cloud"
	var terrain := WorldTerrain.instance
	if is_instance_valid(terrain) and is_instance_valid(terrain.terrain) and (collider == terrain.terrain or "terrain" in label):
		var data: Object = terrain.terrain.data
		if data != null and data.has_method("get_texture_id"):
			var info: Vector3 = data.call("get_texture_id", Vector3(hit.position))
			if info.is_finite():
				var id := int(info.y if info.z >= .5 else info.x)
				var assets: Object = terrain.terrain.assets
				var texture: Object = assets.call("get_texture", id) if assets != null and assets.has_method("get_texture") else null
				if texture != null: label = str(texture.get("name")).to_lower()
		return season_surface(source.get_tree(), Vector3(hit.position), Vector3(hit.normal), classify(label, "grass"), weather)
	if "terrain" in label: return classify(label, "grass")
	var known := classify(label, "")
	if not known.is_empty(): return known
	# Room contracts distinguish authored timber floors from town stone, regardless of collider names.
	return "wood" if HOUSE.at(source.get_tree(), Vector3(hit.position) + Vector3.UP * .02) != null else "stone"


## What lies on a terrain step: snow > leaves > puddle > mud > the texture's own kind (M-SEA-05:
## winter alone no longer means snow; bare slopes, trodden paths and thawed ground keep theirs).
static func season_surface(tree: SceneTree, at: Vector3, normal: Vector3, kind: String, weather: Node = null) -> String:
	if kind == "snow": return kind
	if SNOW.cover_at(tree, at, normal) >= SNOW_STEP: return "snow"
	if leaves_at(tree, at) >= LEAF_STEP: return "leaves"
	var wet := wetness_at(tree, at)
	if puddle_at(at, normal, wet) >= PUDDLE_STEP and puddles_shown(tree): return "puddle"
	var rain := 0.0
	if is_instance_valid(weather):
		var params: Variant = weather.get("params")
		if params is Dictionary: rain = float((params as Dictionary).get("rain", 0.0))
	if kind == "dirt" and (rain > .22 or wet > MUD_WET): return "mud"
	return kind


## Deepest leaves any leaf provider reports at `at` (0 without providers).
static func leaves_at(tree: SceneTree, at: Vector3) -> float:
	if tree == null or not tree.has_group(LEAF_GROUP): return 0.0
	var amount := 0.0
	for node: Node in tree.get_nodes_in_group(LEAF_GROUP):
		if node.has_method("leaves_at"): amount = maxf(amount, float(node.call("leaves_at", at)))
	return clampf(amount, 0.0, 1.0)


## Rain-wet ground at `at`: season wetness x the climate map's wet response (desert stays dry).
static func wetness_at(tree: SceneTree, at: Vector3) -> float:
	var state := SNOW.seasons(tree)
	if state == null: return 0.0
	var wet := float(state.call("wetness"))
	if wet <= .001: return 0.0
	return clampf(wet * float(state.call("climate", Vector2(at.x, at.z), 2)), 0.0, 1.0)


## Puddles stand on flat ground where it is wet enough; more of the ground floods as it gets
## wetter. Soft blobs a few metres across. The terrain shader's puddle mask (W2-SEAS-B) must use
## the same formula so a splash is heard where a puddle is seen.
static func puddle_at(at: Vector3, normal: Vector3, wet: float) -> float:
	if wet < .35: return 0.0
	var flat := smoothstep(.975, .995, normal.y)
	if flat <= 0.0: return 0.0
	var blobs := .5 + .25 * (sin(at.x * .43 + sin(at.z * .29) * 1.7) + sin(at.z * .37 + at.x * .19))
	var level := 1.05 - wet * .45
	return flat * smoothstep(level, level + .1, blobs)


## Puddles follow the quality key that shows them (default on until the key exists).
static func puddles_shown(tree: SceneTree) -> bool:
	var quality: Node = tree.root.get_node_or_null("Quality") if tree != null else null
	return quality == null or not quality.has_method("get_value") or bool(quality.call("get_value", "puddles", true))


static func classify(label: String, fallback: String = "stone") -> String:
	for pair: Array in [["snow", "snow"], ["gravel", "gravel"], ["sandstone", "stone"], ["sand", "sand"], ["mud", "mud"],
		["leaf", "leaves"], ["leaves", "leaves"], ["grass", "grass"], ["dirt", "dirt"],
		["wood", "wood"], ["plank", "wood"], ["bridge", "wood"], ["timber", "wood"],
		["rug", "cloth"], ["carpet", "cloth"], ["cushion", "cloth"], ["mattress", "cloth"],
		["rock", "stone"], ["stone", "stone"], ["cobble", "stone"], ["brick", "stone"], ["tile", "stone"], ["road", "stone"]]:
		if str(pair[0]) in label: return str(pair[1])
	return fallback
