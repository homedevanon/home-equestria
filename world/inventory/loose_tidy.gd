extends RefCounted
## Room for one more of Anon's things out of the briefcase. At most MAX_LOOSE (24) of his things
## may be out of it at once (briefcase_inventory.gd); empty cider mugs and photos he set down and
## forgot counted too, and buying then did nothing (thread report 2026-11-03, post 43683741).
## At the cap, the discarded leftover lying furthest from him goes back into the briefcase by
## itself, exactly as if he had stashed it: an empty food container (cider mug, jam jar) or a
## photo set down on the ground. Nothing is destroyed, and nothing else is moved: a photo hung at
## home, a laid-out blanket, an open easel, fish and goods he set down stay where they are.
const STORE := preload("res://world/inventory/inventory_store.gd")
const CATALOG := preload("res://world/inventory/item_catalog.gd")
const FOOD := preload("res://world/food/food_catalog.gd")
const PAINTINGS := preload("res://world/painting/painting_registry.gd")

## True when another thing may come out of the briefcase now (tidying one leftover if needed).
static func make_room(inventory: Node) -> bool:
	var store: RefCounted = inventory.get("inventory")
	if store == null: return false
	var loans: Dictionary = store.get("loans")
	if loans.size() < int(inventory.MAX_LOOSE): return true
	var camera: Variant = inventory.get("camera")
	var head: Vector3 = (camera as Camera3D).global_position if camera is Camera3D and is_instance_valid(camera) else Vector3.INF
	var bodies: Dictionary = inventory.get("loose")
	var in_hand: Array = (inventory.get("held") as Dictionary).values()
	var best := ""
	var best_distance := -1.0
	for token: String in loans:
		var loan: Dictionary = loans[token]
		if not leftover(loan): continue
		var body: Variant = bodies.get(token)
		if body in in_hand: continue
		var at: Vector3 = (body as Node3D).global_position if body is Node3D and is_instance_valid(body) else STORE.decode_pose(loan.world_transform).origin
		var distance: float = at.distance_to(head) if head.is_finite() and at.is_finite() else 0.0
		if distance > best_distance:
			best = token; best_distance = distance
	if best.is_empty(): return false
	var id := str(loans[best].get("id", ""))
	if not bool(store.call("put", best)): return false
	var tidied: Variant = bodies.get(best)
	bodies.erase(best)
	if tidied is Node and is_instance_valid(tidied): (tidied as Node).queue_free()
	print("[inventory] put a %s left lying about back in the briefcase to make room" % id)
	return true

## The hotbar line when nothing could be tidied (shop_purchase.gd _say, like its other refusals).
static func full_text(inventory: Node) -> String:
	return "%d of your things are out of the briefcase, the most there can be. Put some away first." % int(inventory.MAX_LOOSE)

## The hotbar line when a thing from an activity (a catch, a painting, a station's output) could
## not be placed (briefcase_drops.gd spawn_owned_drop): too many things out, or no briefcase slot.
static func not_placed_text(inventory: Node, id: String, loose_full: bool) -> String:
	var name := str(CATALOG.definition(id).get("name", ""))
	if name.is_empty(): name = "It"
	if loose_full:
		return "%s could not be placed: %d of your things are out of the briefcase, the most there can be. Put some away first." % [name, int(inventory.MAX_LOOSE)]
	return "%s could not be placed: your briefcase is full. Make room first." % name

## A discarded leftover lying in the world: an empty food container or a photo, set down (not
## held, worn, hung at home, laid out or standing open).
static func leftover(loan: Dictionary) -> bool:
	if not STORE.valid_pose(loan.get("world_transform")) or bool(loan.get("equipped", false)): return false
	for key: String in ["furnishing_home", "picnic_deployed", "easel_open"]:
		if loan.has(key): return false
	var id := CATALOG.canonical(str(loan.get("id", "")))
	return FOOD.is_empty_container(id) or (CATALOG.is_art(id) and PAINTINGS.is_photo(PAINTINGS.art_id(id)))
