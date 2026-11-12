extends RefCounted
## Only the measured native tree atlases. Mixed bark/leaf textures retain a soft
## green-pixel mask; houses, ponies, trunks and colored blossoms keep their palette.
const ATLAS := {
	"Evershade_6.png":"Tree01", "Evershade_5.png":"Tree02",
	"Evershade_3.png":"Tree03", "Evershade_2.png":"Tree04",
	"Evershade_1.png":"Tree05_Diff", "White_Tail_Park_2.png":"PineTreeTex2"
}
## Atlases of evergreen trees: their copy gets the shader's `evergreen` flag (seasons: no autumn
## orange, no leaf drop, only a little cold darkening and crown snow). Any other material whose
## name says pine or spruce is evergreen too.
const EVERGREEN := ["PineTreeTex2"]
const EVERGREEN_WORDS := ["pine", "spruce", "conifer"]
## Blossom trees (the Grassy sakura): their leaf-card materials get `blossom_tree` = 1, so in
## spring they fill out sooner and a growing share of their cards flower pink.
const BLOSSOM_WORDS := ["sakura", "blossom", "cherry"]
const LEAF_SHADER := "res://world/terrain/kits/grassy_fields/leaves.gdshader"
## The town's offline far trees (tools/trees/build_far_trees.gd, one mesh per species, used by
## town_trees.scn) carry their own leaf material: apply() marks a blossom species' far mesh once.
const FAR_TREES := "res://world/foliage/grassy_fields/far/"
static var _cache: Dictionary = {}
static var _shaders: Dictionary = {}

static func material_for(source: Material) -> Material:
	if not source is ShaderMaterial or source.shader==null or source.has_meta(&"vegetation_ground_hue"):return source
	if not source.shader.resource_path.begins_with("res://addons/cel-shader/"):return source
	var texture: Texture2D=source.get_shader_parameter("base_texture")
	if texture==null or ATLAS.get(texture.resource_path.get_file(),"")!=source.resource_name:return source
	var key:=source.get_instance_id()
	if _cache.has(key):
		var cached: Material=_cache[key].get_ref()
		if cached!=null:return cached
	var path: String=source.shader.resource_path
	if not _shaders.has(path):
		var derived:="res://world/foliage/shaders/"+path.get_file()
		if not ResourceLoader.exists(derived):return source
		_shaders[path]=load(derived)
	var result:=source.duplicate() as ShaderMaterial
	result.shader=_shaders[path];result.set_meta(&"vegetation_ground_hue",true)
	if is_evergreen(source.resource_name):result.set_shader_parameter("evergreen",true)
	_cache[key]=weakref(result)
	return result

static func is_evergreen(material_name: String) -> bool:
	if material_name in EVERGREEN:return true
	var lower:=material_name.to_lower()
	for word: String in EVERGREEN_WORDS:
		if lower.contains(word):return true
	return false

static func is_blossom(tree_id: String) -> bool:
	var lower:=tree_id.to_lower()
	for word: String in BLOSSOM_WORDS:
		if lower.contains(word):return true
	return false

## Marks every leaf-card material of a tree (a PackedScene, Node or Mesh) as a blossom tree and
## returns how many it marked. The materials are shared resources, so this changes every user of
## them: call it once where the catalogue loads a blossom tree (grassy_catalogue.gd scene()),
## before any copy of the material is made (impostor crossfade copies duplicate it).
static func mark_blossom(source: Variant) -> int:
	var marked:=0
	if source is PackedScene:
		var instance:=(source as PackedScene).instantiate()
		marked=mark_blossom(instance)
		instance.free()
	elif source is Mesh:
		for surface in (source as Mesh).get_surface_count():marked+=_mark_blossom_material((source as Mesh).surface_get_material(surface))
	elif source is Node:
		var pending: Array[Node]=[source as Node]
		while not pending.is_empty():
			var node:=pending.pop_back() as Node
			if node is GeometryInstance3D:marked+=_mark_blossom_material((node as GeometryInstance3D).material_override)
			if node is MeshInstance3D and (node as MeshInstance3D).mesh!=null:
				var mesh_node:=node as MeshInstance3D
				for surface in mesh_node.mesh.get_surface_count():
					marked+=_mark_blossom_material(mesh_node.get_surface_override_material(surface))
					marked+=_mark_blossom_material(mesh_node.mesh.surface_get_material(surface))
			elif node is MultiMeshInstance3D and (node as MultiMeshInstance3D).multimesh!=null and (node as MultiMeshInstance3D).multimesh.mesh!=null:
				marked+=mark_blossom((node as MultiMeshInstance3D).multimesh.mesh)
			pending.append_array(node.get_children())
	return marked

static func _mark_blossom_material(material: Material) -> int:
	if not material is ShaderMaterial:return 0
	var shader:=(material as ShaderMaterial).shader
	if shader==null or shader.resource_path!=LEAF_SHADER:return 0
	if (material as ShaderMaterial).get_shader_parameter("blossom_tree")==1.0:return 0
	(material as ShaderMaterial).set_shader_parameter("blossom_tree",1.0)
	return 1

static func apply(root: Node) -> void:
	var pending: Array[Node]=[root]
	while not pending.is_empty():
		var node:=pending.pop_back() as Node
		var mesh: Mesh
		if node is MeshInstance3D:mesh=node.mesh
		elif node is MultiMeshInstance3D and node.multimesh!=null:mesh=node.multimesh.mesh
		if mesh!=null:
			# W2-SEAS-D H4: the sakura's far mesh blossoms like its near LODs (once; a marked mesh is skipped).
			if mesh.resource_path.begins_with(FAR_TREES) and not mesh.has_meta(&"blossom_checked"):
				mesh.set_meta(&"blossom_checked",true)
				if is_blossom(mesh.resource_path.get_file().get_basename()):mark_blossom(mesh)
			if node.material_override!=null:node.material_override=material_for(node.material_override)
			else:
				var replacement: Mesh
				for surface in mesh.get_surface_count():
					var source: Material=node.get_active_material(surface) if node is MeshInstance3D else mesh.surface_get_material(surface)
					var fitted:=material_for(source)
					if source==fitted:continue
					if node is MeshInstance3D:node.set_surface_override_material(surface,fitted)
					else:
						if replacement==null:replacement=mesh.duplicate()
						replacement.surface_set_material(surface,fitted)
				if replacement!=null:
					var multimesh: MultiMesh=node.multimesh.duplicate();multimesh.mesh=replacement;node.multimesh=multimesh
		pending.append_array(node.get_children())
