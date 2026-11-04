extends Node3D
## The see-through copy of held furniture where it would go (dev 2026-11-03: "a green/red placing
## object type feature like they have in building games"): green when home_furnishing.gd would
## accept the spot, red when it would not, nothing when the aim is off every surface. Owned by the
## briefcase. It re-asks at CHECK_SECONDS, not every frame: plan() runs ray and shape queries.
const FURNISHING := preload("res://world/housing/home_furnishing.gd")
const CHECK_SECONDS := 0.05
const GOOD := Color(0.25, 0.95, 0.35, 0.45)
const BAD := Color(0.95, 0.2, 0.2, 0.45)

var ui: Node3D
var _good: StandardMaterial3D
var _bad: StandardMaterial3D
var _shown_item: Node3D
var _wait := 0.0

func setup(owner_ui: Node3D) -> void:
	ui = owner_ui
	top_level = true
	_good = _material(GOOD); _bad = _material(BAD)

static func _material(colour: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = colour
	return material

func _process(delta: float) -> void:
	_wait -= delta
	if _wait > 0.0: return
	_wait = CHECK_SECONDS
	var pick := _pick()
	if pick.is_empty():
		visible = false
		return
	var item: Node3D = pick.target
	if item != _shown_item: _copy(item)
	var size := FURNISHING.size_of(item)
	transform = (pick.pose as Transform3D).scaled_local(Vector3.ONE * size)
	var material := _good if bool(pick.ok) else _bad
	for child: Node in get_children():
		(child as MeshInstance3D).material_override = material
	visible = true

func _pick() -> Dictionary:
	if not is_instance_valid(ui): return {}
	var sides: Array = ["desktop"] if bool(ui.get("_desktop")) else ["right", "left"]
	for side: String in sides:
		var pick := FURNISHING.plan(ui, side)
		if not pick.is_empty(): return pick
	return {}

## A mesh for every visible mesh of the item, in the item's own frame.
func _copy(item: Node3D) -> void:
	for child: Node in get_children():
		remove_child(child); child.queue_free()
	_shown_item = item
	var to_item := item.global_transform.affine_inverse()
	for node: Node in item.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if not mesh.is_visible_in_tree() or mesh.mesh == null: continue
		var copy := MeshInstance3D.new()
		copy.mesh = mesh.mesh
		copy.transform = to_item * mesh.global_transform
		copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(copy)
