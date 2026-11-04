extends Node
## What a pony owns (docs/MECHANICS_ARCHITECTURE_2026_11_01.md 4.4): gifts from Anon that she keeps
## (not food she ate, not wear: the wardrobe owns that), and later things she buys or makes. Saved in
## world_context.state.pony_belongings = {pony_id: [{"id", "from", "value", "day", "n", "home",
## "pose"?}]}, at most MAX_PER_PONY each (the oldest goes). Dev 2026-11-01: a gifted home good or
## painting appears placed in her house where she can take it; when no spot is found it stays a
## belonging only (a fact, no visual). Her belongings are also what she can hand back with [give].
## The visuals are frozen display bodies under her house, never in Anon's inventory.loose, so grab
## targets and the briefcase ignore them. One 1.5 s timer; at most MAX_PLACE visuals per tick.
const ITEM_CATALOG := preload("res://world/inventory/item_catalog.gd")
const FOOD := preload("res://world/food/food_catalog.gd")
const FOOD_INTERACTION := preload("res://world/food/food_interaction.gd")
const SHOP := preload("res://world/shop/shop_items.gd")
const RULES := preload("res://world/housing/furnishing_rules.gd")
const HOME_FURNISHING := preload("res://world/housing/home_furnishing.gd")
const BOOK := preload("res://world/books/book_item.gd")
const FACTS := preload("res://world/mechanics/facts.gd")
const STORE := preload("res://world/inventory/inventory_store.gd")
const STATE_KEY := "pony_belongings"
const MAX_PER_PONY := 24
const SHOW_EVERY := 1.5     # s, Timer
const SHOW_RANGE := 80.0    # camera to house
const MAX_PLACE := 2        # visuals built per tick
const ITEM_LAYER := 1 << 17
const GROUP := "pony_belongings"
const ID_CHARS := 96

var context: Node
var _timer: Timer
var _nodes: Dictionary = {}   # "owner:n" -> display body

func bind(world_context: Node) -> void:
	context = world_context

func _ready() -> void:
	_timer = Timer.new(); _timer.wait_time = SHOW_EVERY; _timer.autostart = true
	_timer.timeout.connect(_show)
	add_child(_timer)

func _writable() -> bool:
	return is_instance_valid(context) and not bool(context.get("_read_only")) and context.get("state") is Dictionary

## Every saved row of one pony that is still a real item, read with type guards (writes nothing).
func items(pony_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not is_instance_valid(context) or not context.get("state") is Dictionary: return result
	var block: Variant = (context.state as Dictionary).get(STATE_KEY)
	if not block is Dictionary: return result
	var rows: Variant = (block as Dictionary).get(pony_id)
	if not rows is Array: return result
	for row: Variant in rows:
		if row is Dictionary and (row as Dictionary).get("id") is String and ITEM_CATALOG.has(str(row.id)): result.append(row)
	return result

## Pony ids that own anything.
func owners() -> Array[String]:
	var result: Array[String] = []
	if not is_instance_valid(context) or not context.get("state") is Dictionary: return result
	var block: Variant = (context.state as Dictionary).get(STATE_KEY)
	if not block is Dictionary: return result
	for id: Variant in block:
		if id is String and (block as Dictionary)[id] is Array and not ((block as Dictionary)[id] as Array).is_empty(): result.append(str(id))
	return result

## The saved list of one pony, created (or replaced when malformed) for a write.
func _rows(pony_id: String) -> Array:
	var block: Variant = context.state.get(STATE_KEY)
	if not block is Dictionary:
		block = {}
		context.state[STATE_KEY] = block
	var rows: Variant = (block as Dictionary).get(pony_id)
	if not rows is Array:
		rows = []
		(block as Dictionary)[pony_id] = rows
	return rows

## She now owns one `item_id`, given by `from` ("player", a pony id or "self").
func add(pony_id: String, item_id: String, from: String) -> void:
	item_id = ITEM_CATALOG.canonical(item_id)
	if pony_id.is_empty() or not ITEM_CATALOG.has(item_id) or not _writable(): return
	var rows := _rows(pony_id)
	var serial := 0
	for row: Variant in rows:
		if row is Dictionary: serial = maxi(serial, int(FACTS._number((row as Dictionary).get("n"), 0)))
	rows.append({"id": item_id.left(ID_CHARS), "from": from.left(ID_CHARS), "value": ITEM_CATALOG.value(item_id),
		"day": int(FACTS.clock().day), "n": serial + 1, "home": ""})
	while rows.size() > MAX_PER_PONY:
		var dropped: Variant = rows.pop_front()
		if dropped is Dictionary: _free_node(pony_id, dropped)
	context._changed()

## Removes the first entry of `item_id` (frees its display); the removed entry, or {}.
func take_entry(pony_id: String, item_id: String) -> Dictionary:
	item_id = ITEM_CATALOG.canonical(item_id)
	if not _writable(): return {}
	var block: Variant = context.state.get(STATE_KEY)
	if not block is Dictionary or not (block as Dictionary).get(pony_id) is Array: return {}
	var rows: Array = (block as Dictionary)[pony_id]
	for index: int in rows.size():
		var row: Variant = rows[index]
		if not row is Dictionary or ITEM_CATALOG.canonical(str((row as Dictionary).get("id", ""))) != item_id: continue
		rows.remove_at(index)
		_free_node(pony_id, row)
		context._changed()
		return row
	return {}

func take(pony_id: String, item_id: String) -> bool:
	return not take_entry(pony_id, item_id).is_empty()

## Puts a taken entry back (a hand-over that failed); it keeps its serial and pose.
func restore(pony_id: String, entry: Dictionary) -> void:
	if entry.is_empty() or not _writable(): return
	var rows := _rows(pony_id)
	rows.append(entry)
	while rows.size() > MAX_PER_PONY: rows.pop_front()
	context._changed()

func _key(owner: String, row: Dictionary) -> String:
	return "%s:%d" % [owner, int(FACTS._number(row.get("n"), 0))]

func _free_node(owner: String, row: Dictionary) -> void:
	var key := _key(owner, row)
	var node: Variant = _nodes.get(key)
	_nodes.erase(key)
	if is_instance_valid(node): (node as Node).queue_free()

# --- display in her home -----------------------------------------------------------------------

func _population() -> Node:
	return get_tree().get_first_node_in_group("pony_populations") if is_inside_tree() else null

## Timer: belongings of ponies whose home is loaded and near the camera get their visuals. A new
## belonging is measured as its real body first (its model sets the box), then placed once; the
## pose is saved relative to her house, so it stays put across loads.
func _show() -> void:
	if not is_instance_valid(context) or not is_inside_tree(): return
	var population := _population()
	var camera := get_viewport().get_camera_3d() if get_viewport() != null else null
	if population == null or not population.has_method("home_house") or camera == null: return
	var built := 0
	var today := int(FACTS.clock().day)
	for owner: String in owners():
		var house: Node3D = population.home_house(owner)
		if not is_instance_valid(house) or not house.is_inside_tree() or not bool(house.get("furnish_done")) or not house.has_method("contains"): continue
		if house.global_position.distance_to(camera.global_position) > SHOW_RANGE: continue
		var home_id := str(house.call("place_id")) if house.has_method("place_id") else ""
		for row: Dictionary in items(owner):
			if built >= MAX_PLACE: return
			var key := _key(owner, row)
			if is_instance_valid(_nodes.get(key)): continue
			var saved: bool = str(row.get("home", "")) == home_id and row.get("pose") is Array and STORE.valid_pose(row.pose)
			if not saved and (str(row.get("home", "")) == home_id and int(FACTS._number(row.get("no_spot"), -1)) == today): continue
			if not saved and not _writable(): continue
			built += 1
			# Houses are scaled: poses use the house's unscaled frame, so the body enters Jolt at
			# scale 1 and the saved relative pose stays orthonormal (STORE.valid_pose).
			var frame := Transform3D(house.global_basis.orthonormalized(), house.global_position)
			var body := _display(str(row.id), frame * STORE.decode_pose(row.pose) if saved else Transform3D(Basis.IDENTITY, house.global_position + Vector3.DOWN * 50.0))
			if body == null: continue
			body.set_meta("belonging_key", key); body.set_meta("belonging_owner", owner)
			house.add_child(body)
			_measure(body)
			if not saved:
				var found: Variant = pose_in(house, str(row.id), house.get_world_3d().direct_space_state, body_box(body), [body.get_rid()])
				row.home = home_id
				if found is Transform3D:
					body.global_transform = found
					row.pose = STORE.encode_pose(frame.affine_inverse() * (found as Transform3D))
					row.erase("no_spot")
				else:
					row.erase("pose"); row.no_spot = today   # kept as a belonging only; tried again tomorrow
					body.queue_free()
				context._changed()
				if not found is Transform3D: continue
			_nodes[key] = body

## A frozen display body: the item's own scene and collision, like briefcase_drops._make_item.
## top_level keeps it unscaled whatever the house's scale (Jolt keeps a body's entry scale).
static func _display(id: String, pose: Transform3D) -> RigidBody3D:
	var scene: PackedScene = ITEM_CATALOG.scene(id)
	if scene == null: return null
	var visual: Node3D = scene.instantiate() as Node3D
	if visual == null: return null
	var body := RigidBody3D.new(); body.name = "Belonging"
	body.set_meta("item_id", id)
	body.freeze = true; body.collision_mask = 0
	body.collision_layer = ITEM_LAYER | (1 if RULES.has(id) and not RULES.wall(id) else 0)
	var shape := CollisionShape3D.new(); shape.name = "Shape"
	var box := BoxShape3D.new(); var bounds := box_for(id)
	box.size = bounds.size; shape.shape = box; shape.position = bounds.get_center()
	body.add_child(shape); body.add_child(visual)
	if FOOD.has(id): FOOD_INTERACTION.configure(body, visual, shape)
	elif visual.has_method("configure_body"): visual.configure_body(body, shape)
	body.top_level = true
	body.transform = pose
	body.add_to_group(GROUP)
	return body

## Shop goods measure their model when it enters the tree (shop_item_visual.gd bounds).
static func _measure(body: RigidBody3D) -> void:
	var shape := body.get_node_or_null("Shape") as CollisionShape3D
	if shape == null or not shape.shape is BoxShape3D: return
	for visual: Node in body.get_children():
		if visual is CollisionShape3D or not "bounds" in visual or not SHOP.has(str(body.get_meta("item_id", ""))): continue
		var bounds: AABB = visual.bounds
		if bounds.size.length() <= 0.0: continue
		(shape.shape as BoxShape3D).size = bounds.size.max(Vector3.ONE * .02); shape.position = bounds.get_center()

## The body's collision box in its own space.
static func body_box(body: RigidBody3D) -> AABB:
	var shape := body.get_node_or_null("Shape") as CollisionShape3D
	if shape == null or not shape.shape is BoxShape3D: return AABB()
	var size: Vector3 = (shape.shape as BoxShape3D).size
	return AABB(shape.position - size * .5, size)

## The item's box with its bottom at y = 0 (an estimate before the model is measured).
static func box_for(id: String) -> AABB:
	if ITEM_CATALOG.is_book(id): return AABB(Vector3(-BOOK.SIZE.x * .5, 0, -BOOK.SIZE.z * .5), BOOK.SIZE)
	if SHOP.has(id):
		var edge := float(SHOP.definition(id).get("size_m", .3))
		return AABB(Vector3(-edge * .5, 0, -edge * .5), Vector3(edge, edge * .5, edge))
	if ITEM_CATALOG.is_art(id): return AABB(Vector3(-.2, -.25, 0), Vector3(.4, .5, .03))
	return AABB(Vector3(-.075, 0, -.075), Vector3(.15, .12, .15))

static func _small(id: String) -> bool:
	for tag: String in ["book", "sweet", "photo", "food", "stationery", "tea"]:
		if ITEM_CATALOG.has_tag(id, tag) and not RULES.wall(id): return true
	return not RULES.has(id) and not ITEM_CATALOG.has_tag(id, "home_good")

## Where `item_id` can stand in `house` (world pose), or null: wall goods on a wall at 1.4 m,
## small goods on a table top, then everything on clear floor that fits the home.
## `box` is the item's measured box (bottom-relative, as body_box gives it), else box_for(item_id).
static func pose_in(house: Node3D, item_id: String, space: PhysicsDirectSpaceState3D, measured := AABB(), exclude: Array[RID] = []) -> Variant:
	if not is_instance_valid(house) or space == null or not house.has_method("contains") or not house.has_method("center"): return null
	var box := measured if measured.size.length() > 0.0 else box_for(item_id)
	var floor_at: Vector3 = house.center()
	if RULES.wall(item_id):
		var origin := floor_at + Vector3.UP * 1.4
		var best: Dictionary = {}
		var best_gap := INF
		for step: int in 8:
			var direction := Vector3.FORWARD.rotated(Vector3.UP, TAU * float(step) / 8.0)
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(origin, origin + direction * 6.0, 1, exclude))
			if hit.is_empty(): continue
			var normal: Vector3 = hit.normal
			if absf(normal.y) > .2: continue
			var point: Vector3 = hit.position
			if not house.contains(Vector3(point.x, floor_at.y, point.z) + Vector3(normal.x, 0, normal.z).normalized() * .1): continue
			var gap := origin.distance_to(point)
			if gap < best_gap: best = hit; best_gap = gap
		if best.is_empty(): return null
		var flat := Vector3(best.normal.x, 0, best.normal.z).normalized()
		var pose := Transform3D(Basis(Vector3.UP.cross(flat), Vector3.UP, flat), Vector3.ZERO)
		pose.origin = Vector3(best.position) + flat * (-box.position.z + .012) - Vector3.UP * box.get_center().y
		return pose
	if _small(item_id):
		var top: Variant = _table_top(house, box, space, exclude)
		if top is Transform3D: return top
	var candidates: Array[Vector3] = []
	if house.has_method("slots"):
		for point: Vector3 in house.slots(): candidates.append(point)
	candidates.append(floor_at)
	for offset: Vector3 in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		candidates.append(floor_at + house.global_basis.orthonormalized() * offset)
	for point: Vector3 in candidates:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(point + Vector3.UP * 1.2, point + Vector3.DOWN * .5, 1, exclude))
		if hit.is_empty() or Vector3(hit.normal).y <= .9 or not house.contains(hit.position): continue
		var pose := Transform3D(Basis(Vector3.UP, house.global_basis.orthonormalized().get_euler().y), Vector3(hit.position) + Vector3.UP * (-box.position.y + .008))
		if not HOME_FURNISHING.fits_home(house, pose, box): continue
		if _clear(space, pose, box, exclude): return pose
	return null

static func _clear(space: PhysicsDirectSpaceState3D, pose: Transform3D, box: AABB, exclude: Array[RID] = []) -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	var shape := BoxShape3D.new(); shape.size = box.size * .98
	query.shape = shape; query.transform = pose * Transform3D(Basis.IDENTITY, box.get_center())
	query.collision_mask = 1 | ITEM_LAYER; query.exclude = exclude
	return space.intersect_shape(query, 1).is_empty()

## A clear spot on a table, island or kitchen counter top inside the house (the arrival story's
## _table_top pattern, arrival_story.gd), trying the centre and four nearby spots.
static func _table_top(house: Node3D, box: AABB, space: PhysicsDirectSpaceState3D, exclude: Array[RID] = []) -> Variant:
	for node: Node in house.find_children("*", "Node3D", true, false):
		var name := str(node.name).to_lower()
		if not ("table" in name or "island" in name or "kitchen" in name): continue
		for collision: CollisionShape3D in node.find_children("*", "CollisionShape3D", true, false):
			if collision.disabled or not collision.shape is BoxShape3D: continue
			var body := collision.get_parent() as StaticBody3D
			if body == null or (body.collision_layer & 1) == 0: continue
			var size: Vector3 = (collision.shape as BoxShape3D).size
			var world: AABB = collision.global_transform * AABB(-size * .5, size)
			if world.size.y < .3 or world.size.y > 1.4: continue
			var top := Vector3(world.get_center().x, world.end.y, world.get_center().z)
			if not house.contains(Vector3(top.x, house.center().y, top.z)): continue
			var heading := Basis(Vector3.UP, atan2((node as Node3D).global_basis.z.x, (node as Node3D).global_basis.z.z))
			for offset: Vector3 in [Vector3.ZERO, Vector3(.18, 0, 0), Vector3(-.18, 0, 0), Vector3(0, 0, .18), Vector3(0, 0, -.18)]:
				var point := top + heading * offset
				var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(point + Vector3.UP * .12, point - Vector3.UP * .12, 1, exclude))
				if hit.is_empty() or hit.get("collider") != body or Vector3(hit.normal).y < .95: continue
				var pose := Transform3D(heading, Vector3(hit.position) + Vector3.UP * (-box.position.y + .006))
				if _clear(space, pose, box, exclude): return pose
	return null
