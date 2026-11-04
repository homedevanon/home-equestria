extends Node3D
## The walk-in Ponyville Day Spa building (docs/SPA_PLAN_2026_10_29.md step 2, Godot part).
## Attach once to the EXISTING town node spa_01, the way zecora_hut.gd swaps its hut: the original
## mesh is hidden and its eight filled collision boxes and the town's spa_01_ramp are switched off.
## In their place, under one identity transform in spa_01's own space (door faces +Z, shop floor
## y 0.36, street y -1.74): the Blender-edited shell (world/props/spa/spa_shell.glb) with its
## doorway, steps and inner walls, and the interior model (spa_interior.glb) with the 20 contract
## markers. Nothing visible is built here; the only code-made things are collision, lights and
## the hinged door, whose leaf is the original door artwork (spa_door_leaf.glb). The two waiting
## benches are the town's existing wooden-bench prop, placed here (SPA_PLAN "Waiting seats: reuse").
## Room logic copied from the Hayburger (hayburger_runtime.gd / hayburger_shell.gd), not shared:
## hollow two-sided shell collision with the roof and ceiling marked navigation_ceiling, a smooth
## 22 degree ramp collider under the visible steps, a latched door open 09:00-19:00, one walk grid
## refresh per navigation service, and the inside hidden beyond 40 m / shown again within 35 m.
## Markers: spa_markers() (venue-local, the spa_customers.gd contract), global_markers() and
## marker(name) (global). Every marker's -Z is the way the pony or player faces.
const DOOR := preload("res://world/minigames/spa/spa_door.gd")
const SOURCE_ID := "spa_01"
const SHELL_PATH := "res://world/props/spa/spa_shell.glb"
const INTERIOR_PATH := "res://world/props/spa/spa_interior.glb"
const LEAF_PATH := "res://world/props/spa/spa_door_leaf.glb"
const BENCH_PATH := "res://world/props/household/wooden-bench.glb"
const GUIDE := preload("res://world/minigames/spa/spa_guide.gd")
const SEAT := preload("res://world/life/seat.gd")
## Waiting benches (dev 2026-10-29: waiting clients sit on a bench). The prop is 1.0 x 0.32 x 0.25;
## scaled like the town's (placements.json "bench": 1.80 x 0.48 x 0.47). [name, centre on the
## floor, yaw]; at yaw 0 the bench runs along x and its sitters face -Z. "hoof": along the hoof
## room's front wall, clear of the doorway past partition A (x > -1.2) and the table's foot; the
## rub line waits here. "lobby": against the right tower's east wall, facing the counter; clients
## waiting for the wing nook wait here.
const BENCH_SCALE := Vector3(1.807, 1.49, 1.865)
const BENCH_SIZE := Vector3(1.80, 0.48, 0.47)
const BENCHES := [["hoof", Vector3(-3.75, 0.36, 1.15), 0.0], ["lobby", Vector3(6.15, 0.36, -0.60), 90.0]]
## Two seats per bench, this far either side of its middle (seating.gd SPACING is 0.95).
const SEAT_OFFSET := 0.45
const CUSTOMERS_PATH := "res://world/minigames/spa/spa_customers.gd"
const HANDS_PATH := "res://world/minigames/spa/spa_hands.gd"
const OPEN_HOUR := 9.0
const CLOSE_HOUR := 19.0
## Spa-local survey numbers (art-source/spa-2026-10-29/SHELL_NOTES.md).
const FLOOR_Y := 0.36
const CEILING_Y := 4.6
const STREET_Y := -1.74
const DOOR_X := -0.14
const DOOR_PLANE_Z := 2.40
const HINGE := Vector3(0.78, 0.36, 2.40)
const LEAF_SIZE := Vector3(1.84, 3.43, 0.08)
## Triangles whose centre is above this (1.24 m over the shop floor) are upper walls, the door arch,
## window heads, ceiling and roof: they still collide and limit headroom, but the walk grid skips
## them as floor (navigation_ceiling). It keeps two floor spans per column; under the doorway the
## lintel and arch soffit used both, so the floor there was never sampled and the inside was cut
## off. Nothing a pony or player stands on in the spa is this high.
const CEILING_SPLIT := 1.6
## The original filled boxes stopped at y 6.81; roof triangles wholly above this get no collider.
const COLLISION_TOP := 6.9
## One smooth plane from the upper landing edge to the street, 6 cm over every step nosing. The
## shell's foot apron is at -1.74, but in town spa_01 stands at world y -10.267 and the street at
## -12.061 (local -1.794), so the plane runs on to -1.90 and ends under the street: no lip at the foot.
const RAMP_TOP := Vector2(4.81, 0.36)    # (z, y)
const RAMP_FOOT := Vector2(10.41, -1.90)
const RAMP_X := Vector2(-1.44, 1.16)
const RAMP_BASE_Y := -2.6
## The room volume (spa-local): is_inside(), the distance hide and the walk grid refresh use it.
const ROOM := AABB(Vector3(-8.2, 0.0, -5.6), Vector3(16.6, 4.8, 8.0))
const NAV_BOX := AABB(Vector3(-8.6, -2.8, -6.4), Vector3(17.2, 8.0, 17.0))
const HIDE_BEYOND := 40.0
const SHOW_WITHIN := 35.0

var shell: Node3D
var interior: Node3D
var door: DOOR
var business_open := false
var game: Node
var customers: Node
var hands: Node
## First-visit tips while the player is inside (spa_guide.gd).
var guide: Node
## Built once in _ready: venue-local marker transforms by name.
var _markers: Dictionary = {}
var _lights: Array[Light3D] = []
var _environment_timer := 0.0
var report: Dictionary = {}
## Set by attach() so the GLBs are read once.
var _shell_scene: Node3D
var _leaf_scene: Node3D
var _interior_scene: Node3D


## Hides the original spa and installs the venue under it. Fails closed: if the shell or door
## cannot be loaded the original building stays as it was. Returns the venue, or null.
## `-- --no-spa` (developer launches only) keeps the original building: rollback and FPS A/B.
static func attach(existing: Node3D) -> Node3D:
	if existing == null or str(existing.name) != SOURCE_ID: return null
	if "--no-spa" in preload("res://world/dev_tools.gd").user_args(): return null
	var installed: Node3D = existing.get_node_or_null("SpaVenue") as Node3D
	if installed != null: return installed
	# Read the replacement before disabling the source's eight filled boxes.
	var shell_scene: Node3D = load_scene(SHELL_PATH)
	var leaf_scene: Node3D = load_scene(LEAF_PATH)
	if shell_scene == null or leaf_scene == null:
		push_warning("Spa venue: shell or door model missing; the old spa stays")
		if shell_scene != null: shell_scene.free()
		if leaf_scene != null: leaf_scene.free()
		return null
	var interior_scene: Node3D = load_scene(INTERIOR_PATH)
	if interior_scene == null: push_warning("Spa venue: interior model missing; the room stays empty")
	_switch_off(existing)
	# The town's 22 degree stone wedge overlaps the new steps (tools/rnl_scenery/build.gd ramp()).
	# spa_01_foundation stays: its top is below the shop floor.
	var ramp: Node3D = existing.get_parent().get_node_or_null(SOURCE_ID + "_ramp") as Node3D if existing.get_parent() != null else null
	if ramp != null: _switch_off(ramp)
	var venue: Node3D = load("res://world/minigames/spa/spa_venue.gd").new()
	venue.name = "SpaVenue"
	venue._shell_scene = shell_scene; venue._leaf_scene = leaf_scene; venue._interior_scene = interior_scene
	existing.add_child(venue)
	existing.set_meta("spa_interior", true)
	print("[spa] venue attached")
	return venue


static func _switch_off(node: Node3D) -> void:
	if node is CollisionObject3D:
		(node as CollisionObject3D).collision_layer = 0; (node as CollisionObject3D).collision_mask = 0
	for collider: CollisionObject3D in node.find_children("*", "CollisionObject3D", true, false):
		collider.collision_layer = 0
		collider.collision_mask = 0
	if node is MeshInstance3D: (node as MeshInstance3D).visible = false
	for mesh: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		mesh.visible = false


## An imported GLB scene, or (in a source checkout before the editor imported it) the GLB read
## straight from disk. Not cached: the spa reads each model once.
static func load_scene(path: String) -> Node3D:
	if ResourceLoader.exists(path, "PackedScene"):
		var packed: PackedScene = load(path) as PackedScene
		if packed != null: return packed.instantiate() as Node3D
	if not FileAccess.file_exists(path): return null
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file(path, state) != OK: return null
	return document.generate_scene(state) as Node3D


func _ready() -> void:
	add_to_group("spa_venue")
	add_to_group("interaction_hint_sources")
	if _shell_scene == null: _shell_scene = load_scene(SHELL_PATH)
	if _leaf_scene == null: _leaf_scene = load_scene(LEAF_PATH)
	if _interior_scene == null: _interior_scene = load_scene(INTERIOR_PATH)
	if _shell_scene == null or _leaf_scene == null:
		push_warning("Spa venue: shell or door model missing")
		return
	var started := Time.get_ticks_usec()
	shell = _shell_scene; shell.name = "SpaShell"; add_child(shell)
	_build_shell_collision()
	_build_ramp()
	_build_door()
	if _interior_scene != null:
		interior = Node3D.new(); interior.name = "Interior"; add_child(interior)
		_interior_scene.name = "SpaInterior"; interior.add_child(_interior_scene)
		_collect_markers()
		_place_navigation_anchor.call_deferred()
		_build_furniture_collision()
		_build_benches()
		_build_lights()
	report["build_ms"] = (Time.get_ticks_usec() - started) / 1000.0
	report["markers"] = _markers.size()
	_update_environment()


## Two-sided trimesh of the shell below the old collision top, split in two bodies: the walls,
## floor, landing and steps (walkable) and the ceiling/roof (navigation_ceiling).
func _build_shell_collision() -> void:
	var walk := PackedVector3Array()
	var over := PackedVector3Array()
	var dropped := 0
	for mesh: MeshInstance3D in shell.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null: continue
		var to_venue: Transform3D = global_transform.affine_inverse() * mesh.global_transform
		for surface in mesh.mesh.get_surface_count():
			var material: Material = mesh.mesh.surface_get_material(surface)
			# The window panes (2026-10-29 real windows) block but are never floor.
			var glass: bool = material != null and material.resource_name.contains("window_glass")
			var arrays: Array = mesh.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var count: int = indices.size() if not indices.is_empty() else vertices.size()
			for i: int in range(0, count - 2, 3):
				var a: Vector3 = to_venue * vertices[indices[i] if not indices.is_empty() else i]
				var b: Vector3 = to_venue * vertices[indices[i + 1] if not indices.is_empty() else i + 1]
				var c: Vector3 = to_venue * vertices[indices[i + 2] if not indices.is_empty() else i + 2]
				if minf(a.y, minf(b.y, c.y)) > COLLISION_TOP: dropped += 1; continue
				var centre_y := (a.y + b.y + c.y) / 3.0
				# Window sills: flat shell faces between knee height in the shop and the split. Ponies
				# stopped at the foot of the steps once the windows were cut (walk-in test); nothing
				# stands on a sill.
				var flat := absf((b - a).cross(c - a).normalized().y) > 0.7
				var sill := flat and centre_y > FLOOR_Y + 0.3 and centre_y <= CEILING_SPLIT
				if centre_y > CEILING_SPLIT or glass or sill: over.append_array([a, b, c])
				else: walk.append_array([a, b, c])
	_trimesh_body("SpaShellCollision", walk, false)
	_trimesh_body("SpaCeilingCollision", over, true)
	report["collision_walk_tris"] = walk.size() / 3
	report["collision_ceiling_tris"] = over.size() / 3
	report["collision_dropped_tris"] = dropped


func _trimesh_body(label: String, faces: PackedVector3Array, ceiling: bool) -> void:
	if faces.is_empty(): return
	var body := StaticBody3D.new(); body.name = label; body.collision_mask = 0
	if ceiling: body.set_meta("navigation_ceiling", true)
	var shape := ConcavePolygonShape3D.new(); shape.set_faces(faces); shape.backface_collision = true
	var holder := CollisionShape3D.new(); holder.name = "Shell"; holder.shape = shape; body.add_child(holder)
	# Jolt keeps the scale a body enters with: the transform is set before it joins the tree.
	body.transform = Transform3D.IDENTITY
	add_child(body)


## Invisible smooth wedge over the visible steps (no 17.6 cm risers for a pony capsule).
func _build_ramp() -> void:
	var points := PackedVector3Array()
	for x: float in [RAMP_X.x, RAMP_X.y]:
		points.append(Vector3(x, RAMP_TOP.y, RAMP_TOP.x))
		points.append(Vector3(x, RAMP_FOOT.y, RAMP_FOOT.x))
		points.append(Vector3(x, RAMP_BASE_Y, RAMP_TOP.x))
		points.append(Vector3(x, RAMP_BASE_Y, RAMP_FOOT.x))
	var body := StaticBody3D.new(); body.name = "StepRamp"; body.collision_mask = 0
	var shape := ConvexPolygonShape3D.new(); shape.points = points
	var holder := CollisionShape3D.new(); holder.name = "Ramp"; holder.shape = shape; body.add_child(holder)
	body.transform = Transform3D.IDENTITY
	add_child(body)
	report["ramp_degrees"] = rad_to_deg(atan2(RAMP_TOP.y - RAMP_FOOT.y, RAMP_FOOT.x - RAMP_TOP.x))


## The original door leaf on a hinge at the right jamb (seen from the street), swinging out over
## the landing like Zecora's. Latched outside opening hours; egress always allowed.
func _build_door() -> void:
	door = DOOR.new(); door.name = "FrontDoor"; door.entrance = self
	door.position = HINGE
	door.handle = Vector3(-LEAF_SIZE.x + 0.24, 1.05, 0)
	# Closed-leaf frame, covering the outward swing like the Hayburger's leaves.
	door.navigation_box = AABB(Vector3(-LEAF_SIZE.x - 0.1, -0.1, -0.1), Vector3(LEAF_SIZE.x + 0.2, LEAF_SIZE.y + 0.2, LEAF_SIZE.x + 0.2))
	var leaf: MeshInstance3D = null
	for found: MeshInstance3D in _leaf_scene.find_children("*", "MeshInstance3D", true, false):
		leaf = found; break
	if leaf != null:
		# The GLB node sits at the hinge; the leaf mesh extends along -X from it.
		var placed: Transform3D = _relative(leaf, _leaf_scene)
		leaf.get_parent().remove_child(leaf)
		leaf.owner = null
		leaf.name = "OriginalDoorArtwork"
		leaf.transform = Transform3D(Basis.IDENTITY, -HINGE) * placed
		door.add_child(leaf)
	_leaf_scene.free(); _leaf_scene = null
	var holder := CollisionShape3D.new(); holder.name = "LeafCollision"
	var box := BoxShape3D.new(); box.size = LEAF_SIZE
	holder.shape = box; holder.position = Vector3(-LEAF_SIZE.x * 0.5, LEAF_SIZE.y * 0.5, 0)
	door.add_child(holder)
	add_child(door)


static func _relative(node: Node3D, top: Node) -> Transform3D:
	var xf: Transform3D = node.transform
	var parent: Node = node.get_parent()
	while parent != null and parent != top:
		if parent is Node3D: xf = (parent as Node3D).transform * xf
		parent = parent.get_parent()
	if top is Node3D: xf = (top as Node3D).transform * xf
	return xf


func _collect_markers() -> void:
	var inverse: Transform3D = global_transform.affine_inverse()
	for node: Node in _interior_scene.find_children("SPA_*", "Node3D", true, false):
		var local: Transform3D = inverse * (node as Node3D).global_transform
		_markers[str(node.name)] = Transform3D(local.basis.orthonormalized(), local.origin)


## Named-place routes ("landmark:spa_01" in the day tables) go to the foot of the steps, not to
## spa_01's origin, which is now inside the open entry strip on the way to every station.
## place_directory.gd reads a NavigationAnchor child of the ai_observable node (spa_01 itself).
func _place_navigation_anchor() -> void:
	var host: Node3D = get_parent() as Node3D
	if host == null or not _markers.has("SPA_DOOR_OUT") or host.get_node_or_null("NavigationAnchor") != null: return
	var anchor := Node3D.new(); anchor.name = "NavigationAnchor"
	anchor.transform = transform * (_markers["SPA_DOOR_OUT"] as Transform3D)
	host.add_child(anchor)


## Simple boxes from MARKERS.md; tiles, deck, trays, rugs and cushion stay visual so the walking
## floor is the shell's flat 0.36. All on layer 1, the floor ponies stand on (the massage table too).
func _build_furniture_collision() -> void:
	var body := StaticBody3D.new(); body.name = "FurnitureCollision"; body.collision_mask = 0
	var boxes: Array = [
		# The massage table (spa_interior.glb, build_interior.py TABLE): 1.20 along her (x) by 0.80
		# across, pad top 0.62 over the floor (y 0.98), where she lies for the back-hoof rub.
		["MassageTable", Vector3(-6.825, 0.67, -0.40), Vector3(1.55, 0.62, 0.80), 0.0],
		["CounterLeft", Vector3(2.47, 0.86, -0.52), Vector3(0.97, 1.0, 0.70), -23.2],
		["CounterMiddle", Vector3(3.30, 0.86, -0.35), Vector3(0.97, 1.0, 0.70), 0.0],
		["CounterRight", Vector3(4.13, 0.86, -0.52), Vector3(0.97, 1.0, 0.70), 23.2],
		["PartitionA", Vector3(-1.20, 1.46, -2.10), Vector3(0.12, 2.20, 4.00), 0.0],
		["PartitionAPost", Vector3(-1.20, 1.46, -0.10), Vector3(0.24, 2.20, 0.24), 0.0],
		["PartitionB", Vector3(4.745, 1.135, -1.65), Vector3(5.49, 1.55, 0.12), 0.0],
		["PartitionBPost", Vector3(2.00, 1.135, -1.65), Vector3(0.24, 1.55, 0.24), 0.0],
	]
	for spec: Array in boxes:
		var holder := CollisionShape3D.new(); holder.name = spec[0]
		var box := BoxShape3D.new(); box.size = spec[2]; holder.shape = box
		holder.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(float(spec[3]))), spec[1])
		body.add_child(holder)
	body.transform = Transform3D.IDENTITY
	add_child(body)


## The benches: the prop under the interior (hidden with it), a solid box on layer 1 that she sits
## on, and two seat.gd seats each. Seats are for the player too; spa_customers.gd seats its own
## waiting clients (for_ponies off: the living world does not send its ponies in to sit here).
var _bench_seats := {}

func _build_benches() -> void:
	var scene: PackedScene = load(BENCH_PATH) if ResourceLoader.exists(BENCH_PATH) else null
	var body := StaticBody3D.new(); body.name = "BenchCollision"; body.collision_mask = 0
	for spec: Array in BENCHES:
		var place := Transform3D(Basis(Vector3.UP, deg_to_rad(float(spec[2]))), spec[1])
		if scene != null:
			var prop: Node3D = scene.instantiate()
			prop.name = "Bench_" + str(spec[0])
			prop.transform = Transform3D(place.basis.scaled(BENCH_SCALE), place.origin)
			interior.add_child(prop)
		var holder := CollisionShape3D.new(); holder.name = "Bench_" + str(spec[0])
		var box := BoxShape3D.new(); box.size = BENCH_SIZE; holder.shape = box
		holder.transform = Transform3D(place.basis, place.origin + Vector3.UP * BENCH_SIZE.y * .5)
		body.add_child(holder)
		var seats: Array[Node3D] = []
		for along: float in [-SEAT_OFFSET, SEAT_OFFSET]:
			var seat: Node3D = SEAT.new()
			seat.name = "Seat_%s_%d" % [spec[0], seats.size() + 1]
			seat.set("depth", BENCH_SIZE.z)
			seat.set("for_ponies", false)
			seat.transform = Transform3D(place.basis, place.origin + place.basis.x * along + Vector3.UP * BENCH_SIZE.y)
			interior.add_child(seat)
			seats.append(seat)
		_bench_seats[str(spec[0])] = seats
	add_child(body)


## The seat.gd seats of bench "hoof" or "lobby" (empty before the interior is built).
func bench_seats(bench: String) -> Array:
	return _bench_seats.get(bench, [])


## The shell is closed, so the room needs its own light: one warm lamp per tower, one in the entry.
## No shadows; hidden with the interior at distance and outside opening hours.
func _build_lights() -> void:
	for spec: Array in [["LeftTowerLight", Vector3(-3.79, 3.9, -1.21), 1.3, 7.0],
			["RightTowerLight", Vector3(3.67, 3.9, -1.26), 1.3, 7.0], ["EntryLight", Vector3(-0.14, 3.5, 0.9), 0.6, 4.5]]:
		var light := OmniLight3D.new(); light.name = spec[0]; light.position = spec[1]
		light.light_color = Color("ffe4c8"); light.light_energy = spec[2]; light.omni_range = spec[3]
		light.shadow_enabled = false
		interior.add_child(light); _lights.append(light)


## Venue-local marker transforms by name (spa_customers.gd setup() reads this).
func spa_markers() -> Dictionary:
	return _markers.duplicate()


## Marker name -> global Transform3D.
func global_markers() -> Dictionary:
	var out: Dictionary = {}
	for key: String in _markers: out[key] = global_transform * (_markers[key] as Transform3D)
	return out


func marker(marker_name: String) -> Transform3D:
	if not _markers.has(marker_name): return Transform3D(Basis(), Vector3.INF)
	return global_transform * (_markers[marker_name] as Transform3D)


## Inside the shop, behind the door plane (the door latch, hinged_door queue_passage and checks).
func is_inside(point: Vector3) -> bool:
	var local: Vector3 = to_local(point)
	return local.z < DOOR_PLANE_Z - 0.02 and ROOM.has_point(local)

func contains(point: Vector3) -> bool:
	return is_inside(point)


func is_open_at(hours: float) -> bool:
	return hours >= OPEN_HOUR and hours < CLOSE_HOUR


## Optional wiring for the spa services (wave 2: one game.gd line). Creates the customer controller
## and the player's hands if their scripts load, and refreshes the walk grid now.
func setup(host: Node) -> void:
	game = host
	for service: Node in get_tree().get_nodes_in_group("pony_navigation"): refresh_navigation(service)
	if _markers.is_empty(): return
	var customers_script: Script = load(CUSTOMERS_PATH) as Script
	if customers == null and customers_script != null and customers_script.can_instantiate():
		customers = customers_script.new(); customers.name = "SpaCustomers"; add_child(customers)
		customers.setup(host, self)
	var hands_script: Script = load(HANDS_PATH) as Script
	if hands == null and customers != null and hands_script != null and hands_script.can_instantiate():
		hands = hands_script.new(); hands.name = "SpaHands"; add_child(hands)
		hands.setup(customers, host)
	if guide == null and hands != null:
		guide = GUIDE.new(); add_child(guide)
		guide.setup(customers, hands, host)


## Cached walk-grid chunks may still hold the old filled building and wedge; once per service.
func refresh_navigation(service: Node) -> void:
	if not is_instance_valid(service) or not service.has_method("notify_geometry_changed"): return
	if service.get_meta("spa_geometry_applied", false): return
	service.notify_geometry_changed(global_transform * NAV_BOX)
	service.set_meta("spa_geometry_applied", true)


func set_open(value: bool) -> void:
	business_open = value
	if door == null: return
	door.locked = not value
	door._close_after_passage = not value
	door._close_delay = 2.0 if not value else 0.0
	if not value: door._visitors.clear()
	if not is_instance_valid(door.holder): door.target = door.open_limit() if value else 0.0


## Outside opening hours the locked door says so (players arriving at night or on a new game at
## 08:50 found a shut building with no sign and thought the spa was missing, 2026-10-31).
func interaction_hint() -> Dictionary:
	if business_open or door == null: return {}
	var camera: Camera3D = preload("res://world/player_view.gd").camera(self)
	if camera == null or is_inside(camera.global_position): return {}
	var at: Vector3 = to_local(camera.global_position)
	if absf(at.x - DOOR_X) > 2.5 or at.z < DOOR_PLANE_Z - 0.2 or at.z > DOOR_PLANE_Z + 3.5 or absf(at.y - FLOOR_Y) > 3.0: return {}
	return {"target": door, "point": to_global(Vector3(DOOR_X, FLOOR_Y + 1.5, DOOR_PLANE_Z + 0.1)), "outline": null,
		"text": "Spa closed · open %02d:00-%02d:00" % [int(OPEN_HOUR), int(CLOSE_HOUR)]}


## Opens the door for a pony near it (inwards only during hours; outwards always).
func offer_passage(actor: Node3D) -> void:
	if door == null or not is_instance_valid(actor): return
	var at: Vector3 = to_local(actor.global_position)
	if absf(at.x - DOOR_X) > 2.5 or absf(at.z - DOOR_PLANE_Z) > 3.0 or at.y < FLOOR_Y - 3.0 or at.y > FLOOR_Y + 3.0: return
	if not business_open and is_inside(actor.global_position) and not is_instance_valid(door.holder):
		door.target = door.open_limit(); door._close_delay = 1.0
	door.request_passage(actor)


func _process(delta: float) -> void:
	_environment_timer -= delta
	if _environment_timer > 0.0: return
	_environment_timer = 0.25
	_update_environment()


## Opening hours, lights, the distance hide, walk grid refresh and door passage offers.
func _update_environment() -> void:
	if door == null: return
	var clock: Node = get_node_or_null("/root/TimeOfDay")
	var hours: float = float(clock.get("hours")) if clock != null else 12.0
	var open_now := is_open_at(hours)
	if open_now != business_open or not report.has("hours_applied"):
		report["hours_applied"] = true
		set_open(open_now)
	for service: Node in get_tree().get_nodes_in_group("pony_navigation"): refresh_navigation(service)
	if interior != null:
		var camera: Camera3D = preload("res://world/player_view.gd").camera(self)
		if is_instance_valid(game) and is_instance_valid(game.get("inventory")):
			var eye: Camera3D = game.inventory.get("camera") as Camera3D
			if eye != null: camera = eye
		if camera != null:
			var at: Vector3 = to_local(camera.global_position)
			var distance: float = at.distance_to(at.clamp(ROOM.position, ROOM.end))
			# Five metres of hysteresis prevents flicker at the cutoff.
			var wanted: bool = distance < (HIDE_BEYOND if interior.visible else SHOW_WITHIN)
			if interior.visible != wanted: interior.visible = wanted
		for light: Light3D in _lights:
			if light.visible != business_open: light.visible = business_open
	# Before setup() (wave 2 wires it from game.gd) the world root still lists its ponies, so one
	# who wandered in during the day is let out after closing, as at the Hayburger.
	var host: Node = game if is_instance_valid(game) else get_tree().current_scene
	if is_instance_valid(host) and host.get("mares") is Array:
		for actor: Variant in host.get("mares"):
			if actor is Node3D: offer_passage(actor as Node3D)
