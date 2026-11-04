extends Node3D
const CURRENCY := preload("res://world/ui/currency.gd")
## Attach at a chosen counter/stall surface. Finite stock, no world scan or respawn timer.
signal stock_changed(state: Dictionary)
const CATALOG: Script = preload("res://world/food/food_catalog.gd")
const SPAWN: Script = preload("res://world/food/food_spawn.gd")
const MERGE: Script = preload("res://world/food/food_mesh_merge.gd")
## Pre-made food only (dev 2026-10-14: "nobody is gonna buy ... a bottom bun or top bun or
## tomato ... it just needs to be pre-made food items"). Preset names stay as the saved stall
## keys: "pantry" is now the market's hot-snack stand and "regional" the fair's treat stall.
## Removed shelf entries are listed in world/shop/archived_stock.json.
const PRESETS: Dictionary = {
	"restaurant": ["hayburger", "carrot-dog", "hay-fries", "daffodil-daisy-sandwich", "grass-pancakes", "sweet-carrot-pancakes", "spicy-flat-noodle-soup"],
	"produce": ["red-apple", "green-apple", "carrot", "strawberry", "buttered-corn"],
	"bakery": ["cupcake", "apple-fritter", "caramel-apple", "candy-apple", "rainbow-pie"],
	# Sugarcube Corner's second case (dev 2026-10-18: "add muffins to sugarcube corner + more pastries").
	"pastries": ["blueberry-muffin", "chocolate-chip-muffin", "banana-nut-muffin", "croissant", "cinnamon-roll", "cherry-danish", "sprinkle-donut", "chocolate-chip-cookie", "strawberry-cake-slice"],
	"drinks": ["sweet-apple-acres-cider", "sunflower-smoothie"],
	"pantry": ["carrot-dog", "hay-fries", "buttered-corn", "daffodil-daisy-sandwich"],
	"regional": ["buttered-corn", "caramel-apple", "candy-apple"],
	"celebration": ["apple-pie"],
	# Separate useful supplies; the ready-meal menus above keep their saved identities.
	"cooking": ["flour", "egg", "butter", "carrot", "mushroom", "spices"],
	"pony-feed": ["oats", "hay-bundle"],
}
## The stock before 2026-10-15, kept only so saved "taken" keys from older games still load
## (world/food/food_world.gd valid_snapshot); they are dropped on restore.
const LEGACY_PRESETS: Dictionary = {
	"restaurant": ["hayburger", "carrot-dog", "hay-fries", "daffodil-daisy-sandwich", "grass-pancakes", "sweet-carrot-pancakes", "spicy-flat-noodle-soup"],
	"produce": ["red-apple", "green-apple", "carrot", "strawberry", "blueberries", "raspberries", "cherries", "pear", "peach", "potato", "tomato", "lettuce", "corn", "mushroom", "oats", "hay-bundle"],
	"bakery": ["chimi-cherry-chonga", "cupcake", "strawberry-cinnamon-cilantro-cupcake", "spicy-rainbow", "rainbow-pie", "apple-fritter", "apple-pie", "caramel-apple", "candy-apple"],
	"drinks": ["sweet-apple-acres-cider", "sunflower-smoothie", "nectar"],
	"pantry": ["bread-loaf", "burger-bun-bottom", "burger-bun-top", "hay-patty", "cheese-slice", "tomato-slice", "lettuce-leaf", "zap-apple-jam", "flour", "egg", "butter", "spices"],
	"regional": ["crystal-berries", "crystal-corn", "edible-gems"],
	"celebration": ["marzipan-mascarpone-meringue-madness"],
}
@export_enum("restaurant", "produce", "bakery", "pastries", "drinks", "pantry", "regional", "celebration", "cooking", "pony-feed") var preset: String = "restaurant"
## A category printed on each physical price card, never a floating world label.
@export var category_label: String = ""
## Optional explicit food: IDs, in display order. Empty uses the chosen finite preset.
@export var item_ids: PackedStringArray = PackedStringArray()
@export_range(1, 4) var copies_per_item: int = 1
@export_range(1, 8) var columns: int = 4
@export var build_surface: bool = true
## Clear space beyond each food's bounds. Narrow counters may use closer columns.
@export var spacing_margin: Vector2 = Vector2(0.10, 0.18)
## Shop stock is paid by default. Complimentary/player-owned displays opt out explicitly.
@export var for_sale: bool = true
## Main can key snapshot()/restore_stock() by this stable authored location ID.
@export var display_id: String = ""
## Stock inside a shop room stops drawing with the shut room (food_mesh_merge.gd cap_indoor).
@export var indoor: bool = false
var _taken: Dictionary = {}
var _items: Dictionary = {}
var _populated: bool = false
var _surface_built: bool = false
var _cards: Dictionary = {}

func _ready() -> void:
	populate.call_deferred()

func selected_ids() -> Array[String]:
	var result: Array[String] = []
	if not item_ids.is_empty():
		for id: String in item_ids:
			if CATALOG.has(id):
				result.append(id)
	else:
		for slug: String in PRESETS.get(preset, []):
			result.append("food:" + slug)
	return result

func populate() -> void:
	if _populated or not is_inside_tree():
		return
	_populated = true
	var ids: Array[String] = selected_ids()
	if ids.is_empty():
		return
	var spacing: Vector2 = _spacing(ids)
	var spacing_x: float = spacing.x
	var spacing_z: float = spacing.y
	var count: int = ids.size() * clampi(copies_per_item, 1, 4)
	var width: int = mini(clampi(columns, 1, 8), count)
	var rows: int = ceili(float(count) / width)
	if build_surface and not _surface_built:
		_surface_built = true
		_make_surface(Vector3(width * spacing_x + 0.08, 0.06, rows * spacing_z + 0.08))
	for index: int in count:
		var id: String = ids[index / clampi(copies_per_item, 1, 4)]
		var key: String = "%d:%s" % [index, id]
		if _taken.has(key) or (_items.has(key) and is_instance_valid(_items[key])):
			continue
		var point: Vector3 = Vector3((float(index % width) - (width - 1) * 0.5) * spacing_x, 0.0, (float(index / width) - (rows - 1) * 0.5) * spacing_z)
		var surface: Transform3D = global_transform.orthonormalized() * Transform3D(Basis.IDENTITY, point)
		var item: RigidBody3D = SPAWN.spawn(self, id, surface, for_sale)
		if item == null:
			continue
		_items[key] = item
		var visual: Node = item.get_meta("food_visual")
		visual.acquired.connect(_on_acquired.bind(key))
		if indoor:
			MERGE.cap_indoor(visual, _interior_range())
			visual.acquired.connect(MERGE.uncap_indoor.bind(visual), CONNECT_ONE_SHOT)
		if not _cards.has(key):
			_cards[key] = _make_price_card(id, surface * Transform3D(Basis.IDENTITY, Vector3(0.0, 0.006, spacing_z * 0.5 - 0.05)))

## Metre footprint including the physical cards; used by authored shop table legs.
func surface_size() -> Vector3:
	var ids: Array[String] = selected_ids()
	if ids.is_empty():
		return Vector3.ZERO
	var spacing: Vector2 = _spacing(ids)
	var count: int = ids.size() * clampi(copies_per_item, 1, 4)
	var width: int = mini(clampi(columns, 1, 8), count)
	return Vector3(width * spacing.x + 0.08, 0.06, ceili(float(count) / width) * spacing.y + 0.08)

func _spacing(ids: Array[String]) -> Vector2:
	var spacing: Vector2 = Vector2(0.30, 0.30)
	for id: String in ids:
		var size: Array = CATALOG.definition(id).get("size_m", [0.20, 0.20, 0.20])
		spacing.x = maxf(spacing.x, float(size[0]) + spacing_margin.x)
		spacing.y = maxf(spacing.y, float(size[2]) + spacing_margin.y)
	return spacing

func _make_price_card(id: String, at: Transform3D) -> Label3D:
	var card: MeshInstance3D = MeshInstance3D.new()
	card.name = "FoodPriceCard"
	card.top_level = true
	card.transform = at
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = Vector3(0.25, 0.004, 0.09)
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = Color("eee1bd")
	material.roughness = 1.0
	mesh.material = material
	card.mesh = mesh
	var label: Label3D = Label3D.new()
	label.rotation.x = -PI * 0.5
	label.position.y = 0.0025
	label.font_size = 24
	label.pixel_size = 0.0006
	label.width = 380.0
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.outline_size = 0
	label.modulate = Color("30261b")
	CURRENCY.apply(label)
	label.text = str(CATALOG.definition(id).name) + "\n" + (CURRENCY.amount(CATALOG.price_bits(id)) if for_sale else "Complimentary")
	if not category_label.is_empty(): label.text = category_label + " · " + label.text
	card.add_child(label)
	# The print is ~1.5 cm tall: the label goes with the card's depth, the card with its width.
	MERGE.fade_out_far(label, mesh.size.z)
	MERGE.fade_out_far(card, mesh.size.x)
	if indoor:
		MERGE.cap_indoor(card, _interior_range())
	add_child(card)
	return label

## The card's words for a price (a [sell] offer, world/mechanics/market/market.gd) or the list price.
func _card_text(id: String, price: int) -> String:
	var text := str(CATALOG.definition(id).name) + "\n" + (CURRENCY.amount(price) if for_sale else "Complimentary")
	return category_label + " · " + text if not category_label.is_empty() else text

func _interior_range() -> float:
	var quality: Node = get_node_or_null("/root/Quality")
	return float(quality.get_value("interior_range", 0.0)) if quality != null else 0.0

func _make_surface(size: Vector3) -> void:
	var support: StaticBody3D = StaticBody3D.new()
	support.name = "FoodDisplaySurface"
	support.top_level = true
	support.transform = global_transform.orthonormalized()
	support.position -= support.basis.y * size.y * 0.5
	var collision: CollisionShape3D = CollisionShape3D.new()
	var shape: BoxShape3D = BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	support.add_child(collision)
	var visual: MeshInstance3D = MeshInstance3D.new()
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = size
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = Color("987249")
	material.roughness = 0.9
	mesh.material = material
	visual.mesh = mesh
	support.add_child(visual)
	add_child(support)

func _on_acquired(key: String) -> void:
	_taken[key] = true
	_items.erase(key)
	stock_changed.emit(snapshot())

## The 06:00 refill (world/shop/shop_world.gd): every sold portion is back on the table.
func restock() -> void:
	if _taken.is_empty():
		return
	_taken.clear()
	_populated = false
	populate()
	stock_changed.emit(snapshot())

func snapshot() -> Dictionary:
	return {"display_id": display_id, "taken": _taken.keys()}

## Call before attaching/populating. Save ownership stays with main's world save.
func restore_stock(state: Dictionary) -> bool:
	if _populated or str(state.get("display_id", "")) != display_id or not state.get("taken") is Array:
		return false
	var taken: Dictionary = {}
	for key: Variant in state.taken:
		if not key is String:
			return false
		taken[key] = true
	_taken = taken
	return true

func available_count() -> int:
	return _items.size()

# Uniform stock API for the market (world/mechanics/market/market.gd, P7): ponies buy and give
# from stalls, keepers refill only the slots they pay for, and [sell] offers show on the card.

## Untaken portions on the counter: [{key, id, node}].
func stock_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for key: String in _items:
		if is_instance_valid(_items[key]) and not _taken.has(key): rows.append({"key": key, "id": key.substr(key.find(":") + 1), "node": _items[key]})
	return rows

## A pony took this portion: it leaves the counter.
func take(key: String) -> bool:
	if key.is_empty() or _taken.has(key): return false
	var item: Variant = _items.get(key)
	if is_instance_valid(item): (item as Node).queue_free()
	_on_acquired(key)
	return true

## The 06:00 refill of only these slots (the keeper paid for them).
func restock_keys(keys: Array) -> void:
	var changed := false
	for key: Variant in keys:
		if _taken.erase(str(key)): changed = true
	if not changed: return
	_populated = false
	populate()
	stock_changed.emit(snapshot())

## A [sell] price on one card (`price` < 0 puts the list price back).
func refresh_card(key: String, price: int) -> void:
	var label: Variant = _cards.get(key)
	if not label is Label3D or not is_instance_valid(label): return
	var id := key.substr(key.find(":") + 1)
	(label as Label3D).text = _card_text(id, CATALOG.price_bits(id) if price < 0 else price)
