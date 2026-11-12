extends Node
## The trees of a town's own scene, made known to everything that asks "where are the trees"
## (dev 2026-11-10: "no leaves falling"). The town's trees are a built scene (TownTrees, from
## tools/trees/build_town.gd) and the kit's few Grassy trees; neither is foliage that
## world/foliage/biome_foliage.gd places, so the "bird_habitats" group did not have them. In town
## that meant: no falling leaves, no leaf piles or leaf carpet under trees, and birds and sparrows
## with no tree to sing from. Measured in the shot tool on the main street: 0 crowns within reach.
##
## This node joins "bird_habitats" and answers the two questions of that group from a list of
## crowns it reads once, on the first question (the scene does not change afterwards):
## - tree_canopies(origin, radius) -> [{"position", "radius", "kind", "root"}] (world/seasons/tree_query.gd)
## - bird_perches(origin, near, far) -> [{"position", "owner"}] (world/ambience.gd)
## Cost: one pass over the town's tree nodes at the first question; a distance test per crown after.

const GROUP := "bird_habitats"
## A mesh lower than this is a bush or a stump, not a tree.
const MIN_HEIGHT := 3.0
## The crown's middle sits this far up the tree (the same share biome_foliage.gd uses).
const CROWN_UP := 0.72
const EVERGREEN_WORDS := ["cypress", "fir", "pine", "spruce"]

var _sources: Array = []
var _crowns: Array = []      # {"position": Vector3, "radius": float, "kind": int, "owner": Node}
var _read := false


## sources: nodes whose tree meshes or tree nodes to read (null entries are skipped).
func setup(sources: Array) -> void:
	_sources = sources
	add_to_group(GROUP)


func tree_canopies(origin: Vector3, radius: float) -> Array:
	_read_once()
	var result: Array = []
	for crown: Dictionary in _crowns:
		if (crown.position as Vector3).distance_to(origin) <= radius:
			result.append({"position": crown.position, "radius": crown.radius, "kind": crown.kind, "root": crown.root})
	return result


func bird_perches(origin: Vector3, near_distance := 25.0, far_distance := 70.0) -> Array:
	_read_once()
	var result: Array = []
	for crown: Dictionary in _crowns:
		if int(crown.kind) != 0 or not is_instance_valid(crown.owner): continue
		var distance := (crown.position as Vector3).distance_to(origin)
		if distance >= near_distance and distance <= far_distance:
			result.append({"position": crown.position, "owner": crown.owner})
	return result


func _read_once() -> void:
	if _read: return
	_read = true
	var seen: Dictionary = {}
	for source: Variant in _sources:
		if not (source is Node) or not is_instance_valid(source): continue
		for found: Node in (source as Node).find_children("*", "MeshInstance3D", true, false):
			var item := found as MeshInstance3D
			# One record per tree: its near mesh (the far mesh and the other parts repeat it).
			var title := str(item.name)
			if item.mesh == null or title.ends_with("_far") or (title.contains("_part") and not title.ends_with("_part0")): continue
			if title.begins_with("LOD") and not title.begins_with("LOD0"): continue
			var box := item.global_transform * item.mesh.get_aabb()
			if box.size.y < MIN_HEIGHT or not box.position.is_finite(): continue
			var crown := box.position + box.size * Vector3(0.5, CROWN_UP, 0.5)
			var key := "%d_%d" % [roundi(crown.x), roundi(crown.z)]
			if seen.has(key): continue
			seen[key] = true
			var words := (str(item.get_path())).to_lower()
			var evergreen := false
			for word: String in EVERGREEN_WORDS:
				if words.contains(word): evergreen = true
			_crowns.append({"position": crown, "radius": clampf(minf(box.size.x, box.size.z) * 0.5, 1.0, 6.0),
				"kind": 1 if evergreen else 0, "owner": item, "root": item.global_position})
