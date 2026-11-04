extends Node
## Two cheap draw-call cuts for Ponyville (dev 2026-09-25, from the draw-call profile):
## - Small parts stop casting sun shadows: window sashes and reveals, door pieces, props under
##   SMALL_CASTER metres. Every caster is drawn again for each shadow cascade it is in, which
##   was 32-42 % of all draws in town.
## - Occlusion culling: every house's exterior shell becomes an occluder (simplified), so at street
##   level whatever is behind a house (ponies, other houses, props) is not drawn at all. The house
##   the camera is inside drops its own occluder, so its windows still show the outside even if
##   simplification closed their holes.
## game.gd adds this node under the town once at startup.
##
## Sun and moon shadows, second pass (dev 2026-09-26, tools/profile/shadow_casters.gd at dev's
## snapshot: 1,269 of 3,099 draws were the moon's shadow pass, one draw per caster surface per
## cascade). No lamp in the game casts shadows, so cast_shadow only concerns the sun and moon.
## - No visible shadow, no caster: anything inside a house or the restaurant (walls and roof
##   already shade it), floors, and flat things under FLAT_CASTER tall. Also applied to meshes
##   added later (furniture is placed over several frames).
## - Everything else in town that stands still and is opaque is merged into shadow-only meshes,
##   one per SHADOW_CELL square (two where some casters are double-sided), with continuous LODs.
##   The originals still draw but stop casting. Doors (they swing), trees (wind), alpha-cut
##   cards, MultiMeshes, skinned meshes and anything with a short draw distance keep their own.

const HOUSE := preload("res://world/buildings/house_interior.gd")
const SMALL_CASTER := 1.6
## Anything lower than this casts a sliver at most.
const FLAT_CASTER := 0.4
const SHADOW_CELL := 64.0
## _merge_kinds: this surface keeps its own shadow (shadow-only twin), the others merge.
const KEEP_OWN := -1
## Shadow cells start at the first LOD with at most this share of their full triangles
## (0.4 until the 2026-10-23 GPU pass: 390k shadow triangles at the town hall).
const SHADOW_DETAIL := 0.15
## Alpha-cut casters merge per material, so their cells are bigger (fewer, fuller meshes).
const CUT_CELL := 256.0
## Parts that only exist inside a building, by node name (and everything under them).
const INDOOR := ["HouseInterior", "RestaurantInterior", "PonyBed", "FloorSlab", "FittedFloor", "Baseboard",
	"Skirting", "FloorUnderlay", "InnerThresholdRamp"]
## Town meshes with no LODs (houses and kit props: ~420k triangles, dev 2026-10-23 triangle pass)
## get generated ones on worker threads, so distance lowers their detail like the scenery's.
## LOD0 is the unchanged mesh. Meshes under this many triangles are not worth a task.
const VISIBLE_LOD_MIN_TRIANGLES := 600
## Occluder triangles per house exterior after simplification (the originals are ~11k).
const OCCLUDER_TRIANGLES := 1500

static var _occluders := {}  # exterior mesh -> ArrayOccluder3D, shared by every house of that kind
static var _lod_meshes := {}  # source mesh without LODs -> the same mesh with generated LODs

var town: Node3D
var _by_house := {}  # house interior -> its occluder
var _hidden: OccluderInstance3D
var _doors := {}  # house interior -> [[door mesh, its cast_shadow]]
var _door_home: Node
var _tick := 0.0
## Main-thread ownership of worker results, materials and weak shadow targets.
## Every WorkerThreadPool task must be joined, even when already completed.
var _lod_tasks: Dictionary = {}
var _mesh_tasks: Dictionary = {}  # task -> {"source", "surfaces", "materials", "names", "result"}
var statistics := {"shadows_trimmed": 0, "occluders": 0, "occluder_triangles": 0,
	"shadow_cells": 0, "merged_casters": 0, "merged_triangles": 0, "late_trimmed": 0,
	"flowerbed_boxes": 0, "batched_props": 0, "prop_batches": 0}

func setup(town_root: Node3D) -> void:
	town = town_root
	statistics.shadows_trimmed = trim_shadows(town)
	_merge_flowerbeds()
	_add_house_occluders()
	_collect_doors()
	get_viewport().use_occlusion_culling = true
	print("[render budget] %d small shadow casters off, %d house occluders (%d triangles)" % [
		statistics.shadows_trimmed, statistics.occluders, statistics.occluder_triangles])
	get_tree().node_added.connect(_on_node_added)
	var quality := get_node_or_null("/root/Quality")
	if quality != null and not quality.preset_changed.is_connected(_on_quality_changed): quality.preset_changed.connect(_on_quality_changed)
	# The window pieces merge on the frame after the houses are ready; merge the shadows after that.
	get_tree().create_timer(1.0).timeout.connect(_merge_shadows)
	get_tree().create_timer(1.5).timeout.connect(_queue_visible_lods)

## The caster size floor: SMALL_CASTER (Ultra), or the quality tier's small_caster (Low..High 3 m, Very Low 5 m).
static func small_caster() -> float:
	var loop := Engine.get_main_loop() as SceneTree
	var quality: Node = loop.root.get_node_or_null("Quality") if loop != null else null
	return float(quality.get_value("small_caster", SMALL_CASTER)) if quality != null else SMALL_CASTER

## A lower tier trims more casters; shadows are never given back until the town is rebuilt.
func _on_quality_changed(_preset: int) -> void:
	if is_instance_valid(town): statistics.late_trimmed += trim_shadows(town)

## Stops shadows from every mesh under `root` that is under SMALL_CASTER, flat, or indoors.
static func trim_shadows(root: Node) -> int:
	var count := 0
	var caster_floor := small_caster()
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		if _trim(node as GeometryInstance3D, root, caster_floor): count += 1
	return count

static func _trim(gi: GeometryInstance3D, root: Node, caster_floor: float) -> bool:
	if gi.cast_shadow in [GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY]:
		return false
	# Authored lining walls/ceilings are intentional indoor light blockers.
	# Their owner already disables shadows on paint, floor and trim.
	if bool(gi.get_meta("interior_attachment_surface", false)) and gi.find_parent("AuthoredLining") != null:
		return false
	if _world_size(gi) < caster_floor or _world_height(gi) < FLAT_CASTER or _indoor(gi, root):
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		return true
	return false

static func _indoor(node: Node, root: Node) -> bool:
	var at := node
	while at != null and at != root:
		var n := str(at.name)
		for prefix: String in INDOOR:
			if n.begins_with(prefix): return true
		at = at.get_parent()
	return false

static func _world_height(gi: GeometryInstance3D) -> float:
	if not (gi is MeshInstance3D) or (gi as MeshInstance3D).mesh == null: return INF
	return (gi.global_transform * gi.get_aabb()).size.y

## Furniture and other late meshes: the same rules once they have their mesh and place.
func _on_node_added(node: Node) -> void:
	if node is GeometryInstance3D and town != null and town.is_ancestor_of(node):
		_check_late.call_deferred(node)

func _check_late(node: Node) -> void:
	if is_instance_valid(node) and node.is_inside_tree() and not node.has_meta(BATCHED) and _trim(node as GeometryInstance3D, town, small_caster()):
		statistics.late_trimmed += 1

## One shadow-only mesh per SHADOW_CELL cell from every static caster left in town: plain opaque
## surfaces as positions only (one or two meshes per cell, one- and double-sided), alpha-cut
## surfaces with their UVs, one mesh per cell and material. LODs come from a worker thread.
func _merge_shadows() -> void:
	if not is_instance_valid(town): return
	var started := Time.get_ticks_msec()
	var cells := {}       # [cell x, cell z, double, material id or 0] -> {"vertices", "uvs", "indices"}
	var materials := {}   # material id -> the material, for alpha-cut groups
	var own_twins: Array = []   # [mesh instance, surfaces that keep their own shadow]
	for node in town.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var kinds := _merge_kinds(mi)
		if kinds.is_empty(): continue
		var double := mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		var centre := (mi.global_transform * mi.get_aabb()).get_center()
		var own: Array[int] = []
		for s in kinds.size():
			if typeof(kinds[s]) == TYPE_INT: own.append(s); continue
			var material: Material = kinds[s]
			var id := 0 if material == null else material.get_instance_id()
			if material != null: materials[id] = material
			var cell_size := SHADOW_CELL if id == 0 else CUT_CELL
			var key := [floori(centre.x / cell_size), floori(centre.z / cell_size), double, id]
			if not cells.has(key): cells[key] = {"vertices": PackedVector3Array(), "uvs": PackedVector2Array(), "indices": PackedInt32Array()}
			_append(cells[key], mi, s, material != null, Transform3D.IDENTITY)
		if not own.is_empty(): own_twins.append([mi, own])
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		statistics.merged_casters += 1
	var holder := Node3D.new(); holder.name = "MergedShadows"; town.add_child(holder)
	# Surfaces that cannot merge (blended glass, animated vertices) keep casting through a
	# shadow-only twin of just those surfaces; the rest of their mesh merges. The town hall shell
	# cast its whole 51.6k triangles for one glass surface (2026-10-23 GPU pass).
	for twin_of: Array in own_twins:
		var source: MeshInstance3D = twin_of[0]
		var mesh := ArrayMesh.new()
		for s: int in twin_of[1]:
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, source.mesh.surface_get_arrays(s))
			mesh.surface_set_material(mesh.get_surface_count() - 1, source.get_active_material(s))
		var twin := MeshInstance3D.new()
		twin.name = "OwnShadow_" + str(source.name)
		twin.mesh = mesh
		twin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		holder.add_child(twin)
		twin.global_transform = source.global_transform
	var one_sided := StandardMaterial3D.new()
	var two_sided := StandardMaterial3D.new(); two_sided.cull_mode = BaseMaterial3D.CULL_DISABLED
	var two_sided_copies := {}
	for key in cells:
		var cell: Dictionary = cells[key]
		if cell.indices.is_empty(): continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = cell.vertices
		arrays[Mesh.ARRAY_INDEX] = cell.indices
		var material: Material = one_sided
		if key[3] != 0:
			arrays[Mesh.ARRAY_TEX_UV] = cell.uvs
			material = materials[key[3]]
			if key[2]:
				if not two_sided_copies.has(key[3]):
					var copy := material.duplicate()
					if copy is BaseMaterial3D: (copy as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
					two_sided_copies[key[3]] = copy
				material = two_sided_copies[key[3]]
		elif key[2]:
			material = two_sided
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, material)
		var shadow := MeshInstance3D.new()
		shadow.name = "Cell_%d_%d%s%s" % [key[0], key[1], "_double" if key[2] else "", "" if key[3] == 0 else "_cut"]
		shadow.mesh = mesh
		shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		holder.add_child(shadow)
		statistics.shadow_cells += 1
		statistics.merged_triangles += cell.indices.size() / 3
		_queue_lods(arrays, shadow, material)
	print("[render budget] shadows: %d casters merged into %d shadow meshes (%d triangles) in %d ms; %d late indoor/flat/small casters off" % [
		statistics.merged_casters, statistics.shadow_cells, statistics.merged_triangles, Time.get_ticks_msec() - started, statistics.late_trimmed])
	_merge_tree_shadows()
	_batch_props()

## Town tree shadows (2026-10-23 GPU pass: ~80 separate shadow draws for 110 trees): every tree's
## full-detail surfaces merge per material into a few shadow-only meshes per CUT_CELL, and the
## trees themselves stop casting. Leaves keep their wind sway in the shadow: leaves.gdshader works in
## world space already; only the billboard card size needed the tree's scale, which each merged
## vertex carries in UV2.x for a variant of the shader (TREE_SHADOW_CARD).
const TREE_SHADOW_CARD := ["vec3 card_offset = (mat3(MODEL_MATRIX) * facing_local * billboard_size_cm", "vec3 card_offset = (facing_world * UV2.x * billboard_size_cm"]
static var _tree_shadow_shaders := {}

func _merge_tree_shadows() -> void:
	var trees := town.get_node_or_null("TownTrees")
	if trees == null: return
	var holder := Node3D.new(); holder.name = "MergedTreeShadows"; town.add_child(holder)
	var to_holder := holder.global_transform.affine_inverse()
	var groups := {}   # [cell x, cell z, material id] -> {material, v, n, uv, uv2, i}
	var casters := 0
	for node in trees.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF: continue
		# The full-detail tree casts for every distance; its far LOD stops casting too.
		if mi.visibility_range_begin <= 0.0:
			var xf: Transform3D = to_holder * mi.global_transform
			var tree_scale := mi.global_transform.basis.get_scale().x
			var centre := (mi.global_transform * mi.get_aabb()).get_center()
			for surface in mi.mesh.get_surface_count():
				var material := mi.get_active_material(surface)
				if material == null: continue
				var key := [floori(centre.x / CUT_CELL), floori(centre.z / CUT_CELL), material.get_instance_id()]
				if not groups.has(key): groups[key] = {"material": material, "v": PackedVector3Array(), "n": PackedVector3Array(),
					"uv": PackedVector2Array(), "uv2": PackedVector2Array(), "i": PackedInt32Array()}
				_append_tree(groups[key], mi.mesh.surface_get_arrays(surface), xf, tree_scale)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		casters += 1
	for key: Array in groups:
		var group: Dictionary = groups[key]
		var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = group.v; arrays[Mesh.ARRAY_NORMAL] = group.n
		arrays[Mesh.ARRAY_TEX_UV] = group.uv; arrays[Mesh.ARRAY_TEX_UV2] = group.uv2; arrays[Mesh.ARRAY_INDEX] = group.i
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, _tree_shadow_material(group.material))
		var shadow := MeshInstance3D.new()
		shadow.name = "TreeShadow_%d_%d" % [key[0], key[1]]
		shadow.mesh = mesh
		shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		holder.add_child(shadow)
	print("[render budget] tree shadows: %d tree meshes into %d shadow meshes" % [casters, groups.size()])

static func _append_tree(into: Dictionary, arrays: Array, xf: Transform3D, tree_scale: float) -> void:
	# Packed arrays come out of a Dictionary as copies: work on locals, store them back.
	var v: PackedVector3Array = into.v; var n: PackedVector3Array = into.n
	var uv: PackedVector2Array = into.uv; var uv2: PackedVector2Array = into.uv2; var index: PackedInt32Array = into.i
	var source: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
	var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV]
	var base := v.size()
	v.append_array(xf * source)
	for k in source.size():
		n.append((xf.basis * (normals as PackedVector3Array)[k]).normalized() if normals is PackedVector3Array else Vector3.UP)
		uv.append((uvs as PackedVector2Array)[k] if uvs is PackedVector2Array else Vector2.ZERO)
		uv2.append(Vector2(tree_scale, 0.0))
	var indices: Variant = arrays[Mesh.ARRAY_INDEX]
	if indices is PackedInt32Array and (indices as PackedInt32Array).size() > 0:
		for k: int in (indices as PackedInt32Array): index.append(base + k)
	else:
		for k in source.size(): index.append(base + k)
	into.v = v; into.n = n; into.uv = uv; into.uv2 = uv2; into.i = index

## Leaves need the per-vertex tree scale; any other material (trunks) casts as it is.
static func _tree_shadow_material(material: Material) -> Material:
	var shader_material := material as ShaderMaterial
	if shader_material == null or shader_material.shader == null or not shader_material.shader.code.contains(TREE_SHADOW_CARD[0]):
		return material
	var original: Shader = shader_material.shader
	if not _tree_shadow_shaders.has(original):
		var variant := Shader.new()
		variant.code = original.code.replace(TREE_SHADOW_CARD[0], TREE_SHADOW_CARD[1])
		_tree_shadow_shaders[original] = variant
	var copy := shader_material.duplicate() as ShaderMaterial
	copy.shader = _tree_shadow_shaders[original]
	return copy

func _queue_lods(arrays: Array, shadow: MeshInstance3D, material: Material) -> int:
	var result: Array[Dictionary] = []
	# Workers own data only. No scene nodes/materials or deferred swap callbacks
	# can survive scene removal or run after the RenderingServer is destroyed.
	var task: int = WorkerThreadPool.add_task(_add_lods.bind(arrays, result), false, "Shadow cell LODs")
	_lod_tasks[task] = {"arrays":arrays, "result":result, "shadow":weakref(shadow), "material":material}
	return task

func _poll_lods() -> void:
	if _lod_tasks.is_empty(): return
	for task: int in _lod_tasks.keys():
		if not WorkerThreadPool.is_task_completed(task):
			continue
		WorkerThreadPool.wait_for_task_completion(task)
		var job: Dictionary = _lod_tasks[task]
		var target: WeakRef = job.shadow
		var shadow: MeshInstance3D = target.get_ref() as MeshInstance3D
		var result: Array[Dictionary] = job.result
		if shadow != null and not result.is_empty():
			_swap_lods(shadow, job.arrays, result[0], job.material)
		_lod_tasks.erase(task)

func _exit_tree() -> void:
	# Runtime stays asynchronous: only teardown waits for unfinished work. Drop
	# completed results here rather than scheduling swaps onto exiting nodes.
	for task: int in _lod_tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_lod_tasks.clear()
	for task: int in _mesh_tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_mesh_tasks.clear()

## Every static town mesh without LODs, once per mesh: copy its surfaces on the main thread,
## generate LODs on a worker, then swap the LOD'd copy onto every user (_poll_mesh_lods).
func _queue_visible_lods() -> void:
	if not is_instance_valid(town): return
	var users := {}  # mesh -> [weakref to each MeshInstance3D / MultiMeshInstance3D using it]
	for node in town.find_children("*", "GeometryInstance3D", true, false):
		var source := _lod_source(node)
		if source == null: continue
		if not users.has(source): users[source] = []
		(users[source] as Array).append(weakref(node))
	for mesh: ArrayMesh in users:
		if _lod_meshes.has(mesh):
			_use_lod_mesh(mesh, _lod_meshes[mesh], users[mesh]); continue
		var surfaces := []; var materials := []; var names := []
		var triangles := 0
		var usable := mesh.get_blend_shape_count() == 0
		for s in mesh.get_surface_count():
			if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES or not (RenderingServer.mesh_get_surface(mesh.get_rid(), s).get("lods", []) as Array).is_empty():
				usable = false; break
			var arrays := mesh.surface_get_arrays(s)
			triangles += ((arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() if arrays[Mesh.ARRAY_INDEX] != null else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
			surfaces.append(arrays); materials.append(mesh.surface_get_material(s)); names.append(mesh.surface_get_name(s))
		if not usable or triangles < VISIBLE_LOD_MIN_TRIANGLES: continue
		var result: Array[Dictionary] = []
		var task: int = WorkerThreadPool.add_task(_surface_lods.bind(surfaces, result), false, "Town mesh LODs")
		_mesh_tasks[task] = {"source": mesh, "surfaces": surfaces, "materials": materials, "names": names, "result": result, "users": users[mesh]}

static func _lod_source(node: Node) -> ArrayMesh:
	if node is MeshInstance3D and (node as MeshInstance3D).skin == null: return (node as MeshInstance3D).mesh as ArrayMesh
	if node is MultiMeshInstance3D and (node as MultiMeshInstance3D).multimesh != null: return (node as MultiMeshInstance3D).multimesh.mesh as ArrayMesh
	return null

## Worker thread: per-surface LOD indices only; the main thread builds the mesh.
static func _surface_lods(surfaces: Array, result: Array[Dictionary]) -> void:
	var lods := {}
	for s in surfaces.size():
		var importer := ImporterMesh.new()
		var arrays: Array = surfaces[s]
		if arrays[Mesh.ARRAY_INDEX] == null:
			var count := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			var indices := PackedInt32Array(); indices.resize(count)
			for i in count: indices[i] = i
			arrays = arrays.duplicate(); arrays[Mesh.ARRAY_INDEX] = indices; surfaces[s] = arrays
		importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, _lod_input(arrays))
		importer.generate_lods(60.0, 25.0, [])
		var levels := {}
		for i in importer.get_surface_lod_count(0):
			levels[importer.get_surface_lod_size(0, i)] = importer.get_surface_lod_indices(0, i)
		lods[s] = levels
	result.append(lods)

func _poll_mesh_lods() -> void:
	if _mesh_tasks.is_empty(): return
	for task: int in _mesh_tasks.keys():
		if not WorkerThreadPool.is_task_completed(task): continue
		WorkerThreadPool.wait_for_task_completion(task)
		var job: Dictionary = _mesh_tasks[task]
		_mesh_tasks.erase(task)
		var result: Array[Dictionary] = job.result
		if result.is_empty() or not is_instance_valid(town): continue
		var source: ArrayMesh = job.source
		var mesh := ArrayMesh.new()
		mesh.resource_name = source.resource_name
		for s in (job.surfaces as Array).size():
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, job.surfaces[s], [], result[0].get(s, {}))
			mesh.surface_set_material(s, job.materials[s])
			mesh.surface_set_name(s, job.names[s])
		mesh.custom_aabb = source.custom_aabb
		_lod_meshes[source] = mesh
		_use_lod_mesh(source, mesh, job.users)

static func _use_lod_mesh(source: ArrayMesh, mesh: ArrayMesh, users: Array) -> void:
	for ref: WeakRef in users:
		var node: Object = ref.get_ref()
		if node is MeshInstance3D and (node as MeshInstance3D).mesh == source: (node as MeshInstance3D).mesh = mesh
		elif node is MultiMeshInstance3D and (node as MultiMeshInstance3D).multimesh != null and (node as MultiMeshInstance3D).multimesh.mesh == source:
			(node as MultiMeshInstance3D).multimesh.mesh = mesh

## Worker thread: only its result is shared; main reads it after joining the task.
static func _add_lods(arrays: Array, result: Array[Dictionary]) -> void:
	var importer := ImporterMesh.new()
	importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, _lod_input(arrays))
	importer.generate_lods(60.0, 25.0, [])
	var lods := {}
	for i in importer.get_surface_lod_count(0):
		lods[importer.get_surface_lod_size(0, i)] = importer.get_surface_lod_indices(0, i)
	result.append(lods)

## ImporterMesh's missing-normal fallback allocates by index count, but then
## reads normals by vertex index. Cut/merged surfaces can retain unused vertices
## (house F windows: 7866 vertices, 468 indices), so that fallback reads past its
## buffer. Supply actual indexed, area-weighted normals on a worker-only copy.
## Keep original positions, indices and UVs exactly: LOD indices still address
## the original full-resolution shadow mesh and visible meshes are never changed.
static func _lod_input(arrays: Array) -> Array:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var existing: Variant = arrays[Mesh.ARRAY_NORMAL]
	if existing is PackedVector3Array and existing.size() == vertices.size():
		return arrays
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var normals: PackedVector3Array = PackedVector3Array()
	normals.resize(vertices.size())
	for offset: int in range(0, indices.size(), 3):
		var a: int = indices[offset]
		var b: int = indices[offset + 1]
		var c: int = indices[offset + 2]
		var normal: Vector3 = (vertices[a] - vertices[c]).cross(vertices[a] - vertices[b])
		normals[a] += normal
		normals[b] += normal
		normals[c] += normal
	for index: int in normals.size():
		normals[index] = normals[index].normalized()
	var prepared: Array = arrays.duplicate()
	prepared[Mesh.ARRAY_NORMAL] = normals
	return prepared

static func _swap_lods(shadow: MeshInstance3D, arrays: Array, lods: Dictionary, material: Material) -> void:
	if not is_instance_valid(shadow) or lods.is_empty(): return
	# A shadow needs only the caster's silhouette (dev 2026-10-23 triangle pass): start from the
	# first generated LOD at or below SHADOW_DETAIL of the full triangles and keep the coarser
	# ones for distance. A cell whose LODs never get that low keeps its full mesh.
	var full: int = (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
	var sizes: Array = lods.keys()
	sizes.sort_custom(func(a, b) -> bool: return (lods[a] as PackedInt32Array).size() > (lods[b] as PackedInt32Array).size())
	for size in sizes:
		var indices: PackedInt32Array = lods[size]
		if indices.size() > full * SHADOW_DETAIL: continue
		arrays = arrays.duplicate()
		arrays[Mesh.ARRAY_INDEX] = indices
		var coarser := {}
		for other in lods:
			if (lods[other] as PackedInt32Array).size() < indices.size(): coarser[other] = lods[other]
		lods = coarser
		break
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], lods)
	mesh.surface_set_material(0, material)
	shadow.mesh = mesh

## Per surface of a static, unskinned, casting, visible mesh: null for a plain opaque surface, the
## material for an alpha-cut one (its shadow needs the texture). Empty when the mesh keeps its own
## shadow: doors swing, trees sway, and a draw distance shorter than any shadow distance (the
## quality presets go up to 200 m) would leave a shadow with nothing casting it.
func _merge_kinds(mi: MeshInstance3D) -> Array:
	if mi.mesh == null or mi.skin != null or not mi.is_visible_in_tree(): return []
	if not (mi.cast_shadow in [GeometryInstance3D.SHADOW_CASTING_SETTING_ON, GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED]): return []
	if mi.visibility_range_end > 0.0 and mi.visibility_range_end < 210.0: return []
	if mi.visibility_range_begin > 0.0: return []
	var at: Node = mi.get_parent()
	while at != null and at != town:
		if at is CharacterBody3D or str(at.name).contains("Door") or str(at.name) == "TownTrees": return []
		# Merged shadows stand still: the floating Cloudominium keeps its own (cloud_drift.gd).
		if at.has_meta("floating"): return []
		var script: Script = at.get_script()
		if script != null and script.resource_path.contains("door"): return []
		at = at.get_parent()
	var out := []
	for s in mi.mesh.get_surface_count():
		if mi.mesh is ArrayMesh and (mi.mesh as ArrayMesh).surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES: return []
		var material := mi.get_active_material(s)
		match _shadow_kind(material):
			0: out.append(KEEP_OWN)
			1: out.append(null)
			2: out.append(material)
	# Nothing mergeable: the mesh keeps its own shadow as before.
	if out.all(func(k: Variant) -> bool: return typeof(k) == TYPE_INT): return []
	return out

## 1: its shadow is just its geometry. 2: alpha-cut, the shadow needs the material and UVs.
## 0: can't be merged (blended transparency, billboards, moving vertices).
static func _shadow_kind(material: Material) -> int:
	if material == null: return 1
	if material is BaseMaterial3D:
		var base := material as BaseMaterial3D
		if base.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED: return 0
		match base.transparency:
			BaseMaterial3D.TRANSPARENCY_DISABLED: return 1
			BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR, BaseMaterial3D.TRANSPARENCY_ALPHA_HASH:
				# Many imported props are marked alpha-cut with a texture that has no alpha at all.
				return 2 if base.albedo_color.a < 0.999 or _has_alpha(base.albedo_texture) else 1
		return 0
	if material is ShaderMaterial:
		var shader := (material as ShaderMaterial).shader
		if shader == null: return 1
		var code := shader.code
		if code.contains("void vertex") and code.contains("TIME"): return 0
		# The cel shader variants say what they do in their defines (addons/cel-shader).
		if code.contains("#define USE_ALPHA"):
			if code.contains("#define USE_ALPHA 1"): return 0
			if not code.contains("#define USE_ALPHA_CUTOFF 1"): return 1
			var shader_material := material as ShaderMaterial
			var tint: Variant = shader_material.get_shader_parameter("color")
			var texture: Variant = shader_material.get_shader_parameter("base_texture")
			if tint is Color and (tint as Color).a < 0.999: return 2
			return 2 if texture == null or _has_alpha(texture as Texture2D) else 1
		if code.contains("ALPHA") or code.contains("discard"): return 0
		return 1
	return 0

## Whether a texture has any transparent texel (cached per texture). Unknown counts as yes.
static var _texture_alpha := {}
static func _has_alpha(texture: Texture2D) -> bool:
	if texture == null: return false
	var id := texture.get_instance_id()
	if _texture_alpha.has(id): return _texture_alpha[id]
	var result := true
	var image := texture.get_image()
	if image != null:
		match image.get_format():
			Image.FORMAT_DXT1, Image.FORMAT_ETC, Image.FORMAT_ETC2_RGB8, Image.FORMAT_BPTC_RGBF, Image.FORMAT_BPTC_RGBFU, \
			Image.FORMAT_RGB8, Image.FORMAT_L8, Image.FORMAT_RGTC_R, Image.FORMAT_RGTC_RG:
				result = false
			_:
				var copy := image
				if copy.is_compressed():
					copy = image.duplicate(); copy.decompress()
				result = copy.is_compressed() or copy.detect_alpha() != Image.ALPHA_NONE
	_texture_alpha[id] = result
	return result

## Positions (and UVs for alpha-cut groups) and indices of one surface of `mi`, in world space.
static func _append(cell: Dictionary, mi: MeshInstance3D, surface: int, with_uv: bool, space: Transform3D) -> void:
	var xform := space * mi.global_transform
	var vertices: PackedVector3Array = cell.vertices
	var uvs: PackedVector2Array = cell.uvs
	var indices: PackedInt32Array = cell.indices
	var arrays := mi.mesh.surface_get_arrays(surface)
	var source: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var base := vertices.size()
	for v in source: vertices.append(xform * v)
	if with_uv:
		var source_uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		if source_uv.size() == source.size(): uvs.append_array(source_uv)
		else:
			for i in source.size(): uvs.append(Vector2.ZERO)
	if arrays[Mesh.ARRAY_INDEX] != null and (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() > 0:
		for i in (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array): indices.append(base + i)
	else:
		for i in source.size(): indices.append(base + i)
	cell.vertices = vertices
	cell.uvs = uvs
	cell.indices = indices

static func _world_size(gi: GeometryInstance3D) -> float:
	var local := AABB()
	var scale := gi.global_basis.get_scale()
	if gi is MultiMeshInstance3D:
		var mm := (gi as MultiMeshInstance3D).multimesh
		if mm == null or mm.mesh == null or mm.instance_count == 0: return INF
		local = mm.mesh.get_aabb()
		scale *= mm.get_instance_transform(0).basis.get_scale()
	elif gi is MeshInstance3D:
		if (gi as MeshInstance3D).mesh == null: return INF
		local = (gi as MeshInstance3D).mesh.get_aabb()
	else:
		return INF
	var size := local.size * scale
	return maxf(size.x, maxf(size.y, size.z))

const FLOWERBED := "res://world/props/ponyville/flowerbed.scn"
## Flowerbed boxes (soil and four boards per bed, 19 beds: 95 draws of 12-triangle boxes) become
## one mesh per material for the whole town. Only boxes the trim above left without a shadow
## merge; a board on a slope that still casts keeps its own node for the shadow merge.
func _merge_flowerbeds() -> void:
	var props := town.get_node_or_null("OutdoorProps")
	if props == null: return
	var groups := {}  # [material, layers] -> merged arrays
	var sources := {}  # BoxMesh -> its CPU arrays (append_from would read each back from the GPU)
	var to_town := town.global_transform.affine_inverse()
	for bed in props.get_children():
		if bed.scene_file_path != FLOWERBED: continue
		for child in bed.get_children():
			var box := child as MeshInstance3D
			if box == null or not (box.mesh is BoxMesh) or not box.is_visible_in_tree() or box.material_overlay != null: continue
			if box.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF or box.visibility_range_end > 0.0: continue
			var key := [box.material_override, box.layers]
			if not groups.has(key):
				groups[key] = {"v": PackedVector3Array(), "n": PackedVector3Array(), "t": PackedFloat32Array(), "uv": PackedVector2Array(), "i": PackedInt32Array()}
			if not sources.has(box.mesh): sources[box.mesh] = (box.mesh as BoxMesh).get_mesh_arrays()
			_append_arrays(groups[key], sources[box.mesh], to_town * box.global_transform)
			box.visible = false
			statistics.flowerbed_boxes += 1
	for key: Array in groups:
		var part: Dictionary = groups[key]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = part.v; arrays[Mesh.ARRAY_NORMAL] = part.n; arrays[Mesh.ARRAY_TANGENT] = part.t
		arrays[Mesh.ARRAY_TEX_UV] = part.uv; arrays[Mesh.ARRAY_INDEX] = part.i
		var mesh := ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var merged := MeshInstance3D.new(); merged.name = "MergedFlowerbeds%d" % town.get_child_count()
		merged.mesh = mesh
		merged.material_override = key[0]; merged.layers = key[1]
		merged.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		town.add_child(merged)

## A primitive's arrays moved by `xf` onto `into` ({v, n, t, uv, i}), normals and tangents turned.
static func _append_arrays(into: Dictionary, src: Array, xf: Transform3D) -> void:
	var v: PackedVector3Array = into.v; var n: PackedVector3Array = into.n; var t: PackedFloat32Array = into.t
	var uv: PackedVector2Array = into.uv; var index: PackedInt32Array = into.i
	var base := v.size()
	var normal_basis := xf.basis.inverse().transposed()
	for p: Vector3 in src[Mesh.ARRAY_VERTEX]: v.append(xf * p)
	for q: Vector3 in src[Mesh.ARRAY_NORMAL]: n.append((normal_basis * q).normalized())
	var tangents: PackedFloat32Array = src[Mesh.ARRAY_TANGENT]
	for k in range(0, tangents.size(), 4):
		var d := (xf.basis * Vector3(tangents[k], tangents[k + 1], tangents[k + 2])).normalized()
		t.append(d.x); t.append(d.y); t.append(d.z); t.append(tangents[k + 3])
	uv.append_array(src[Mesh.ARRAY_TEX_UV])
	for k: int in src[Mesh.ARRAY_INDEX]: index.append(base + k)
	into.v = v; into.n = n; into.t = t; into.uv = uv; into.i = index

const BATCH_CELL := 64.0
const BATCHED := &"render_budget_batch"
## RNL prefab folders (world/props/rnl/<folder>/prefab.scn) that are plain repeated scenery.
const BATCH_KINDS := ["haybale", "hay_pile", "haypile", "banner", "barrel", "crate", "soda_case", "applejack_pile", "plantpot", "boulder"]
## dev 2026-10-20 perf pass: these repeat too (38 street lamps, 11 apple buckets, 7 picnic tables,
## 8 benches, 4 farm sheds; ~30 instance draws of 2-3 surfaces each saved town-wide). A lamp's
## light is a sibling node and the seats are measured by hand (seating.gd MANUAL), so neither
## reads these meshes. Empty this list to roll back.
const BATCH_KINDS_MORE := ["lamppost", "applebucket", "picnictable", "lyrasbench", "appleacres_shed"]
const DAISY := "res://world/props/ponyville/daisy.scn"
## Repeated RNL props (hay bales, hay piles, banners, crates, barrels…, ~200 nodes, a draw per
## surface each) become one MultiMesh per mesh and BATCH_CELL cell with the same mesh, shadow,
## layer and fade settings. Each batch's draw distance grows by its reach (a batch fades by its
## centre), so no prop goes sooner than before. Nodes, colliders and labels stay; only each
## prop's own mesh drawing is switched off. Runs after the shadow merge so its casting holds.
func _batch_props() -> void:
	var meshes: Array[Node] = []
	# The flowerbeds' daisies repeat too (57 single draws, 2026-10-23 GPU pass).
	for part: String in ["RNLScenery", "OutdoorProps"]:
		var scenery := town.get_node_or_null(part)
		if scenery != null: meshes.append_array(scenery.find_children("*", "MeshInstance3D", true, false))
	if meshes.is_empty(): return
	var groups := {}
	for node in meshes:
		var mi := node as MeshInstance3D
		if not _batchable(mi): continue
		var centre := (mi.global_transform * mi.get_aabb()).get_center()
		var key := [mi.mesh, mi.cast_shadow, mi.layers, mi.gi_mode, mi.lod_bias, mi.visibility_range_end,
			mi.visibility_range_end_margin, mi.visibility_range_fade_mode, floori(centre.x / BATCH_CELL), floori(centre.z / BATCH_CELL)]
		if not groups.has(key): groups[key] = []
		(groups[key] as Array).append(mi)
	var holder := Node3D.new(); holder.name = "BatchedProps"; town.add_child(holder)
	var to_holder := holder.global_transform.affine_inverse()
	for key: Array in groups:
		var list: Array = groups[key]
		if list.size() < 2: continue
		var first: MeshInstance3D = list[0]
		var mm := MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.mesh = first.mesh
		mm.instance_count = list.size()
		# Visibility ranges use the instance node's origin, not the MultiMesh's
		# remote geometry. Centre the node on its geometry in holder coordinates.
		var bounds := AABB()
		for i in list.size():
			var xf: Transform3D = to_holder * (list[i] as MeshInstance3D).global_transform
			var instance_bounds: AABB = xf * first.mesh.get_aabb()
			bounds = instance_bounds if i == 0 else bounds.merge(instance_bounds)
		var batch_origin := bounds.get_center()
		# One upload (MultiMesh.buffer rows, as set_instance_transform writes them): a first
		# set_instance_transform copies the new GPU buffer back to the CPU, a stall per batch.
		var data := PackedFloat32Array(); data.resize(list.size() * 12)
		for i in list.size():
			var xf: Transform3D = to_holder * (list[i] as MeshInstance3D).global_transform
			xf.origin -= batch_origin
			var b := xf.basis; var o := xf.origin; var k := i * 12
			data[k] = b.x.x; data[k + 1] = b.y.x; data[k + 2] = b.z.x; data[k + 3] = o.x
			data[k + 4] = b.x.y; data[k + 5] = b.y.y; data[k + 6] = b.z.y; data[k + 7] = o.y
			data[k + 8] = b.x.z; data[k + 9] = b.y.z; data[k + 10] = b.z.z; data[k + 11] = o.z
		mm.buffer = data
		mm.custom_aabb = AABB(bounds.position - batch_origin, bounds.size)
		var centre := holder.global_transform * batch_origin
		var reach := 0.0
		for mi: MeshInstance3D in list:
			reach = maxf(reach, (mi.global_transform * mi.get_aabb()).get_center().distance_to(centre))
		var batch := MultiMeshInstance3D.new(); batch.name = "Batch_%d" % statistics.prop_batches
		batch.position = batch_origin
		batch.multimesh = mm
		# Its shadow setting is already the trimmed one of the props it draws.
		batch.set_meta(BATCHED, true)
		batch.cast_shadow = first.cast_shadow; batch.layers = first.layers
		batch.gi_mode = first.gi_mode; batch.lod_bias = first.lod_bias
		if first.visibility_range_end > 0.0: batch.visibility_range_end = first.visibility_range_end + reach
		batch.visibility_range_end_margin = first.visibility_range_end_margin
		batch.visibility_range_fade_mode = first.visibility_range_fade_mode
		holder.add_child(batch)
		for mi: MeshInstance3D in list: mi.visible = false
		statistics.prop_batches += 1
		statistics.batched_props += list.size()
	print("[render budget] %d flowerbed boxes merged; %d repeated props drawn as %d batches" % [
		statistics.flowerbed_boxes, statistics.batched_props, statistics.prop_batches])
	_merge_stone()

func _batchable(mi: MeshInstance3D) -> bool:
	if mi.mesh == null or mi.skin != null or mi.material_override != null or mi.material_overlay != null: return false
	if mi.get_child_count() > 0 or not mi.is_visible_in_tree() or mi.visibility_range_begin > 0.0 or mi.transparency > 0.0: return false
	for s in mi.get_surface_override_material_count():
		if mi.get_surface_override_material(s) != null: return false
	if mi.mesh.resource_path.begins_with(DAISY): return true
	var prefab := mi.get_parent()
	var path := prefab.scene_file_path if prefab != null else ""
	if not path.begins_with("res://world/props/rnl/"): return false
	var folder := path.get_base_dir().get_file()
	for kind: String in BATCH_KINDS + BATCH_KINDS_MORE:
		if kind in folder: return true
	return false

## dev 2026-10-20 perf pass: the flagstone foundations under the houses (41), the fitted stair
## approaches (18) and the scenery buildings' foundation boxes and door ramps were ~100 separate
## draws of a few dozen triangles each, all with one of stone_dressing.gd's two shared materials.
## That shader maps the stone in world space from position and normal only, so one mesh per
## material, render setting and STONE_CELL square draws the same pixels in a few draws. Nodes and
## colliders stay (walk_grid_service.gd still reads each foundation's own mesh); only each piece's
## drawing is switched off, as for the batched props. Mirrored or unevenly scaled pieces keep their
## own draw. A merged mesh's draw distance grows by its reach, so no piece goes sooner than before.
## false = off (rollback).
const MERGE_STONE := true
const STONE_CELL := 256.0

func _merge_stone() -> void:
	if not MERGE_STONE or not is_instance_valid(town) or not town.has_meta("stone_dressing"): return
	var dressing: Variant = town.get_meta("stone_dressing")
	if not dressing is Dictionary: return
	var stone_materials: Array = (dressing as Dictionary).values()
	var pieces: Array[MeshInstance3D] = []
	for child: Node in town.get_children():
		if child is MeshInstance3D and str(child.name).begins_with("Foundation_"): pieces.append(child as MeshInstance3D)
	var approaches := town.get_node_or_null("TerrainStairApproaches")
	if approaches != null:
		for node: Node in approaches.find_children("StoneRamp", "MeshInstance3D", true, false): pieces.append(node as MeshInstance3D)
	# Scenery extras (tools/rnl_scenery/build.gd extras): "<id>_foundation" boxes, "<id>_ramp" wedges.
	var scenery := town.get_node_or_null("RNLScenery")
	if scenery != null:
		for node: Node in scenery.find_children("*", "MeshInstance3D", true, false):
			var label := str(node.name)
			if label.ends_with("_foundation") or label.ends_with("_ramp"): pieces.append(node as MeshInstance3D)
	var holder := Node3D.new(); holder.name = "MergedStone"; town.add_child(holder)
	var to_holder := holder.global_transform.affine_inverse()
	var groups := {}
	for mi: MeshInstance3D in pieces:
		if not _stone_mergeable(mi, stone_materials): continue
		var xf: Transform3D = to_holder * mi.global_transform
		if not _uniform(xf.basis): continue
		var surfaces := _stone_surfaces(mi.mesh)
		if surfaces.is_empty(): continue
		var centre := (xf * mi.get_aabb()).get_center()
		var key := [mi.material_override, mi.cast_shadow, mi.layers, mi.gi_mode, mi.visibility_range_end,
			mi.visibility_range_end_margin, mi.visibility_range_fade_mode, floori(centre.x / STONE_CELL), floori(centre.z / STONE_CELL)]
		if not groups.has(key): groups[key] = {"v": PackedVector3Array(), "n": PackedVector3Array(), "i": PackedInt32Array(), "pieces": []}
		_append_stone(groups[key], surfaces, xf)
		(groups[key].pieces as Array).append(mi)
	var merged_pieces := 0
	var meshes := 0
	for key: Array in groups:
		var part: Dictionary = groups[key]
		var list: Array = part.pieces
		if list.size() < 2: continue
		var vertices: PackedVector3Array = part.v
		var bounds := AABB(vertices[0], Vector3.ZERO)
		for p: Vector3 in vertices: bounds = bounds.expand(p)
		var origin := bounds.get_center()
		for k: int in vertices.size(): vertices[k] -= origin
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices; arrays[Mesh.ARRAY_NORMAL] = part.n; arrays[Mesh.ARRAY_INDEX] = part.i
		var mesh := ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var first: MeshInstance3D = list[0]
		var merged := MeshInstance3D.new(); merged.name = "Stone_%d" % meshes
		merged.position = origin
		merged.mesh = mesh
		merged.material_override = first.material_override
		merged.cast_shadow = first.cast_shadow; merged.layers = first.layers; merged.gi_mode = first.gi_mode
		merged.set_meta(BATCHED, true)
		if first.visibility_range_end > 0.0:
			# Ranges are measured from a node's origin: cover every piece's own origin.
			var at := holder.global_transform * origin
			var reach := 0.0
			for mi: MeshInstance3D in list: reach = maxf(reach, mi.global_position.distance_to(at))
			merged.visibility_range_end = first.visibility_range_end + reach
		merged.visibility_range_end_margin = first.visibility_range_end_margin
		merged.visibility_range_fade_mode = first.visibility_range_fade_mode
		holder.add_child(merged)
		for mi: MeshInstance3D in list: mi.visible = false
		merged_pieces += list.size()
		meshes += 1
	statistics["stone_pieces"] = merged_pieces
	statistics["stone_meshes"] = meshes
	print("[render budget] %d stone foundations and ramps drawn as %d meshes" % [merged_pieces, meshes])

func _stone_mergeable(mi: MeshInstance3D, stone_materials: Array) -> bool:
	if mi.mesh == null or mi.skin != null or mi.material_overlay != null or mi.transparency > 0.0: return false
	if not mi.is_visible_in_tree() or mi.visibility_range_begin > 0.0 or mi.has_meta(BATCHED): return false
	return stone_materials.has(mi.material_override)

## Rotation and one positive scale only: then the baked normal is the direction the stone shader
## computes from MODEL_MATRIX * NORMAL, and the triangles keep their facing.
static func _uniform(basis: Basis) -> bool:
	var size := basis.x.length()
	if size <= 0.0 or basis.determinant() <= 0.0: return false
	var tolerance := size * 0.001
	return absf(basis.y.length() - size) < tolerance and absf(basis.z.length() - size) < tolerance \
		and absf(basis.x.dot(basis.y)) < tolerance * size and absf(basis.y.dot(basis.z)) < tolerance * size \
		and absf(basis.z.dot(basis.x)) < tolerance * size

## Each triangle surface's arrays with positions and matching normals, or [] if any surface lacks them.
static func _stone_surfaces(mesh: Mesh) -> Array:
	var out := []
	for s in mesh.get_surface_count():
		if mesh is ArrayMesh and (mesh as ArrayMesh).surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES: return []
		# A primitive's CPU arrays (surface_get_arrays would read each back from the GPU).
		var arrays: Array = (mesh as PrimitiveMesh).get_mesh_arrays() if mesh is PrimitiveMesh else mesh.surface_get_arrays(s)
		if arrays.size() != Mesh.ARRAY_MAX or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array or not arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array: return []
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		if vertices.is_empty() or normals.size() != vertices.size(): return []
		out.append(arrays)
	return out

static func _append_stone(into: Dictionary, surfaces: Array, xf: Transform3D) -> void:
	var v: PackedVector3Array = into.v; var n: PackedVector3Array = into.n; var index: PackedInt32Array = into.i
	for arrays: Array in surfaces:
		var source: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var base := v.size()
		v.append_array(xf * source)
		for q: Vector3 in normals: n.append((xf.basis * q).normalized())
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		if indices is PackedInt32Array and (indices as PackedInt32Array).size() > 0:
			for k: int in (indices as PackedInt32Array): index.append(base + k)
		else:
			for k: int in source.size(): index.append(base + k)
	into.v = v; into.n = n; into.i = index

func _add_house_occluders() -> void:
	for plot in town.get_children():
		if not str(plot.name).begins_with("plot_"): continue
		var exterior := plot.find_child("Exterior", true, false) as MeshInstance3D
		if exterior == null or exterior.mesh == null: continue
		var occluder := _occluder_for(exterior.mesh)
		if occluder == null: continue
		var instance := OccluderInstance3D.new()
		instance.name = "HouseOccluder"
		instance.occluder = occluder
		exterior.add_child(instance)
		statistics.occluders += 1
		statistics.occluder_triangles += occluder.indices.size() / 3
		for home in plot.find_children("*", "", true, false):
			if home.is_in_group("house_interiors"): _by_house[home] = instance

## The exterior's opaque surfaces, each reduced to its coarsest generated LOD that still has at
## least a share of OCCLUDER_TRIANGLES, as one occluder.
static func _occluder_for(mesh: Mesh) -> ArrayOccluder3D:
	if _occluders.has(mesh): return _occluders[mesh]
	var total := 0
	for s in mesh.get_surface_count(): total += maxi(mesh.surface_get_array_index_len(s), mesh.surface_get_array_len(s)) / 3
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	for s in mesh.get_surface_count():
		var material := mesh.surface_get_material(s)
		if material is BaseMaterial3D and (material as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			continue
		var arrays := mesh.surface_get_arrays(s)
		var source: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var source_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(source.size()))
		var target := maxi(OCCLUDER_TRIANGLES * source_indices.size() / 3 / maxi(total, 1), 12)
		var chosen := source_indices
		var slim := []
		slim.resize(Mesh.ARRAY_MAX)
		slim[Mesh.ARRAY_VERTEX] = source
		if arrays[Mesh.ARRAY_NORMAL] != null: slim[Mesh.ARRAY_NORMAL] = arrays[Mesh.ARRAY_NORMAL]
		slim[Mesh.ARRAY_INDEX] = source_indices
		var importer := ImporterMesh.new()
		importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, slim)
		importer.generate_lods(60.0, 25.0, [])
		for lod in importer.get_surface_lod_count(0):
			var candidate := importer.get_surface_lod_indices(0, lod)
			chosen = candidate
			if candidate.size() / 3 <= target: break
		var base := vertices.size()
		vertices.append_array(source)
		for i in chosen: indices.append(i + base)
	if indices.is_empty():
		_occluders[mesh] = null
		return null
	var occluder := ArrayOccluder3D.new()
	occluder.set_arrays(vertices, indices)
	_occluders[mesh] = occluder
	return occluder

## A shut door sits in its wall, whose shadow already covers it outside; its own shadow only shows
## as the lit door shape on the floor inside. So doors cast only for the house the camera is in.
func _collect_doors() -> void:
	for plot in town.get_children():
		if not str(plot.name).begins_with("plot_"): continue
		var home: Node = null
		for node in plot.find_children("*", "", true, false):
			if node.is_in_group("house_interiors"): home = node; break
		if home == null: continue
		var parts := []
		for door in plot.find_children("*", "AnimatableBody3D", true, false):
			var script: Script = door.get_script()
			if script == null or not script.resource_path.contains("door"): continue
			for mesh in door.find_children("*", "GeometryInstance3D", true, false):
				var gi := mesh as GeometryInstance3D
				if gi.cast_shadow in [GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY]: continue
				parts.append([gi, gi.cast_shadow])
				gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if not parts.is_empty(): _doors[home] = parts

func _set_door_shadows(home: Node, on: bool) -> void:
	for part: Array in _doors.get(home, []):
		if is_instance_valid(part[0]):
			(part[0] as GeometryInstance3D).cast_shadow = part[1] if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _process(delta: float) -> void:
	_poll_lods()
	_poll_mesh_lods()
	_tick -= delta
	if _tick > 0.0: return
	_tick = 0.25
	var camera := preload("res://world/player_view.gd").camera(self)
	if camera == null: return
	var home := HOUSE.at(get_tree(), camera.global_position)
	if home != _door_home:
		_set_door_shadows(_door_home, false)
		_set_door_shadows(home, true)
		_door_home = home
	var inside: OccluderInstance3D = _by_house.get(home)
	if inside == _hidden: return
	if is_instance_valid(_hidden): _hidden.visible = true
	_hidden = inside
	if is_instance_valid(_hidden): _hidden.visible = false
