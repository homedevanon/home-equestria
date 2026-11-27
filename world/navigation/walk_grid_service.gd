class_name WalkGridService
extends Node3D
## Physics sampling stays on the main thread with a wall-time budget. Search
## sees immutable array snapshots on one worker; completed results carry revisions.
signal navigation_ready
signal navigation_failed(message: String)
signal rebuild_started
## 8 (2026-11-19): town house roofs and attics became navigation ceilings (house_nav_ceiling.gd);
## the town's houses are not in a zone's collider hashes, so cached chunks would keep them as floor.
const CACHE_VERSION := 8
const WATER_MASK := 1 << 15
## Resident chunks, ~250 KB each (arrays + published view): 384 is ~95 MB and holds a
## ~300 m town; 128 thrashed Ponyville's working set. One route still asks for at most
## ROUTE_CHUNKS, so the planner's reach is unchanged. Desktop keeps 768 (~190 MB): at 384 the
## town still evicted and reloaded chunks every step, 0.8 ms per physics step with a warm cache
## (2026-10-23 CPU pass). Quest keeps 384 for its memory.
const MAX_CHUNKS := 384
var max_chunks := MAX_CHUNKS if OS.has_feature("android") else MAX_CHUNKS * 2
const ROUTE_CHUNKS := 128
## Route choice from modChad's Pathfinding Fix 1.1.0 (ported 2026-11-20). The coarse chunk corridor
## scores every 16 m chunk alike, and the exact search then stays inside that band, so a road just
## outside it is never used. With OPEN_ROUTES a route up to corridor_off_m searches every resident
## chunk with a larger budget; one that runs out of budget is asked once more inside the corridor.
## A failed route also grows its chunk set by expand_step per retry up to route_chunks (was 12 and
## ROUTE_CHUNKS), so a way round a river needs fewer searches. A quality tier that lowered the
## search limit keeps the corridor. false = routing as before.
const OPEN_ROUTES := false
const OPEN_ROUTES_DESKTOP := {"corridor_off_m": 200.0, "open_limit": 400000, "expand_step": 32, "route_chunks": ROUTE_CHUNKS * 2}
const OPEN_ROUTES_QUEST := {"corridor_off_m": 80.0, "open_limit": 150000, "expand_step": 24, "route_chunks": ROUTE_CHUNKS}
const BUDGET_REASON := "Search budget reached"
const SAMPLE_BUDGET_US := 1000
## Share of the slice for speculative sampling while no route or spawn waits (2026-10-23 CPU pass:
## a cold cache burnt the full 1 ms on every physics step for minutes after load).
const IDLE_BUDGET_SHARE := 0.3
## Old caches of this zone (terrain or zone edits make a new one) are removed after this long
## unused; the dev's folder had 339 of them, 12 GB.
const STALE_CACHE_DAYS := 3
## Chunks a spawn is waiting on (game.gd _scatter_spots); sampled with the boosted budget.
var urgent: Array[Vector2i] = []
var grid := WalkGrid.new()
var layers: MapLayers
var ready_for_paths := false
var baking := false
var _dirty := false
var revision := 0
var statistics := {}
## Worker searches since start, by outcome, for profiling (statistics.searches).
var search_counts := {"path":0,"wander":0,"retry":0,"stale":0,"cancelled":0,"busy_ms":0.0,"native":0,"native_cpu_ms":0.0,"native_wander":0,"concurrent_peak":0}
## Route search expansion cap from the quality tier (quality.gd nav_search_limit), read when a
## search starts so a tier change applies to the next route.
var _search_limit := WalkPlanner.LIMIT
var _search_started := 0
var zone_id := ""
var bounds := AABB()
var _content: Node3D
var _queue: Array[Vector2i] = []
var _column := 0
var _blockers := {}
var _dynamic_chunks: Dictionary = {}
var _cache_dir := ""
var _jobs: Array[Dictionary] = []
var _active: Dictionary = {}
var _worker := -1
var preset_geometry: Dictionary = {}
var _next_request := 0
var _pending_result := {}
var _water_body: StaticBody3D
var _paint_stamp := ""
var _paint_timer := 0.0
var _ray := PhysicsRayQueryParameters3D.new()
## dev 2026-10-20 multithreading: _sample_column() in C++ (pony_column_sampler.h), still on the main
## thread: Godot 4.5 gives only the main thread a space's direct state, and Jolt queries do not lock
## bodies. One-line rollback: NATIVE_COLUMNS = false.
const NATIVE_COLUMNS := true
var _column_sampler: RefCounted = ClassDB.instantiate("PonyColumnSampler") if NATIVE_COLUMNS and ClassDB.class_exists("PonyColumnSampler") else null
## Perf trial grid_parallel (2026-11-24): the sampler on all cores (pony_column_parallel.cpp), --try=grid_parallel.
const TRY := preload("res://world/perf/try_switch.gd")
var _volume := PhysicsShapeQueryParameters3D.new()
var _room_cache := {}
var _cancelled := {}
var generation := 0
var _paint_queue: Array[Vector2i] = []
var _paint_column := 0
var _io_queue: Array[Dictionary] = []
var _io_job := {}
var _io_worker := -1
var _prune_worker := -1
var _prune_cancel: Array = [false]
var _terrain_paths = preload("res://world/navigation/terrain_paths.gd").new()
var _io_loaded: WalkChunk
## Derived copies are keyed on everything _apply_paint reads (see _derived_path); a live
## terrain control edit turns them off for the session.
var _derive_cache := true
var _derive_base := ""
var _derive_regions := {}
## Chunks sampled while a house door was open; never cached, resampled once it shuts.
var _door_tainted := {}
## Perf overhaul 2026-11-21 (lane walk_grid): each chunk's cache file carries its own key
## (walk_grid_keys.gd: the static shapes under it, the ray range, the terrain texels under it), so
## a release, a mod or a placed house resamples only the chunks whose ground changed. One file per
## coordinate in user://navigation/walkgrid/<zone>_chunks/. The key is taken when a chunk is
## admitted and again when its sampling ends; a chunk is saved only under the key its samples were
## taken with. Keys come from a registry of static bodies kept up to date through SceneTree
## node_added / node_removed (version 2: a memoised digest, tens of microseconds; version 1's
## physics query per key cost 6 to 24 ms in house chunks and regressed the A/B round).
## Rollback: CHUNK_KEYS = false (the old folder hash); `-- --walk-grid-keys=on|off` overrides it
## for one launch (A/B and the proofs).
const CHUNK_KEYS := true
static var chunk_keys: bool = _chunk_keys_wanted()
static func _chunk_keys_wanted() -> bool:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--walk-grid-keys="): return arg.ends_with("=on")
	return CHUNK_KEYS
const KEYS := preload("res://world/navigation/walk_grid_keys.gd")
var _keys: RefCounted = KEYS.new() if chunk_keys else null
## Admitted chunks waiting for their key (state QUEUED until keyed and looked up).
var _key_queue: Array[Vector2i] = []
## Key of each resident chunk's current samples ("" = not keyable, never cached).
var _chunk_keys: Dictionary = {}
## Keys of chunks evicted this session, reused when they come back (no physics query); dropped
## for any area a late collider, notify_geometry_changed or a blocker touches.
var _session_keys: Dictionary = {}
## Chunks resampled once because their key changed while they were sampled.
var _key_retried: Dictionary = {}
## Baked town chunks (walk_grid_bake.gd), {coord: [key, offset, size]}; empty when none ship.
## Rollback: BAKED_GRID = false.
const BAKED_GRID := true
const RESIDENT_BAKED := true
## _evict(): chunks of every queued route are kept while an unrouted chunk can go.
const PROTECT_ROUTES := true
const BAKE := preload("res://world/navigation/walk_grid_bake.gd")
var _baked: Dictionary = {}
var _baked_path := ""
## Counters for the log line ("[walk-grid] <zone> sampling ..." / "quiet ...").
var _counts := {"sampled": 0, "loaded": 0, "derived_loaded": 0, "baked": 0, "keyed": 0}
var _was_sampling := false
var _sampling_since := 0
## Admission time (msec) of chunks not yet READY, and the first READY_LOG admission-to-ready
## times with their source, for the "how soon is the ground there" question (statistics.ready).
var _admitted_at: Dictionary = {}
var _ready_log: Array = []
const READY_LOG := 400
## Late colliders: a static body entering or leaving the tree (an interior streamed in, a house
## placed or given, a mod's building) is (re)registered with the key registry; resident chunks its
## bounds touch get a fresh key, and a chunk whose key changed is resampled. Bodies moved in place
## are not seen here; their owners call notify_geometry_changed() as before.
## Rollback: LATE_COLLIDERS = false (the registry then only knows the bodies present at start).
const LATE_COLLIDERS := true
var _rekey: Dictionary = {}
## Main-thread floor for registering bodies while the registry is behind (keys wait on it).
const REGISTER_MIN_US := 400
## Native route search (`-- --native-navigation search`, native_navigation_backend.gd). One
## search still runs at a time per service; while it runs natively, _native_busy stands in for
## _worker. The legacy WalkPlanner stays the default and answers wander searches either way.
const NATIVE_BACKEND := preload("res://world/navigation/native_navigation_backend.gd")
var _native_world := -1
## Published chunk views by coord (a view is replaced, never edited, on every revision).
var _native_views: Dictionary = {}
var _native_synced: Dictionary = {}
## Native actor handle [slot, generation] per requester instance id.
var _native_actors: Dictionary = {}
var _native_busy := false
var _native_handle := PackedInt64Array()
var _native_generation := 0

static func bake(content: Node3D, cfg: Dictionary = {}, preset: Dictionary = {}) -> Node3D:
	var service := WalkGridService.new()
	service.name = "Navigation"
	service._content = content
	service.preset_geometry = preset
	service.zone_id = str(cfg.get("id", content.name)).to_lower()
	content.add_child(service)
	return service

func _ready() -> void:
	add_to_group("pony_navigation")
	# ZoneManager has already installed the final zone transform before _ready.
	if get_parent().get_parent() != null and str(get_parent().get_parent().name).begins_with("Zone_"):
		zone_id = str(get_parent().get_parent().name).trim_prefix("Zone_")
	layers = MapLayers.load_zone(zone_id)
	if is_instance_valid(WorldTerrain.instance):
		var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(WorldTerrain.TEXTURES))
		_terrain_paths.bind(WorldTerrain.instance.terrain.data, doc.get("textures", []))
		if WorldTerrain.instance.biome_surfaces != null:
			WorldTerrain.instance.biome_surfaces.controls_changed.connect(_terrain_controls_changed)
	_ray.collision_mask = 1
	_ray.hit_back_faces = true
	_volume.collision_mask = 1
	var shape := CylinderShape3D.new()
	shape.radius = WalkGrid.CELL*.72
	shape.height = .20
	_volume.shape = shape
	if _column_sampler != null and TRY.on("grid_parallel") and _column_sampler.has_method(&"set_parallel"): _column_sampler.set_parallel(true)
	_setup_geometry()
	_draw_window_setup()
	if chunk_keys:
		_keys.mask = 1 | WATER_MASK
		_keys.limits = bounds
		_keys.scan(get_tree().root)
		if LATE_COLLIDERS:
			get_tree().node_added.connect(_collider_added)
			get_tree().node_removed.connect(_collider_removed)
	ready_for_paths = true
	navigation_ready.emit()

## World AABB and cache signature of one collider, or [] when it does not block walking.
## Thousands of trimesh colliders per zone: the parent mesh's AABB is free, a debug mesh per
## shape costs ~0.2 ms each (1.4 s for the Heartland), and hashing the face arrays ~0.2 s;
## the scene file's mtime (added by _setup_geometry) covers geometry edits instead.
static func collider_signature(col: CollisionShape3D) -> Array:
	var body := col.get_parent() as CollisionObject3D
	if col.disabled or col.shape == null or body == null or not (body.collision_layer & 1): return []
	var parent_mesh := body.get_parent() as MeshInstance3D
	var box: AABB
	var signature: Variant
	if col.shape is ConcavePolygonShape3D and parent_mesh != null and parent_mesh.mesh != null:
		box = parent_mesh.global_transform * parent_mesh.mesh.get_aabb()
		signature = (col.shape as ConcavePolygonShape3D).data.size()
	else:
		box = col.global_transform * col.shape.get_debug_mesh().get_aabb()
		var shape_properties := {}
		for property in col.shape.get_property_list():
			if property.usage & PROPERTY_USAGE_STORAGE:
				var value: Variant = col.shape.get(property.name)
				if not value is Object: shape_properties[property.name] = hash(value)
		signature = shape_properties
	var parts: Array = [col.global_transform,col.shape.get_class(),signature]
	# Only opted-in shells change their cache signature; ordinary terrain caches remain valid.
	if body.get_meta("navigation_ceiling", false): parts.append("ceiling_not_walkable_v1")
	return [box,parts]

## ZoneManager attaches the colliders one by one and can hand over their merged AABB and
## signatures (`preset` = {bounds, hashes}) so a 8k-collider zone does not spend 60 ms here.
func _setup_geometry() -> void:
	var hashes := []
	var has_bounds := false
	if not preset_geometry.is_empty():
		has_bounds = preset_geometry.has("bounds")
		if has_bounds: bounds = preset_geometry.bounds
		hashes = preset_geometry.hashes.duplicate()
	else:
		for node in _content.find_children("*","CollisionShape3D",true,false):
			var sig := collider_signature(node as CollisionShape3D)
			if sig.is_empty(): continue
			bounds = bounds.merge(sig[0]) if has_bounds else sig[0]
			has_bounds = true
			hashes.append(sig[1])
	if _content.scene_file_path != "": hashes.append([_content.scene_file_path,FileAccess.get_modified_time(_content.scene_file_path)])
	if not has_bounds: bounds = AABB(Vector3(-128,-32,-128),Vector3(256,96,256))
	_water_body = StaticBody3D.new()
	_water_body.name = "NavigationWaterSamples"
	_water_body.collision_layer = WATER_MASK
	_water_body.collision_mask = 0
	add_child(_water_body)
	# Water is tagged by the zone processor (group navigation_water, saved in the bake); the
	# shader check only confirms it. Walking every mesh's materials cost 20+ ms per zone.
	for node in get_tree().get_nodes_in_group("navigation_water"):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null or not _content.is_ancestor_of(mi): continue
		var col := CollisionShape3D.new()
		col.shape = mi.mesh.create_trimesh_shape()
		_water_body.add_child(col)
		col.global_transform = mi.global_transform
		hashes.append([mi.global_transform,hash(mi.mesh.get_faces())])
	# Some columns fall back to Terrain3D when detailed physics is unloaded. Tie those
	# persisted samples to the terrain import, while leaving collision-only fixtures alone.
	if is_instance_valid(WorldTerrain.instance) and WorldTerrain.instance.navigation_revision != "":
		hashes.append(["world_terrain", WorldTerrain.instance.navigation_revision])
	_cache_dir = "user://navigation/walkgrid/%s_%s" % [zone_id,var_to_bytes([CACHE_VERSION,hashes]).hex_encode().sha256_text()]
	# Per-chunk keys: one folder per zone. The old whole-zone hash folders are no longer written,
	# so the stale-folder prune below removes them once untouched for STALE_CACHE_DAYS, as it did
	# before. `-- --keep-walkgrid-folders` skips the prune for one launch (A/B rounds against an
	# older build that still reads those folders).
	if chunk_keys: _cache_dir = "user://navigation/walkgrid/%s_chunks" % zone_id
	if chunk_keys and BAKED_GRID and not ("--no-baked-walk-grid" in OS.get_cmdline_user_args()):
		_baked_path = BAKE.path_for(zone_id)
		_baked = BAKE.read_index(_baked_path, KEYS.KEY_VERSION)
	# A town shipped baked stays resident on desktop: the cap covers its whole footprint, so a chunk
	# loaded once is never evicted and reloaded while routes cross the town (the crowd spot of the
	# 2026-11-21 whole-game rounds evicted and reloaded about one chunk a step at the 768 cap, and
	# each change re-snapshot and re-synced the native grid). Costs about 125 KB a chunk held
	# (walk_grid.md has the measured figure). The Quest keeps its cap. Rollback:
	# RESIDENT_BAKED = false, or `-- --walk-grid-resident=off` for one launch.
	if RESIDENT_BAKED and not _baked.is_empty() and not OS.has_feature("android") \
			and not ("--walk-grid-resident=off" in OS.get_cmdline_user_args()):
		var a := WalkGrid.chunk_of(WalkGrid.column(bounds.position))
		var b := WalkGrid.chunk_of(WalkGrid.column(bounds.end))
		max_chunks = maxi(max_chunks, (b.x - a.x + 1) * (b.y - a.y + 1) + 64)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_cache_dir))
	if _prune_worker < 0 and not ("--keep-walkgrid-folders" in OS.get_cmdline_user_args()):
		_prune_worker = WorkerThreadPool.add_task(_prune_stale.bind(ProjectSettings.globalize_path("user://navigation/walkgrid"),
			zone_id + "_", _cache_dir.get_file(), Time.get_unix_time_from_system() - STALE_CACHE_DAYS * 86400.0, _prune_cancel), false, "Walk grid cache prune")
	_paint_stamp = _paint_signature()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_cache_dir.path_join("derived")))
	_derive_base = _derive_signature()

var _quality_node: Node

func _physics_process(delta: float) -> void:
	_poll_io()
	_paint_timer -= delta
	if _paint_timer <= 0.0:
		_paint_timer = 2.0
		var stamp := _paint_signature()
		if stamp != _paint_stamp: _paint_stamp = stamp; reload_layers()
	var start := Time.get_ticks_usec()
	var count := 0
	# The Quality autoload is looked up once (it lives as long as the tree), not every physics tick.
	if not is_instance_valid(_quality_node): _quality_node = get_node_or_null("/root/Quality")
	var quality_node := _quality_node
	var base_budget: int = int(quality_node.get_value("nav_sample_budget_us", SAMPLE_BUDGET_US)) if quality_node != null else SAMPLE_BUDGET_US
	# A route waiting on unsampled chunks gets those chunks first and a larger slice of
	# the tick: a follower must not stand for seconds while fresh ground is measured.
	var budget := base_budget
	if _jobs.is_empty() and urgent.is_empty(): budget = int(base_budget * IDLE_BUDGET_SHARE)
	# Spawn placement names the chunks it is waiting on; they behave like a waiting route.
	if not urgent.is_empty():
		urgent.assign(urgent.filter(func(c): return not grid.chunks.has(c) or grid.chunks[c].state != WalkChunk.State.READY))
	# Any waiting route or spawn whose own chunks still need sampling or painting this tick.
	var route_work := false
	if not _jobs.is_empty() or not urgent.is_empty():
		var wanted: Array[Vector2i] = []
		var deriving: Array[Vector2i] = []
		var keying: Array[Vector2i] = []
		for c in (urgent if _jobs.is_empty() else _jobs[0].chunks):
			if not grid.chunks.has(c): continue
			if grid.chunks[c].state == WalkChunk.State.SAMPLING and c in _queue: wanted.append(c)
			elif grid.chunks[c].state == WalkChunk.State.DERIVING and c in _paint_queue: deriving.append(c)
			elif grid.chunks[c].state == WalkChunk.State.QUEUED and c in _key_queue: keying.append(c)
		# Player follows/commands/approaches, spawns: request_path queues them first.
		var urgent_job := _jobs.is_empty() or bool(_jobs[0].get("priority", false))
		route_work = not wanted.is_empty() or not deriving.is_empty() or not keying.is_empty()
		if not keying.is_empty():
			if urgent_job: budget = base_budget * 6
			for c in keying: _key_queue.erase(c)
			_key_queue = keying + _key_queue
		if not deriving.is_empty():
			if urgent_job: budget = base_budget * 6
			# Keep partial progress, then finish chunks needed by the oldest route
			# before unrelated disk-cache loads and speculative sampling.
			var partial: Array[Vector2i] = []
			if _paint_column > 0: partial.append(_paint_queue[0])
			for c in deriving: _paint_queue.erase(c)
			for c in partial: deriving.erase(c); _paint_queue.erase(c)
			_paint_queue = partial + deriving + _paint_queue
		# The 6x slice only while the waiting route's own chunks need work.
		# Unrelated chunks stay at the base budget: with 40 wandering mares a
		# job was always pending and every tick burnt the full 6 ms here (2026-09-17).
		if not wanted.is_empty():
			# A follower's route or a spawn earns the slice; autonomous trips, wanders and
			# route certification do not: one was always waiting and every tick burnt 6 ms.
			if urgent_job:
				budget = base_budget * 6
			if _queue[0] not in wanted:
				var partial: Array[Vector2i] = []
				if _column > 0: partial.append(_queue[0])
				for c in wanted: _queue.erase(c)
				for c in partial: wanted.erase(c); _queue.erase(c)
				_queue = partial + wanted + _queue
	# Only speculative chunks queued (the waiting routes' own ground is done or not admitted yet):
	# the idle share, as with no route at all (W1/W2-PERF-STEP-OTHER: 466-694 us a step here, about
	# 55% of all non-pony script time, spent on wander ground while a route waited elsewhere).
	if not route_work: budget = mini(budget, int(base_budget * IDLE_BUDGET_SHARE))
	# Register static bodies that came or went; resident chunks they touch get a fresh key, and a
	# changed key resamples them.
	if chunk_keys and _keys.busy():
		_keys.advance(maxi(start + budget, Time.get_ticks_usec() + REGISTER_MIN_US))
	if chunk_keys:
		for c: Vector2i in _keys.take_changed():
			_session_keys.erase(c)
			if _chunk_keys.has(c): _rekey[c] = true
	while chunk_keys and not _keys.busy() and not _rekey.is_empty() and Time.get_ticks_usec()-start < budget:
		var coord: Vector2i = _rekey.keys()[0]
		_rekey.erase(coord)
		if grid.chunks.has(coord) and _chunk_keys.has(coord): _check_key(coord)
	# Key admitted chunks (a memoised digest each), then look them up on disk. Keys wait while the
	# registry has bodies to read.
	while not _key_queue.is_empty() and Time.get_ticks_usec()-start < budget and (not _keys.busy() or _session_keys.has(_key_queue[0])):
		var coord: Vector2i = _key_queue.pop_front()
		if not grid.chunks.has(coord) or grid.chunks[coord].state != WalkChunk.State.QUEUED: continue
		if _session_keys.has(coord):
			_chunk_keys[coord] = _session_keys[coord]
		else:
			_chunk_keys[coord] = _chunk_key(coord)
			_counts.keyed += 1
		_admit_keyed(coord, grid.chunks[coord], STAGE_DERIVED)
	# Publish sampled ground before sampling more. A busy town keeps _queue
	# nonempty for minutes; spending the whole slice there starves DERIVING
	# chunks, so every resident waits despite the ground already being sampled.
	var paint_from := Time.get_ticks_usec()
	while not _paint_queue.is_empty() and Time.get_ticks_usec()-start < budget:
		var coord := _paint_queue[0]
		var chunk: WalkChunk = grid.chunks[coord]
		if PAINT_RUNS:
			_paint_column += _apply_paint_run(chunk, _paint_column, start + budget)
		else:
			_apply_paint(chunk,_paint_column)
			_paint_column += 1
		if (layers.rasters.is_empty() and not chunk.painted and not is_instance_valid(_terrain_paths.data)) or _paint_column == WalkGrid.CHUNK_CELLS*WalkGrid.CHUNK_CELLS:
			chunk.painted = not layers.rasters.is_empty()
			chunk.state = WalkChunk.State.READY
			_note_ready(coord, "baked" if chunk.has_meta("baked") else ("loaded" if chunk.from_cache else "sampled"))
			_counts["painted"] = int(_counts.get("painted", 0)) + 1
			chunk.last_used_frame = Engine.get_physics_frames()
			if _derive_cache and _blockers.is_empty() and not _dynamic_blocks(coord) and not _door_tainted.has(coord):
				if not chunk_keys:
					_io_queue.append({"kind":"save","chunk":chunk.cache_copy(),"coord":coord,"path":_derived_path(coord)})
				elif str(_chunk_keys.get(coord, "")) != "":
					var derived_copy := chunk.cache_copy()
					var derive_key := _derive_key(coord, str(_chunk_keys[coord]))
					derived_copy.set_meta("cache_key", derive_key)
					_io_queue.append({"kind":"save","chunk":derived_copy,"coord":coord,"path":_keyed_path(coord, true, derive_key)})
			_paint_queue.pop_front(); _paint_column = 0
			grid._snapshot_frame = -1; _room_cache.clear(); generation += 1
			navigation_ready.emit()
	_counts["paint_us"] = int(_counts.get("paint_us", 0)) + Time.get_ticks_usec() - paint_from
	var door_checked := Vector2i(2147483647, 2147483647)
	# With the draw window in use, columns are sampled on a worker while the frame renders.
	var on_main := not _draw_window_active()
	while on_main and not _queue.is_empty() and Time.get_ticks_usec()-start < budget and count < 128 * 6:
		var coord := _queue[0]
		if not grid.chunks.has(coord): _queue.pop_front(); _column = 0; continue
		var chunk: WalkChunk = grid.chunks[coord]
		if coord != door_checked:
			door_checked = coord
			if _door_open_over(coord): _door_tainted[coord] = true
		var sampled := 0
		if _column_sampler != null:
			# dev 2026-10-20 multithreading: one native call samples this chunk's columns until the
			# budget or the per-tick column cap runs out (same rays, parameters and order).
			sampled = _column_sampler.sample(get_world_3d().direct_space_state, _ray, _volume, chunk, _column,
				mini(WalkGrid.CHUNK_CELLS*WalkGrid.CHUNK_CELLS-_column, 128*6-count), start+budget, bounds, _blockers.values(),
				WorldTerrain.instance if is_instance_valid(WorldTerrain.instance) else null)
		if sampled <= 0:
			_sample_column(chunk,_column)
			sampled = 1
		count += sampled
		_advance_sampling(coord, chunk, sampled, start)
	baking = not _queue.is_empty() or not _key_queue.is_empty() or not _paint_queue.is_empty() or not _io_queue.is_empty() or _io_worker >= 0
	_dirty = baking
	statistics = {"chunks":grid.chunks.size(),"queued":_queue.size(),"sample_us":Time.get_ticks_usec()-start,"columns":count,"revision":revision,"searches":search_counts}
	if chunk_keys:
		statistics["keying"] = _key_queue.size(); statistics["keys"] = _keys.stats; statistics["counts"] = _counts
	_report_sampling()
	if _worker >= 0 and WorkerThreadPool.is_task_completed(_worker):
		WorkerThreadPool.wait_for_task_completion(_worker)
		_worker = -1
		_complete_search(_pending_result)
		_pending_result = {}
	# dev 2026-10-20 multithreading: with the native backend, several searches run at once
	# (_running); otherwise exactly the old one-search-at-a-time path below.
	if not _running.is_empty():
		_poll_parallel()
	elif _native_busy:
		_poll_native()
	if _worker < 0 and (not _native_busy or not _running.is_empty()) and PARALLEL_SEARCH and NATIVE_BACKEND.wander_enabled():
		_dispatch_parallel()
	elif _worker < 0 and not _native_busy and _running.is_empty():
		for i in _jobs.size():
			var job := _jobs[i]
			var ready := true
			# Only the oldest waiter admits missing chunks. Admitting every job
			# here made later requests evict one another's unfinished terrain.
			for c in job.chunks:
				if not grid.chunks.has(c) and i == 0: ensure_chunk(c)
				# Admit the whole oldest route before running a ready background search.
				if not grid.chunks.has(c) or grid.chunks[c].state != WalkChunk.State.READY:
					ready = false
					# Later jobs admit nothing, so their first gap decides.
					if i > 0: break
			if not ready: continue
			_jobs.remove_at(i)
			_active = job
			_active.revision = revision
			_active.cancel_signal = Semaphore.new()
			var snapshot := grid.snapshot()
			var quality := get_node_or_null("/root/Quality")
			_search_limit = int(quality.get_value("nav_search_limit", WalkPlanner.LIMIT)) if quality != null else WalkPlanner.LIMIT
			search_counts[job.kind] += 1; _search_started = Time.get_ticks_usec()
			if job.kind == "path" and NATIVE_BACKEND.search_enabled() and _start_native(job, snapshot):
				break
			_worker = WorkerThreadPool.add_task(_search.bind(snapshot,job),false,"Pony terrain route")
			break

## `sampled` more columns of the queue head are done; a finished chunk goes on to painting.
func _advance_sampling(coord: Vector2i, chunk: WalkChunk, sampled: int, start: int, end_key: Variant = null) -> void:
	_column += sampled
	if _column != WalkGrid.CHUNK_CELLS*WalkGrid.CHUNK_CELLS: return
	if chunk_keys and not _finish_keyed_sample(coord, chunk, end_key): return
	chunk.state = WalkChunk.State.DERIVING
	chunk.sample_ms = (Time.get_ticks_usec()-start)/1000.0
	_counts.sampled += 1
	if not chunk_keys and _blockers.is_empty() and not _dynamic_chunks.has(coord) and not _door_tainted.has(coord): _io_queue.append({"kind":"save","chunk":chunk.cache_copy(),"coord":coord})
	_paint_queue.append(coord)
	_queue.pop_front(); _column = 0

## Perf overhaul 2026-11-21 (lane walk_grid): column sampling while the frame renders. Between
## RenderingServer.frame_pre_draw and frame_post_draw the main thread only renders (rendering on
## the main thread): no script, deferred call, tween or physics step runs and no body moves, so
## the Jolt space is stable for read-only queries from a worker. At pre-draw one high-priority
## task samples the queue head with the native sampler until a deadline of DRAW_SHARE of the last
## draw's length (capped); at post-draw the main thread waits for it (at most one column late) and
## does the bookkeeping. Without a drawn frame in the last DRAW_STALE frames (headless, minimised),
## with a separate render thread (render_thread.gd separate()) or without the native sampler, the
## main-thread budget samples as before. Rollback: DRAW_WINDOW_SAMPLING = false.
const DRAW_WINDOW_SAMPLING := false
const DRAW_SHARE := 0.8
const DRAW_CAP_US := 4000
const DRAW_MIN_US := 150
const DRAW_STALE := 2
## Waiting chunks keyed per drawn frame at most (each a physics box query).
const DRAW_KEYS := 16
var _draw_task := -1
var _draw_plan := {}
var _draw_done := 0
var _draw_started := 0
var _draw_length_us := 0
var _draw_frame := -1000
var _draw_usable := false
var _draw_door_checked := Vector2i(2147483647, 2147483647)

func _draw_window_setup() -> void:
	# `-- --walk-grid-draw-window=on|off` overrides the default for one launch (A/B and the proof).
	var wanted := DRAW_WINDOW_SAMPLING
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--walk-grid-draw-window="): wanted = arg.ends_with("=on")
	if not wanted or _column_sampler == null: return
	# 2026-11-25: asked through the render-thread helper. The engine consumes `--render-thread`, so the
	# old command-line test never saw it: with `=on` and a separate thread the worker would sample the
	# Jolt space while the main thread runs the next physics steps (pre-draw does not hold the main
	# thread then, and post-draw arrives as a deferred call).
	if preload("res://world/perf/render_thread.gd").separate(): return
	_draw_usable = true
	RenderingServer.frame_pre_draw.connect(_on_pre_draw)
	RenderingServer.frame_post_draw.connect(_on_post_draw)

func _draw_window_active() -> bool:
	return _draw_usable and Engine.get_process_frames() - _draw_frame <= DRAW_STALE

func _on_pre_draw() -> void:
	_draw_started = Time.get_ticks_usec()
	_draw_frame = Engine.get_process_frames()
	if _draw_task >= 0 or not ready_for_paths or not is_inside_tree(): return
	if _queue.is_empty(): return
	var space := get_world_3d().direct_space_state
	var terrain: Object = WorldTerrain.instance if is_instance_valid(WorldTerrain.instance) else null
	var length := clampi(int(_draw_length_us * DRAW_SHARE), DRAW_MIN_US, DRAW_CAP_US)
	# Chunks waiting for a key go first (cheap, and on the load path); taken off the queue here,
	# put back at post-draw if the deadline came first.
	# Keys are taken on the main thread (the registry is not shared with workers).
	var keying: Array[Vector2i] = []
	_draw_plan = {"start": _draw_started, "keying": keying, "keys": {}, "end_key": null}
	var chunk: WalkChunk = grid.chunks.get(_queue[0]) if not _queue.is_empty() else null
	if chunk != null and chunk.is_allocated():
		var coord := _queue[0]
		if coord != _draw_door_checked:
			_draw_door_checked = coord
			if _door_open_over(coord): _door_tainted[coord] = true
		_draw_plan.coord = coord; _draw_plan.chunk = chunk; _draw_plan.first = _column
	_draw_done = 0
	_draw_task = WorkerThreadPool.add_task(_draw_work.bind(space, _draw_plan, _draw_started + length, _blockers.values(), terrain),
		true, "Walk grid sampling (draw window)")

## Worker: keys of waiting chunks, then the same native column call the main-thread loop makes,
## then the end-of-sampling key when the chunk is done. Writes only `plan` and _draw_done.
func _draw_work(space: PhysicsDirectSpaceState3D, plan: Dictionary, deadline: int, blockers: Array, terrain: Object) -> void:
	if not plan.has("chunk") or Time.get_ticks_usec() >= deadline: return
	var chunk: WalkChunk = plan.chunk
	var first: int = plan.first
	var total := WalkGrid.CHUNK_CELLS*WalkGrid.CHUNK_CELLS
	_draw_done = _column_sampler.sample(space, _ray, _volume, chunk, first, total - first, deadline, bounds, blockers, terrain)

func _on_post_draw() -> void:
	_draw_length_us = Time.get_ticks_usec() - _draw_started
	_join_draw_task()

func _join_draw_task() -> void:
	if _draw_task < 0: return
	WorkerThreadPool.wait_for_task_completion(_draw_task)
	_draw_task = -1
	var plan := _draw_plan
	_draw_plan = {}
	var keys: Dictionary = plan.get("keys", {})
	var keying: Array = plan.get("keying", [])
	for i in range(keying.size() - 1, -1, -1):
		var c: Vector2i = keying[i]
		if not grid.chunks.has(c) or grid.chunks[c].state != WalkChunk.State.QUEUED: continue
		if not keys.has(c):
			_key_queue.push_front(c)
			continue
		_chunk_keys[c] = keys[c]
		_counts.keyed += 1
		_admit_keyed(c, grid.chunks[c], STAGE_DERIVED)
	if not plan.has("chunk"): return
	# Nothing can have changed the queue since pre-draw; checked anyway.
	if _draw_done <= 0 or _queue.is_empty() or _queue[0] != plan.coord or grid.chunks.get(plan.coord) != plan.chunk or _column != int(plan.first): return
	_counts["draw_columns"] = int(_counts.get("draw_columns", 0)) + _draw_done
	_advance_sampling(plan.coord, plan.chunk, _draw_done, int(plan.start), plan.end_key)

## A finished search (worker or native): cancelled, expanded to more chunks, delivered, or
## reported stale when the geometry it read changed meanwhile.
func _complete_search(result: Dictionary) -> void:
	var job := _active
	_active = {}
	search_counts.busy_ms += (Time.get_ticks_usec()-_search_started)/1000.0
	_deliver(job, result)

## Delivery of one finished search, shared by the single search and the parallel ones.
func _deliver(job: Dictionary, result: Dictionary) -> void:
	var current: bool = job.revision == revision and not bool(result.get("stale", false))
	if _cancelled.has(job.id):
		_cancelled.erase(job.id); search_counts.cancelled += 1
	elif current and _expand_route(job,result): search_counts.retry += 1
	elif current and job.callback.is_valid(): job.callback.call(result,job.id,revision)
	elif job.callback.is_valid():
		job.callback.call({"path":PackedVector3Array(),"stale":true},job.id,revision); search_counts.stale += 1

## Starts the active route search on the native backend; false keeps the GDScript worker.
func _start_native(job: Dictionary, snapshot: Dictionary) -> bool:
	var submitted := _submit_native(job, snapshot)
	if submitted.is_empty(): return false
	_native_handle = PackedInt64Array([submitted[0], submitted[1]])
	_native_busy = true
	return true

## Submits one native route intent: [actor slot, actor generation, intent generation], or empty.
func _submit_native(job: Dictionary, snapshot: Dictionary) -> PackedInt64Array:
	if _native_world < 0:
		_native_world = NATIVE_BACKEND.acquire_world()
		if _native_world < 0: return PackedInt64Array()
	var native := NATIVE_BACKEND.instance()
	_sync_native(snapshot)
	var requester: Object = job.callback.get_object() if job.callback.is_valid() else null
	var key: int = requester.get_instance_id() if requester != null else 0
	var handle := _native_actor_for(key, NATIVE_BACKEND.profile_of(job.profile))
	if handle.size() != 2:
		push_error("Native route search could not register a %s actor; using the GDScript search" % zone_id)
		return PackedInt64Array()
	_native_generation += 1
	var intent := {"owner": key, "generation": _native_generation, "from": job.from, "goal": job.to,
		"any_floor": bool(job.get("any_floor", false)), "relaxed": bool(job.get("relaxed", false)),
		"expansion_limit": _search_limit, "priority": 1 if bool(job.get("priority", false)) else 0}
	if _open_route(job):
		intent["use_corridor"] = false
		intent["expansion_limit"] = maxi(_search_limit, int(_open_rules().open_limit))
	# Phase 2 follower options (only with -- --native-navigation follow): a cramped start may leave
	# its nook along capsule-sized floor, and obstruction evidence keeps the search out of discs.
	var extra: Dictionary = job.get("extra", {})
	if extra.has("escape_reach"): intent["escape_reach"] = float(extra.escape_reach)
	if extra.has("blocked"): intent["blocked"] = extra.blocked
	var accepted: int = native.submit_intent(handle[0], handle[1], intent)
	if accepted != _native_generation:
		push_error("Native route search rejected a %s request; using the GDScript search" % zone_id)
		return PackedInt64Array()
	search_counts.native += 1
	return PackedInt64Array([handle[0], handle[1], _native_generation])

## The native actor [slot, generation] of one requester (a navigator), registered on first use and
## shared by its searches and its native follower. Empty when the native world is unavailable.
func _native_actor_for(key: int, profile: Dictionary) -> PackedInt64Array:
	var native := NATIVE_BACKEND.instance()
	if native == null or _native_world < 0: return PackedInt64Array()
	var handle: PackedInt64Array = _native_actors.get(key, PackedInt64Array())
	if handle.size() == 2 and native.is_actor_live(handle[0], handle[1]):
		native.update_actor_profile(handle[0], handle[1], profile)
		return handle
	_sweep_native_actors()
	handle = native.register_actor(_native_world, profile)
	if handle.size() == 2:
		_native_actors[key] = handle
	return handle

## Phase 2 follower: the requester's native actor in this service's world, with the current READY
## chunks published (once per revision; free while the snapshot is unchanged). Empty when the
## native backend cannot run here.
func native_follow_actor(requester: Object, locomotion: Resource) -> PackedInt64Array:
	if not NATIVE_BACKEND.follow_enabled() or requester == null: return PackedInt64Array()
	if _native_world < 0:
		_native_world = NATIVE_BACKEND.acquire_world()
		if _native_world < 0: return PackedInt64Array()
	_sync_native(grid.snapshot())
	return _native_actor_for(requester.get_instance_id(), NATIVE_BACKEND.profile_of(WalkGrid.profile(locomotion)))

## Keeps the follower's ground current: publishes chunks that changed since the last call.
func native_follow_sync() -> void:
	if _native_world >= 0: _sync_native(grid.snapshot())

## Publishes changed READY chunk views (each converted once per revision) and removes
## chunks that left the snapshot. Skipped while the snapshot object is unchanged.
func _sync_native(snapshot: Dictionary) -> void:
	if is_same(snapshot, _native_synced): return
	_native_synced = snapshot
	_counts["native_syncs"] = int(_counts.get("native_syncs", 0)) + 1
	for coord: Vector2i in _native_views.keys():
		if not snapshot.has(coord):
			NATIVE_BACKEND.remove_chunk(_native_world, coord)
			_native_views.erase(coord)
	for coord: Vector2i in snapshot:
		var view: Dictionary = snapshot[coord]
		if is_same(_native_views.get(coord), view): continue
		if NATIVE_BACKEND.publish_view(_native_world, coord, view) > 0:
			_native_views[coord] = view
		else:
			NATIVE_BACKEND.remove_chunk(_native_world, coord)
			_native_views.erase(coord)

func _poll_native() -> void:
	for result: Dictionary in NATIVE_BACKEND.take_results(_native_world):
		if _native_handle.size() != 2 or int(result.get("slot", -1)) != _native_handle[0] \
				or int(result.get("generation", -1)) != _native_handle[1] \
				or int(result.get("intent_generation", -1)) != _native_generation:
			continue
		_native_busy = false
		search_counts.native_cpu_ms += float(result.get("cpu_ms", 0.0))
		_complete_search(NATIVE_BACKEND.legacy_result(result))
		return

func _cancel_native() -> void:
	var native := NATIVE_BACKEND.instance()
	if _native_busy and native != null and _native_handle.size() == 2:
		native.cancel_intent(_native_handle[0], _native_handle[1], _native_generation)
	_native_busy = false

## Requesters that left the tree keep no native actor slot.
func _sweep_native_actors() -> void:
	if _native_actors.size() < 64: return
	var native := NATIVE_BACKEND.instance()
	for key: int in _native_actors.keys():
		if key != 0 and not is_instance_id_valid(key):
			var handle: PackedInt64Array = _native_actors[key]
			if native != null: native.unregister_actor(handle[0], handle[1])
			_native_actors.erase(key)

func _release_native() -> void:
	if _native_world < 0: return
	_cancel_native()
	var native := NATIVE_BACKEND.instance()
	if native != null:
		for handle: PackedInt64Array in _native_actors.values():
			native.unregister_actor(handle[0], handle[1])
	_native_actors.clear(); _native_views.clear(); _native_synced = {}
	NATIVE_BACKEND.release_world(_native_world)
	_native_world = -1

## dev 2026-10-20 multithreading: parallel searches. One-line rollback: PARALLEL_SEARCH = false
## (or `-- --native-navigation off`) restores the single search per service with the GDScript
## wander. With it on, wander searches run natively (PonyWanderJob, one low-priority
## WorkerThreadPool task each) and route searches as native intents (their scheduler workers follow
## the pool too), up to NATIVE_BACKEND.search_concurrency() at once across all services.
## Each search reads its own immutable snapshot (native chunks published once per revision on
## the main thread; workers never see nodes or Dictionaries).
## Ownership: _running, _jobs, callbacks and the counter below are main thread only. A running
## search's result crosses back through the pool's task completion (wander) or the native result
## queue (route), both polled here. Delivery keeps today's rules: a job records `revision` when
## it starts and is reported stale if the geometry changed meanwhile; at most one search per
## requester runs at a time, so one pony's results keep their request order; finished searches
## are delivered in start order.
const PARALLEL_SEARCH := true
## Searches running in parallel, oldest first: {job, key, kind, started, done, result,
## wander (PonyWanderJob) | handle [slot, generation, intent generation]}.
var _running: Array[Dictionary] = []
## Parallel searches in flight over every service (main thread only).
static var _parallel_in_flight := 0

func _requester_key(job: Dictionary) -> int:
	var callback: Callable = job.callback
	var requester: Object = callback.get_object() if callback.is_valid() else null
	return requester.get_instance_id() if requester != null else 0

## Starts every ready job the concurrency budget allows, in queue order (the same readiness and
## chunk-admission rules as the single search: only the oldest waiter admits missing chunks).
func _dispatch_parallel() -> void:
	# Nothing waits: nothing can start and the running count (the peak) only grows below.
	if _jobs.is_empty(): return
	var limit := NATIVE_BACKEND.search_concurrency()
	var busy := {}
	for entry: Dictionary in _running: busy[entry.key] = true
	var i := 0
	while i < _jobs.size() and _parallel_in_flight < limit:
		var job := _jobs[i]
		var ready := true
		for c in job.chunks:
			if not grid.chunks.has(c) and i == 0: ensure_chunk(c)
			if not grid.chunks.has(c) or grid.chunks[c].state != WalkChunk.State.READY:
				ready = false
				if i > 0: break
		var key := _requester_key(job)
		if not ready or busy.has(key):
			i += 1
			continue
		_jobs.remove_at(i)
		if not _start_parallel(job, key):
			# The native backend refused it: the GDScript worker takes this job, as before.
			_active = job
			_active.revision = revision
			_active.cancel_signal = Semaphore.new()
			search_counts[job.kind] += 1; _search_started = Time.get_ticks_usec()
			_worker = WorkerThreadPool.add_task(_search.bind(grid.snapshot(),job),false,"Pony terrain route")
			return
		busy[key] = true
	search_counts.concurrent_peak = maxi(int(search_counts.get("concurrent_peak", 0)), _running.size())

func _start_parallel(job: Dictionary, key: int) -> bool:
	var snapshot := grid.snapshot()
	var quality := get_node_or_null("/root/Quality")
	_search_limit = int(quality.get_value("nav_search_limit", WalkPlanner.LIMIT)) if quality != null else WalkPlanner.LIMIT
	var entry := {"job": job, "key": key, "kind": str(job.kind), "started": Time.get_ticks_usec(), "done": false, "result": {}}
	if job.kind == "path":
		var submitted := _submit_native(job, snapshot)
		if submitted.is_empty(): return false
		entry.handle = submitted
	else:
		if _native_world < 0:
			_native_world = NATIVE_BACKEND.acquire_world()
			if _native_world < 0: return false
		_sync_native(snapshot)
		var context: Dictionary = job.get("context", {})
		# The seed is drawn here, on the main thread: concurrent searches never share the global RNG.
		var params := {"from": job.from, "radius": float(job.radius), "interest": job.interest,
			"home": job.get("home", Vector3.INF), "leash": float(job.get("leash", INF)),
			"recent": context.get("recent", []), "heading": context.get("heading", Vector3.ZERO), "seed": randi()}
		var wander: RefCounted = NATIVE_BACKEND.instance().wander_job(_native_world, NATIVE_BACKEND.profile_of(job.profile), params)
		if wander == null: return false
		wander.start()
		entry.wander = wander
		search_counts.native_wander = int(search_counts.get("native_wander", 0)) + 1
	job.revision = revision
	search_counts[job.kind] += 1
	_running.append(entry)
	_parallel_in_flight += 1
	_native_busy = _running_route()
	return true

func _running_route() -> bool:
	for entry: Dictionary in _running:
		if entry.kind == "path": return true
	return false

## Collects finished parallel searches and delivers them, oldest first.
func _poll_parallel() -> void:
	if _native_world >= 0 and _running_route():
		for result: Dictionary in NATIVE_BACKEND.take_results(_native_world):
			for entry: Dictionary in _running:
				if entry.done or entry.kind != "path": continue
				var handle: PackedInt64Array = entry.handle
				if int(result.get("slot", -1)) != handle[0] or int(result.get("generation", -1)) != handle[1] \
						or int(result.get("intent_generation", -1)) != handle[2]:
					continue
				entry.done = true
				search_counts.native_cpu_ms += float(result.get("cpu_ms", 0.0))
				entry.result = NATIVE_BACKEND.legacy_result(result)
				break
	var finished: Array[Dictionary] = []
	for i in range(_running.size()-1, -1, -1):
		var entry: Dictionary = _running[i]
		if not entry.done and entry.kind == "wander" and entry.wander.is_done():
			entry.done = true
			entry.result = {"destination": entry.wander.destination(), "intent": entry.job.get("intent", "Exploring")}
		if entry.done:
			finished.push_front(entry)
			_running.remove_at(i)
			_parallel_in_flight -= 1
	_native_busy = _running_route()
	# Callbacks may request or cancel searches; finished entries are already out of _running.
	for entry: Dictionary in finished:
		search_counts.busy_ms += (Time.get_ticks_usec()-int(entry.started))/1000.0
		_deliver(entry.job, entry.result)

## Cancels one parallel search: a route intent is withdrawn at once and never answers; a wander is
## told to stop and is dropped silently when its task ends (the single search's rule).
func _cancel_parallel(id: int) -> void:
	for i in range(_running.size()-1, -1, -1):
		var entry: Dictionary = _running[i]
		if int(entry.job.id) != id: continue
		if entry.kind == "path":
			var native := NATIVE_BACKEND.instance()
			var handle: PackedInt64Array = entry.handle
			if native != null: native.cancel_intent(handle[0], handle[1], handle[2])
			_running.remove_at(i)
			_parallel_in_flight -= 1
			search_counts.busy_ms += (Time.get_ticks_usec()-int(entry.started))/1000.0
			search_counts.cancelled += 1
		else:
			_cancelled[id] = true
			entry.wander.cancel()
	_native_busy = _running_route()

## Zone unload: stops every parallel search. Returns true when none is left; `block` waits for
## running wander tasks (each stops within 128 cells once cancelled).
func _drain_parallel(block: bool) -> bool:
	for i in range(_running.size()-1, -1, -1):
		var entry: Dictionary = _running[i]
		if entry.kind == "wander":
			entry.wander.cancel()
			if block: entry.wander.wait()
			elif not entry.wander.is_done(): continue
		_running.remove_at(i)
		_parallel_in_flight -= 1
	_native_busy = _running_route()
	return _running.is_empty()

## Body-room results shared by this service's searches (one search runs at a time).
var _search_room := {"views": {}, "profiles": {}, "entries": 0}

func _search(snapshot: Dictionary, job: Dictionary) -> void:
	var planner := WalkPlanner.new()
	planner.cancel_signal = job.cancel_signal
	planner.shared = _search_room
	planner.limit = _search_limit
	if job.kind == "wander":
		_pending_result = {"destination":planner.wander(snapshot,job.from,job.profile,job.radius,job.interest,job.get("home",Vector3.INF),job.get("leash",INF),job.get("context",{})), "intent":job.get("intent", "Exploring")}
	else:
		planner.use_corridor = not _open_route(job)
		_pending_result = planner.plan(snapshot,job.from,job.to,job.profile,job.get("any_floor",false),job.get("relaxed",false))

func _open_rules() -> Dictionary:
	return OPEN_ROUTES_QUEST if OS.has_feature("android") else OPEN_ROUTES_DESKTOP

## True when this route search skips the coarse corridor (OPEN_ROUTES).
func _open_route(job: Dictionary) -> bool:
	if not OPEN_ROUTES or str(job.get("kind", "path")) != "path" or bool(job.get("corridor_only", false)): return false
	if _search_limit < WalkPlanner.LIMIT: return false
	var from: Vector3 = job.get("from", Vector3.ZERO)
	var to: Vector3 = job.get("to", Vector3.ZERO)
	return Vector2(from.x - to.x, from.z - to.z).length() <= float(_open_rules().corridor_off_m)

func _sample_column(chunk: WalkChunk, column: int) -> void:
	chunk.clear_column(column)
	var cell := chunk.coord*WalkGrid.CHUNK_CELLS + Vector2i(column%WalkGrid.CHUNK_CELLS,column/WalkGrid.CHUNK_CELLS)
	var x := (cell.x+.5)*WalkGrid.CELL
	var z := (cell.y+.5)*WalkGrid.CELL
	var space := get_world_3d().direct_space_state
	_ray.from = Vector3(x,bounds.end.y+5.0,z)
	_ray.to = Vector3(x,bounds.position.y-5.0,z)
	_ray.collision_mask = WATER_MASK
	_ray.hit_from_inside = false
	var water := space.intersect_ray(_ray)
	var water_y: float = water.position.y if not water.is_empty() else -INF
	_ray.collision_mask = 1
	var height := bounds.end.y+5.0
	var found := 0
	var base_excludes: Array[RID] = _ray.exclude.duplicate()
	var floor_excludes: Array[RID] = base_excludes.duplicate()
	for attempt in 6:
		_ray.from = Vector3(x,height,z)
		_ray.to = Vector3(x,bounds.position.y-5.0,z)
		_ray.hit_from_inside = false
		_ray.exclude = floor_excludes
		var hit := space.intersect_ray(_ray)
		_ray.exclude = base_excludes # Overhead geometry must still constrain headroom.
		if hit.is_empty(): break
		height = hit.position.y-.025
		# Non-walkable roof/ceiling shells still block motion and headroom rays,
		# but must not consume both floor spans above an accessible restaurant.
		if hit.collider.get_meta("navigation_ceiling", false):
			floor_excludes.append(hit.rid)
			continue
		if hit.normal.y <= .01: continue
		var slot := column*WalkGrid.SPANS+found
		chunk.floor_y[slot] = hit.position.y
		chunk.slope_deg[slot] = ceili(rad_to_deg(acos(clampf(hit.normal.y,-1,1)))-.001)
		chunk.water_depth[slot] = maxf(0.0,water_y-hit.position.y)
		chunk.flags[slot] = WalkGrid.SOLID | (WalkGrid.WATER if chunk.water_depth[slot] > .001 else 0)
		_ray.from = hit.position+Vector3.UP*.03
		_ray.to = Vector3(x,bounds.end.y+5.0,z)
		_ray.hit_from_inside = true
		var ceiling := space.intersect_ray(_ray)
		chunk.headroom[slot] = ceiling.position.y-hit.position.y if not ceiling.is_empty() else INF
		# Catch thin vertical walls between column centres. The foot band clears
		# ordinary ramp rise across this radius, while final profile erosion owns width.
		_volume.transform = Transform3D(Basis.IDENTITY,hit.position+Vector3.UP*.237)
		if not space.intersect_shape(_volume,1).is_empty(): chunk.headroom[slot] = 0.0
		for box in _blockers.values():
			if box.grow(.18).has_point(hit.position+Vector3.UP*.3): chunk.headroom[slot] = 0.0
		found += 1
		if found >= WalkGrid.SPANS: break
	if found == 0 and is_instance_valid(WorldTerrain.instance):
		# No physics floor here (unloaded zone, or outside Terrain3D's dynamic collision
		# radius): the world heightmap is the ground.
		var ground: float = WorldTerrain.instance.height_at(Vector3(x,0.0,z))
		if is_finite(ground):
			var normal: Vector3 = WorldTerrain.instance.normal_at(Vector3(x,ground,z))
			var slot := column*WalkGrid.SPANS
			chunk.floor_y[slot] = ground
			chunk.slope_deg[slot] = ceili(rad_to_deg(acos(clampf(normal.y,-1,1)))-.001)
			chunk.water_depth[slot] = maxf(0.0,water_y-ground)
			chunk.flags[slot] = WalkGrid.SOLID | (WalkGrid.WATER if chunk.water_depth[slot] > .001 else 0)
			# A Terrain3D fallback is still surrounded by real rocks/plants. The lack
			# of a downward floor hit must not grant clearance through those colliders.
			_ray.from = Vector3(x, ground + .03, z)
			_ray.to = Vector3(x, maxf(ground + 3.0, bounds.end.y + 5.0), z)
			_ray.hit_from_inside = true
			var ceiling := space.intersect_ray(_ray)
			chunk.headroom[slot] = ceiling.position.y-ground if not ceiling.is_empty() else INF
			_volume.transform = Transform3D(Basis.IDENTITY, Vector3(x, ground + .237, z))
			if not space.intersect_shape(_volume, 1).is_empty(): chunk.headroom[slot] = 0.0
			for box in _blockers.values():
				if box.grow(.18).has_point(Vector3(x,ground+.3,z)): chunk.headroom[slot] = 0.0

## Trail weights of the chunk being painted (terrain_paths.chunk_weights).
var _trail_chunk: WalkChunk
var _trail_weights := PackedFloat64Array()

## 0.1.0 perf: _apply_paint() over a run of columns in one call, with the chunk's arrays held in
## locals and stored back once. `chunk.trail_weight[slot] = x` copied the whole 8 KB array on every
## write (the property read shares it, the write copies it): two copies per column, 64 MB per chunk.
## Same columns, same values, same per-column time check as the old loop. Rollback: PAINT_RUNS = false.
const PAINT_RUNS := true

## Columns from `first` until the chunk ends, its quick finish (nothing to paint) or `deadline`
## (usec); at least one. Returns how many it painted.
func _apply_paint_run(chunk: WalkChunk, first: int, deadline: int) -> int:
	var total := WalkGrid.CHUNK_CELLS*WalkGrid.CHUNK_CELLS
	var quick := layers.rasters.is_empty() and not chunk.painted and not is_instance_valid(_terrain_paths.data)
	if first == 0:
		chunk._cached_view = {}
		if chunk.trail_weight.size() != chunk.flags.size(): chunk.trail_weight.resize(chunk.flags.size())
	if first == 0 or _trail_chunk != chunk:
		_trail_chunk = chunk
		_trail_weights = _terrain_paths.chunk_weights(chunk.coord, WalkGrid.CELL, WalkGrid.CHUNK_CELLS)
	var weights := _trail_weights
	var trail := chunk.trail_weight
	var floor_y := chunk.floor_y
	var flags := chunk.flags
	var paint_cost := chunk.paint_cost
	var painting := not (layers.rasters.is_empty() and not chunk.painted)
	var terrain: Node = WorldTerrain.instance if is_instance_valid(WorldTerrain.instance) else null
	var base := chunk.coord*WalkGrid.CHUNK_CELLS
	var column := first
	while true:
		var cell := base+Vector2i(column%WalkGrid.CHUNK_CELLS,column/WalkGrid.CHUNK_CELLS)
		var terrain_point := Vector3((cell.x+.5)*WalkGrid.CELL,0,(cell.y+.5)*WalkGrid.CELL)
		var surface_weight: float = weights[column] if column < weights.size() else _terrain_paths.weight_at(terrain_point)
		var ground: float = terrain.height_at(terrain_point) if terrain != null and surface_weight > 0.0 else NAN
		for span in WalkGrid.SPANS:
			var slot := column*WalkGrid.SPANS+span
			trail[slot] = roundi(surface_weight*255.0) if is_finite(ground) and absf(floor_y[slot]-ground)<.5 else 0
		if painting:
			var local := _content.to_local(terrain_point)
			var xz := Vector2(local.x,local.z)
			var paint := layers.flags_at(xz)
			var cost := layers.cost_at(xz)
			paint_cost[column] = 255 if is_inf(cost) else mini(254,roundi(cost*WalkGrid.PAINT_SCALE))
			for span in WalkGrid.SPANS:
				var slot := column*WalkGrid.SPANS+span
				flags[slot] &= ~(WalkGrid.PAINT_BLOCK|WalkGrid.PAINT_TRAIL|WalkGrid.PAINT_FORD)
				if paint.block: flags[slot] |= WalkGrid.PAINT_BLOCK
				if paint.trail: flags[slot] |= WalkGrid.PAINT_TRAIL
				if paint.ford: flags[slot] |= WalkGrid.PAINT_FORD
				# Paint conveys intent; it cannot conjure a bridge or make deep water safe.
				if paint.lake and not paint.ford and not (paint.bridge and span == 0 and chunk.water_depth[slot] <= .001): flags[slot] |= WalkGrid.PAINT_BLOCK
		column += 1
		if quick or column == total or Time.get_ticks_usec() >= deadline: break
	chunk.trail_weight = trail
	if painting:
		chunk.flags = flags
		chunk.paint_cost = paint_cost
	return column - first

func _apply_paint(chunk: WalkChunk, column: int) -> void:
	if column == 0: chunk._cached_view = {}
	if column == 0 and chunk.trail_weight.size() != chunk.flags.size(): chunk.trail_weight.resize(chunk.flags.size())
	var terrain_point := Vector3((chunk.coord.x*WalkGrid.CHUNK_CELLS+column%WalkGrid.CHUNK_CELLS+.5)*WalkGrid.CELL,0,
		(chunk.coord.y*WalkGrid.CHUNK_CELLS+column/WalkGrid.CHUNK_CELLS+.5)*WalkGrid.CELL)
	# The whole chunk's trail weights at its first column (or when another chunk interleaves).
	if column == 0 or _trail_chunk != chunk:
		_trail_chunk = chunk
		_trail_weights = _terrain_paths.chunk_weights(chunk.coord, WalkGrid.CELL, WalkGrid.CHUNK_CELLS)
	var surface_weight: float = _trail_weights[column] if column < _trail_weights.size() else _terrain_paths.weight_at(terrain_point)
	var ground := WorldTerrain.instance.height_at(terrain_point) if is_instance_valid(WorldTerrain.instance) and surface_weight > 0.0 else NAN
	for span in WalkGrid.SPANS:
		var slot := column*WalkGrid.SPANS+span
		chunk.trail_weight[slot] = roundi(surface_weight*255.0) if is_finite(ground) and absf(chunk.floor_y[slot]-ground)<.5 else 0
	if layers.rasters.is_empty() and not chunk.painted: return
	if true:
		var cell := chunk.coord*WalkGrid.CHUNK_CELLS+Vector2i(column%WalkGrid.CHUNK_CELLS,column/WalkGrid.CHUNK_CELLS)
		var world := Vector3((cell.x+.5)*WalkGrid.CELL,0,(cell.y+.5)*WalkGrid.CELL)
		var local := _content.to_local(world)
		var xz := Vector2(local.x,local.z)
		var paint := layers.flags_at(xz)
		var cost := layers.cost_at(xz)
		chunk.paint_cost[column] = 255 if is_inf(cost) else mini(254,roundi(cost*WalkGrid.PAINT_SCALE))
		for span in WalkGrid.SPANS:
			var slot := column*WalkGrid.SPANS+span
			chunk.flags[slot] &= ~(WalkGrid.PAINT_BLOCK|WalkGrid.PAINT_TRAIL|WalkGrid.PAINT_FORD)
			if paint.block: chunk.flags[slot] |= WalkGrid.PAINT_BLOCK
			if paint.trail: chunk.flags[slot] |= WalkGrid.PAINT_TRAIL
			if paint.ford: chunk.flags[slot] |= WalkGrid.PAINT_FORD
			# Paint conveys intent; it cannot conjure a bridge or make deep water safe.
			if paint.lake and not paint.ford and not (paint.bridge and span == 0 and chunk.water_depth[slot] <= .001): chunk.flags[slot] |= WalkGrid.PAINT_BLOCK

func ensure_chunk(c: Vector2i) -> void:
	if grid.chunks.has(c): grid.chunks[c].last_used_frame = Engine.get_physics_frames(); return
	if grid.chunks.size() >= max_chunks and not _evict(): return
	var chunk := WalkChunk.new(); chunk.coord = c
	_admitted_at[c] = Time.get_ticks_msec()
	_admit(c, chunk, _derive_cache)
	grid.chunks[c] = chunk
	# No snapshot reset: a new chunk is QUEUED or SAMPLING, never in the snapshot (and
	# _evict above resets it itself).
	chunk.last_used_frame = Engine.get_physics_frames()

## Disk first: a derived copy skips DERIVING, a sampled copy skips physics; else sample.
func _admit(c: Vector2i, chunk: WalkChunk, derived: bool) -> void:
	if chunk_keys:
		# Keyed in _physics_process inside the step budget, then _admit_keyed().
		chunk.state = WalkChunk.State.QUEUED
		if c not in _key_queue: _key_queue.append(c)
		return
	if _blockers.is_empty() and not _dynamic_chunks.has(c):
		var path := _derived_path(c) if derived else ""
		var is_derived := path != "" and FileAccess.file_exists(path)
		if not is_derived: path = _cache_dir.path_join("%d_%d.res"%[c.x,c.y])
		if FileAccess.file_exists(path):
			chunk.state = WalkChunk.State.QUEUED
			_io_queue.append({"kind":"load","coord":c,"revision":revision,"derived":is_derived,"path":path})
			return
	chunk.allocate()
	chunk.state = WalkChunk.State.SAMPLING
	_queue.append(c)

## A keyed chunk: its derived copy, else its sampled copy, when the stored key matches; else
## sampling. The loaded file's key is checked again when the IO worker returns it (_poll_io).
## Stages, each tried once in order: STAGE_DERIVED (the user's painted copy), STAGE_SAMPLED (the
## baked chunk when its key matches, else the user's sampled copy), then sampling.
const STAGE_DERIVED := 0
const STAGE_SAMPLED := 1
const STAGE_SAMPLE := 2
func _admit_keyed(c: Vector2i, chunk: WalkChunk, stage: int) -> void:
	var key := str(_chunk_keys.get(c, ""))
	if key != "" and _blockers.is_empty() and not _dynamic_blocks(c):
		var baked: Array = _baked.get(c, [])
		var baked_match := not baked.is_empty() and str(baked[0]) == key
		if stage <= STAGE_DERIVED and _derive_cache and baked_match and str(baked[3]) != "" and str(baked[3]) == _derive_key(c, key):
			# The baked chunk painted exactly as this world would paint it: ready without painting.
			chunk.state = WalkChunk.State.QUEUED
			_io_queue.append({"kind":"load","coord":c,"revision":revision,"derived":true,"path":_baked_path,"key":str(baked[3]),"baked":baked})
			return
		var derive_key := _derive_key(c, key) if stage <= STAGE_DERIVED and _derive_cache else ""
		if derive_key != "" and FileAccess.file_exists(_keyed_path(c, true, derive_key)):
			chunk.state = WalkChunk.State.QUEUED
			_io_queue.append({"kind":"load","coord":c,"revision":revision,"derived":true,"path":_keyed_path(c, true, derive_key),"key":derive_key})
			return
		if stage <= STAGE_SAMPLED:
			if baked_match:
				chunk.state = WalkChunk.State.QUEUED
				_io_queue.append({"kind":"load","coord":c,"revision":revision,"derived":false,"path":_baked_path,"key":key,"baked":baked})
				return
			if FileAccess.file_exists(_keyed_path(c, false, key)):
				chunk.state = WalkChunk.State.QUEUED
				_io_queue.append({"kind":"load","coord":c,"revision":revision,"derived":false,"path":_keyed_path(c, false, key),"key":key})
				return
	chunk.allocate()
	chunk.state = WalkChunk.State.SAMPLING
	_queue.append(c)

## Key of chunk `c`, "" while the registry still has bodies to read.
func _chunk_key(c: Vector2i) -> String:
	return _keys.chunk_key(c, bounds, WorldTerrain.instance if is_instance_valid(WorldTerrain.instance) else null)

## Sampling of `coord` just finished. Takes its key again: unchanged (or never taken) -> saved
## under it; changed while sampling -> sampled once more from the first column (false).
func _finish_keyed_sample(coord: Vector2i, chunk: WalkChunk, taken: Variant = null) -> bool:
	var key := str(taken) if taken != null else _chunk_key(coord)
	var before: Variant = _chunk_keys.get(coord)
	# Registry behind (a body came or went this moment): publish, cache nothing; the chunk is
	# re-keyed when the registry catches up if the body touched it.
	if key == "": before = null
	if before != null and str(before) != key and not _key_retried.has(coord):
		if _reload_for_key(coord, key): return false
		_key_retried[coord] = true
		_chunk_keys[coord] = key
		_column = 0
		return false
	_key_retried.erase(coord)
	# A second change while resampling: publish, never cache.
	_chunk_keys[coord] = key if before == null or str(before) == key else ""
	if str(_chunk_keys[coord]) != "" and _blockers.is_empty() and not _dynamic_blocks(coord) and not _door_tainted.has(coord):
		var copy := chunk.cache_copy()
		copy.set_meta("cache_key", key)
		_io_queue.append({"kind":"save","chunk":copy,"coord":coord,"path":_keyed_path(coord, false, key)})
	return true

## Takes a resident chunk's key again. A chunk waiting on its file only records the new key (the
## file is then refused); a published or painting chunk with a changed key loads the cache file of
## its new key when there is one, else is resampled, and routes replan as after any other ground
## change. A chunk being sampled loads that file at once when there is one, else is checked when
## its sampling ends.
func _check_key(coord: Vector2i) -> void:
	var fresh := _chunk_key(coord)
	if fresh == "" or fresh == str(_chunk_keys[coord]): return
	var chunk: WalkChunk = grid.chunks[coord]
	match chunk.state:
		WalkChunk.State.QUEUED:
			_chunk_keys[coord] = fresh
		WalkChunk.State.SAMPLING:
			_reload_for_key(coord, fresh)
		WalkChunk.State.READY, WalkChunk.State.DERIVING:
			var published := chunk.state == WalkChunk.State.READY
			if not _reload_for_key(coord, fresh):
				_reset_chunk(coord)
				_counts["late_resampled"] = int(_counts.get("late_resampled", 0)) + 1
			if published:
				revision += 1
				grid._snapshot_frame = -1
				_room_cache.clear()
				rebuild_started.emit()

## The key of resident chunk `coord` changed to `fresh` (a static body came, went or moved) and a
## cache file under `fresh` is on disk: the chunk is loaded from it instead of being sampled again
## (true). Ultracode 2026-11-25: in the town overhaul the houses furnish for seconds after the first
## chunks around the player are keyed (652 furniture bodies after the first key, 22 chunks), so every
## launch sampled those chunks twice although the file of their final key was already on disk.
func _reload_for_key(coord: Vector2i, fresh: String) -> bool:
	if fresh == "" or not _blockers.is_empty() or _dynamic_blocks(coord): return false
	var baked: Array = _baked.get(coord, [])
	if not (baked.size() > 0 and str(baked[0]) == fresh) and not FileAccess.file_exists(_keyed_path(coord, false, fresh)) \
			and not (_derive_cache and FileAccess.file_exists(_keyed_path(coord, true, _derive_key(coord, fresh)))):
		return false
	_door_tainted.erase(coord)
	if not _queue.is_empty() and _queue[0] == coord: _column = 0
	_queue.erase(coord)
	if not _paint_queue.is_empty() and _paint_queue[0] == coord: _paint_column = 0
	_paint_queue.erase(coord)
	_key_queue.erase(coord); _key_retried.erase(coord)
	var chunk := WalkChunk.new(); chunk.coord = coord
	chunk.state = WalkChunk.State.QUEUED
	grid.chunks[coord] = chunk
	_chunk_keys[coord] = fresh
	_counts["key_reloaded"] = int(_counts.get("key_reloaded", 0)) + 1
	_admit_keyed(coord, chunk, STAGE_DERIVED)
	return true

## SceneTree node_added: a static body, or a shape added under one, is (re)registered with the
## key registry. Every other node costs two type checks.
func _collider_added(node: Node) -> void:
	if node is CollisionObject3D:
		if _keys.relevant(node): _keys.queue_body(node)
	elif node is CollisionShape3D or node is CollisionPolygon3D:
		var body := node.get_parent() as CollisionObject3D
		if body != null: _keys.touch_body(body)

## SceneTree node_removed: the body leaves the registry; a removed shape re-reads its body.
func _collider_removed(node: Node) -> void:
	if node is CollisionObject3D:
		_keys.remove_body(node)
	elif node is CollisionShape3D or node is CollisionPolygon3D:
		var body := node.get_parent() as CollisionObject3D
		if body != null: _keys.touch_body(body)

## Ground changed after the zone signature (notify_geometry_changed) kept a chunk out of the old
## folder cache for the session. A chunk key sees those changes itself (terrain texels, every
## static shape, taken again after the change), so keyed chunks are cached and loaded as usual.
## Rollback: KEYED_DYNAMIC = false (such chunks sample every session, as before).
const KEYED_DYNAMIC := true
func _dynamic_blocks(c: Vector2i) -> bool:
	return _dynamic_chunks.has(c) and not (chunk_keys and KEYED_DYNAMIC)

func _note_ready(c: Vector2i, source: String) -> void:
	var at: Variant = _admitted_at.get(c)
	if at == null: return
	_admitted_at.erase(c)
	if _ready_log.size() < READY_LOG: _ready_log.append([c, source, Time.get_ticks_msec() - int(at), int(at)])

## Admission-to-ready times so far: {source: [count, median ms, max ms]} and the raw log.
func ready_report() -> Dictionary:
	var by := {}
	for row: Array in _ready_log:
		if not by.has(row[1]): by[row[1]] = []
		(by[row[1]] as Array).append(int(row[2]))
	var out := {}
	for source: String in by:
		var times: Array = by[source]
		times.sort()
		out[source] = [times.size(), times[times.size() / 2], times[-1]]
	return out

## One file per coordinate; the key inside the file decides whether it is still valid.
## One file per coordinate and key: ground that flips between two states (an interior streamed
## in and out) keeps both copies instead of resampling at every flip.
func _keyed_path(c: Vector2i, derived: bool, key: String) -> String:
	return _cache_dir.path_join(("derived/%d_%d_%s.res" if derived else "%d_%d_%s.res") % [c.x, c.y, key.substr(0, 16)])

## Key of a derived copy: the chunk's samples plus everything painting reads (_derived_path).
func _derive_key(c: Vector2i, key: String) -> String:
	return (_derive_stamp(c) + "|" + key).sha256_text()

## Logs when sampling starts and when it goes quiet, so a run's log tells whether the walk grid
## was sampling (and costing up to its budget each physics step) during a measurement.
func _report_sampling() -> void:
	var sampling := not _queue.is_empty()
	if sampling == _was_sampling: return
	_was_sampling = sampling
	var now := Time.get_ticks_msec()
	if sampling:
		_sampling_since = now
		print("[walk-grid] %s sampling: %d chunks queued (sampled %d, loaded %d so far)" % [zone_id, _queue.size(), _counts.sampled, _counts.loaded])
	else:
		print("[walk-grid] %s quiet after %.1f s: sampled %d, loaded %d (derived %d, baked %d), keyed %d, key time %.1f ms" % [
			zone_id, (now - _sampling_since) / 1000.0, _counts.sampled, _counts.loaded, _counts.derived_loaded, _counts.baked,
			_counts.keyed, float(_keys.stats.usec) / 1000.0 if _keys != null else 0.0])

func ensure_near(pos: Vector3, radius := 18.0) -> Array[Vector2i]:
	var a := WalkGrid.chunk_of(WalkGrid.column(pos-Vector3(radius,0,radius)))
	var b := WalkGrid.chunk_of(WalkGrid.column(pos+Vector3(radius,0,radius)))
	var result: Array[Vector2i] = []
	for z in range(a.y,b.y+1):
		for x in range(a.x,b.x+1):
			var c := Vector2i(x,z); ensure_chunk(c); result.append(c)
	return result

func request_path(from: Vector3, to: Vector3, profile: Resource, callback: Callable, any_floor := false, relaxed := false, extra: Dictionary = {}) -> int:
	_next_request += 1
	if not include_supported_ground(from) or not include_supported_ground(to):
		callback.call_deferred({"path":PackedVector3Array(),"reason":"Destination is outside collision terrain"},_next_request,revision)
		return _next_request
	var coords: Array[Vector2i] = []
	var steps := maxi(1,ceili(from.distance_to(to)/8.0))
	for i in steps+1:
		var sample:=from.lerp(to,float(i)/steps)
		var margin:float=profile.radius+1.0 # nearest-cell search plus body clearance
		var a:=WalkGrid.chunk_of(WalkGrid.column(sample-Vector3(margin,0,margin)))
		var b:=WalkGrid.chunk_of(WalkGrid.column(sample+Vector3(margin,0,margin)))
		for z in range(a.y,b.y+1):
			for x in range(a.x,b.x+1):
				var q := Vector2i(x,z)
				if q not in coords: coords.append(q)
	if coords.size() > ROUTE_CHUNKS:
		callback.call_deferred({"path":PackedVector3Array(),"reason":"Route exceeds resident chunk budget"},_next_request,revision)
		return _next_request
	for c in coords: ensure_chunk(c)
	# Requested travel precedes speculative wander selection in a busy town, and travel
	# the player waits on (follow, commands, a mare walking up to greet) precedes
	# autonomous trips and route certification (relaxed).
	var requester := callback.get_object()
	var priority := not relaxed
	if not priority and is_instance_valid(requester):
		var approaching: Variant = requester.get("_approaching_player")
		var owner: String = str(requester.get("command_owner"))
		var activity: String = str(requester.get_meta("player_waiting_route", ""))
		priority = (approaching is bool and approaching) or owner == "social:player_greeting" or (not activity.is_empty() and activity == owner)
	_enqueue_path({"id":_next_request,"kind":"path","from":from,"to":to,"profile":WalkGrid.profile(profile),"chunks":coords,"callback":callback,"revision":revision,"any_floor":any_floor,"relaxed":relaxed,"priority":priority,"extra":extra})
	return _next_request

## Zone geometry bounds are a streaming/cache footprint, not an invisible fence.
## Extend only around a supported requested point; cell physics still certifies every step.
func include_supported_ground(at:Vector3)->bool:
	if not at.is_finite():return false
	if at.x>=bounds.position.x and at.z>=bounds.position.z and at.x<=bounds.end.x and at.z<=bounds.end.z:return true
	var query:=PhysicsRayQueryParameters3D.create(at+Vector3.UP*2.,at-Vector3.UP*5.,1)
	var hit:=get_world_3d().direct_space_state.intersect_ray(query)
	var ground:float=hit.position.y if not hit.is_empty() else (WorldTerrain.instance.height_at(at) if is_instance_valid(WorldTerrain.instance) else NAN)
	if not is_finite(ground):return false
	bounds=bounds.merge(AABB(Vector3(at.x-24.,ground-8.,at.z-24.),Vector3(48.,40.,48.)))
	return true

func request_wander(from: Vector3, radius: float, profile: Resource, callback: Callable, spot := "", home: Vector3 = Vector3.INF, leash := INF, context: Dictionary = {}) -> int:
	_next_request += 1
	var interest: Vector3 = context.get("interest", Vector3.INF)
	var intent: String = str(context.get("intent", "Exploring somewhere new")) if interest.is_finite() else "Exploring somewhere new"
	var hot: Dictionary = layers.hot_spot(spot)
	if hot.is_empty() and not interest.is_finite():
		var local := _content.to_local(from)
		var nearby := layers.nearest_hot_spots(Vector2(local.x,local.z))
		if not nearby.is_empty() and randf() < .8: hot = nearby.slice(0, mini(4, nearby.size())).pick_random()
	if not hot.is_empty() and not interest.is_finite():
		interest = _content.to_global(Vector3(hot.pos.x,0,hot.pos.y)); interest.y = from.y
		intent = "Visiting " + str(hot.get("id", "a nearby place")).replace("_", " ")
	# Pick a reachable next stretch from resident ground. A 55 m outing used to wait
	# for 64 complete chunks before taking a single step, repeatedly timing out in
	# town. Only require the local neighbourhood; the worker may use farther cells
	# already resident, and later outings extend the journey as she moves.
	ensure_near(from, minf(radius, 8.0) + profile.radius)
	# A stroll needs some reachable ground, not every surrounding tile. Requiring
	# all four/nine tiles parked newly loaded residents behind cold sampling even
	# with a clear local route. The worker only traverses published safe cells;
	# missing neighbours remain impassable and continue loading at the normal budget.
	var start_chunk := WalkGrid.chunk_of(WalkGrid.column(from))
	_jobs.append({"id":_next_request,"kind":"wander","from":from,"radius":radius,"interest":interest,"intent":intent,"context":context.duplicate(true),"home":home,"leash":leash,"profile":WalkGrid.profile(profile),"chunks":[start_chunk],"callback":callback,"revision":revision})
	return _next_request

func closest(pos: Vector3, profile: Resource, radius := 1.0) -> Vector3:
	_sync_cells(grid.snapshot())
	var settings := WalkGrid.profile(profile)
	var sig := settings.hash()
	if radius < .5: return _closest_column(pos, settings, sig, radius)
	var key := _nearest_cached(pos, settings, _rooms_for(settings, sig), radius)
	return _cell_point(key) if key.y >= 0 else Vector3.INF

## Main-thread queries (steering, closest, trails) run many times per tick over the same
## few cells. Each cell is decoded once per published snapshot instead of once per query,
## and plain has_room results are kept per snapshot and profile. Both reset with it.
const CELL_CACHE_LIMIT := 32768
var _cells_for: Dictionary = {}
var _cells := {}
var _rooms := {}

func _sync_cells(data: Dictionary) -> void:
	if is_same(data, _cells_for) and _cells.size() < CELL_CACHE_LIMIT: return
	_cells_for = data; _cells = {}; _rooms = {}

## WalkGrid.sample(snapshot, key) for the snapshot given to _sync_cells. Read only.
func _cell(key: Vector3i) -> Dictionary:
	var s: Variant = _cells.get(key)
	if s == null:
		s = WalkGrid.sample(_cells_for, key)
		_cells[key] = s
	return s

## WalkGrid.sample(grid.snapshot(), key) from the same per-snapshot cache. Read only.
func cached_sample(key: Vector3i) -> Dictionary:
	_sync_cells(grid.snapshot())
	return _cell(key)

func _cell_point(key: Vector3i) -> Vector3:
	return Vector3((key.x+.5)*WalkGrid.CELL,_cell(key).get("height",NAN),(key.z+.5)*WalkGrid.CELL)

## closest() for radius < .5: this column's span with body room within `radius` of pos.
## _room_cache keeps its old lifetime (cleared on publish, not on eviction).
func _closest_column(pos: Vector3, settings: Dictionary, sig: int, radius: float) -> Vector3:
	var c := WalkGrid.column(pos)
	for span in WalkGrid.SPANS:
		var k := Vector3i(c.x,span,c.y)
		var point := _cell_point(k)
		if not point.is_finite() or absf(point.y-pos.y) > radius: continue
		var known: Variant = _room_cache.get(sig)
		if known == null: known = {}; _room_cache[sig] = known
		var room: Variant = known.get(k)
		if room == null:
			room = _pure_room(k, settings, _rooms_for(settings, sig))
			known[k] = room
		if room: return point
	return Vector3.INF

## This snapshot's has_room memo for a profile; a throwaway one if another profile
## shares its hash, so a collision can only cost time.
func _rooms_for(settings: Dictionary, sig: int) -> Dictionary:
	var entry: Variant = _rooms.get(sig)
	if entry == null:
		entry = [settings, {}]; _rooms[sig] = entry
	elif entry[0] != settings: return {}
	return entry[1]

## WalkGrid.has_room(snapshot, key, settings), memoised in `rooms` (from _rooms_for).
func _pure_room(key: Vector3i, settings: Dictionary, rooms: Dictionary) -> bool:
	var known: Variant = rooms.get(key)
	if known == null:
		known = _has_room_cached(key, settings)
		rooms[key] = known
	return known

## WalkGrid.has_room() reading cached samples.
func _has_room_cached(key: Vector3i, p: Dictionary) -> bool:
	var center := _cell(key)
	if not WalkGrid.allowed(center,p): return false
	var r := ceili(p.radius/WalkGrid.CELL)
	for z in range(-r,r+1):
		for x in range(-r,r+1):
			if x*x+z*z == 0 or Vector2(x,z).length()*WalkGrid.CELL > p.radius: continue
			var found := false
			for span in WalkGrid.SPANS:
				if WalkGrid.connected(center,_cell(Vector3i(key.x+x,span,key.z+z)),Vector2(x,z).length()*WalkGrid.CELL,p): found = true; break
			if not found: return false
	return true

## WalkGrid.nearest() reading cached samples and room results.
func _nearest_cached(pos: Vector3, p: Dictionary, rooms: Dictionary, radius: float) -> Vector3i:
	if NEAREST_BY_DISTANCE: return _nearest_by_distance(pos, p, rooms, radius)
	var c := WalkGrid.column(pos)
	var best := Vector3i(0,-1,0)
	var best_d := radius*radius
	var r := ceili(radius/WalkGrid.CELL)
	for z in range(-r,r+1):
		for x in range(-r,r+1):
			for span in WalkGrid.SPANS:
				var key := Vector3i(c.x+x,span,c.y+z)
				if not WalkGrid.allowed(_cell(key),p): continue
				var d := _cell_point(key).distance_squared_to(pos)
				if d <= best_d and _pure_room(key,p,rooms): best_d = d; best = key
	return best

## 0.1.0 perf: _nearest_cached() tested body room (25+ cells each) for every allowed cell that beat
## the running best in scan order. This collects the allowed cells first and tests them nearest
## first, stopping at the first with room: the same answer (smallest distance, a tie going to the
## later cell in scan order, as `d <= best_d` did) with one or two room tests instead of ~15.
## Rollback: NEAREST_BY_DISTANCE = false.
const NEAREST_BY_DISTANCE := true
var _near_keys: Array[Vector3i] = []
var _near_dist := PackedFloat64Array()

func _nearest_by_distance(pos: Vector3, p: Dictionary, rooms: Dictionary, radius: float) -> Vector3i:
	var c := WalkGrid.column(pos)
	var limit := radius*radius
	var r := ceili(radius/WalkGrid.CELL)
	_near_keys.clear(); _near_dist.clear()
	for z in range(-r,r+1):
		for x in range(-r,r+1):
			for span in WalkGrid.SPANS:
				var key := Vector3i(c.x+x,span,c.y+z)
				if not WalkGrid.allowed(_cell(key),p): continue
				var d := _cell_point(key).distance_squared_to(pos)
				if d <= limit: _near_keys.append(key); _near_dist.append(d)
	var count := _near_dist.size()
	while true:
		var best := -1
		var best_d := limit
		for i in count:
			if _near_dist[i] <= best_d: best_d = _near_dist[i]; best = i
		if best < 0: return Vector3i(0,-1,0)
		if _pure_room(_near_keys[best],p,rooms): return _near_keys[best]
		_near_dist[best] = INF
	return Vector3i(0,-1,0)

## True when nothing *known* along the segment is bad: every sample is walkable or lies
## in a chunk that is not sampled yet. Following a player over ground they just walked
## may proceed on the controller's physical probes while the grid catches up; a sampled
## cell that refuses stays a refusal.
func segment_unknown_or_clear(from: Vector3, to: Vector3, profile: Resource, respect_trails := false) -> bool:
	var length := Vector2(to.x-from.x, to.z-from.z).length()
	if length > 2.5: return false
	if steering_segment_clear(from, to, profile, respect_trails): return true
	var count := maxi(1, ceili(length / (WalkGrid.CELL * .5)))
	var any_unknown := false
	var previous := Vector3.INF
	for i in count + 1:
		var p := from.lerp(to, float(i) / count)
		var floor := closest(p, profile, .4)
		if floor.is_finite():
			if previous.is_finite() and not steering_segment_clear(previous, p, profile, respect_trails): return false
			previous = p
			continue
		var chunk := WalkGrid.chunk_of(WalkGrid.column(p))
		if not grid.chunks.has(chunk) or grid.chunks[chunk].state != WalkChunk.State.READY:
			ensure_chunk(chunk); any_unknown = true; previous = Vector3.INF; continue
		return false
	# A known disconnected step or grass shortcut is not an unknown-ground exception.
	return any_unknown


func is_walkable(pos: Vector3, profile: Resource) -> bool:
	var floor := closest(pos,profile,.4)
	return floor.is_finite() and Vector2(pos.x-floor.x,pos.z-floor.z).length() <= .2


func trail_weight_at(pos: Vector3) -> float:
	_sync_cells(grid.snapshot())
	var column := WalkGrid.column(pos)
	for span in WalkGrid.SPANS:
		var sample := _cell(Vector3i(column.x, span, column.y))
		if not sample.is_empty() and absf(float(sample.height)-pos.y) < .4:
			return float(sample.get("trail", 0.0))
	return 0.0


## A placed pony may already overlap the grid's clearance margin. Permit only a
## short departure to full-clearance ground; every centre cell must still have
## legal floor, slope, headroom and water. The caller also sweeps the physical body.
func escape_point(from: Vector3, locomotion: Resource) -> Vector3:
	if is_walkable(from, locomotion): return Vector3.INF
	var goal := closest(from, locomotion, locomotion.radius + WalkGrid.CELL * 2.0)
	if not goal.is_finite(): return Vector3.INF
	var planner := WalkPlanner.new()
	planner.data = grid.snapshot()
	planner.profile = WalkGrid.profile(locomotion)
	planner.profile.radius = 0.0
	var corridor := planner.corridor_segment(from, goal)
	return goal if not corridor.is_empty() and absf(corridor[0].y-from.y) < .4 else Vector3.INF


## Short, bounded steering checks reuse the per-column clearance cache. Unlike endpoint
## snapping this rejects a shortcut through a tree, cliff or disconnected bridge span.
func steering_segment_clear(from: Vector3, to: Vector3, locomotion: Resource, respect_trails := false) -> bool:
	var length := Vector2(to.x-from.x, to.z-from.z).length()
	if length > 2.5: return false
	var count := maxi(1, ceili(length / (WalkGrid.CELL * .5)))
	var settings := WalkGrid.profile(locomotion)
	var sig := settings.hash()
	_sync_cells(grid.snapshot())
	var minimum_trail := 0.0
	if respect_trails:
		minimum_trail = 1.0
		for endpoint in [from, to]:
			var column := WalkGrid.column(endpoint)
			var value := 0.0
			for span in WalkGrid.SPANS:
				var sample := _cell(Vector3i(column.x,span,column.y))
				if not sample.is_empty() and absf(sample.height-endpoint.y)<.4: value=maxf(value,float(sample.get("trail",0)))
			minimum_trail = minf(minimum_trail,value)
		minimum_trail -= .25
	var previous := {}
	var previous_key := Vector2i(2147483647, 2147483647)
	for i in count + 1:
		var p := from.lerp(to, float(i) / count)
		var floor := _closest_column(p, settings, sig, .4)
		if not floor.is_finite(): return false
		var cell := WalkGrid.column(floor)
		var current := {}
		for span in WalkGrid.SPANS:
			var sample := _cell(Vector3i(cell.x, span, cell.y))
			if not sample.is_empty() and absf(sample.height-floor.y) < .01:
				current = sample; break
		if current.is_empty() or float(current.get("trail", 0.0)) < minimum_trail: return false
		if not previous.is_empty() and cell != previous_key:
			if not WalkGrid.connected(previous, current, Vector2(cell-previous_key).length()*WalkGrid.CELL, settings): return false
			if cell.x != previous_key.x and cell.y != previous_key.y:
				for side in [Vector2i(cell.x, previous_key.y), Vector2i(previous_key.x, cell.y)]:
					var clear := false
					for span in WalkGrid.SPANS:
						var middle := _cell(Vector3i(side.x,span,side.y))
						if WalkGrid.connected(previous,middle,WalkGrid.CELL,settings) and WalkGrid.connected(middle,current,WalkGrid.CELL,settings): clear = true; break
					if not clear: return false
		previous = current; previous_key = cell
	return true

func nearby_places(at: Vector3, maximum := 30.0) -> Array:
	var result: Array = []
	if layers == null or not is_instance_valid(_content): return result
	for spot: Dictionary in layers.hot_spots:
		var position := _content.to_global(Vector3(spot.pos.x, 0, spot.pos.y))
		var distance := Vector2(position.x - at.x, position.z - at.z).length()
		if distance <= maximum:
			result.append({"id": spot.id, "name": str(spot.get("name", str(spot.id).replace("_", " "))), "kind": spot.kind, "distance": distance})
	result.sort_custom(func(a, b): return a.distance < b.distance)
	return result.slice(0, 3)


func hot_spot_world(id: String, near_y: float) -> Vector3:
	var spot := layers.hot_spot(id)
	if spot.is_empty(): return Vector3.INF
	var world := _content.to_global(Vector3(spot.pos.x,0,spot.pos.y))
	world.y = near_y
	return world

func spawn_world(id: String, index: int) -> Vector3:
	var chosen := Vector2.INF
	for spawn in layers.spawns:
		if spawn.id == id: chosen = spawn.pos; break
	if not chosen.is_finite() and index < layers.spawns.size(): chosen = layers.spawns[index].pos
	if not chosen.is_finite() and not layers.hot_spots.is_empty():
		var hot: Dictionary = layers.hot_spots[index%layers.hot_spots.size()]
		var angle := index*2.399963
		chosen = hot.pos+Vector2(cos(angle),sin(angle))*minf(hot.radius*.6,2.6)
	return _content.to_global(Vector3(chosen.x,0,chosen.y)) if chosen.is_finite() else Vector3.INF

## True while path request `request_id` is still queued only because chunks of its corridor are
## not READY yet (not admitted, being keyed, loading, sampled or painted). False when it is running,
## finished, cancelled, unknown, or waits only for a free search slot (2026-11-21, for the
## navigator's "Waiting for the ground to be sampled" reason).
func route_waits_on_sampling(request_id: int) -> bool:
	for job: Dictionary in _jobs:
		if int(job.id) != request_id: continue
		if str(job.kind) != "path": return false
		for c: Vector2i in job.chunks:
			if not grid.chunks.has(c) or grid.chunks[c].state != WalkChunk.State.READY: return true
		return false
	return false

func cancel_request(id: int) -> void:
	if id < 0: return
	for i in range(_jobs.size()-1,-1,-1):
		if _jobs[i].id == id: _jobs.remove_at(i)
	if not _running.is_empty(): _cancel_parallel(id)
	if not _active.is_empty() and _active.id == id:
		# With parallel searches running, _active can only be the GDScript fallback worker.
		if _native_busy and _running.is_empty():
			# The native intent is cancelled atomically and will never deliver a result.
			_cancel_native()
			_active = {}
			search_counts.busy_ms += (Time.get_ticks_usec()-_search_started)/1000.0
			search_counts.cancelled += 1
			return
		_cancelled[id] = true
		_active.cancel_signal.post()

func set_blocker(id: StringName, box: AABB) -> void:
	var prior: AABB = _blockers.get(id,box)
	_blockers[id] = box
	_invalidate(prior.merge(box))


## Physics geometry changed after the zone signature was made (world-editor vegetation).
## Transient collider states must never enter the original zone's disk cache.
func notify_geometry_changed(box: AABB) -> void:
	if not bounds.intersects(box): return
	box = bounds.intersection(box)
	var a := WalkGrid.chunk_of(WalkGrid.column(box.position - Vector3.ONE))
	var b := WalkGrid.chunk_of(WalkGrid.column(box.end + Vector3.ONE))
	var affected := false
	for z in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			var coord := Vector2i(x, z)
			_dynamic_chunks[coord] = true
			_session_keys.erase(coord)
			if chunk_keys and _chunk_keys.has(coord): _rekey[coord] = true
			if affected: continue
			affected = grid.chunks.has(coord) or coord in _active.get("chunks", [])
			for entry: Dictionary in _running:
				if coord in entry.job.chunks: affected = true
			for job: Dictionary in _jobs:
				if coord in job.chunks: affected = true; break
	_io_queue = _io_queue.filter(func(job): return job.kind != "save" or not _dynamic_blocks(job.coord))
	# The bodies there may have moved in place: read them again (their keys follow).
	if chunk_keys: _keys.notify(box, true)
	# Streaming distant trees must still forbid stale disk data, but cannot change a
	# route whose cached/requested coverage never included them. Keep pending chunks
	# and queued/active coverage here as well as READY chunks: those may hold old work.
	if affected: _invalidate(box)

## A house door came to rest shut. Only chunks sampled while a leaf was open can hold an
## open doorway; they alone are resampled, and navigators replan only if one was in use.
func door_settled_shut(box: AABB) -> void:
	if _door_tainted.is_empty(): return
	var area := Rect2(box.position.x-1.0, box.position.z-1.0, box.size.x+2.0, box.size.z+2.0)
	var published := false
	for c: Vector2i in _door_tainted.keys():
		if not _chunk_rect(c).intersects(area): continue
		_door_tainted.erase(c)
		if not grid.chunks.has(c): continue
		published = published or grid.chunks[c].state == WalkChunk.State.READY
		_reset_chunk(c)
	if published:
		revision += 1
		grid._snapshot_frame = -1
		_room_cache.clear()
		rebuild_started.emit()

func _door_open_over(c: Vector2i) -> bool:
	var doors := get_tree().get_nodes_in_group("open_house_doors")
	if doors.is_empty(): return false
	var rect := _chunk_rect(c).grow(1.0)
	for door: Node in doors:
		var box: AABB = door.navigation_world_box()
		if rect.intersects(Rect2(box.position.x, box.position.z, box.size.x, box.size.z)): return true
	return false

func _chunk_rect(c: Vector2i) -> Rect2:
	var size := WalkGrid.CHUNK_CELLS*WalkGrid.CELL
	return Rect2(Vector2(c)*size, Vector2(size, size))

func remove_blocker(id: StringName) -> void:
	if not _blockers.has(id): return
	var box: AABB = _blockers[id]
	_blockers.erase(id)
	_invalidate(box)

func _invalidate(box: AABB) -> void:
	revision += 1
	grid._snapshot_frame = -1
	_room_cache.clear()
	rebuild_started.emit()
	var a := WalkGrid.chunk_of(WalkGrid.column(box.position-Vector3.ONE))
	var b := WalkGrid.chunk_of(WalkGrid.column(box.end+Vector3.ONE))
	for z in range(a.y,b.y+1):
		for x in range(a.x,b.x+1):
			var c := Vector2i(x,z)
			_session_keys.erase(c)
			if grid.chunks.has(c): _reset_chunk(c)

func _reset_chunk(c: Vector2i) -> void:
	_door_tainted.erase(c)
	if not _queue.is_empty() and _queue[0] == c: _column = 0
	_queue.erase(c)
	if not _paint_queue.is_empty() and _paint_queue[0] == c: _paint_column = 0
	_paint_queue.erase(c)
	# Its ground changed: the samples get the key taken when this resampling ends.
	_key_queue.erase(c); _chunk_keys.erase(c); _key_retried.erase(c)
	var chunk := WalkChunk.new(); chunk.coord = c; chunk.allocate()
	chunk.state = WalkChunk.State.SAMPLING
	grid.chunks[c] = chunk; _queue.append(c)

func reload_layers() -> void:
	layers = MapLayers.load_zone(zone_id)
	_derive_base = _derive_signature()
	for chunk in grid.chunks.values():
		if chunk.state == WalkChunk.State.READY:
			chunk.state = WalkChunk.State.DERIVING
			_paint_queue.append(chunk.coord)
	_paint_column = 0
	revision += 1
	grid._snapshot_frame = -1
	_room_cache.clear()
	navigation_ready.emit()

func _paint_signature() -> String:
	var stamp := []
	for dir in [MapLayers.working_dir(zone_id),MapLayers.published_dir(zone_id)]:
		for file in ["layers.json","paint_trail.png","paint_avoid.png","paint_block.png","paint_ford.png","paint_lake.png","paint_bridge.png"]:
			var path: String = dir.path_join(file)
			stamp.append(FileAccess.get_file_as_string(path).sha256_text() if file == "layers.json" and FileAccess.file_exists(path) else FileAccess.get_modified_time(path))
	return str(stamp)

func _evict() -> bool:
	var protected := {}
	for job in _jobs.slice(0,1) + ([_active] if not _active.is_empty() else []):
		for c in job.chunks: protected[c] = true
	for entry: Dictionary in _running:
		for c in entry.job.chunks: protected[c] = true
	for c in urgent: protected[c] = true
	# Finish the column work in progress; queued speculative chunks can yield.
	if not _queue.is_empty(): protected[_queue[0]] = true
	if not _paint_queue.is_empty(): protected[_paint_queue[0]] = true
	# Chunks of every queued route too, while anything else can go (2026-11-21: with only the
	# oldest waiter protected, 100 cross-town routes at the Quest's cap evicted and reloaded 3743
	# chunks in 600 steps). When everything left is routed, today's rule: the oldest waiter still
	# admits its chunks. Order: least recently used (ensure_chunk refreshes it on every route
	# admission). Rollback: PROTECT_ROUTES = false.
	var routed := {}
	if PROTECT_ROUTES:
		for job: Dictionary in _jobs:
			for c in job.chunks: routed[c] = true
	var oldest := Vector2i.ZERO
	var frame := 9223372036854775807
	var free_oldest := Vector2i.ZERO
	var free_frame := 9223372036854775807
	for c in grid.chunks:
		if protected.has(c): continue
		var used: int = grid.chunks[c].last_used_frame
		if used < frame: frame = used; oldest = c
		if used < free_frame and not routed.has(c): free_frame = used; free_oldest = c
	if frame == 9223372036854775807: return false
	if free_frame != 9223372036854775807: oldest = free_oldest
	# READY-only eviction kept a full cache of unfinished samples and discarded
	# each freshly usable chunk. Evict the least recently needed work instead.
	_queue.erase(oldest)
	_paint_queue.erase(oldest)
	_io_queue = _io_queue.filter(func(job): return job.kind != "load" or job.coord != oldest)
	_door_tainted.erase(oldest)
	if _chunk_keys.has(oldest) and grid.chunks[oldest].state == WalkChunk.State.READY: _session_keys[oldest] = _chunk_keys[oldest]
	_admitted_at.erase(oldest)
	_key_queue.erase(oldest); _chunk_keys.erase(oldest); _key_retried.erase(oldest)
	grid.chunks.erase(oldest)
	grid._snapshot_frame = -1
	_counts["evicted"] = int(_counts.get("evicted", 0)) + 1
	return true

func debug_mesh(center: Vector3, radius := 12.0, water := false) -> ImmediateMesh:
	var mesh := ImmediateMesh.new()
	var data := grid.snapshot()
	var c := WalkGrid.column(center)
	var r := ceili(radius/WalkGrid.CELL)
	var count := 0
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for z in range(c.y-r,c.y+r+1,2):
		for x in range(c.x-r,c.x+r+1,2):
			for span in WalkGrid.SPANS:
				var key := Vector3i(x,span,z)
				var s := WalkGrid.sample(data,key)
				if s.is_empty(): continue
				var p := WalkGrid.point(data,key)+Vector3.UP*.035
				var color := Color(.15,.8,.3) if not (s.flags & WalkGrid.PAINT_BLOCK) else Color.RED
				if s.slope > 20 or s.clearance < 1.2: color = Color(.8,.25,.15)
				elif s.paint < 1: color = Color(1,.8,.2)
				if water: color = Color(.1,.8,1).lerp(Color(.1,.05,.7),clampf(s.water/.5,0,1))
				mesh.surface_set_color(color)
				for offset in [Vector3(-.1,0,0),Vector3(.1,0,0),Vector3(0,0,-.1),Vector3(0,0,.1)]: mesh.surface_add_vertex(to_local(p+offset))
				count += 4
				if count >= 8000: break
			if count >= 8000: break
		if count >= 8000: break
	if count == 0:
		mesh.surface_add_vertex(Vector3.ZERO); mesh.surface_add_vertex(Vector3.ZERO)
	mesh.surface_end()
	return mesh

## Zone unload: stop taking work and report when the workers are done, so ZoneManager can
## free the zone without _exit_tree blocking the main thread on a route search or cache IO.
func release() -> bool:
	ready_for_paths = false
	_join_draw_task()
	_release_native()
	if not _active.is_empty() and _active.has("cancel_signal"): _active.cancel_signal.post()
	_jobs.clear(); _queue.clear(); _key_queue.clear(); _paint_queue.clear(); _io_queue.clear()
	if _worker >= 0 and WorkerThreadPool.is_task_completed(_worker):
		WorkerThreadPool.wait_for_task_completion(_worker); _worker = -1
	if _io_worker >= 0 and WorkerThreadPool.is_task_completed(_io_worker):
		WorkerThreadPool.wait_for_task_completion(_io_worker); _io_worker = -1
	var parallel_done := _drain_parallel(false)
	return _worker < 0 and _io_worker < 0 and parallel_done

func _exit_tree() -> void:
	ready_for_paths = false
	_join_draw_task()
	_release_native()
	if not _active.is_empty() and _active.has("cancel_signal"): _active.cancel_signal.post()
	if _worker >= 0: WorkerThreadPool.wait_for_task_completion(_worker)
	if _io_worker >= 0: WorkerThreadPool.wait_for_task_completion(_io_worker)
	if _prune_worker >= 0:
		_prune_cancel[0] = true
		WorkerThreadPool.wait_for_task_completion(_prune_worker); _prune_worker = -1
	_drain_parallel(true)

## Worker: delete this zone's other cache folders untouched since `before` (unix seconds).
static func _prune_stale(root: String, prefix: String, keep: String, before: float, cancel: Array) -> void:
	for folder in DirAccess.get_directories_at(root):
		if bool(cancel[0]): return
		# zone_<64-hex hash> exactly: "house_" must not match another zone such as "house_b_...".
		if not folder.begins_with(prefix) or folder == keep or folder.length() != prefix.length() + 64: continue
		if not folder.substr(prefix.length()).is_valid_hex_number(): continue
		var path := root.path_join(folder)
		if FileAccess.get_modified_time(path) > before: continue
		if not _remove_tree(path, cancel): return

static func _remove_tree(path: String, cancel: Array) -> bool:
	for sub in DirAccess.get_directories_at(path):
		if not _remove_tree(path.path_join(sub), cancel): return false
	for file in DirAccess.get_files_at(path):
		if bool(cancel[0]): return false
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)
	return true

## Perf overhaul 2026-11-21 (lane walk_grid): one IO task carries up to IO_BATCH jobs, loads
## before saves (keyed caches only: a stale file is refused by its key). One job per physics step
## made a town of cached or baked chunks take 13 s and more to come back after load.
## Rollback: IO_BATCH = 1.
const IO_BATCH := 16
var _io_batch: Array[Dictionary] = []
var _io_results: Array = []

func _poll_io() -> void:
	if _io_worker >= 0 and WorkerThreadPool.is_task_completed(_io_worker):
		WorkerThreadPool.wait_for_task_completion(_io_worker); _io_worker = -1
		var batch := _io_batch
		var results := _io_results
		_io_batch = []; _io_results = []
		for i in batch.size():
			_io_job = batch[i]
			_io_loaded = results[i] as WalkChunk
			var c: Vector2i = _io_job.coord
			if _io_job.kind == "load" and grid.chunks.has(c) and grid.chunks[c].state == WalkChunk.State.QUEUED and _io_job.has("key"):
				_finish_keyed_load(c)
			elif _io_job.kind == "load" and grid.chunks.has(c) and grid.chunks[c].state == WalkChunk.State.QUEUED:
				if _io_job.derived:
					# The key is taken again now: a paint reload or control edit since the request
					# falls back to the sampled copy (or sampling) instead of stale derived data.
					if _io_loaded != null and _io_loaded.is_allocated() and _io_loaded.trail_weight.size() == _io_loaded.flags.size() \
							and _derive_cache and _blockers.is_empty() and not _dynamic_chunks.has(c) and _io_job.path == _derived_path(c):
						_io_loaded.state = WalkChunk.State.READY; _io_loaded.from_cache = true
						_io_loaded.painted = not layers.rasters.is_empty()
						_io_loaded.last_used_frame = Engine.get_physics_frames()
						grid.chunks[c] = _io_loaded
						grid._snapshot_frame = -1; _room_cache.clear(); generation += 1
						navigation_ready.emit()
					else:
						_admit(c, grid.chunks[c], false)
				elif _io_loaded != null and _io_loaded.is_allocated() and _io_job.revision == revision:
					_io_loaded.state = WalkChunk.State.DERIVING; _io_loaded.from_cache = true
					_io_loaded.last_used_frame = Engine.get_physics_frames()
					grid.chunks[c] = _io_loaded; _paint_queue.append(c)
				else:
					grid.chunks[c].allocate(); grid.chunks[c].state = WalkChunk.State.SAMPLING; _queue.append(c)
			_io_loaded = null; _io_job = {}
	if _io_worker < 0 and not _io_queue.is_empty():
		if chunk_keys and IO_BATCH > 1:
			for job: Dictionary in _io_queue:
				if job.kind == "load" and _io_batch.size() < IO_BATCH: _io_batch.append(job)
			for job: Dictionary in _io_queue:
				if job.kind != "load" and _io_batch.size() < IO_BATCH: _io_batch.append(job)
			for job: Dictionary in _io_batch: _io_queue.erase(job)
		else:
			_io_batch.append(_io_queue.pop_front())
		_io_results.resize(_io_batch.size())
		_io_worker = WorkerThreadPool.add_task(_cache_io_batch.bind(_io_batch, _io_results),false,"Terrain cache IO")

## Worker: every job of one batch; results[i] is the chunk a load read (or null).
func _cache_io_batch(batch: Array[Dictionary], results: Array) -> void:
	for i in batch.size():
		_cache_io(batch[i])
		results[i] = _io_loaded
		_io_loaded = null

## A keyed load came back: used only when the file's key is the one asked for and nothing
## invalidated the chunk meanwhile; a stale derived copy falls back to the sampled one, a stale
## sampled copy to sampling.
func _finish_keyed_load(c: Vector2i) -> void:
	var wanted := str(_chunk_keys.get(c, ""))
	var usable := _io_loaded != null and _io_loaded.is_allocated() and wanted != "" and _blockers.is_empty() \
		and not _dynamic_blocks(c)
	if _io_job.derived:
		if usable and _derive_cache and _io_loaded.trail_weight.size() == _io_loaded.flags.size() \
				and str(_io_loaded.get_meta("cache_key", "")) == _derive_key(c, wanted):
			_io_loaded.state = WalkChunk.State.READY; _io_loaded.from_cache = true
			_io_loaded.painted = not layers.rasters.is_empty()
			_io_loaded.last_used_frame = Engine.get_physics_frames()
			grid.chunks[c] = _io_loaded
			grid._snapshot_frame = -1; _room_cache.clear(); generation += 1
			_counts.loaded += 1; _counts.derived_loaded += 1
			if _io_job.has("baked"): _counts.baked += 1
			_note_ready(c, "baked_painted" if _io_job.has("baked") else "derived")
			navigation_ready.emit()
		else:
			_admit_keyed(c, grid.chunks[c], STAGE_SAMPLED)
	elif usable and str(_io_loaded.get_meta("cache_key", "")) == wanted:
		_io_loaded.state = WalkChunk.State.DERIVING; _io_loaded.from_cache = true
		_io_loaded.last_used_frame = Engine.get_physics_frames()
		grid.chunks[c] = _io_loaded; _paint_queue.append(c)
		_counts.loaded += 1
		if _io_job.has("baked"):
			_counts.baked += 1
			_io_loaded.set_meta("baked", true)
	elif _io_job.has("baked") and FileAccess.file_exists(_keyed_path(c, false, wanted)):
		# A baked chunk that failed to read: the user's own sampled copy, else sampling.
		_io_job.erase("baked")
		_io_queue.push_front({"kind":"load","coord":c,"revision":revision,"derived":false,"path":_keyed_path(c, false, wanted),"key":wanted})
	else:
		_admit_keyed(c, grid.chunks[c], STAGE_SAMPLE)

func _cache_io(job: Dictionary) -> void:
	var path: String = job.get("path", _cache_dir.path_join("%d_%d.res"%[job.coord.x,job.coord.y]))
	if job.kind == "load" and job.has("baked"):
		_io_loaded = BAKE.load_chunk(path, job.coord, job.baked)
		if _io_loaded != null:
			# Asked for its samples only: undo the bake's paint (this world paints differently).
			if not bool(job.derived): BAKE.strip_paint(_io_loaded)
			_io_loaded.set_meta("cache_key", str(job.key))
	elif job.kind == "load": _io_loaded = ResourceLoader.load(path,"",ResourceLoader.CACHE_MODE_IGNORE) as WalkChunk
	else: ResourceSaver.save(job.chunk,path)

## Keep the same queue class when a route discovers that it needs a detour.
## FIFO within the class lets other waiting customers get their turn too.
func _enqueue_path(job: Dictionary) -> void:
	var priority: bool=job.get("priority",false)
	var insertion: int=0
	while insertion<_jobs.size() and _jobs[insertion].kind=="path" and (not priority or _jobs[insertion].get("priority",false)):
		insertion+=1
	_jobs.insert(insertion,job)

func _expand_route(job: Dictionary, result: Dictionary) -> bool:
	if job.kind != "path" or not result.get("path",PackedVector3Array()).is_empty(): return false
	# An open search that ran out of budget: once more inside the corridor.
	if str(result.get("reason", "")) == BUDGET_REASON and _open_route(job):
		job["corridor_only"] = true
		_enqueue_path(job)
		return true
	var candidates: Array = result.get("frontier",[])
	var end_chunk := WalkGrid.chunk_of(WalkGrid.column(job.to))
	candidates.sort_custom(func(a,b): return Vector2(a-end_chunk).length_squared()<Vector2(b-end_chunk).length_squared())
	var added := 0
	for c in candidates:
		var center := Vector3((c.x+.5)*16.0,0,(c.y+.5)*16.0)
		if center.x+8 < bounds.position.x or center.x-8 > bounds.end.x or center.z+8 < bounds.position.z or center.z-8 > bounds.end.z: continue
		if c in job.chunks: continue
		if job.chunks.size() >= (int(_open_rules().route_chunks) if OPEN_ROUTES else ROUTE_CHUNKS):
			result.reason = "Route needs more than the resident chunk budget; no unsafe shortcut returned"
			break
		job.chunks.append(c); added += 1
		if added >= (int(_open_rules().expand_step) if OPEN_ROUTES else 12): break
	if added == 0: return false
	_enqueue_path(job)
	return true


func _terrain_controls_changed(locations: Array) -> void:
	if chunk_keys: _keys.drop_memo()
	var changed := false
	for coord: Vector2i in grid.chunks:
		var region := Vector2i(floori(float(coord.x*16)/WorldTerrain.REGION), floori(float(coord.y*16)/WorldTerrain.REGION))
		if region not in locations: continue
		var chunk: WalkChunk = grid.chunks[coord]
		if chunk.state in [WalkChunk.State.READY, WalkChunk.State.DERIVING]:
			chunk.state = WalkChunk.State.DERIVING
			if not _paint_queue.is_empty() and _paint_queue[0] == coord: _paint_column = 0
			if coord not in _paint_queue: _paint_queue.append(coord)
			changed = true
	if changed:
		revision += 1; grid._snapshot_frame = -1; _room_cache.clear()
	# Region hashes predate this edit, and chunks at a region edge are not re-derived.
	_derive_cache = false

## Inputs of _apply_paint that are not in the chunk itself: map paint rasters and their
## frame, the zone transform they are read through, and which Terrain3D textures are trails.
## Sampled arrays come from the same cache directory (its key covers geometry and terrain).
func _derive_signature() -> String:
	var parts: Array = [_content.global_transform, is_instance_valid(_terrain_paths.data), layers.cell, layers.origin, layers.size]
	var trails: Array = _terrain_paths.trail_ids.keys(); trails.sort(); parts.append(trails)
	var names: Array = layers.rasters.keys(); names.sort()
	for name: String in names:
		var digest := HashingContext.new(); digest.start(HashingContext.HASH_SHA256)
		digest.update((layers.rasters[name] as Image).get_data())
		parts.append([name, digest.finish().hex_encode()])
	return var_to_bytes(parts).hex_encode().sha256_text()

## Also keyed on the live control and height maps of every Terrain3D region the chunk's
## trail weights read (bilinear, so one metre past its far edge).
func _derived_path(c: Vector2i) -> String:
	return _cache_dir.path_join("derived/%d_%d_%s.res" % [c.x, c.y, _derive_stamp(c).sha256_text().substr(0, 24)])

func _derive_stamp(c: Vector2i) -> String:
	var stamp := _derive_base
	var size := WalkGrid.CHUNK_CELLS*WalkGrid.CELL
	for rz in range(floori(c.y*size/WorldTerrain.REGION), floori((c.y*size+size+1.0)/WorldTerrain.REGION)+1):
		for rx in range(floori(c.x*size/WorldTerrain.REGION), floori((c.x*size+size+1.0)/WorldTerrain.REGION)+1):
			var loc := Vector2i(rx, rz)
			if not _derive_regions.has(loc):
				var region: Object = _terrain_paths.data.get_region(loc) if is_instance_valid(_terrain_paths.data) else null
				_derive_regions[loc] = "-" if region == null else "%d.%d" % [hash(region.get_control_map().get_data()), hash(region.get_height_map().get_data())]
			stamp += ":" + _derive_regions[loc]
	return stamp
