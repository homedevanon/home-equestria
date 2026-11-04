extends Node
## Places the non-food shop tables (world/shop/shop_display.gd) and restocks every shop at 06:00,
## the food stalls too (world/food/food_world.gd). Package 10 of the bulk prompt, dev 2026-09-30:
## the first useful shops are Rarity's Boutique (Anon's outfits), the market (existing food
## stalls) and a general goods tent (small household things). Stock is saved with the game.
## Anon's human clothes are bought once and then kept in his wardrobe; their shelf samples stay
## and read "In your wardrobe" (dev 2026-10-14).
signal stock_changed(state: Dictionary)
const DISPLAY := preload("res://world/shop/shop_display.gd")
const CIDER_POUR := preload("res://world/items/cider_pour.gd")
const TOWN := "Zones/PonyvilleTown/"
const RESTOCK_HOUR := 6.0
## "at" is in the anchor's frame; "turn" spins the table to face its customers (price cards read
## from the display's local +z side). A "counter" placement uses the shop's authored surface;
## other displays retain their existing ground-fitted tables until their own asset pass.
const PLACEMENTS: Array[Dictionary] = [
	{"id": "ponyville:boutique:flight", "anchor": "RNLScenery/Central/Boutique/rarityboutique_01/BoutiqueRoomFrame/UsableBoutique", "at": Vector3.ZERO, "columns": 1, "counter": true,
		"items": ["equipment:wing-sandals"], "spacing": Vector2(0.7, 0.62),
		"mounts": ["BoutiqueInterior/BoutiqueShelves/OutfitShelves/Stock01"]},
	{"id": "ponyville:boutique:outfits", "anchor": "RNLScenery/Central/Boutique/rarityboutique_01/BoutiqueRoomFrame/UsableBoutique", "at": Vector3.ZERO, "columns": 3, "counter": true,
		"items": ["outfit:ponyville-casual", "outfit:farm-work", "outfit:pajamas", "outfit:winter-tweed", "outfit:canterlot-evening", "outfit:boutique-special",
			"outfit:manehattan-business", "outfit:saddle-arabian-travel", "outfit:whitetail-tweed"], "spacing": Vector2(0.7, 0.62),
		"mounts": ["BoutiqueInterior/BoutiqueShelves/OutfitShelves/Stock03", "BoutiqueInterior/BoutiqueShelves/OutfitShelves/Stock04", "BoutiqueInterior/BoutiqueShelves/OutfitShelves/Stock05",
			"BoutiqueInterior/BoutiqueShelves/OutfitShelves/Stock06", "BoutiqueInterior/BoutiqueShelves/OutfitShelves/Stock07", "BoutiqueInterior/BoutiqueShelves/OutfitShelves/Stock08",
			"BoutiqueInterior/BoutiqueShelves/OutfitShelves/Stock00", "BoutiqueInterior/BoutiqueShelves/OutfitShelves/Stock02", "BoutiqueInterior/BoutiqueShelves/OutfitShelves/Stock09"]},
	{"id": "ponyville:boutique:accessories", "anchor": "RNLScenery/Central/Boutique/rarityboutique_01/BoutiqueRoomFrame/UsableBoutique", "at": Vector3.ZERO, "columns": 3, "counter": true,
		"items": ["wear:scarf:0", "wear:scarf:1", "wear:beanie:4", "wear:sunhat:2", "wear:socks:5", "wear:socks:3", "wear:spa-necklace:0", "wear:bowtie:0", "wear:necktie:0", "wear:nurse-cap:0", "wear:cat-eye-glasses:0", "wear:aviators:0", "wear:goggles:0", "wear:headphones:0"], "spacing": Vector2(0.7, 0.62),
		"mounts": ["BoutiqueInterior/BoutiqueShelves/AccessoryShelves/Stock03", "BoutiqueInterior/BoutiqueShelves/AccessoryShelves/Stock04", "BoutiqueInterior/BoutiqueShelves/AccessoryShelves/Stock07",
			"BoutiqueInterior/BoutiqueShelves/AccessoryShelves/Stock06", "BoutiqueInterior/BoutiqueShelves/AccessoryShelves/Stock00", "BoutiqueInterior/BoutiqueShelves/AccessoryShelves/Stock01", "BoutiqueInterior/BoutiqueShelves/AccessoryShelves/Stock05", "BoutiqueInterior/BoutiqueShelves/AccessoryShelves/Stock08", "BoutiqueInterior/BoutiqueShelves/AccessoryShelves/Stock02", "BoutiqueInterior/BoutiqueShelves/AccessoryShelves/Stock10", "BoutiqueInterior/BoutiqueShelves/AccessoryShelves/Stock09", "BoutiqueInterior/BoutiqueShelves/AccessoryShelves/Stock11", "BoutiqueInterior/BoutiqueShelves/OutfitShelves/Stock10", "BoutiqueInterior/BoutiqueShelves/OutfitShelves/Stock11"]},
	{"id": "ponyville:trixie:stall", "anchor": "TrixieWagon", "at": Vector3(2.4, 0, -3.2), "columns": 2,
		"items": ["wear:wizard_hat:4", "wear:cape:4", "wear:wizard_hat:1", "wear:cape:1"], "spacing": Vector2(0.7, 0.62)},
	# Trimmed to things with a use (dev 2026-10-14: "do we NEED 100 little things"): the picnic
	# blanket and a pillow. The rest of the old stock is listed in world/shop/archived_stock.json.
	{"id": "ponyville:market:goods", "anchor": "RNLScenery/Town/Market/tent_friagram_lightbrown_01", "at": Vector3(-0.8, 0.95, 6.45), "counter": true, "columns": 1,
		"items": ["goods:folded-blanket", "goods:pillow", "goods:camera"], "spacing": Vector2(0.7, 0.62)},
	# Writing paper and the quill (world/letters/, docs/LETTERS_PLAN_2026_10_29.md): a narrow column on
	# the same goods counter, between the goods above and the cooking stall's food (x 0.35 and up).
	# Placed from the layout numbers only; it still wants a look in a render.
	{"id": "ponyville:market:stationery", "anchor": "RNLScenery/Town/Market/tent_friagram_lightbrown_01", "at": Vector3(-0.15, 0.95, 6.35), "counter": true, "columns": 1,
		"items": ["goods:paper-plain", "goods:paper-cream", "goods:paper-floral", "goods:paper-hearts", "goods:quill"], "spacing": Vector2(0.4, 0.3)},
	{"id": "ponyville:market:furniture", "anchor": "RNLScenery/Town/Market/tent_friagram_pinkish_01", "at": Vector3(0, 0.95, 6.3), "counter": true, "columns": 3,
		"items": ["goods:footstool", "goods:bedside-table", "goods:rug-round", "goods:curtains", "goods:table-lamp", "goods:picture", "goods:potted-plant", "goods:easel"], "spacing": Vector2(0.7, 0.5),
		# Full-sized goods use distinct counter surfaces. The rug hangs behind the plants;
		# purchase retains its real dimensions, with no miniature-to-owned replacement.
		"surfaces": [Transform3D(Basis.IDENTITY, Vector3(-1.2, 0, 0.35)), Transform3D(Basis.IDENTITY, Vector3(-0.4, 0, 0.35)),
			Transform3D(Basis(Vector3.RIGHT, PI / 2.0), Vector3(1.0, 0.75, -0.4)), Transform3D(Basis.IDENTITY, Vector3(-0.9, 0, -0.4)),
			Transform3D(Basis.IDENTITY, Vector3(0.4, 0, 0.35)), Transform3D(Basis.IDENTITY, Vector3(0.3, 0, -0.4)), Transform3D(Basis.IDENTITY, Vector3(1.25, 0, 0.4)),
			# The folded easel (world/painting/) stands upright on the ground just past the
			# counter's right end (about x 1.86), clear of the right tent pole (about x 2.6).
			Transform3D(Basis(Vector3.BACK, PI / 2.0), Vector3(2.1, -0.175, 0.2))]},
	# Applejack's cider stall beside the Sweet Apple Acres sign (world/items/cider_keg.gd); "@orchard"
	# is that sign, placed by world/minigames/apple_bucking/apple_bucking.gd. It faces the lane.
	# The apple sapling (P5, world/items/apple_sapling.gd) is appended after the keg, so the saved
	# stock key "0:goods:cider-keg" stays valid.
	{"id": "sweet-apple-acres:farm:cider", "anchor": "@orchard", "at": Vector3(1.6, 0, 0.7), "columns": 2,
		"items": ["goods:cider-keg", "goods:apple-sapling"], "spacing": Vector2(0.62, 0.55)},
]
var game: Node
var _stock: Dictionary = {}
var _displays: Dictionary = {}
var _retry := 0.0
var restocked_day := -1
var _restock_initialized := false
var _restocking := false
## Explicit startup diagnostic only; ordinary retries do not collect timings.
var _trace_startup := "--stock-startup-profile" in OS.get_cmdline_user_args()
var _traced_place := false

func setup(host: Node) -> void:
	game = host
	set_physics_process(true)
	var pour: Node = CIDER_POUR.new(); pour.name = "CiderPour"
	add_child(pour); pour.setup(host)

func _physics_process(delta: float) -> void:
	if not is_instance_valid(game): return
	_retry -= delta
	if _retry > 0.0: return
	_retry = 1.0
	_refresh_stock()

## Run the same first stock pass under the loading cover, after restored state,
## clothing/form and authored mounts are ready. Missing anchors/ground still
## defer to ordinary retries; dawn remains owned by _restock_check.
func prepare_loaded() -> void:
	if not is_instance_valid(game) or not game.is_inside_tree(): return
	_refresh_stock()
	_retry = 1.0

func _refresh_stock() -> void:
	_place()
	_restock_check()
	for display: Variant in _displays.values():
		if is_instance_valid(display): display.refresh_owned()

func _anchor(path: String) -> Node3D:
	if path == "@orchard":
		var farm: Node = game.get("apple_bucking")
		return (farm as Node).get_node_or_null("OrchardNotice") as Node3D if is_instance_valid(farm) else null
	var node := game.get_node_or_null(TOWN + path) as Node3D
	if node != null: return node
	var zones := game.get_node_or_null("Zones")
	return zones.find_child(path.get_file(), true, false) as Node3D if zones != null else null

func _place() -> void:
	var started: int = Time.get_ticks_usec() if _trace_startup else 0
	var built := 0
	for spec: Dictionary in PLACEMENTS:
		if is_instance_valid(_displays.get(spec.id)): continue
		var anchor := _anchor(str(spec.anchor))
		if anchor == null or not anchor.is_inside_tree(): continue
		var display_started: int = Time.get_ticks_usec() if _trace_startup else 0
		var display: Node3D = DISPLAY.new()
		display.name = "ShopDisplay_" + str(spec.id).get_slice(":", 2)
		display.display_id = spec.id
		display.item_ids = PackedStringArray(spec.items)
		display.columns = spec.columns
		display.spacing = spec.spacing
		display.build_surface = not bool(spec.get("counter", false))
		display.owned_check = _owns
		var at: Vector3 = anchor.to_global(spec.at)
		var ground: float = at.y
		if display.build_surface:
			var query := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 2.0, at - Vector3.UP * 4.0, 1)
			var hit := anchor.get_world_3d().direct_space_state.intersect_ray(query)
			if hit.is_empty(): display.free(); continue   # terrain collision not streamed yet
			ground = (hit.position as Vector3).y
			at.y = ground + .9
		display.top_level = true
		anchor.add_child(display)
		display.global_transform = Transform3D(Basis(Vector3.UP, anchor.global_rotation.y + float(spec.get("turn", 0.0))), at)
		for surface: Transform3D in spec.get("surfaces", []):
			display.slot_transforms.append(surface)
		var valid_mounts := true
		for path: String in spec.get("mounts", []):
			var mount := anchor.get_node_or_null(path) as Node3D
			if mount == null:
				valid_mounts = false; break
			display.slot_transforms.append(display.global_transform.affine_inverse() * mount.global_transform.orthonormalized())
		if not valid_mounts:
			display.free(); continue # The owning interior has not installed its shelf yet.
		if _stock.has(spec.id): display.restore_stock(_stock[spec.id])
		display.stock_changed.connect(_remember)
		_displays[spec.id] = display
		display.populate()
		if display.build_surface:
			_legs(display, ground)
		built += 1
		if _trace_startup:
			print("STOCK_STARTUP_DISPLAY ",JSON.stringify({"owner":"shop","id":spec.id,"ms":float(Time.get_ticks_usec()-display_started)/1000.0,"items":display._items.size(),"physics_frame":Engine.get_physics_frames()}))
	if _trace_startup and (not _traced_place or built > 0):
		_traced_place = true
		print("STOCK_STARTUP_PASS ",JSON.stringify({"owner":"shop","ms":float(Time.get_ticks_usec()-started)/1000.0,"new_displays":built,"physics_frame":Engine.get_physics_frames(),"loading_cover":game.has_node("LoadingCover")}))

## Whether Anon keeps this human garment in his wardrobe already (clothing_profile.gd owned).
func _owns(id: String) -> bool:
	var inventory: Variant = game.get("inventory") if is_instance_valid(game) else null
	var clothing: Variant = (inventory as Node).get("clothing") if is_instance_valid(inventory) and inventory is Node else null
	return clothing is RefCounted and (clothing as RefCounted).call("owns", id) == true

## Four legs under the table, to the ground.
func _legs(display: Node3D, ground: float) -> void:
	var surface: StaticBody3D = display.get_node_or_null("ShopDisplaySurface")
	if surface == null: return
	var size: Vector3 = ((surface.get_child(0) as CollisionShape3D).shape as BoxShape3D).size
	for x: float in [-1.0, 1.0]:
		for z: float in [-1.0, 1.0]:
			var foot: Vector3 = surface.global_transform * Vector3(x * (size.x * 0.5 - 0.06), 0, z * (size.z * 0.5 - 0.06))
			var leg := MeshInstance3D.new(); var mesh := BoxMesh.new()
			mesh.size = Vector3(0.05, foot.y - ground, 0.05)
			var material := StandardMaterial3D.new(); material.albedo_color = Color("795836"); mesh.material = material
			leg.mesh = mesh; leg.top_level = true; display.add_child(leg)
			leg.global_position = Vector3(foot.x, (foot.y + ground) * 0.5, foot.z)

func _remember(state: Dictionary) -> void:
	_stock[str(state.display_id)] = state.duplicate(true)
	if not _restocking: stock_changed.emit(snapshot())

## Every shop refills once a day at 06:00: these tables and the food stalls.
func _restock_check() -> void:
	var clock := get_node_or_null("/root/TimeOfDay")
	if clock == null: return
	# The latest elapsed dawn can be yesterday's when sleep skips whole days.
	var refill_day := int(clock.day) if float(clock.hours) >= RESTOCK_HOUR else int(clock.day) - 1
	if not _restock_initialized:
		# Fresh games and legacy snapshots without a boundary keep current stock.
		restocked_day = refill_day
		_restock_initialized = true
		return
	if refill_day <= restocked_day: return
	restocked_day = refill_day
	# The pony economy (world/mechanics/market/market.gd, P7): keepers refill only the slots they
	# pay for (or have supply for). Without the hub's market (fixtures) everything refills as before.
	var hub: Node = get_tree().get_first_node_in_group("mechanics") if is_inside_tree() else null
	var market: Variant = hub.get("market") if hub != null else null
	var plan: Variant = (market as Node).call("plan_restock") if is_instance_valid(market) and market is Node and (market as Node).has_method("economy_on") and bool((market as Node).call("economy_on")) else null
	_restocking = true
	var food: Node = game.get("food_world")
	if plan is Dictionary:
		for display: Variant in _displays.values():
			if is_instance_valid(display): display.restock_keys((plan as Dictionary).get(str(display.display_id), []))
		for key: String in _stock:
			var refill: Array = (plan as Dictionary).get(key, [])
			_stock[key].taken = (_stock[key].taken as Array).filter(func(taken: Variant) -> bool: return not taken in refill)
		if is_instance_valid(food) and food.has_method("restock_keys"): food.restock_keys(plan)
	else:
		for display: Variant in _displays.values():
			if is_instance_valid(display): display.restock()
		for key: String in _stock: _stock[key].taken = []
		if is_instance_valid(food) and food.has_method("restock"): food.restock()
	_restocking = false
	stock_changed.emit(snapshot())
	print("[shops] restocked for day ", refill_day)

func snapshot() -> Dictionary:
	return {"version": 1, "displays": _stock.duplicate(true), "restocked_day": restocked_day}

static func valid_snapshot(value: Variant) -> bool:
	if not value is Dictionary or value.get("version") != 1 or not value.get("displays") is Dictionary: return false
	var day: Variant = value.get("restocked_day", -1)
	if not (day is int or day is float) or not is_finite(float(day)) or float(day) < -1 or floorf(float(day)) != float(day): return false
	if value.displays.size() > 256: return false
	for id: Variant in value.displays:
		var stock: Variant = value.displays[id]
		if not id is String or id.is_empty() or not stock is Dictionary: return false
		if stock.get("display_id") != id or not stock.get("taken") is Array or stock.taken.size() > 256: return false
		for key: Variant in stock.taken:
			if not key is String or key.is_empty() or key.length() > 256: return false
	return true

func restore_state(value: Variant) -> bool:
	if not valid_snapshot(value): return false
	_stock = (value.displays as Dictionary).duplicate(true)
	restocked_day = int(value.get("restocked_day", -1))
	# -1 is a real boundary before day zero's dawn, not an unknown legacy date.
	_restock_initialized = value.has("restocked_day")
	return true
