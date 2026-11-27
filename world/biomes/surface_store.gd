class_name BiomeSurfaceStore
extends RefCounted
## Exact control-map snapshots and sparse authored coverage. No height/holes editing.
const ROOT := "res://world/biomes/authored"
const WORK := "user://world_editor/biomes"
var published_dir := ROOT
var working_dir := WORK
var terrain: Node
var records: Dictionary = {}
## Only true while announcing an unchanged published overlay restored from disk.
## Consumers with a complete matching published bake can retain that coverage.
var restoring_published := false
signal controls_changed(locations: Array)
## Lane memory 2026-11-21: a record's "baseline" (the unpainted control map, 4 MB per authored
## region) is read only by `load_saved`, right after `ensure` made it. The game's own pass
## (`load_saved(false)`) drops it afterwards; `_baseline` reads it again from the baked baseline
## file or the region file when a later pass needs it. A dropped record's "baseline" is null.
## false keeps every baseline resident as before.
const DROP_PLAY_BASELINES := true


func _init(node: Node = null) -> void:
	terrain = node


func ensure(loc: Vector2i) -> Dictionary:
	if records.has(loc):
		var kept: Dictionary = records[loc]
		if kept.get("coverage") == null: kept.coverage = _published_coverage(loc)
		return kept
	var region: Object = terrain.data.get_region(loc)
	if region == null: return {}
	var control: Image = region.get_control_map()
	var rec := {"baseline": control.duplicate(), "coverage": Image.create(1024, 1024, false, Image.FORMAT_L8), "bounds": Rect2i()}
	var baseline_path := "res://world/terrain/gen/%s/baseline_control.f32" % WorldBiomeField.key(loc)
	if FileAccess.file_exists(baseline_path):
		var bytes := FileAccess.get_file_as_bytes(baseline_path)
		if bytes.size() == 1024 * 1024 * 4: rec.baseline = Image.create_from_data(1024, 1024, false, Image.FORMAT_RF, bytes)
	records[loc] = rec
	return rec


## A dropped play record's coverage: the published coverage image, as load_saved read it.
func _published_coverage(loc: Vector2i) -> Image:
	var name := WorldBiomeField.key(loc)
	var index: Dictionary = WorldBiomeField.index_at(published_dir, true).get("tiles", {})
	if index.has(name):
		var coverage := preload("res://world/resource_image.gd").read(published_dir.path_join(str(index[name])).path_join("coverage.png"))
		if coverage != null: return coverage
	return Image.create(1024, 1024, false, Image.FORMAT_L8)


## The record's unpainted control map: kept, or (dropped in play) read again from disk.
func _baseline(loc: Vector2i, rec: Dictionary) -> Image:
	if rec.get("baseline") is Image: return rec.baseline
	var baseline_path := "res://world/terrain/gen/%s/baseline_control.f32" % WorldBiomeField.key(loc)
	if FileAccess.file_exists(baseline_path):
		var bytes := FileAccess.get_file_as_bytes(baseline_path)
		if bytes.size() == 1024 * 1024 * 4:
			rec.baseline = Image.create_from_data(1024, 1024, false, Image.FORMAT_RF, bytes); return rec.baseline
	var world := WorldTerrain.instance
	if world != null and world._region_files.has(loc):
		var region: Resource = ResourceLoader.load(world.active_data_dir().path_join(str(world._region_files[loc])), "", ResourceLoader.CACHE_MODE_IGNORE)
		if region != null and region.has_method("get_control_map"):
			var control: Variant = region.call("get_control_map")
			if control is Image and (control as Image).get_width() == 1024:
				rec.baseline = (control as Image).duplicate(); return rec.baseline
	push_warning("BiomeSurfaceStore: no source for %s; the live control map stands in for its baseline" % loc)
	rec.baseline = terrain.data.get_region(loc).get_control_map().duplicate()
	return rec.baseline


func snapshot(loc: Vector2i) -> Dictionary:
	var rec := ensure(loc)
	if rec.is_empty(): return {}
	var region: Object = terrain.data.get_region(loc)
	return {"control": region.get_control_map().duplicate(), "coverage": rec.coverage.duplicate(), "bounds": rec.bounds}


func restore(loc: Vector2i, saved: Dictionary) -> void:
	var rec := ensure(loc)
	var region: Object = terrain.data.get_region(loc)
	if region == null or saved.is_empty(): return
	region.set_control_map(saved.control.duplicate()); region.set_modified(true)
	rec.coverage = saved.coverage.duplicate(); rec.bounds = saved.bounds


## `only`: restrict to these region locations (the terrain window re-applies per region).
func load_saved(working := false, only: Array = []) -> void:
	var touched: Array = []
	for root_dir in [published_dir, working_dir] if working else [published_dir]:
		var index: Dictionary = WorldBiomeField.index_at(root_dir, true).get("tiles", {})
		for name: String in index:
			var xy := name.split("_"); var loc := Vector2i(int(xy[0]), int(xy[1]))
			if not only.is_empty() and loc not in only: continue
			var rec := ensure(loc)
			if rec.is_empty(): continue
			var folder: String = root_dir.path_join(str(index[name]))
			var coverage := preload("res://world/resource_image.gd").read(folder.path_join("coverage.png"))
			var bytes := FileAccess.get_file_as_bytes(folder.path_join("control.f32"))
			var metadata := WorldBiomeField.read_json(folder.path_join("meta.json"))
			if coverage == null or bytes.size() != 1024 * 1024 * 4 or not metadata.has("bounds"): continue
			var a: Array = metadata.bounds; var rect := Rect2i(int(a[0]), int(a[1]), int(a[2]), int(a[3]))
			var region: Object = terrain.data.get_region(loc)
			# Each saved tile is a complete authored overlay, including erased coverage.
			# Imported controls can already contain a previous publication.
			var map: Image
			if not working and DROP_PLAY_BASELINES:
				# In place: the region keeps its own Image object, so the terrain plugin holds no
				# stale copy of the unpainted map once the baseline is dropped.
				map = region.get_control_map(); map.copy_from(_baseline(loc, rec))
			else:
				map = _baseline(loc, rec).duplicate()
			preload("res://world/terrain/terrain_overlay.gd").apply(map, bytes, coverage, rect)
			region.set_control_map(map); region.set_modified(true)
			rec.coverage = coverage; rec.bounds = rect; touched.append(loc)
	if not working and DROP_PLAY_BASELINES:
		for rec: Dictionary in records.values(): rec.baseline = null
		# Coverage (1 MB a region) is read only by editing and saving; ensure() rebuilds it.
		for loc: Vector2i in touched: records[loc].coverage = null
	if not only.is_empty(): touched = touched.filter(func(loc): return loc in only)
	if not touched.is_empty():
		var previous := restoring_published
		restoring_published = not working
		upload(touched)
		restoring_published = previous


## A region left the terrain window: its record is stale once the region reloads from disk.
func forget(loc: Vector2i) -> void:
	records.erase(loc)


func upload(locations: Array) -> void:
	# Terrain3D defaults to rebuilding the entire texture array. Mark only changed
	# layers and explicitly select its incremental upload path (1.0.2 native API).
	for loc in locations:
		var region: Object = terrain.data.get_region(loc)
		if region != null: region.set_edited(true)
	terrain.data.update_maps(1, false, false)
	for loc in locations:
		var region: Object = terrain.data.get_region(loc)
		if region != null: region.set_edited(false)

	controls_changed.emit(locations)


func save(publish := false) -> Error:
	var root_dir := published_dir if publish else working_dir
	var index: Dictionary = WorldBiomeField.read_json(root_dir.path_join("surface_index.json")).get("tiles", {})
	for loc: Vector2i in records:
		var rec: Dictionary = ensure(loc)
		var region: Object = terrain.data.get_region(loc)
		if region == null: continue
		var generation := "surface/%s/%d_%d" % [WorldBiomeField.key(loc), Time.get_unix_time_from_system(), Time.get_ticks_usec()]
		var folder := root_dir.path_join(generation)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
		var control: Image = region.get_control_map()
		var f := FileAccess.open(folder.path_join("control.f32"), FileAccess.WRITE)
		if f == null: return FileAccess.get_open_error()
		f.store_buffer(control.get_data()); f.close()
		var err: Error = rec.coverage.save_png(folder.path_join("coverage.png"))
		if err != OK: return err
		# The offline generator consumes the same data through its byte ID images.
		var base := Image.create(1024, 1024, false, Image.FORMAT_L8)
		var overlay := base.duplicate(); var blend := base.duplicate()
		var bounds: Rect2i = rec.bounds
		for y in range(bounds.position.y, bounds.end.y):
			for x in range(bounds.position.x, bounds.end.x):
				var bits: int = Terrain3DUtil.as_uint(control.get_pixel(x, y).r)
				base.set_pixel(x, y, Color(((bits >> 27) & 31) / 255.0, 0, 0))
				overlay.set_pixel(x, y, Color(((bits >> 22) & 31) / 255.0, 0, 0))
				blend.set_pixel(x, y, Color(((bits >> 14) & 255) / 255.0, 0, 0))
		for pair in [["base", base], ["overlay", overlay], ["blend", blend]]:
			err = pair[1].save_png(folder.path_join(str(pair[0]) + ".png"))
			if err != OK: return err
		err = WorldBiomeField.atomic_json(folder.path_join("meta.json"), {"bounds": [bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y]})
		if err != OK: return err
		index[WorldBiomeField.key(loc)] = generation
	return WorldBiomeField.atomic_json(root_dir.path_join("surface_index.json"), {"version": 1, "tiles": index})
