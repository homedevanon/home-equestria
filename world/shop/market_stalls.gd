extends Node3D
## Authored replacements share mesh/collision resources; no per-frame work or mesh builds.
const PRODUCE_MESH: Mesh = preload("res://world/shop/stalls/produce_mesh.res")
const PRODUCE_COLLISION: Shape3D = preload("res://world/shop/stalls/produce_collision.res")
const BAKERY_MESH: Mesh = preload("res://world/shop/stalls/bakery_mesh.res")
const BAKERY_COLLISION: Shape3D = preload("res://world/shop/stalls/bakery_collision.res")
const PANTRY_MESH: Mesh = preload("res://world/shop/stalls/pantry_mesh.res")
const PANTRY_COLLISION: Shape3D = preload("res://world/shop/stalls/pantry_collision.res")
const GOODS_MESH: Mesh = preload("res://world/shop/stalls/goods_mesh.res")
const GOODS_COLLISION: Shape3D = preload("res://world/shop/stalls/goods_collision.res")
const FURNITURE_MESH: Mesh = preload("res://world/shop/stalls/furniture_mesh.res")
const FURNITURE_COLLISION: Shape3D = preload("res://world/shop/stalls/furniture_collision.res")

func _ready() -> void:
	for path: String in ["Town/Market/kiosk_01_02", "East/Fair/kiosk_01_01"]:
		_install(path, PRODUCE_MESH, PRODUCE_COLLISION)
	for path: String in ["Town/Market/kiosk_02_02", "East/Fair/kiosk_02_01"]:
		_install(path, BAKERY_MESH, BAKERY_COLLISION)
	_install("Town/Market/cloudsdale_hotdogstand_02", PANTRY_MESH, PANTRY_COLLISION)
	_install("Town/Market/tent_friagram_lightbrown_01", GOODS_MESH, GOODS_COLLISION)
	_install("Town/Market/tent_friagram_pinkish_01", FURNITURE_MESH, FURNITURE_COLLISION)
	# The original tents faced away from the market, leaving merchandise at their backs.
	for path: String in ["Town/Market/tent_friagram_lightbrown_01", "Town/Market/tent_friagram_pinkish_01"]:
		var tent: Node3D = get_node_or_null(path)
		if tent != null:
			tent.rotation.y = 0.0
	# The fixed rubbish bins in the market and at Anon's door (player board card 69).
	var bins := preload("res://world/props/rubbish_bins.gd").new()
	bins.name = "RubbishBins"
	add_child(bins)

func _install(path: String, mesh: Mesh, shape: Shape3D) -> void:
	var stall: Node3D = get_node_or_null(path)
	if stall == null:
		return
	var visual: MeshInstance3D = stall.get_node("Mesh1")
	var collision: CollisionShape3D = stall.get_node("Solid").get_child(0)
	visual.mesh = mesh
	collision.shape = shape
	collision.transform = visual.transform
