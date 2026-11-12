extends RefCounted
## Nearby tree crowns for the seasonal leaf and petal emitter and the leaf piles (W2-SEAS-E
## 2026-11-08, design captures/overhaul-2026-11-08/seasons/AUDIT_AND_DESIGN.md 6.3).
##
## Reads only public foliage data (hazard H8: never the private fields of biome_foliage.gd or the
## painted tree batches). Every node in the "bird_habitats" group (world/foliage/biome_foliage.gd)
## is asked, in this order:
## - tree_canopies(origin, radius) -> [{"position", "radius", "kind"}] when it has one (the richer
##   getter requested from the foliage owner: crown size and the tree kind of batched trees);
## - bird_perches(origin, 0, radius) -> [{"position", "owner"}] otherwise: the crown point of every
##   loaded tree (zone trees and painted batches). The kind comes from the owner node (zone tree
##   names, the grassy_tree_variant meta); batched trees read as broadleaf.
##
## A canopy record is {"position": Vector3 crown centre, "radius": crown radius in metres,
## "kind": BROADLEAF | EVERGREEN | BLOSSOM}, and "root" (Vector3, the tree's model origin) from a
## source that knows it. Records are plain data, so tests pass fixture lists.
const GROUP := "bird_habitats"
const CLIMATE := preload("res://world/seasons/climate_map.gd")
const BROADLEAF := 0
const EVERGREEN := 1
const BLOSSOM := 2
## Crown radius when the source does not say (bird_perches gives a point only).
const DEFAULT_RADIUS := 2.5
const MAX_RADIUS := 6.0
## Owner names / tree variant ids that mark a kind.
const EVERGREEN_WORDS := ["spruce", "pine", "fir"]
const BLOSSOM_WORDS := ["sakura", "blossom", "cherry"]

## Every crown within radius (horizontal and vertical) of origin from the live foliage.
static func canopies(tree: SceneTree, origin: Vector3, radius: float) -> Array:
	var result: Array = []
	if tree == null: return result
	for habitat: Node in tree.get_nodes_in_group(GROUP):
		if habitat.has_method("tree_canopies"):
			var rows: Variant = habitat.call("tree_canopies", origin, radius)
			if rows is Array:
				for row: Variant in rows:
					if row is Dictionary: result.append(normalised(row))
			continue
		if not habitat.has_method("bird_perches"): continue
		var perches: Variant = habitat.call("bird_perches", origin, 0.0, radius)
		if not perches is Array: continue
		for perch: Variant in perches:
			if not perch is Dictionary: continue
			var at: Variant = (perch as Dictionary).get("position")
			if not at is Vector3: continue
			var owner: Variant = (perch as Dictionary).get("owner")
			result.append({"position": at, "radius": DEFAULT_RADIUS, "kind": kind_of_owner(owner as Object if owner is Object else null)})
	return result

## A record with every key present and typed (fixtures and the future getter may leave some out).
static func normalised(row: Dictionary) -> Dictionary:
	var at: Variant = row.get("position", Vector3.ZERO)
	var radius: Variant = row.get("radius", DEFAULT_RADIUS)
	var kind: Variant = row.get("kind", BROADLEAF)
	var kind_id := BROADLEAF
	if kind is int: kind_id = clampi(kind, BROADLEAF, BLOSSOM)
	elif kind is String or kind is StringName: kind_id = kind_of_name(str(kind))
	var out := {"position": at if at is Vector3 else Vector3.ZERO,
		"radius": clampf(float(radius), 0.5, MAX_RADIUS) if radius is float or radius is int else DEFAULT_RADIUS,
		"kind": kind_id}
	# Optional: where the tree stands (its model origin), for a source that knows it. The leaf
	# carpet works out the tree's autumn colours from it, as the leaf shaders do.
	if row.get("root") is Vector3: out["root"] = row.get("root")
	return out

## The kind from a zone tree node (its name or its grassy_tree_variant id); BROADLEAF when unknown.
static func kind_of_owner(owner: Object) -> int:
	if owner == null or not is_instance_valid(owner): return BROADLEAF
	var words := ""
	if owner is Node: words = String((owner as Node).name)
	if owner.has_meta(&"grassy_tree_variant"):
		var variant: Variant = owner.get_meta(&"grassy_tree_variant", "")
		words += " " + str(variant)
	return kind_of_name(words)

static func kind_of_name(words: String) -> int:
	var lower := words.to_lower()
	if lower == "evergreen" or lower.begins_with("ck_sprucetree"): return EVERGREEN
	if lower == "blossom": return BLOSSOM
	for word: String in BLOSSOM_WORDS:
		if lower.contains(word): return BLOSSOM
	for word: String in EVERGREEN_WORDS:
		if lower.contains(word): return EVERGREEN
	return BROADLEAF

## The tree's own numbers as the leaf shaders work them out from its root (vegetation_autumn_tree
## in world/foliage/vegetation_color.gdshaderinc; keep the two the same): x = how late it is
## (0..1), y = its autumn colour kind.
static func autumn_tree(root: Vector3) -> Vector2:
	var v := ((int(floor(root.x * 4.0)) * 73856093) ^ (int(floor(root.z * 4.0)) * 19349663)) & 0xFFFFFFFF
	v = (v * 747796405 + 2891336453) & 0xFFFFFFFF
	var w := (((v >> ((v >> 28) + 4)) ^ v) * 277803737) & 0xFFFFFFFF
	w = ((w >> 22) ^ w) & 0xFFFFFFFF
	var late := float(w >> 8) / 16777215.0
	return Vector2(late, fposmod(late * 61.37 + 0.19, 1.0))

## Share of the broadleaf trees that flower in spring (SPRING_BLOSSOM_SHARE in the shader include).
const SPRING_BLOSSOM_SHARE := 0.6
## Does this tree flower in spring (vegetation_spring_tree in the shader include): a blossom tree
## always, an evergreen never, a broadleaf by its own number. A record without "root" is judged
## from its crown position, which may differ from what the shader draws for that tree.
static func flowers(row: Dictionary) -> bool:
	var kind := int(row.get("kind", BROADLEAF))
	if kind == BLOSSOM: return true
	if kind != BROADLEAF: return false
	return fposmod(autumn_tree(root_of(row)).x * 97.13 + 0.37, 1.0) < SPRING_BLOSSOM_SHARE

## The blossom kind of a tree, 0..1 (below 0.5 cherry pink, to 0.8 apple white, above plum).
static func blossom_kind(row: Dictionary) -> float:
	return fposmod(autumn_tree(root_of(row)).x * 41.7 + 0.11, 1.0)

static func root_of(row: Dictionary) -> Vector3:
	var root: Variant = row.get("root")
	if root is Vector3: return root
	var at: Variant = row.get("position", Vector3.ZERO)
	return at if at is Vector3 else Vector3.ZERO

## Emission points for the falling leaves (mode "leaves": every non-evergreen crown, thinned by the
## climate's deciduous share so the jungle and desert keep their leaves) or the petals (mode
## "petals": the crowns that flower in spring, flowers()). Each point is Vector4(crown centre xyz, crown radius). The
## nearest crowns to origin win when there are more than max_points. Deterministic: the same trees
## give the same points. use_climate false skips the climate map (tests).
static func emission_points(trees: Array, mode: String, origin: Vector3, max_points: int, use_climate := true) -> PackedVector4Array:
	var picked: Array = []
	for row: Variant in trees:
		if not row is Dictionary: continue
		var rec := normalised(row)
		var kind: int = rec.kind
		if mode == "petals":
			if not flowers(rec): continue
		elif mode == "leaves":
			if kind == EVERGREEN: continue
		else: continue
		var at: Vector3 = rec.position
		if mode == "leaves" and use_climate:
			# Deciduous share 0..1: a stable per-tree hash keeps that share of the crowns.
			var share := CLIMATE.sample(Vector2(at.x, at.z), 1)
			if share < 0.999 and _hash01(at) >= share: continue
		picked.append([at.distance_squared_to(origin), Vector4(at.x, at.y, at.z, float(rec.radius))])
	picked.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var points := PackedVector4Array()
	for i in mini(picked.size(), maxi(0, max_points)):
		points.append(picked[i][1])
	return points

## A stable 0..1 value from a world position (0.5 m grid, so float noise cannot flip it).
static func _hash01(at: Vector3) -> float:
	var key := Vector2i(roundi(at.x * 2.0), roundi(at.z * 2.0))
	return float(absi(hash(key)) % 10007) / 10007.0
