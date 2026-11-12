extends Node3D
const CURRENCY := preload("res://world/ui/currency.gd")
## A shop table or rack of non-food goods (world/shop/shop_items.gd), the counterpart of
## world/food/food_display.gd: each good waits frozen in its place with a price card; picking it
## up buys it (world/shop/shop_purchase.gd); the slot stays empty until the 06:00 restock
## (world/shop/shop_world.gd). Stock is saved per display.
signal stock_changed(state: Dictionary)
const ITEMS := preload("res://world/shop/shop_items.gd")
const FADE := preload("res://world/food/food_mesh_merge.gd")
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const SHELF_LAYER := 1 << 17
@export var item_ids: PackedStringArray = PackedStringArray()
@export_range(1, 8) var columns: int = 3
@export var display_id := ""
@export var build_surface := true
## Metres between item centres (big goods get the wide spacing).
@export var spacing := Vector2(0.62, 0.55)
## Optional authored surfaces, one per item. Empty retains the existing table grid.
@export var slot_transforms: Array[Transform3D] = []
## id -> bool: whether Anon already keeps it in his wardrobe (set by shop_world.gd). Owned
## human clothes stay on the shelf as samples, marked "In your wardrobe", and cannot be bought.
var owned_check: Callable
## key -> "sale", "owned" or "hidden" (clothes for the other form), see refresh_owned.
var _owned: Dictionary = {}
var _taken: Dictionary = {}
var _items: Dictionary = {}
var _cards: Dictionary = {}
var _surface_built := false

func populate() -> void:
	if not is_inside_tree(): return
	var count := item_ids.size()
	if count == 0: return
	if not slot_transforms.is_empty() and slot_transforms.size() != count:
		push_error("Shop stock mounts must match item count: " + display_id); return
	var width := mini(columns, count)
	var rows := ceili(float(count) / width)
	if build_surface and not _surface_built:
		_surface_built = true
		_make_surface(Vector3(width * spacing.x + 0.1, 0.06, rows * spacing.y + 0.1))
	for index in count:
		var id := str(item_ids[index])
		var key := "%d:%s" % [index, id]
		if _taken.has(key) or (_items.has(key) and is_instance_valid(_items[key])): continue
		var point := Vector3((float(index % width) - (width - 1) * 0.5) * spacing.x, 0.0, (float(index / width) - (rows - 1) * 0.5) * spacing.y)
		var local_surface := Transform3D(Basis.IDENTITY, point) if slot_transforms.is_empty() else slot_transforms[index]
		var surface := global_transform.orthonormalized() * local_surface
		var item := spawn_item(self, id, surface)
		if item == null: continue
		item.set_meta("shop_display", self); item.set_meta("shop_key", key)
		_items[key] = item
		if not _cards.has(key): _cards[key] = _make_price_card(id, surface * Transform3D(Basis.IDENTITY, Vector3(0.0, 0.006, spacing.y * 0.5 - 0.06)))
		_owned.erase(key)
	refresh_owned()

## Owned wardrobe clothes leave the buyable group and their card says so; Anon's human clothes
## are hidden with their card while he is a pony (dev 2026-10-14). Pony wear is for sale to both
## forms: a human buys it to give (dev 2026-10-22). Cheap: one form lookup and one bool
## per clothes item, called once a second by shop_world.gd and after a purchase.
func refresh_owned() -> void:
	var pony := is_inside_tree() and PLAYER_FORM.is_pony(PLAYER_FORM.active(get_tree()))
	for key: String in _items:
		var item: RigidBody3D = _items[key]
		if not is_instance_valid(item): continue
		var id := str(item.get_meta("item_id", ""))
		var human_only := ITEMS.wardrobe_only(id)
		if not human_only and not ITEMS.pony_wear(id): continue
		# Anon's human clothes hide while he is a pony; pony wear always sells (gifts, dev 2026-10-22).
		var state := "hidden" if human_only and pony else "sale"
		if state == "sale" and human_only and owned_check.is_valid() and owned_check.call(id) == true: state = "owned"
		if _owned.get(key, "") == state: continue
		_owned[key] = state
		item.visible = state != "hidden"
		item.collision_layer = 0 if state == "hidden" else SHELF_LAYER
		if state == "sale": item.add_to_group("shop_items")
		else: item.remove_from_group("shop_items")
		var card: Node3D = _cards.get(key)
		if not is_instance_valid(card): continue
		card.visible = state != "hidden"
		var label: Label3D = card.get_node_or_null("PriceLabel") as Label3D
		if label != null: label.text = card_text(id, state == "owned")

static func card_text(id: String, owned: bool) -> String:
	var note := ITEMS.form_note(id, owned)
	var price := "" if owned and ITEMS.wardrobe_only(id) else CURRENCY.amount(ITEMS.price_bits(id))
	var lines := PackedStringArray([str(ITEMS.definition(id).name)])
	if not price.is_empty(): lines.append(price)
	if not note.is_empty(): lines.append(note)
	return "\n".join(lines)

## A frozen, unowned good for sale at `surface` (group "shop_items").
static func spawn_item(parent: Node3D, id: String, surface: Transform3D) -> RigidBody3D:
	var packed := ITEMS.scene(id)
	if packed == null: return null
	var visual: Node3D = packed.instantiate()
	var item := RigidBody3D.new()
	item.name = "Shop_" + id.replace(":", "_").replace("-", "_")
	item.set_meta("item_id", id); item.set_meta("for_sale", true)
	item.collision_layer = SHELF_LAYER; item.collision_mask = 1
	item.freeze = true
	item.add_child(visual)
	item.top_level = true
	parent.add_child(item)
	item.global_transform = surface.orthonormalized()
	# A catalogue tool (shop_items.gd TOOLS) is its own scene with no `bounds`: its known box, lifted
	# so its base sits on the surface.
	var bounds: AABB = visual.bounds if "bounds" in visual else ITEMS.tool_bounds(id)
	if not "bounds" in visual: item.global_transform = item.global_transform.translated_local(Vector3.UP * -bounds.position.y)
	var shape := CollisionShape3D.new(); var box := BoxShape3D.new()
	box.size = bounds.size.max(Vector3.ONE * 0.02); shape.shape = box; shape.position = bounds.get_center()
	item.add_child(shape)
	# Small goods stop drawing once a few pixels, like food; furniture-sized goods keep drawing.
	var longest := maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z))
	if longest < 0.45: FADE.fade_out_far(visual, longest)
	item.add_to_group("shop_items")
	return item

func _make_price_card(id: String, at: Transform3D) -> Node3D:
	var card := MeshInstance3D.new(); card.name = "ShopPriceCard"; card.top_level = true
	var mesh := BoxMesh.new(); mesh.size = Vector3(0.3, 0.004, 0.09)
	var material := StandardMaterial3D.new(); material.albedo_color = Color("eee1bd"); material.roughness = 1.0
	mesh.material = material; card.mesh = mesh
	var label := Label3D.new(); label.name = "PriceLabel"; label.rotation.x = -PI * 0.5; label.position.y = 0.0025
	label.font_size = 24; label.pixel_size = 0.0006; label.width = 460.0
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; label.outline_size = 0; label.modulate = Color("30261b")
	CURRENCY.apply(label)
	label.text = card_text(id, false)
	card.add_child(label); FADE.fade_out_far(label, mesh.size.z); FADE.fade_out_far(card, mesh.size.x); add_child(card); card.global_transform = at
	return card

func _make_surface(size: Vector3) -> void:
	var support := StaticBody3D.new(); support.name = "ShopDisplaySurface"; support.top_level = true
	add_child(support)
	support.global_transform = global_transform.orthonormalized()
	support.position -= support.basis.y * size.y * 0.5
	var collision := CollisionShape3D.new(); var shape := BoxShape3D.new(); shape.size = size
	collision.shape = shape; support.add_child(collision)
	var visual := MeshInstance3D.new(); var mesh := BoxMesh.new(); mesh.size = size
	var material := StandardMaterial3D.new(); material.albedo_color = Color("987249"); material.roughness = 0.9
	mesh.material = material; visual.mesh = mesh; support.add_child(visual)

## Called by the purchase once the good is in the player's hands.
func sold(key: String) -> void:
	_taken[key] = true
	_items.erase(key)
	stock_changed.emit(snapshot())

func restock() -> void:
	if _taken.is_empty(): return
	_taken.clear()
	populate()
	stock_changed.emit(snapshot())

# Uniform stock API for the market (world/mechanics/market/market.gd, P7): ponies buy and give
# from stalls, keepers refill only the slots they pay for, and [sell] offers show on the card.

## Untaken goods on the table: [{key, id, node}].
func stock_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for key: String in _items:
		if is_instance_valid(_items[key]) and not _taken.has(key): rows.append({"key": key, "id": str((_items[key] as Node).get_meta("item_id", "")), "node": _items[key]})
	return rows

## A pony took this slot (bought it or gave it away): the good leaves the table.
func take(key: String) -> bool:
	if key.is_empty() or _taken.has(key): return false
	var item: Variant = _items.get(key)
	if is_instance_valid(item): (item as Node).queue_free()
	sold(key)
	return true

## The 06:00 refill of only these slots (the keeper paid for them).
func restock_keys(keys: Array) -> void:
	var changed := false
	for key: Variant in keys:
		if _taken.erase(str(key)): changed = true
	if not changed: return
	populate()
	stock_changed.emit(snapshot())

## A [sell] price on one card (`price` < 0 puts the list price back).
func refresh_card(key: String, price: int) -> void:
	var card: Node3D = _cards.get(key)
	var label: Label3D = card.get_node_or_null("PriceLabel") as Label3D if is_instance_valid(card) else null
	if label == null: return
	var id := key.substr(key.find(":") + 1)
	label.text = card_text(id, false) if price < 0 else "%s\n%s" % [str(ITEMS.definition(id).name), CURRENCY.amount(price)]

func snapshot() -> Dictionary:
	return {"display_id": display_id, "taken": _taken.keys()}

func restore_stock(state: Dictionary) -> bool:
	if str(state.get("display_id", "")) != display_id or not state.get("taken") is Array: return false
	_taken.clear()
	for key: Variant in state.taken:
		if key is String: _taken[key] = true
	return true
