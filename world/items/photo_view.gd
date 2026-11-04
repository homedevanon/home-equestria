extends Node3D
## A print held up to look at (dev 2026-11-03: "allow me to click on photos and view the photos i've
## taken"). Desktop only: in a headset the hand simply brings the print to the face. A click holds
## the picture before the eyes, the wheel brings it closer (letter_sheet.gd zoom), the next click
## lowers it. Attached to the held print on first use.
const REGISTRY := preload("res://world/painting/painting_registry.gd")
const LETTER_TOOL := preload("res://world/letters/paper/letter_tool.gd")
const SHEET := preload("res://world/letters/paper/letter_sheet.gd")
const PICTURE := Vector2(0.21, 0.1575)
const ZOOM_EASE := 14.0

var item: Node3D
var _inventory: Node
var _quad: MeshInstance3D
var _goal: float = SHEET.READ_FAR
var _at: float = SHEET.READ_FAR

static func on(held_item: Node3D) -> Node3D:
	var tool := held_item.get_node_or_null("PhotoView") as Node3D
	if tool != null: return tool
	tool = (load("res://world/items/photo_view.gd") as GDScript).new()
	tool.name = "PhotoView"; tool.item = held_item
	held_item.add_child(tool)
	return tool

static func handles(held_item: Node) -> bool:
	if not is_instance_valid(held_item): return false
	var id := REGISTRY.art_id(str(held_item.get_meta("item_id", "")))
	return not id.is_empty() and REGISTRY.is_photo(id)

func _ready() -> void:
	set_process(false)

func viewing() -> bool:
	return is_instance_valid(_quad) and _quad.visible

func toggle(inventory: Node) -> void:
	_inventory = inventory
	if viewing():
		_quad.hide(); set_process(false); return
	if not is_instance_valid(_quad): _build()
	_at = SHEET.READ_FAR; _goal = SHEET.READ_FAR
	_quad.show()
	set_process(true)

func zoom(step: int) -> void:
	_goal = clampf(_goal - step * SHEET.ZOOM_STEP, SHEET.READ_NEAR, SHEET.READ_FAR)

func _build() -> void:
	_quad = MeshInstance3D.new(); _quad.name = "Picture"
	var mesh := QuadMesh.new(); mesh.size = PICTURE
	_quad.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var image := Image.load_from_file(REGISTRY.art_path(REGISTRY.art_id(str(item.get_meta("item_id", "")))))
	if image != null and not image.is_empty(): material.albedo_texture = ImageTexture.create_from_image(image)
	_quad.material_override = material
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.top_level = true
	add_child(_quad)

func _process(delta: float) -> void:
	var held: Variant = _inventory.get("held") if is_instance_valid(_inventory) else null
	var eye: Camera3D = _inventory.get("camera") if is_instance_valid(_inventory) else null
	if not held is Dictionary or not (held as Dictionary).values().has(item) or eye == null:
		_quad.hide(); set_process(false); return
	_at = lerpf(_at, _goal, 1.0 - exp(-delta * ZOOM_EASE))
	_quad.global_transform = eye.global_transform * Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -_at))
