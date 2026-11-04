extends RefCounted
## Item tags and value (P0 of docs/MECHANICS_ARCHITECTURE_2026_11_01.md, section 2). Every system
## asks the registry by tag ("giftable", "ingredient", "apple"...), never by a hard-coded id list
## (dev 2026-11-01: no "mojang copper" that is used for one thing only). Derived tags are rules over
## the existing catalogues, so new rows get them automatically; explicit tags and values live in
## item_tags.json. Callers use the forwarders in item_catalog.gd, which hands itself in first
## (bind_catalog): this script never references the catalogue, so no dependency cycle forms.
const DATA_PATH := "res://world/inventory/item_tags.json"
const STATIONS_PATH := "res://world/mechanics/data/stations.json"
const JOBS_PATH := "res://world/mechanics/data/jobs.json"
const IDENTITY := preload("res://world/inventory/item_identity.gd")
const FOOD := preload("res://world/food/food_catalog.gd")
const SHOP := preload("res://world/shop/shop_items.gd")
const CIDER := preload("res://world/items/cider_keg.gd")
const RECIPES := preload("res://world/cooking/cooking_recipes.gd")
const FURNISHING := preload("res://world/housing/furnishing_rules.gd")
const STATIONERY := preload("res://world/letters/stationery.gd")
const PAINTINGS := preload("res://world/painting/painting_registry.gd")
## The exact tag vocabulary (architecture 2.2). Explicit tags outside it are ignored with a warning.
const VOCABULARY := ["food", "edible", "drink", "alcohol", "meal", "sweet", "party", "fruit", "apple",
	"apple_food", "cider", "farm_food", "animal_feed", "ingredient", "regional", "container", "home_good",
	"wall_good", "fabric", "tea", "plant", "plantable", "stationery", "tool", "wear", "fashion", "sporty",
	"magic", "cozy", "wardrobe", "book", "art", "photo", "painting", "letter", "fish", "gem", "giftable",
	"sellable", "collectible"]
const CATEGORY_TAGS := {"meals": "meal", "sweets": "sweet", "fruit": "fruit", "apple-family": "apple_food",
	"ingredients": "ingredient", "regional": "regional"}
const SWEET_EXTRA := ["food:rainbow-pie", "food:caramel-apple", "food:candy-apple"]
const FRUIT_EXTRA := ["apple", "food:green-apple", "food:strawberry"]
const APPLES := ["apple", "food:green-apple"]
const FARM_EXTRA := ["carrot", "food:hay-bundle", "food:oats", "food:bread-loaf"]
const SPORTY_WEAR := ["goggles", "aviators", "sunhat", "cowpony-hat"]
const MAGIC_WEAR := ["wizard_hat", "cape"]
const COZY_WEAR := ["scarf", "socks", "beanie"]
## Values for families without a price (architecture 2.3).
const BOOK_VALUE := 12
const PAINTING_VALUE := 40
const PHOTO_VALUE := 8
const KEG_SERVING_VALUE := 5
## Never handed over: the old key is not even a catalogue item, but stays excluded by name.
const NEVER_GIFT := ["house-key"]

static var _catalog: Script
static var _data: Dictionary = {}
static var _cache: Dictionary = {}
static var _enumerable: Array[String] = []
static var _by_tag: Dictionary = {}
static var _process_rows: Array = []
static var _process_loaded := false

## The item catalogue (item_catalog.gd) whose ids these rules describe; unbound means no ids.
static func bind_catalog(catalog: Script) -> void:
	if _catalog == catalog: return
	_catalog = catalog
	_data = {}; _cache = {}; _enumerable = []; _by_tag = {}

static func bound() -> bool:
	return _catalog != null

static func _cat() -> Script:
	return _catalog

static func _has(id: String) -> bool:
	var cat := _cat()
	return cat != null and bool(cat.call("has", id))

static func _definition(id: String) -> Dictionary:
	var cat := _cat()
	if cat == null: return {}
	var found: Variant = cat.call("definition", id)
	return found if found is Dictionary else {}

static func _explicit() -> Dictionary:
	if not _data.is_empty(): return _data
	_data = {"tags": {}, "values": {}}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
	if not parsed is Dictionary:
		push_warning("item_tags.json is missing or invalid; only derived tags apply")
		return _data
	var tags: Variant = (parsed as Dictionary).get("tags", {})
	var values: Variant = (parsed as Dictionary).get("values", {})
	var unknown: Array[String] = []
	if tags is Dictionary:
		for id: Variant in tags:
			var list: Variant = tags[id]
			if not id is String or not list is Array or not _has(str(id)):
				unknown.append(str(id)); continue
			var clean: Array[String] = []
			for tag: Variant in list:
				if tag is String and tag in VOCABULARY: clean.append(str(tag))
				else: unknown.append("%s:%s" % [id, tag])
			_data.tags[IDENTITY.canonical(str(id))] = clean
	if values is Dictionary:
		for id: Variant in values:
			var amount: Variant = values[id]
			if not id is String or not (amount is int or amount is float) or not is_finite(float(amount)) or not _has(str(id)):
				unknown.append(str(id)); continue
			_data.values[IDENTITY.canonical(str(id))] = maxi(0, int(amount))
	if not unknown.is_empty(): push_warning("item_tags.json ignores unknown rows: " + ", ".join(unknown))
	return _data

static func _is_book(id: String) -> bool:
	return id.begins_with("book:") and id.substr(5).is_valid_int()

static func _is_letter(id: String) -> bool:
	return id.begins_with("letter:")

## Books, paintings and letters are made at runtime; their tags are never cached or enumerated.
static func _dynamic(id: String) -> bool:
	return _is_book(id) or PAINTINGS.is_art(id) or _is_letter(id)

## Canonical id's tags (derived plus explicit); empty when the catalogue does not know the id.
static func tags(id: String) -> PackedStringArray:
	id = IDENTITY.canonical(id)
	if not _has(id): return PackedStringArray()
	var dynamic := _dynamic(id)
	if not dynamic and _cache.has(id): return _cache[id]
	var found: Dictionary = {}
	if FOOD.has(id):
		var row: Dictionary = FOOD.definition(id)
		if FOOD.is_empty_container(id):
			found["container"] = true
		else:
			found["food"] = true
			if FOOD.can_consume(id): found["edible"] = true
			if bool(row.get("drink", false)): found["drink"] = true
			if bool(row.get("alcohol", false)): found["alcohol"] = true
			var category := str(row.get("category", ""))
			if CATEGORY_TAGS.has(category): found[CATEGORY_TAGS[category]] = true
			if id in SWEET_EXTRA: found["sweet"] = true
			if id in FRUIT_EXTRA: found["fruit"] = true
			if id in APPLES: found["apple"] = true
			if RECIPES.ingredient(id): found["ingredient"] = true
			if id == CIDER.MUG_FULL: found["cider"] = true
			if found.has("apple") or found.has("apple_food") or id in FARM_EXTRA: found["farm_food"] = true
	if CIDER.is_keg(id): found["cider"] = true
	if FURNISHING.has(id):
		found["home_good"] = true
		if FURNISHING.wall(id): found["wall_good"] = true
	if not STATIONERY.of_item(id).is_empty() or id == STATIONERY.QUILL: found["stationery"] = true
	if SHOP.pony_wear(id):
		found["wear"] = true; found["fashion"] = true
		var kind := id.get_slice(":", 1)
		if kind in SPORTY_WEAR: found["sporty"] = true
		if kind in MAGIC_WEAR: found["magic"] = true
		if kind in COZY_WEAR: found["cozy"] = true
	if SHOP.wardrobe_only(id): found["wardrobe"] = true
	if _is_book(id): found["book"] = true
	if PAINTINGS.is_art(id) or id == "goods:picture": found["art"] = true
	if PAINTINGS.is_art(id):
		found["photo" if PAINTINGS.is_photo(PAINTINGS.art_id(id)) else "painting"] = true
	if _is_letter(id): found["letter"] = true
	for tag: String in _explicit().tags.get(id, []): found[tag] = true
	if found.has("book") or found.has("art"): found["collectible"] = true
	var giftable := not (found.has("tool") or found.has("letter") or found.has("wardrobe") or found.has("container")) and not id in NEVER_GIFT
	if giftable:
		found["giftable"] = true
		if value(id) > 0: found["sellable"] = true
	var result := PackedStringArray()
	for tag: String in found: result.append(tag)
	if not dynamic: _cache[id] = result
	return result

static func has_tag(id: String, tag: String) -> bool:
	return tag in tags(id)

## Bits, >= 0: explicit value, then a keg's servings, then the price, then the family default.
static func value(id: String) -> int:
	id = IDENTITY.canonical(id)
	if not _has(id): return 0
	var explicit: Dictionary = _explicit().values
	if explicit.has(id): return int(explicit[id])
	if CIDER.is_keg(id): return CIDER.servings(id) * KEG_SERVING_VALUE
	var row := _definition(id)
	if row.has("price_bits"):
		var price: Variant = row.price_bits
		return maxi(0, int(price)) if (price is int or price is float) and is_finite(float(price)) else 0
	if _is_book(id): return BOOK_VALUE
	if PAINTINGS.is_art(id): return PHOTO_VALUE if PAINTINGS.is_photo(PAINTINGS.art_id(id)) else PAINTING_VALUE
	return 0

## Every id that can be listed: plain items, current foods and their empty containers, goods,
## wear in each colour (fitted kinds colour 0), outfits, the wing sandals, a full cider keg and
## the apple sapling.
static func enumerable() -> Array[String]:
	if not _enumerable.is_empty(): return _enumerable
	var ids: Array[String] = []
	var cat := _cat()
	if cat != null:
		var items: Variant = cat.get_script_constant_map().get("ITEMS", {})
		if items is Dictionary:
			for id: Variant in items: ids.append(str(id))
	for id: String in FOOD.ids():
		if id not in ids: ids.append(id)
		var empty := FOOD.empty_id(id)
		if not empty.is_empty() and empty not in ids: ids.append(empty)
	for model: String in SHOP.GOODS: ids.append("goods:" + model)
	for kind: String in SHOP.WEAR:
		if kind in SHOP.FITTED_WEAR: ids.append("wear:%s:0" % kind)
		else:
			for colour: int in SHOP.WEAR_COLOURS.size(): ids.append("wear:%s:%d" % [kind, colour])
	for outfit: String in SHOP.OUTFITS: ids.append("outfit:" + outfit)
	ids.append(SHOP.WING_SANDALS)
	ids.append(CIDER.ID)
	ids.append(SHOP.SAPLING.ID)
	for id: String in ids:
		if _has(id) and id not in _enumerable: _enumerable.append(id)
	return _enumerable

## Enumerable ids carrying `tag` (books, paintings and letters are never listed).
static func with_tag(tag: String) -> Array[String]:
	if _by_tag.has(tag): return (_by_tag[tag] as Array[String]).duplicate()
	var result: Array[String] = []
	for id: String in enumerable():
		if has_tag(id, tag): result.append(id)
	_by_tag[tag] = result
	return result.duplicate()

## The id in `ids` that `text` names, or "": exact id, exact name, name containment (3+ characters),
## a tag word, then the same again with a plural folded to its singular ("apples" -> "apple").
static func match_name(text: String, ids: Array) -> String:
	var wanted := text.strip_edges()
	if wanted.is_empty() or ids.is_empty(): return ""
	var found := _match(wanted, ids)
	if not found.is_empty(): return found
	var lower := wanted.to_lower()
	for suffix: String in ["es", "s"]:
		if lower.length() > suffix.length() + 2 and lower.ends_with(suffix):
			found = _match(wanted.left(wanted.length() - suffix.length()), ids)
			if not found.is_empty(): return found
	return ""

static func _match(wanted: String, ids: Array) -> String:
	var lower := wanted.to_lower()
	for id: Variant in ids:
		if str(id) == wanted or IDENTITY.canonical(str(id)) == IDENTITY.canonical(wanted): return str(id)
	var names: Array[String] = []
	for id: Variant in ids: names.append(str(_definition(str(id)).get("name", "")).to_lower())
	for index: int in ids.size():
		if not names[index].is_empty() and names[index] == lower: return str(ids[index])
	if lower.length() >= 3:
		for index: int in ids.size():
			if not names[index].is_empty() and (names[index].contains(lower) or lower.contains(names[index])): return str(ids[index])
	var tag := lower.replace(" ", "_").replace("-", "_")
	if tag in VOCABULARY:
		for id: Variant in ids:
			if has_tag(str(id), tag): return str(id)
	return ""

## Station and job rows (world/mechanics/data/*.json), read once as data; [] before they exist.
static func _rows() -> Array:
	if _process_loaded: return _process_rows
	_process_loaded = true
	for pair: Array in [[STATIONS_PATH, "stations"], [JOBS_PATH, "jobs"]]:
		if not FileAccess.file_exists(str(pair[0])): continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(pair[0])))
		if not parsed is Dictionary: continue
		var list: Variant = (parsed as Dictionary).get(str(pair[1]), [])
		if not list is Array: continue
		for row: Variant in list:
			if row is Dictionary and (row as Dictionary).get("id") is String: _process_rows.append(row)
	return _process_rows

## True when a row's list (rows {id|tag} or "tag:x"/id strings) names `id` or one of its tags.
static func _mentions(entries: Variant, id: String, item_tags: PackedStringArray) -> bool:
	if not entries is Array: return false
	for entry: Variant in entries:
		var named := ""
		var tag := ""
		if entry is Dictionary:
			named = str((entry as Dictionary).get("id", ""))
			tag = str((entry as Dictionary).get("tag", ""))
		elif entry is String:
			if str(entry).begins_with("tag:"): tag = str(entry).substr(4)
			else: named = str(entry)
		if not named.is_empty() and IDENTITY.canonical(named) == id: return true
		if not tag.is_empty() and tag in item_tags: return true
	return false

static func _copper(row: Dictionary, key: String) -> Variant:
	var copper: Variant = row.get("copper", {})
	return (copper as Dictionary).get(key, []) if copper is Dictionary else []

## Station/job ids whose outputs include `id` (by id or tag).
static func made_by(id: String) -> PackedStringArray:
	id = IDENTITY.canonical(id)
	var result := PackedStringArray()
	var item_tags := tags(id)
	for row: Dictionary in _rows():
		if _mentions(row.get("outputs", []), id, item_tags) or _mentions(_copper(row, "makes"), id, item_tags):
			if str(row.id) not in result: result.append(str(row.id))
	return result

## Station/job ids whose inputs include `id` or one of its tags.
static func used_by(id: String) -> PackedStringArray:
	id = IDENTITY.canonical(id)
	var result := PackedStringArray()
	var item_tags := tags(id)
	for row: Dictionary in _rows():
		if _mentions(row.get("inputs", []), id, item_tags) or _mentions(_copper(row, "takes"), id, item_tags):
			if str(row.id) not in result: result.append(str(row.id))
	return result
