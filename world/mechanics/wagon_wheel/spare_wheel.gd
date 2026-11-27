extends Node3D
## The spare cart wheel leaning on the back wall inside the Sweet Apple Acres barn while Applejack's
## wagon is broken (wagon_wheel.gd places it, hides it while Anon has a wheel of his own and frees it
## once the wagon is mended). Picked up the way the orchard's loose apples are
## (world/inventory/harvest_pickup.gd): VR, reach for it and squeeze the grip (grab_providers, so the
## hand outlines it); desktop, look at it with a free hand and click or press E (the hint comes from
## interaction_hint_sources). Taking it grants "food:cart-wheel" into the briefcase and the hand
## (world/mechanics/hand_over.gd).
const HELD := preload("res://world/mechanics/stations/held_items.gd")
const COOKING := preload("res://world/cooking/cooking_input.gd")
const MODEL := "res://world/props/apple_cart/cart_wheel.scn"
const SHOW_DISTANCE := 160.0
const DESKTOP_REACH := 2.4
const DESKTOP_AIM := 0.45
const VR_REACH := 0.5
## Its middle, from the bottom of the rim where it stands on the floor.
const MIDDLE := Vector3(0.0, 0.5, 0.0)

## The grab router (world/inventory/grab_router.gd) only asks providers whose `inventory` is the
## player's; the wagon wheel keeps it current.
var inventory: Node
var wheel: Node   # wagon_wheel.gd

func _ready() -> void:
	name = "SpareWheel"
	add_to_group("grab_providers")
	add_to_group("interaction_hint_sources")
	var scene := load(MODEL) as PackedScene
	if scene == null:
		push_warning("[wagon_wheel] missing model " + MODEL)
		return
	var model: Node3D = scene.instantiate()
	model.name = "CartWheel"
	wheel.far_fade(model, SHOW_DISTANCE)
	add_child(model)

func point() -> Vector3:
	return global_transform * MIDDLE

func _available() -> bool:
	return is_visible_in_tree() and is_instance_valid(inventory) and is_instance_valid(wheel) and COOKING.allowed(inventory)

func _desktop() -> bool:
	return is_instance_valid(inventory) and bool(inventory.get("_desktop"))

## Desktop: a free hand looking at it.
func desktop_offer() -> Dictionary:
	if not _desktop() or not _available() or bool(inventory.hand_busy("desktop")): return {}
	if not HELD.looking_at(inventory, point(), DESKTOP_AIM, DESKTOP_REACH): return {}
	return {"target": self, "point": point(), "text": "Click / E · Pick up the cart wheel"}

func interaction_hint() -> Dictionary:
	return desktop_offer()

func _unhandled_input(event: InputEvent) -> void:
	var pressed: bool = event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	pressed = pressed or (event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E)
	if not pressed or desktop_offer().is_empty(): return
	if bool(wheel.take_spare("desktop")): get_viewport().set_input_as_handled()

# --- VR: reach for it and squeeze the grip --------------------------------------------------------

func grab_offer(side: String, sample: Dictionary) -> Dictionary:
	if _desktop() or not _available() or sample.get("active", false) != true: return {}
	var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	var from: Variant = sample.get("grip_position", pose.origin)
	if not from is Vector3 or not (from as Vector3).is_finite(): return {}
	var distance := (from as Vector3).distance_to(point())
	if distance >= VR_REACH: return {}
	return {"target": self, "point": point(), "distance": distance, "text": side.capitalize() + " grip · Pick up the cart wheel"}

func grab_take(side: String, _offer: Dictionary, _sample: Dictionary) -> bool:
	return bool(wheel.take_spare(side))
