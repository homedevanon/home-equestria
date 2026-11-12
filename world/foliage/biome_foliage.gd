class_name BiomeFoliage
extends Node3D
## Stream authored vegetation in 32 m cells. Existing traversal props stay native.
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const VEGETATION_SCALE := preload("res://world/foliage/vegetation_scale.gd")
const GRASSY := preload("res://world/foliage/grassy_catalogue.gd")
const EVERFREE := preload("res://world/foliage/everfree_catalogue.gd")
const IMPOSTORS := preload("res://world/foliage/foliage_impostors.gd")
const CELL := 32.0
const PLANT_RANGE := 160.0
const TREE_RANGE := 900.0
const MAX_CANDIDATES_PER_CELL := 84
var field: WorldBiomeField
var terrain: WorldTerrain
var _catalog: Array = []
var _assets: Dictionary = {}
var _asset_levels: Dictionary = {}
var _cells: Dictionary = {}
var _pending: Array[Vector2i] = []
var _native: Dictionary = {}
var _timer := 0.0
var _indexing: Dictionary = {}
var _generation := 0
var _leaves: GPUParticles3D
var _nav_dirty := false
var _physics_points: Array[Vector2] = []
var _queued: Dictionary = {}
var _paint_cells: Dictionary = {}
var _schedule_signature: Array = []
var _tree_batches: Node3D
var _camera_position := Vector2.ZERO
## Cells whose holder may have physics active; every active holder is in here.
var _physics_cells: Dictionary = {}
## Painted cells of the current edited tiles, and those of them not built. Keyed on
## _painted_key (field revision, edited tile names).
var _painted: Dictionary = {}
var _unbuilt: Dictionary = {}
var _painted_key: Array = []
## Every built cell corner lies within _reach_extent of _reach_centre (-1: unknown).
var _reach_centre := Vector2.ZERO
var _reach_extent := -1.0
var _density_scale := 1.0
## Foliage work per frame: cell builds get FILL_BUDGET_USEC (the next cell waits for the next frame
## when its predicted cost would pass it), their tree batches the rest of FRAME_BUDGET_USEC.
const FILL_BUDGET_USEC := 2000
const FRAME_BUDGET_USEC := 2500
## Moving average of one cell's build time, for that prediction.
var _cell_usec := 800.0
## dev 2026-10-20 multithreading: the pure slot tests of each cell build (positions, biome pixels and
## weights, preset roll, thinning, tree spacing) run in C++ (PonyFoliageFill, native/pony_solver)
## on the WorkerThreadPool, a batch of the next pending cells kicked after the fill and collected next
## frame; the main thread keeps the terrain/physics tests of the survivors and all node work. Same
## instances in the same order as _build_cell (tools/foliage/test_native_fill_equivalence.gd).
## Rollback/A-B: false (or --native-foliage-fill-off) builds every cell with the GDScript _build_cell.
const NATIVE_FILL := true
## Cells per worker batch; the pool spreads them over its threads (processor count by default).
const NATIVE_FILL_BATCH := 96
const FIELD_SCRIPT := preload("res://world/biomes/biome_field.gd")
var _fill: Object = null
var _fill_on := false
## Field tiles snapshotted into _fill, for _fill_revision: loc -> [tile dictionary, accepted].
var _fill_tiles: Dictionary = {}
var _fill_revision := -1
## Worker results by cell, and the field revision of the batch in flight. Ownership: the pool's
## threads only ever touch PonyFoliageFill's own copy of the inputs; these are main-thread only.
var _prefilled: Dictionary = {}
var _fill_batch_revision := -1
## Candidate positions and spacing priorities of a cell's slots: pure functions of the cell,
## shared by its own build and its neighbours' spacing checks. [PackedVector2Array, PackedFloat64Array]
var _slots: Dictionary = {}
const SLOT_CACHE_CELLS := 4096
## Per preset: [vegetation family, tree slots, plant slots, tree spacing]; and the distinct
## [tree slots, plant slots] of presets that grow trees (field.presets is fixed after load).
var _preset_rows: Array = []
var _tree_rules: Array[Vector2i] = []
## Catalogue choices per family and tree/plant (_catalog is fixed after _ready).
var _choices: Dictionary = {}
## Painted cells per edited tile hold while the field revision does (coverage changes bump it).
var _paint_cells_revision := -1
## Pending navigation boxes; touching ones merge, far-apart ones stay separate.
var _nav_boxes: Array[AABB] = []
const NAV_MERGE_GAP := 16.0
const NAV_MAX_BOXES := 24
## Highest tree slot of any tree-growing preset at density <= 1 (slots at or past it are never trees there).
var _tree_slot_limit := 0
## Near-window cells (13x13 around the camera cell) not yet holding plants, for window key
## [camera cell, _generation]; full-built cells stay built until a discard bumps _generation.
var _window_key: Array = []
var _window_open: Array[Vector2i] = []
## Every painted cell of _unbuilt was built or queued at the last pass with this key
## [reach, _generation, _painted_epoch]; camera movement alone then cannot enqueue anything.
var _unbuilt_settled := false
var _unbuilt_key: Array = []
var _painted_epoch := 0
## Trees-only holders taken down for plants, keyed by cell: their tree colliders and trunk flag,
## with the _generation/_density_scale they were built under. The cell's tree batch is left in
## place, so the plant build adds plants without rebuilding identical trees (and their far tile).
var _promote: Dictionary = {}


func _on_setting_changed(key: String) -> void:
	if key == "video/foliage_density": _density_scale = get_node("/root/Settings").foliage_density()


func _ready() -> void:
	add_to_group("bird_habitats")
	var settings := get_node_or_null("/root/Settings")
	if settings != null:
		_density_scale = settings.foliage_density()
		settings.changed.connect(_on_setting_changed)
	terrain = get_parent() as WorldTerrain; field = terrain.biomes
	_catalog = WorldBiomeField.read_json("res://world/foliage/catalogue.json").get("assets", [])
	var approved := GRASSY.woodland_entries()
	if not approved.is_empty() and "--grassy-trees-off" not in preload("res://world/dev_tools.gd").user_args():
		_catalog = _catalog.filter(func(row): return row.family != "woodland")
		_catalog.append_array(approved)
	_catalog = _catalog.filter(func(row): return row.family != "everfree")
	_catalog.append_array(EVERFREE.entries())
	# The native fill replicates WorldBiomeField's own sampling; subclasses (test fakes) keep GDScript.
	_fill_on = NATIVE_FILL and "--native-foliage-fill-off" not in preload("res://world/dev_tools.gd").user_args() \
		and ClassDB.class_exists("PonyFoliageFill") and field.get_script() == FIELD_SCRIPT
	if _fill_on: _fill = ClassDB.instantiate("PonyFoliageFill")
	_choices.clear(); _cache_presets()
	field.changed.connect(_changed)
	terrain.regions_loaded.connect(_regions_loaded)
	var sculptor := terrain.get_node_or_null("TerrainSculptor")
	if sculptor!=null and sculptor.has_signal("height_changed"):
		sculptor.height_changed.connect(_terrain_height_changed)
	var manager := get_node_or_null("/root/ZoneManager")
	if manager != null:
		manager.zone_loaded.connect(_index_zone)
		manager.zone_unloaded.connect(_prune_native)
		for id in manager.loaded_ids(): _index_zone(id)
	_tree_batches=preload("res://world/foliage/painted_tree_batches.gd").new()
	_tree_batches.asset_parts=_asset;_tree_batches.asset_lods=_tree_lods;_tree_batches.native=_fill;add_child(_tree_batches)
	_tree_batches.streaming=func()->bool:return is_processing() and not _pending.is_empty()
	_build_leaves()


func _prune_native(id: String) -> void:
	# Cancel the suspended indexer immediately. Deferred zone freeing can otherwise
	# leave its work stack holding already-freed nodes, or erase a newer index job.
	_indexing.erase(id)
	for cell in _native.keys():
		_native[cell] = _native[cell].filter(func(rec): return rec.get("zone", "") != id and is_instance_valid(rec.node))
		if _native[cell].is_empty(): _native.erase(cell)


func _cell(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / CELL), floori(pos.y / CELL))


func _index_zone(id: String) -> void:
	if _indexing.has(id): return
	var manager := get_node_or_null("/root/ZoneManager")
	if manager == null: return
	var root: Node = manager._loaded.get(id)
	if root == null: return
	var token: int = root.get_instance_id()
	_indexing[id] = token
	var family: String = str(WorldLayout.region_of_zone(id).get("biome", "forest"))
	family = "everfree" if family == "dark_forest" else ("desert" if family == "desert" else "woodland")
	var stack: Array = [root]; var clock := Time.get_ticks_usec()
	while not stack.is_empty() and is_instance_valid(root) and _indexing.get(id) == token:
		var candidate_node: Variant = stack.pop_back()
		if not is_instance_valid(candidate_node): continue
		var node: Node = candidate_node
		var name := String(node.name).to_lower()
		var pine := name.begins_with("ck_sprucetree0")
		var broadleaf := name.begins_with("deciduoustree") and not name.contains("seasonal")
		var approved_tree := node.has_meta(&"grassy_tree_variant")
		var candidate := approved_tree or (not name.contains("lod") and (pine or broadleaf or (not name.contains("_") and (name.begins_with("everfreetree0") or name.begins_with("tree0") or name.begins_with("everfreebush") or name.begins_with("fern") or name.begins_with("bush06") or name.begins_with("bush07") or name.begins_with("brambles") or name.begins_with("cactus")))))
		if candidate and node is Node3D:
			var pos: Vector3 = node.global_position; var cell := _cell(Vector2(pos.x, pos.z))
			var bodies: Array = []
			for body in node.find_children("*", "StaticBody3D", true, false): bodies.append([body, body.collision_layer])
			var bounds := AABB(pos, Vector3.ZERO)
			var meshes: Array = node.find_children("*", "MeshInstance3D", true, false)
			if node is MeshInstance3D: meshes.append(node)
			for mesh: MeshInstance3D in meshes:
				if mesh.mesh != null: bounds = bounds.merge(mesh.global_transform * mesh.get_aabb())
			var tree := approved_tree or pine or broadleaf or name.begins_with("everfreetree0") or name.begins_with("tree0")
			var rec := {"node": node, "zone": id, "pos": pos, "bodies": bodies, "bounds": bounds.grow(0.5), "family": "woodland" if approved_tree else family, "pine": pine, "approved_tree": approved_tree, "visible": node.visible, "bird_tree": tree}
			if not _native.has(cell): _native[cell] = []
			_native[cell].append(rec); _native_visibility(rec)
		else:
			for child in node.get_children(): stack.append(child)
		if Time.get_ticks_usec() - clock > 2000:
			if not await SHUTDOWN.frame(self): return
			clock = Time.get_ticks_usec()
	if _indexing.get(id) != token: return
	_indexing.erase(id)
	# Generated candidates made before this zone arrived must respect its native plants.
	# Visibility was already applied per plant in the sliced loop above. Only
	# invalidate generated cells here; a second whole-zone visibility pass stalls.
	_changed(WorldLayout.footprint(WorldLayout.region_of_zone(id)), field.revision, false)


## Actual loaded canopy locations, using the existing 32 m vegetation index.
## Owners let an active call stop when its tree is erased, hidden or unloaded.
## Crowns for seasonal effects (world/seasons/tree_query.gd, W2-SEAS-E hook 1): position, crown
## radius, kind (tree_query.gd BROADLEAF 0, EVERGREEN 1, BLOSSOM 2; its kind_of_name would read the
## word "evergreen" as broadleaf). Painted batch sakura trees then shed spring
## petals and every crown has its real radius. Called on a 10 m camera move, not per frame.
func tree_canopies(origin: Vector3, radius: float) -> Array:
	var result: Array = []
	var low := _cell(Vector2(origin.x, origin.z) - Vector2.ONE * radius)
	var high := _cell(Vector2(origin.x, origin.z) + Vector2.ONE * radius)
	for x in range(low.x, high.x + 1):
		for z in range(low.y, high.y + 1):
			var cell := Vector2i(x, z)
			for rec: Dictionary in _native.get(cell, []):
				if not rec.get("bird_tree", false) or not is_instance_valid(rec.node) or not rec.node.is_visible_in_tree(): continue
				var box: AABB = rec.bounds
				if box.size.y < 3.0: continue
				var crown := box.position + box.size * Vector3(.5, .72, .5)
				if origin.distance_to(crown) > radius: continue
				var variant := str(rec.node.get_meta(&"grassy_tree_variant", "")) if rec.node.has_meta(&"grassy_tree_variant") else ""
				var kind := 1 if bool(rec.get("pine", false)) else (2 if variant.contains("sakura") else 0)
				var record := {"position": crown, "radius": clampf(minf(box.size.x, box.size.z) * 0.35, 1.0, 6.0), "kind": kind}
				# Where the tree stands, so the seasons' script side (leaf carpet, petals) finds the
				# same per-tree numbers as the leaf shaders (world/seasons/tree_query.gd autumn_tree).
				if rec.node is Node3D: record["root"] = (rec.node as Node3D).global_position
				result.append(record)
			if not is_instance_valid(_tree_batches): continue
			var batch: Dictionary = _tree_batches.batches.get(_tree_batches._key(cell), {})
			var owner: Variant = batch.get("node")
			if not is_instance_valid(owner) or not owner.is_visible_in_tree(): continue
			for group: Dictionary in (batch.cells.get(cell, {}) as Dictionary).values():
				var entry: Dictionary = group.entry
				if entry.category != "tree" or float(entry.height) < 3.0: continue
				var id := str(entry.get("id", ""))
				var kind := 2 if id.contains("sakura") else (1 if id.contains("pine") or id.contains("spruce") else 0)
				var canopy := GRASSY.collar_offset(entry) + Vector3.UP * (float(entry.height) - GRASSY.support_y(entry)) * .72
				for placement: Transform3D in group.transforms:
					var crown := Vector3(cell.x * CELL, 0, cell.y * CELL) + placement * canopy
					if origin.distance_to(crown) <= radius:
						result.append({"position": crown, "radius": clampf(float(entry.get("radius", 4.0)) * 0.4 * placement.basis.get_scale().x, 1.0, 6.0), "kind": kind,
							"root": Vector3(cell.x * CELL, 0, cell.y * CELL) + placement.origin})
	return result

func bird_perches(origin: Vector3, near_distance := 25.0, far_distance := 70.0) -> Array:
	var result: Array = []
	var low := _cell(Vector2(origin.x, origin.z) - Vector2.ONE * far_distance)
	var high := _cell(Vector2(origin.x, origin.z) + Vector2.ONE * far_distance)
	for x in range(low.x, high.x + 1):
		for z in range(low.y, high.y + 1):
			var cell := Vector2i(x, z)
			for rec: Dictionary in _native.get(cell, []):
				if not rec.get("bird_tree", false) or not is_instance_valid(rec.node) or not rec.node.is_visible_in_tree(): continue
				var box: AABB = rec.bounds
				if box.size.y < 3.0: continue
				var perch := box.position + box.size * Vector3(.5, .72, .5)
				var distance := origin.distance_to(perch)
				if distance >= near_distance and distance <= far_distance:
					result.append({"position": perch, "owner": rec.node})
			if not is_instance_valid(_tree_batches): continue
			var batch: Dictionary = _tree_batches.batches.get(_tree_batches._key(cell), {})
			var owner: Variant = batch.get("node")
			if not is_instance_valid(owner) or not owner.is_visible_in_tree(): continue
			var groups: Dictionary = batch.cells.get(cell, {})
			for group: Dictionary in groups.values():
				var entry: Dictionary = group.entry
				if entry.category != "tree" or float(entry.height) < 3.0: continue
				var canopy := GRASSY.collar_offset(entry) + Vector3.UP * (float(entry.height) - GRASSY.support_y(entry)) * .72
				for placement: Transform3D in group.transforms:
					var perch := Vector3(cell.x * CELL, 0, cell.y * CELL) + placement * canopy
					var distance := origin.distance_to(perch)
					if distance >= near_distance and distance <= far_distance:
						result.append({"position": perch, "owner": owner})
	return result


func _native_visibility(rec: Dictionary) -> void:
	if not is_instance_valid(rec.node): return
	var pos := Vector2(rec.pos.x, rec.pos.z); var loc := WorldBiomeField.location(pos)
	var data := field.tile(loc); var pixel := Vector2i((pos - Vector2(loc * 1024)) / 4)
	pixel = pixel.clamp(Vector2i.ZERO, Vector2i(255, 255))
	var visible: bool = rec.visible
	if data.coverage.get_pixelv(pixel).r > 0:
		var w := field.sample_weights(pos); var same := 0.0
		var override := WorldBiomeField.vegetation_biome(data, pixel)
		var family_weights: Array = [override] if override >= 0 else range(w.size())
		for i in family_weights:
			# Authored Normal forest replaces other tree families with pines. Native
			# vegetation outside painted coverage retains its original appearance.
			if i == 2 and not rec.get("pine", false) and not rec.get("approved_tree", false): continue
			if field.presets[i].vegetation == rec.family: same += 1.0 if override >= 0 else w[i]
		visible = visible and _random(pos, 91) < same * data.density.get_pixelv(pixel).r
	elif rec.family == "everfree":
		# An inward, irregular edge preserves the existing forest footprint.
		var forest := WorldLayout.footprint(WorldLayout.region("everfree"))
		if forest.has_point(pos):
			var edge := minf(minf(pos.x - forest.position.x, forest.end.x - pos.x), minf(pos.y - forest.position.y, forest.end.y - pos.y))
			var width := 100.0 + 45.0 * sin(pos.x * 0.019 + sin(pos.y * 0.013) * 2)
			visible = visible and _random(pos, 93) < smoothstep(0.0, width, edge)
	if rec.node.visible == visible: return
	rec.node.visible = visible
	for body in rec.bodies:
		if is_instance_valid(body[0]): body[0].collision_layer = int(body[1]) if visible else 0
	# Ask the live grid to resample this small area; leave all reach/slope rules alone.
	_invalidate(rec.bounds, StringName("biome_native_%d" % rec.node.get_instance_id()))


func _invalidate(box: AABB, _id: StringName) -> void:
	# One union of far-apart changes (trunk cells toggling on both sides of a pony) would
	# make the walk grid resample every chunk between them; keep separate areas separate.
	_nav_dirty = true
	for i in _nav_boxes.size():
		if _nav_boxes[i].grow(NAV_MERGE_GAP).intersects(box):
			_nav_boxes[i] = _nav_boxes[i].merge(box); return
	if _nav_boxes.size() < NAV_MAX_BOXES:
		_nav_boxes.append(box); return
	# Many scattered changes at once (zone indexing): the single union, as before.
	var union := box
	for other in _nav_boxes: union = union.merge(other)
	_nav_boxes.assign([union])


func _flush_navigation() -> void:
	# Regional residents (including Everfree) own services outside ZoneManager.
	# Every live walk-grid registers here; each service filters changes to its bounds.
	for service: Node in get_tree().get_nodes_in_group("pony_navigation"):
		if not service.is_queued_for_deletion() and service.has_method("notify_geometry_changed"):
			for box in _nav_boxes: service.notify_geometry_changed(box)
	_nav_boxes.clear(); _nav_dirty = false


func _changed(bounds: Rect2, _revision: int, recheck_native := true) -> void:
	_rebuild_generated(bounds,CELL)
	if recheck_native:
		var grown := bounds.grow(CELL)
		for cell in _native:
			if not grown.intersects(Rect2(Vector2(cell) * CELL, Vector2.ONE * CELL)): continue
			for rec in _native[cell]: _native_visibility(rec)


func _terrain_height_changed(bounds: AABB) -> void:
	# Generated instances derive their Y from Terrain3D and must be rebuilt after
	# sculpting. Imported plants retain native support decisions: blindly moving
	# them would detach trees grounded on zone meshes, bridges, or stacked floors.
	if not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size.x<=0.0 or bounds.size.z<=0.0: return
	_rebuild_generated(Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z)),0.0)


func _regions_loaded(locations: Array) -> void:
	# A windowed terrain can be absent when a cell first builds. Retry those
	# holders with the same one-cell margin, once for the whole arrival batch.
	if locations.is_empty() or _cells.is_empty(): return
	# A queued promotion keeps trees sampled before this terrain arrived; rebuild it whole.
	_promote.clear()
	var affected := {}; var seen := {}
	var span := int(WorldBiomeField.REGION / CELL)
	for location: Vector2i in locations:
		if seen.has(location): continue
		seen[location] = true
		var origin := location * span
		for y in range(origin.y - 1, origin.y + span + 1):
			for x in range(origin.x - 1, origin.x + span + 1):
				var cell := Vector2i(x, y)
				if _cells.has(cell): affected[cell] = true
	if not affected.is_empty(): _discard_generated(affected.keys(), true)


func native_support_changed(bounds: AABB) -> void:
	# NativePlantSupport has already made its bounded correction. Refresh only
	# cached vegetation records whose old or new geometry intersects that union;
	# vertical corrections normally remain in the same XZ cell.
	if not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size == Vector3.ZERO: return
	var xz := Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z)).grow(CELL)
	var lo := _cell(xz.position)
	var hi := _cell(xz.end)
	var affected := Rect2()
	var has_affected := false
	var candidate_cells: Array[Vector2i] = []
	for z in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			var candidate := Vector2i(x, z)
			if _native.has(candidate): candidate_cells.append(candidate)
	for old_cell in candidate_cells:
		for rec: Dictionary in (_native[old_cell] as Array).duplicate():
			var node := rec.get("node") as Node3D
			if not is_instance_valid(node): continue
			var old_bounds: AABB = rec.get("bounds", AABB())
			var old_pos: Vector3 = rec.get("pos", node.global_position)
			var new_pos: Vector3 = node.global_position
			var translated := AABB(old_bounds.position + new_pos - old_pos, old_bounds.size)
			if not old_bounds.intersects(bounds) and not translated.intersects(bounds): continue
			rec.pos = new_pos; rec.bounds = translated
			var new_cell := _cell(Vector2(new_pos.x, new_pos.z))
			if new_cell != old_cell:
				(_native[old_cell] as Array).erase(rec)
				if not _native.has(new_cell): _native[new_cell] = []
				(_native[new_cell] as Array).append(rec)
			var old_xz := Rect2(Vector2(old_bounds.position.x, old_bounds.position.z), Vector2(old_bounds.size.x, old_bounds.size.z))
			var rec_xz := old_xz.merge(Rect2(Vector2(translated.position.x, translated.position.z), Vector2(translated.size.x, translated.size.z)))
			affected = rec_xz if not has_affected else affected.merge(rec_xz); has_affected = true
		if (_native[old_cell] as Array).is_empty(): _native.erase(old_cell)
	if has_affected: _rebuild_generated(affected, CELL)


func _rebuild_generated(bounds: Rect2, margin: float) -> void:
	var grown := bounds.grow(margin)
	var affected: Array[Vector2i] = []
	for cell: Vector2i in _cells:
		if grown.intersects(Rect2(Vector2(cell) * CELL, Vector2.ONE * CELL)): affected.append(cell)
	_discard_generated(affected)


func _discard_generated(cells: Array, preserve_pending := false) -> void:
	_generation += 1
	_promote.clear()
	# Painted cells depend on the field alone (_painted_cells follows its revision); removed
	# painted cells go back to the unbuilt set instead of rescanning every edited tile.
	_schedule_signature.clear()
	for cell: Vector2i in cells:
		var old: Node = _cells[cell]
		if old.get_meta("physics_active",false): _invalidate(AABB(Vector3(cell.x * CELL, -500, cell.y * CELL), Vector3(CELL, 2000, CELL)), &"")
		old.queue_free(); _cells.erase(cell)
		if _painted.has(cell): _unbuilt[cell] = true
		if _tree_batches != null: _tree_batches.erase(cell)
	# Region arrivals do not change the biome field. Queued cells sample the now
	# resident terrain when built, so retain their work and existing tie order.
	if not preserve_pending: _pending.clear(); _queued.clear()
	_timer = 0


func _process(delta: float) -> void:
	var profiling := preload("res://tools/crowd_cpu_profile.gd")
	if not profiling.enabled:
		_profiled_process(delta)
		return
	var started := Time.get_ticks_usec()
	_profiled_process(delta)
	profiling.record("biome_foliage", started)
	_probe_frame(Time.get_ticks_usec() - started)


## Opt-in diagnostics while the CPU timers run: one line every 2 s with where the time went.
var _probe := {}
var _probe_sched := 0
var _probe_fill := 0
var _probe_flush := 0
var _probe_built := 0
func _probe_frame(total: int) -> void:
	if _probe.is_empty(): _probe = {"at": Time.get_ticks_msec(), "frames": 0, "total": 0, "max": 0, "sched": 0, "sched_max": 0, "fill": 0, "flush": 0, "flush_max": 0, "built": 0}
	_probe.frames += 1; _probe.total += total; _probe.max = maxi(_probe.max, total)
	_probe.sched += _probe_sched; _probe.sched_max = maxi(_probe.sched_max, _probe_sched)
	_probe.fill += _probe_fill; _probe.flush += _probe_flush; _probe.flush_max = maxi(_probe.flush_max, _probe_flush)
	_probe.built += _probe_built
	if Time.get_ticks_msec() - int(_probe.at) < 2000: return
	var n := float(_probe.frames)
	print("[foliage-probe] frames=%d avg_us=%d max_us=%d sched_us/f=%d sched_max=%d fill_us/f=%d built=%d flush_us/f=%d flush_max=%d cells=%d pending=%d unbuilt=%d physics_cells=%d points=%d dirty=%d far_dirty=%d cell_usec=%d" % [
		_probe.frames, _probe.total / n, _probe.max, _probe.sched / n, _probe.sched_max, _probe.fill / n, _probe.built,
		_probe.flush / n, _probe.flush_max, _cells.size(), _pending.size(), _unbuilt.size(), _physics_cells.size(), _physics_points.size(),
		_tree_batches.dirty.size(), _tree_batches.far_dirty.size(), _cell_usec])
	_probe = {}


func _profiled_process(delta: float) -> void:
	var camera := preload("res://world/player_view.gd").camera(self)
	if camera == null or _catalog.is_empty(): return
	_timer -= delta
	var sched_started := Time.get_ticks_usec(); _probe_sched = 0
	if _timer <= 0:
		_timer = 0.5
		if _nav_dirty: _flush_navigation()
		var centre := Vector2(camera.global_position.x, camera.global_position.z)
		_physics_points.assign([centre])
		for pony in get_tree().get_nodes_in_group(PonyCrowd.MEMBERS):
			if pony.sim_tier < 2: _physics_points.append(Vector2(pony.global_position.x, pony.global_position.z))
		_camera_position=centre
		var at := _cell(centre)
		var reach:=maxf(TREE_RANGE,camera.far)
		# No built cell can be out of reach unless the reach shrank or the camera travelled past the bound (.01 m float slack).
		if _reach_extent<0.0 or _reach_extent+_reach_centre.distance_to(centre)+.01>reach+CELL*8:
			var extent:=0.0
			for cell: Vector2i in _cells.keys():
				var distance:=(Vector2(cell)*CELL-centre).length()
				if distance>reach+CELL*8:
					_tree_batches.erase(cell);_cells[cell].queue_free();_cells.erase(cell)
					if _painted.has(cell):
						_unbuilt[cell]=true;_unbuilt_settled=false
				else:extent=maxf(extent,distance)
			_reach_centre=centre;_reach_extent=extent
		# Close groundcover is disposable; trees have persistent shared batches.
		# Cells already holding plants stay so until a discard bumps _generation, so only the
		# rest of the window is revisited while the camera stays in its cell.
		if _window_key!=[at,_generation]:
			_window_key=[at,_generation];_window_open.clear()
			for y in range(at.y-6,at.y+7):
				for x in range(at.x-6,at.x+7):_window_open.append(Vector2i(x,y))
		var still_open: Array[Vector2i]=[]
		for cell: Vector2i in _window_open:
			if _cells.has(cell):
				var holder: Node=_cells[cell]
				if not holder.get_meta("trees_only",false):continue
				# Square corners can remain outside _build_cell's plant radius.
				if (Vector2(cell)*CELL-centre).length()>CELL*9:still_open.append(cell);continue
				_promote[cell]={"generation":_generation,"density":_density_scale,
					"colliders":holder.get_meta("tree_colliders",[]),"trunks":holder.get_meta("trunks",false)}
				holder.queue_free();_cells.erase(cell)
				if _painted.has(cell):_unbuilt[cell]=true
			_enqueue(cell);still_open.append(cell)
		_window_open=still_open
		var signature:=[at,reach,field.revision,_generation]
		if signature!=_schedule_signature:
			_schedule_signature=signature
			var edited: Array=field._published.keys()+(field._working.keys() if field.working else [])
			for loc in field._dirty:edited.append(WorldBiomeField.key(loc))
			var painted_key:=[field.revision,edited]
			if painted_key!=_painted_key:
				_painted_key=painted_key;_painted.clear()
				var seen:={}
				for name: String in edited:
					if seen.has(name):continue
					seen[name]=true
					for cell: Vector2i in _painted_cells(name):_painted[cell]=true
				_unbuilt=_painted.duplicate();_painted_epoch+=1
			# Built cells leave the set; removals above put them back. Once every one was built
			# or queued under this reach/generation/paint, camera movement alone adds nothing.
			var unbuilt_key:=[reach,_generation,_painted_epoch]
			if not _unbuilt_settled or unbuilt_key!=_unbuilt_key:
				var settled:=true
				for cell: Vector2i in _unbuilt.keys():
					if _cells.has(cell):_unbuilt.erase(cell)
					elif (Vector2(cell)*CELL-centre).length()<=reach+CELL*2:_enqueue(cell)
					else:settled=false
				_unbuilt_settled=settled;_unbuilt_key=unbuilt_key
			_pending=_nearest_first(_pending,at)

		var w := field.sample_weights(centre)
		_leaves.emitting = w[3] > 0.4 and camera.global_position.y - terrain.height_at(camera.global_position) < 30
		_leaves.global_position = camera.global_position + Vector3(0, 10, 0)
		# Only nearby trunks create physics nodes. Far batches retain visual trees.
		# A cell corner within 96 m of a point lies within 3 cells of the point's cell.
		var near_cells:={}
		for point in _physics_points:
			var home:=_cell(point)
			for y in range(home.y-3,home.y+4):
				for x in range(home.x-3,home.x+4):
					var cell:=Vector2i(x,y)
					if _cells.has(cell) and point.distance_squared_to(Vector2(cell)*CELL)<96*96:near_cells[cell]=true
		for cell: Vector2i in _physics_cells:
			if not near_cells.has(cell) and _cells.has(cell):_sync_physics(_cells[cell],false)
		for cell: Vector2i in near_cells:_sync_physics(_cells[cell],true)
		_physics_cells=near_cells
		_probe_sched = Time.get_ticks_usec() - sched_started
	# Bounded initial fill, with nearby cells first. Empty or sparse distant cells
	# need not consume a whole rendered frame each.
	# The next cell waits for the next frame when its predicted cost would pass the budget; the
	# count cap only matters for empty cells.
	var started:=Time.get_ticks_usec();var built:=0
	if _fill_on:_collect_fill()
	while not _pending.is_empty() and built<8:
		if built>0 and Time.get_ticks_usec()-started+_cell_usec>FILL_BUDGET_USEC:break
		var cell: Vector2i=_pending.pop_front();_queued.erase(cell)
		var before:=Time.get_ticks_usec()
		if _fill_on:_build_cell_native(cell,_prefilled.get(cell,{}))
		else:_build_cell(cell)
		built+=1
		_cell_usec=lerpf(_cell_usec,float(Time.get_ticks_usec()-before),.25)
	# Workers fill the next cells while this frame renders; collected at the next fill.
	if _fill_on:_kick_fill()
	var flush_started := Time.get_ticks_usec(); _probe_fill = flush_started - started; _probe_built = built
	# Detail batches keep pace with the cells built, so their far tiles are not rebuilt over a backlog.
	_tree_batches.flush_one(maxi(1,built),maxi(0,FRAME_BUDGET_USEC-(Time.get_ticks_usec()-started)))
	_probe_flush = Time.get_ticks_usec() - flush_started

func _enqueue(cell: Vector2i) -> void:
	if not _cells.has(cell) and not _queued.has(cell):_queued[cell]=true;_pending.append(cell)

## Nearest first, as the old sort_custom(length_squared) did, in one native sort: squared cell
## distance in the high bits, list index in the low bits (ties keep list order).
static func _nearest_first(cells: Array[Vector2i],at: Vector2i) -> Array[Vector2i]:
	if cells.size()>=1<<20:
		cells.sort_custom(func(a,b):return Vector2(a-at).length_squared()<Vector2(b-at).length_squared());return cells
	var keys:=PackedInt64Array();keys.resize(cells.size())
	for i in cells.size():
		var d:=cells[i]-at;keys[i]=((d.x*d.x+d.y*d.y)<<20)|i
	keys.sort()
	var sorted: Array[Vector2i]=[];sorted.resize(cells.size())
	for i in keys.size():sorted[i]=cells[keys[i]&0xFFFFF]
	return sorted

func _painted_cells(name: String) -> Array:
	if _paint_cells_revision!=field.revision:_paint_cells.clear();_paint_cells_revision=field.revision
	if _paint_cells.has(name):return _paint_cells[name]
	var parts:=name.split("_");var loc:=Vector2i(int(parts[0]),int(parts[1]))
	var data:=field.tile(loc);var coverage: Image=data.coverage
	var found:={}
	var used:=coverage.get_used_rect()
	var width:=coverage.get_width();var height:=coverage.get_height()
	# Any painted pixel qualifies its cell; centre-only sampling misses narrow strokes.
	if coverage.get_format()==Image.FORMAT_L8 and width%8==0 and height%8==0:
		# One byte per pixel: a block row is one u64 (nonzero = painted), a zero 8-row band skips 32 blocks.
		var bytes:=coverage.get_data()
		for cz in range(used.position.y/8,ceili(used.end.y/8.0)):
			if bytes.slice(cz*8*width,(cz*8+8)*width).count(0)==8*width:continue
			for cx in range(used.position.x/8,ceili(used.end.x/8.0)):
				for z in range(cz*8,cz*8+8):
					if bytes.decode_u64(z*width+cx*8)!=0:found[loc*32+Vector2i(cx,cz)]=true;break
		_paint_cells[name]=found.keys();return _paint_cells[name]
	for cz in range(used.position.y/8,ceili(used.end.y/8.0)):
		for cx in range(used.position.x/8,ceili(used.end.x/8.0)):
			var painted:=false
			for z in range(cz*8,mini(cz*8+8,height)):
				for x in range(cx*8,mini(cx*8+8,width)):
					if coverage.get_pixel(x,z).r>0:painted=true;break
				if painted:break
			if painted:found[loc*32+Vector2i(cx,cz)]=true
	_paint_cells[name]=found.keys();return _paint_cells[name]

func _sync_physics(holder: Node3D, near: bool) -> void:
	if holder.get_meta("physics_active",false)==near:return
	holder.set_meta("physics_active",near)
	if not holder.get_meta("tree_colliders",[]).is_empty():
		_invalidate(AABB(holder.global_position-Vector3(0,500,0),Vector3(CELL,2000,CELL)),&"")
	if not near:
		for child in holder.get_children():
			if child is StaticBody3D:child.collision_layer=0;child.queue_free()
		return
	for spec: Array in holder.get_meta("tree_colliders",[]):
		var body:=StaticBody3D.new();body.collision_layer=1;body.collision_mask=0
		var shape:=CollisionShape3D.new();var cylinder:=CylinderShape3D.new();cylinder.radius=spec[1];cylinder.height=spec[2]
		shape.shape=cylinder;shape.position.y=spec[2]*.5;body.add_child(shape);body.position=spec[0];holder.add_child(body)


func _needs_physics(pos: Vector2) -> bool:
	for point in _physics_points:
		if point.distance_squared_to(pos) < 96 * 96: return true
	return false


func _asset(entry: Dictionary) -> Array:
	if _assets.has(entry.id): return _assets[entry.id]
	if str(entry.id).begins_with("sm_"):
		_assets[entry.id] = GRASSY.parts(entry)
		return _assets[entry.id]
	var packed: PackedScene = load(str(entry.get("lod_scene",entry.scene)))
	if packed == null: return []
	var node := packed.instantiate(); var parts: Array = []
	preload("res://world/foliage/vegetation_materials.gd").apply(node)
	for child in node.get_children():
		if not (child is MeshInstance3D): continue
		var mesh: Mesh = child.mesh
		if mesh == null or mesh.get_surface_count() == 0:
			push_warning("[foliage] skipping empty mesh in %s" % str(entry.scene))
			continue
		# Extracted resources keep every source surface and its shader.
		if child.material_override != null or child.get_surface_override_material_count() > 0:
			mesh = mesh.duplicate()
			for i in mesh.get_surface_count():
				var material: Material = child.material_override if child.material_override != null else child.get_surface_override_material(i)
				if material != null: mesh.surface_set_material(i, preload("res://world/native_material_modes.gd").material_for(material))
		if mesh == null or mesh.get_surface_count() == 0: continue
		parts.append([mesh, child.transform])
	node.free(); _assets[entry.id] = parts
	return parts


func _tree_lods(entry:Dictionary)->Array:
	if str(entry.id).begins_with("everfree_"): return EVERFREE.levels(entry)
	if not str(entry.id).begins_with("sm_"):return []
	if _asset_levels.has(entry.id):return _asset_levels[entry.id]
	# Distances are world metres, independent of source model scale. The 32 m
	# batch radius leaves at least 80 m of detailed trees around the player.
	var distant := IMPOSTORS.parts(entry)
	assert(not distant.is_empty(), "Missing baked foliage: " + str(entry.id))
	var result := [
		{"lod":0,"parts":_asset(entry),"begin":0.0,"end":105.0},
		{"lod":2,"parts":distant,"begin":105.0,"end":0.0}]
	_asset_levels[entry.id]=result
	return result


func _plant_lods(entry: Dictionary) -> Array:
	var distant := IMPOSTORS.parts(entry)
	if distant.is_empty(): return [{"parts":_asset(entry),"begin":0.0,"end":PLANT_RANGE}]
	return [{"parts":_asset(entry),"begin":0.0,"end":65.0},
		{"parts":distant,"begin":65.0,"end":PLANT_RANGE}]



func _cache_presets() -> void:
	_preset_rows.clear(); _tree_rules.clear()
	for preset: Dictionary in field.presets:
		var row := [str(preset.vegetation), int(preset.get("tree_candidates", 3)), int(preset.get("plant_candidates", 24)), float(preset.get("tree_spacing", 20.0))]
		_preset_rows.append(row)
		var rule := Vector2i(int(row[1]), int(row[2]))
		if row[0] in ["everfree", "woodland", "desert"] and not _tree_rules.has(rule): _tree_rules.append(rule)
	_tree_slot_limit = 0
	for rule: Vector2i in _tree_rules: _tree_slot_limit = maxi(_tree_slot_limit, mini(rule.x, MAX_CANDIDATES_PER_CELL))
	if _fill != null:
		var region := WorldLayout.region("everfree")
		_fill.configure(_preset_rows, _tree_rules, WorldLayout.footprint(region) if not region.is_empty() else Rect2())
		_prefilled.clear()


## Whether every slot of `cell` has vegetation density <= 1: no density boost painted in its 8x8
## field pixels (the pixels its slots sample). Unknown image layouts answer false.
static func _density_at_most_one(cell: Vector2i, loc: Vector2i, data: Dictionary) -> bool:
	var boost: Image = data.get("density_boost")
	if boost == null: return true
	if boost.get_format() != Image.FORMAT_L8 or boost.get_width() != 256 or boost.get_height() != 256: return false
	var local := cell - loc * 32
	var bytes := boost.get_data()
	for z in range(local.y * 8, local.y * 8 + 8):
		if bytes.decode_u64(z * 256 + local.x * 8) != 0: return false
	return true


## Whether slot n can be a tree under any preset at this density (the `tree` rule in _build_cell).
func _could_be_tree(n: int, density: float) -> bool:
	for rule: Vector2i in _tree_rules:
		if n < rule.x: return true
		if n >= rule.y and n < mini(MAX_CANDIDATES_PER_CELL, rule.y + density_candidate_count(rule.x, density) - rule.x): return true
	return false


func _catalog_choices(family: String, tree: bool) -> Array:
	var key := family + ("/tree" if tree else "/plant")
	if not _choices.has(key):
		_choices[key] = _catalog.filter(func(a): return a.family == family and a.category == ("tree" if tree else "plant") and (tree or float(a.height) < 7.0))
	return _choices[key]


## Slot positions (exactly the candidate formula) and spacing priorities of `cell`, at least `count` of them.
func _cell_slots(cell: Vector2i, count: int) -> Array:
	var slots: Array = _slots.get(cell, [])
	if slots.is_empty():
		if _slots.size() >= SLOT_CACHE_CELLS: _slots.clear()
		slots = [PackedVector2Array(), PackedFloat64Array()]; _slots[cell] = slots
	var points: PackedVector2Array = slots[0]
	if points.size() >= count: return slots
	var priorities: PackedFloat64Array = slots[1]
	var other := Vector2(cell)
	for n in range(points.size(), count):
		var candidate := other * CELL + Vector2(_random(other, n * 2 + 1), _random(other, n * 2 + 2)) * CELL
		points.append(candidate); priorities.append(_random(candidate, 107))
	slots[0] = points; slots[1] = priorities
	return slots


func _build_cell(cell: Vector2i) -> void:
	if _cells.has(cell): return
	if _preset_rows.size() != field.presets.size(): _cache_presets()
	var holder := Node3D.new(); holder.position = Vector3(cell.x * CELL, 0, cell.y * CELL)
	add_child(holder); _cells[cell] = holder
	if _reach_extent>=0.0:_reach_extent=maxf(_reach_extent,(Vector2(cell)*CELL-_reach_centre).length())
	var groups: Dictionary = {}; var tree_spots: Array[Vector3] = []
	var trees_only: bool=(Vector2(cell)*CELL-_camera_position).length()>CELL*9
	holder.set_meta("trees_only",trees_only)
	# A promotion whose trees are still current plants only; its tree batch already holds the trees.
	var kept: Dictionary = _promote.get(cell, {})
	if not kept.is_empty():
		_promote.erase(cell)
		if trees_only or int(kept.generation) != _generation or float(kept.density) != _density_scale: kept = {}
	var keep_trees := not kept.is_empty()
	var colliders:=[]
	var cell_loc := WorldBiomeField.location(Vector2(cell) * CELL); var cell_data := field.tile(cell_loc)
	# With density <= 1 throughout the cell, slots at or past _tree_slot_limit are never trees
	# (_could_be_tree), so a trees-only build need not generate or test them.
	var slot_count := _tree_slot_limit if trees_only and _density_at_most_one(cell, cell_loc, cell_data) else MAX_CANDIDATES_PER_CELL
	var points: PackedVector2Array = _cell_slots(cell, slot_count)[0]
	# Visible native plants of this cell and its eight neighbours, in the order the old per-slot
	# scan visited them: their trunks for the clearance test, their bodies for the ray exclusions
	# (a slot that clears every trunk collected all of them). Nothing changes them during a build.
	var native_points := PackedVector2Array(); var native_excludes: Array[RID] = []
	for nearby in [cell, cell + Vector2i.LEFT, cell + Vector2i.RIGHT, cell + Vector2i.UP, cell + Vector2i.DOWN,
		cell + Vector2i(-1, -1), cell + Vector2i(1, -1), cell + Vector2i(-1, 1), cell + Vector2i(1, 1)]:
		for rec in _native.get(nearby, []):
			if not is_instance_valid(rec.node) or not rec.node.visible: continue
			for native_body in rec.bodies:
				if is_instance_valid(native_body[0]) and native_body[0] is CollisionObject3D:
					native_excludes.append((native_body[0] as CollisionObject3D).get_rid())
			native_points.append(Vector2(rec.pos.x, rec.pos.z))
	var everfree := Rect2(); var everfree_known := false
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.new(); query.collision_mask = 1 | WalkGridService.WATER_MASK; query.exclude = native_excludes
	# Every rejection below is a pure test of the slot, so the cheap ones run first; a slot
	# passes the same tests, and is planted identically, whatever their order.
	for n in slot_count:
		var p := points[n]
		var loc := WorldBiomeField.location(p); var data := cell_data if loc == cell_loc else field.tile(loc)
		var pixel := Vector2i((p - Vector2(loc * 1024)) / 4)
		pixel = pixel.clamp(Vector2i.ZERO, Vector2i(255, 255))
		var authored: bool = data.coverage.get_pixelv(pixel).r > 0
		var density: float = WorldBiomeField.vegetation_density(data, pixel) if authored else 1.0
		# Existing/default fields retain the old 42-candidate work bound. The
		# second half is touched only where a user explicitly painted >1x.
		if n >= 42 and density <= 1.0: continue
		# Far cells keep trees only: a slot no preset makes a tree at this density needs no sampling.
		if trees_only and not _could_be_tree(n, density): continue
		if not authored:
			# Unpainted slots grow only inside the existing forest (tested again below).
			if not everfree_known: everfree = WorldLayout.footprint(WorldLayout.region("everfree")); everfree_known = true
			if not everfree.has_point(p): continue
		var vegetation_override := WorldBiomeField.vegetation_biome(data, pixel) if authored else -1
		var w := PackedFloat32Array(); var selected := 0
		if vegetation_override >= 0: selected = vegetation_override
		else:
			w = field.sample_weights(p); var roll := _random(p, 54)
			for i in w.size():
				roll -= w[i]
				if roll <= 0: selected = i; break
		var row: Array = _preset_rows[selected]
		var family: String = row[0]
		var base_tree_slots: int = row[1]
		var base_plant_slots: int = row[2]
		var tree_slots: int = density_candidate_count(base_tree_slots, density)
		var extra_tree_slots: int = tree_slots - base_tree_slots
		var candidate_limit: int = mini(MAX_CANDIDATES_PER_CELL, base_plant_slots + extra_tree_slots)
		var spacing: float = density_tree_spacing(row[3], density)
		var tree: bool = (n < base_tree_slots or (n >= base_plant_slots and n < candidate_limit)) and family in ["everfree", "woodland", "desert"]
		if trees_only and not tree:continue
		if keep_trees and tree: continue
		if n >= candidate_limit: continue
		if not authored:
			# Fill the existing forest, preserving paths, source trunks and landmarks.
			if not everfree_known: everfree = WorldLayout.footprint(WorldLayout.region("everfree")); everfree_known = true
			if not everfree.has_point(p) or w[3] < 0.5: continue
			if tree and (n >= 2 or _random(p, 93) > 0.45): continue
			if not tree and n >= 18: continue
		elif density <= 1.0 and _random(p, 51) > density: continue
		if family in ["none", "rock"]: continue
		# Settings → Graphics → Trees & plants: deterministic thinning of cells built from now on.
		if _density_scale < 1.0 and _random(p, 71) > _density_scale: continue
		var world := Vector3(p.x, 0, p.y); var h := terrain.height_at(world)
		if not is_finite(h) or terrain.normal_at(world).y < 0.74: continue
		if tree and not _tree_spacing(cell, p, spacing, base_tree_slots, base_plant_slots, extra_tree_slots): continue
		if family == "meadow": family = "woodland"; tree = false
		# Terrain3DData.get_control already returns the packed integer. Reinterpreting
		# it as an RF pixel corrupts path/water/blocked flags and plants trees there.
		var control: int = int(terrain.terrain.data.get_control(world))
		if ((control >> 27) & 31) in [1, 4, 5, 6, 7, 18] or (control & 4) != 0: continue
		var blocked := false
		var clearance := maxf(2.5, spacing * 0.45) if tree else 2.0
		for trunk in native_points:
			if trunk.distance_to(p) < clearance: blocked = true; break
		if blocked: continue
		# No new plants under bridges, in water, or inside imported structures.
		# Indexed source-tree bodies are excluded here: their broad canopy shapes
		# must not suppress a whole painted grove; trunk clearance above still applies.
		query.from = Vector3(p.x, h + 40, p.y); query.to = Vector3(p.x, h + 0.4, p.y)
		if not space.intersect_ray(query).is_empty(): continue
		var choices: Array = _catalog_choices(family, tree)
		if choices.is_empty(): continue
		var entry: Dictionary = choices[int(_random(p, 71) * choices.size()) % choices.size()]
		if tree and family == "everfree": entry = EVERFREE.choose(choices, _random(p, 71))
		var scale := instance_scale(entry, p)
		var basis := Basis(Vector3.UP, _random(p, 73) * TAU).scaled(scale)
		var contact_offset := GRASSY.contact_offset(entry) if entry.has("contact_offset") \
			else Vector3(0.0, -float(entry.get("support_y", entry.base_y)), 0.0)
		var transform := Transform3D(basis,
			# Recentered scenes retain their authored collar through the measured contact vector.
			Vector3(p.x, h, p.y) + basis * contact_offset - holder.position)
		if tree and entry.has("trunk_radius"):
			var offset: Array = entry.trunk_offset
			var centre := Vector3(p.x,h,p.y) + basis * Vector3(offset[0],0,offset[2])
			if not EVERFREE.clears_trail(centre, float(entry.trunk_radius)*maxf(scale.x,scale.z)): continue
		if not groups.has(entry.id): groups[entry.id] = {"entry": entry, "transforms": []}
		groups[entry.id].transforms.append(transform)
		if tree:
			var trunk_offset: Array = entry.get("trunk_offset", [0.0,0.0,0.0])
			var trunk_at := Vector3(p.x,h,p.y) + basis * Vector3(trunk_offset[0],0,trunk_offset[2]) - holder.position
			var trunk_radius := float(entry.trunk_radius) * maxf(scale.x,scale.z) if entry.has("trunk_radius") else clampf(float(entry.radius)*.07*maxf(scale.x,scale.z),.25,1.2)
			var trunk_height := float(entry.trunk_height) * scale.y if entry.has("trunk_height") else maxf(1,float(entry.height)*.65*scale.y)
			colliders.append([trunk_at,trunk_radius,trunk_height])
			tree_spots.append(Vector3(p.x,h,p.y))
	_finish_cell(cell, holder, groups, colliders, tree_spots, kept, keep_trees)


## The end of a cell build (both paths): trunk colliders, the tree batch, physics, plant MultiMeshes.
func _finish_cell(cell: Vector2i, holder: Node3D, groups: Dictionary, colliders: Array, tree_spots: Array[Vector3], kept: Dictionary, keep_trees: bool) -> void:
	holder.set_meta("tree_colliders",kept.colliders if keep_trees else colliders)
	if keep_trees and kept.trunks: tree_spots.append(holder.position)
	var trees:={}
	for id: String in groups.keys():
		if groups[id].entry.category=="tree":trees[id]=groups[id];groups.erase(id)
	if _tree_batches!=null and not keep_trees:_tree_batches.put(cell,trees)
	var near:=_needs_physics(Vector2(cell)*CELL)
	_sync_physics(holder,near)
	if near:_physics_cells[cell]=true

	for data: Dictionary in groups.values():
		var levels := _plant_lods(data.entry)
		var shared_bounds := AABB();var first := true
		for level: Dictionary in levels:
			for part: Array in level.parts:
				if _fill != null:
					# dev 2026-10-20 multithreading: the same merge in C++ (PonyFoliageFill.merge_bounds).
					var merged: Array = _fill.merge_bounds(shared_bounds, first, data.transforms, part[1], part[0].get_aabb(), true)
					shared_bounds = merged[0]; first = merged[1]; continue
				for transform: Transform3D in data.transforms:
					var box: AABB = (transform * part[1]) * part[0].get_aabb()
					shared_bounds = box if first else shared_bounds.merge(box);first=false
		for level: Dictionary in levels:
			for part: Array in level.parts:
				var mm := MultiMesh.new();mm.transform_format=MultiMesh.TRANSFORM_3D
				mm.mesh=part[0];mm.instance_count=data.transforms.size()
				mm.buffer=_fill.pack_transforms(data.transforms,part[1],true) if _fill != null else instance_buffer(data.transforms,part[1])
				mm.custom_aabb=shared_bounds.grow(.8)
				var mesh := MultiMeshInstance3D.new();mesh.multimesh=mm
				mesh.visibility_range_begin=level.begin;mesh.visibility_range_end=level.end
				# Distant billboard plants follow the far-tree policy: their cards
				# do not project extra shadow silhouettes. Close meshes still cast.
				if float(level.begin)>0.0:mesh.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				holder.add_child(mesh)

	if not tree_spots.is_empty():
		holder.set_meta("trunks", true)


## dev 2026-10-20 multithreading: _build_cell with its pure slot tests already done by PonyFoliageFill
## (`result`: a worker batch's, or computed here when missing or stale). The survivors, in slot order,
## get _build_cell's terrain, control, clearance, ray and placement steps line for line. A cell the
## native fill could not sample (a field tile it was not given) is built by _build_cell instead.
func _build_cell_native(cell: Vector2i, result: Dictionary) -> void:
	if _cells.has(cell): return
	if _preset_rows.size() != field.presets.size(): _cache_presets(); result = {}
	_prefilled.erase(cell)
	var trees_only: bool=(Vector2(cell)*CELL-_camera_position).length()>CELL*9
	var kept: Dictionary = _promote.get(cell, {})
	var keep_trees := not kept.is_empty() and not (trees_only or int(kept.generation) != _generation or float(kept.density) != _density_scale)
	if result.is_empty() or not _fill_current(result, trees_only, keep_trees): result = _fill_cell(cell, trees_only, keep_trees)
	if int(result.status) != 0:
		_build_cell(cell); return
	var holder := Node3D.new(); holder.position = Vector3(cell.x * CELL, 0, cell.y * CELL)
	add_child(holder); _cells[cell] = holder
	if _reach_extent>=0.0:_reach_extent=maxf(_reach_extent,(Vector2(cell)*CELL-_reach_centre).length())
	var groups: Dictionary = {}; var tree_spots: Array[Vector3] = []
	holder.set_meta("trees_only",trees_only)
	if not kept.is_empty():
		_promote.erase(cell)
		if not keep_trees: kept = {}
	var colliders:=[]
	var native_points := PackedVector2Array(); var native_excludes: Array[RID] = []
	for nearby in [cell, cell + Vector2i.LEFT, cell + Vector2i.RIGHT, cell + Vector2i.UP, cell + Vector2i.DOWN,
		cell + Vector2i(-1, -1), cell + Vector2i(1, -1), cell + Vector2i(-1, 1), cell + Vector2i(1, 1)]:
		for rec in _native.get(nearby, []):
			if not is_instance_valid(rec.node) or not rec.node.visible: continue
			for native_body in rec.bodies:
				if is_instance_valid(native_body[0]) and native_body[0] is CollisionObject3D:
					native_excludes.append((native_body[0] as CollisionObject3D).get_rid())
			native_points.append(Vector2(rec.pos.x, rec.pos.z))
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.new(); query.collision_mask = 1 | WalkGridService.WATER_MASK; query.exclude = native_excludes
	var rows: PackedInt32Array = result.rows; var points: PackedVector2Array = result.points; var spacings: PackedFloat64Array = result.spacing
	for k in points.size():
		var p := points[k]
		var world := Vector3(p.x, 0, p.y); var h := terrain.height_at(world)
		if not is_finite(h) or terrain.normal_at(world).y < 0.74: continue
		var tree := rows[k * 3 + 2] != 0
		var family: String = _preset_rows[rows[k * 3 + 1]][0]
		if family == "meadow": family = "woodland"
		var spacing := spacings[k]
		var control: int = int(terrain.terrain.data.get_control(world))
		if ((control >> 27) & 31) in [1, 4, 5, 6, 7, 18] or (control & 4) != 0: continue
		var blocked := false
		var clearance := maxf(2.5, spacing * 0.45) if tree else 2.0
		for trunk in native_points:
			if trunk.distance_to(p) < clearance: blocked = true; break
		if blocked: continue
		query.from = Vector3(p.x, h + 40, p.y); query.to = Vector3(p.x, h + 0.4, p.y)
		if not space.intersect_ray(query).is_empty(): continue
		var choices: Array = _catalog_choices(family, tree)
		if choices.is_empty(): continue
		var entry: Dictionary = choices[int(_random(p, 71) * choices.size()) % choices.size()]
		if tree and family == "everfree": entry = EVERFREE.choose(choices, _random(p, 71))
		var scale := instance_scale(entry, p)
		var basis := Basis(Vector3.UP, _random(p, 73) * TAU).scaled(scale)
		var contact_offset := GRASSY.contact_offset(entry) if entry.has("contact_offset") \
			else Vector3(0.0, -float(entry.get("support_y", entry.base_y)), 0.0)
		var transform := Transform3D(basis, Vector3(p.x, h, p.y) + basis * contact_offset - holder.position)
		if tree and entry.has("trunk_radius"):
			var offset: Array = entry.trunk_offset
			var centre := Vector3(p.x,h,p.y) + basis * Vector3(offset[0],0,offset[2])
			if not EVERFREE.clears_trail(centre, float(entry.trunk_radius)*maxf(scale.x,scale.z)): continue
		if not groups.has(entry.id): groups[entry.id] = {"entry": entry, "transforms": []}
		groups[entry.id].transforms.append(transform)
		if tree:
			var trunk_offset: Array = entry.get("trunk_offset", [0.0,0.0,0.0])
			var trunk_at := Vector3(p.x,h,p.y) + basis * Vector3(trunk_offset[0],0,trunk_offset[2]) - holder.position
			var trunk_radius := float(entry.trunk_radius) * maxf(scale.x,scale.z) if entry.has("trunk_radius") else clampf(float(entry.radius)*.07*maxf(scale.x,scale.z),.25,1.2)
			var trunk_height := float(entry.trunk_height) * scale.y if entry.has("trunk_height") else maxf(1,float(entry.height)*.65*scale.y)
			colliders.append([trunk_at,trunk_radius,trunk_height])
			tree_spots.append(Vector3(p.x,h,p.y))
	_finish_cell(cell, holder, groups, colliders, tree_spots, kept, keep_trees)


## Whether a native fill result was computed for the cell's current inputs.
func _fill_current(result: Dictionary, trees_only: bool, keep_trees: bool) -> bool:
	return int(result.get("revision", -1)) == field.revision and bool(result.trees_only) == trees_only \
		and bool(result.keep_trees) == keep_trees and float(result.density_scale) == _density_scale \
		and int(result.slot_limit) == _tree_slot_limit


## The native fill of one cell, now, on this thread (a few microseconds in C++).
func _fill_cell(cell: Vector2i, trees_only: bool, keep_trees: bool) -> Dictionary:
	_fill_cell_tiles(cell)
	var result: Dictionary = _fill.compute_cell(cell, trees_only, keep_trees, _density_scale, _tree_slot_limit)
	result.revision = field.revision
	return result


## Gives the native fill the field tiles a cell reads: its own (loaded as _build_cell would) and, on
## the tile's last pixel row/column, the next tiles the bilinear weights reach, only when the field
## already holds them (_build_cell would load or seed those itself: such a cell falls back to it).
func _fill_cell_tiles(cell: Vector2i) -> void:
	if _fill_revision != field.revision:
		_fill.clear_tiles(); _fill_tiles.clear(); _fill_revision = field.revision
	var loc := WorldBiomeField.location(Vector2(cell) * CELL)
	_fill_tile(loc, true)
	var local := cell - loc * int(WorldBiomeField.REGION / CELL)
	var last := int(WorldBiomeField.REGION / CELL) - 1
	if local.x == last: _fill_tile(loc + Vector2i(1, 0), false)
	if local.y == last: _fill_tile(loc + Vector2i(0, 1), false)
	if local.x == last and local.y == last: _fill_tile(loc + Vector2i.ONE, false)


func _fill_tile(loc: Vector2i, load_tile: bool) -> void:
	var data: Variant = field._tiles.get(loc)
	if data == null:
		if not load_tile:
			if _fill_tiles.has(loc): _fill_tiles.erase(loc); _fill.erase_tile(loc)
			return
		data = field.tile(loc)
	var known: Array = _fill_tiles.get(loc, [])
	if not known.is_empty() and is_same(known[0], data): return
	_fill_tiles[loc] = [data, _fill.set_tile(loc, data)]


## Starts a worker batch for the next pending cells without a result, unless one is in flight.
func _kick_fill() -> void:
	if _fill.is_busy() or _pending.is_empty(): return
	var cells := PackedInt32Array(); var count := 0
	for cell: Vector2i in _pending:
		if count >= NATIVE_FILL_BATCH: break
		if _prefilled.has(cell) or _cells.has(cell): continue
		var trees_only: bool=(Vector2(cell)*CELL-_camera_position).length()>CELL*9
		var kept: Dictionary = _promote.get(cell, {})
		var keep_trees := not kept.is_empty() and not (trees_only or int(kept.generation) != _generation or float(kept.density) != _density_scale)
		_fill_cell_tiles(cell)
		cells.append(cell.x); cells.append(cell.y); cells.append((1 if trees_only else 0) | (2 if keep_trees else 0))
		count += 1
	if count > 0 and _fill.submit(cells, _density_scale, _tree_slot_limit): _fill_batch_revision = field.revision


## Takes a finished worker batch (never waits for a running one).
func _collect_fill() -> void:
	if not _fill.is_ready(): return
	var results: Array = _fill.collect()
	if _fill_batch_revision != field.revision: return
	if _prefilled.size() > SLOT_CACHE_CELLS: _prefilled.clear()
	for result: Dictionary in results:
		result.revision = _fill_batch_revision
		_prefilled[result.cell] = result


## MultiMesh.buffer for `transforms`, each times `part`: the 3x4 matrix row by row, the same
## floats set_instance_transform writes, in one upload.
static func instance_buffer(transforms: Array, part: Transform3D) -> PackedFloat32Array:
	var data := PackedFloat32Array(); data.resize(transforms.size() * 12)
	for i in transforms.size():
		var t: Transform3D = transforms[i] * part; var b := t.basis; var o := t.origin; var k := i * 12
		data[k] = b.x.x; data[k + 1] = b.y.x; data[k + 2] = b.z.x; data[k + 3] = o.x
		data[k + 4] = b.x.y; data[k + 5] = b.y.y; data[k + 6] = b.z.y; data[k + 7] = o.y
		data[k + 8] = b.x.z; data[k + 9] = b.y.z; data[k + 10] = b.z.z; data[k + 11] = o.z
	return data


static func instance_scale(entry: Dictionary, pos: Vector2) -> Vector3:
	if str(entry.id).begins_with("everfree_"):
		return Vector3.ONE * lerpf(0.9, 1.1, _random(pos, 82))
	if str(entry.get("family", "")) == "woodland" and str(entry.get("archetype", "")).begins_with("ck_sprucetree"):
		# Three authored silhouettes, varied size and modest crown width. All
		# variation is world-seeded so streaming never reshuffles a painted forest.
		var height := lerpf(8.0, 22.0, _random(pos, 82))
		var vertical := height / maxf(0.1, float(entry.height))
		var radial := vertical * lerpf(0.85, 1.12, _random(pos, 83))
		return Vector3(radial, vertical, radial)
	var bounds := AABB(Vector3.ZERO, Vector3(float(entry.radius) * 2.0, float(entry.height), float(entry.radius) * 2.0))
	var scale := lerpf(0.8, 1.15, _random(pos, 82)) if VEGETATION_SCALE.source_scale_requested() else VEGETATION_SCALE.scale_for_bounds(bounds, str(entry.name), pos, str(entry.category))
	return Vector3.ONE * scale


static func _random(pos: Vector2, salt: int) -> float:
	# Integer hash: no frame/time RNG, no seams when a neighbouring cell is streamed.
	var h: int = (floori(pos.x * 31) * 73856093) ^ (floori(pos.y * 31) * 19349663) ^ (salt * 83492791)
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff
	return float(h % 100000) / 100000.0


static func density_candidate_count(base_count: int, density: float) -> int:
	# The legacy 0..1 range keeps its exact candidate set and uses acceptance
	# thinning below. Above 1, expose more deterministic candidates.
	if density <= 1.0: return clampi(base_count, 0, MAX_CANDIDATES_PER_CELL)
	return clampi(ceili(base_count * density), 0, MAX_CANDIDATES_PER_CELL)


static func density_tree_spacing(base_spacing: float, density: float) -> float:
	# Area density scales with inverse spacing squared. The 4.0 m floor keeps
	# trunks physically usable even if a preset later requests a tighter value.
	if density <= 1.0: return base_spacing
	return maxf(4.0, base_spacing / sqrt(density))


func _tree_spacing(cell: Vector2i, pos: Vector2, spacing := 20.0, candidates := 3, extra_start := -1, extra_count := 0) -> bool:
	# Deterministic thinning across cell borders; unloading/reordering changes nothing.
	# Slots of [0, candidates) and [extra_start, extra_start + extra_count) in the 3x3 cells.
	var priority := _random(pos, 107)
	var limit := spacing * spacing
	var extra_end := extra_start + extra_count if extra_start >= 0 else 0
	var count := maxi(candidates, extra_end)
	# A cell's slots lie inside it, so a neighbour more than `spacing` away on either axis
	# holds no slot in range (.5 m covers float rounding); skipping it changes no result.
	var reach := spacing + 0.5
	var inside := pos - Vector2(cell) * CELL
	for z in range(cell.y - 1, cell.y + 2):
		if (z < cell.y and inside.y > reach) or (z > cell.y and CELL - inside.y > reach): continue
		for x in range(cell.x - 1, cell.x + 2):
			if (x < cell.x and inside.x > reach) or (x > cell.x and CELL - inside.x > reach): continue
			var slots := _cell_slots(Vector2i(x, z), count)
			var points: PackedVector2Array = slots[0]; var priorities: PackedFloat64Array = slots[1]
			for n in candidates:
				if priorities[n] < priority and points[n].distance_squared_to(pos) < limit: return false
			if extra_start >= 0:
				for n in range(extra_start, extra_end):
					if priorities[n] < priority and points[n].distance_squared_to(pos) < limit: return false
	return true


func _build_leaves() -> void:
	_leaves = GPUParticles3D.new(); _leaves.amount = 48; _leaves.lifetime = 14
	_leaves.visibility_aabb = AABB(Vector3(-25, -20, -25), Vector3(50, 40, 50))
	_leaves.local_coords = false; _leaves.emitting = false
	var process := ParticleProcessMaterial.new(); process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(18, 4, 18); process.direction = Vector3(1, -1, 0.3)
	process.initial_velocity_min = 0.35; process.initial_velocity_max = 0.8; process.gravity = Vector3(0.08, -0.08, 0)
	process.angular_velocity_min = -35; process.angular_velocity_max = 35
	process.scale_min = 0.7; process.scale_max = 1.3
	_leaves.process_material = process
	var mesh := ImmediateMesh.new(); var mat := StandardMaterial3D.new(); mat.albedo_color = Color(0.28, 0.38, 0.16); mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, mat)
	for v in [Vector3(0, 0.08, 0), Vector3(-0.035, 0, 0), Vector3(0, -0.06, 0), Vector3(0, 0.08, 0), Vector3(0, -0.06, 0), Vector3(0.035, 0, 0)]:
		mesh.surface_set_normal(Vector3.FORWARD); mesh.surface_add_vertex(v)
	mesh.surface_end(); _leaves.draw_pass_1 = mesh; add_child(_leaves)
