extends Node3D
## Authored Golden Oak library. Parent to the shell's unit-scale InteriorFrame, then build().
## Source references: Giardina's IntLibraryTree pilot art; show reading-area screenshot;
## bedroom-background fan vector only supplements the loft/blanket colour reference.
## The shell owns floor, walls, windows, ceiling and entry passage. Main owns home/navigation.
const KIT := preload("res://world/buildings/golden_oak/furniture_kit.gd")
const SHELVES := preload("res://world/buildings/golden_oak/furniture_shelves.gd")
const ARCHITECTURE := preload("res://world/buildings/golden_oak/furniture_architecture.gd")
const REFERENCE := preload("res://world/buildings/golden_oak/reference_furniture.gd")
const GUEST_REST := preload("res://world/relationships/shared_bed.gd")
const STATIC_MERGE := preload("res://world/buildings/static_mesh_merge.gd")
## Perf 0.1.0 (geometry): still decoration (stairs, rails, lanterns, carved bays, table roots,
## fireplace, telescope) draws as one merged mesh per look instead of ~350 surfaces.
## false = every piece draws on its own again (rollback / A-B).
const MERGE_STATIC := true

var radius := 5.0
var floor_y := 0.0
var loft_y := 3.4
var ceiling_y := 7.2
var stair_path: Array[Vector3] = []
var ground_walk_points: Array[Vector3] = []
var loft_walk_points: Array[Vector3] = []
var beds: Dictionary = {}
var _built := false
var _kit := KIT.new()

func build(layout: Dictionary = {}) -> void:
	if _built:
		return
	# Refuse inherited scale before creating physical bodies; Jolt caches entry scale.
	if is_inside_tree() and not global_basis.get_scale().is_equal_approx(Vector3.ONE):
		push_error("Golden Oak interior requires a unit-scale frame before build().")
		return
	_built = true
	radius = float(layout.get("radius", 5.0))
	floor_y = float(layout.get("floor_y", 0.0))
	loft_y = float(layout.get("loft_y", 3.4))
	ceiling_y = float(layout.get("ceiling_y", 7.2))
	stair_path = ARCHITECTURE.build(self, radius, loft_y)
	_build_shelves()
	_build_reading_circle()
	_build_bedrooms()
	_build_breakfast()
	_build_game_nook()
	_build_lamps()
	REFERENCE.telescope(self, Vector3(3.55, loft_y, -2.85))
	REFERENCE.fireplace(self, ARCHITECTURE.polar(4.1, deg_to_rad(-125.0), 0), deg_to_rad(55.0))
	KIT.marker(self, "Entry", Vector3(0.16, 0, 4.4))
	KIT.marker(self, "Loft", stair_path[-1])
	KIT.marker(self, "Bed", Vector3(1.55, 0, -1.35))
	KIT.marker(self, "Tea", Vector3(2.85, 0, 0.85))
	_limit_render_cost()
	ground_walk_points.assign([
		Vector3(0, 0, 4.4), Vector3(-1.35, 0, 3.8), Vector3(-0.9, 0, 3.0),
		Vector3(-1.85, 0, -1.55), Vector3(0, 0, -1.65), Vector3(1.6, 0, -1.4),
		Vector3(2.95, 0, -0.65), Vector3(2.75, 0, 0.65), Vector3(1.2, 0, 3.8),
		# Full-size princess clearance: skirt the cafe table and sideboard corner.
		Vector3(1.4, 0, 1.5), Vector3(2.75, 0, -0.75),
		# Round the game table to its fireplace-side cushion (_build_game_nook): the straight
		# line from the aisle grazes the table.
		Vector3(-2.5, 0, -2.0),
	])
	# The aisle between the foot of Twilight's bed (z -1.95) and the balcony rail (z -0.74) is
	# only 1.2 m: its points sit on the aisle's centre line, and one past the bed's foot corner
	# leads out of it. The old aisle point's leg west grazed that corner, so a pony standing
	# there had no route out (tester 2026-10-20: stuck between bed end and railing).
	loft_walk_points.assign([
		stair_path[-1], Vector3(-1.1, loft_y, -3.35), Vector3(-0.7, loft_y, -1.65),
		Vector3(0.05, loft_y, -1.3), Vector3(1.6, loft_y, -1.34), Vector3(3.2, loft_y, -1.5),
	])
	set_meta("stair_path", stair_path)
	set_meta("ground_walk_points", ground_walk_points)
	set_meta("loft_walk_points", loft_walk_points)
	set_meta("floor_y", floor_y)
	set_meta("loft_y", loft_y)
	set_meta("review_views", {
		"library": {"eye": Vector3(0.25, 1.7, 4.45), "target": Vector3(0, 2.7, -1.65)},
		"loft": {"eye": Vector3(-1.4, loft_y + 1.65, -2.0), "target": Vector3(1.6, loft_y + 0.8, -3.0)},
	})

func _build_shelves() -> void:
	# Right-hand bays follow the trunk; the left wall is reserved for the entire stair.
	var index := 0
	for angle_degrees: float in [56.0, 80.0, 104.0]:
		var angle := deg_to_rad(angle_degrees)
		var at := ARCHITECTURE.polar(radius - 0.46, angle, 0)
		SHELVES.build(self, at, angle + PI, index)
		index += 1
	# Below the bedroom and above the ground-floor guest nook: separate accessible bays.
	for angle_degrees: float in [141.0, 199.0]:
		var angle := deg_to_rad(angle_degrees)
		SHELVES.build(self, ARCHITECTURE.polar(radius - 0.46, angle, 0), angle + PI, index, 1.6, 2.6)
		index += 1
	for angle_degrees: float in [116.0, 142.0, 195.0]:
		var angle := deg_to_rad(angle_degrees)
		SHELVES.build(self, ARCHITECTURE.polar(radius - 0.46, angle, loft_y), angle + PI, index, 1.4, 2.65)
		index += 1

func _build_reading_circle() -> void:
	var wood := KIT.material("b94f4b")
	var edge := KIT.material("efac6c")
	var plum := KIT.material("873663")
	var gold := KIT.material("d5b269")
	var centre := Vector3(0.0, 0, 0.2)
	KIT.disc(self, "ReadingRugBorder", 2.05, 0.012, centre + Vector3.UP * 0.008, gold)
	KIT.disc(self, "ReadingRug", 1.98, 0.012, centre + Vector3.UP * 0.016, plum)
	KIT.disc(self, "ReadingTableTop", 0.92, 0.105, centre + Vector3.UP * 0.60, wood, true)
	KIT.disc(self, "ReadingTableLip", 0.935, 0.035, centre + Vector3.UP * 0.64, edge)
	# Preserve the tested support bodies while replacing their machine-round visuals.
	KIT.disc(self, "ReadingTablePedestal", 0.18, 0.55, centre + Vector3.UP * 0.275, wood, true).hide()
	KIT.disc(self, "ReadingTableFoot", 0.51, 0.1, centre + Vector3.UP * 0.05, wood, true).hide()
	REFERENCE.rooted_table(self, centre)
	REFERENCE.reading_stand(self, centre + Vector3(0, 0.664, 0.14))
	for angle_degrees: float in [-90.0, 0.0, 90.0]:
		var angle := deg_to_rad(angle_degrees)
		var at := centre + ARCHITECTURE.polar(1.72, angle, 0.025)
		add_child(_kit.prop("floor-cushion", at, angle + PI))
	KIT.marker(self, "Reading", Vector3(0, 0, -1.35), "read")
	# The existing library fills this modest table book-rest with graspable books when installed.
	var rest := Node3D.new()
	rest.name = "TableBookRest"
	rest.position = centre + Vector3(0, 0.662, -0.48)
	add_child(rest)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("golden_oak:reading_table")
	KIT.BOOKS.fill(rest, {"x": [-0.29, 0.29], "front": 0.1, "levels": [[0.0, 0.34]]}, rng, "golden_oak:reading_table", 1.8)

func _build_bedrooms() -> void:
	var twilight := _kit.bed(Vector3(1.55, loft_y, -3.0), 0.0, "TwilightBed", true)
	var guest := _kit.bed(Vector3(1.55, 0, -3.0), 0.0, "GuestBed", false)
	for bed: Node3D in [twilight, guest]:
		bed.set_meta("house", self)
		bed.set_meta("side_local", Vector3(0, 0, 1.65))
		add_child(bed)
	beds["twilight"] = twilight
	beds["guest"] = guest
	beds["spike"] = _spike_basket()
	KIT.marker(self, "TwilightBedApproach", Vector3(1.55, loft_y, -1.35), "sleep")
	KIT.marker(self, "GuestBedApproach", Vector3(1.55, 0, -1.35), "sleep")
	add_child(_kit.prop("bedside-table", Vector3(3.0, loft_y, -2.85)))
	add_child(_kit.prop("bedside-table", Vector3(3.0, 0, -2.85)))
	add_child(_kit.prop("folded-blanket", Vector3(1.45, float(guest.get_meta("mattress_top", 0.6)) + 0.05, -2.45)))
	_star_blanket(twilight)
	REFERENCE.guest_curtains(self, loft_y)
	# Use the existing physical player-bed rest controller, with no relationship requirement.
	var rest := GUEST_REST.new()
	rest.name = "GuestBedRest"
	rest.house = self
	add_child(rest)

## Spike's basket bed beside Twilight's, between her bed and the stairs, as in the show.
## A soft cushion is the only collider: he hops in over the rim when he goes to bed.
const SPIKE_BASKET := preload("res://world/buildings/golden_oak/spike_basket.glb")
const SPIKE_BASKET_AT := Vector3(-0.35, 0.0, -3.3)
func _spike_basket() -> Node3D:
	var basket := Node3D.new()
	basket.name = "SpikeBasket"
	basket.position = SPIKE_BASKET_AT + Vector3.UP * loft_y
	add_child(basket)
	basket.add_child(SPIKE_BASKET.instantiate())
	var body := StaticBody3D.new(); body.name = "Cushion"; body.collision_layer = 1; body.collision_mask = 0
	var shape := CollisionShape3D.new(); var cylinder := CylinderShape3D.new()
	cylinder.radius = 0.34; cylinder.height = 0.115
	shape.shape = cylinder; shape.position.y = 0.0575
	body.add_child(shape); basket.add_child(body)
	basket.set_meta("house", self)
	basket.set_meta("bed_size", Vector3(0.82, 0.27, 0.82))
	basket.set_meta("mattress_top", 0.115)
	basket.set_meta("side_local", Vector3(0, 0, 0.75))
	body.set_meta("mattress_top", 0.115)
	KIT.marker(self, "SpikeBedApproach", SPIKE_BASKET_AT + Vector3(0, loft_y, 0.75), "sleep")
	return basket

func _star_blanket(bed: Node3D) -> void:
	var gold := KIT.material("efd98c")
	var top := float(bed.get_meta("mattress_top", 0.6))
	# Perf 0.1.0: the nine identical star prisms draw as one mesh (was nine draws per pass).
	# Same vertices and material; MERGE_STATIC false keeps nine separate stars.
	var holder := Node3D.new() if MERGE_STATIC else bed
	for index: int in 9:
		var polygon := PackedVector2Array()
		var centre := Vector2(-0.55 + (index % 3) * 0.5, -0.18 + (index / 3) * 0.32)
		for point: int in 10:
			var angle := TAU * point / 10.0
			var reach := 0.105 if point % 2 == 0 else 0.037
			polygon.append(centre + Vector2(sin(angle), cos(angle)) * reach)
		if Geometry2D.is_polygon_clockwise(polygon):
			polygon.reverse()
		ARCHITECTURE.prism(holder, "BlanketStar", polygon, top + 0.045, 0.004, gold, false)
	if holder == bed:
		return
	var stars := SurfaceTool.new()
	for star: MeshInstance3D in holder.get_children():
		stars.append_from(star.mesh, 0, Transform3D.IDENTITY)
	stars.set_material(gold)
	var view := MeshInstance3D.new()
	view.name = "BlanketStars"
	view.mesh = stars.commit()
	bed.add_child(view)
	holder.free()

func _build_breakfast() -> void:
	var table := _kit.prop("round-cafe-table", Vector3(2.85, 0, 2.0))
	add_child(table)
	add_child(_kit.prop("cottage-tea-set", Vector3(2.85, 0.735, 2.0)))
	add_child(_kit.prop("floor-cushion", Vector3(2.6, 0, 3.22), PI))
	var wood := KIT.material("c65b51")
	KIT.box(self, "TeaSideboardTop", Vector3(0.95, 0.07, 0.55), Vector3(3.75, 0.78, 0.1), wood, true)
	KIT.box(self, "TeaSideboardShelf", Vector3(0.84, 0.045, 0.45), Vector3(3.75, 0.28, 0.1), wood)
	for x: float in [3.45, 4.05]:
		KIT.disc(self, "BreakfastSideboardLeg", 0.07, 0.78, Vector3(x, 0.39, 0.1), wood, true)
	KIT.marker(self, "Breakfast", Vector3(2.85, 0, 0.85), "cook")

## The game table by the fireplace (dev 2026-10-26: chess and checkers at Twilight's,
## world/minigames/board_games/board_table.gd): a low table for two on floor cushions, Anon's on
## the room side and the other with the fire at her back, off the ground walk lines, under a
## lantern of its own. The players face each other along X; the table's long side runs along Z
## (the taken pieces line up there). Each cushion keeps a pony's half-width (0.45 m, the
## gait profile's radius) clear of the table, so a pony walking to it fits.
const BOARD_TABLE := preload("res://world/minigames/board_games/board_table.gd")
const GAME_TABLE_AT := Vector3(-1.3, 0, -2.75)
const GAME_TABLE_TOP := 0.4
const GAME_SEAT_REACH := 0.9
func _build_game_nook() -> void:
	var wood := KIT.material("b94f4b")
	var edge := KIT.material("efac6c")
	var at := GAME_TABLE_AT
	KIT.box(self, "GameTableTop", Vector3(0.66, 0.04, 0.82), at + Vector3.UP * (GAME_TABLE_TOP - 0.02), wood, true)
	KIT.box(self, "GameTableApron", Vector3(0.58, 0.05, 0.74), at + Vector3.UP * (GAME_TABLE_TOP - 0.065), edge)
	for corner: Vector2 in [Vector2(-0.26, -0.34), Vector2(0.26, -0.34), Vector2(-0.26, 0.34), Vector2(0.26, 0.34)]:
		KIT.disc(self, "GameTableLeg", 0.03, GAME_TABLE_TOP - 0.04, at + Vector3(corner.x, (GAME_TABLE_TOP - 0.04) * 0.5, corner.y), wood)
	var seats: Array[Node3D] = []
	for side: float in [1.0, -1.0]:
		var cushion := _kit.prop("floor-cushion", at + Vector3(GAME_SEAT_REACH * side, 0, 0), -PI * 0.5 * side)
		# Its bench-style seat would have a pony hop on from the table side, and its solid block
		# would stop her walking onto it: a floor seat, soft underfoot.
		var unwanted: Array = cushion.find_children("*", "Node3D", true, false).filter(func(old: Node) -> bool:
			return old.get_script() == KIT.SEAT or (old is StaticBody3D and str(old.name).begins_with("Seat")))
		for old: Node in unwanted:
			old.get_parent().remove_child(old)
			old.free()
		var seat := Node3D.new()
		seat.set_script(KIT.SEAT)
		seat.name = "GameSeat"
		seat.set("floor_sit", true)
		seat.set("for_ponies", false)
		seat.set("depth", 0.5)
		# A seat faces its -Z, the cushion's front: the table.
		seat.transform = Transform3D(Basis(Vector3.UP, PI), Vector3(0, 0.06, 0))
		cushion.add_child(seat)
		add_child(cushion)
		seats.append(seat)
	REFERENCE.lantern(self, at + Vector3.UP * 2.3, loft_y)
	var light := OmniLight3D.new()
	light.name = "GameTableLamp"
	light.position = at + Vector3.UP * 2.1
	light.light_color = Color("ffddb0")
	light.light_energy = 0.9
	light.omni_range = 3.6
	light.omni_attenuation = 0.8
	light.shadow_enabled = false
	light.distance_fade_enabled = true
	light.distance_fade_begin = 25.0
	light.distance_fade_length = 10.0
	add_child(light)
	var table := BOARD_TABLE.new()
	table.name = "GameTable"
	# Its +Z faces Anon's cushion.
	table.transform = Transform3D(Basis(Vector3.UP, PI * 0.5), at + Vector3.UP * GAME_TABLE_TOP)
	add_child(table)
	table.setup(self, seats[0], seats[1])

func _build_lamps() -> void:
	for at: Vector3 in [Vector3(0.0, 2.85, 0.8), Vector3(1.0, 6.15, -2.3), Vector3(3.3, 2.4, 2.2)]:
		REFERENCE.lantern(self, at, ceiling_y)
		var light := OmniLight3D.new()
		light.name = "WarmLibraryLamp"
		light.position = at - Vector3.UP * 0.2
		light.light_color = Color("ffddb0")
		light.light_energy = 1.15
		light.omni_range = 6.0 if at.y > loft_y else 5.5
		light.omni_attenuation = 0.65
		light.shadow_enabled = false
		light.distance_fade_enabled = true
		light.distance_fade_begin = 25.0
		light.distance_fade_length = 10.0
		add_child(light)

func _limit_render_cost() -> void:
	for visual: GeometryInstance3D in find_children("*", "GeometryInstance3D", true, false):
		visual.visibility_range_end = 45.0
		visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if MERGE_STATIC:
		# The carved bays are plain static furniture; their books are bodies and never merge.
		STATIC_MERGE.merge(self, ["house_furniture", "book_shelves"], [preload("res://world/buildings/golden_oak/reference_surface.gdshader")], "MergedDecoration")

func ensure_bed(id: String = "") -> Node3D:
	var key := id.to_lower()
	return beds.get("twilight" if key.contains("twilight") else ("spike" if key.contains("spike") else "guest")) as Node3D

func bed_shared(_id: String = "") -> bool:
	return false

func bed_side(id: String = "") -> Vector3:
	var bed := ensure_bed(id)
	return bed.to_global(Vector3(bed.get_meta("side_local"))) if bed != null else Vector3.INF

func bed_rest(id: String = "") -> Transform3D:
	var bed := ensure_bed(id)
	if bed == null:
		return Transform3D(Basis.IDENTITY, Vector3.INF)
	var top := float(bed.get_meta("mattress_top", 0.6))
	return Transform3D(Basis.looking_at(-bed.global_basis.z, Vector3.UP), bed.to_global(Vector3(0, top, 0.15)))

func on_mattress(point: Vector3, id: String = "") -> bool:
	var bed := ensure_bed(id)
	if bed == null:
		return false
	var local := bed.to_local(point)
	var top := float(bed.get_meta("mattress_top", 0.6))
	var size: Vector3 = bed.get_meta("bed_size", Vector3(2.05, 1.1, 2.1))
	return absf(local.y - top) <= 0.4 and absf(local.x) < size.x * 0.5 + 0.12 and absf(local.z) < size.z * 0.5 + 0.12
