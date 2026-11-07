extends Node3D
## Ground grass for the whole terrain (replaces TerrainGrass, 2026-09-23).
## Three LOD rings of world-grid tiles follow the camera. All tiles of a LOD share one
## MultiMesh of grid points; the shader finds each clump's ground, colour and coverage on
## the GPU, so moving costs only a few node moves per frame and no mesh rebuilding.
## Colour: an unshaded top-down render of the terrain only (the same albedo the ground
## shows, paint and biome included), refreshed when the camera travels ~48 m.
## Buildings/props: a footprint mask rasterized once from the town's colliders.
const SHADER := preload("res://world/foliage/grass/ground_grass.gdshader")
const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd")
const PROBE_LAYER := 1 << 19       # render layer 20: terrain only, for the colour probe
const PROBE_SIZE := 384.0          # metres covered by the colour probe
const PROBE_PIXELS := 512
const MASK_CELL := 0.5
# Coverage per Terrain3D texture id (world/terrain/textures.json): grass ids full,
# Everfree floor sparser, dirt sparse; paths, gravel, rock, sand, mud, snow none.
const DENSITY := {0: 1.0, 2: 1.0, 17: 1.0, 10: 1.0, 11: 0.55, 3: 0.05}
# Blades per m²: 80 near (20 per 0.5 m cell, mostly in tufts), 20 mid, ~2.7 far.
# Budget pass (dev 2026-10-18: "the grass ON ITS OWN is 1.2 million triangles"): the same blades
# with fewer segments where the curve no longer reads (3 to 8 m, 2 to 15 m, 1 beyond), smaller
# tiles that hug each ring, and a sparser, wider far ring. "group" is the distance band the
# quality tier's grass_rings counts (0 near, 1 mid, 2 far), so tiers keep the reach they had.
const LODS := [
	{"mesh": "res://world/foliage/grass/clump_lod0.res", "lite": "res://world/foliage/grass/clump_lod0_lite.res", "spacing": 0.5, "tile": 6.0, "inner": 0.0, "outer": 8.0, "width": 0.04, "tuft": 0.13, "fade": 0.0, "group": 0, "shared_outer": true},
	{"mesh": "res://world/foliage/grass/clump_lod1.res", "lite": "res://world/foliage/grass/clump_lod1_lite.res", "spacing": 0.5, "tile": 4.0, "inner": 8.0, "outer": 15.0, "width": 0.04, "tuft": 0.13, "fade": 0.0, "group": 0},
	{"mesh": "res://world/foliage/grass/clump_lod1_flat.res", "spacing": 1.0, "tile": 12.0, "inner": 15.0, "outer": 42.0, "width": 0.075, "tuft": 0.0, "fade": 0.0, "group": 1},
	{"mesh": "res://world/foliage/grass/clump_lod2.res", "spacing": 3.0, "tile": 48.0, "inner": 42.0, "outer": 125.0, "width": 0.21, "tuft": 0.0, "fade": 35.0, "group": 2},
]
## The 8-15 m ring uses 4 m tiles (was 8 m, dev 2026-10-23 triangle pass): with the 6 m dithered
## band each ring's tiles reach 4.5 m past both radii, and smaller squares hug that annulus,
## about 20% fewer triangles for that ring for a few more draws. "lite" meshes (fewer
## segments, same blades) replace the near rings' meshes on Medium and below (grass_lite_clumps).
## Blade rings (everything but the flowers) are fixed ring-shaped sets of grid cells, built once
## per quality change from the cells inside that ring plus its dithered band, split into
## camera-relative square chunks of the ring's tile size (fine enough to frustum-cull; 30-degree
## slices were not) and moved with the camera in whole-cell steps (dev 2026-10-23 grass rewrite:
## world tiles drew 2-4x the blades each ring keeps). Cells stay on the same world lattice, so
## every blade keeps its hash and spot. Spacings must be binary-exact (0.5, 1, 3) for that; the
## 0.4 m flower ring keeps world tiles.
const BAND := 6.0  # ground_grass.gdshader band default
## Narrower dither where neighbouring rings differ only in blade segments (8 m) or little (15 m);
## both rings at a boundary use the same value, so each blade is kept by exactly one of them.
const BOUNDARY_BANDS := {8.0: 1.0, 15.0: 3.0}
## Tiles are kept while any part of them is within this distance of their ring (the rings move
## with the camera every metre).
const TILE_MARGIN := 1.5

# Wildflowers ride the same tiling (ground_flowers.gdshader): one possible flower per cell.
const FLOWERS := {"mesh": "", "shader": "res://world/foliage/grass/ground_flowers.gdshader", "spacing": 0.4, "tile": 12.0,
	"inner": 0.0, "outer": 34.0, "width": 0.0, "tuft": 0.0, "fade": 8.0}

var terrain: Node          # WorldTerrain
var rings: Array = []      # per LOD: {material, multimesh, tiles: {Vector2i: MultiMeshInstance3D}, free: []}
var probe: SubViewport
var probe_camera: Camera3D
var probe_centre := Vector2(INF, INF)
## The probe blurred over about 1.2 m, rendered after each probe update (blades read it once).
var probe_soft: SubViewport
var _soft_frames := 0
var _soft_rect := Vector4.ZERO
const SOFT_BLUR := """shader_type canvas_item;
uniform sampler2D src : filter_linear, repeat_disable;
uniform vec2 step_uv;
void fragment() {
	vec4 c = texture(src, UV);
	vec3 sum = c.rgb * 2.0 + texture(src, UV + vec2(step_uv.x, 0.0)).rgb + texture(src, UV - vec2(step_uv.x, 0.0)).rgb
		+ texture(src, UV + vec2(0.0, step_uv.y)).rgb + texture(src, UV - vec2(0.0, step_uv.y)).rgb;
	COLOR = vec4(sum / 6.0, c.a);
}"""
var mask_image: Image
var mask_texture: ImageTexture
var mask_rect := Rect2()
var _last_camera := Vector3(INF, INF, INF)
var _mask_pending := true
var _contact_ground_cache: Dictionary = {}
var _contact_ground_cache_active := false
var _maps := []
var _frames := 0
var _exclusions: Dictionary = {}
var _exclusion_texture: ImageTexture
var _exclusion_uploads := 0
var _exclusion_centre := Vector2(INF,INF)
var _active_exclusions: Array[Dictionary] = []
var _density := 1.0
static var _clip_shaders: Dictionary = {}

func _ready() -> void:
	add_to_group("grass_footprints")
	terrain = get_parent()
	terrain.terrain.render_layers |= PROBE_LAYER
	_build_probe()
	var data: Object = terrain.terrain.data
	var region_map: PackedInt32Array = data.get_region_map()
	var ids := PackedFloat32Array(); ids.resize(32)
	for id: int in DENSITY: ids[id] = DENSITY[id]
	for lod: Dictionary in LODS + [FLOWERS]:
		var mm := MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = load(lod.mesh) if lod.mesh != "" else _flower_mesh()
		var n := int(round(float(lod.tile) / float(lod.spacing)))
		mm.instance_count = n * n
		# Cells in a fixed shuffled order, so a lower density draws fewer instances spread evenly
		# over the tile (set_density) instead of collapsing blades in the shader after paying for
		# their triangles (dev 2026-10-22: "on low mode why is there 460k triangles worth of grass").
		var order: Array[int] = []
		for k in n * n: order.append(k)
		var rng := RandomNumberGenerator.new(); rng.seed = 7741 + n
		for k in range(order.size() - 1, 0, -1):
			var r := rng.randi_range(0, k); var swap := order[k]; order[k] = order[r]; order[r] = swap
		for slot in order.size():
			var i := order[slot] / n; var j := order[slot] % n
			mm.set_instance_transform(slot, Transform3D(Basis(), Vector3((i + 0.5) * lod.spacing, 0, (j + 0.5) * lod.spacing)))
		var mat := ShaderMaterial.new(); mat.shader = load(lod.shader) if lod.has("shader") else SHADER
		mat.set_shader_parameter("region_map", region_map)
		mat.set_shader_parameter("region_size", float(terrain.terrain.region_size))
		mat.set_shader_parameter("vertex_spacing", float(terrain.terrain.vertex_spacing))
		mat.set_shader_parameter("id_density", ids)
		mat.set_shader_parameter("spacing", float(lod.spacing))
		mat.set_shader_parameter("blade_width", float(lod.width))
		mat.set_shader_parameter("tuft_radius", float(lod.tuft))
		mat.set_shader_parameter("inner_radius", float(lod.inner))
		mat.set_shader_parameter("outer_radius", float(lod.outer))
		mat.set_shader_parameter("fade_out", float(lod.fade))
		mat.set_shader_parameter("shared_outer", bool(lod.get("shared_outer", false)))
		mat.set_shader_parameter("inner_band", float(BOUNDARY_BANDS.get(float(lod.inner), BAND)))
		mat.set_shader_parameter("outer_band", float(BOUNDARY_BANDS.get(float(lod.outer), BAND)))
		if not lod.has("shader"): mat.set_shader_parameter("coverage", 1.0)
		mat.set_shader_parameter("ground_color", probe.get_texture())
		mat.set_shader_parameter("ground_color_soft", probe_soft.get_texture())
		rings.append({"lod": lod, "material": mat, "multimesh": mm, "tiles": {}, "free": [], "inner": float(lod.inner), "outer": float(lod.outer), "enabled": true,
			"sectored": not lod.has("shader"), "sectors": [], "snap": Vector2i(2147483647, 0), "heights_at": Vector2(INF, INF)})

	_upload_exclusions()
	_restore_deployed_footprints()
	_bind_maps()
	_apply_quality(0)
	var quality := get_node_or_null("/root/Quality")
	if quality != null: quality.preset_changed.connect(_apply_quality)

## Coverage scale (player's grass density x quality tier, Settings.apply_grass): keep that share of
## the world's grass cells, picked by a hash of each cell so the same blades stay as the camera-
## relative rings move (dev 2026-10-23: thinning by instance count made grass shift at 75 %).
## Dropped cells exit the vertex shader before any ground lookup. Flowers keep their own count.
## Below 100% the chunks leave out whole cells by a 4x4 world pattern (THIN), so fewer blades are
## submitted at all (dev 2026-10-23: 50% cost the same as 100% when the shader rejected them).
## The pattern stays put in the world because the chunks then move in steps of 4 cells.
const THIN_CELLS := 4
const THIN := [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

func set_density(scale: float) -> void:
	var before := _thin_level(_density)
	_density = scale
	for ring: Dictionary in rings:
		if (ring.lod as Dictionary).has("shader"): continue
		(ring.material as ShaderMaterial).set_shader_parameter("coverage", 1.0)
		if _thin_level(scale) != before: _build_sectors(ring)
	visible = scale > 0.0

## Cells kept out of every 16 for a coverage.
static func _thin_level(scale: float) -> int:
	return clampi(roundi(clampf(scale, 0.0, 1.0) * 16.0), 0, 16)

## Quality tier: grass_range_mul scales every ring's radii and fade (Low 0.7, Very Low 0.6) and
## grass_rings keeps only the first N blade rings (Very Low 2: LOD0 + LOD1, nothing past ~25 m).
## The flower ring follows the range multiplier only. Coverage (grass_density) is applied by
## Settings.apply_grass on top of the player's own density.
func _apply_quality(_preset: int) -> void:
	var loop := Engine.get_main_loop() as SceneTree
	var quality: Node = loop.root.get_node_or_null("Quality") if loop != null else null
	var mul: float = float(quality.get_value("grass_range_mul", 1.0)) if quality != null else 1.0
	var count: int = int(quality.get_value("grass_rings", 3)) if quality != null else 3
	var lite: bool = bool(quality.get_value("grass_lite_clumps", false)) if quality != null else false
	for i in rings.size():
		var ring: Dictionary = rings[i]
		var lod: Dictionary = ring.lod
		ring.enabled = lod.has("shader") or int(lod.get("group", i)) < count
		if bool(ring.sectored):
			ring.mesh = load(lod.lite if lite and lod.has("lite") else lod.mesh)
		ring.inner = float(lod.inner) * mul
		ring.outer = float(lod.outer) * mul
		var mat: ShaderMaterial = ring.material
		mat.set_shader_parameter("inner_radius", ring.inner)
		mat.set_shader_parameter("outer_radius", ring.outer)
		mat.set_shader_parameter("fade_out", float(lod.fade) * mul)
		if not ring.enabled:
			var tiles: Dictionary = ring.tiles
			for key: Vector2i in tiles.keys():
				var node: MultiMeshInstance3D = tiles[key]; node.visible = false
				(ring.free as Array).append(node); tiles.erase(key)
	for ring: Dictionary in rings:
		if bool(ring.sectored): _build_sectors(ring)
	_last_camera = Vector3(INF, INF, INF)
	if _exclusion_texture != null: _upload_exclusions()

## One flower: a stem quad (COLOR.r 0) and a head quad (COLOR.r 1); the shader places both.
static func _flower_mesh() -> ArrayMesh:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for part in 2:
		var corners := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]
		for c: Vector2 in corners:
			st.set_color(Color(part, 0, 0)); st.set_uv(c); st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(c.x - 0.5, c.y * 0.3, 0.0))
	# Shared corners: 8 vertices instead of 12, so the vertex shader runs a third less per cell.
	st.index()
	var mesh := st.commit()
	# Vertices are moved in the shader: give culling a generous box around the cell.
	mesh.custom_aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	return mesh

## Terrain3D replaces its map arrays when regions or sculpts change: rebind on a new RID.
func _bind_maps() -> void:
	var data: Object = terrain.terrain.data
	var now := [data.get_height_maps_rid(), data.get_control_maps_rid()]
	if now == _maps: return
	# Diagnostic (dev 2026-10-23: grass and flowers jump to the player's altitude while flying):
	# a stale binding would read an emptied height texture until this rebind.
	if not _maps.is_empty(): print("[grass] terrain maps replaced, rebinding at frame %d (camera y %.1f)" % [Engine.get_process_frames(), _last_camera.y])
	_maps = now
	for ring: Dictionary in rings:
		var rid: RID = (ring.material as ShaderMaterial).get_rid()
		RenderingServer.material_set_param(rid, "height_maps", now[0])
		RenderingServer.material_set_param(rid, "control_maps", now[1])
		(ring.material as ShaderMaterial).set_shader_parameter("region_map", data.get_region_map())

func _process(_delta: float) -> void:
	if not CPU_PROFILE.enabled:
		_profiled_process(_delta)
		return
	var started := Time.get_ticks_usec()
	_profiled_process(_delta)
	CPU_PROFILE.record("ground_grass", started)

func _profiled_process(_delta: float) -> void:
	_frames += 1
	if _frames % 60 == 0: _bind_maps()
	var camera := preload("res://world/player_view.gd").camera(self)
	if camera == null: return
	var eye := camera.global_position
	_update_exclusion_window(eye)
	if _mask_pending:
		_mask_pending = false; rebuild_mask()
	if Vector2(eye.x, eye.z).distance_to(probe_centre) > 48.0: _move_probe(eye)
	if _soft_frames > 0:
		_soft_frames -= 1
		if _soft_frames == 0: _apply_soft()
	for ring: Dictionary in rings:
		if bool(ring.sectored): _update_sectors(ring, eye)
	if eye.distance_to(_last_camera) < 1.0: return
	_last_camera = eye
	for ring: Dictionary in rings:
		if not bool(ring.sectored): _update_ring(ring, eye)

func _update_ring(ring: Dictionary, eye: Vector3) -> void:
	if not bool(ring.get("enabled", true)): return
	var lod: Dictionary = ring.lod
	var size := float(lod.tile)
	var outer := float(ring.get("outer", lod.outer))
	var inner := float(ring.get("inner", lod.inner))
	var reach := outer + size
	var lo := Vector2i(floori((eye.x - reach) / size), floori((eye.z - reach) / size))
	var hi := Vector2i(floori((eye.x + reach) / size), floori((eye.z + reach) / size))
	var wanted := {}
	# The shader's dithered ring edges reach half its band past each radius.
	var edge := TILE_MARGIN + 3.0
	for x in range(lo.x, hi.x + 1):
		for z in range(lo.y, hi.y + 1):
			# Exact nearest and farthest distance from the eye to the tile square.
			var x0 := x * size; var x1 := x0 + size; var z0 := z * size; var z1 := z0 + size
			var near := Vector2(maxf(maxf(x0 - eye.x, 0.0), eye.x - x1), maxf(maxf(z0 - eye.z, 0.0), eye.z - z1)).length()
			var far := Vector2(maxf(absf(eye.x - x0), absf(eye.x - x1)), maxf(absf(eye.z - z0), absf(eye.z - z1))).length()
			if near > outer + edge or far < inner - edge: continue
			wanted[Vector2i(x, z)] = true
	var tiles: Dictionary = ring.tiles
	for key: Vector2i in tiles.keys():
		if not wanted.has(key):
			var node: MultiMeshInstance3D = tiles[key]; node.visible = false
			(ring.free as Array).append(node); tiles.erase(key)
	for key: Vector2i in wanted:
		if tiles.has(key): continue
		var node: MultiMeshInstance3D = (ring.free as Array).pop_back() if not (ring.free as Array).is_empty() else _new_tile(ring)
		node.position = Vector3(key.x * size, 0, key.y * size)
		node.custom_aabb = _tile_bounds(key, size)
		node.visible = true
		tiles[key] = node

## The ring's cells (camera cell at the origin) grouped into square chunks, each its own
## MultiMesh. Density thins by world cell in the shader (`coverage`), never by instance count. Cells reach past the
## ring by half the shader band plus cell and tuft slack, so no kept blade is ever missing.
func _build_sectors(ring: Dictionary) -> void:
	for node: MultiMeshInstance3D in ring.sectors: node.queue_free()
	ring.sectors = []
	ring.snap = Vector2i(2147483647, 0)
	ring.heights_at = Vector2(INF, INF)
	if not bool(ring.enabled): return
	var lod: Dictionary = ring.lod
	var spacing := float(lod.spacing)
	var level := _thin_level(_density)
	var steps := 1 if level >= 16 else THIN_CELLS
	ring.snap_cells = steps
	# The camera can sit anywhere in the first `steps` cells of the chunk origin.
	var slack := spacing * 1.5 + float(lod.tuft) + 0.25 + (steps - 1) * spacing * 0.71
	var inner := float(ring.inner)
	var low := maxf(0.0, inner - float(BOUNDARY_BANDS.get(float(lod.inner), BAND)) * 0.5 - slack) if inner > 0.0 else 0.0
	var high := float(ring.outer) + float(BOUNDARY_BANDS.get(float(lod.outer), BAND)) * 0.5 + slack
	ring.reach = high
	var n := ceili(high / spacing) + steps
	var centre := Vector2(spacing, spacing) * 0.5 * steps
	var chunk := float(lod.tile)
	var buckets := {}
	for i in range(-n, n + 1):
		for j in range(-n, n + 1):
			var cell := Vector2((i + 0.5) * spacing, (j + 0.5) * spacing)
			var d := cell.distance_to(centre)
			if d < low or d > high: continue
			if level < 16 and THIN[posmod(i, THIN_CELLS) * THIN_CELLS + posmod(j, THIN_CELLS)] >= level: continue
			var key := Vector2i(floori(cell.x / chunk), floori(cell.y / chunk))
			if not buckets.has(key): buckets[key] = []
			(buckets[key] as Array).append(cell)
	var rng := RandomNumberGenerator.new()
	for key: Vector2i in buckets:
		var cells: Array = buckets[key]
		rng.seed = 7741 + key.x * 7919 + key.y * 31 + int(spacing * 8.0)
		for k in range(cells.size() - 1, 0, -1):
			var r := rng.randi_range(0, k); var swap: Vector2 = cells[k]; cells[k] = cells[r]; cells[r] = swap
		var buffer := PackedFloat32Array(); buffer.resize(cells.size() * 12)
		var lo := Vector2(INF, INF); var hi := Vector2(-INF, -INF)
		for k in cells.size():
			var c: Vector2 = cells[k]
			var o := k * 12
			buffer[o] = 1.0; buffer[o + 3] = c.x; buffer[o + 5] = 1.0; buffer[o + 10] = 1.0; buffer[o + 11] = c.y
			lo = lo.min(c); hi = hi.max(c)
		var mm := MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = ring.mesh
		mm.instance_count = cells.size()
		mm.buffer = buffer
		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		node.material_override = ring.material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		node.top_level = true
		# Whole-cell steps must not be smoothed into a slide.
		node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		node.set_meta("xz", Rect2(lo - Vector2(2, 2), hi - lo + Vector2(4, 4)))
		add_child(node)
		(ring.sectors as Array).append(node)

## Moves the ring's slices with the camera in whole cells; refreshes their culling height range
## from terrain samples every 8 m.
func _update_sectors(ring: Dictionary, eye: Vector3) -> void:
	if (ring.sectors as Array).is_empty(): return
	var spacing := float(ring.lod.spacing)
	var steps := int(ring.get("snap_cells", 1))
	var snap := Vector2i(floori(eye.x / (spacing * steps)) * steps, floori(eye.z / (spacing * steps)) * steps)
	if snap == ring.snap: return
	ring.snap = snap
	var at := Vector3(snap.x * spacing, 0.0, snap.y * spacing)
	var refresh := Vector2(at.x, at.z).distance_to(ring.heights_at) > 8.0
	var lo_y := 0.0; var hi_y := 0.0
	if refresh:
		ring.heights_at = Vector2(at.x, at.z)
		var reach := float(ring.reach)
		lo_y = INF; hi_y = -INF
		for i in 5:
			for j in 5:
				var h: float = terrain.height_at(Vector3(at.x + (i - 2) * reach * 0.5, 0, at.z + (j - 2) * reach * 0.5))
				if is_finite(h) and h > -1e5: lo_y = minf(lo_y, h); hi_y = maxf(hi_y, h)
		if lo_y == INF: lo_y = eye.y - 50.0; hi_y = eye.y + 50.0
		lo_y = minf(lo_y, eye.y - 30.0) - 10.0; hi_y = maxf(hi_y, eye.y) + 10.0
	for node: MultiMeshInstance3D in ring.sectors:
		node.position = at
		if refresh:
			var xz: Rect2 = node.get_meta("xz")
			node.custom_aabb = AABB(Vector3(xz.position.x, lo_y, xz.position.y), Vector3(xz.size.x, hi_y - lo_y, xz.size.y))

func _new_tile(ring: Dictionary) -> MultiMeshInstance3D:
	var node := MultiMeshInstance3D.new()
	node.multimesh = ring.multimesh
	node.material_override = ring.material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	node.top_level = true
	add_child(node)
	return node

func _tile_bounds(key: Vector2i, size: float) -> AABB:
	# Local bounds for culling: the tile's height range from a few terrain samples.
	var lo := INF; var hi := -INF
	for i in 3:
		for j in 3:
			var h: float = terrain.height_at(Vector3((key.x + i * 0.5) * size, 0, (key.y + j * 0.5) * size))
			if is_finite(h) and h > -1e5: lo = minf(lo, h); hi = maxf(hi, h)
	if lo == INF: lo = -1.0; hi = 1.0
	return AABB(Vector3(-2, lo - 3.0, -2), Vector3(size + 4, hi - lo + 7.0, size + 4))

# ------------------------------------------------------------------ colour probe
func _build_probe() -> void:
	probe = SubViewport.new(); probe.name = "GrassColourProbe"
	probe.size = Vector2i(PROBE_PIXELS, PROBE_PIXELS)
	probe.render_target_update_mode = SubViewport.UPDATE_DISABLED
	probe.debug_draw = Viewport.DEBUG_DRAW_UNSHADED
	probe.transparent_bg = true
	probe.msaa_3d = Viewport.MSAA_DISABLED
	probe.positional_shadow_atlas_size = 0
	add_child(probe)
	probe_camera = Camera3D.new()
	# A data snapshot must use the exact rect below, never an interpolated camera pose.
	# UPDATE_ONCE otherwise freezes road/river colours tens of metres from their roots.
	probe_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	probe_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	probe_camera.size = PROBE_SIZE
	probe_camera.cull_mask = PROBE_LAYER
	probe_camera.near = 1.0; probe_camera.far = 4000.0
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	probe_camera.environment = env
	probe_camera.rotation = Vector3(-PI / 2, 0, 0)
	probe.add_child(probe_camera)
	probe_soft = SubViewport.new(); probe_soft.name = "GrassColourSoft"
	probe_soft.size = Vector2i(PROBE_PIXELS, PROBE_PIXELS)
	probe_soft.disable_3d = true
	probe_soft.transparent_bg = true
	probe_soft.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(probe_soft)
	var blur := ColorRect.new()
	blur.size = Vector2(PROBE_PIXELS, PROBE_PIXELS)
	var blur_shader := Shader.new(); blur_shader.code = SOFT_BLUR
	var blur_material := ShaderMaterial.new(); blur_material.shader = blur_shader
	blur_material.set_shader_parameter("src", probe.get_texture())
	blur_material.set_shader_parameter("step_uv", Vector2.ONE * 1.2 / PROBE_SIZE)
	blur.material = blur_material
	probe_soft.add_child(blur)

func _move_probe(eye: Vector3) -> void:
	probe_centre = Vector2(eye.x, eye.z).snapped(Vector2(16, 16))
	probe_camera.position = Vector3(probe_centre.x, eye.y + 1500.0, probe_centre.y)
	probe.render_target_update_mode = SubViewport.UPDATE_ONCE
	_soft_frames = 2   # blur the new probe image once it has rendered
	# Looking straight down with -Z up the image: texture v grows with world +z.
	# The blades read only the soft copy: its rect changes with it, two frames later.
	_soft_rect = Vector4(probe_centre.x - PROBE_SIZE * 0.5, probe_centre.y - PROBE_SIZE * 0.5, PROBE_SIZE, PROBE_SIZE)

## Blur the probe's latest image and move the blades' colour rect with it.
func _apply_soft() -> void:
	_soft_frames = 0
	probe_soft.render_target_update_mode = SubViewport.UPDATE_ONCE
	for ring: Dictionary in rings: (ring.material as ShaderMaterial).set_shader_parameter("ground_color_rect", _soft_rect)

## Season look changed (snow, ground tint): render the colour probe again, nothing else.
func refresh_colour() -> void:
	probe_centre = Vector2(INF, INF)

## Paint/sculpt edits change the ground colour: render the probe again.
func notify_terrain_changed(_area: Rect2 = Rect2()) -> void:
	probe_centre = Vector2(INF, INF)
	_last_camera = Vector3(INF, INF, INF)
	_bind_maps()
	_mask_pending = true

# ------------------------------------------------------------------ reversible deployed footprints
## Shared lifecycle contract: picnic:<saved loan token>, world frame, local half-size.
func set_footprint(owner_token: String, frame: Transform3D, half_extents: Vector2) -> bool:
	return add_exclusion(owner_token,frame,half_extents)

func remove_footprint(owner_token: String) -> void:
	remove_exclusion(owner_token)

## Grass can be reconstructed after the cloth. Rebind existing deployed owners once.
func _restore_deployed_footprints() -> void:
	for item: Node in get_tree().get_nodes_in_group("picnic_blankets"):
		if not item is Node3D or not ("loan_token" in item): continue
		var token := str(item.get("loan_token"))
		if token != "": set_footprint("picnic:" + token,(item as Node3D).global_transform,Vector2(1.2,1.0))
	# Fixed things that sit in the grass (the plaza game table, plaza_table.gd): meta "grass_key"
	# and "grass_half", the local half-size of their patch.
	for fixed: Node in get_tree().get_nodes_in_group("grass_patches"):
		if fixed is Node3D and fixed.has_meta("grass_key"): set_footprint(str(fixed.get_meta("grass_key")), (fixed as Node3D).global_transform, fixed.get_meta("grass_half"))
	# Open folding game boards (world/minigames/board_games/board_fold.gd) clear their patch too.
	for board: Node in get_tree().get_nodes_in_group("open_game_boards"):
		if board is Node3D: load("res://world/minigames/board_games/board_fold.gd").clear_grass(board, true)

## Token ownership is session-local; restored deployed items register from their saved pose.
## Project the local X/Z rectangle onto ground X/Z, keeping yaw, scale and slope exact.
func add_exclusion(owner_token: String, frame: Transform3D, half_extents: Vector2) -> bool:
	if owner_token.is_empty() or not frame.origin.is_finite() or (not frame.basis.x.is_finite() or not frame.basis.y.is_finite() or not frame.basis.z.is_finite()) or not half_extents.is_finite() or half_extents.x <= 0.0 or half_extents.y <= 0.0: return false
	var x := Vector2(frame.basis.x.x,frame.basis.x.z)
	var z := Vector2(frame.basis.z.x,frame.basis.z.z)
	var determinant := x.cross(z)
	if absf(determinant) < 0.000001: return false
	var centre := Vector2(frame.origin.x,frame.origin.z)
	var extent := x.abs()*half_extents.x + z.abs()*half_extents.y
	var row := {"centre":centre,"half":half_extents,"inverse":Vector4(z.y,-z.x,-x.y,x.x)/determinant,"bounds":Rect2(centre-extent,extent*2.0)}
	if _exclusions.get(owner_token,{}) == row: return true
	_exclusions[owner_token] = row
	_upload_exclusions()
	return true

func remove_exclusion(owner_token: String) -> void:
	if not _exclusions.has(owner_token): return
	_exclusions.erase(owner_token)
	_upload_exclusions()

## Same containment math as the shader, exposed for deterministic lifecycle checks.
func exclusion_contains(point: Vector2) -> bool:
	for row: Dictionary in _exclusions.values():
		var delta: Vector2 = point - (row.centre as Vector2)
		var inverse: Vector4 = row.inverse
		var local := Vector2(inverse.x*delta.x + inverse.y*delta.y,inverse.z*delta.x + inverse.w*delta.y)
		var half: Vector2 = row.half
		if absf(local.x) <= half.x and absf(local.y) <= half.y: return true
	return false

func _set_exclusion_shader(ring: Dictionary, active: bool) -> void:
	var material: ShaderMaterial = ring.material
	if not ring.has("base_shader"): ring.base_shader = material.shader
	if bool(ring.get("fragment_clip",false)) == active: return
	var base: Shader = ring.base_shader
	if not _clip_shaders.has(base):
		var clipped := Shader.new()
		clipped.code = "#define DEPLOYED_FRAGMENT_CLIP\n" + base.code
		_clip_shaders[base] = clipped
	# Shader replacement can clear local parameters. Preserve renderer-bound RID maps
	# as well as ordinary material resources, then restore after choosing the variant.
	var parameters: Dictionary = {}
	for uniform: Dictionary in material.shader.get_shader_uniform_list():
		var name := StringName(uniform.name)
		var value: Variant = RenderingServer.material_get_param(material.get_rid(),name)
		if value != null: parameters[name] = value
	material.shader = _clip_shaders[base] if active else base
	for name: StringName in parameters:
		var value: Variant = parameters[name]
		if value is RID: RenderingServer.material_set_param(material.get_rid(),name,value)
		else: material.set_shader_parameter(name,value)
	ring.fragment_clip = active

func _update_exclusion_window(eye: Vector3) -> void:
	# A 16 m window step amortizes the CPU query; its extra margin covers the full step.
	var centre := Vector2(eye.x,eye.z).snapped(Vector2(16,16))
	if centre == _exclusion_centre: return
	_exclusion_centre = centre
	_upload_exclusions()

func _upload_exclusions() -> void:
	if not _exclusion_centre.is_finite() and is_inside_tree():
		var camera := preload("res://world/player_view.gd").camera(self)
		if camera != null: _exclusion_centre = Vector2(camera.global_position.x,camera.global_position.z).snapped(Vector2(16,16))
	# Shared ring materials see only footprints in the camera's drawn tile area, never
	# every blanket in the save. Include tile corners, shader jitter and window margin.
	var reach := 210.0
	for ring: Dictionary in rings:
		if not bool(ring.get("enabled",true)): continue
		var lod: Dictionary = ring.get("lod",{})
		reach = maxf(reach,float(ring.get("outer",125.0)) + float(lod.get("tile",48.0))*1.5 + 20.0)
	var area := Rect2(_exclusion_centre-Vector2.ONE*reach,Vector2.ONE*reach*2.0)
	var active: Array[Dictionary] = []
	var bounds := Rect2()
	for row: Dictionary in _exclusions.values():
		var footprint: Rect2 = row.bounds
		if _exclusion_centre.is_finite() and not area.intersects(footprint,true): continue
		bounds = footprint if active.is_empty() else bounds.merge(footprint)
		active.append(row)
	if _exclusion_texture != null and active == _active_exclusions: return
	_active_exclusions = active
	# Two float texels per relevant owner; no fixed cap or lossy world raster.
	var image := Image.create_empty(2,maxi(1,active.size()),false,Image.FORMAT_RGBAF)
	for index in active.size():
		var row: Dictionary = active[index]
		var centre: Vector2 = row.centre; var half: Vector2 = row.half; var inverse: Vector4 = row.inverse
		image.set_pixel(0,index,Color(centre.x,centre.y,half.x,half.y))
		image.set_pixel(1,index,Color(inverse.x,inverse.y,inverse.z,inverse.w))
	if _exclusion_texture == null: _exclusion_texture = ImageTexture.create_from_image(image)
	else: _exclusion_texture.set_image(image)
	for ring: Dictionary in rings:
		_set_exclusion_shader(ring,not active.is_empty())
		var material: ShaderMaterial = ring.material
		material.set_shader_parameter("exclusion_rects",_exclusion_texture)
		material.set_shader_parameter("exclusion_count",active.size())
		material.set_shader_parameter("exclusion_bounds",Vector4(bounds.position.x,bounds.position.y,bounds.end.x,bounds.end.y))
	_exclusion_uploads += 1

# ------------------------------------------------------------------ footprint mask
## Rasterize every solid collider of the town and placed models (their bottom within a
## few metres of the ground) into a coverage mask: no grass inside houses or under props.
func rebuild_mask() -> void:
	_contact_ground_cache.clear()
	_contact_ground_cache_active = true
	var shapes := []
	for root_name in ["PonyvilleTown"]:
		for town in get_tree().root.find_children(root_name, "", true, false):
			shapes.append_array(town.find_children("*", "CollisionShape3D", true, false))
	var placed := terrain.get_node_or_null("ModelPlacements")
	if placed: shapes.append_array(placed.find_children("*", "CollisionShape3D", true, false))
	var bounds := Rect2(); var first := true
	var polys := []
	for c: CollisionShape3D in shapes:
		if c.shape == null or c.disabled: continue
		var body := c.get_parent() as CollisionObject3D
		if body == null or not (body.collision_layer & 1): continue
		for poly: PackedVector2Array in _footprints(c):
			polys.append(poly)
			for p: Vector2 in poly:
				if first: bounds = Rect2(p, Vector2.ZERO); first = false
				else: bounds = bounds.expand(p)
	if first:
		_contact_ground_cache_active = false
		_contact_ground_cache.clear()
		for ring: Dictionary in rings: (ring.material as ShaderMaterial).set_shader_parameter("block_enabled", false)
		return
	bounds = bounds.grow(150.0)
	# Rivers and lakes near town: no blades standing in the water.
	for water: Node in get_tree().get_nodes_in_group("navigation_water"):
		var mi := water as MeshInstance3D
		if mi == null or mi.mesh == null or str(mi.name) == "Sea": continue
		var faces := mi.mesh.get_faces()
		var xf := mi.global_transform
		for face in range(0, faces.size(), 3):
			var tri := PackedVector2Array()
			for k in 3:
				var p := xf * faces[face + k]
				tri.append(Vector2(p.x, p.z))
			if bounds.has_point((tri[0] + tri[1] + tri[2]) / 3.0): polys.append(tri)
	var w := int(ceil(bounds.size.x / MASK_CELL)); var h := int(ceil(bounds.size.y / MASK_CELL))
	mask_image = Image.create_empty(w, h, false, Image.FORMAT_R8)
	for poly: PackedVector2Array in polys:
		_fill(poly, bounds)
	mask_rect = bounds
	mask_texture = ImageTexture.create_from_image(mask_image)
	for ring: Dictionary in rings:
		var mat: ShaderMaterial = ring.material
		mat.set_shader_parameter("block_mask", mask_texture)
		mat.set_shader_parameter("block_rect", Vector4(bounds.position.x, bounds.position.y, w * MASK_CELL, h * MASK_CELL))
		mat.set_shader_parameter("block_enabled", true)
	_contact_ground_cache_active = false
	_contact_ground_cache.clear()

func _footprints(c: CollisionShape3D) -> Array[PackedVector2Array]:
	var xf := c.global_transform
	var shape := c.shape
	var polys: Array[PackedVector2Array] = []
	if shape is ConcavePolygonShape3D:
		var faces: PackedVector3Array = (shape as ConcavePolygonShape3D).get_faces()
		if faces.is_empty(): return polys
		var box: AABB = xf * _points_aabb(faces)
		if box.size.x * box.size.z > 4000.0: return polys
		# Each face owns its ground contact. A low floor must not admit a high roof
		# or fill the empty corners of a rotated/concave house's world bounds.
		for face in range(0, faces.size(), 3):
			var points := PackedVector3Array([xf * faces[face], xf * faces[face + 1], xf * faces[face + 2]])
			var poly := _project_contact(_clip_ground_face(points))
			if not poly.is_empty(): polys.append(poly)
		return polys
	if shape is ConvexPolygonShape3D:
		var points := PackedVector3Array()
		var heights := PackedFloat32Array()
		var projected := PackedVector2Array()
		for local: Vector3 in (shape as ConvexPolygonShape3D).points:
			var point: Vector3 = xf * local
			points.append(point)
			heights.append(_contact_height(point))
			if heights[-1] <= 0.0: projected.append(Vector2(point.x, point.z))
		if points.is_empty(): return polys
		var box := _points_aabb(points)
		if box.size.x * box.size.z > 4000.0: return polys
		# Hull vertices are unordered. Every hull edge is a vertex pair; extra
		# interior chords cannot enlarge the convex clipped projection.
		for i in points.size():
			for j in range(i + 1, points.size()):
				if (heights[i] <= 0.0) == (heights[j] <= 0.0): continue
				var point: Vector3 = points[i].lerp(points[j], heights[i] / (heights[i] - heights[j]))
				projected.append(Vector2(point.x, point.z))
		if projected.size() >= 3:
			var hull := Geometry2D.convex_hull(projected)
			if not hull.is_empty(): polys.append(hull)
		return polys
	if shape is BoxShape3D:
		var e: Vector3 = (shape as BoxShape3D).size * 0.5
		var base := PackedVector3Array()
		for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			base.append(xf * Vector3(e.x * corner.x, -e.y, e.z * corner.y))
		var poly := _project_contact(_clip_ground_face(base))
		if not poly.is_empty(): polys.append(poly)
		return polys
	var box: AABB
	if shape is CylinderShape3D: var cy := shape as CylinderShape3D; box = xf * AABB(Vector3(-cy.radius, -cy.height * .5, -cy.radius), Vector3(cy.radius * 2, cy.height, cy.radius * 2))
	elif shape is SphereShape3D: var sp := shape as SphereShape3D; box = xf * AABB(-Vector3.ONE * sp.radius, Vector3.ONE * sp.radius * 2)
	elif shape is CapsuleShape3D: var ca := shape as CapsuleShape3D; box = xf * AABB(Vector3(-ca.radius, -ca.height * .5, -ca.radius), Vector3(ca.radius * 2, ca.height, ca.radius * 2))
	else: return polys
	var ground: float = terrain.height_at(xf.origin)
	if box.position.y > ground + 2.5 or box.size.x * box.size.z > 4000.0: return polys
	var radius := minf(box.size.x, box.size.z) * 0.5; var centre := box.get_center()
	var ring := PackedVector2Array()
	for k in 8: ring.append(Vector2(centre.x, centre.z) + Vector2.from_angle(k * TAU / 8) * radius)
	polys.append(ring)
	return polys

func _contact_height(point: Vector3) -> float:
	# Retain the existing 2.5 m floor/ramp allowance, evaluated at the face's
	# vertices rather than admitting a whole floor-to-roof collider by its bottom.
	var ground: float
	if _contact_ground_cache_active:
		# Exact X/Z keys share ground samples between collider faces and heights.
		var key := Vector2(point.x, point.z)
		if _contact_ground_cache.has(key):
			ground = _contact_ground_cache[key]
		else:
			ground = terrain.height_at(point)
			_contact_ground_cache[key] = ground
	else:
		ground = terrain.height_at(point)
	return point.y - ground - 2.5

func _clip_ground_face(points: PackedVector3Array) -> PackedVector3Array:
	var clipped := PackedVector3Array()
	if points.is_empty(): return clipped
	var previous := points[-1]
	var last_height := _contact_height(previous)
	var previous_height := last_height
	for i in points.size():
		var point: Vector3 = points[i]
		var height := last_height if i == points.size() - 1 else _contact_height(point)
		if (height <= 0.0) != (previous_height <= 0.0):
			clipped.append(previous.lerp(point, previous_height / (previous_height - height)))
		if height <= 0.0: clipped.append(point)
		previous = point; previous_height = height
	return clipped

func _project_contact(points: PackedVector3Array) -> PackedVector2Array:
	var projected := PackedVector2Array()
	for point: Vector3 in points: projected.append(Vector2(point.x, point.z))
	if projected.size() < 3: return PackedVector2Array()
	var area := 0.0
	for i in projected.size(): area += projected[i].cross(projected[(i + 1) % projected.size()])
	if absf(area) > 0.00001: return projected
	# A wall can project to a line. Cover only its narrow contact strip, so
	# raster-cell alignment cannot lose a wall or restore blades through it.
	var a := projected[0]; var b := a
	for point: Vector2 in projected:
		if a.distance_squared_to(point) > a.distance_squared_to(b): b = point
	if a.distance_squared_to(b) < 0.00001: return PackedVector2Array()
	var side := (b - a).orthogonal().normalized() * MASK_CELL * 0.5
	return PackedVector2Array([a + side, b + side, b - side, a - side])

func _points_aabb(points: PackedVector3Array) -> AABB:
	var box := AABB(points[0], Vector3.ZERO) if points.size() > 0 else AABB()
	for p in points: box = box.expand(p)
	return box

func _fill(poly: PackedVector2Array, bounds: Rect2) -> void:
	# Scanline fill of a convex polygon in mask cells (one fill_rect per row).
	var ymin := INF; var ymax := -INF
	for p in poly: ymin = minf(ymin, p.y); ymax = maxf(ymax, p.y)
	var r0 := maxi(0, int((ymin - bounds.position.y) / MASK_CELL)); var r1 := mini(mask_image.get_height() - 1, int((ymax - bounds.position.y) / MASK_CELL))
	for row in range(r0, r1 + 1):
		var y := bounds.position.y + (row + 0.5) * MASK_CELL
		var xl := INF; var xr := -INF
		for i in poly.size():
			var a := poly[i]; var b := poly[(i + 1) % poly.size()]
			if (a.y <= y and b.y >= y) or (b.y <= y and a.y >= y):
				var t := 0.5 if absf(b.y - a.y) < 1e-6 else (y - a.y) / (b.y - a.y)
				var x := lerpf(a.x, b.x, t); xl = minf(xl, x); xr = maxf(xr, x)
		if xl > xr: continue
		var c0 := maxi(0, int((xl - bounds.position.x) / MASK_CELL)); var c1 := mini(mask_image.get_width() - 1, int((xr - bounds.position.x) / MASK_CELL))
		if c1 >= c0: mask_image.fill_rect(Rect2i(c0, row, c1 - c0 + 1, 1), Color(1, 0, 0))
