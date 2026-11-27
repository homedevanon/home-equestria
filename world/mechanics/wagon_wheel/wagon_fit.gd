extends Node3D
## Where Anon fits the spare wheel on Applejack's broken apple wagon (wagon_wheel.gd): a station node
## (world/mechanics/stations/station_input.gd) at the wagon's middle, under the wagon, shown only
## while the broken cart is.
##   desktop: holding the wheel and looking at the wagon, a click (the briefcase's click chain hands
##            it to the nearest station node) or E fits it.
##   VR:      hold the wheel up to the wagon, within VR_FIT_REACH of its middle. Checked every
##            FIT_CHECK seconds, only while a hand holds a wheel (the wagon wheel switches it on).
const HELD := preload("res://world/mechanics/stations/held_items.gd")
const COOKING := preload("res://world/cooking/cooking_input.gd")
const GROUP := "mechanics_station_nodes"
## Desktop: the view's centre line within FIT_AIM of the wagon's middle, no further than FIT_REACH
## (station_input.gd only asks station nodes within its own REACH of the eye).
const FIT_REACH := 3.0
const FIT_AIM := 1.3
const VR_FIT_REACH := 1.6
## VR: how near a held wheel shows the hint.
const VR_HINT_REACH := 3.0
const FIT_CHECK := 0.2

var wheel: Node   # wagon_wheel.gd
var _check := 0.0

func _ready() -> void:
	name = "WheelFit"
	add_to_group(GROUP)
	set_physics_process(false)

func _ready_to_fit(ui: Node, side: String) -> bool:
	return is_instance_valid(wheel) and is_visible_in_tree() and bool(wheel.can_fit()) and bool(wheel.is_wheel(HELD.id(ui, side)))

func station_hint(ui: Node, side: String) -> Dictionary:
	if not _ready_to_fit(ui, side): return {}
	# The wagon is the target, so the hint's line of sight may end on its own collision; the broken
	# cart is what glows.
	var hint := {"target": get_parent_node_3d(), "point": global_position, "outline": wheel.broken_cart()}
	if side == "desktop":
		if not HELD.looking_at(ui, global_position, FIT_AIM, FIT_REACH): return {}
		hint["text"] = "Click / E · Fit the wheel"
		return hint
	var at := HELD.point(ui, side)
	if not at.is_finite() or at.distance_to(global_position) > VR_HINT_REACH: return {}
	hint["text"] = "Hold it to the wagon · Fit the wheel"
	return hint

func station_use(ui: Node, side: String, down: bool) -> bool:
	if not down or side != "desktop" or not _ready_to_fit(ui, side): return false
	if not HELD.looking_at(ui, global_position, FIT_AIM, FIT_REACH): return false
	return bool(wheel.fit(side))

## Desktop E does what the click does (the briefcase sends only clicks to station nodes).
func _unhandled_input(event: InputEvent) -> void:
	if not visible or not event is InputEventKey or not event.pressed or event.echo or (event as InputEventKey).physical_keycode != KEY_E: return
	var ui: Node = wheel.ui() if is_instance_valid(wheel) else null
	if ui == null or not bool(ui.get("_desktop")) or not COOKING.allowed(ui): return
	if station_use(ui, "desktop", true): get_viewport().set_input_as_handled()

func _physics_process(delta: float) -> void:
	_check -= delta
	if _check > 0.0: return
	_check = FIT_CHECK
	check_hands()

## VR: a held wheel near the wagon's middle is fitted. Switches the check off once no hand holds a
## wheel. True when it fitted one.
func check_hands() -> bool:
	var ui: Node = wheel.ui() if is_instance_valid(wheel) else null
	if ui == null or bool(ui.get("_desktop")) or not is_visible_in_tree():
		set_physics_process(false)
		return false
	var holding := false
	for side: String in ["left", "right"]:
		if not _ready_to_fit(ui, side): continue
		holding = true
		var item := HELD.body(ui, side)
		if item != null and item.global_position.distance_to(global_position) <= VR_FIT_REACH and COOKING.allowed(ui):
			return bool(wheel.fit(side))
	if not holding: set_physics_process(false)
	return false
