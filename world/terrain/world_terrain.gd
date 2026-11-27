class_name WorldTerrain
extends Node3D
## The world's ground: one Terrain3D for the whole 15 km Equestria (WORLD.md), built at
## runtime so the game, the labs and the headless tools all get the same node.
##
## Data lives in world/terrain/data/ (gitignored; rebuilt from the generator tiles by
## tools/import_world_terrain.gd). Without data the node exists but has no regions, and
## ZoneManager keeps building the old per-zone terrain meshes.

const DATA_DIR := "res://world/terrain/data"
## 512-texel / 2 m regions with the sculpt and biome overlays baked in (tools/terrain/
## make_half_res_data.gd): the potato tier's `terrain_texel_m` 2.0 loads these instead.
const HALF_DATA_DIR := "res://world/terrain/data_half"
const TEXTURES := "res://world/terrain/textures.json"
const REGION := 1024
const TEXELS := 1024
const FULL_COLLISION_REGIONS := 16
static var instance: WorldTerrain
var terrain: Node
var collision_enabled := true
var biomes: WorldBiomeField
var biome_surfaces: BiomeSurfaceStore
## Cheap revision used by persisted navigation columns. It is captured once when this
## WorldTerrain enters the tree: terrain imports take effect on the next world lifecycle.
var navigation_revision := ""
## Region window (dev 2026-09-29: "terrain3d cut that shit"). Every resident region costs
## 12 MB of maps (1024 x 1024 texels of height RF, control and colour), so the 234-region
## world holds 2.8 GB of VRAM before anything else loads. A tier with `terrain_window_m`
## keeps only the regions within that reach of the streaming anchor, drops them again
## WINDOW_SLACK further out, and re-applies the sculpt/biome overlays to whatever loads.
## 0 (High, Ultra, headless fixtures) keeps the whole world resident as before.
const WINDOW_SLACK := 800.0
const WINDOW_POLL := 0.5
const PARALLEL_REGION_LOADS := true
# Each decoder temporarily holds compressed data and three full-size maps.
const REGION_LOAD_BATCH := 4
static var _parallel_loads := PARALLEL_REGION_LOADS and not ("--terrain-regions=serial" in OS.get_cmdline_user_args())
var _region_version := -1.0
var window_m := 0.0
var half_res := false
var _region_files := {}  # Vector2i location -> "terrain3d_00-01.res"
var _window_center := Vector2i(1 << 20, 1 << 20)
var _window_poll := 0.0
## The last window move, by stage in ms (focus()); empty until the window first moves.
var window_stats := {}
signal regions_loaded(locations: Array)


## The single instance, created under `parent` when missing (ZoneManager.setup calls this).
static func ensure(parent: Node) -> WorldTerrain:
	if is_instance_valid(instance) and instance.is_inside_tree():
		return instance
	var node := WorldTerrain.new()
	node.name = "WorldTerrain"
	parent.add_child(node)
	return node


static func has_data() -> bool:
	var dir := DATA_DIR
	if not DirAccess.dir_exists_absolute(dir):
		return false
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".res"):
			return true
	return false


## Terrain3D region resources are several gigabytes together, so navigation only hashes
## their sorted names and filesystem metadata. The importer replaces these files; a changed
## name, size, or mtime therefore invalidates height-derived walk-grid columns without
## reading their contents. Missing/empty directories deliberately match the old no-terrain
## cache behavior.
static func data_revision(data_dir := DATA_DIR) -> String:
	var dir := data_dir
	if not DirAccess.dir_exists_absolute(dir):
		return ""
	var entries := []
	var files := DirAccess.get_files_at(dir)
	files.sort()
	for file in files:
		if not file.ends_with(".res"):
			continue
		var path := data_dir.path_join(file)
		var handle := FileAccess.open(path, FileAccess.READ)
		if handle == null:
			continue
		entries.append([file, handle.get_length(), FileAccess.get_modified_time(path)])
	return "" if entries.is_empty() else var_to_bytes(entries).hex_encode().sha256_text()


func _init() -> void:
	terrain = ClassDB.instantiate("Terrain3D")
	terrain.name = "Terrain3D"
	# No sun-shadow pass for the ground (dev 2026-10-23 triangle pass): the clipmap was drawn
	# again into every cascade, about half its ~520k triangles. Ponies, houses and trees still
	# shadow the ground; hills no longer shadow other ground at low sun.
	if terrain.has_method("set_cast_shadows"): terrain.set_cast_shadows(GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	add_child(terrain)


func _ready() -> void:
	instance = self
	navigation_revision = data_revision()
	# Replacing the town changes walkable geometry even when the heightmap stays.
	if FileAccess.file_exists("res://world/towns/ponyville/layout.json"):
		navigation_revision += ":town:"+FileAccess.get_md5("res://world/towns/ponyville/layout.json")
	for dependency: String in ["rnl_hall.scn", "hall_interior.gd"]:
		var path := "res://world/buildings/town_hall/" + dependency
		if FileAccess.file_exists(path): navigation_revision += ":town-hall:" + FileAccess.get_md5(path)
	for dependency: String in ["barn.scn", "barn_interior.gd"]:
		var path := "res://world/buildings/barn/" + dependency
		if FileAccess.file_exists(path): navigation_revision += ":barn:" + FileAccess.get_md5(path)
	navigation_revision += ":houses:"+FileAccess.get_md5("res://tools/buildings/browser_houses.json")
	if FileAccess.file_exists("res://world/towns/ponyville/stair_approaches.scn"):
		navigation_revision += ":stairs:"+FileAccess.get_md5("res://world/towns/ponyville/stair_approaches.scn")
	navigation_revision += ":beds:"+FileAccess.get_md5("res://world/buildings/house_interior.gd")
	navigation_revision += ":shell-repairs:"+FileAccess.get_md5("res://world/interiors/shell_repairs.gd")+FileAccess.get_md5("res://world/interiors/shell_repairs/g_collision.res")+FileAccess.get_md5("res://world/interiors/shell_repairs/c_collision.res")
	navigation_revision += ":a-inner-wall:"+FileAccess.get_md5("res://world/interiors/shell_repairs/a_inner_wall.gd")+FileAccess.get_md5("res://world/interiors/shell_repairs/a_inner_collision.scn")+FileAccess.get_md5("res://world/interiors/shell_repairs/a_window_parts.gd")+FileAccess.get_md5("res://world/interiors/shell_repairs/a_window_parts.json")
	navigation_revision += ":mare-home-lining:"+FileAccess.get_md5("res://world/interiors/mare_home_lining.gd")
	for design: String in ["house_a", "house_b", "house_c", "house_d", "house_e", "house_f", "house_g", "house_h"]:
		var lining := "res://world/interiors/linings/" + design + "_lining.scn"
		if FileAccess.file_exists(lining): navigation_revision += ":lining:" + FileAccess.get_md5(lining)
	navigation_revision += ":linings-approved:" + FileAccess.get_md5("res://world/interiors/linings/approved.json")
	# Furniture stands in every house and blocks walking there.
	navigation_revision += ":furniture:"+FileAccess.get_md5("res://world/interiors/interior_furnisher.gd")+FileAccess.get_md5("res://world/interiors/interior_kit.json")
	# These helpers now own geometry, beds and routing formerly in the hashed facades.
	for dependency: String in ["authored_home.gd", "homes.json", "house_shell_ops.gd", "house_floor_fit.gd", "house_beds.gd", "interior_range.gd", "house_routing.gd", "indoor_route_graph.gd", "stair_path_follower.gd", "bed_slot.gd"]:
		navigation_revision += ":home-helper:" + FileAccess.get_md5("res://world/buildings/" + dependency)
	for dependency: String in ["furniture_assets.gd", "furnish_style.gd", "occupancy_grid.gd", "furnish_candidates.gd", "furnish_surfaces.gd"]:
		navigation_revision += ":furniture-helper:" + FileAccess.get_md5("res://world/interiors/" + dependency)
	for dependency: String in ["world/cooking/cooking_fit.gd", "world/cooking/cooking_tools.scn", "world/props/household/kitchen-island.glb", "world/props/household/compact-kitchen.scn"]:
		navigation_revision += ":cooking:" + FileAccess.get_md5("res://" + dependency)
	navigation_revision += ":seats:"+FileAccess.get_md5("res://world/life/seating.gd")
	# Walk-in shops replace filled scenery collision and add furnished rooms.
	for dependency: String in ["boutique.gd", "shell.gd", "layout.gd", "architecture.gd", "window_reveals.gd", "interior.gd", "props.gd", "home.gd", "shelves.gd", "shelves.scn"]:
		navigation_revision += ":boutique:" + FileAccess.get_md5("res://world/buildings/boutique/" + dependency)
	for dependency: String in ["res://world/buildings/sugarcube/rnl_bakery.scn", "res://world/buildings/sugarcube/bakery_interior.gd", "res://world/towns/ponyville/sugarcube.scn", "res://world/buildings/golden_oak/home.gd", "res://world/buildings/golden_oak/shell.gd", "res://world/buildings/cloudominium/home.gd"]:
		if FileAccess.file_exists(dependency): navigation_revision += ":bakery:" + FileAccess.get_md5(dependency)
	for dependency:String in ["furniture.gd", "furniture_beds.gd", "furniture_lounge.gd", "furniture_music.gd", "furniture_display.gd", "architecture_ornament.gd", "room_props.gd", "models/room_pack/rd_lamp.scn"]:
		navigation_revision += ":cloudominium:"+FileAccess.get_md5("res://world/buildings/cloudominium/"+dependency)
	navigation_revision += ":physical-lamp:"+FileAccess.get_md5("res://world/props/lamps/lamp.gd")
	navigation_revision += ":wagon:"+FileAccess.get_md5("res://world/buildings/trixie_wagon.gd")
	navigation_revision += ":zecora-hut:"+FileAccess.get_md5("res://world/buildings/zecora/zecora_hut.gd")+FileAccess.get_md5("res://world/buildings/zecora/assets/shell.glb")
	for dependency: String in ["cottage.gd", "cottage_home.gd", "geometry.json", "architecture.scn", "shell.res"]:
		navigation_revision += ":fluttershy:" + FileAccess.get_md5("res://world/buildings/fluttershy/" + dependency)
	navigation_revision += ":river-dock:"+FileAccess.get_md5("res://world/minigames/fishing/fishing_dock.gd")+FileAccess.get_md5("res://world/minigames/fishing/dock_spec.json")
	for prop: String in ["outdoor_props", "bench", "table", "streetlamp", "flowerbed", "daisy", "town_trees", "rnl_scenery", "pony_bed"]:
		var prop_path := "res://world/props/ponyville/"+prop+".scn"
		if FileAccess.file_exists(prop_path): navigation_revision += ":props:"+FileAccess.get_md5(prop_path)
	# The inherited placement defaults move collision without rebuilding the base scene.
	# Ponyville kit dressing blocks walking around houses, roads and lawns.
	navigation_revision += ":ponyville-kit:"+FileAccess.get_md5("res://world/props/ponyville_kit/placements.json")+FileAccess.get_md5("res://world/props/ponyville_kit/kit_dressing.gd")+FileAccess.get_md5("res://world/props/ponyville_kit/activity/fit.json")
	navigation_revision += ":scenery-defaults:"+FileAccess.get_md5("res://world/props/ponyville/rnl_scenery_defaults.tscn")
	for dependency: String in ["market_stalls.gd", "stalls/produce_collision.res", "stalls/bakery_collision.res", "stalls/pantry_collision.res", "stalls/goods_collision.res", "stalls/furniture_collision.res"]:
		navigation_revision += ":market:" + FileAccess.get_md5("res://world/shop/" + dependency)
	biomes = preload("res://world/biomes/biome_field.gd").new()
	add_to_group("world_terrain")
	# Terrain3D only accepts these once it is in the tree.
	half_res = _tier_texel_m() >= 2.0 and DirAccess.dir_exists_absolute(HALF_DATA_DIR) and not DirAccess.get_files_at(HALF_DATA_DIR).is_empty()
	var texels := TEXELS / 2 if half_res else TEXELS
	terrain.region_size = texels
	terrain.vertex_spacing = float(REGION) / float(texels)
	if half_res: navigation_revision += ":half-res"
	terrain.collision_layer = 1
	terrain.collision_mask = 0
	terrain.material.world_background = 0  # NONE: nothing outside the imported regions
	# Use Terrain3D's native cliff projection, including oblique hills (no custom
	# per-pixel noise/displacement or extra terrain render pass).
	terrain.material.set_shader_param("enable_projection", true)
	terrain.material.set_shader_param("projection_threshold", 0.85)
	_apply_quality(0)
	var quality := get_node_or_null("/root/Quality")
	if quality != null and not quality.preset_changed.is_connected(_apply_quality): quality.preset_changed.connect(_apply_quality)
	if quality != null and not quality.preset_changed.is_connected(_apply_window): quality.preset_changed.connect(_apply_window)
	terrain.assets = _build_assets()
	terrain.material.set_shader_param("macro_variation1", Color(0.90, 0.95, 0.86))
	terrain.material.set_shader_param("macro_variation2", Color(1.0, 0.98, 0.92))
	preload("res://world/terrain/gaea_material.gd").apply(terrain)
	if has_data():
		_region_files = _scan_regions(active_data_dir())
		window_m = _tier_window()
		if window_m > 0.0:
			print("[terrain] world terrain: %d regions on disk%s, window %.0f m (loaded on focus)" % [_region_files.size(), " (half-res)" if half_res else "", window_m])
		else:
			terrain.data_directory = active_data_dir()
			print("[terrain] world terrain: %d regions%s" % [terrain.data.get_region_count(), " (half-res)" if half_res else ""])
	biome_surfaces = preload("res://world/biomes/surface_store.gd").new(terrain)
	if not half_res: biome_surfaces.load_saved()  # baked into the half-res regions
	var vegetation_color: Node=load("res://world/foliage/vegetation_color_field.gd").new()
	vegetation_color.name="VegetationColor";add_child(vegetation_color);vegetation_color.bind(self)
	# Applied sculpt overlays load before collision/navigation; generated resources stay intact.
	var sculptor: Node = null
	if not half_res:  # the half-res regions carry the published sculpt already
		sculptor = load("res://tools/editor/terrain_sculptor.gd").new()
		sculptor.name = "TerrainSculptor"; add_child(sculptor); sculptor.bind(self, false)
	var sculpt_index := "res://world/terrain/sculpt/index.json"
	if FileAccess.file_exists(sculpt_index): navigation_revision += ":" + FileAccess.get_md5(sculpt_index)
	# Global WorldWater is outside each zone's mesh subtree. Its canal boundary
	# still changes dry-bank routes, so include its authored input in zone caches.
	navigation_revision += ":canals:" + FileAccess.get_md5("res://world/water/ponyville_canals.json")
	# Collision: heightmap shapes are cheap (4 MB per 1024 m region), so a small world or a
	# headless run (no camera for the dynamic window to follow) gets full collision; the big
	# world uses the dynamic window around the camera and the walk grid's height queries.
	var regions: int = terrain.data.get_region_count() if terrain.data != null else 0
	var headless := DisplayServer.get_name() == "headless"
	if not collision_enabled:
		terrain.collision_mode = 0  # DISABLED
	elif headless or (regions <= FULL_COLLISION_REGIONS and window_m <= 0.0):
		terrain.collision_mode = 3  # FULL_GAME
	else:
		terrain.collision_mode = 1  # DYNAMIC_GAME
	if not headless and not ("--biome-foliage-off" in preload("res://world/dev_tools.gd").user_args()):
		var foliage := preload("res://world/foliage/biome_foliage.gd").new()
		foliage.name = "BiomeFoliage"; add_child(foliage)
		if "--terrain-grass-off" not in preload("res://world/dev_tools.gd").user_args():
			var grass: Node = load("res://world/foliage/grass/ground_grass.gd").new()
			grass.name = "GroundGrass"; add_child(grass)
	var placed: Node = load("res://world/props/model_placements.gd").new()
	placed.terrain_data = terrain.data
	placed.name = "ModelPlacements"; add_child(placed)
	placed.bounds_changed.connect(_model_bounds_changed)
	if sculptor != null: sculptor.height_changed.connect(placed.refresh_surface_contacts)
	placed.load_saved(false); placed.sync()

func _model_bounds_changed(bounds: AABB) -> void:
	var area := Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))
	var grass := get_node_or_null("GroundGrass")
	if grass != null: grass.notify_terrain_changed(area)
	var foliage := get_node_or_null("BiomeFoliage")
	if foliage != null: foliage._rebuild_generated(area, 1.0)
	for service in get_tree().get_nodes_in_group("pony_navigation"):
		if service.has_method("notify_geometry_changed"): service.notify_geometry_changed(bounds)


## The tier's window. Read through Settings: Quality applies the stored preset deferred, after
## the world's own _ready has already needed the ground. Headless fixtures keep everything.
func _tier_window(preset_index: int = -1) -> float:
	# Lane memory 2026-11-21: fixtures and the picture pairs for a High window pass
	# --terrain-window=<metres> (0 = whole world); it wins over the tier, headless included.
	var forced := _forced_window()
	if forced >= 0.0: return forced
	if DisplayServer.get_name() == "headless": return 0.0
	var quality := get_node_or_null("/root/Quality")
	var settings := get_node_or_null("/root/Settings")
	if quality == null: return 0.0
	var index: int = preset_index if preset_index >= 0 else quality.preset
	if preset_index < 0 and settings != null:
		var names: Array = quality.PRESET_NAMES
		var stored := names.find(str(settings.get_value("video/quality")))
		if stored >= 0: index = stored
	return float(quality.CONFIG[index].get("terrain_window_m", 0.0))


static func _forced_window() -> float:
	for arg: String in preload("res://world/dev_tools.gd").user_args():
		if arg.begins_with("--terrain-window="): return maxf(0.0, float(arg.trim_prefix("--terrain-window=")))
	return -1.0


## Tier changed in-game: a window tier drops the far regions on the next focus; a
## whole-world tier loads everything back.
func _apply_window(preset: int) -> void:
	var wanted := _tier_window(preset)
	if is_equal_approx(wanted, window_m): return
	window_m = wanted
	_window_center = Vector2i(1 << 20, 1 << 20)
	if window_m <= 0.0 and terrain.data != null:
		var missing: Array = []
		for loc in _region_files:
			if not terrain.data.has_region(loc): missing.append(loc)
		if not missing.is_empty():
			_load_regions(missing)
			terrain.data.update_maps(); _apply_overlays(missing); regions_loaded.emit(missing)
		print("[terrain] whole world resident: %d regions" % terrain.data.get_region_count())
	_window_poll = 0.0


func _process(delta: float) -> void:
	if window_m <= 0.0: return
	_window_poll -= delta
	if _window_poll > 0.0: return
	_window_poll = WINDOW_POLL
	var manager := get_node_or_null("/root/ZoneManager")
	var anchor: Node3D = manager.anchor if manager != null and "anchor" in manager else null
	if is_instance_valid(anchor) and anchor.is_inside_tree(): focus(anchor.global_position)


## Loads the regions within the window around `pos` and drops the ones beyond it plus the
## slack. Synchronous: a 1 km crossing on Very Low swaps about a ring of regions. No-op
## while the whole world is resident.
func focus(pos: Vector3) -> void:
	if window_m <= 0.0 or terrain.data == null: return
	var center := Vector2i(floori(pos.x / float(REGION)), floori(pos.z / float(REGION)))
	if center == _window_center: return
	_window_center = center
	var at := Vector2(pos.x, pos.z)
	var removed := 0
	var t0 := Time.get_ticks_usec()
	for loc in terrain.data.get_region_locations():
		if _region_distance(loc, at) > window_m + WINDOW_SLACK:
			terrain.data.remove_regionl(loc, false); removed += 1
			_forget(loc)
	# Removal updates the location list immediately. has_region() still consults
	# the old numeric region IDs until update_maps() rebuilds their index.
	var resident: Array = terrain.data.get_region_locations()
	var added: Array = []
	for loc in _region_files:
		if _region_distance(loc, at) <= window_m and not resident.has(loc):
			added.append(loc)
	if added.is_empty() and removed == 0: return
	_load_regions(added)
	var t1 := Time.get_ticks_usec()
	# Deleted regions keep their CPU maps for the editor's save path; the game never saves.
	var all: Dictionary = terrain.data.get_regions_all()
	for loc in all.keys():
		var region: Object = all[loc]
		if region != null and region.has_method("is_deleted") and region.is_deleted(): all.erase(loc)
	terrain.data.update_maps()
	var t2 := Time.get_ticks_usec()
	if not added.is_empty(): _apply_overlays(added)
	var t3 := Time.get_ticks_usec()
	var collision: Object = terrain.get_collision() if terrain.has_method("get_collision") else null
	if collision != null and collision.has_method("update"): collision.update(true)
	var t4 := Time.get_ticks_usec()
	print("[terrain] window at %s: %d regions resident (+%d -%d)" % [center, terrain.data.get_region_count(), added.size(), removed])
	regions_loaded.emit(added)
	# Lane memory 2026-11-21: what one window move costs, by stage (read by fixtures).
	window_stats = {"moves": int(window_stats.get("moves", 0)) + 1, "added": added.size(), "removed": removed,
		"regions": terrain.data.get_region_count(), "load_ms": (t1 - t0) / 1000.0, "update_maps_ms": (t2 - t1) / 1000.0,
		"overlays_ms": (t3 - t2) / 1000.0, "collision_ms": (t4 - t3) / 1000.0, "signal_ms": (Time.get_ticks_usec() - t4) / 1000.0}


## Decode independent resources on the pool. Terrain3D owns installation, in
## the same region order as its synchronous load_region() path.
func _load_regions(locations: Array) -> void:
	var folder := active_data_dir()
	if locations.is_empty(): return
	if not _parallel_loads or locations.size() == 1:
		for loc: Vector2i in locations: terrain.data.load_region(loc, folder, false)
		return
	var first := 0
	if _region_version < 0.0:
		# Let this build of Terrain3D establish its region format and size.
		var loc: Vector2i = locations[0]
		terrain.data.load_region(loc, folder, false)
		var seed_region: Object = terrain.data.get_region(loc)
		if seed_region != null: _region_version = seed_region.get_version()
		first = 1
	for start in range(first, locations.size(), REGION_LOAD_BATCH):
		var count := mini(REGION_LOAD_BATCH, locations.size() - start)
		var paths := PackedStringArray()
		var decoded: Array[Resource] = []
		decoded.resize(count)
		for i in count:
			paths.append(folder.path_join(_region_files[locations[start + i]]))
		var job := -1
		if count > 1:
			job = WorkerThreadPool.add_group_task(_decode_region.bind(paths, decoded, 1), count - 1, -1, true, "Terrain region load")
		_decode_region(0, paths, decoded, 0)
		if job >= 0: WorkerThreadPool.wait_for_group_task_completion(job)
		for i in count:
			var loc: Vector2i = locations[start + i]
			var region: Resource = decoded[i]
			if _region_version < 0.0 or region == null or region.get_region_size() != terrain.region_size:
				terrain.data.load_region(loc, folder, false)
				continue
			region.take_over_path(paths[i])
			region.set_location(loc)
			region.set_version(_region_version)
			terrain.data.add_region(region, false)


static func _decode_region(index: int, paths: PackedStringArray, decoded: Array[Resource], offset: int) -> void:
	var i := index + offset
	decoded[i] = ResourceLoader.load(paths[i], "Terrain3DRegion", ResourceLoader.CACHE_MODE_IGNORE)


## Sculpt heights, authored biome controls, prop contacts and walk-grid columns for regions
## that just came in; nothing else knows a region was missing before.
func _apply_overlays(locations: Array) -> void:
	var sculptor := get_node_or_null("TerrainSculptor")
	if sculptor != null: sculptor.load_saved(false, locations)
	if biome_surfaces != null and not half_res: biome_surfaces.load_saved(false, locations)
	var placed := get_node_or_null("ModelPlacements")
	if placed != null and placed.has_method("refresh_surface_contacts"): placed.refresh_surface_contacts()
	for service in get_tree().get_nodes_in_group("pony_navigation"):
		if not service.has_method("notify_geometry_changed"): continue
		for loc in locations:
			service.notify_geometry_changed(AABB(Vector3(loc.x * REGION, -10000, loc.y * REGION), Vector3(REGION, 20000, REGION)))


func _forget(loc: Vector2i) -> void:
	var sculptor := get_node_or_null("TerrainSculptor")
	if sculptor != null and sculptor.has_method("forget"): sculptor.forget(loc)
	if biome_surfaces != null: biome_surfaces.forget(loc)


## Metres from `at` to the nearest edge of region `loc` (0 inside it).
static func _region_distance(loc: Vector2i, at: Vector2) -> float:
	var origin := Vector2(loc.x * REGION, loc.y * REGION)
	var nearest := Vector2(clampf(at.x, origin.x, origin.x + REGION), clampf(at.y, origin.y, origin.y + REGION))
	return at.distance_to(nearest)


## Terrain3D names regions terrain3d_XX_YY.res, with "-" replacing the separator before a
## negative coordinate: terrain3d_00-01.res is (0, -1).
func active_data_dir() -> String:
	return HALF_DATA_DIR if half_res else DATA_DIR


## The tier's terrain texel size in metres (1 full, 2 half-res), read like the window.
func _tier_texel_m() -> float:
	if DisplayServer.get_name() == "headless": return 1.0
	var quality := get_node_or_null("/root/Quality")
	var settings := get_node_or_null("/root/Settings")
	if quality == null: return 1.0
	var index: int = quality.preset
	if settings != null:
		var names: Array = quality.PRESET_NAMES
		var chosen := str(settings.get_value("video/quality"))
		var stored := names.find(str(settings.get_value("video/quality_base")) if chosen == "Custom" else chosen)
		if stored >= 0: index = stored
	return float(quality.CONFIG[index].get("terrain_texel_m", 1.0))


static func _scan_regions(dir: String = DATA_DIR) -> Dictionary:
	var found := {}
	var pattern := RegEx.create_from_string("^terrain3d([_-])(\\d+)([_-])(\\d+)\\.res$")
	for file in DirAccess.get_files_at(dir):
		var m := pattern.search(file)
		if m == null: continue
		var x := int(m.get_string(2)) * (-1 if m.get_string(1) == "-" else 1)
		var y := int(m.get_string(4)) * (-1 if m.get_string(3) == "-" else 1)
		found[Vector2i(x, y)] = file
	return found


func _exit_tree() -> void:
	if instance == self:
		instance = null


func _build_assets() -> Object:
	var assets: Object = ClassDB.instantiate("Terrain3DAssets")
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEXTURES))
	if not (doc is Dictionary):
		return assets
	var list: Array = []
	# Terrain3D needs one compressed format for every layer: once any layer carries a painted
	# height (DXT5), the others get a flat mid height instead of opaque alpha (DXT1).
	var any_height := false
	for entry in doc.get("textures", []):
		any_height = any_height or bool(entry.get("height_alpha", false))
	for entry in doc.get("textures", []):
		var asset: Object = ClassDB.instantiate("Terrain3DTextureAsset")
		asset.name = String(entry.name)
		asset.id = int(entry.id)
		asset.uv_scale = float(entry.get("uv_scale", 0.1))
		var tint: Array = entry.get("albedo_color", [1.0, 1.0, 1.0])
		asset.albedo_color = Color(float(tint[0]), float(tint[1]), float(tint[2]))
		asset.detiling_rotation = float(entry.get("detiling_rotation", 0.0))
		asset.detiling_shift = float(entry.get("detiling_shift", 0.0))
		asset.albedo_texture = _load_albedo(String(entry.file), bool(entry.get("height_alpha", false)), any_height)
		# Terrain3D otherwise generates a raw RGBA8 flat normal per layer (5 MB each, 22 layers).
		asset.normal_texture = _flat_normal()
		list.append(asset)
	assets.set_texture_list(list)
	return assets


## Terrain3D packs every albedo into one texture array, so all of them must share one size
## and carry mipmaps. The native layer textures are mixed sizes without mipmaps, so they are
## loaded as images, resized and mipmapped here rather than through the import pipeline.
const ALBEDO_SIZE := 1024


func _load_albedo(path: String, height_alpha := false, flat_height := false) -> Texture2D:
	var image := preload("res://world/resource_image.gd").read(path)
	if image == null:
		push_warning("[terrain] missing texture %s" % path)
		image = Image.create(ALBEDO_SIZE, ALBEDO_SIZE, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.4, 0.6, 0.3))
	if image.is_compressed():
		image.decompress()
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	# Terrain3D reads the albedo alpha as a height/blend channel; native textures with a stray
	# alpha (or none) must not turn black. Painted layers carry a real height (height_alpha).
	if not height_alpha:
		image.convert(Image.FORMAT_RGB8)
		image.convert(Image.FORMAT_RGBA8)
		if flat_height:
			var data := image.get_data()
			for i in range(3, data.size(), 4): data[i] = 128
			image.set_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, data)
	if image.get_width() != ALBEDO_SIZE or image.get_height() != ALBEDO_SIZE:
		image.resize(ALBEDO_SIZE, ALBEDO_SIZE, Image.INTERPOLATE_LANCZOS)
	# Every layer must share one format: DXT5 keeps the alpha height channel and costs a
	# quarter of RGBA8 in the packed array and in the kept source texture.
	return preload("res://world/resource_image.gd").upload(image)


static var _flat_normal_texture: ImageTexture


## One shared flat normal (alpha = roughness 1, Terrain3D's own default) in the albedo's
## size and DXT5 format, so the normal array packs compressed like the albedo array.
static func _flat_normal() -> ImageTexture:
	if _flat_normal_texture == null:
		var image := Image.create(ALBEDO_SIZE, ALBEDO_SIZE, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.5, 0.5, 1.0, 1.0))
		_flat_normal_texture = preload("res://world/resource_image.gd").upload(image)
	return _flat_normal_texture


## Ground height at a world position, NAN where no region exists.
func height_at(pos: Vector3) -> float:
	if terrain.data == null:
		return NAN
	return terrain.data.get_height(pos)


func normal_at(pos: Vector3) -> Vector3:
	if terrain.data == null:
		return Vector3.UP
	var n: Vector3 = terrain.data.get_normal(pos)
	return n if n.is_finite() and n.length_squared() > 0.5 else Vector3.UP


func has_ground(pos: Vector3) -> bool:
	return is_finite(height_at(pos))


## Terrain3D clipmap detail from the quality tier: mesh_size (vertices per clipmap ring, 48
## default, Low 32, Very Low 16), mesh_lods (7, Very Low 6) and the triplanar cliff projection
## (off on Very Low). The region maps stay resident whatever the tier (docs/PERFORMANCE_TIERS_2026_09_29.md).
func _apply_quality(_preset: int) -> void:
	var quality := get_node_or_null("/root/Quality")
	if quality == null or terrain == null: return
	var size := int(quality.get_value("terrain_mesh_size", 48))
	var lods := int(quality.get_value("terrain_mesh_lods", 7))
	if "mesh_size" in terrain and int(terrain.mesh_size) != size: terrain.mesh_size = size
	if "mesh_lods" in terrain and int(terrain.mesh_lods) != lods: terrain.mesh_lods = lods
	if terrain.material != null: terrain.material.set_shader_param("enable_projection", bool(quality.get_value("terrain_projection", true)))
