extends Node3D
## Foot shade (dev 2026-11-18: "things should look like they stand on the ground"). For the houses
## near the camera: a soft dark band on the ground around the foot of each house, reaching a little
## in under the wall and up the lowest part of the walls, so the house reads as standing on the
## ground instead of floating on it. A contact shade that lives in the world (Decal nodes darkening
## the albedo of the ground and walls they fall on), not a screen effect, so the headset sees it
## like any surface. The shade's shape is the house's own footprint: the convex hull of the shell
## vertices near its lowest point, turned once per house design into a small soft-edged texture.
##
## Trial: off unless the game is started with the user argument --look-foot-shade=on.
## Cost: a 0.5 Hz step that re-picks the nearest houses; a fixed pool of POOL decals, hidden when
## unused. Each house design is measured once (shell boxes, then vertices of the lowest meshes only)
## and its TEXTURE_SIZE^2 texture is filled ROWS_PER_FRAME rows per frame, one design at a time.
## Limits: a convex hull, so L-shaped or courtyard houses get their hull shaded (the inner corner of
## an L is filled in); the decal box is level with the house's lowest point, so on steep ground one
## side of the band may fall outside the box (BOX_HEIGHT_M) and be cut; the texture orientation in
## the decal (FLIP_U / FLIP_V) is unverified by render.
## Rollback: start without --look-foot-shade=on (the default); nothing is built then.

const PLAYER_VIEW := preload("res://world/player_view.gd")
const STEP := 2.0
const POOL := 24
const RANGE := 90.0
## Width of the band outside the wall, in metres.
const FADE_M := 1.3
## How far the shade reaches in under the wall, in metres.
const INNER_M := 0.25
## Vertices this far above the house's lowest point count as its foot, in metres.
const BAND_M := 0.5
const BOX_HEIGHT_M := 1.6
const TEXTURE_SIZE := 64
const ROWS_PER_FRAME := 8
## Most points kept on a footprint outline (see _distinct_hull).
const HULL_MAX := 28
const SHADE_COLOR := Color(0.10, 0.12, 0.18)
const STRENGTH := 0.38
## Share of STRENGTH left at full night (the ground is dark already).
const NIGHT_FACTOR := 0.45
const NORMAL_FADE := 0.0
## Godot's Decal is taken to map its texture over the box's local X (u, growing with +X) and local
## Z (v, growing with +Z), projecting along local -Y: texture column = house x, row = house z.
## That mapping is unverified by render; if the shade comes out mirrored, flip these.
const FLIP_U := false
const FLIP_V := false

static var enabled: bool = "--look-foot-shade=on" in OS.get_cmdline_user_args() or "--look-foot-shade=on" in OS.get_cmdline_args()
## scene path -> {"centre": Vector3 (house space, y = lowest y), "size": Vector2 (house-space x/z
## extent of the texture rectangle), "texture": ImageTexture}. An empty Dictionary marks a design
## with no shell meshes (nothing to shade; not retried).
static var _footprints: Dictionary = {}

var _decals: Array[Decal] = []
var _timer := 0.0
var _report := ""
## The one pending texture build (null image = none).
var _job_key := ""
var _job_hull := PackedVector2Array()
var _job_rect := Rect2()
var _job_scale := 1.0
var _job_centre := Vector3.ZERO
var _job_image: Image = null
var _job_row := 0


func _ready() -> void:
	if not enabled:
		set_process(false)
		return
	for i in POOL:
		var decal := Decal.new()
		decal.albedo_mix = 1.0
		decal.emission_energy = 0.0
		decal.upper_fade = 0.3; decal.lower_fade = 0.3
		decal.normal_fade = NORMAL_FADE
		decal.distance_fade_enabled = true
		decal.distance_fade_begin = RANGE * 0.7; decal.distance_fade_length = RANGE * 0.3
		decal.visible = false
		add_child(decal)
		_decals.append(decal)


func _process(delta: float) -> void:
	_advance_job()
	_timer -= delta
	if _timer > 0.0: return
	_timer = STEP
	var camera := PLAYER_VIEW.camera(self)
	if camera == null: return
	var eye := camera.global_position
	var clock: Node = get_node_or_null("/root/TimeOfDay")
	var daylight: float = float(clock.call("daylight")) if clock != null else 1.0
	var strength := STRENGTH * lerpf(NIGHT_FACTOR, 1.0, daylight)
	# Every house within range, lit or not, nearest first.
	var near: Array = []
	for glow: Node in get_tree().get_nodes_in_group("window_glow"):
		var houses: Variant = glow.get("_houses")
		if not houses is Array: continue
		for entry: Variant in houses:
			var house := entry as Node3D
			if not is_instance_valid(house) or not house.is_inside_tree(): continue
			var d := house.global_position.distance_to(eye)
			if d > RANGE: continue
			near.append([d, house])
	near.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var used := 0
	var missing: Node3D = null
	for row: Array in near:
		var house: Node3D = row[1]
		var key := house.scene_file_path
		# Houses built in code have no design to cache the footprint under.
		if key.is_empty(): continue
		if not _footprints.has(key):
			if missing == null and key != _job_key: missing = house
			continue
		var footprint: Dictionary = _footprints[key]
		if not footprint.has("texture") or used >= _decals.size(): continue
		var centre: Vector3 = footprint.get("centre", Vector3.ZERO)
		var size: Vector2 = footprint.get("size", Vector2.ONE)
		var texture: ImageTexture = footprint.get("texture", null)
		var to_world := house.global_transform
		var scales := to_world.basis.get_scale()
		var decal := _decals[used]
		used += 1
		decal.global_transform = Transform3D(to_world.basis.orthonormalized(), to_world * centre)
		decal.size = Vector3(size.x * scales.x, BOX_HEIGHT_M, size.y * scales.z)
		decal.texture_albedo = texture
		decal.modulate = Color(SHADE_COLOR.r, SHADE_COLOR.g, SHADE_COLOR.b, strength)
		decal.visible = true
	for i in range(used, _decals.size()):
		_decals[i].visible = false
	if missing != null and _job_image == null:
		_start_job(missing)
	var designs := 0
	for entry: Variant in _footprints.values():
		if entry is Dictionary and (entry as Dictionary).has("texture"): designs += 1
	var report := "houses=%d shown=%d designs=%d" % [near.size(), used, designs]
	if report != _report:
		_report = report
		print("[foot_shade] ", report)


## Measures one house design (steps a to e: shell boxes, foot vertices, hull, texture rectangle)
## and queues its texture fill.
func _start_job(house: Node3D) -> void:
	var key := house.scene_file_path
	var inverse := house.global_transform.affine_inverse()
	var metres := maxf(house.global_transform.basis.get_scale().y, 0.001)
	# Pass 1, boxes only: the lowest point and the x/z box of the whole shell.
	var shells: Array = []
	var lowest_y := INF
	var box_min := Vector2(INF, INF); var box_max := Vector2(-INF, -INF)
	for node: Node in house.find_children("*", "MeshInstance3D", true, false):
		var instance := node as MeshInstance3D
		if instance.mesh == null or not instance.is_visible_in_tree(): continue
		# The shell only: rooms, linings and furniture sit under the interior node.
		var inside := false
		var parent := instance.get_parent()
		while parent != null and parent != house:
			if parent.is_in_group("house_interiors"): inside = true; break
			parent = parent.get_parent()
		if inside: continue
		var to_house := inverse * instance.global_transform
		var box := instance.mesh.get_aabb()
		var bottom := INF
		for corner in 8:
			var at: Vector3 = to_house * box.get_endpoint(corner)
			bottom = minf(bottom, at.y)
			box_min = Vector2(minf(box_min.x, at.x), minf(box_min.y, at.z))
			box_max = Vector2(maxf(box_max.x, at.x), maxf(box_max.y, at.z))
		lowest_y = minf(lowest_y, bottom)
		shells.append([instance, to_house, bottom])
	if shells.is_empty():
		_footprints[key] = {}
		return
	# Pass 2: vertices near the foot, only from meshes that reach down to it.
	var band_top := lowest_y + BAND_M / metres
	var points := PackedVector2Array()
	for shell: Array in shells:
		if float(shell[2]) >= band_top: continue
		var mesh: Mesh = (shell[0] as MeshInstance3D).mesh
		var to_house: Transform3D = shell[1]
		for s in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(s)
			if arrays.size() <= Mesh.ARRAY_VERTEX: continue
			if not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array: continue
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for vertex: Vector3 in vertices:
				var at := to_house * vertex
				if at.y <= band_top: points.append(Vector2(at.x, at.z))
	var hull := PackedVector2Array()
	if points.size() >= 3:
		hull = _distinct_hull(points)
	if hull.size() < 3:
		hull = PackedVector2Array([box_min, Vector2(box_max.x, box_min.y), box_max, Vector2(box_min.x, box_max.y)])
	var low := hull[0]; var high := hull[0]
	for point: Vector2 in hull:
		low = low.min(point); high = high.max(point)
	var grow := FADE_M / metres
	low -= Vector2(grow, grow); high += Vector2(grow, grow)
	_job_key = key
	_job_hull = hull
	_job_rect = Rect2(low, high - low)
	_job_scale = metres
	_job_centre = Vector3((low.x + high.x) * 0.5, lowest_y, (low.y + high.y) * 0.5)
	_job_image = Image.create_empty(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	_job_row = 0


## Fills ROWS_PER_FRAME texture rows of the pending design; stores the footprint when done.
func _advance_job() -> void:
	if _job_image == null: return
	var count := _job_hull.size()
	var last := mini(_job_row + ROWS_PER_FRAME, TEXTURE_SIZE)
	for row in range(_job_row, last):
		var source_row := (TEXTURE_SIZE - 1 - row) if FLIP_V else row
		var z := _job_rect.position.y + (float(source_row) + 0.5) / float(TEXTURE_SIZE) * _job_rect.size.y
		for column in TEXTURE_SIZE:
			var source_column := (TEXTURE_SIZE - 1 - column) if FLIP_U else column
			var x := _job_rect.position.x + (float(source_column) + 0.5) / float(TEXTURE_SIZE) * _job_rect.size.x
			var p := Vector2(x, z)
			var nearest := INF
			for i in count:
				var closest := Geometry2D.get_closest_point_to_segment(p, _job_hull[i], _job_hull[(i + 1) % count])
				nearest = minf(nearest, p.distance_to(closest))
			var d_m := nearest * _job_scale
			var alpha: float
			if Geometry2D.is_point_in_polygon(p, _job_hull):
				alpha = 1.0 - smoothstep(0.0, INNER_M, d_m)
			else:
				alpha = pow(1.0 - smoothstep(0.0, FADE_M, d_m), 1.6)
			_job_image.set_pixel(column, row, Color(1.0, 1.0, 1.0, clampf(alpha, 0.0, 1.0)))
	_job_row = last
	if _job_row < TEXTURE_SIZE: return
	_footprints[_job_key] = {
		"centre": _job_centre,
		"size": _job_rect.size,
		"texture": ImageTexture.create_from_image(_job_image),
	}
	_job_image = null
	_job_key = ""
	_job_hull = PackedVector2Array()


## Convex hull without the repeated closing point or coincident points.
static func _distinct_hull(points: PackedVector2Array) -> PackedVector2Array:
	var hull := Geometry2D.convex_hull(points)
	var distinct := PackedVector2Array()
	for point: Vector2 in hull:
		if not distinct.is_empty() and distinct[distinct.size() - 1].is_equal_approx(point): continue
		distinct.append(point)
	while distinct.size() > 1 and distinct[0].is_equal_approx(distinct[distinct.size() - 1]):
		distinct.remove_at(distinct.size() - 1)
	# A round tower's hull can hold hundreds of points, and every texel measures its distance to
	# every edge. Past HULL_MAX points keep every n-th: the outline moves in by centimetres.
	if distinct.size() > HULL_MAX:
		var thinned := PackedVector2Array()
		var stride := ceili(float(distinct.size()) / float(HULL_MAX))
		for i in range(0, distinct.size(), stride): thinned.append(distinct[i])
		distinct = thinned
	return distinct
