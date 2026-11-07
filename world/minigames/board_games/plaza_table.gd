extends RefCounted
## The public game table by the Plaza fountain (dev 2026-10-29: "a public board somewhere in
## Ponyville"): a low stone table between two low stone seats, like the chess tables of a town
## square, on the green east of the plaza's fountain, between a bench and the fair's honey stall.
## The game is board_table.gd, as in the library: Anon sits on his side and asks a pony passing
## by, or a pony sets a game up here herself and waits for him. Loaded once by
## world/game_town_adapters.gd through load(), before navigation is built, so walkers path round it.
## The pose is a constant measured once in the lab, like the Balloon Hill easel
## (world/painting/station_install.gd): no runtime raycast.
const TABLE := preload("res://world/minigames/board_games/board_table.gd")
const SEAT := preload("res://world/life/seat.gd")
const NAME := "PlazaGameTable"
const PLACE := "at the stone game table by the Plaza fountain"
## The table's middle on the ground. Its local X runs from the pony's seat (-X) to Anon's (+X),
## round the fountain. Measured 2026-10-29 in a release copy: the first guess, south of the fountain,
## stood in Pinkie's party cannon; the next, on the sand in front of a bench, looked squeezed against
## it (dev: "a bit awkward next to the banc. Maybe more in the grass?"). Rings of spots 9-16 m out
## were tested for flat grass under the table and both seats and nothing within 1.7 m; this one, 9 m
## east on the green between the bench and the honey stall, is the nearest.
const POSE := Transform3D(Basis(Vector3.UP, 1.0472), Vector3(251.79, 7.917, -257.5))
const TOP := 0.42
const TOP_SIZE := Vector3(0.72, 0.07, 0.86)
## Each seat a sitting pony's half-width (0.45 m) clear of the table's edge.
const SEAT_REACH := 0.86
const SEAT_RADIUS := 0.3
const SEAT_HEIGHT := 0.12
## Local half-size of the grass-free patch: both seats along X, the table along Z.
const GRASS_HALF := Vector2(1.3, 0.55)

static func attach(town: Node) -> void:
	if not town is Node3D or not town.is_inside_tree() or town.get_node_or_null(NAME) != null: return
	var root := Node3D.new(); root.name = NAME
	town.add_child(root)
	root.global_transform = POSE
	# No grass growing through the table and its seats (ground_grass.gd; it reads this group when
	# it is built after the town).
	root.set_meta("grass_key", "plaza-game-table"); root.set_meta("grass_half", GRASS_HALF)
	root.add_to_group("grass_patches")
	root.get_tree().call_group("grass_footprints", "set_footprint", "plaza-game-table", POSE, GRASS_HALF)
	var stone := StandardMaterial3D.new(); stone.albedo_color = Color("c9bfae"); stone.roughness = 0.85
	var darker := StandardMaterial3D.new(); darker.albedo_color = Color("a79c8b"); darker.roughness = 0.9
	var solid := StaticBody3D.new(); solid.name = "Stone"; solid.collision_layer = 1; solid.collision_mask = 0
	root.add_child(solid)
	# The table: a thick slab on a pedestal over a square foot.
	_box(root, solid, "Top", TOP_SIZE, Vector3(0, TOP - TOP_SIZE.y * 0.5, 0), stone)
	_box(root, solid, "Pedestal", Vector3(0.28, TOP - TOP_SIZE.y - 0.06, 0.34), Vector3(0, (TOP - TOP_SIZE.y + 0.06) * 0.5, 0), darker)
	_box(root, null, "Foot", Vector3(0.5, 0.06, 0.58), Vector3(0, 0.03, 0), darker)
	var seats: Array[Node3D] = []
	for side: float in [1.0, -1.0]:
		var at := Vector3(SEAT_REACH * side, 0, 0)
		var block := MeshInstance3D.new(); block.name = "SeatStone"
		var mesh := CylinderMesh.new(); mesh.top_radius = SEAT_RADIUS; mesh.bottom_radius = SEAT_RADIUS + 0.03; mesh.height = SEAT_HEIGHT
		block.mesh = mesh; block.material_override = darker; block.position = at + Vector3.UP * SEAT_HEIGHT * 0.5
		root.add_child(block)
		# Anon's stone is solid, so aiming at it (E, the VR trigger, both on layer 1) finds his seat:
		# seating.gd accepts a hit on the table's own body. Hers stays soft underfoot, like the library's
		# cushions: a solid stone kept her from stepping on and she sat on the ground behind it.
		if side > 0.0:
			var round_shape := CylinderShape3D.new(); round_shape.radius = SEAT_RADIUS; round_shape.height = SEAT_HEIGHT
			var holder := CollisionShape3D.new(); holder.name = "SeatStone"; holder.shape = round_shape; holder.position = block.position
			solid.add_child(holder)
		var seat := Node3D.new(); seat.set_script(SEAT)
		seat.name = "PlayerSeat" if side > 0.0 else "PonySeat"
		seat.set("floor_sit", true)
		seat.set("for_ponies", false)
		seat.set("for_player", side > 0.0)
		seat.set("depth", 0.5)
		# A seat faces its -Z: both look at the table.
		seat.transform = Transform3D(Basis(Vector3.UP, PI * 0.5 * side), at + Vector3.UP * SEAT_HEIGHT)
		root.add_child(seat)
		seats.append(seat)
	var table: Node3D = TABLE.new()
	table.name = "GameTable"
	table.set("place_words", PLACE)
	# Its +Z faces Anon's seat.
	table.transform = Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3.UP * TOP)
	root.add_child(table)
	table.call("setup", root, seats[0], seats[1])

static func _box(root: Node3D, solid: StaticBody3D, part: String, size: Vector3, at: Vector3, material: Material) -> void:
	var visual := MeshInstance3D.new(); visual.name = part
	var mesh := BoxMesh.new(); mesh.size = size
	visual.mesh = mesh; visual.material_override = material; visual.position = at
	root.add_child(visual)
	if solid == null: return
	var shape := BoxShape3D.new(); shape.size = size
	var holder := CollisionShape3D.new(); holder.name = part; holder.shape = shape; holder.position = at
	solid.add_child(holder)
