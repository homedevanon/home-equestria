extends RefCounted
## Per-chunk cache keys for the walk grid (perf overhaul 2026-11-21, lane walk_grid).
##
## The old cache folder was named by one hash over every input of the zone; for the town that
## included WorldTerrain.navigation_revision, the md5 of about sixty files (scripts among them), so
## any release or edit reset every player's whole grid. A chunk's key now covers only what its
## columns can read:
## - every static body on the walking or water layer whose bounds touch the chunk (grown by
##   MARGIN), described by its transform, layers, `navigation_ceiling` tag and every shape (owner
##   transform, disabled flag, class, a hash of the shape's data). Only static bodies count
##   (StaticBody3D, frozen-static RigidBody3D); characters, loose rigid bodies, kinematic bodies
##   (doors, trains) and areas stayed out of the old key as well. Terrain3D stands in by its texels.
## - the ray range (the service's bounds in y),
## - the Terrain3D height and control texels under the chunk (plus a border), or "absent".
##
## Version 2 (after the first A/B round, 2026-11-21): version 1 asked the physics space for every
## shape in the chunk's prism on each key; house chunks hold thousands of small interior shapes
## and a key cost 6 to 24 ms on the main thread. Bodies are now registered once (a scan of the
## tree when the service starts, then SceneTree node_added / node_removed), each body's signature
## is built once in budgeted slices, a chunk index maps chunks to bodies, and a chunk's key is a
## memoised digest of its bodies' signatures: tens of microseconds, recomputed only when a body
## touching the chunk is added, removed or re-registered, or its terrain is notified.
## A body moved in place without notify_geometry_changed() is not seen (the walk grid's contract
## for moved geometry, as before).
const KEY_VERSION := 2
## Metres around the chunk: the clearance volume (radius 0.18 m) and blocker growth (0.18 m).
const MARGIN := 0.5
## Terrain texels around the chunk (bilinear heights and normals read neighbours).
const TEXEL_BORDER := 2
## Result cap of the tools' own physics queries (bake_walk_grid.gd).
const MAX_RESULTS := 16384
## Shape owners read per slice of a large body (an interior lining holds 2000 and more).
const SLICE_OWNERS := 64

var mask := 1
## Area the index covers (the service's bounds); bodies wholly outside are not indexed.
var limits := AABB()
## instance id -> [signature, Rect2i of chunk coords]
var _bodies: Dictionary = {}
## chunk -> {instance id: true}
var _chunks: Dictionary = {}
## chunk -> key (memo)
var _keys: Dictionary = {}
## Bodies waiting to be (re)registered, in order, and the one being read in slices.
var _pending: Array[int] = []
var _pending_set: Dictionary = {}
var _work: Dictionary = {}
var _shape_infos: Dictionary = {}
## Chunks whose body set changed since take_changed() (the service re-checks resident ones).
var _changed: Dictionary = {}
var stats := {"keys": 0, "usec": 0, "registered": 0, "register_usec": 0, "scanned": 0}


## Static, blocking, on the walking or water layer.
func relevant(node: Node) -> bool:
	var body := node as CollisionObject3D
	if body == null or not (body.collision_layer & mask): return false
	if body is Area3D or body is CharacterBody3D or body is AnimatableBody3D: return false
	# Terrain3D's collision (an editor-mode child body) stands in by its texels.
	if body.get_parent() != null and body.get_parent().get_class() == "Terrain3D": return false
	if body is RigidBody3D:
		var rigid := body as RigidBody3D
		return rigid.freeze and rigid.freeze_mode == RigidBody3D.FREEZE_MODE_STATIC
	return body is StaticBody3D


## Every relevant body under `root` (once, when the service starts).
func scan(root: Node) -> void:
	for node: Node in root.find_children("*", "CollisionObject3D", true, false):
		stats.scanned += 1
		if relevant(node): queue_body(node)


func queue_body(node: Node) -> void:
	var id := node.get_instance_id()
	if _pending_set.has(id): return
	_pending_set[id] = true
	_pending.append(id)


## A body left the tree: its chunks change now.
func remove_body(node: Node) -> void:
	var id := node.get_instance_id()
	_pending_set.erase(id)
	if not _work.is_empty() and int(_work.id) == id: _work = {}
	_unindex(id)


## A shape owner came or went under a registered body: read the body again.
func touch_body(node: Node) -> void:
	if relevant(node) and node.is_inside_tree(): queue_body(node)


## Re-register every indexed body touching `box` (it may have moved: notify_geometry_changed),
## and drop the memoised keys there (terrain texels may have changed).
func notify(box: AABB, reread_bodies: bool) -> void:
	var size := WalkGrid.CHUNK_CELLS * WalkGrid.CELL
	var a := Vector2i(floori((box.position.x - MARGIN) / size), floori((box.position.z - MARGIN) / size))
	var b := Vector2i(floori((box.end.x + MARGIN) / size), floori((box.end.z + MARGIN) / size))
	for z in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			var c := Vector2i(x, z)
			_keys.erase(c)
			if reread_bodies and _chunks.has(c):
				for id: int in _chunks[c]:
					var node: Object = instance_from_id(id)
					if node != null and node is Node and (node as Node).is_inside_tree(): queue_body(node as Node)


func busy() -> bool:
	return not _pending.is_empty() or not _work.is_empty()


func take_changed() -> Dictionary:
	var out := _changed
	_changed = {}
	return out


## Registers waiting bodies until `deadline` (usec); a large body is read over several calls.
func advance(deadline: int) -> void:
	var started := Time.get_ticks_usec()
	while (not _work.is_empty() or not _pending.is_empty()) and Time.get_ticks_usec() < deadline:
		if _work.is_empty():
			var id: int = _pending.pop_front()
			_pending_set.erase(id)
			var node: Object = instance_from_id(id)
			if node == null or not node is CollisionObject3D or not (node as Node).is_inside_tree() or not relevant(node as Node):
				_unindex(id)
				continue
			var body := node as CollisionObject3D
			if _far(body.global_position):
				_unindex(id)
				continue
			var digest := HashingContext.new()
			digest.start(HashingContext.HASH_SHA256)
			var owners := body.get_shape_owners()
			digest.update(var_to_bytes([body.global_transform, body.collision_layer & mask,
				body.get_meta("navigation_ceiling", false), owners.size()]))
			_work = {"id": id, "body": body, "owners": owners, "i": 0, "digest": digest, "box": AABB(), "has_box": false}
		var work := _work
		var body: CollisionObject3D = work.body
		if not is_instance_valid(body) or not body.is_inside_tree():
			_unindex(int(work.id)); _work = {}
			continue
		var owners: PackedInt32Array = work.owners
		var digest: HashingContext = work.digest
		var end := mini(int(work.i) + SLICE_OWNERS, owners.size())
		var to_world := body.global_transform
		for i in range(int(work.i), end):
			var owner := owners[i]
			var local := body.shape_owner_get_transform(owner)
			var disabled := body.is_shape_owner_disabled(owner)
			for j in body.shape_owner_get_shape_count(owner):
				var shape := body.shape_owner_get_shape(owner, j)
				if shape == null: continue
				var info := _shape_info(shape)
				digest.update(var_to_bytes([local, disabled, info[0]]))
				if disabled: continue
				var world_box: AABB = to_world * local * (info[1] as AABB)
				work.box = world_box if not work.has_box else (work.box as AABB).merge(world_box)
				work.has_box = true
		work.i = end
		if end < owners.size(): continue
		_unindex(int(work.id))
		if work.has_box:
			_index(int(work.id), digest.finish().hex_encode(), work.box)
		_work = {}
		stats.registered += 1
	stats.register_usec += Time.get_ticks_usec() - started


## Origin more than FAR_MARGIN outside the indexed area (another zone's body): not read at all.
const FAR_MARGIN := 256.0
func _far(at: Vector3) -> bool:
	if limits.size == Vector3.ZERO: return false
	return at.x < limits.position.x - FAR_MARGIN or at.z < limits.position.z - FAR_MARGIN \
		or at.x > limits.end.x + FAR_MARGIN or at.z > limits.end.z + FAR_MARGIN


func _index(id: int, signature: String, box: AABB) -> void:
	box = box.grow(MARGIN)
	if limits.size != Vector3.ZERO:
		var flat := AABB(Vector3(limits.position.x, box.position.y, limits.position.z), Vector3(limits.size.x, box.size.y, limits.size.z))
		if not flat.intersects(box): return
		box = flat.intersection(box)
	var size := WalkGrid.CHUNK_CELLS * WalkGrid.CELL
	var a := Vector2i(floori(box.position.x / size), floori(box.position.z / size))
	var b := Vector2i(floori(box.end.x / size), floori(box.end.z / size))
	var rect := Rect2i(a, b - a + Vector2i.ONE)
	_bodies[id] = [signature, rect]
	for z in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			var c := Vector2i(x, z)
			if not _chunks.has(c): _chunks[c] = {}
			_chunks[c][id] = true
			_keys.erase(c)
			_changed[c] = true


func _unindex(id: int) -> void:
	if not _bodies.has(id): return
	var rect: Rect2i = _bodies[id][1]
	_bodies.erase(id)
	for z in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var c := Vector2i(x, z)
			if _chunks.has(c):
				(_chunks[c] as Dictionary).erase(id)
				if (_chunks[c] as Dictionary).is_empty(): _chunks.erase(c)
			_keys.erase(c)
			_changed[c] = true


## Key of chunk `coord`; "" while bodies still wait to be registered (the caller waits).
func chunk_key(coord: Vector2i, bounds: AABB, terrain: Object) -> String:
	var known: Variant = _keys.get(coord)
	if known != null: return known
	if busy(): return ""
	var started := Time.get_ticks_usec()
	var parts := PackedStringArray()
	for id: int in _chunks.get(coord, {}):
		parts.append(str(_bodies[id][0]))
	parts.sort()
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(var_to_bytes([KEY_VERSION, bounds.position.y, bounds.end.y]))
	for part in parts: digest.update(part.to_ascii_buffer())
	digest.update(_terrain_bytes(coord, terrain))
	var key := digest.finish().hex_encode()
	_keys[coord] = key
	stats.keys += 1
	stats.usec += Time.get_ticks_usec() - started
	return key


## [hash, bounds] of a shape resource (class and data), once per resource this session.
func _shape_info(shape: Shape3D) -> Array:
	var known: Variant = _shape_infos.get(shape.get_instance_id())
	if known != null: return known
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(shape.get_class().to_ascii_buffer())
	var box := AABB()
	if shape is BoxShape3D:
		var size := (shape as BoxShape3D).size
		digest.update(var_to_bytes(size))
		box = AABB(-size * .5, size)
	elif shape is SphereShape3D:
		var r := (shape as SphereShape3D).radius
		digest.update(var_to_bytes(r))
		box = AABB(-Vector3.ONE * r, Vector3.ONE * r * 2.0)
	elif shape is CapsuleShape3D:
		var r := (shape as CapsuleShape3D).radius
		var h := (shape as CapsuleShape3D).height
		digest.update(var_to_bytes([r, h]))
		box = AABB(Vector3(-r, -h * .5, -r), Vector3(r * 2.0, h, r * 2.0))
	elif shape is CylinderShape3D:
		var r := (shape as CylinderShape3D).radius
		var h := (shape as CylinderShape3D).height
		digest.update(var_to_bytes([r, h]))
		box = AABB(Vector3(-r, -h * .5, -r), Vector3(r * 2.0, h, r * 2.0))
	elif shape is ConvexPolygonShape3D:
		var points := (shape as ConvexPolygonShape3D).points
		digest.update(points.to_byte_array())
		box = _points_box(points, shape)
	elif shape is ConcavePolygonShape3D:
		var faces := (shape as ConcavePolygonShape3D).get_faces()
		digest.update(faces.to_byte_array())
		digest.update(var_to_bytes((shape as ConcavePolygonShape3D).backface_collision))
		box = _points_box(faces, shape)
	elif shape is HeightMapShape3D:
		var map := shape as HeightMapShape3D
		digest.update(var_to_bytes([map.map_width, map.map_depth]))
		digest.update(map.map_data.to_byte_array())
		var low := 0.0
		var high := 0.0
		if not map.map_data.is_empty():
			low = map.get_min_height(); high = map.get_max_height()
		box = AABB(Vector3(-map.map_width * .5, low, -map.map_depth * .5), Vector3(map.map_width, high - low, map.map_depth))
	else:
		# WorldBoundaryShape3D and anything unusual: data through the property list, bounds the
		# whole index area (clipped to `limits` when indexed).
		for property in shape.get_property_list():
			if property.usage & PROPERTY_USAGE_STORAGE:
				var value: Variant = shape.get(property.name)
				if not value is Object: digest.update(var_to_bytes([property.name, value]))
		box = AABB(Vector3.ONE * -1e6, Vector3.ONE * 2e6)
	var info := [digest.finish().hex_encode().substr(0, 32), box]
	_shape_infos[shape.get_instance_id()] = info
	return info


## Bounds of a point list; long ones through the engine's debug mesh (a GDScript loop over a
## large trimesh would cost milliseconds in one step).
static func _points_box(points: PackedVector3Array, shape: Shape3D) -> AABB:
	if points.is_empty(): return AABB()
	if points.size() > 256 and shape.get_debug_mesh() != null: return shape.get_debug_mesh().get_aabb()
	var low := points[0]
	var high := points[0]
	for p in points:
		low = low.min(p); high = high.max(p)
	return AABB(low, high - low)


## Memoised key of `coord`, or "" (none taken since the last change there).
func peek(coord: Vector2i) -> String:
	return str(_keys.get(coord, ""))


## Drops every memoised key (terrain controls changed; bodies stay registered).
func drop_memo() -> void:
	_keys.clear()


## Height and control texels of every Terrain3D region the chunk (plus border) reads.
func _terrain_bytes(coord: Vector2i, terrain: Object) -> PackedByteArray:
	var out := PackedByteArray()
	if terrain == null or not is_instance_valid(terrain): return "no-terrain".to_ascii_buffer()
	var t3d: Object = terrain.get("terrain")
	var data: Object = t3d.get("data") if t3d != null else null
	if data == null: return "no-terrain-data".to_ascii_buffer()
	var spacing := float(t3d.get("vertex_spacing"))
	var region_m := float(WorldTerrain.REGION)
	var size := WalkGrid.CHUNK_CELLS * WalkGrid.CELL
	var border := spacing * TEXEL_BORDER
	var x0 := coord.x * size - border
	var z0 := coord.y * size - border
	var x1 := coord.x * size + size + border
	var z1 := coord.y * size + size + border
	for rz in range(floori(z0 / region_m), floori(z1 / region_m) + 1):
		for rx in range(floori(x0 / region_m), floori(x1 / region_m) + 1):
			var loc := Vector2i(rx, rz)
			out.append_array(var_to_bytes([loc, spacing]))
			var region: Object = data.get_region(loc)
			if region == null:
				out.append_array("absent".to_ascii_buffer())
				continue
			var heights: Image = region.get_height_map()
			var controls: Image = region.get_control_map()
			if heights == null:
				out.append_array("no-heights".to_ascii_buffer())
				continue
			var origin := Vector2(rx * region_m, rz * region_m)
			var a := Vector2i(floori((maxf(x0, origin.x) - origin.x) / spacing), floori((maxf(z0, origin.y) - origin.y) / spacing))
			var b := Vector2i(ceili((minf(x1, origin.x + region_m) - origin.x) / spacing), ceili((minf(z1, origin.y + region_m) - origin.y) / spacing))
			var rect := Rect2i(a, b - a + Vector2i.ONE).intersection(Rect2i(Vector2i.ZERO, heights.get_size()))
			out.append_array(var_to_bytes(rect))
			out.append_array(heights.get_region(rect).get_data())
			if controls != null: out.append_array(controls.get_region(rect.intersection(Rect2i(Vector2i.ZERO, controls.get_size()))).get_data())
	return out
