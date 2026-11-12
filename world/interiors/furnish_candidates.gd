extends RefCounted
## furnish candidates extracted from interior_furnisher.gd.
## State and callback dispatch stay on the owning instance; authored transforms and order are unchanged.

const SOLID := 2
const LANE := 4
const CLEAR := 8
const RUG := 16
const GAP := 0.03
const TALL_M := 1.35
const BED_SIZE := Vector3(2.05, 1.1, 2.1)
## Furniture Anon placed (world/housing/home_furnishing.gd ITEM_LAYER on top of layer 1). The
## built-in layout ignores it: whether those items had loaded before the house furnished changed
## the player's home layout from load to load (bug board #34, 2026-10-28).
const PLAYER_FURNISHING_LAYER := 1 << 17
## M-LIF-05 (board #195, "furniture clear of doors"): standing furniture keeps out of a zone just
## inside the front door: DOOR_SIDE_CLEARANCE past each jamb along the wall and DOOR_DEPTH_CLEARANCE
## into the room. The door swing, the inside handle and the walking lane were already kept clear
## (furnish_surfaces.gd, occupancy_grid.gd); a wardrobe could still stand right beside the latch
## jamb or a table just past the lane, so ponies and Anon squeezed in. Rugs, the doormat and
## wall/table decor are exempt.
const DOOR_SIDE_CLEARANCE := 0.35
const DOOR_DEPTH_CLEARANCE := 1.1

## False when a piece of `size` at plan point `c` turned `yaw` would stand in the door zone above.
## Rollback / A-B switch (tools/life_beds/door_clearance_probe.gd --no-door-rule): false = no door zone.
static var door_rule_enabled := true
static func _door_ok(context: RefCounted, c: Vector2, yaw: float, size: Vector3) -> bool:
	if not door_rule_enabled or size.y <= 0.03: return true
	var door_pt := context.door_pt as Vector2
	var inward := (context.door_in as Vector2) - door_pt
	if inward.length_squared() < 1e-6: return true
	inward = inward.normalized()
	var along := Vector2(-inward.y, inward.x)
	var half_door := float((context.home as Node3D).door_width) * float(context.s) * 0.5
	# Separating axes of two rectangles: the zone (door frame) and the piece (its own frame).
	var zone_c := door_pt + inward * DOOR_DEPTH_CLEARANCE * 0.5
	var zone_half := Vector2(half_door + DOOR_SIDE_CLEARANCE, DOOR_DEPTH_CLEARANCE * 0.5)
	var right := context._right(yaw) as Vector2
	var front := context._front(yaw) as Vector2
	var piece_half := Vector2(size.x * 0.5, size.z * 0.5)
	var offset := c - zone_c
	for axis: Vector2 in [along, inward, right, front]:
		var zone_r := absf(axis.dot(along)) * zone_half.x + absf(axis.dot(inward)) * zone_half.y
		var piece_r := absf(axis.dot(right)) * piece_half.x + absf(axis.dot(front)) * piece_half.y
		if absf(axis.dot(offset)) >= zone_r + piece_r: return true
	return false


static func _wall_candidates(context: RefCounted, area: Dictionary, id: String, size: Vector3, spec: Dictionary, step: Dictionary) -> Array:
	var out := []
	var r: Rect2 = area.rect
	var clear: float = spec.get("clear", 0.0)
	for side in 4:
		var n: Vector2 = [Vector2(0, 1), Vector2(0, -1), Vector2(1, 0), Vector2(-1, 0)][side]
		var along_x := n.x == 0
		var lo := (r.position.x if along_x else r.position.y) + size.x * 0.5 + 0.05
		var hi := (r.end.x if along_x else r.end.y) - size.x * 0.5 - 0.05
		var line: float = [r.position.y, r.end.y, r.position.x, r.end.x][side]
		var yaw := (context._yaw_of(n) as float)
		var a := lo
		var k := -1
		var side_out := []
		while a <= hi + 1e-4:
			var on_wall := Vector2(a, line) if along_x else Vector2(line, a)
			var c := on_wall + n * (size.z * 0.5 + GAP)
			a += 0.1
			k += 1
			if not (context._solid_ok((context._cells(c, yaw, size.x * 0.5, size.z * 0.5) as PackedInt32Array)) as bool): continue
			if clear > 0.0 and not (context._open_ok((context._cells(c + n * (size.z * 0.5 + clear * 0.5), yaw, size.x * 0.5, clear * 0.5) as PackedInt32Array)) as bool): continue
			if not (context._backed(c, yaw, size.x, size.z) as bool): continue
			if (context._blocks_window(c, yaw, size) as bool): continue
			var weight := 1.0
			var corner := (context._corner(c, yaw, size.x, size.z) as int)
			if step.get("corner", false): weight *= 5.0 if corner != 0 else 0.4
			if step.get("mid_wall", false):
				weight *= 0.3 + 3.0 * (1.0 - absf(a - 0.1 - (lo + hi) * 0.5) / maxf((hi - lo) * 0.5, 0.1))
			if step.has("near") and area.placed.has(step.near):
				weight *= 0.2 + 4.0 * exp(-c.distance_to(area.placed[step.near].pos) / 1.2)
			if step.has("far_from") and area.placed.has(step.far_from):
				weight *= 0.2 + c.distance_to(area.placed[step.far_from].pos)
			if size.y < TALL_M and (context._under_window(c, yaw, size) as bool): weight *= 2.0
			# Bedroom pieces (wardrobe, dresser) belong by the bed, not across the room.
			if step.get("near_bed", false) and not area.beds.is_empty():
				var d := INF
				for bed: Dictionary in area.beds: d = minf(d, c.distance_to(bed.pos))
				weight *= 0.25 + 3.0 * exp(-d / 2.0)
			weight *= 0.5 + minf(c.distance_to((context.door_in as Vector2)), 4.0) / 4.0
			side_out.append({"pos": c, "yaw": yaw, "weight": weight, "snug": true, "k": k})
		# dev 2026-09-26: a whole free wall stayed empty while a cupboard went by a window. Long
		# unbroken stretches of free wall draw pieces to them.
		var i := 0
		while i < side_out.size():
			var j := i
			while j + 1 < side_out.size() and side_out[j + 1].k == side_out[j].k + 1: j += 1
			var run_m := (j - i + 1) * 0.1 + size.x
			for m in range(i, j + 1): side_out[m].weight *= 0.4 + run_m / 1.5
			i = j + 1
		out.append_array(side_out)
	return out

static func _island_candidates(context: RefCounted, area: Dictionary, size: Vector3, spec: Dictionary) -> Array:
	var out := []
	var r: Rect2 = area.rect
	var aisle: float = spec.get("aisle", 0.85)
	var mid := r.get_center()
	var solid := (context._sat(SOLID | LANE | CLEAR) as PackedInt32Array)
	var open := (context._sat(SOLID) as PackedInt32Array)
	for q in 2:
		var ex := size.x * 0.5 if q == 0 else size.z * 0.5
		var ez := size.z * 0.5 if q == 0 else size.x * 0.5
		var y := r.position.y + 0.2
		while y < r.end.y:
			var x := r.position.x + 0.2
			while x < r.end.x:
				var c := Vector2(x, y)
				x += 0.2
				if not (context._box_clean(solid, c, ex, ez) as bool) or not (context._box_clean(open, c, ex + aisle, ez + aisle) as bool): continue
				# The oven and cupboards face into the house, toward the door side.
				var yaw := q * PI * 0.5
				if (context._front(yaw) as Vector2).dot((context.door_in as Vector2) - c) < 0.0: yaw += PI
				out.append({"pos": c, "yaw": yaw, "weight": 1.0 / (1.0 + c.distance_to(mid)), "free": true})
			y += 0.2
	return out

static func _face_candidates(context: RefCounted, area: Dictionary, size: Vector3, spec: Dictionary, step: Dictionary) -> Array:
	var out := []
	if not area.placed.has(step.anchor): return out
	var a: Dictionary = area.placed[step.anchor]
	var range_m: Array = step.get("distance", [2.3, 3.0])
	var f := (context._front(a.yaw) as Vector2)
	var clear: float = spec.get("clear", 0.0)
	var dist: float = range_m[0]
	while dist <= range_m[1] + 1e-4:
		for lateral in [0.0, -0.2, 0.2]:
			var c: Vector2 = a.pos + f * (a.size.z * 0.5 + dist) + (context._right(a.yaw) as Vector2) * lateral
			var yaw: float = a.yaw + PI
			if not (context._solid_ok((context._cells(c, yaw, size.x * 0.5, size.z * 0.5) as PackedInt32Array), a.index) as bool): continue
			if not (context._open_ok((context._cells(c - f * (size.z * 0.5 + clear * 0.5), yaw, size.x * 0.5, clear * 0.5) as PackedInt32Array)) as bool): continue
			out.append({"pos": c, "yaw": yaw, "weight": 2.0 if lateral == 0.0 else 1.0, "faces": step.anchor, "allow": a.index})
		dist += 0.2
	return out

static func _front_candidates(context: RefCounted, area: Dictionary, size: Vector3, step: Dictionary) -> Array:
	var out := []
	if not area.placed.has(step.anchor): return out
	var a: Dictionary = area.placed[step.anchor]
	var gaps: Array = step.get("gap", [0.35, 0.5])
	for g in [gaps[0], (gaps[0] + gaps[1]) * 0.5, gaps[1]]:
		var c: Vector2 = a.pos + (context._front(a.yaw) as Vector2) * (a.size.z * 0.5 + g + size.z * 0.5)
		# "turn": 180 faces it back at the anchor (a bench at a table).
		var yaw: float = a.yaw + deg_to_rad(float(step.get("turn", 0.0)))
		if (context._solid_ok((context._cells(c, yaw, size.x * 0.5, size.z * 0.5) as PackedInt32Array), a.index) as bool):
			out.append({"pos": c, "yaw": yaw, "weight": 1.0, "allow": a.index})
	return out

static func _flank_candidates(context: RefCounted, area: Dictionary, size: Vector3, step: Dictionary) -> Array:
	var out := []
	if not area.placed.has(step.anchor): return out
	var a: Dictionary = area.placed[step.anchor]
	for sgn in [1.0, -1.0]:
		for forward in [0.35, 0.65, 0.95]:
			var c: Vector2 = a.pos + (context._right(a.yaw) as Vector2) * sgn * (a.size.x * 0.5 + 0.25 + size.x * 0.5) + (context._front(a.yaw) as Vector2) * forward
			var yaw: float = a.yaw - sgn * deg_to_rad(35.0)
			if not (context._solid_ok((context._cells(c, yaw, size.x * 0.5, size.z * 0.5) as PackedInt32Array)) as bool): continue
			if not (context._open_ok((context._cells(c + (context._front(yaw) as Vector2) * (size.z * 0.5 + 0.3), yaw, size.x * 0.5, 0.3) as PackedInt32Array)) as bool): continue
			out.append({"pos": c, "yaw": yaw, "weight": 1.0})
	return out

static func _between_candidates(context: RefCounted, area: Dictionary, size: Vector3, step: Dictionary) -> Array:
	var out := []
	if not area.placed.has(step.anchor): return out
	var a: Dictionary = area.placed[step.anchor]
	var f := (context._front(a.yaw) as Vector2)
	var centre: Vector2 = a.pos + f * (a.size.z * 0.5 + size.z * 0.5 - 0.1)
	if a.faces != "" and area.placed.has(a.faces):
		var t: Dictionary = area.placed[a.faces]
		centre = ((a.pos + f * a.size.z * 0.5) + (t.pos + (context._front(t.yaw) as Vector2) * t.size.z * 0.5)) * 0.5
	for offset in [0.0, 0.2, -0.2, 0.4]:
		var c: Vector2 = centre + f * offset
		if (context._flat_ok((context._cells(c, a.yaw, size.x * 0.5 - 0.15, size.z * 0.5 - 0.15) as PackedInt32Array), false) as bool):
			out.append({"pos": c, "yaw": a.yaw, "weight": 2.0 if offset == 0.0 else 1.0})
	return out

static func _bedside_candidates(context: RefCounted, size: Vector3, b: Dictionary) -> Array:
	var out := []
	for sgn in [1.0, -1.0]:
		var c: Vector2 = b.pos + (context._right(b.yaw) as Vector2) * sgn * (BED_SIZE.x * 0.5 + 0.06 + size.x * 0.5) - (context._front(b.yaw) as Vector2) * (BED_SIZE.z * 0.5 - size.z * 0.5 - 0.04)
		if not (context._solid_ok((context._cells(c, b.yaw, size.x * 0.5, size.z * 0.5) as PackedInt32Array)) as bool): continue
		out.append({"pos": c, "yaw": b.yaw, "weight": 2.0 if sgn == b.side_sign else 1.0, "snug": true})
	return out

static func _bedrug_candidates(context: RefCounted, size: Vector3, b: Dictionary) -> Array:
	var out := []
	for sgn in [b.side_sign, -b.side_sign]:
		var c: Vector2 = b.pos + (context._right(b.yaw) as Vector2) * sgn * (BED_SIZE.x * 0.5 + size.z * 0.5 - 0.05) + (context._front(b.yaw) as Vector2) * 0.2
		if (context._flat_ok((context._cells(c, b.yaw + PI * 0.5, size.x * 0.5 - 0.15, size.z * 0.5 - 0.15) as PackedInt32Array), false) as bool):
			out.append({"pos": c, "yaw": b.yaw + PI * 0.5, "weight": 3.0 if sgn == b.side_sign else 1.0})
	var foot: Vector2 = b.pos + (context._front(b.yaw) as Vector2) * (BED_SIZE.z * 0.5 + size.z * 0.5 - 0.05)
	if (context._flat_ok((context._cells(foot, b.yaw, size.x * 0.5 - 0.15, size.z * 0.5 - 0.15) as PackedInt32Array), false) as bool):
		out.append({"pos": foot, "yaw": b.yaw, "weight": 1.5})
	return out

static func _on_candidates(context: RefCounted, area: Dictionary, id: String, step: Dictionary) -> Array:
	if not area.placed.has(step.anchor) or not (context._kit as Dictionary).on.has(step.anchor): return []
	var a: Dictionary = area.placed[step.anchor]
	var spec: Dictionary = (context._kit as Dictionary).on[step.anchor]
	var off: Array = spec.offset
	var sgn := 1.0 if (context.rng as RandomNumberGenerator).randf() < 0.5 else -1.0
	var c: Vector2 = a.pos + (context._right(a.yaw) as Vector2) * float(off[0]) * sgn + (context._front(a.yaw) as Vector2) * float(off[2])
	return [{"pos": c, "yaw": a.yaw + deg_to_rad(float(spec.get("yaw", 0.0))) * sgn, "weight": 1.0, "lift": float(off[1])}]

static func _bedfoot_candidates(context: RefCounted, size: Vector3, b: Dictionary) -> Array:
	var c: Vector2 = b.pos + (context._front(b.yaw) as Vector2) * (BED_SIZE.z * 0.5 + 0.12 + size.z * 0.5)
	if not (context._solid_ok((context._cells(c, b.yaw, size.x * 0.5, size.z * 0.5) as PackedInt32Array)) as bool): return []
	return [{"pos": c, "yaw": b.yaw, "weight": 1.0}]

static func _window_floor_candidates(context: RefCounted, area: Dictionary, size: Vector3, spec: Dictionary) -> Array:
	var out := []
	for w: Dictionary in (context.windows as Array):
		if not area.rect.grow(0.3).has_point(w.edge): continue
		var c: Vector2 = w.edge + w.n * (size.z * 0.5 + 0.12)
		if (context._flat_ok((context._cells(c, (context._yaw_of(w.n) as float), size.x * 0.5, size.z * 0.5) as PackedInt32Array), spec.get("no_lane", false)) as bool) \
				and _door_ok(context, c, (context._yaw_of(w.n) as float), size):
			out.append({"pos": c, "yaw": (context._yaw_of(w.n) as float), "weight": 1.0})
	return out

static func _open_candidates(context: RefCounted, area: Dictionary, size: Vector3, spec: Dictionary, flat: bool) -> Array:
	var out := []
	var r: Rect2 = area.rect
	var ring: float = spec.get("ring", 0.4)
	var along_z := r.size.y > r.size.x
	var yaw := PI * 0.5 if along_z else 0.0
	var ex := size.z * 0.5 if along_z else size.x * 0.5
	var ez := size.x * 0.5 if along_z else size.z * 0.5
	var solid := (context._sat(SOLID | RUG) as PackedInt32Array) if flat else (context._sat(SOLID | LANE | CLEAR) as PackedInt32Array)
	var open := (context._sat(SOLID) as PackedInt32Array)
	var y := r.position.y + 0.25
	while y < r.end.y:
		var x := r.position.x + 0.25
		while x < r.end.x:
			var c := Vector2(x, y)
			x += 0.25
			if flat:
				if (context._box_clean(solid, c, ex - 0.1, ez - 0.1) as bool):
					out.append({"pos": c, "yaw": yaw, "weight": 1.0 / (1.0 + c.distance_to(r.get_center()))})
				continue
			if not (context._box_clean(solid, c, ex, ez) as bool) or not (context._box_clean(open, c, ex + ring, ez + ring) as bool): continue
			var weight := 1.0
			for w: Dictionary in (context.windows as Array):
				if c.distance_to(w.edge) < 1.6: weight = 3.0
			out.append({"pos": c, "yaw": yaw + (context.rng as RandomNumberGenerator).randf_range(-0.4, 0.4), "weight": weight, "free": true})
		y += 0.25
	return out

static func _door_candidates(context: RefCounted, size: Vector3) -> Array:
	var n := ((context.door_in as Vector2) - (context.door_pt as Vector2)).normalized()
	if n == Vector2.ZERO: return []
	var yaw := (context._yaw_of(-n) as float)
	var c := (context.door_pt as Vector2) + n * (size.z * 0.5 + 0.08)
	return [{"pos": c, "yaw": yaw, "weight": 1.0}]

static func _snug(context: RefCounted, c: Vector2, yaw: float, size: Vector3, room: int) -> Variant:
	var shape := BoxShape3D.new()
	shape.size = Vector3(maxf(size.x - 0.1, 0.05), minf(size.y, 1.6) - 0.2, 0.04)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 1
	var f := (context._front(yaw) as Vector2)
	var start := c + f * 0.1
	query.transform = Transform3D((context._yaw_basis(yaw) as Basis), (context._world(start, room, 0.15 + shape.size.y * 0.5) as Vector3))
	var reach := size.z * 0.5 + 0.1 + 0.6
	var back := (context.home as Node3D).global_basis.orthonormalized() * Vector3(-f.x, 0, -f.y)
	query.motion = back.normalized() * reach
	var result := (context.space as PhysicsDirectSpaceState3D).cast_motion(query)
	if result.size() < 2 or result[0] <= 0.0 or result[0] >= 1.0: return null
	var travelled: float = result[0] * reach
	var wall := start - f * (travelled + 0.02)
	return wall + f * (size.z * 0.5 + GAP)

static func _wall_behind(context: RefCounted, c: Vector2, yaw: float, size: Vector3, room: int) -> bool:
	var f := (context._front(yaw) as Vector2)
	var r := (context._right(yaw) as Vector2)
	var back := (context.home as Node3D).global_basis.orthonormalized() * Vector3(-f.x, 0, -f.y)
	var skip: Array[RID] = []
	for bed in [(context.home as Node3D).bed] + (context.home as Node3D)._extra_beds:
		if is_instance_valid(bed):
			for body: CollisionObject3D in bed.find_children("*", "CollisionObject3D", true, false): skip.append(body.get_rid())
	var touching := 0
	for t in [-0.4, -0.2, 0.0, 0.2, 0.4]:
		var at: Vector2 = c - f * (size.z * 0.5 - 0.08) + r * size.x * t
		for h in [0.35, 0.7]:
			var from := (context._world(at, room, h) as Vector3)
			var query := PhysicsRayQueryParameters3D.create(from, from + back.normalized() * 0.33, 1, skip)
			if not (context.space as PhysicsDirectSpaceState3D).intersect_ray(query).is_empty(): touching += 1; break
	return touching >= 4

static func _physics_clear(context: RefCounted, c: Vector2, yaw: float, size: Vector3, room: int) -> bool:
	# The door zone is tested on the spot already drawn (like the physics below), not by dropping
	# candidates beforehand: a house whose draw never lands in the zone keeps its layout exactly.
	if not _door_ok(context, c, yaw, size): return false
	var shape := BoxShape3D.new()
	shape.size = Vector3(maxf(size.x - 0.04, 0.05), maxf(minf(size.y, 2.0) - 0.15, 0.05), maxf(size.z - 0.04, 0.05))
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 1
	query.transform = Transform3D((context._yaw_basis(yaw) as Basis), (context._world(c, room, 0.12 + shape.size.y * 0.5) as Vector3))
	var hits := (context.space as PhysicsDirectSpaceState3D).intersect_shape(query, 8)
	hits = hits.filter(func(hit: Dictionary) -> bool:
		var body := hit.collider as CollisionObject3D
		return body == null or (body.collision_layer & PLAYER_FURNISHING_LAYER) == 0)
	if not hits.is_empty() and (context.debug_hits as PackedStringArray).size() < 4:
		var debug_hits: PackedStringArray = context.debug_hits
		debug_hits.append(str(hits[0].collider.get_parent().name) + "/" + str(hits[0].collider.name))
		context.debug_hits = debug_hits
	return hits.is_empty()

