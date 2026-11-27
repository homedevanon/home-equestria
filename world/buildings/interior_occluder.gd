extends Node3D
## Interior occluder (performance overhaul 2026-11-21, lane card). From inside an ordinary town
## house nothing outdoors was occluded: town_render_budget.gd hides the house's own exterior
## occluder while the camera is inside (simplification may close its window holes), so grass,
## trees, terrain and water behind the walls all drew. Measured on High at 1600 x 900, door shut,
## everything outdoors hidden: 1.41 -> 0.83 ms and 1.54 -> 0.89 ms of card time, 233 to 329 draws.
##
## This node, made under a house interior the first time the camera enters it, is a shell of
## occluder walls just outside the measured room walls (house_interior.gd _fitted_rooms: the floor
## rects moved to the real inner wall faces), with a cap over each room at the roof's top, holes
## at every window pane of the design (window_panes.json, each 1.25 x its size + 0.35 m, plus half
## its distance to the occluder wall, the Golden Oak rule) and at the doorway. A separate panel
## closes the doorway hole while the leaf has stood exactly shut for DOOR_SETTLE seconds, checked
## every frame after the doors' own step. Walls between two rooms are left out (openings between a
## house and its wing). The shell shows only while the camera is inside the measured rooms, checked
## every frame. Occlusion culling is the camera's only: sun shadows are culled on their own, so
## casters outdoors still throw shadows in through the windows.
## town_render_budget.gd calls show_for(home) when the camera enters a house and show_for(null) when
## it leaves. Rollback: ENABLED = false.
const ENABLED := true
## House designs the visibility proof covered (lane card L3 2026-11-21: 270 views, every window at
## eye height and 0.3 m offsets with a pony 2.5 m outside each, the door through its swing, the
## doorway, straight up; nothing outdoors lost). Other designs keep today's behaviour until proven.
const PROVEN_DESIGNS := ["house_a", "house_e", "house_g"]
## Metres outside the measured inner wall face (inside the wall, or just past a thin wall).
const OUT_M := 0.15
## Metres the walls reach below the floor.
const BELOW_M := 1.0
## Window and door hole margin: scale and metres added on every side.
const HOLE_SCALE := 1.25
const HOLE_M := 0.35
## Two rooms closer than this (metres) on a side are one space: no wall between them.
const NEIGHBOUR_M := 1.0
const DOOR_SETTLE := 0.1
const PLAYER_VIEW := preload("res://world/player_view.gd")
const GLOW := preload("res://world/buildings/window_glow/window_glow.gd")

static var _active: Node3D   # the interior occluder now in charge (one at a time)

var home: Node3D
var _shell: OccluderInstance3D
var _door_panel: OccluderInstance3D
var _rooms: Array[Rect2] = []
var _floor := 0.0
var _top := 0.0
var _shut_for := 0.0


## The interior occluder of `house_interior` (made on first use), or null when it cannot be built.
static func ensure(house_interior: Node3D) -> Node3D:
	if not ENABLED or house_interior == null: return null
	var have := house_interior.get_node_or_null("InteriorOccluder") as Node3D
	if have != null: return have
	var house := house_interior.get_parent()
	if house == null or not house.scene_file_path.get_file().get_basename() in PROVEN_DESIGNS: return null
	var rooms: Variant = house_interior.get("_fitted_rooms")
	if not rooms is Array or (rooms as Array).is_empty(): return null   # walls not measured yet
	var node: Node3D = (load("res://world/buildings/interior_occluder.gd") as GDScript).new()
	node.name = "InteriorOccluder"
	node.set("home", house_interior)
	if not bool(node.call("_build")):
		node.free()
		return null
	house_interior.add_child(node)
	return node


## The camera entered `house_interior` (null: it is in no house).
static func show_for(house_interior: Node3D) -> void:
	if not ENABLED: return
	var next: Node3D = ensure(house_interior) if house_interior != null else null
	if is_instance_valid(_active) and _active != next: _active.call("_set_active", false)
	_active = next
	if next != null: next.call("_set_active", true)


func _set_active(on: bool) -> void:
	set_process(on)
	if not on:
		_shell.visible = false
		_door_panel.visible = false


func _metres() -> float:
	return maxf(home.global_basis.get_scale().x, 0.0001)


## Builds the shell in the interior's own space. False when the house has nothing to build from.
func _build() -> bool:
	var m := _metres()
	var out := OUT_M / m
	_floor = float(home.get("floor_y"))
	_top = float(home.get("_ceiling_y"))
	for rect: Rect2 in home.get("_fitted_rooms"): _rooms.append(rect)
	if _rooms.is_empty() or _top <= _floor: return false
	var bottom := _floor - BELOW_M / m
	var cap := _top + out
	# Holes in the interior's space: [pane centre, outward normal, half width, half height].
	var holes: Array = []
	var house := home.get_parent() as Node3D
	var to_home := home.transform.affine_inverse()   # house root space -> interior space
	var designs: Dictionary = GLOW._load_panes()
	var design := house.scene_file_path.get_file().get_basename() if house != null else ""
	if designs.has(design):
		for pane: Dictionary in (designs[design] as Dictionary).panes:
			var c: Vector3 = to_home * GLOW._vec(pane.c)
			var n: Vector3 = (to_home.basis * GLOW._vec(pane.n)).normalized()
			var u: float = (to_home.basis * GLOW._vec(pane.u)).length()
			var v: float = (to_home.basis * GLOW._vec(pane.v)).length()
			holes.append([c, n, u, v])
	var doorway: Vector3 = home.get("doorway")
	var door_half := float(home.get("door_width")) * 0.5
	var door_top := _floor + 2.4 / m
	var leaf := home.call("door") as Node3D
	if leaf != null:
		for mesh: Node in leaf.find_children("*", "MeshInstance3D", true, false):
			var instance := mesh as MeshInstance3D
			if instance.mesh == null: continue
			var box: AABB = (home.global_transform.affine_inverse() * instance.global_transform) * instance.mesh.get_aabb()
			door_top = maxf(door_top, box.end.y)
	var vertices := PackedVector3Array(); var indices := PackedInt32Array()
	var door_quad := PackedVector3Array()
	for i in _rooms.size():
		var r := _rooms[i]
		# Four sides: [outward normal (x, z), plane coordinate, span low, span high].
		var sides := [[Vector2(-1, 0), r.position.x - out, r.position.y - out, r.end.y + out],
			[Vector2(1, 0), r.end.x + out, r.position.y - out, r.end.y + out],
			[Vector2(0, -1), r.position.y - out, r.position.x - out, r.end.x + out],
			[Vector2(0, 1), r.end.y + out, r.position.x - out, r.end.x + out]]
		for side: Array in sides:
			var normal: Vector2 = side[0]
			var plane: float = side[1]
			var spans: Array = [[float(side[2]), float(side[3])]]
			# Leave out the part of this wall another room stands right behind.
			for j in _rooms.size():
				if j == i: continue
				var o := _rooms[j]
				var near := NEIGHBOUR_M / m
				var behind := false
				if normal.x != 0.0:
					var face := r.end.x if normal.x > 0.0 else r.position.x
					behind = (o.position.x - face) * normal.x < near and (o.end.x - face) * normal.x > near if normal.x > 0.0 else (face - o.end.x) < near and (face - o.position.x) > near
					if behind: spans = _subtract(spans, o.position.y - out, o.end.y + out)
				else:
					var face := r.end.y if normal.y > 0.0 else r.position.y
					behind = (o.position.y - face) < near and (o.end.y - face) > near if normal.y > 0.0 else (face - o.end.y) < near and (face - o.position.y) > near
					if behind: spans = _subtract(spans, o.position.x - out, o.end.x + out)
			# Holes on this wall: windows whose outward normal points this way and whose centre
			# lies within reach of the wall, and the doorway.
			var cuts: Array = []   # [span low, span high, height low, height high]
			for hole: Array in holes:
				var c: Vector3 = hole[0]; var n: Vector3 = hole[1]
				var along := Vector2(n.x, n.z)
				if along.length() < 0.5 or along.normalized().dot(normal) < 0.7: continue
				var pane_at: float = c.x if normal.x != 0.0 else c.z
				var distance: float = (plane - pane_at) * (normal.x + normal.y)
				if absf(distance) > 2.5 / m: continue
				var t: float = c.z if normal.x != 0.0 else c.x
				var grow := HOLE_M / m + absf(distance) * 0.5
				var hw: float = float(hole[2]) * HOLE_SCALE + grow
				var hh: float = float(hole[3]) * HOLE_SCALE + grow
				cuts.append([t - hw, t + hw, c.y - hh, c.y + hh])
			var door_cut: Array = []
			var door_at: float = doorway.x if normal.x != 0.0 else doorway.z
			var door_t: float = doorway.z if normal.x != 0.0 else doorway.x
			var door_distance: float = (plane - door_at) * (normal.x + normal.y)
			if absf(door_distance) < 1.5 / m and door_t > float(side[2]) and door_t < float(side[3]):
				var grow := HOLE_M / m + absf(door_distance) * 0.5
				door_cut = [door_t - door_half * HOLE_SCALE - grow, door_t + door_half * HOLE_SCALE + grow, bottom, door_top + grow]
				cuts.append(door_cut)
			for span: Array in spans:
				_wall(vertices, indices, normal, plane, float(span[0]), float(span[1]), bottom, cap, cuts)
			if not door_cut.is_empty() and door_quad.is_empty():
				door_quad = _quad(normal, plane, float(door_cut[0]), float(door_cut[1]), float(door_cut[2]), float(door_cut[3]))
		# The cap over the room.
		var base := vertices.size()
		vertices.append_array([Vector3(r.position.x - out, cap, r.position.y - out), Vector3(r.end.x + out, cap, r.position.y - out),
			Vector3(r.end.x + out, cap, r.end.y + out), Vector3(r.position.x - out, cap, r.end.y + out)])
		indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	if indices.is_empty(): return false
	var shape := ArrayOccluder3D.new()
	shape.set_arrays(vertices, indices)
	_shell = OccluderInstance3D.new(); _shell.name = "Shell"; _shell.occluder = shape; _shell.visible = false
	add_child(_shell)
	_door_panel = OccluderInstance3D.new(); _door_panel.name = "DoorPanel"; _door_panel.visible = false
	if not door_quad.is_empty():
		var panel := ArrayOccluder3D.new()
		panel.set_arrays(door_quad, PackedInt32Array([0, 1, 2, 0, 2, 3]))
		_door_panel.occluder = panel
	add_child(_door_panel)
	# After the doors' own step in the same frame.
	process_priority = 100
	set_process(false)
	return true


## Spans [[a, b], ...] minus [lo, hi].
static func _subtract(spans: Array, lo: float, hi: float) -> Array:
	var out: Array = []
	for span: Array in spans:
		var a: float = span[0]; var b: float = span[1]
		if hi <= a or lo >= b: out.append(span); continue
		if lo > a: out.append([a, lo])
		if hi < b: out.append([hi, b])
	return out


## A quad on the wall plane: t along the wall, y up.
static func _quad(normal: Vector2, plane: float, t0: float, t1: float, y0: float, y1: float) -> PackedVector3Array:
	if normal.x != 0.0:
		return PackedVector3Array([Vector3(plane, y0, t0), Vector3(plane, y0, t1), Vector3(plane, y1, t1), Vector3(plane, y1, t0)])
	return PackedVector3Array([Vector3(t0, y0, plane), Vector3(t1, y0, plane), Vector3(t1, y1, plane), Vector3(t0, y1, plane)])


## One wall span from y0 to y1 with rectangular holes: split into a grid on every hole edge and
## keep the cells no hole covers.
static func _wall(vertices: PackedVector3Array, indices: PackedInt32Array, normal: Vector2, plane: float, t0: float, t1: float, y0: float, y1: float, cuts: Array) -> void:
	var ts: Array[float] = [t0, t1]; var ys: Array[float] = [y0, y1]
	for cut: Array in cuts:
		for t: float in [float(cut[0]), float(cut[1])]:
			if t > t0 and t < t1: ts.append(t)
		for y: float in [float(cut[2]), float(cut[3])]:
			if y > y0 and y < y1: ys.append(y)
	ts.sort(); ys.sort()
	for i in ts.size() - 1:
		for j in ys.size() - 1:
			if ts[i + 1] - ts[i] <= 0.0 or ys[j + 1] - ys[j] <= 0.0: continue
			var mid := Vector2((ts[i] + ts[i + 1]) * 0.5, (ys[j] + ys[j + 1]) * 0.5)
			var open := false
			for cut: Array in cuts:
				if mid.x > float(cut[0]) and mid.x < float(cut[1]) and mid.y > float(cut[2]) and mid.y < float(cut[3]): open = true; break
			if open: continue
			var base := vertices.size()
			vertices.append_array(_quad(normal, plane, ts[i], ts[i + 1], ys[j], ys[j + 1]))
			indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


## The camera inside one of the measured rooms, between the floor's underside and the cap.
func _camera_inside(camera: Camera3D) -> bool:
	var p := home.to_local(camera.global_position)
	if p.y < _floor - BELOW_M / _metres() or p.y > _top: return false
	for rect: Rect2 in _rooms:
		if rect.has_point(Vector2(p.x, p.z)): return true
	return false


func _process(delta: float) -> void:
	if not is_instance_valid(home):
		set_process(false)
		return
	var camera := PLAYER_VIEW.camera(self)
	var inside := camera != null and _camera_inside(camera)
	if _shell.visible != inside: _shell.visible = inside
	var leaf := home.call("door") as Node
	var shut := leaf != null and leaf.has_method("opening_angle") and float(leaf.call("opening_angle")) == 0.0
	_shut_for = _shut_for + delta if shut else 0.0
	var closed := inside and shut and _shut_for >= DOOR_SETTLE and _door_panel.occluder != null
	if _door_panel.visible != closed: _door_panel.visible = closed
