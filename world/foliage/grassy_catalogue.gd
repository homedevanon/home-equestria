extends RefCounted
## Portable approved pack shared by runtime vegetation, placements and proxy baking.
const PATH := "res://world/foliage/grassy_fields/catalogue_grassy.json"
static var _entries: Array = []
static var _scenes: Dictionary = {}

static func entries() -> Array:
	if _entries.is_empty() and FileAccess.file_exists(PATH):
		var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if doc is Dictionary and doc.get("portable", false): _entries = doc.get("assets", [])
	return _entries

static func trees() -> Array:
	return entries().filter(func(row): return row.category == "tree")


static func support_y(entry: Dictionary) -> float:
	# Portable scenes are shifted so their lowest root tip is local Y=0. The
	# original authored origin remains the trunk collar and is recorded by the
	# inverse vertical contact offset. Older manifests only have that offset.
	if entry.has("support_y") and float(entry.support_y) > 0.0:
		return float(entry.support_y)
	var offset: Variant = entry.get("contact_offset", [])
	return maxf(0.0, -float(offset[1])) if offset is Array and offset.size() >= 2 else 0.0

static func contact_offset(entry: Dictionary) -> Vector3:
	var value: Variant = entry.get("contact_offset", [])
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3(0.0, -support_y(entry), 0.0)

static func collar_offset(entry: Dictionary) -> Vector3:
	# Portable geometry was translated by -contact_offset. This is therefore the
	# original authored origin (the trunk collar) in the portable scene.
	return -contact_offset(entry)

static func scene(entry: Dictionary) -> PackedScene:
	var path := str(entry.scene)
	if not _scenes.has(path):
		_scenes[path] = load(path)
		# Sakura and other flowering trees get their spring blossom (W2-SEAS-D H1): once, before
		# tree_impostors.fading() duplicates the leaf material, so near/far LODs and crossfades match.
		var materials := preload("res://world/foliage/vegetation_materials.gd")
		if _scenes[path] != null and materials.is_blossom(str(entry.get("id", ""))): materials.mark_blossom(_scenes[path])
	return _scenes[path]

static func woodland_entries() -> Array:
	var result := []
	for source: Dictionary in entries():
		if source.category not in ["tree", "plant", "bush", "flower"]: continue
		var row := source.duplicate()
		row.family = "woodland"; row.archetype = row.id
		row.category = "tree" if row.category == "tree" else "plant"
		row.scale_class = "tree" if row.category == "tree" else "bush"
		result.append(row)
	return result

static func parts(entry: Dictionary, lod := 0) -> Array:
	var packed := scene(entry)
	if packed == null: return []
	var instance := packed.instantiate()
	var level := instance.get_node_or_null("LOD%d" % lod)
	if level == null:
		for child in instance.get_children():
			if str(child.name).begins_with("LOD%d_" % lod): level = child; break
	if level == null: level = instance
	var result := []; var stack := [[level, level.transform if level is Node3D else Transform3D.IDENTITY]]
	while not stack.is_empty():
		var item: Array = stack.pop_back(); var node: Node = item[0]; var xform: Transform3D = item[1]
		if node is MeshInstance3D and node.mesh != null:
			var mesh: Mesh = node.mesh.duplicate()
			for i in mesh.get_surface_count(): mesh.surface_set_material(i, node.get_active_material(i))
			result.append([mesh, xform])
		for child in node.get_children(): stack.append([child, xform * child.transform if child is Node3D else xform])
	instance.free()
	return result
