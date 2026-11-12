extends Node
## Benches, picnic tables, stumps and logs ponies can sit on with their normal sit posture.
## Seats are found from the props' own geometry, once, when the town is in the world:
## level surfaces 0.25-0.75 m up become seat slabs, the side with a backrest (or away from a
## table top) sets which way a sitter faces. Props whose collision is one big box get
## seat, back and table boxes instead so a pony can rest on the seat itself.
## Sitting: walk to the floor spot in front, hop up, sit. Any stand request (a new walk,
## a command, the living world) makes her stand on the seat, hop down, and go.
const SEAT_PROPS := ["bench_"]
## Props measured by hand (prop-local metres): seats [x, y, z, face_x, face_z], seat slabs and
## the parts a sitter may overlap (backrest, table top) as [centre, size].
const MANUAL := {
	"lyrasbench_": {"seats": [[0.05, 0.55, -0.6, 1, 0], [0.05, 0.55, 0.6, 1, 0]],
		"slabs": [[Vector3(0, 0.275, -0.05), Vector3(1.0, 0.55, 2.4)]],
		"upper": [[Vector3(-0.62, 0.99, -0.05), Vector3(0.55, 0.88, 2.5)]]},
	"picnictable_": {"seats": [[-0.8, 0.45, 0.88, 0, -1], [0.8, 0.45, 0.88, 0, -1], [-0.8, 0.45, -0.88, 0, 1], [0.8, 0.45, -0.88, 0, 1]],
		"slabs": [[Vector3(0, 0.225, 0.88), Vector3(3.2, 0.45, 0.5)], [Vector3(0, 0.225, -0.88), Vector3(3.2, 0.45, 0.5)]],
		"upper": [[Vector3(0, 0.7, 0), Vector3(3.25, 0.12, 1.22)], [Vector3(0, 0.33, 0), Vector3(0.3, 0.64, 0.9)]]},
}
const CELL := 0.1
const SPACING := 0.95
const BED_REST := preload("res://world/relationships/shared_bed.gd")
const BED_MATTRESS := preload("res://world/life/couch/mattress.gd")
var seats: Array[Node3D] = []
var _ready_done := false
var _tries := 0
var _users := {}   # actor instance id -> {actor, seat, phase, lie_after}

func _ready() -> void:
	add_to_group("pony_seating")
	_scan.call_deferred()

## Wait for the town and its collision, then build every seat once.
func _scan() -> void:
	var towns := get_tree().get_nodes_in_group("town_roots")
	if towns.is_empty():
		_tries += 1
		if _tries < 30: get_tree().create_timer(2.0).timeout.connect(_scan)
		return
	for town: Node in towns:
		for node: Node in town.find_children("*", "Node3D", true, false):
			var name := str(node.name)
			var done := false
			for prefix: String in MANUAL:
				if name.begins_with(prefix): _build_manual(node as Node3D, MANUAL[prefix]); done = true; break
			if done: continue
			for prefix: String in SEAT_PROPS:
				if name.begins_with(prefix): _build(node as Node3D, false); break
	# Seat nodes (world/life/seat.gd) placed before this scan ran.
	for seat: Node in get_tree().get_nodes_in_group("pony_seats"):
		if seat not in seats and bool(seat.get("for_ponies") if seat.get("for_ponies") != null else true): seats.append(seat)
	_ready_done = true
	print("[seating] %d seats" % seats.size())

func _build(prop: Node3D, replace: bool) -> void:
	var basis := prop.global_basis.orthonormalized()
	var ax := basis.x; var az := basis.z
	var base_y := prop.global_position.y
	var cells := {}       # Vector2i (world xz / CELL) -> height above base
	var table := {}
	var tall := PackedVector3Array()
	for mi: MeshInstance3D in prop.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null or not mi.visible: continue
		var xf := mi.global_transform
		var faces := mi.mesh.get_faces()
		for i in range(0, faces.size(), 3):
			var a := xf * faces[i]; var b := xf * faces[i + 1]; var c := xf * faces[i + 2]
			for p in [a, b, c]:
				if p.y - base_y > 0.0: tall.append(p)
			var n := (b - a).cross(c - a)
			if n.length_squared() < 1e-10 or absf(n.normalized().y) < 0.85: continue
			var h := (a.y + b.y + c.y) / 3.0 - base_y
			if h < 0.25 or h > 1.05: continue
			var target := cells if h <= 0.75 else table
			_raster(target, Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z), h)
	var table_cells := table.keys()
	var added := false
	var bodies: Array = []
	for component: Array in _components(cells):
		# Extent in the prop's own axes.
		var lo := Vector2(INF, INF); var hi := Vector2(-INF, -INF); var h := 0.0
		for key: Vector2i in component:
			var w := Vector3((key.x + .5) * CELL, 0, (key.y + .5) * CELL)
			var p := Vector2(w.dot(ax), w.dot(az))
			lo = lo.min(p); hi = hi.max(p); h = maxf(h, cells[key])
		var size := hi - lo + Vector2(CELL, CELL)
		if component.size() * CELL * CELL < 0.12 or minf(size.x, size.y) < 0.25 or maxf(size.x, size.y) < 0.45: continue
		var long_x := size.x >= size.y
		var along := ax if long_x else az
		var across := az if long_x else ax
		var mid2 := (lo + hi) * 0.5
		var centre := ax * mid2.x + az * mid2.y
		centre.y = base_y + h
		var length := maxf(size.x, size.y); var depth := minf(size.x, size.y)
		# Which way to face: toward an adjacent table top, else away from a backrest.
		var facing := 0.0
		for key: Vector2i in table_cells:
			var w := Vector3((key.x + .5) * CELL, 0, (key.y + .5) * CELL) - Vector3(centre.x, 0, centre.z)
			if absf(w.dot(along)) < length * 0.5 and absf(w.dot(across)) < depth * 0.5 + 0.7: facing += signf(w.dot(across))
		if facing == 0.0:
			var back := 0.0
			for p in tall:
				var w := p - centre
				if p.y > centre.y + 0.2 and absf(w.dot(along)) < length * 0.5 and absf(w.dot(across)) < depth * 0.5 + 0.3:
					back += w.dot(across)
			facing = -signf(back) if absf(back) > 0.01 else 1.0
		var forward := (across * signf(facing)).normalized()
		var count := clampi(int(length / SPACING), 1, 4)
		for s in count:
			var offset := (s + 0.5) / count * length - length * 0.5
			var seat := Node3D.new(); seat.name = "Seat%d" % seats.size()
			prop.add_child(seat)
			seat.global_transform = Transform3D(Basis.looking_at(forward, Vector3.UP), centre + along * offset)
			seat.set_meta("depth", depth)
			seat.add_to_group("pony_seats")
			seats.append(seat)
		if replace: bodies.append([centre, along, across, length, depth, forward])
	if replace and not bodies.is_empty():
		for body in prop.find_children("Solid", "StaticBody3D", true, false): (body as StaticBody3D).collision_layer = 0
		var solid := StaticBody3D.new(); solid.name = "SeatSolid"; solid.collision_mask = 0
		prop.add_child(solid)
		for b: Array in bodies:
			_box(solid, b[0] - Vector3.UP * 0.04, b[1], b[2], Vector3(b[3], 0.08, b[4]))
			_box(solid, Vector3(b[0].x, (base_y + b[0].y) * 0.5, b[0].z), b[1], b[2], Vector3(b[3] * 0.9, b[0].y - base_y - 0.1, b[4] * 0.6))
		# The rest of the prop (a backrest behind the seat, a table top) stays solid in its own
		# body, which a pony sitting there is allowed to overlap.
		var upper := AABB(); var first := true
		var seat0: Array = bodies[0]
		for p in tall:
			var behind: bool = (p - (seat0[0] as Vector3)).dot(seat0[5] as Vector3) < -float(seat0[4]) * 0.3
			if (p.y - base_y > 0.8 and behind) or (not table_cells.is_empty() and p.y - base_y > 0.66):
				if first: upper = AABB(p, Vector3.ZERO); first = false
				else: upper = upper.expand(p)
		if not first:
			var top := StaticBody3D.new(); top.name = "SeatUpper"; top.collision_mask = 0; prop.add_child(top)
			var shape := BoxShape3D.new(); shape.size = upper.size.max(Vector3(0.05, 0.05, 0.05))
			var col := CollisionShape3D.new(); col.shape = shape; top.add_child(col); col.global_position = upper.get_center()

func _build_manual(prop: Node3D, spec: Dictionary) -> void:
	for body in prop.find_children("Solid", "StaticBody3D", true, false): (body as StaticBody3D).collision_layer = 0
	var solid := StaticBody3D.new(); solid.name = "SeatSolid"; solid.collision_mask = 0; prop.add_child(solid)
	var top := StaticBody3D.new(); top.name = "SeatUpper"; top.collision_mask = 0; prop.add_child(top)
	for part: Array in spec.slabs: _local_box(solid, part[0], part[1])
	for part: Array in spec.upper: _local_box(top, part[0], part[1])
	for s: Array in spec.seats:
		var seat := Node3D.new(); seat.name = "Seat%d" % seats.size(); prop.add_child(seat)
		var at := prop.to_global(Vector3(s[0], s[1], s[2]))
		var forward := prop.global_basis.orthonormalized() * Vector3(s[3], 0, s[4])
		seat.global_transform = Transform3D(Basis.looking_at(forward.normalized(), Vector3.UP), at)
		seat.set_meta("depth", 0.5)
		seat.add_to_group("pony_seats")
		seats.append(seat)

func _local_box(body: StaticBody3D, centre: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new(); shape.size = size
	var col := CollisionShape3D.new(); col.shape = shape; body.add_child(col); col.position = centre

func _box(parent: Node3D, at: Vector3, along: Vector3, across: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new(); shape.size = size
	var col := CollisionShape3D.new(); col.shape = shape; parent.add_child(col)
	col.global_transform = Transform3D(Basis(along, Vector3.UP, across).orthonormalized(), at)

func _raster(target: Dictionary, a: Vector2, b: Vector2, c: Vector2, h: float) -> void:
	var lo := a.min(b).min(c); var hi := a.max(b).max(c)
	for x in range(floori(lo.x / CELL), floori(hi.x / CELL) + 1):
		for z in range(floori(lo.y / CELL), floori(hi.y / CELL) + 1):
			var p := Vector2((x + .5) * CELL, (z + .5) * CELL)
			if Geometry2D.point_is_inside_triangle(p, a, b, c) or (hi - lo).length() < CELL * 1.5:
				var key := Vector2i(x, z)
				target[key] = maxf(float(target.get(key, 0.0)), h)

func _components(cells: Dictionary) -> Array:
	var out := []; var seen := {}
	for start: Vector2i in cells:
		if seen.has(start): continue
		var group := []; var stack := [start]; seen[start] = true
		while not stack.is_empty():
			var key: Vector2i = stack.pop_back(); group.append(key)
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var next: Vector2i = key + d
				if cells.has(next) and not seen.has(next) and absf(float(cells[next]) - float(cells[key])) < 0.05:
					seen[next] = true; stack.append(next)
		out.append(group)
	return out

## Seat nodes (world/life/seat.gd) add and remove themselves as furniture comes and goes.
func register_seat(seat: Node3D) -> void:
	if seat not in seats: seats.append(seat)

func unregister_seat(seat: Node3D) -> void:
	seats.erase(seat)

## The Hayburger's booths (world/buildings/hayburger/hayburger_interior.gd "Booth_*", board #348):
## one pony seat per bench, on its aisle half, facing the table; she walks to the aisle end of
## the bench ("front" meta, the sit() rest's approach and landing spot), hops along onto it and
## sits with the normal sit posture. Built once per room from the booth's own vinyl cushions and
## tabletop and kept in the room's meta. Only the restaurant's customers use them
## (hayburger_customers.gd _take_booth): they are not in `seats`, so free_seat_near never offers
## a booth seat with an approach under the table.
const BOOTH_ALONG := 0.55        # seat centre from the bench centre, towards the aisle (m)
const BOOTH_BACK := 0.06         # nearer the backrest than the cushion centre (m)
const BOOTH_AISLE := 1.68        # the approach spot from the bench centre, past its aisle end (m)
const BOOTH_CUSHION_TOP := 0.075 # half the vinyl cushion's height
const BOOTH_SEAT_FLOOR := 0.405  # the cushion centre above the floor
func booth_seats(room: Node3D) -> Array:
	if not is_instance_valid(room) or not room.is_inside_tree(): return []
	if room.has_meta("pony_booth_seats"):
		var cached: Variant = room.get_meta("pony_booth_seats")
		if cached is Array: return cached
	var made: Array = []
	var centre := room.global_position
	for booth: Node in room.find_children("Booth_*", "Node3D", true, false):
		var top: Node3D = null
		var cushions: Array[Node3D] = []
		for child: Node in booth.get_children():
			if not child is Node3D: continue
			if str(child.name).contains("CreamTabletop"): top = child as Node3D
			elif str(child.name).contains("VinylSeat"): cushions.append(child as Node3D)
		if top == null: continue
		for cushion: Node3D in cushions:
			var at := cushion.global_position
			var forward := top.global_position - at
			forward.y = 0.0
			if forward.length() < 0.05: continue
			forward = forward.normalized()
			var along := forward.cross(Vector3.UP).normalized()
			if along.dot(Vector3(centre.x - at.x, 0.0, centre.z - at.z)) < 0.0: along = -along
			var seat := Node3D.new(); seat.name = "PonyBoothSeat"
			booth.add_child(seat)
			var point := at + along * BOOTH_ALONG - forward * BOOTH_BACK
			point.y = at.y + BOOTH_CUSHION_TOP
			seat.global_transform = Transform3D(Basis.looking_at(forward, Vector3.UP), point)
			seat.set_meta("depth", 0.45)
			var floor_at := at + along * BOOTH_AISLE
			floor_at.y = at.y - BOOTH_SEAT_FLOOR
			seat.set_meta("front", floor_at)
			made.append(seat)
	room.set_meta("pony_booth_seats", made)
	return made

## The free player seat nearest `at` within `radius` (any seat node in group "player_seats",
## or a town bench seat), for Anon.
func player_seat_near(at: Vector3, radius: float, who: Object = null, hit_collider: Object = null) -> Node3D:
	var best: Node3D = null
	var best_d := radius
	var candidates: Array = get_tree().get_nodes_in_group("player_seats")
	for seat in seats:
		if seat not in candidates: candidates.append(seat)
	for seat: Node3D in candidates:
		if not is_instance_valid(seat) or not _free(seat, who): continue
		if seat.get("for_player") != null and not seat.for_player: continue
		var d := seat.global_position.distance_to(at)
		if d < best_d and player_seat_accessible(seat, who, hit_collider): best = seat; best_d = d
	if best == null and hit_collider != null: best = _bed_seat(hit_collider, who)
	return best

## Any bed is a place to lie down and cuddle (dev 2026-09-28): aiming anywhere on it picks its rest,
## installed on first use (world/relationships/shared_bed.gd). Only the bed that was hit counts.
func _bed_seat(hit_collider: Object, who: Object) -> Node3D:
	var bed: Node3D = BED_MATTRESS.bed_of(hit_collider)
	if bed == null or not bed.has_meta("mattress_top"): return null
	var rest: Node3D = BED_REST.for_bed(bed)
	var seats_here: Variant = rest.get("seats") if rest != null else null
	if not seats_here is Array or (seats_here as Array).is_empty(): return null
	var seat: Variant = (seats_here as Array)[0]
	if not is_instance_valid(seat) or not _free(seat, who) or not player_seat_accessible(seat, who, hit_collider): return null
	return seat as Node3D

## A wall hit must never select nearby furniture on its other side. Both the
## target ray and the seated body need a clear route, not merely a nearby cushion.
func player_seat_accessible(seat: Node3D, who: Object, hit_collider: Object = null) -> bool:
	if not is_instance_valid(seat) or not who is Node3D: return false
	var furniture: Node = seat.get_parent()
	if hit_collider != null and not (hit_collider is Node and (hit_collider == furniture or furniture.is_ancestor_of(hit_collider))): return false
	var camera: Camera3D = preload("res://world/player_view.gd").camera(who)
	var eye: Vector3 = camera.global_position if is_instance_valid(camera) else who.global_position + Vector3.UP * .78
	if eye.distance_to(seat.global_position) > 3.0: return false
	var excludes: Array[RID] = []
	if who is CollisionObject3D: excludes.append(who.get_rid())
	# Ignore furniture for the entire ray, so its backrest cannot hide a wall
	# between a protruding cushion and the seated destination.
	if furniture is CollisionObject3D: excludes.append(furniture.get_rid())
	for part: Node in furniture.find_children("*", "CollisionObject3D", true, false): excludes.append(part.get_rid())
	var body_at: Vector3 = Vector3(eye.x, who.global_position.y + .35, eye.z)
	var space: PhysicsDirectSpaceState3D = seat.get_world_3d().direct_space_state
	for segment: Array in [[eye, seat.global_position + Vector3.UP * .12], [body_at, seat.global_position + Vector3.UP * .35]]:
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(segment[0], segment[1], 1)
		query.exclude = excludes
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty(): return false
	return true

# ------------------------------------------------------------------ using seats
func _free(seat: Node3D, actor: Object) -> bool:
	var who: Variant = (seat.get_meta("occupant") if seat.has_meta("occupant") else null)
	return who == null or not is_instance_valid(who) or who == actor

func free_seat_near(at: Vector3, radius: float, actor: Node3D = null) -> Node3D:
	var best: Node3D = null; var best_d := radius
	for seat in seats:
		if not is_instance_valid(seat) or not _free(seat, actor): continue
		var d := seat.global_position.distance_to(at)
		if d < best_d: best = seat; best_d = d
	return best

func phase(actor: Node3D) -> String:
	return str(_users.get(actor.get_instance_id(), {}).get("phase", ""))

## Walk to a free seat within `radius` and sit on it. False when there is none.
func sit(actor: Node3D, radius: float, seat: Node3D = null, rest: Dictionary = {}) -> bool:
	if not _ready_done: return false
	if seat == null: seat = free_seat_near(actor.global_position, radius, actor)
	if seat == null or not _free(seat, actor) or _users.has(actor.get_instance_id()): return false
	var couch: Variant = (seat.get_meta("couch") if seat.has_meta("couch") else null)
	if is_instance_valid(couch) and couch.opened and rest.is_empty(): return false
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav == null: return false
	seat.set_meta("occupant", actor)
	var entry := {"actor": actor, "seat": seat, "phase": "approach", "until": Time.get_ticks_msec() + 60000, "posture": str(rest.get("posture", "sit"))}
	entry.merge(rest, true)
	_users[actor.get_instance_id()] = entry
	actor.set_meta("seating", true)
	nav.go_to(entry.get("front", _front(seat)), 1)
	return true

func _front(seat: Node3D) -> Vector3:
	if seat.get_meta("floor_sit", false): return seat.global_position
	var at := seat.global_position - seat.global_basis.z * (float(seat.get_meta("depth", 0.45)) * 0.5 + 0.55)
	var hit := seat.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.3, at + Vector3.DOWN * 3.0, 1))
	return hit.position if not hit.is_empty() else Vector3(at.x, seat.global_position.y - 0.45, at.z)

func _physics_process(_delta: float) -> void:
	if _users.is_empty(): return   # no keys() copy on the (usual) empty ticks
	for key in _users.keys():
		var entry: Dictionary = _users[key]
		# Check before typing: assigning a freed pony to a Node3D variable is itself an error
		# (5240 "previously freed instance" errors when a seated pony despawned).
		if not is_instance_valid(entry.actor) or not is_instance_valid(entry.seat):
			_release(entry)
			continue
		var actor: Node3D = entry.actor
		var seat: Node3D = entry.seat
		var nav: Node = actor.get_node_or_null("Navigator")
		if nav == null:
			_release(entry); continue
		if entry.has("owner") and nav.command_owner != entry.owner:
			if entry.phase in ["approach", "climbing", "sitting_down"]:
				_release(entry); continue
			actor.request_posture("stand")
		match entry.phase:
			"approach":
				var front: Vector3 = entry.get("front", _front(seat))
				var near := Vector2(actor.global_position.x - front.x, actor.global_position.z - front.z).length() < 0.6 and absf(actor.global_position.y - front.y) < 0.4
				if near and actor.posture_status().kind == "stand":
					if seat.get_meta("floor_sit", false):
						nav.stay()
						actor.set_meta("seated", true)
						entry.tries = 0
						entry.phase = "sitting_down"
					else: _hop_on(entry, actor, seat)
				elif Time.get_ticks_msec() > int(entry.until) or nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED] or (not nav._has_target and not near):
					_release(entry)
			"sitting_down":
				if seat.get_meta("floor_sit", false) and actor.has_method("face_direction"):
					actor.face_direction(-seat.global_basis.orthonormalized().z)
					if (-actor.global_basis.orthonormalized().z).dot(-seat.global_basis.orthonormalized().z) < .95: continue
				# Landing on the seat takes a tick or two before she counts as supported.
				if actor.request_posture(entry.posture):
					if actor.get("posture") != null:
						# No drifting into a lie-down on a bench.
						entry.lie_after = actor.posture.lie_after_seconds
						actor.posture.lie_after_seconds = 1e9
					entry.phase = "seated"
					preload("res://world/audio/interaction_sounds.gd").play_at(actor, "prop_rest")
				else:
					entry.tries = int(entry.tries) + 1
					if entry.tries > 90:
						print("[seating] %s could not sit: %s" % [actor.name, actor.posture_status().refusal])
						_hop_off(entry, actor, seat)
			"seated":
				var status: Dictionary = actor.posture_status()
				if actor.get("_held") or status.requested != entry.posture:
					# Someone wants her up: stand on the seat, then hop down in front of it.
					if actor.get("_held"): _release(entry)
					elif status.kind == "stand" and status.settled: _hop_off(entry, actor, seat)

func _hop_on(entry: Dictionary, actor: Node3D, seat: Node3D) -> void:
	if entry.has("couch"):
		if not is_instance_valid(entry.couch): _release(entry); return
		if not entry.couch.hop_clear(actor, actor.global_position, entry.rest.origin): return
	entry.phase = "climbing"
	actor.set_meta("seated", true)
	actor.get_node("Navigator").stay()
	actor.motion_paused = true
	var start := actor.global_position
	var start_rotation := actor.global_basis.get_rotation_quaternion()
	var rest: Transform3D = entry.get("rest", Transform3D(seat.global_basis.orthonormalized(), seat.global_position + Vector3.UP * 0.02))
	for upper in seat.get_parent().find_children("SeatUpper", "StaticBody3D", false, false): actor.add_collision_exception_with(upper)
	var tween := create_tween().bind_node(actor)
	entry.tween = tween
	tween.tween_method(func(t: float):
		actor.global_position = start.lerp(rest.origin, t) + Vector3.UP * sin(PI * t) * 0.3 * actor.body_scale
		# Rotations only: a scaled seat (or pony) basis cannot be slerped.
		actor.global_basis = Basis(start_rotation.slerp(rest.basis.get_rotation_quaternion(), t)), 0.0, 1.0, 0.5)
	tween.tween_callback(func():
		actor.motion_paused = false
		actor.reset_motion(rest)
		entry.tries = 0
		entry.phase = "sitting_down")

func _hop_off(entry: Dictionary, actor: Node3D, seat: Node3D) -> void:
	if seat.get_meta("floor_sit", false):
		_release(entry); return
	if entry.has("couch") and is_instance_valid(entry.couch):
		var floor_at: Vector3 = preload("res://world/life/couch/exit_space.gd").find_exit(actor, seat, entry.front, actor.profile.clearance, actor.profile.radius)
		if not floor_at.is_finite(): return
		if not entry.couch.hop_clear(actor, actor.global_position, floor_at): return
		entry.front = floor_at
	entry.phase = "leaving"
	actor.motion_paused = true
	var start := actor.global_position
	var land: Vector3 = entry.get("front", _front(seat))
	var tween := create_tween().bind_node(actor)
	entry.tween = tween
	tween.tween_method(func(t: float):
		actor.global_position = start.lerp(land, t) + Vector3.UP * sin(PI * t) * 0.25 * actor.body_scale, 0.0, 1.0, 0.45)
	tween.tween_callback(func():
		actor.motion_paused = false
		actor.reset_motion(Transform3D(actor.global_basis, land + Vector3.UP * 0.02))
		_release(entry))

func _release(entry: Dictionary) -> void:
	var actor: Variant = entry.actor
	var seat: Variant = entry.seat
	var tween: Variant = entry.get("tween")
	if tween != null and tween.is_valid(): tween.kill()
	if is_instance_valid(seat) and (seat.get_meta("occupant") if seat.has_meta("occupant") else null) == actor: seat.remove_meta("occupant")
	if is_instance_valid(actor):
		actor.remove_meta("seating")
		actor.remove_meta("seated")
		actor.motion_paused = false
		if entry.get("posture", "sit") == "lie_down": actor.sleeping = false
		if is_instance_valid(seat):
			for upper in seat.get_parent().find_children("SeatUpper", "StaticBody3D", false, false): actor.remove_collision_exception_with(upper)
		if entry.has("lie_after") and actor.get("posture") != null: actor.posture.lie_after_seconds = entry.lie_after
		if not is_instance_valid(seat) or entry.phase == "climbing":
			actor.request_posture("stand")
			if entry.has("front") and not actor.get("_held"):
				actor.reset_motion(Transform3D(actor.global_basis, entry.front))
	# A freed actor cannot supply its instance ID.
	for key in _users.keys():
		if is_same(_users[key], entry): _users.erase(key); break

func _exit_tree() -> void:
	for entry in _users.values(): _release(entry)
