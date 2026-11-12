extends Node
## Selling Anon's finished paintings at a shop counter (M-ACT-03, docs/PAINTING_STATION_2026_10_22.md
## section 13 "selling art"). A shopkeeper listed in world/mechanics/data/shops.json "art_buyers"
## (Rarity at her boutique) who stands within `radius` m of her shop's landmark, with Anon beside
## her (market.gd BUY_RANGE + 1 m) holding one of his paintings, offers to buy it: the market's
## own [buy] offer (market.gd buy_offer: two minutes, her purse must cover it) and one line on the
## wrist/HUD message line. Handing the painting to her (the ordinary hand-over, hand_feeding.gd)
## completes the sale through gifts.received -> market.complete_buy: she pays, it is a sale, not
## a gift, and the painting becomes hers. No menu: the price is spoken on the message line and the
## exchange is the physical hand-over. Photos are not bought.
## Ticks once a second; a tick with no painting in Anon's hands stops at the first check.
const MARKET := preload("res://world/mechanics/market/market.gd")
const LEDGER := preload("res://world/mechanics/ledger.gd")
const REGISTRY := preload("res://world/painting/painting_registry.gd")
const PLACES := preload("res://world/navigation/place_directory.gd")
const TICK := 1.0
## Anon's camera to her, on the ground plane (market.gd BUY_RANGE + 1, like its [buy] row).
const NEAR := 4.0
## A refusal (she cannot pay) is said again after this many seconds at most.
const REPEAT_SECONDS := 60.0
var buyers: Dictionary = {}          # pony id -> {"landmark", "radius", "price": [min, max]}
var inventory: Node                  # optional (tests); else the current scene's inventory
var population: Node                 # optional (tests); else group "pony_populations"
var camera_override: Node3D          # optional (tests)
var auto_tick := true
var last_line := ""                  # the last message said, for tests/debug
var _points: Dictionary = {}         # landmark -> Vector3 (resolved once it resolves)
var _said: Dictionary = {}           # "<pony>:<item>" -> msec of the last "can't buy" line
var _timer: Timer

func _init() -> void:
	name = "ArtBuyers"
	buyers = load_buyers()

func _ready() -> void:
	if not auto_tick: return
	_timer = Timer.new(); _timer.wait_time = TICK; _timer.autostart = true
	_timer.timeout.connect(tick)
	add_child(_timer)

## shops.json "art_buyers" rows with a landmark, a radius and a [min, max] price.
static func load_buyers() -> Dictionary:
	var result := {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MARKET.SHOPS_PATH))
	var rows: Variant = (parsed as Dictionary).get("art_buyers") if parsed is Dictionary else null
	if not rows is Dictionary: return result
	for pony: Variant in rows:
		var row: Variant = (rows as Dictionary)[pony]
		if not pony is String or str(pony).begins_with("_") or not row is Dictionary: continue
		var price: Variant = (row as Dictionary).get("price")
		if not price is Array or (price as Array).size() != 2 or not str((row as Dictionary).get("landmark", "")).begins_with("landmark:"): continue
		result[pony] = {"landmark": str(row.landmark), "radius": float(row.get("radius", 12.0)),
			"price": [maxi(1, int(price[0])), maxi(1, int(price[1]))]}
	return result

## What `pony` offers for painting `item_id` ("art:<id>"): fixed per painting, in her range.
func price_for(pony: String, item_id: String) -> int:
	var span: Array = buyers.get(pony, {}).get("price", [10, 10])
	var low := mini(int(span[0]), int(span[1]))
	var high := maxi(int(span[0]), int(span[1]))
	return low + absi(hash("art_price:" + item_id)) % (high - low + 1)

## The paintings (not photos) in Anon's hands, as item ids.
func held_paintings() -> Array[String]:
	var ids: Array[String] = []
	var inv := _inventory()
	var held: Variant = inv.get("held") if inv != null else null
	if not held is Dictionary: return ids
	for side: Variant in held:
		var item: Variant = (held as Dictionary)[side]
		if not is_instance_valid(item) or not item is Node or not (item as Node).has_meta("item_id"): continue
		var id := str((item as Node).get_meta("item_id"))
		if REGISTRY.is_art(id) and not REGISTRY.is_photo(REGISTRY.art_id(id)) and not id in ids: ids.append(id)
	return ids

func tick() -> void:
	if buyers.is_empty(): return
	var paintings := held_paintings()
	if paintings.is_empty(): return
	var market: Node = MARKET.of(get_tree()) if is_inside_tree() else null
	var camera := _camera()
	if market == null or camera == null: return
	for pony: String in buyers:
		var actor := _actor(pony)
		if actor == null or not _at_her_shop(pony, actor): continue
		if _flat(camera.global_position, actor.global_position) > NEAR: continue
		offer(market, pony, paintings[0])

## Her offer for one painting (market.buy_offer) and the line that tells Anon. True when an offer
## stands (new or already running).
func offer(market: Node, pony: String, item_id: String) -> bool:
	if not (market.call("buy_offer_for", pony, item_id) as Dictionary).is_empty(): return true
	var price := price_for(pony, item_id)
	var made: Dictionary = market.call("buy_offer", pony, item_id, price)
	var key := "%s:%s" % [pony, item_id]
	var who := pony.replace("_", " ").capitalize()
	if str(made.get("status", "")) == "completed":
		_say("%s would pay %d bits for your painting. Hand it to her to sell it." % [who, price])
		return true
	# Her purse is short: said once a minute at most while he stands there holding it.
	if not _said.has(key) or Time.get_ticks_msec() - int(_said[key]) >= int(REPEAT_SECONDS * 1000.0):
		_said[key] = Time.get_ticks_msec()
		_say("%s likes your painting, but she can't buy it right now." % who)
	return false

func _say(text: String) -> void:
	last_line = text
	var inv := _inventory()
	if inv != null: LEDGER.say(inv, text)

func _at_her_shop(pony: String, actor: Node3D) -> bool:
	var row: Dictionary = buyers[pony]
	var landmark := str(row.landmark)
	if not _points.has(landmark):
		var at: Vector3 = PLACES.resolve(get_tree(), landmark) if is_inside_tree() else Vector3.INF
		if not at.is_finite(): return false
		_points[landmark] = at
	return _flat(actor.global_position, _points[landmark]) <= float(row.radius)

static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

func _actor(pony: String) -> Node3D:
	var people: Node = population if is_instance_valid(population) else (get_tree().get_first_node_in_group("pony_populations") if is_inside_tree() else null)
	var live: Variant = people.get("live") if people != null else null
	var entry: Variant = (live as Dictionary).get(pony) if live is Dictionary else null
	var actor: Variant = (entry as Dictionary).get("actor") if entry is Dictionary else null
	return actor as Node3D if is_instance_valid(actor) and actor is Node3D and (actor as Node3D).is_inside_tree() else null

func _inventory() -> Node:
	if is_instance_valid(inventory): return inventory
	var scene: Node = get_tree().current_scene if is_inside_tree() else null
	var found: Variant = scene.get("inventory") if scene != null else null
	return found as Node if found is Node and is_instance_valid(found) else null

func _camera() -> Node3D:
	if is_instance_valid(camera_override): return camera_override
	var inv := _inventory()
	var eye: Variant = inv.get("camera") if inv != null else null
	if eye is Node3D and is_instance_valid(eye): return eye
	return get_viewport().get_camera_3d() if is_inside_tree() and get_viewport() != null else null
