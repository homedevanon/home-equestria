extends RefCounted
## The game table's board and pieces, built from code once and shared (board_table.gd):
## turned wooden chess pieces in Staunton proportions, the knight a pony's head, ridged checkers
## pieces (a king is two stacked), and an inlaid board with its square names on both edges.
## A board is 8 squares of SQUARE metres plus a border; its local origin is the middle of the
## playing surface, files run along +X and ranks along -Z (rank 1 at the +Z edge).
const SQUARE := 0.056
const BORDER := 0.024
const THICKNESS := 0.024
## The playing surface above whatever the board lies on (its frame, plus the inlay's gaps).
const LIFT := THICKNESS + 0.003
const SEGMENTS := 28
## A profile corner sharper than this keeps a crisp edge.
const CREASE := deg_to_rad(35.0)
const WOODS := {"light_square": Color("ead2a8"), "dark_square": Color("9a6644"), "frame": Color("5b3122"), "inlay": Color("d5b269")}
const PIECE_COLORS := {"chess": {1: Color("f2e7d2"), -1: Color("3a2343")}, "checkers": {1: Color("b3303b"), -1: Color("efe3c6")}}
static var _meshes: Dictionary = {}
static var _materials: Dictionary = {}

## Where the middle of a square sits on the board (board-local).
static func square_position(sq: int) -> Vector3:
	return Vector3(((sq & 7) - 3.5) * SQUARE, 0.0, -((sq >> 3) - 3.5) * SQUARE)

## The square under a board-local point, or -1 off the board.
static func square_at(local: Vector3) -> int:
	var file := floori(local.x / SQUARE + 4.0)
	var rank := floori(-local.z / SQUARE + 4.0)
	if file < 0 or file > 7 or rank < 0 or rank > 7: return -1
	return rank * 8 + file

static func half_size() -> float:
	return 4.0 * SQUARE + BORDER

static func piece_material(game: String, owner: int) -> StandardMaterial3D:
	var key := "%s/%d" % [game, owner]
	if not _materials.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = PIECE_COLORS[game][owner]
		mat.roughness = 0.38
		mat.clearcoat_enabled = true
		mat.clearcoat = 0.4
		_materials[key] = mat
	return _materials[key]

static func _wood(name: String) -> StandardMaterial3D:
	if not _materials.has(name):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = WOODS[name]
		mat.roughness = 0.55 if name.ends_with("square") else 0.7
		if name == "inlay": mat.metallic = 0.6; mat.roughness = 0.35
		_materials[name] = mat
	return _materials[name]

# ------------------------------------------------------------------ the board

## The board: frame, gold inlay line, 64 squares and their names. `parent` gets the parts.
static func build_board(parent: Node3D) -> void:
	var half := half_size()
	var frame := MeshInstance3D.new(); frame.name = "BoardFrame"
	var box := BoxMesh.new(); box.size = Vector3(half * 2.0, THICKNESS, half * 2.0)
	frame.mesh = box; frame.material_override = _wood("frame")
	# A millimetre or more between stacked faces, or they flicker through each other.
	frame.position.y = -THICKNESS * 0.5 - 0.003
	parent.add_child(frame)
	var inlay := MeshInstance3D.new(); inlay.name = "BoardInlay"
	var line := BoxMesh.new(); line.size = Vector3(8.0 * SQUARE + 0.008, 0.001, 8.0 * SQUARE + 0.008)
	inlay.mesh = line; inlay.material_override = _wood("inlay")
	inlay.position.y = -0.0015
	parent.add_child(inlay)
	for shade: String in ["light_square", "dark_square"]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for sq in 64:
			var dark := ((sq >> 3) + (sq & 7)) % 2 == 0
			if dark != (shade == "dark_square"): continue
			var c := square_position(sq)
			var h := SQUARE * 0.5
			_quad_up(st, c + Vector3(-h, 0, -h), c + Vector3(h, 0, -h), c + Vector3(h, 0, h), c + Vector3(-h, 0, h))
		var squares := MeshInstance3D.new(); squares.name = shade.to_pascal_case()
		squares.mesh = st.commit(); squares.material_override = _wood(shade)
		parent.add_child(squares)
	# Square names along both edges, each set facing the player on that side.
	for near: bool in [true, false]:
		var edge := (4.0 * SQUARE + BORDER * 0.5) * (1.0 if near else -1.0)
		for i in 8:
			var file_label := _edge_label("abcdefgh"[i], near)
			file_label.position = Vector3((i - 3.5) * SQUARE, 0.0005, edge)
			parent.add_child(file_label)
			var rank_label := _edge_label(str(i + 1), near)
			# On that player's left, as on a real board.
			rank_label.position = Vector3(-edge, 0.0005, -(i - 3.5) * SQUARE)
			parent.add_child(rank_label)

static func _edge_label(text: String, near: bool) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font_size = 40
	label.pixel_size = 0.00035
	label.modulate = Color("e9cf8f")
	label.outline_size = 0
	label.shaded = true
	label.double_sided = false
	label.rotation = Vector3(-PI * 0.5, 0.0 if near else PI, 0.0)
	return label

static func _quad_up(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_tri(st, a, b, c, Vector3.UP, Vector3.UP, Vector3.UP)
	_tri(st, a, c, d, Vector3.UP, Vector3.UP, Vector3.UP)

# ------------------------------------------------------------------ pieces

## The mesh for `kind` (chess 1 pawn .. 6 king; checkers 1 man, 2 king), in metres, standing on y 0.
static func piece_mesh(game: String, kind: int) -> Mesh:
	var key := "%s/%d" % [game, kind]
	if _meshes.has(key): return _meshes[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var k := SQUARE
	if game == "checkers":
		_checker(st, 0.0, k)
		if kind == 2: _checker(st, 0.13 * k, k)
	else:
		match kind:
			1: _lathe(st, _base() + _pts([[0.22, 0.18], [0.17, 0.28], [0.13, 0.42], [0.21, 0.47], [0.21, 0.51], [0.12, 0.54]]) + _arc(0.0, 0.70, 0.17, -70.0, 90.0, 8), k)
			2:
				_lathe(st, _base() + _pts([[0.27, 0.18], [0.23, 0.25], [0.25, 0.29], [0.0, 0.29]]), k)
				_extrude(st, _pts([[-0.24, 0.27], [-0.27, 0.55], [-0.23, 0.80], [-0.15, 0.98], [-0.07, 1.07], [-0.06, 1.21], [0.01, 1.11],
					[0.10, 1.06], [0.22, 0.96], [0.33, 0.82], [0.37, 0.73], [0.32, 0.66], [0.20, 0.67], [0.12, 0.61], [0.13, 0.50], [0.20, 0.38], [0.23, 0.27]]), 0.24, k)
				# The mane: a ridge down the back of the neck, a little wider than the head.
				_extrude(st, _pts([[-0.25, 0.46], [-0.31, 0.62], [-0.28, 0.83], [-0.20, 0.99], [-0.11, 1.08], [-0.08, 1.02], [-0.15, 0.92], [-0.21, 0.78], [-0.23, 0.60], [-0.21, 0.47]]), 0.30, k)
			3:
				_lathe(st, _base() + _pts([[0.24, 0.18], [0.17, 0.32], [0.12, 0.64], [0.21, 0.69], [0.21, 0.73], [0.12, 0.76], [0.15, 0.82], [0.17, 0.90], [0.165, 0.98],
					[0.13, 1.07], [0.08, 1.14], [0.03, 1.18]]) + _arc(0.0, 1.235, 0.055, -40.0, 90.0, 6), k)
			4:
				_lathe(st, _base() + _pts([[0.26, 0.18], [0.24, 0.30], [0.21, 0.72], [0.28, 0.76], [0.28, 0.80], [0.25, 0.82], [0.25, 0.99], [0.17, 0.99], [0.17, 0.93], [0.0, 0.93]]), k)
				for i in 4:
					var angle := TAU * i / 4.0 + PI * 0.25
					_box(st, Vector3(cos(angle) * 0.21, 1.035, sin(angle) * 0.21) * k, Vector3(0.11, 0.09, 0.08) * k, angle)
			5:
				_lathe(st, _base() + _pts([[0.27, 0.18], [0.19, 0.32], [0.13, 0.72], [0.24, 0.77], [0.24, 0.81], [0.13, 0.84], [0.14, 0.90], [0.23, 1.12], [0.25, 1.18],
					[0.20, 1.19], [0.12, 1.15], [0.07, 1.18]]) + _arc(0.0, 1.255, 0.08, -60.0, 90.0, 7), k)
				for i in 9:
					var angle := TAU * i / 9.0
					_lathe(st, _arc(0.0, 0.0, 0.035, -90.0, 90.0, 5), k, Vector3(cos(angle) * 0.235, 1.195, sin(angle) * 0.235) * k)
			_:
				_lathe(st, _base() + _pts([[0.28, 0.18], [0.20, 0.32], [0.14, 0.77], [0.25, 0.82], [0.25, 0.86], [0.14, 0.89], [0.15, 0.95], [0.23, 1.17], [0.23, 1.22],
					[0.12, 1.26], [0.10, 1.31], [0.0, 1.31]]), k)
				_box(st, Vector3(0, 1.44, 0) * k, Vector3(0.065, 0.27, 0.065) * k)
				_box(st, Vector3(0, 1.47, 0) * k, Vector3(0.2, 0.065, 0.065) * k)
	var mesh := st.commit()
	_meshes[key] = mesh
	return mesh

## A piece's radius on the board, for picking it with the mouse or a hand.
static func piece_radius() -> float:
	return SQUARE * 0.4

static func piece_height(game: String, kind: int) -> float:
	if game == "checkers": return SQUARE * (0.26 if kind == 2 else 0.13)
	return SQUARE * [0.0, 0.87, 1.21, 1.29, 1.08, 1.33, 1.51][clampi(kind, 0, 6)]

static func _base() -> PackedVector2Array:
	return _pts([[0.0, 0.0], [0.37, 0.0], [0.37, 0.05], [0.34, 0.08], [0.33, 0.11], [0.28, 0.14]])

static func _checker(st: SurfaceTool, lift: float, k: float) -> void:
	_lathe(st, _pts([[0.0, 0.0], [0.39, 0.0], [0.41, 0.015], [0.41, 0.035], [0.395, 0.045], [0.41, 0.055], [0.41, 0.075], [0.395, 0.085],
		[0.41, 0.095], [0.41, 0.112], [0.39, 0.128], [0.29, 0.128], [0.26, 0.112], [0.24, 0.122], [0.0, 0.122]]), k, Vector3.UP * lift)

static func _pts(rows: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for row: Array in rows: out.append(Vector2(float(row[0]), float(row[1])))
	return out

## Points on a circle of radius r around (cx, cy), from a0 to a1 degrees (radius, height).
static func _arc(cx: float, cy: float, r: float, a0: float, a1: float, steps: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in steps + 1:
		var a := deg_to_rad(lerpf(a0, a1, float(i) / steps))
		out.append(Vector2(maxf(0.0, cx + cos(a) * r), cy + sin(a) * r))
	return out

## A turned shape: `profile` (radius, height) from the bottom centre round to the top, in square
## widths, times k metres, around `at`.
static func _lathe(st: SurfaceTool, profile: PackedVector2Array, k: float, at := Vector3.ZERO) -> void:
	var count := profile.size()
	var normals: Array[Vector2] = []
	for i in count - 1:
		var d := profile[i + 1] - profile[i]
		normals.append(Vector2(d.y, -d.x).normalized() if d.length() > 0.0001 else Vector2.UP)
	for i in count - 1:
		var a := profile[i]
		var b := profile[i + 1]
		if a.distance_to(b) < 0.0001: continue
		var na: Vector2 = normals[i]
		var nb: Vector2 = normals[i]
		if i > 0 and normals[i - 1].angle_to(normals[i]) < CREASE and normals[i - 1].angle_to(normals[i]) > -CREASE:
			na = (normals[i - 1] + normals[i]).normalized()
		if i < count - 2 and normals[i].angle_to(normals[i + 1]) < CREASE and normals[i].angle_to(normals[i + 1]) > -CREASE:
			nb = (normals[i] + normals[i + 1]).normalized()
		for s in SEGMENTS:
			var t0 := TAU * s / SEGMENTS
			var t1 := TAU * (s + 1) / SEGMENTS
			var p00 := at + Vector3(cos(t0) * a.x, a.y, sin(t0) * a.x) * k
			var p01 := at + Vector3(cos(t1) * a.x, a.y, sin(t1) * a.x) * k
			var p10 := at + Vector3(cos(t0) * b.x, b.y, sin(t0) * b.x) * k
			var p11 := at + Vector3(cos(t1) * b.x, b.y, sin(t1) * b.x) * k
			var n00 := Vector3(cos(t0) * na.x, na.y, sin(t0) * na.x)
			var n01 := Vector3(cos(t1) * na.x, na.y, sin(t1) * na.x)
			var n10 := Vector3(cos(t0) * nb.x, nb.y, sin(t0) * nb.x)
			var n11 := Vector3(cos(t1) * nb.x, nb.y, sin(t1) * nb.x)
			_tri(st, p00, p01, p11, n00, n01, n11)
			_tri(st, p00, p11, p10, n00, n11, n10)

## A flat-sided shape: `outline` (forward, up) in square widths, `width` thick across.
static func _extrude(st: SurfaceTool, outline: PackedVector2Array, width: float, k: float) -> void:
	var w := width * 0.5 * k
	var indices := Geometry2D.triangulate_polygon(outline)
	for side: float in [-1.0, 1.0]:
		var n := Vector3(side, 0, 0)
		for i in range(0, indices.size(), 3):
			var p := [outline[indices[i]], outline[indices[i + 1]], outline[indices[i + 2]]]
			_tri(st, Vector3(side * w, p[0].y * k, p[0].x * k), Vector3(side * w, p[1].y * k, p[1].x * k), Vector3(side * w, p[2].y * k, p[2].x * k), n, n, n)
	var clockwise := Geometry2D.is_polygon_clockwise(outline)
	for i in outline.size():
		var a := outline[i]
		var b := outline[(i + 1) % outline.size()]
		var d := b - a
		var out2 := Vector2(d.y, -d.x).normalized() if clockwise else Vector2(-d.y, d.x).normalized()
		var n := Vector3(0, out2.y, out2.x)
		var a0 := Vector3(-w, a.y * k, a.x * k)
		var a1 := Vector3(w, a.y * k, a.x * k)
		var b0 := Vector3(-w, b.y * k, b.x * k)
		var b1 := Vector3(w, b.y * k, b.x * k)
		_tri(st, a0, a1, b1, n, n, n)
		_tri(st, a0, b1, b0, n, n, n)

static func _box(st: SurfaceTool, centre: Vector3, size: Vector3, yaw := 0.0) -> void:
	var basis := Basis(Vector3.UP, -yaw)
	var h := size * 0.5
	for axis in 3:
		for sign: float in [-1.0, 1.0]:
			var n := Vector3.ZERO; n[axis] = sign
			var u := Vector3.ZERO; u[(axis + 1) % 3] = 1.0
			var v := Vector3.ZERO; v[(axis + 2) % 3] = 1.0
			var c := n * h[axis]
			var du := u * h[(axis + 1) % 3]
			var dv := v * h[(axis + 2) % 3]
			var corners := [c - du - dv, c + du - dv, c + du + dv, c - du + dv]
			var world: Array = corners.map(func(p: Vector3) -> Vector3: return centre + basis * p)
			var wn := basis * n
			_tri(st, world[0], world[1], world[2], wn, wn, wn)
			_tri(st, world[0], world[2], world[3], wn, wn, wn)

## One triangle facing its normals (Godot's front faces wind clockwise); degenerate ones dropped.
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3) -> void:
	var face := (b - a).cross(c - a)
	if face.length_squared() < 1e-14: return
	if face.dot(na + nb + nc) > 0.0:
		var swap := b; b = c; c = swap
		var swap_n := nb; nb = nc; nc = swap_n
	st.set_normal(na); st.add_vertex(a)
	st.set_normal(nb); st.add_vertex(b)
	st.set_normal(nc); st.add_vertex(c)
