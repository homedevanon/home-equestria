extends Node3D
## What a shop good looks like in the hand or on a shelf (world/shop/shop_items.gd): household
## models scaled to real size and set on their base, or a folded stack of clothes in the
## outfit's own colours. `bounds` is the local box the inventory uses for its collision shape.
const ITEMS := preload("res://world/shop/shop_items.gd")
const PROFILE := preload("res://world/customization/clothing_profile.gd")
@export var item_id := ""
var bounds := AABB(Vector3(-0.1, 0, -0.1), Vector3(0.2, 0.1, 0.2))

func _ready() -> void:
	if get_child_count() > 0: return
	if item_id.begins_with("goods:"): _goods()
	elif item_id.begins_with("outfit:"): _outfit()
	elif item_id.begins_with("wear:"): _wear()
	elif item_id == "equipment:wing-sandals":
		var pair := preload("res://world/customization/wing_sandals.gd").display()
		add_child(pair)
		var measured := _measure(pair, self)
		pair.position = Vector3(-measured.get_center().x, -measured.position.y, -measured.get_center().z)
		bounds = AABB(Vector3(-measured.size.x * 0.5, 0, -measured.size.z * 0.5), measured.size)

func _goods() -> void:
	if ITEMS.CIDER.is_keg(item_id):
		bounds = ITEMS.CIDER.build_visual(self); return
	if item_id == "goods:game-board":
		bounds = load("res://world/minigames/board_games/board_fold.gd").build_visual(self); return
	if ITEMS.SAPLING.is_sapling(item_id):
		bounds = ITEMS.SAPLING.build_visual(self); return
	var model := item_id.substr(6)
	var path: String = ITEMS.GOODS_MODELS.get(model, ITEMS.HOUSEHOLD % model)
	if not ResourceLoader.exists(path): return
	var visual: Node3D = (load(path) as PackedScene).instantiate()
	add_child(visual)
	# The inventory's single body owns collision. Reused placed-world prefabs may
	# contain their own StaticBody, which must not remain solid while being carried.
	for body: CollisionObject3D in visual.find_children("*", "CollisionObject3D", true, false):
		body.collision_layer = 0
		body.collision_mask = 0
	var box := _measure(visual, visual)
	var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	var factor := float(ITEMS.GOODS[model][1]) / maxf(longest, 0.001)
	visual.scale = Vector3.ONE * factor
	visual.position = Vector3(-box.get_center().x, -box.position.y, -box.get_center().z) * factor
	bounds = AABB(Vector3(-box.size.x * 0.5, 0, -box.size.z * 0.5) * factor, box.size * factor)
	for mesh: GeometryInstance3D in visual.find_children("*", "GeometryInstance3D", true, false):
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if longest * factor < 0.4 else GeometryInstance3D.SHADOW_CASTING_SETTING_ON

func _measure(node: Node, origin: Node3D) -> AABB:
	var box := AABB()
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		box = (origin.global_transform.affine_inverse() * (node as Node3D).global_transform) * (node as MeshInstance3D).get_aabb() if origin.is_inside_tree() else (node as MeshInstance3D).transform * (node as MeshInstance3D).get_aabb()
	for child: Node in node.get_children():
		var sub := _measure(child, origin)
		if sub.size != Vector3.ZERO: box = sub if box.size == Vector3.ZERO else box.merge(sub)
	return box

## A pony accessory as it will be worn (pony_wardrobe.gd builders), set on its base.
func _wear() -> void:
	var WARDROBE: Script = load("res://world/characters/accessories/pony_wardrobe.gd")
	var parts := item_id.split(":")
	var colour: Color = WARDROBE.COLOURS[int(parts[2]) % WARDROBE.COLOURS.size()]
	var piece: Node3D
	if WARDROBE.FITTED.has(parts[1]):
		piece = WARDROBE.FITTED.display_fitted(parts[1])
	else:
		match parts[1]:
			"scarf": piece = WARDROBE._scarf(colour)
			"wizard_hat": piece = WARDROBE._wizard_hat(colour)
			"cape": piece = WARDROBE._cape(colour)
			_: piece = WARDROBE._sock(colour)
	add_child(piece)
	var box := _measure(piece, self)
	piece.position = Vector3(-box.get_center().x, -box.position.y, -box.get_center().z)
	bounds = AABB(Vector3(-box.size.x * 0.5, 0, -box.size.z * 0.5), box.size)

## Folded jacket over folded trousers, with the tie laid on top.
func _outfit() -> void:
	var parts: Dictionary = ITEMS.outfit(item_id)
	var layers := [["pants", 0.030, Vector3(0.30, 0.03, 0.24)], ["suit", 0.062, Vector3(0.31, 0.034, 0.25)], ["shirt", 0.085, Vector3(0.24, 0.012, 0.16)], ["tie", 0.094, Vector3(0.035, 0.006, 0.17)]]
	for layer: Array in layers:
		var part: String = layer[0]
		var colour_index: int = int(parts.get(part, {}).get("color", 0))
		var palette: Array = PROFILE.PALETTES[part]
		var colour := Color(str(palette[clampi(colour_index, 0, palette.size() - 1)]).get_slice(":", 1))
		var mesh := MeshInstance3D.new(); mesh.name = part.capitalize()
		var shape := BoxMesh.new(); shape.size = layer[2]
		var material := StandardMaterial3D.new(); material.albedo_color = colour; material.roughness = 0.95
		shape.material = material; mesh.mesh = shape
		mesh.position = Vector3(0, float(layer[1]) - float((layer[2] as Vector3).y) * 0.5, 0)
		add_child(mesh)
	bounds = AABB(Vector3(-0.155, 0, -0.125), Vector3(0.31, 0.1, 0.25))
