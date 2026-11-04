extends RefCounted
## Food-only bridge into the existing briefcase's ownership and physical hand paths.
const CATALOG: Script = preload("res://world/food/food_catalog.gd")
const STORE: Script = preload("res://world/inventory/inventory_store.gd")
const PLAYER_MOUTH: Script = preload("res://player/player_mouth.gd")
const SFX: Script = preload("res://world/audio/interaction_sounds.gd")
const LEDGER: Script = preload("res://world/mechanics/ledger.gd")
const MARKET: Script = preload("res://world/mechanics/market/market.gd")
const TIDY: Script = preload("res://world/inventory/loose_tidy.gd")
const SHOP_PURCHASE: Script = preload("res://world/shop/shop_purchase.gd")
const GRASP_REACH: float = 0.16
const EAT_SECONDS: float = 1.35
const CUPCAKE_BITE_SECONDS: float = EAT_SECONDS / 3.0
## Cups must lean at least ~18 degrees to drink in VR; desktop tips them 40 degrees.
const DRINK_TILT_COS: float = 0.95
const DESKTOP_DRINK_TILT: float = 0.7
static var _bounds: Dictionary = {}

static func has(id: String) -> bool:
	return CATALOG.has(id)

static func hold_local(id: String) -> Transform3D:
	id = CATALOG.IDENTITY.canonical(id)
	if id == "carrot": return Transform3D(Basis.IDENTITY, Vector3(0, .025, -.025))
	var entry: Dictionary = CATALOG.definition(id)
	var size: Array = entry.get("size_m", [0.15, 0.15, 0.15])
	return Transform3D(Basis.IDENTITY, Vector3(0.0, -0.02, -float(size[2]) * 0.5 - 0.035))

static func configure(body: RigidBody3D, visual: Node3D, collision: CollisionShape3D) -> void:
	var id: String = str(body.get_meta("item_id", ""))
	visual.configure_body(body, collision)
	body.mass = float(CATALOG.definition(id).get("mass", 0.15))
	_bounds[id] = body.get_meta("food_bounds")

static func item_bounds(id: String) -> AABB:
	if not _bounds.has(id):
		var visual: Node3D = CATALOG.scene(id).instantiate()
		visual.prepare()
		_bounds[id] = visual.bounds
		visual.free()
	return _bounds[id]

static func rest_height(id: String, basis: Basis) -> float:
	var bounds := item_bounds(id)
	var rotated: AABB = Transform3D(basis, Vector3.ZERO) * bounds
	return -rotated.position.y + 0.008

static func contact(item: Node3D, from: Vector3) -> Vector3:
	var bounds: AABB = item.get_meta("food_bounds", AABB(Vector3.ONE * -0.04, Vector3.ONE * 0.08))
	return item.to_global(item.to_local(from).clamp(bounds.position, bounds.end))

static func clear_reach(item: RigidBody3D, from: Vector3, reach: float) -> bool:
	if not from.is_finite():
		return false
	var to: Vector3 = contact(item, from)
	if from.distance_to(to) > reach:
		return false
	if from.distance_squared_to(to) < 0.00000001:
		to += Vector3.UP * 0.001
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to, 1 | (1 << 17), [item.get_rid()])
	query.hit_from_inside = true
	query.hit_back_faces = true
	return item.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

static func near_distance(item: RigidBody3D, from: Vector3) -> float:
	return from.distance_to(contact(item, from)) if clear_reach(item, from, GRASP_REACH) else INF

static func take_nearby(inventory: Node, side: String, pose: Transform3D) -> bool:
	var nearest: RigidBody3D
	var distance: float = GRASP_REACH
	for item: Node in inventory.get_tree().get_nodes_in_group("world_food"):
		if not item is RigidBody3D:
			continue
		var candidate: float = near_distance(item, pose.origin)
		if candidate < distance:
			nearest = item
			distance = candidate
	return take_world(inventory, side, nearest, pose) if nearest != null else false

static func take_world(inventory: Node, side: String, item: RigidBody3D, pose: Transform3D) -> bool:
	if not is_instance_valid(item) or not item.is_in_group("world_food") or bool(item.get_meta("food_claiming", false)):
		return false
	if not pose.is_finite() or inventory.hand_busy(side) or inventory.held.has(side):
		return false
	if is_instance_valid(inventory.player_body) and "controls_locked" in inventory.player_body and inventory.player_body.controls_locked:
		return false
	var id: String = CATALOG.IDENTITY.canonical(str(item.get_meta("item_id", "")))
	if not has(id) or not clear_reach(item, pose.origin, 2.5 if side == "desktop" else GRASP_REACH):
		return false
	# The loose-item cap used to refuse food silently: buying did nothing (thread report 2026-11-03).
	# An empty mug or photo left lying about makes room first (world/inventory/loose_tidy.gd).
	if not TIDY.make_room(inventory):
		SHOP_PURCHASE._say(inventory, TIDY.full_text(inventory))
		return false
	var store: RefCounted = inventory.inventory
	var price: int = CATALOG.price_bits(id) if bool(item.get_meta("food_for_sale", false)) else 0
	# A keeper's live [sell] offer on this portion (world/mechanics/market/market.gd) is its price now.
	if price > 0: price = int(MARKET.live_price(inventory, _display_id(item), id, price))
	if store.bits < price:
		store.last_error = "insufficient funds!"
		if inventory.has_method("_error"): inventory._error()
		return false
	var slot: int = STORE._place(store.slots, id, -1)
	if slot < 0:
		SHOP_PURCHASE._say(inventory, "No room in your briefcase.")
		return false
	# One persisted transaction, rather than grant() then take(): a failed write
	# never removes the displayed portion or duplicates it into the briefcase.
	var token: String = "food_%d_%d" % [Time.get_ticks_usec(), item.get_instance_id()]
	var checked: Dictionary = store.loans.duplicate(true)
	checked[token] = {"id": id, "slot": slot}
	# A free portion can be set down and picked up again after completed bites. Keep those
	# bites on its new loan too, so a subsequent stash/reload cannot regrow the eaten portion.
	var bites: int = clampi(int(item.get_meta("food_bites", 0)), 0, STORE.MAX_BITES)
	if bites > 0: checked[token]["bites"] = bites
	item.set_meta("food_claiming", true)
	# A sold portion pays its shop's keeper in the same commit (world/mechanics/ledger.gd); free
	# portions and food without a display credit nobody, as before.
	var display_id: String = _display_id(item) if price > 0 else ""
	if not LEDGER.commit_purchase(inventory, store.slots, checked, price, display_id, id):
		item.remove_meta("food_claiming")
		return false
	item.remove_from_group("world_food")
	item.remove_meta("food_claiming")
	item.set_meta("token", token)
	item.set_meta("item_id", id)
	item.reparent(inventory, true)
	item.freeze = true
	item.linear_velocity = Vector3.ZERO
	item.angular_velocity = Vector3.ZERO
	item.set_meta("hold_offset", hold_local(id))
	item.set_meta("hold_from", item.global_transform)
	item.set_meta("hold_blend", 0.0)
	# A hand only holds a free thing: unless it goes onto a wrist slot or into the open briefcase,
	# letting go gives it back to the world (dev 2026-10-01). Bought goods are already paid for.
	if side != "desktop" and price == 0: item.set_meta("world_pick", true)
	inventory.loose[token] = item
	inventory.held[side] = item
	inventory._track.erase(side)
	inventory._claim(side, true)
	inventory._refresh_holding()
	if inventory.has_method("_clear_purchase_error"): inventory._clear_purchase_error()
	inventory._haptic(side)
	if inventory.has_method("_play_item_pickup"):inventory._play_item_pickup(item)
	if price > 0: SFX.play_purchase(item)
	var visual: Node = item.get_meta("food_visual")
	visual.acquired.emit()
	return true

## The food display (world/food/food_display.gd) a stocked portion sits on: its spawn parent.
static func _display_id(item: Node) -> String:
	var parent: Node = item.get_parent()
	var found: Variant = parent.get("display_id") if is_instance_valid(parent) else null
	return str(found) if found is String else ""

## A portion restored from the case, a drop or a save shows its completed bites again.
static func restore_bites(item: RigidBody3D, bites: int) -> void:
	if bites <= 0 or not item.has_meta("food_visual"): return
	var visual: Node3D = item.get_meta("food_visual")
	item.set_meta("food_bites", bites)
	visual.set_bite_stage(bites)
	visual.configure_body(item, item.get_child(0) as CollisionShape3D)

static func mouth_near(item: RigidBody3D, mouth: Vector3) -> bool:
	var visual: Node3D = item.get_meta("food_visual", null)
	if visual == null:
		return false
	if visual.to_global(visual.mouth_local()).distance_to(mouth) >= 0.10:
		return false
	# A drink is tipped to the lips (dev 2026-10-14 cider mug: "hold, tilt to drink"); an
	# upright cup held at the chin does not pour.
	return not is_drink(str(item.get_meta("item_id", ""))) or item.global_basis.y.normalized().dot(Vector3.UP) < DRINK_TILT_COS

static func is_drink(id: String) -> bool:
	return CATALOG.has(id) and bool(CATALOG.definition(id).get("drink", false)) and CATALOG.can_consume(id)

static func desktop_raise(item: RigidBody3D, camera: Camera3D, eating: bool, delta: float) -> void:
	var id: String = str(item.get_meta("item_id", ""))
	var progress: float = float(item.get_meta("food_raise", 0.0))
	progress = move_toward(progress, 1.0 if eating and CATALOG.can_consume(id) else 0.0, delta * 4.0)
	item.set_meta("food_raise", progress)
	if progress <= 0.0:
		return
	var visual: Node3D = item.get_meta("food_visual")
	# A drink tips toward the face as it rises (the hold pose is set fresh every frame).
	if is_drink(id):
		item.global_basis = Basis(camera.global_basis.x, DESKTOP_DRINK_TILT * smoothstep(0.0, 1.0, progress)) * item.global_basis
	# The mouth the food rises to: human Anon's below his eyes, or AnonPony's own muzzle.
	var mouth: Vector3 = PLAYER_MOUTH.point(camera)
	var destination: Vector3 = mouth - item.global_basis * visual.mouth_local()
	item.global_position = item.global_position.lerp(destination, smoothstep(0.0, 1.0, progress))

static func eat_tick(inventory: Node, side: String, item: RigidBody3D, delta: float, near: bool) -> bool:
	var id: String = str(item.get_meta("item_id", ""))
	if not CATALOG.can_consume(id) or not near:
		inventory._eat_time.erase(side)
		return false
	var cupcake: bool = CATALOG.slug(id) in ["cupcake", "strawberry-cinnamon-cilantro-cupcake"]
	var bites: int = int(item.get_meta("food_bites", 0)) if cupcake else 0
	# Pausing discards only the incomplete bite. Completed visual bites stay on this portion.
	var elapsed: float = float(inventory._eat_time.get(side, bites * CUPCAKE_BITE_SECONDS)) + delta
	inventory._eat_time[side] = elapsed
	if cupcake:
		var completed: int = mini(2, floori((elapsed + 0.00001) / CUPCAKE_BITE_SECONDS))
		while bites < completed:
			# A refused durable bite cannot change the portion's visual state.
			if not inventory.inventory.set_bites(str(item.get_meta("token", "")), bites + 1):return false
			bites += 1
			item.set_meta("food_bites", bites)
			var bite_visual: Node3D = item.get_meta("food_visual")
			bite_visual.set_bite_stage(bites)
			bite_visual.configure_body(item, item.get_child(0) as CollisionShape3D)
			# Saved at once, so stowing, dropping or reloading keeps the completed bites.
			inventory._refresh_holding()
			inventory._haptic(side)
			if inventory.has_method("_play_food_use"):inventory._play_food_use(id,inventory._mouth())
	if elapsed < EAT_SECONDS:
		return false
	var token: String = str(item.get_meta("token", ""))
	var store: RefCounted = inventory.inventory
	if not store.loans.has(token):
		return false
	var empty: String = CATALOG.empty_id(id)
	if empty.is_empty():
		if not store.consume(token):
			return false
	else:
		if not store.replace_held(token, empty):
			return false
	inventory._eat_time.erase(side)
	if cupcake: item.set_meta("food_bites", 3)
	inventory._haptic(side)
	# Hunger and cider (world/life/player_needs.gd).
	inventory.get_tree().call_group("player_needs", "ate", id)
	if inventory.has_method("_play_food_use"):inventory._play_food_use(id,inventory._mouth())
	if not empty.is_empty():
		# The loan now owns an empty vessel, including after drop, store or reload.
		item.set_meta("item_id", empty)
		var visual: Node3D = item.get_meta("food_visual")
		visual.food_id = empty
		visual.show_empty()
		configure(item, visual, item.get_child(0) as CollisionShape3D)
		inventory._refresh_holding()
		return false
	inventory.held.erase(side)
	inventory.loose.erase(token)
	inventory._track.erase(side)
	inventory._claim(side, false)
	item.queue_free()
	inventory._refresh_holding()
	return true
