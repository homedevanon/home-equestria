extends RefCounted
## What Anon holds, for the physical Sweet Apple Acres stations (P5 of
## docs/MECHANICS_ARCHITECTURE_2026_11_01.md, section 8: planting plot, cider press, stand keg).
## One place for the three questions every station asks: what is in this hand, is he looking at
## this point (desktop), and "use it up" (the item leaves his hand and his briefcase in one saved
## transaction, the same hand clean-up world/relationships/hand_feeding.gd does after feeding).
## `ui` is the briefcase inventory (world/inventory/briefcase_inventory.gd).

## The body in this hand (side "desktop", "left" or "right"), or null.
static func body(ui: Node, side: String) -> RigidBody3D:
	if not is_instance_valid(ui): return null
	var held: Variant = ui.get("held")
	var item: Variant = (held as Dictionary).get(side) if held is Dictionary else null
	return item as RigidBody3D if is_instance_valid(item) and item is RigidBody3D else null

## The catalogue id in this hand, or "".
static func id(ui: Node, side: String) -> String:
	var item := body(ui, side)
	return str(item.get_meta("item_id", "")) if item != null and item.has_meta("item_id") else ""

## The hand (or desktop view) point an item is offered from: the held body, else the hand pose.
static func point(ui: Node, side: String) -> Vector3:
	var item := body(ui, side)
	if item != null: return item.global_position
	if side == "desktop" or not ui.has_method("hand_sample"): return Vector3.INF
	var sample: Dictionary = ui.call("hand_sample", side)
	if not bool(sample.get("active", false)): return Vector3.INF
	var at: Variant = sample.get("grip_position", (sample.get("pose", Transform3D.IDENTITY) as Transform3D).origin)
	return at if at is Vector3 else Vector3.INF

## Desktop: the view's centre line passes within `radius` of `target`, no further than `reach`.
static func looking_at(ui: Node, target: Vector3, radius: float, reach := 3.0) -> bool:
	var camera: Variant = ui.get("camera") if is_instance_valid(ui) else null
	if not camera is Node3D or not is_instance_valid(camera) or not target.is_finite(): return false
	var eye: Vector3 = (camera as Node3D).global_position
	var ahead: Vector3 = -(camera as Node3D).global_basis.z
	var to := target - eye
	var along := to.dot(ahead)
	if along <= 0.05 or to.length() > reach: return false
	return (to - ahead * along).length() <= radius

## Uses up the held item: its loan ends in the store (one saved commit), then the hand lets go and
## the body is freed. False (and nothing changed) when the store refuses.
static func use_up(ui: Node, side: String) -> bool:
	var item := body(ui, side)
	if item == null: return false
	var store: Variant = ui.get("inventory")
	var token := str(item.get_meta("token", ""))
	if store == null or token.is_empty() or not (store.get("loans") as Dictionary).has(token): return false
	if not bool(store.call("consume", token)): return false
	(ui.get("held") as Dictionary).erase(side)
	var loose: Variant = ui.get("loose")
	if loose is Dictionary: (loose as Dictionary).erase(token)
	var track: Variant = ui.get("_track")
	if track is Dictionary: (track as Dictionary).erase(side)
	if ui.has_method("_claim"): ui.call("_claim", side, false)
	if ui.has_method("_haptic"): ui.call("_haptic", side)
	item.queue_free()
	if ui.has_method("_refresh_holding"): ui.call("_refresh_holding")
	return true

## A loose owned item (dropped or thrown, not in a hand) is used up: its loan ends and it is freed.
static func use_up_loose(ui: Node, item: RigidBody3D) -> bool:
	if not is_instance_valid(ui) or not is_instance_valid(item): return false
	var held: Variant = ui.get("held")
	if held is Dictionary and item in (held as Dictionary).values(): return false
	var store: Variant = ui.get("inventory")
	var token := str(item.get_meta("token", ""))
	if store == null or token.is_empty() or not (store.get("loans") as Dictionary).has(token): return false
	if not bool(store.call("consume", token)): return false
	var loose: Variant = ui.get("loose")
	if loose is Dictionary: (loose as Dictionary).erase(token)
	item.queue_free()
	return true
