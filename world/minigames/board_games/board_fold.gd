extends RefCounted
## The folding game board ("goods:game-board", dev 2026-10-26: "portable versions of the board
## that fit in the inventory and be able to ask pony to play outside"), in the pattern of the
## folding easel (world/painting/easel_fold.gd): held, a click or the trigger unfolds it on flat,
## dry ground in front of Anon, and the inventory saves it as one loose "board_open" unit before
## the hand lets go. Open, it is a board_table.gd like the library's, with a place to sit on
## either side: E on the board plays, E or a grip on its box beside the board packs it up again
## (briefcase_inventory.gd _take_pick), unless a game is still going.
const TABLE := preload("res://world/minigames/board_games/board_table.gd")
const MODELS := preload("res://world/minigames/board_games/board_models.gd")
const SEAT := preload("res://world/life/seat.gd")
const WATER := preload("res://world/water/water_contact.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
const ITEM_ID := "goods:game-board"
## Where each player sits, from the board's middle: a sitting pony's half-width (0.45 m, the gait
## profile's radius) clear of the board's edge.
const SEAT_REACH := 0.78
## Folded: a closed case, the board's two halves on top of each other (metres).
const FOLDED := Vector3(0.26, 0.055, 0.5)
## The box beside the open board that packs it up: its middle and size, board space.
const BOX_AT := Vector3(0.323, 0.025, -0.24)
const BOX_SIZE := Vector3(0.15, 0.05, 0.17)
## Ground sampled under the board's corners, both seats and the box; all within this of each other.
const GROUND := [Vector3(-0.26, 0, -0.26), Vector3(0.26, 0, -0.26), Vector3(-0.26, 0, 0.26), Vector3(0.26, 0, 0.26),
	Vector3(0, 0, 0), Vector3(0, 0, SEAT_REACH), Vector3(0, 0, -SEAT_REACH), Vector3(0.323, 0, -0.24)]
const LEVEL := 0.12
## No grass over the open board, its box and both seats (dev 2026-10-29: the blades hid the
## pieces): local half-size of the cleared patch, like the picnic blanket's (ground_grass.gd).
const GRASS_CLEAR := Vector2(0.45, 1.1)
const GROUP := "open_game_boards"
const ERROR := "Find a flat, dry, clear patch of ground for the game board."
const PLACE := "at the folding game board he has set out on the ground here"

static func unfold(inventory: Node, side: String) -> bool:
	var item: RigidBody3D = inventory.held.get(side) as RigidBody3D
	if not is_instance_valid(item) or str(item.get_meta("item_id", "")) != ITEM_ID: return false
	var token := str(item.get_meta("token", ""))
	var camera: Camera3D = inventory.camera
	if not inventory.inventory.loans.has(token) or camera == null: return false
	var forward := -camera.global_basis.z; forward.y = 0.0
	if forward.length_squared() < 0.01: forward = Vector3.FORWARD
	forward = forward.normalized()
	var at: Vector3 = camera.global_position + forward * 1.0 if side == "desktop" else item.global_position
	if inventory.player_body is Node3D: at.y = (inventory.player_body as Node3D).global_position.y + 0.15
	# The board's +Z, Anon's side, faces him.
	var facing: Vector3 = camera.global_position - at; facing.y = 0.0
	if facing.length_squared() < 0.01: facing = -forward
	var z := facing.normalized()
	var basis := Basis(Vector3.UP.cross(z), Vector3.UP, z)
	var exclude: Array[RID] = [item.get_rid()]
	if inventory.player_body is CollisionObject3D: exclude.append((inventory.player_body as CollisionObject3D).get_rid())
	var placed: Variant = ground_pose(item, Transform3D(basis, at), exclude)
	if not placed is Transform3D:
		inventory.inventory.last_error = ERROR; inventory._error(); return false
	var pose: Transform3D = placed
	if not inventory.inventory.set_board_open(token, pose): inventory._error(); return false
	inventory._unglow(item); inventory.held.erase(side); inventory._track.erase(side); inventory._eat_time.erase(side); inventory._claim(side, false)
	item.global_transform = pose; item.freeze = true; item.linear_velocity = Vector3.ZERO; item.angular_velocity = Vector3.ZERO
	for meta: String in ["hold_offset", "hold_blend", "hold_from", "world_pick"]:
		if item.has_meta(meta): item.remove_meta(meta)
	configure(item, token)
	inventory._refresh_holding(); inventory._haptic(side)
	SFX.play_event(item, "prop_place", {"material": "wood"})
	return true

## Level, supported, dry ground under the board, both seats and the box; nothing standing on the
## board or where she sits. Null when it does not fit.
static func ground_pose(body: Node3D, hint: Transform3D, exclude: Array[RID]) -> Variant:
	var space := body.get_world_3d().direct_space_state
	var lowest := INF
	var highest := -INF
	var centre_y := NAN
	for spot: Vector3 in GROUND:
		var point: Vector3 = hint * spot
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(point + Vector3.UP * 0.9, point - Vector3.UP * 1.2, 1, exclude))
		if hit.is_empty() or (hit.normal as Vector3).y < 0.9: return null
		var collider: Variant = hit.get("collider")
		if collider is Node and (collider as Node).is_in_group("navigation_water"): return null
		var surface: Vector3 = hit.position
		if is_finite(WATER.surface_above(space, surface + Vector3.UP * 0.01)): return null
		lowest = minf(lowest, surface.y); highest = maxf(highest, surface.y)
		if spot == Vector3.ZERO: centre_y = surface.y
	if highest - lowest > LEVEL or is_nan(centre_y): return null
	var pose := Transform3D(hint.basis, Vector3(hint.origin.x, centre_y, hint.origin.z))
	var query := PhysicsShapeQueryParameters3D.new()
	query.exclude = exclude
	for room: Array in [[Vector3(0.04, 0.3, 0.0), Vector3(0.72, 0.5, 0.62), 1 | 2 | (1 << 17)], [Vector3(0, 0.75, -SEAT_REACH - 0.1), Vector3(0.7, 1.2, 0.9), 1]]:
		var box := BoxShape3D.new(); box.size = room[1]
		query.shape = box; query.collision_mask = int(room[2])
		query.transform = Transform3D(pose.basis, pose * (room[0] as Vector3))
		if not space.intersect_shape(query, 1).is_empty(): return null
	return pose

## The open board on an item (after unfold, or when a saved open board streams in).
static func configure(item: RigidBody3D, token: String) -> void:
	if not is_instance_valid(item) or item.has_meta("board_table_root"): return
	var visual := _case_of(item)
	if visual != null: visual.hide()
	var seats: Array[Node3D] = []
	for side: float in [1.0, -1.0]:
		var seat := Node3D.new()
		seat.set_script(SEAT)
		seat.name = "PlayerSeat" if side > 0.0 else "PonySeat"
		seat.set("floor_sit", true)
		seat.set("for_ponies", false)
		seat.set("for_player", side > 0.0)
		seat.set("depth", 0.5)
		# A seat faces its -Z: both look at the board.
		seat.transform = Transform3D(Basis(Vector3.UP, 0.0 if side > 0.0 else PI), Vector3(0, 0.02, SEAT_REACH * side))
		item.add_child(seat)
		seats.append(seat)
	var table: Node3D = TABLE.new()
	table.name = "GameBoard"
	table.set("place_words", PLACE)
	table.set("body_size", Vector3(0.52, 0.05, 0.52))
	table.set("body_lift", 0.035)
	item.add_child(table)
	table.call("setup", item, seats[0], seats[1])
	item.set_meta("board_table_root", table)
	item.add_to_group(GROUP)
	clear_grass(item, true)
	# Streamed out or freed: its patch goes too (configure() clears it again when it streams back in).
	item.tree_exiting.connect(func() -> void: clear_grass(item, false), CONNECT_ONE_SHOT)
	# The item's own collider is the box beside the board: E or a grip there packs it up; the
	# board itself belongs to the game (its BoardBody, on the world layer, sits above).
	var shape := BoxShape3D.new(); shape.size = BOX_SIZE
	var collision := _collider_of(item)
	if collision != null: collision.shape = shape; collision.position = BOX_AT; collision.disabled = false
	item.freeze = true

## Which board body last cleared each patch: a replacement with the same loan token (restored
## drops) registers before the old body leaves, and the old one must not take its patch away.
static var _grass_owner := {}

## The grass patch under an open board on (`clear` true) or off; keyed by its saved loan token.
static func clear_grass(item: Node3D, clear: bool) -> void:
	if not is_instance_valid(item) or not item.is_inside_tree(): return
	var key := "board:" + str(item.get_meta("token", item.get_instance_id()))
	if clear:
		_grass_owner[key] = item.get_instance_id()
		item.get_tree().call_group("grass_footprints", "add_exclusion", key, item.global_transform, GRASS_CLEAR)
	elif int(_grass_owner.get(key, item.get_instance_id())) == item.get_instance_id():
		_grass_owner.erase(key)
		item.get_tree().call_group("grass_footprints", "remove_exclusion", key)

## The folded case's model and the item's own collider, found by kind: an item's children are not
## always in the order it was built (dev 2026-10-29: the open board kept its folded case on top
## and E could not reach the box to pack it up).
static func _case_of(item: Node) -> Node3D:
	for child: Node in item.get_children():
		if child is Node3D and not child is CollisionShape3D and "bounds" in child: return child
	return null

static func _collider_of(item: Node) -> CollisionShape3D:
	for child: Node in item.get_children():
		if child is CollisionShape3D: return child
	return null

## The open board whose packing box the line from `origin` along `direction` enters within `reach`
## metres, or null: E there packs it up before the seat beside it can take the key (player/
## interactor.gd; the interactor's ray does not see items, so it found the seat). The box itself,
## 2 cm larger, is what counts, and `reach` stops at whatever the interactor's ray hit first, so
## the playing surface, a wall or anything else in front keeps the key (Codex review 2026-10-29).
static func box_in_view(tree: SceneTree, origin: Vector3, direction: Vector3, reach := 2.6) -> RigidBody3D:
	var best: RigidBody3D = null
	var best_along := reach
	var half := BOX_SIZE * 0.5 + Vector3.ONE * 0.02
	for node: Node in tree.get_nodes_in_group(GROUP):
		if not node is RigidBody3D or not node.has_meta("board_table_root"): continue
		# The line in the box's own frame, then the slab test against its sides.
		var to_local := (node as Node3D).global_transform.affine_inverse()
		var from: Vector3 = to_local * origin - BOX_AT
		var way: Vector3 = to_local.basis * direction
		var enter := 0.0
		var leave := best_along
		for axis in 3:
			if absf(way[axis]) < 0.000001:
				if absf(from[axis]) > half[axis]: leave = -1.0
				continue
			var a := (-half[axis] - from[axis]) / way[axis]
			var b := (half[axis] - from[axis]) / way[axis]
			enter = maxf(enter, minf(a, b)); leave = minf(leave, maxf(a, b))
		if enter <= leave and enter < best_along: best = node; best_along = enter
	return best

## E on the box: picked up through the inventory like any loose thing (finish or resign a game first).
static func pack_desktop(item: RigidBody3D) -> bool:
	var table: Variant = item.get_meta("board_table_root") if item.has_meta("board_table_root") else null
	var inventory: Variant = (table as Node).get("inventory") if table is Node and is_instance_valid(table) else null
	if not inventory is Node or not (inventory as Node).has_method("_desktop_look_pick"): return false
	return bool((inventory as Node).call("_desktop_look_pick", {"target": item, "kind": "loose"}))

## Packing up only between games: a game in progress has to be finished or given up first.
static func can_pack(item: RigidBody3D) -> bool:
	var table: Variant = item.get_meta("board_table_root") if item.has_meta("board_table_root") else null
	if not (table is Node and is_instance_valid(table)): return true
	var session: Variant = (table as Node).get("session")
	return not (session is Node and is_instance_valid(session) and not bool((session as Node).call("is_over")))

## After the atomic pick_up erased board_open: she gets up, the board folds into its case.
static func fold_visual(item: RigidBody3D) -> void:
	if not is_instance_valid(item): return
	var table: Variant = item.get_meta("board_table_root") if item.has_meta("board_table_root") else null
	if table is Node3D and is_instance_valid(table):
		(table as Node3D).name = "GameBoardFolded"
		(table as Node3D).queue_free()
	if item.has_meta("board_table_root"): item.remove_meta("board_table_root")
	clear_grass(item, false)
	if item.is_in_group(GROUP): item.remove_from_group(GROUP)
	for seat_name: String in ["PlayerSeat", "PonySeat"]:
		var seat := item.get_node_or_null(seat_name)
		if seat != null: seat.queue_free()
	var visual := _case_of(item)
	if visual == null: return
	visual.show()
	if "bounds" in visual:
		var folded := BoxShape3D.new(); folded.size = (visual.bounds as AABB).size.max(Vector3.ONE * .02)
		var collision := _collider_of(item)
		if collision != null: collision.shape = folded; collision.position = (visual.bounds as AABB).get_center(); collision.disabled = false
	SFX.play_event(item, "prop_place", {"material": "wood"})

## The closed case, as carried and on the market stall (world/shop/shop_item_visual.gd): the
## board folded in half, squares outside, a brass hinge and clasp. Returns its bounds.
static func build_visual(parent: Node3D) -> AABB:
	var wood := StandardMaterial3D.new(); wood.albedo_color = MODELS.WOODS.frame; wood.roughness = 0.6
	var brass := StandardMaterial3D.new(); brass.albedo_color = MODELS.WOODS.inlay; brass.metallic = 0.6; brass.roughness = 0.35
	var case := MeshInstance3D.new(); case.name = "Case"
	var box := BoxMesh.new(); box.size = FOLDED
	case.mesh = box; case.material_override = wood; case.position.y = FOLDED.y * 0.5
	parent.add_child(case)
	# The outside of one half: 4 x 8 squares inlaid on top.
	var square := FOLDED.z / 8.0 * 0.92
	for shade: String in ["light_square", "dark_square"]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for row in 8:
			for column in 4:
				if ((row + column) % 2 == 0) != (shade == "dark_square"): continue
				var c := Vector3((column - 1.5) * square, FOLDED.y + 0.0008, (row - 3.5) * square)
				var h := square * 0.5
				st.set_normal(Vector3.UP); st.add_vertex(c + Vector3(-h, 0, -h))
				st.set_normal(Vector3.UP); st.add_vertex(c + Vector3(h, 0, -h))
				st.set_normal(Vector3.UP); st.add_vertex(c + Vector3(h, 0, h))
				st.set_normal(Vector3.UP); st.add_vertex(c + Vector3(-h, 0, -h))
				st.set_normal(Vector3.UP); st.add_vertex(c + Vector3(h, 0, h))
				st.set_normal(Vector3.UP); st.add_vertex(c + Vector3(-h, 0, h))
		var squares := MeshInstance3D.new(); squares.name = shade.to_pascal_case()
		squares.mesh = st.commit()
		var finish := StandardMaterial3D.new(); finish.albedo_color = MODELS.WOODS[shade]; finish.roughness = 0.55
		finish.cull_mode = BaseMaterial3D.CULL_DISABLED
		squares.material_override = finish
		parent.add_child(squares)
	for part: Array in [[Vector3(0.012, 0.03, 0.42), Vector3(-FOLDED.x * 0.5 - 0.004, FOLDED.y * 0.5, 0)], [Vector3(0.012, 0.022, 0.05), Vector3(FOLDED.x * 0.5 + 0.004, FOLDED.y * 0.5, 0)]]:
		var fitting := MeshInstance3D.new(); var mesh := BoxMesh.new(); mesh.size = part[0]
		fitting.mesh = mesh; fitting.material_override = brass; fitting.position = part[1]
		parent.add_child(fitting)
	return AABB(Vector3(-FOLDED.x * 0.5 - 0.01, 0, -FOLDED.z * 0.5), Vector3(FOLDED.x + 0.02, FOLDED.y + 0.001, FOLDED.z))
