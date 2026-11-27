extends Node3D
## Golden Oak entrance plug (performance trial `library_door_occluder` of 2026-11-24, on by default
## since 2026-11-25; the launch user argument --try=no_library_door_occluder leaves it out, see
## world/perf/try_switch.gd and golden_oak.gd).
##
## The library's room occluder (golden_oak.gd _room_occluder) leaves the whole entrance sector open
## at every height, so with the door shut and the camera facing it the engine still listed the
## whole new town behind the door: 1196-1204 draws and 3.5 M triangles against 720 draws and 1.5 M
## facing the wall from the same spot (bench rows 2026-11-24). This node closes that sector with a
## second occluder while, and only while, the leaf rests exactly shut and the camera is inside the
## room or the entrance tunnel, more than NEAR_DOOR from the leaf. Door moving or open, camera
## outside, near the door or anywhere else: the plug is hidden and everything draws as before.
##
## Nothing runs per frame (2026-11-25; the trial polled in _process). The leaf reports when it wakes
## and when it settles (hinged_door.gd motion_changed). Waking hides the plug at once. Settling shut
## starts one check DOOR_SETTLE later; while the camera stays inside, a Timer repeats the check every
## WATCH seconds (camera teleported out, walked up to the door). A camera outside stops it: getting
## back in means opening the door, which reports again. So with the player away from the library
## nothing of this runs, and with the door resting and the player inside only the WATCH timer does.
## Ponies queueing for the door wake it from the moment they set out for it (hinged_door
## queue_passage), long before the leaf moves.
##
## Why NEAR_DOOR: hiding an occluder reaches the engine's culling a few frames late (latency lines
## in the 2026-11-24 check). A player who can reach the leaf (desktop use ray 3 m, hands) could
## open it in that window and see things behind the gap pop in, so near the door the plug is
## already hidden. Unicorn magic reaches farther (8 m); see the notes of 2026-11-25.
##
## Shape (room frame metres, the runtime frame _room_occluder builds in): see make_shape. The
## leaf is a pointed arch, and 1-pixel seams between the arch infill and the tunnel mouth show the
## outdoors from the loft, so the default "slit" shape closes the sector at the infill plane and
## keeps a thin band open round the tunnel mouth. Vertical faces start at FLOOR_LIFT so the thin
## slivers of outdoor ground seen at the floor corners of the entrance keep drawing exactly as
## today. Occlusion is the camera's only; sun shadows cull on their own.
const PLAYER_VIEW := preload("res://world/player_view.gd")
const WINDOWS := preload("res://world/buildings/golden_oak/windows.gd")
## Seconds between the leaf settling exactly shut and the first check. Ponies on their way to the
## door wake it on every navigation tick, even from far off; this keeps the plug from flicking on
## and off between those ticks (each change makes the engine rebuild its occlusion scene).
const DOOR_SETTLE := 0.5
## While the plug may show (door resting shut, camera inside), the check repeats this often.
const WATCH := 0.1
## Camera closer than this to the leaf (its box, room frame metres): hidden. Desktop use reaches
## 3 m (player/interactor.gd REACH); a sprinting player (8 m/s) covers 0.8 m per WATCH, and the
## culling lag is a few frames.
const NEAR_DOOR := 4.5
## The panel sits this far behind the shut leaf's outermost point.
const PANEL_GAP := 0.05
## Bottom of every vertical face (floor-corner slivers stay visible).
const FLOOR_LIFT := 0.35
## Tunnel side wall line and ceiling (shell.gd _build_room: EntranceReveal at x .16 +/- 1.72,
## LibraryCeiling and EntranceCeiling at y 7.28).
const TUNNEL_X := 0.16
const TUNNEL_HALF := 1.72
const TUNNEL_CEILING := 7.28
## The tunnel box starts here (home.gd is_inside: the doorway floor rect begins at z 4).
const TUNNEL_START := 4.0
## Lowest camera height still counted as inside.
const ROOM_FLOOR := -0.5
## A window hole of the room occluder closer than this to the entrance sector: do not build.
const WINDOW_CLEARANCE := 15.0
## Plug shape (see make_shape): "slit", "tight", "box" or "arch". The launch user argument
## --library-plug=<shape> overrides it for A/B measurements (read once, when the plug is built).
const SHAPE := "slit"
## "slit": the open band round the tunnel mouth (outward), the tube's inset (inward), the shoulder
## plane's distance behind the infill, and the tube's segments over the arch.
const SLIT := 0.06
const TUBE_INSET := 0.04
const SHOULDER_GAP := 0.03
const TUBE_STEPS := 24

var door: Node3D
var home: Node
var radius := 0.0
var top := 0.0
var open_degrees := Vector2.ZERO
var leaf_box := AABB()
var leaf_outline := PackedVector2Array()   # the shut leaf seen along z, room frame (x, y)
var mouth_outline := PackedVector2Array()  # the tunnel mouth at the arch infill plane (x, y)
var mouth_z := 0.0
var _plug: OccluderInstance3D
var _timer: Timer


## The plug for the library whose leaf is `door` (shut at this moment). `occluder_radius`,
## `occluder_top` and `occluder_open` are golden_oak.gd OCCLUDER_RADIUS, OCCLUDER_TOP and
## OCCLUDER_OPEN. Add the result under the library's runtime node; it builds itself on entering the
## tree, where the leaf can be measured.
static func create(library_home: Node, leaf: Node3D, occluder_radius: float, occluder_top: float, occluder_open: Vector2) -> Node3D:
	var node: Node3D = (load("res://world/buildings/golden_oak/entrance_occluder.gd") as GDScript).new()
	node.name = "EntranceOccluder"
	node.set("home", library_home)
	node.set("door", leaf if leaf != null else (library_home.call("door") as Node3D if library_home != null and library_home.has_method("door") else null))
	node.set("radius", occluder_radius)
	node.set("top", occluder_top)
	node.set("open_degrees", occluder_open)
	return node


func _ready() -> void:
	if not _build(): return
	_timer = Timer.new()
	_timer.name = "Watch"
	_timer.one_shot = true
	_timer.timeout.connect(check)
	add_child(_timer)
	door.connect("motion_changed", _on_door_motion)
	# The leaf may already rest (it reports again whenever it moves).
	if not door.is_physics_processing(): _on_door_motion(false)


func _build() -> bool:
	if door == null or not door.has_method("opening_angle") or not door.has_signal("motion_changed"):
		print("LIBRARY_DOOR_OCCLUDER not built: no door leaf")
		return false
	var mid := deg_to_rad((open_degrees.x + open_degrees.y) * 0.5)
	var half := deg_to_rad((open_degrees.y - open_degrees.x) * 0.5)
	# The room occluder's window holes, measured as _room_occluder measures them.
	for window: Dictionary in WINDOWS.definitions():
		var centre: Vector3 = window.centre
		var angle := atan2(centre.x, centre.z)
		var hole_half := (float(window.w) * 1.25 + .35) / radius
		var gap := absf(wrapf(angle - mid, -PI, PI)) - hole_half - half
		if gap < deg_to_rad(WINDOW_CLEARANCE):
			print("LIBRARY_DOOR_OCCLUDER not built: window %s is %.1f degrees from the entrance sector" % [window.name, rad_to_deg(gap)])
			return false
	var room := (get_parent() as Node3D).global_transform.affine_inverse()
	# The leaf's picture, shut, in the room frame (this node's parent space).
	var leaf_rest := door.transform
	leaf_rest.basis = Basis.from_euler(Vector3(door.rotation.x, 0.0, door.rotation.z)) * Basis.from_scale(door.scale)
	var to_room: Transform3D = room * (door.get_parent() as Node3D).global_transform * leaf_rest
	var leaf_points := PackedVector2Array()
	var first := true
	for found: Node in door.find_children("*", "MeshInstance3D", true, false):
		var mesh := found as MeshInstance3D
		if mesh.mesh == null: continue
		var local := Transform3D.IDENTITY
		var walk: Node = mesh
		while walk != door and walk != null:
			local = (walk as Node3D).transform * local
			walk = walk.get_parent()
		var box: AABB = (to_room * local) * mesh.mesh.get_aabb()
		leaf_box = box if first else leaf_box.merge(box)
		first = false
		for point: Vector3 in mesh.mesh.get_faces():
			var p := (to_room * local) * point
			leaf_points.append(Vector2(p.x, p.y))
	if first:
		print("LIBRARY_DOOR_OCCLUDER not built: the leaf has no mesh")
		return false
	leaf_outline = _hull(leaf_points)
	# The tunnel mouth: the inner edge of shell.gd's arch infill (TunnelArchLining, a flat ring
	# whose outer corners sit at its own x extremes). Hidden by the static merge, never freed.
	var frame: Node = door.get_parent().get_parent() if door.get_parent() != null else null
	var lining: MeshInstance3D = frame.get_node_or_null("TunnelArchLining") as MeshInstance3D if frame != null else null
	if lining != null and lining.mesh != null:
		var lining_room: Transform3D = room * lining.global_transform
		var points := PackedVector3Array()
		for point: Vector3 in lining.mesh.get_faces(): points.append(lining_room * point)
		var low := INF; var high := -INF
		for p: Vector3 in points: low = minf(low, p.x); high = maxf(high, p.x)
		var inner := PackedVector2Array()
		mouth_z = -INF
		for p: Vector3 in points:
			mouth_z = maxf(mouth_z, p.z)
			if p.x > low + 0.01 and p.x < high - 0.01: inner.append(Vector2(p.x, p.y))
		if inner.size() >= 3: mouth_outline = _hull(inner)
	var variant := SHAPE
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--library-plug="): variant = arg.trim_prefix("--library-plug=")
	var shape := make_shape(variant)
	if shape == null: return false
	_plug = OccluderInstance3D.new()
	_plug.name = "EntrancePlug"
	_plug.occluder = shape
	_plug.visible = false
	add_child(_plug)
	print("LIBRARY_DOOR_OCCLUDER built shape=%s leaf=%s mouth_z=%.3f mouth=%s sector=%s..%s triangles=%d" % [variant, str(leaf_box), mouth_z, str(_box2(mouth_outline)), str(_corner(open_degrees.x)), str(_corner(open_degrees.y)), shape.indices.size() / 3])
	return true


func _corner(degrees: float) -> Vector2:
	return Vector2(sin(deg_to_rad(degrees)), cos(deg_to_rad(degrees))) * radius


## Convex hull without the closing repeat of its first point.
static func _hull(points: PackedVector2Array) -> PackedVector2Array:
	var hull := Geometry2D.convex_hull(points)
	if hull.size() > 1 and hull[0] == hull[hull.size() - 1]: hull.resize(hull.size() - 1)
	return hull


static func _box2(points: PackedVector2Array) -> Rect2:
	if points.is_empty(): return Rect2()
	var box := Rect2(points[0], Vector2.ZERO)
	for p: Vector2 in points: box = box.expand(p)
	return box


## The plug's occluder in the room frame, or null (printed why). Draws at the bench door view,
## door shut, 260 houses (check log library_door_occluder_on3.log): none 1104, box 494, tight 520,
## slit 783, arch 815. `variant`:
## "slit"  (default) the entrance sector closed by side walls and a lid back to a plane 3 cm
##         behind shell.gd's arch infill (TunnelArchLining), with the tunnel mouth left open SLIT
##         wider than the mouth all round; a tube TUBE_INSET inside the mouth runs back to a panel
##         the shape of the shut leaf, 5 cm behind it. Rays through the seams between the infill
##         and the tunnel mouth pass the open band and still reach the town: picture identical in
##         every view checked. The band is coarse in the engine's occlusion buffer, so it lets
##         about 280 more draws through than "box".
## "tight" "slit" with no band (hole = mouth outline, tube starts on it). Same pictures in the
##         views checked, near "box" draws, but nothing keeps the seam rays clear by design.
## "box"   the designer's shape: sector edges to the tunnel walls, a full-height panel across the
##         tunnel 5 cm behind the leaf, a lid. Hides the outdoor pixels seen through those seams
##         (loft view: 72-76 pixels along the arch edge change colour).
## "arch"  the box with its panel cut to the leaf's outline (the designer's fallback; it leaks the
##         most and keeps nothing "slit" does not).
func make_shape(variant: String, slit := SLIT, inset := TUBE_INSET) -> ArrayOccluder3D:
	if variant == "tight":
		variant = "slit"; slit = 0.0; inset = 0.0
	var a := _corner(open_degrees.x)
	var b := _corner(open_degrees.y)
	var zp := leaf_box.end.z + PANEL_GAP
	var left := Vector2(TUNNEL_X - TUNNEL_HALF, zp)
	var right := Vector2(TUNNEL_X + TUNNEL_HALF, zp)
	if leaf_box.position.x < left.x or leaf_box.end.x > right.x or zp <= maxf(a.y, b.y):
		print("LIBRARY_DOOR_OCCLUDER not built: leaf %s outside the tunnel" % str(leaf_box))
		return null
	var lifted := PackedVector2Array([Vector2(-1000, FLOOR_LIFT), Vector2(1000, FLOOR_LIFT), Vector2(1000, top), Vector2(-1000, top)])
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	var panel := Geometry2D.intersect_polygons(leaf_outline, lifted)
	if variant == "box" or variant == "arch":
		for wall: Array in [[a, left], [right, b]] + ([[left, right]] if variant == "box" else []):
			_quad(vertices, indices, wall[0], wall[1], FLOOR_LIFT, top)
		_flat(vertices, indices, PackedVector2Array([a, b, Vector2(right.x, zp), Vector2(left.x, zp)]), top, true)
		if variant == "arch":
			if panel.size() != 1: return _refuse("leaf outline")
			_flat(vertices, indices, panel[0], zp, false)
	elif variant == "slit":
		if mouth_outline.size() < 3: return _refuse("no tunnel mouth (TunnelArchLining)")
		var zs := mouth_z + SHOULDER_GAP
		if zs >= leaf_box.position.z or zs <= maxf(a.y, b.y): return _refuse("mouth plane z %.3f" % mouth_z)
		var hole: Array = Geometry2D.offset_polygon(mouth_outline, slit) if slit > 0.0 else [mouth_outline]
		var inner: Array = Geometry2D.offset_polygon(mouth_outline, -inset) if inset > 0.0 else [mouth_outline]
		if hole.size() != 1 or inner.size() != 1 or panel.size() != 1: return _refuse("outline offsets")
		var mouth_box := _box2(mouth_outline)
		if not _box2(hole[0]).grow(-slit * 0.5).encloses(mouth_box) or not mouth_box.grow(-inset * 0.5).encloses(_box2(inner[0])): return _refuse("outline offsets went the wrong way")
		var frame_rect := PackedVector2Array([Vector2(a.x, FLOOR_LIFT), Vector2(b.x, FLOOR_LIFT), Vector2(b.x, top), Vector2(a.x, top)])
		for wall: Array in [[a, Vector2(a.x, zs)], [b, Vector2(b.x, zs)]]:
			_quad(vertices, indices, wall[0], wall[1], FLOOR_LIFT, top)
		_flat(vertices, indices, PackedVector2Array([a, b, Vector2(b.x, zs), Vector2(a.x, zs)]), top, true)
		for part: PackedVector2Array in Geometry2D.clip_polygons(frame_rect, hole[0]):
			if Geometry2D.is_polygon_clockwise(part): return _refuse("shoulder plane has a hole")
			if not _flat(vertices, indices, part, zs, false): return _refuse("shoulder triangulation")
		_flat(vertices, indices, panel[0], zp, false)
		var start := Geometry2D.intersect_polygons(inner[0], lifted)
		if start.size() != 1: return _refuse("tube start")
		var ring_a := _ring(start[0])
		var ring_b := _ring(panel[0])
		for i in TUBE_STEPS:
			var base := vertices.size()
			vertices.append_array([Vector3(ring_a[i].x, ring_a[i].y, zs), Vector3(ring_a[i + 1].x, ring_a[i + 1].y, zs), Vector3(ring_b[i + 1].x, ring_b[i + 1].y, zp), Vector3(ring_b[i].x, ring_b[i].y, zp)])
			indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	else:
		return _refuse("unknown shape %s" % variant)
	var shape := ArrayOccluder3D.new()
	shape.set_arrays(vertices, indices)
	return shape


func _refuse(why: String) -> ArrayOccluder3D:
	print("LIBRARY_DOOR_OCCLUDER not built: ", why)
	return null


## Vertical quad from p to q (x, z) between heights y0 and y1.
static func _quad(vertices: PackedVector3Array, indices: PackedInt32Array, p: Vector2, q: Vector2, y0: float, y1: float) -> void:
	var base := vertices.size()
	vertices.append_array([Vector3(p.x, y0, p.y), Vector3(q.x, y0, q.y), Vector3(q.x, y1, q.y), Vector3(p.x, y1, p.y)])
	indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


## A flat polygon: horizontal at height `at` (points are x, z) or upright at depth `at` (x, y).
static func _flat(vertices: PackedVector3Array, indices: PackedInt32Array, polygon: PackedVector2Array, at: float, horizontal: bool) -> bool:
	var triangles := Geometry2D.triangulate_polygon(polygon)
	if triangles.is_empty(): return false
	var base := vertices.size()
	for p: Vector2 in polygon: vertices.append(Vector3(p.x, at, p.y) if horizontal else Vector3(p.x, p.y, at))
	for index: int in triangles: indices.append(base + index)
	return true


## TUBE_STEPS + 1 points round a convex arch outline: where rays from just above the middle of
## its base meet the outline, from the right side (angle 0) over the top to the left side (PI).
static func _ring(outline: PackedVector2Array) -> PackedVector2Array:
	var box := _box2(outline)
	var centre := Vector2(box.get_center().x, box.position.y + 0.01)
	var reach := box.size.length() * 2.0
	var ring := PackedVector2Array()
	for i in TUBE_STEPS + 1:
		var angle := PI * i / TUBE_STEPS
		var far := centre + Vector2(cos(angle), sin(angle)) * reach
		var hit := centre
		for j in outline.size():
			var crossing: Variant = Geometry2D.segment_intersects_segment(centre, far, outline[j], outline[(j + 1) % outline.size()])
			if crossing != null and (crossing as Vector2).distance_to(centre) > hit.distance_to(centre): hit = crossing
		ring.append(Vector2(hit.x, maxf(hit.y, box.position.y)))
	return ring


## Camera position (room frame) inside the round room or the entrance tunnel.
func camera_inside(p: Vector3) -> bool:
	if p.y >= ROOM_FLOOR and p.y <= top and Vector2(p.x, p.z).length() <= radius: return true
	return absf(p.x - TUNNEL_X) < TUNNEL_HALF and p.z >= TUNNEL_START and p.z < leaf_box.position.z and p.y >= ROOM_FLOOR and p.y < TUNNEL_CEILING


## Distance from a room-frame point to the shut leaf's box.
func leaf_distance(p: Vector3) -> float:
	var nearest := Vector3(clampf(p.x, leaf_box.position.x, leaf_box.end.x), clampf(p.y, leaf_box.position.y, leaf_box.end.y), clampf(p.z, leaf_box.position.z, leaf_box.end.z))
	return p.distance_to(nearest)


## The leaf woke (may move now) or settled and stopped ticking.
func _on_door_motion(moving: bool) -> void:
	if moving or float(door.call("opening_angle")) != 0.0:
		_timer.stop()
		_show(false)
	else:
		_timer.start(DOOR_SETTLE)


## One check of the rule (public so a paused test can drive it). Keeps the WATCH timer running only
## while the door rests shut and the camera is inside.
func check() -> void:
	if not is_instance_valid(door):
		_show(false)
		return
	if door.is_physics_processing() or float(door.call("opening_angle")) != 0.0:
		_show(false)   # moving or open: the leaf reports again when it settles
		return
	var camera := PLAYER_VIEW.camera(self)
	var p := to_local(camera.global_position) if camera != null else Vector3.INF
	if not p.is_finite() or not camera_inside(p):
		_show(false)   # outside: coming back in means opening the door
		return
	_show(leaf_distance(p) >= NEAR_DOOR)
	_timer.start(WATCH)


func _show(on: bool) -> void:
	if _plug.visible != on: _plug.visible = on
