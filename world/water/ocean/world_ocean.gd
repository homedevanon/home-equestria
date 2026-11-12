class_name WorldOcean
extends Node3D
## The sea (dev 2026-09-25: "integrate tidewater with diverse and good feeling oceans"), ported
## from Tidewater (github.com/dgreenheck/tidewater, MIT) and stylized for the cel-shaded world:
## - OceanFFT: FFT wave cascades on the GPU (compute), with persistent whitecap foam;
## - ocean_surface.gdshader: displacement, shore waves that shoal, break and run up the sand
##   (coast field baked by tools/ocean/bake_coast.py), cel bands, a hard sun glint, crisp foam;
## - this node: the CDLOD mesh (one MultiMesh of grid patches picked from a world-fixed quadtree
##   around the camera), per-region sea moods, wind from the weather and season.
## WorldWater creates it instead of showing its flat toon sea when the "Ocean" setting is
## "Stylized waves" and the renderer has a RenderingDevice; the sea's collision stays in WorldWater.

const SHADER := preload("res://world/water/ocean/ocean_surface.gdshader")
const COAST_JSON := "res://world/water/ocean/coast.json"
const GRID := 32
const LEAF := 32.0         # m, the smallest quadtree node (1 m grid spacing)
const RANGE0 := 64.0       # m, visibility range of the finest lod; doubles per lod (>= 2 x LEAF,
                           # so neighbouring nodes differ by one lod at most and morph together)
const LODS := 12
const MORPH_START := 0.6   # morph from range[l-1] + 60 % of the way to range[l]
const MAX_NODES := 1024
const FOAM_WEIGHTS: Array[float] = [0.35, 0.45, 0.5, 0.25]

## Sea moods, blended by where the camera is (see _mood_weights). Colours are the stylized
## water body; wind/swell/fetch drive the FFT spectrum; shore = surf amplitude (H/2), period s.
const MOODS := {
	"open": {"deep": Color(0.05, 0.22, 0.42), "shallow": Color(0.14, 0.56, 0.62), "surf": Color(0.42, 0.82, 0.78),
		"wind": 8.0, "swell": 0.3, "fetch": 150.0, "swell_scale": 0.5, "choppiness": 0.9, "shore": 0.34, "period": 9.5},
	"bay": {"deep": Color(0.07, 0.36, 0.5), "shallow": Color(0.2, 0.72, 0.7), "surf": Color(0.5, 0.9, 0.82),
		"wind": 4.5, "swell": 0.1, "fetch": 40.0, "swell_scale": 0.2, "choppiness": 0.75, "shore": 0.16, "period": 7.0},
	"cold": {"deep": Color(0.1, 0.2, 0.26), "shallow": Color(0.22, 0.4, 0.4), "surf": Color(0.45, 0.62, 0.6),
		"wind": 11.0, "swell": 0.35, "fetch": 250.0, "swell_scale": 0.6, "choppiness": 1.0, "shore": 0.45, "period": 10.5},
	"warm": {"deep": Color(0.04, 0.3, 0.55), "shallow": Color(0.18, 0.78, 0.76), "surf": Color(0.55, 0.95, 0.85),
		"wind": 6.0, "swell": 0.25, "fetch": 120.0, "swell_scale": 0.45, "choppiness": 0.85, "shore": 0.28, "period": 9.0},
}
## Seasons: wind multiplier and a colour grade (value, saturation).
const SEASONS := {"spring": [1.0, 1.0, 1.0], "summer": [0.9, 1.05, 1.05], "autumn": [1.08, 0.94, 0.92], "winter": [1.2, 0.82, 0.75]}

const FFT := preload("res://world/water/ocean/ocean_fft.gd")
var fft: FFT
var material: ShaderMaterial
var multimesh: MultiMesh
var visual: MultiMeshInstance3D
var sea_level := -80.0
## Review lab overrides: a mood name, and a wind multiplier (< 0: from the weather).
var mood_override := ""
var wind_override := -1.0
var debug_mode := 0:
	set(v):
		debug_mode = v
		if material != null: material.set_shader_parameter("debug_mode", v)
var mood := {}
var node_count := 0
var _ranges: Array[float] = []
var _far := 20000.0
var _planes: Array = []
var _behind := Vector3.ZERO
var _mood_timer := 0.0
var _spectrum_key := Vector4(-1, -1, -1, -1)
## Selection writes the MultiMesh buffer directly (12 transform + 4 custom floats per patch)
## and uploads it in one call, only when the patch set changed.
const STRIDE := 16
var _buffer := PackedFloat32Array()
var _uploaded := PackedFloat32Array()
var _count := 0
var _morph := PackedFloat64Array()        # per lod: where its morph starts
var _behind_reach := PackedFloat64Array() # per lod: the headset behind-test radius
var _plane_ax := PackedFloat64Array()
var _plane_ay := PackedFloat64Array()
var _plane_az := PackedFloat64Array()
var _plane_count := 0
## What the last selection depended on; an unmoved camera keeps its patches.
var _selected_eye := Vector3.INF
var _selected_planes: Array = []
var _selected_behind := Vector3.INF
var _selected_far := -1.0
var _selected_sea := NAN
var _lod_camera := Vector3.INF
var _sky_tint := Color(-1, -1, -1, -1)
var _ocean_time_written := NAN
## Dry land (2026-10-23 GPU pass, dev: "we're never gonna see it from ponyville"): the sea is an
## infinite plane at sea level, so its finest patches were drawn under the town's ground (155-184k
## triangles at 230-300 m). Per quadtree level, 1 where a node and DRY_BORDER around it are all at
## least DRY_HEIGHT above the sea in the baked ground heights; such nodes are skipped. Built on a
## worker from dry_heights.res; until then nothing is skipped. Outside the field counts as sea.
const DRY_HEIGHT := 4.0
const DRY_HEIGHTS := "res://world/water/ocean/dry_heights.res"
const FFT_RATE := 60.0
var _fft_delta := 0.0
const DRY_BORDER := 64.0
var _dry: Array[PackedByteArray] = []
var _dry_size := Vector2i.ZERO
var _dry_origin := Vector2.ZERO
var _dry_task := -1
var _dry_result: Array = []

func setup(level: float) -> void:
	sea_level = level

func _ready() -> void:
	for l in LODS: _ranges.append(RANGE0 * pow(2.0, l))
	for l in LODS:
		var before: float = _ranges[l - 1] if l > 0 else 0.0
		_morph.append(lerpf(before, _ranges[l], MORPH_START))
		var half := LEAF * pow(2.0, l) * 0.5
		_behind_reach.append(Vector3(half + 60.0, 40.0, half + 60.0).length())
	# Per patch only size, x, z and the custom data change; the rest of the basis is fixed.
	_buffer.resize(MAX_NODES * STRIDE)
	for i in MAX_NODES: _buffer[i * STRIDE + 5] = 1.0
	var cascades := 4
	var quality := get_node_or_null("/root/Quality")
	if quality != null: cascades = int(quality.get_value("ocean_cascades", 4))
	if preload("res://world/player_view.gd").viewport(self).use_xr: cascades = mini(cascades, 3)
	fft = FFT.new(cascades)
	# Stylized: more whitecaps than Tidewater's realistic 0.58 (foam where a cascade compresses
	# the surface below this Jacobian), and fresh foam on the sharpest crests (shader foam_bias).
	fft.foam_bias = 0.7
	material = ShaderMaterial.new(); material.shader = SHADER
	var disp: Array[Texture2D] = []; var deriv: Array[Texture2D] = []
	for c in 4:
		disp.append(fft.displacement[mini(c, fft.cascades - 1)])
		deriv.append(fft.derivatives[mini(c, fft.cascades - 1)])
	material.set_shader_parameter("ocean_displacement", disp)
	material.set_shader_parameter("ocean_derivatives", deriv)
	var sizes := PackedFloat32Array(); var weights := PackedFloat32Array()
	for c in 4:
		sizes.append(fft.sizes[c] if c < fft.cascades else 1.0)
		weights.append(FOAM_WEIGHTS[c])
	material.set_shader_parameter("cascade_size", sizes)
	material.set_shader_parameter("foam_weight", weights)
	material.set_shader_parameter("cascade_count", fft.cascades)
	material.set_shader_parameter("foam_bias", 0.9)
	# stylized: waves a little taller than Tidewater's physical scale
	material.set_shader_parameter("amplitude", 1.3)
	material.set_shader_parameter("sea_level", sea_level)
	material.set_shader_parameter("grid_size", float(GRID))
	material.set_shader_parameter("foam_texture", load("res://world/water/ocean/foam.res"))
	if FileAccess.file_exists(COAST_JSON):
		var coast: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(COAST_JSON))
		material.set_shader_parameter("coast_a", load("res://world/water/ocean/coast_a.res"))
		material.set_shader_parameter("coast_t", load("res://world/water/ocean/coast_t.res"))
		var cell := float(coast.cell)
		material.set_shader_parameter("coast_rect", Vector4(float(coast.origin[0]), float(coast.origin[1]), float(coast.width) * cell, float(coast.height) * cell))
		# The shore field is stored compressed (texture diet, 2026-09-29) and cannot give heights;
		# dry_heights.res holds the lowest ground of every LEAF cell (tools/ocean/bake_dry_heights.gd).
		var image: Image = null
		var image_cell := cell
		if ResourceLoader.exists(DRY_HEIGHTS):
			image = load(DRY_HEIGHTS) as Image
			image_cell = LEAF
		if image == null: image = (material.get_shader_parameter("coast_a") as Texture2D).get_image()
		if image != null:
			_dry_origin = Vector2(float(coast.origin[0]), float(coast.origin[1]))
			_dry_task = WorkerThreadPool.add_task(_build_dry.bind(image.duplicate(), image_cell, _dry_result), false, "Ocean dry land")
	else:
		material.set_shader_parameter("shore_enabled", 0.0)
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.mesh = _grid_mesh()
	multimesh.instance_count = MAX_NODES
	multimesh.visible_instance_count = 0
	# every patch is displaced in the shader: one generous box instead of per-instance bounds
	multimesh.custom_aabb = AABB(Vector3(-1e5, -200.0, -1e5), Vector3(2e5, 400.0, 2e5))
	visual = MultiMeshInstance3D.new()
	visual.name = "OceanSurface"
	visual.multimesh = multimesh
	visual.material_override = material
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The patch buffer is rewritten from the camera every rendered frame, so there is nothing to
	# interpolate; interpolated, every write logged "MultiMesh interpolation is being triggered
	# from outside physics process" (M-INP-06) and blended a reused slot between two patches.
	visual.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(visual)

func _exit_tree() -> void:
	if _dry_task >= 0: WorkerThreadPool.wait_for_task_completion(_dry_task); _dry_task = -1
	if fft != null: fft.free_resources()

func _take_dry() -> void:
	if _dry_task < 0 or not WorkerThreadPool.is_task_completed(_dry_task): return
	WorkerThreadPool.wait_for_task_completion(_dry_task)
	_dry_task = -1
	if _dry_result.size() == 2:
		_dry_size = _dry_result[0]; _dry = _dry_result[1]
		_selected_eye = Vector3.INF  # reselect with the mask

## Worker: leaf-sized (LEAF) dry cells from the coast field's ground height, grown by DRY_BORDER
## of wet neighbours, then one level per quadtree lod (dry only when all four children are).
static func _build_dry(image: Image, cell: float, out: Array) -> void:
	if image.is_compressed(): return
	image.convert(Image.FORMAT_RF)
	var data := image.get_data()
	var w := image.get_width(); var h := image.get_height()
	var step := maxi(1, roundi(LEAF / cell))
	var lw := ceili(float(w) / step); var lh := ceili(float(h) / step)
	var wet := PackedByteArray(); wet.resize(lw * lh)
	for z in h:
		for x in w:
			if data.decode_float((z * w + x) * 4) < DRY_HEIGHT: wet[(z / step) * lw + x / step] = 1
	var reach := ceili(DRY_BORDER / LEAF)
	var level := PackedByteArray(); level.resize(lw * lh)
	for z in lh:
		for x in lw:
			var dry := 1
			for dz in range(maxi(0, z - reach), mini(lh, z + reach + 1)):
				for dx in range(maxi(0, x - reach), mini(lw, x + reach + 1)):
					if wet[dz * lw + dx] == 1: dry = 0; break
				if dry == 0: break
			level[z * lw + x] = dry
	var levels: Array[PackedByteArray] = [level]
	var cw := lw; var ch := lh
	for l in range(1, LODS):
		var nw := ceili(cw / 2.0); var nh := ceili(ch / 2.0)
		var next := PackedByteArray(); next.resize(nw * nh)
		for z in nh:
			for x in nw:
				var dry := 1
				for k in 4:
					var sx := x * 2 + (k & 1); var sz := z * 2 + (k >> 1)
					if sx >= cw or sz >= ch or level[sz * cw + sx] == 0: dry = 0; break
				next[z * nw + x] = dry
		levels.append(next); level = next; cw = nw; ch = nh
	out.append(Vector2i(lw, lh)); out.append(levels)

## A GRID x GRID patch over the unit square (x, z in 0..1), flat.
func _grid_mesh() -> ArrayMesh:
	var verts := PackedVector3Array(); var idx := PackedInt32Array()
	for z in GRID + 1:
		for x in GRID + 1:
			verts.append(Vector3(float(x) / GRID, 0.0, float(z) / GRID))
	for z in GRID:
		for x in GRID:
			var a := z * (GRID + 1) + x
			idx.append_array([a, a + 1, a + GRID + 2, a, a + GRID + 2, a + GRID + 1])
	var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts; arrays[Mesh.ARRAY_INDEX] = idx
	var normals := PackedVector3Array(); normals.resize(verts.size()); normals.fill(Vector3.UP)
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.custom_aabb = AABB(Vector3(0, -200, 0), Vector3(1, 400, 1))
	return mesh

func _process(delta: float) -> void:
	var camera := preload("res://world/player_view.gd").camera(self)
	if camera == null or not visible: return
	var eye := camera.global_position
	_mood_timer -= delta
	if _mood_timer <= 0.0 or mood.is_empty():
		_mood_timer = 0.5
		_update_mood(eye)
	_take_dry()
	_select(eye)
	# No sea in view (town, inland): the wave cascades wait instead of computing unseen water.
	# In view they step at most FFT_RATE times a second (2026-10-23 CPU pass: every rendered
	# frame dispatched them, 300+ times a second).
	_fft_delta += delta
	if node_count > 0 and _fft_delta >= 1.0 / FFT_RATE:
		fft.update(_fft_delta)
		_fft_delta = 0.0
	elif node_count == 0:
		_fft_delta = 0.0
	if eye != _lod_camera:
		_lod_camera = eye
		material.set_shader_parameter("lod_camera", eye)
	# Only when the waves stepped (perf 0.1.0): inland the clock stands still, and every write
	# re-uploads the material.
	if fft.time != _ocean_time_written:
		_ocean_time_written = fft.time
		material.set_shader_parameter("ocean_time", fft.time)
	var env := get_viewport().world_3d.environment if get_viewport().world_3d != null else null
	if env != null and env.fog_light_color != _sky_tint:
		_sky_tint = env.fog_light_color
		material.set_shader_parameter("sky_tint", _sky_tint)

# ------------------------------------------------------------------ CDLOD selection

func _select(eye: Vector3) -> void:
	var camera := preload("res://world/player_view.gd").camera(self)
	var far := camera.far if camera != null else 20000.0
	# Frustum culling per node; in the headset only what is behind the head (the Camera3D
	# frustum can be narrower than the eye views).
	var planes: Array = [] if preload("res://world/player_view.gd").viewport(self).use_xr or camera == null else camera.get_frustum()
	var behind := -camera.global_basis.z if camera != null else Vector3.ZERO
	# The selection depends on nothing else: the same inputs give the same patches.
	if eye == _selected_eye and far == _selected_far and behind == _selected_behind and sea_level == _selected_sea and planes == _selected_planes:
		return
	_selected_eye = eye; _selected_far = far; _selected_behind = behind; _selected_sea = sea_level; _selected_planes = planes
	_far = far; _planes = planes; _behind = behind
	_plane_count = planes.size()
	_plane_ax.resize(_plane_count); _plane_ay.resize(_plane_count); _plane_az.resize(_plane_count)
	for i in _plane_count:
		var plane: Plane = planes[i]
		_plane_ax[i] = absf(plane.normal.x); _plane_ay[i] = absf(plane.normal.y); _plane_az[i] = absf(plane.normal.z)
	_count = 0
	var top := LODS - 1
	var root := LEAF * pow(2.0, top)
	var cx := floorf(eye.x / root); var cz := floorf(eye.z / root)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			_visit((cx + dx) * root, (cz + dz) * root, root, top, eye)
	node_count = mini(_count, MAX_NODES)
	if _buffer != _uploaded:
		multimesh.buffer = _buffer
		_uploaded = _buffer.duplicate()
	if multimesh.visible_instance_count != node_count:
		multimesh.visible_instance_count = node_count

## Split a node while the camera is within the next finer lod's range of it. Distance and
## view tests are inlined (hundreds of visits a frame); the maths is unchanged.
func _visit(x: float, z: float, size: float, lod: int, eye: Vector3) -> void:
	var nx := clampf(eye.x, x, x + size); var nz := clampf(eye.z, z, z + size)
	var distance := Vector3(eye.x - nx, eye.y - sea_level, eye.z - nz).length()
	if distance > _far: return
	var half := size * 0.5
	var centre := Vector3(x + half, sea_level, z + half)
	var ex := half + 60.0   # + displacement and shore shift; y extent 40
	for i in _plane_count:
		var plane: Plane = _planes[i]
		if plane.distance_to(centre) > _plane_ax[i] * ex + _plane_ay[i] * 40.0 + _plane_az[i] * ex: return
	if _plane_count == 0 and _behind != Vector3.ZERO:
		if (centre - eye).dot(_behind) < -_behind_reach[lod]: return
	if lod < _dry.size() and is_zero_approx(fposmod(x - _dry_origin.x, size)) and is_zero_approx(fposmod(z - _dry_origin.y, size)):
		var ix := int(floorf((x - _dry_origin.x) / size)); var iz := int(floorf((z - _dry_origin.y) / size))
		var w := ceili(float(_dry_size.x) / pow(2.0, lod)); var h := ceili(float(_dry_size.y) / pow(2.0, lod))
		if ix >= 0 and iz >= 0 and ix < w and iz < h and _dry[lod][iz * w + ix] == 1: return
	if lod > 0 and distance < _ranges[lod - 1]:
		var child := lod - 1
		_visit(x, z, half, child, eye)
		_visit(x + half, z, half, child, eye)
		_visit(x, z + half, half, child, eye)
		_visit(x + half, z + half, half, child, eye)
		return
	if _count < MAX_NODES:
		var o := _count * STRIDE
		_buffer[o] = size; _buffer[o + 3] = x; _buffer[o + 10] = size; _buffer[o + 11] = z
		_buffer[o + 12] = float(lod); _buffer[o + 13] = _morph[lod]; _buffer[o + 14] = _ranges[lod]
	_count += 1

# ------------------------------------------------------------------ moods, weather and season

func _mood_weights(at: Vector3) -> Dictionary:
	if mood_override != "": return {mood_override: 1.0}
	var bay := 0.0
	for r: Dictionary in WorldLayout.regions():
		if str(r.get("kind", "")) == "bay":
			bay = maxf(bay, 1.0 - smoothstep(300.0, 2000.0, WorldLayout.distance_to(r, at)))
	var cold := smoothstep(-2500.0, -6000.0, at.z)
	var warm := smoothstep(2000.0, 5000.0, at.z)
	return {"bay": bay, "cold": cold * (1.0 - bay), "warm": warm * (1.0 - bay), "open": maxf(1.0 - bay - cold - warm, 0.0) + 0.001}

func _update_mood(at: Vector3) -> void:
	var weights := _mood_weights(at)
	var total := 0.0
	for k in weights: total += float(weights[k])
	var blended := {}
	for k in weights:
		var w := float(weights[k]) / total
		for key in MOODS[k]:
			var v: Variant = MOODS[k][key]
			blended[key] = (blended.get(key, Color(0, 0, 0, 0) if v is Color else 0.0)) + v * w
	# weather: calm in clear skies, whitecaps in wind and storms
	var weather := get_tree().get_first_node_in_group("weather")
	var wind_mul := 1.0
	var season := "summer"
	if weather != null:
		var p: Dictionary = weather.params
		wind_mul = 0.65 + float(p.get("gust", 0.0)) * 1.4 + float(p.get("overcast", 0.0)) * 0.35 + float(p.get("rain", 0.0)) * 0.4
		season = str(weather.season)
	if wind_override >= 0.0: wind_mul = wind_override
	var grade: Array = SEASONS.get(season, [1.0, 1.0, 1.0])
	wind_mul *= float(grade[0])
	blended.wind_mul = wind_mul
	mood = blended
	for key in ["deep", "shallow", "surf"]:
		var c: Color = blended[key]
		var gray := Color(c.get_luminance(), c.get_luminance(), c.get_luminance())
		material.set_shader_parameter(key + "_color", gray.lerp(c, float(grade[2])) * float(grade[1]))
	var shore := float(blended.shore) * sqrt(wind_mul)
	material.set_shader_parameter("shore_amplitude", shore)
	material.set_shader_parameter("shore_period", float(blended.period))
	material.set_shader_parameter("foam_coverage", clampf(0.8 + (wind_mul - 1.0) * 0.4, 0.6, 1.6))
	# the spectrum is rebuilt only for a real change (same random phases: waves grow, not jump)
	var clock := get_node_or_null("/root/TimeOfDay")
	var day := float(clock.day) if clock != null else 0.0
	var key := Vector4(float(blended.wind) * wind_mul, float(blended.swell), float(blended.choppiness), 25.0 + 40.0 * sin(day * 1.3))
	if (key - _spectrum_key).abs().x > 0.3 or absf(key.y - _spectrum_key.y) > 0.03 or absf(key.z - _spectrum_key.z) > 0.03 or absf(key.w - _spectrum_key.w) > 3.0:
		_spectrum_key = key
		fft.local.wind_speed = key.x
		fft.local.wind_direction = key.w
		fft.local.fetch = float(blended.fetch)
		fft.swell.wind_speed = maxf(4.0, key.x * 0.75)
		fft.swell.wind_direction = key.w - 20.0
		fft.swell.scale = float(blended.swell_scale)
		fft.swell.swell = clampf(0.6 + key.y, 0.0, 1.0)
		fft.local.swell = key.y * 0.2
		fft.choppiness = key.z
		fft.update_spectrum()
