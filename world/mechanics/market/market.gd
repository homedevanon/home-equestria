extends Node
## The market (docs/MECHANICS_ARCHITECTURE_2026_11_01.md): who owns each shop display. WP1 has only
## the seller lookup that ledger.gd uses to pay the shopkeeper; the pony economy (restock costs,
## offers, [sell]/[buy]) extends this module in WP8. Owners come from world/mechanics/data/shops.json
## (canon-safe Ponyville residents; everything else is a business till until dev names someone).
## WP8 (P7, section 10.4): the pony economy. Shopkeepers keep what they take (purses capped by the
## ledger), pay the town half an item's value to refill a slot at 06:00 (a slot she cannot pay for
## stays empty that day), residents get a little daily income and trade a few times off-screen
## (facts only). Ponies buy at stalls (shop.gd day step), and the AI verbs [sell: ITEM, BITS]
## (a price for Anon on her own stock, two minutes) and [buy: ITEM, BITS] (she pays Anon when he
## hands her that item) go through here. Stock is read from the saved shop/food snapshots, so
## unloaded stalls work too; a loaded stall's visible item leaves only when a pony really takes it.
const SHOPS_PATH := "res://world/mechanics/data/shops.json"
const DEFAULT_OWNER := "business:market"
static var _shops: Dictionary = {}

static func shops() -> Dictionary:
	if not _shops.is_empty(): return _shops
	_shops = {"owners": {}, "default_owner": DEFAULT_OWNER, "landmarks": {}}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SHOPS_PATH))
	if not parsed is Dictionary:
		push_warning("shops.json is missing or invalid; every display pays the market till")
		return _shops
	var data: Dictionary = parsed
	if data.get("owners") is Dictionary:
		for display: Variant in data.owners:
			var owner: Variant = data.owners[display]
			if display is String and owner is String and not str(owner).is_empty(): _shops.owners[display] = owner
	if data.get("default_owner") is String and not str(data.default_owner).is_empty(): _shops.default_owner = data.default_owner
	if data.get("landmarks") is Dictionary: _shops.landmarks = (data.landmarks as Dictionary).duplicate(true)
	return _shops

## The seller of a display: its owner in shops.json, else the market till.
static func seller_for(display_id: String) -> String:
	var table := shops()
	return str(table.owners.get(display_id, table.default_owner))

# --- WP8 (P7): the pony economy -------------------------------------------------------------------

const ITEM_CATALOG := preload("res://world/inventory/item_catalog.gd")
const FACTS := preload("res://world/mechanics/facts.gd")
const STATE_KEY := "market"   # {"version":1, "day": int, "offers": {pony_id: {"kind": "sell"|"buy", "item", "price", "display", "key", "until_ms": int}}}
const VERSION := 1
const GROUP := "mechanics_market"
const RESTOCK_COST := 0.5     # fraction of value an owner pays the town per refilled slot (supply covers it free)
const DAILY_INCOME := [5, 15] # bits from "town" per resident per day, hashed, capped at LEDGER.PURSE_CAP
const OFFSCREEN_TRADES := 6   # per day, deterministic buyer -> owner purchases (facts only, never visible stock)
const OFFER_MS := 120000
const RESTOCK_HOUR := 6.0
const TICK := 1.0
const SELL_RANGE := 10.0      # her and Anon's camera to her loaded stall, for [sell]
const BUY_RANGE := 3.0        # Anon's camera to her, for [buy]
const LIST_MAX := 6
const MAX_PRICE_FACTOR := 2   # an offer is 1..2x the card price ([sell]) or the item's value ([buy], at least 10)

var context: Node
var game: Node
var facts: Node
var gifts: Node            # gifts.gd (tastes for pony_buy), optional
var belongings: Node       # belongings.gd, optional
var stations: Node         # stations.gd (free restock supply), optional
var ledger: Script         # ledger.gd, set by the hub (ledger.gd preloads this file)
var shop_world: Node       # optional (tests); else game.shop_world
var food_world: Node       # optional (tests); else game.food_world
var residents_override: Array = []   # tests; else the population's assignments
var auto_tick := true
var _table: Dictionary = {}           # display id -> {"world": "shop"|"food", "rows": [[key, item id]]}
var _last_take: Dictionary = {}       # pony id -> [display id, key, item id] (gifts' untake)
var _timer: Timer

func _init() -> void:
	add_to_group(GROUP)

func _ready() -> void:
	if not auto_tick: return
	_timer = Timer.new(); _timer.wait_time = TICK; _timer.autostart = true
	_timer.timeout.connect(tick)
	add_child(_timer)

static func of(tree: SceneTree) -> Node:
	return tree.get_first_node_in_group(GROUP) if tree != null else null

## A display's price for Anon now: a live [sell] offer on it, else `default_price` (shop_purchase,
## food_interaction and the hints). Without a market (fixtures) the default.
static func live_price(from: Node, display_id: String, item_id: String, default_price: int) -> int:
	if display_id.is_empty() or not is_instance_valid(from): return default_price
	var tree: SceneTree = from.get_tree() if from.is_inside_tree() else Engine.get_main_loop() as SceneTree
	var market: Node = of(tree)
	return int(market.call("price_for", display_id, item_id, default_price)) if market != null else default_price

func bind(world_context: Node) -> void:
	context = world_context

func _writable() -> bool:
	return is_instance_valid(context) and not bool(context.get("_read_only")) and context.get("state") is Dictionary

## The economy runs only in a writable world (purses and receipts live there); shop_world keeps
## its plain refill-everything restock otherwise.
func economy_on() -> bool:
	return _writable() and ledger != null and is_instance_valid(game)

func _read() -> Dictionary:
	if not is_instance_valid(context) or not context.get("state") is Dictionary: return {}
	var block: Variant = (context.state as Dictionary).get(STATE_KEY)
	return block if block is Dictionary else {}

func _block() -> Dictionary:
	var state: Dictionary = context.state
	if not state.get(STATE_KEY) is Dictionary: state[STATE_KEY] = {"version": VERSION}
	var block: Dictionary = state[STATE_KEY]
	if not block.get("offers") is Dictionary: block["offers"] = {}
	return block

func _day() -> int:
	return int(FACTS.clock().day)

func _ledger_purse(who: String) -> int:
	return int(ledger.call("balance", game, who)) if ledger != null else 0

func _transfer(from: String, to: String, amount: int, reason: String, opts := {}) -> String:
	if ledger == null: return "Bits cannot change hooves right now."
	return str(ledger.call("transfer", game, from, to, amount, reason, opts))

func _fact(type: String, data: Dictionary, text := "", witnesses: Array = []) -> void:
	if is_instance_valid(facts): facts.call("add", type, data, text, witnesses)

static func _name(id: String) -> String:
	return id.replace("_", " ").capitalize()

## "a cider keg", "some apples" (the same wording as gifts.gd/stations.gd).
static func phrase(item_id: String) -> String:
	var lower := str(ITEM_CATALOG.definition(item_id).get("name", "something")).to_lower()
	for article: String in ["a ", "an ", "the ", "some "]:
		if lower.begins_with(article): return lower
	if lower.ends_with("s") and not lower.ends_with("ss"): return "some " + lower
	return ("an " if lower.left(1) in ["a", "e", "i", "o", "u"] else "a ") + lower

## The card price of an item (shop goods and food carry price_bits), else its value.
static func list_price(item_id: String) -> int:
	var row := ITEM_CATALOG.definition(item_id)
	var price: Variant = row.get("price_bits")
	if (price is int or price is float) and is_finite(float(price)): return maxi(0, int(price))
	return ITEM_CATALOG.value(item_id)

# --- Displays (loaded or saved) ---------------------------------------------------------------

func _world(kind: String) -> Node:
	var given: Node = shop_world if kind == "shop" else food_world
	if is_instance_valid(given): return given
	var found: Variant = game.get("shop_world" if kind == "shop" else "food_world") if is_instance_valid(game) else null
	return found as Node if found is Node and is_instance_valid(found) else null

static func _constants(node: Node) -> Dictionary:
	var script: Script = node.get_script() as Script if is_instance_valid(node) else null
	return script.get_script_constant_map() if script != null else {}

## Every display's slots, keyed the way the displays key their saved stock ("%d:%s").
func table() -> Dictionary:
	if not _table.is_empty(): return _table
	var built := {}
	var shops_node := _world("shop")
	for spec: Variant in _constants(shops_node).get("PLACEMENTS", []):
		if not spec is Dictionary: continue
		var rows: Array = []
		var items: Array = (spec as Dictionary).get("items", [])
		for index: int in items.size(): rows.append(["%d:%s" % [index, items[index]], str(items[index])])
		built[str(spec.id)] = {"world": "shop", "rows": rows}
	var foods_node := _world("food")
	var food_constants := _constants(foods_node)
	var display: Variant = food_constants.get("DISPLAY")
	var presets: Dictionary = (display as Script).get_script_constant_map().get("PRESETS", {}) if display is Script else {}
	for spec: Variant in food_constants.get("PLACEMENTS", []):
		if not spec is Dictionary: continue
		var rows: Array = []
		var slugs: Array = presets.get(str((spec as Dictionary).get("preset", "")), [])
		for index: int in slugs.size(): rows.append(["%d:food:%s" % [index, slugs[index]], "food:" + str(slugs[index])])
		built[str(spec.id)] = {"world": "food", "rows": rows}
	# Kept once both worlds exist (game.gd makes them right after the hub).
	if shops_node != null and foods_node != null: _table = built
	return built

func _live_display(display_id: String) -> Node3D:
	var row: Dictionary = table().get(display_id, {})
	var world := _world(str(row.get("world", "")))
	var displays: Variant = world.get("_displays") if world != null else null
	var node: Variant = (displays as Dictionary).get(display_id) if displays is Dictionary else null
	return node as Node3D if is_instance_valid(node) and node is Node3D else null

## Taken keys: the loaded display's own state, else the saved snapshot.
func _taken(display_id: String) -> Array:
	var node := _live_display(display_id)
	if node != null and node.has_method("snapshot"):
		var snap: Variant = node.call("snapshot")
		if snap is Dictionary and (snap as Dictionary).get("taken") is Array: return ((snap as Dictionary).taken as Array).duplicate()
	var world := _world(str(table().get(display_id, {}).get("world", "")))
	var stock: Variant = world.get("_stock") if world != null else null
	var saved: Variant = (stock as Dictionary).get(display_id) if stock is Dictionary else null
	if saved is Dictionary and (saved as Dictionary).get("taken") is Array: return ((saved as Dictionary).taken as Array).duplicate()
	return []

## Untaken [key, id] rows of a display that can change hooves (tag "sellable": never Anon's human
## clothes, which stay on the shelf as samples).
func stock_rows(display_id: String) -> Array:
	var taken := _taken(display_id)
	var result: Array = []
	for row: Array in table().get(display_id, {}).get("rows", []):
		if not str(row[0]) in taken and ITEM_CATALOG.has_tag(str(row[1]), "sellable"): result.append(row)
	return result

## The displays a pony keeps (shops.json owners), in file order.
static func displays_of(pony_id: String) -> Array[String]:
	var found: Array[String] = []
	var owners: Dictionary = shops().owners
	for display: String in owners:
		if str(owners[display]) == pony_id: found.append(display)
	return found

## Untaken item ids on her displays (loaded or saved state), one per id.
func stock_of(pony_id: String) -> Array[String]:
	var ids: Array[String] = []
	for display: String in displays_of(pony_id):
		for row: Array in stock_rows(display):
			var id := ITEM_CATALOG.canonical(str(row[1]))
			if not id in ids: ids.append(id)
	return ids

## Marks a slot taken: a loaded display frees its visible item, else the saved snapshot changes.
func take_key(display_id: String, key: String) -> bool:
	if key.is_empty() or key in _taken(display_id): return false
	var node := _live_display(display_id)
	if node != null and node.has_method("take"): return bool(node.call("take", key))
	var world := _world(str(table().get(display_id, {}).get("world", "")))
	if world == null or not world.has_method("_remember") or not world.get("_stock") is Dictionary: return false
	var stock: Dictionary = world.get("_stock")
	var state: Dictionary = (stock.get(display_id) as Dictionary).duplicate(true) if stock.get(display_id) is Dictionary else {"display_id": display_id, "taken": []}
	if not state.get("taken") is Array: state["taken"] = []
	(state.taken as Array).append(key)
	world.call("_remember", state)
	return true

## Puts slots back (a loaded display spawns them again).
func restock_keys(display_id: String, keys: Array) -> void:
	if keys.is_empty(): return
	var node := _live_display(display_id)
	if node != null and node.has_method("restock_keys"):
		node.call("restock_keys", keys); return
	var world := _world(str(table().get(display_id, {}).get("world", "")))
	if world == null or not world.has_method("_remember") or not world.get("_stock") is Dictionary: return
	var stock: Dictionary = world.get("_stock")
	if not stock.get(display_id) is Dictionary: return
	var state: Dictionary = (stock[display_id] as Dictionary).duplicate(true)
	state["taken"] = (state.get("taken", []) as Array).filter(func(key: Variant) -> bool: return not key in keys)
	world.call("_remember", state)

## [give] from her stall (gifts.gd): takes the first slot holding `item_id`.
func take_from_stock(pony_id: String, item_id: String) -> bool:
	item_id = ITEM_CATALOG.canonical(item_id)
	for display: String in displays_of(pony_id):
		for row: Array in stock_rows(display):
			if ITEM_CATALOG.canonical(str(row[1])) != item_id: continue
			if take_key(display, str(row[0])):
				_last_take[pony_id] = [display, str(row[0]), item_id]
				return true
	return false

## Undoes a take: gifts.gd calls untake(pony_id, item_id) after a failed hand-over; a display id
## and key work too.
func untake(owner_or_display: String, item_or_key: String) -> void:
	var last: Variant = _last_take.get(owner_or_display)
	if last is Array and str(last[2]) == ITEM_CATALOG.canonical(item_or_key):
		_last_take.erase(owner_or_display)
		restock_keys(str(last[0]), [str(last[1])])
		return
	if table().has(owner_or_display): restock_keys(owner_or_display, [item_or_key])

# --- Prices and offers ----------------------------------------------------------------------------

func _offers() -> Dictionary:
	var offers: Variant = _read().get("offers")
	return offers if offers is Dictionary else {}

## An offer still running: its end lies ahead and within OFFER_MS (a reload restarts the msec
## clock, which ends offers saved before it).
static func _live(offer: Variant) -> bool:
	if not offer is Dictionary: return false
	var until: Variant = (offer as Dictionary).get("until_ms")
	if not (until is int or until is float): return false
	var left := int(until) - Time.get_ticks_msec()
	return left > 0 and left <= OFFER_MS

## A live [sell] offer on that display and item, else `default_price`.
func price_for(display_id: String, item_id: String, default_price: int) -> int:
	item_id = ITEM_CATALOG.canonical(item_id)
	var offers := _offers()
	for pony: Variant in offers:
		var offer: Variant = offers[pony]
		if not _live(offer) or str((offer as Dictionary).get("kind", "")) != "sell": continue
		if str(offer.get("display", "")) == display_id and ITEM_CATALOG.canonical(str(offer.get("item", ""))) == item_id:
			var price: Variant = offer.get("price")
			if (price is int or price is float) and int(price) > 0: return int(price)
	return default_price

func _refresh_card(display_id: String, key: String, price: int) -> void:
	var node := _live_display(display_id)
	if node != null and node.has_method("refresh_card"): node.call("refresh_card", key, price)

## [sell: ITEM, BITS]: Anon may take that item from her stall at `price` for OFFER_MS.
func sell_offer(pony_id: String, item_id: String, price: int) -> Dictionary:
	item_id = ITEM_CATALOG.canonical(item_id)
	if not _writable(): return {"status": "failed", "reason": "Nothing can change hooves right now"}
	if price < 1: return {"status": "failed", "reason": "Name a price in bits"}
	for display: String in displays_of(pony_id):
		for row: Array in stock_rows(display):
			if ITEM_CATALOG.canonical(str(row[1])) != item_id: continue
			var card := list_price(item_id)
			if price > maxi(1, card * MAX_PRICE_FACTOR): return {"status": "failed", "reason": "At most %d bits for that" % maxi(1, card * MAX_PRICE_FACTOR)}
			_end_offer(pony_id)
			_block().offers[pony_id] = {"kind": "sell", "item": item_id, "price": price, "display": display, "key": str(row[0]), "until_ms": Time.get_ticks_msec() + OFFER_MS}
			context._changed()
			_refresh_card(display, str(row[0]), price)
			return {"status": "completed", "reason": "Anon can take the %s from your stall for %d bits for the next two minutes" % [str(ITEM_CATALOG.definition(item_id).get("name", item_id)).to_lower(), price]}
	return {"status": "failed", "reason": "That is not on your stall"}

## [buy: ITEM, BITS]: when Anon hands her that item within OFFER_MS she pays him `price`.
func buy_offer(pony_id: String, item_id: String, price: int) -> Dictionary:
	item_id = ITEM_CATALOG.canonical(item_id)
	if not _writable() or not ITEM_CATALOG.has(item_id): return {"status": "failed", "reason": "Nothing can change hooves right now"}
	if price < 1 or price > _ledger_purse(pony_id): return {"status": "failed", "reason": "You only have %d bits" % _ledger_purse(pony_id)}
	_end_offer(pony_id)
	# The key names complete_buy's receipt "buy:<pony>:<key>": wall-clock microseconds, so an offer
	# after a reload (the msec clock restarts) never matches an old receipt and goes unpaid.
	var key := "b%d" % int(Time.get_unix_time_from_system() * 1000000.0)
	_block().offers[pony_id] = {"kind": "buy", "item": item_id, "price": price, "display": "", "key": key, "until_ms": Time.get_ticks_msec() + OFFER_MS}
	context._changed()
	return {"status": "completed", "reason": "If Anon hands you the %s in the next two minutes, you pay him %d bits" % [str(ITEM_CATALOG.definition(item_id).get("name", item_id)).to_lower(), price]}

## Her live [buy] offer for that item, or {}.
func buy_offer_for(pony_id: String, item_id: String) -> Dictionary:
	var offer: Variant = _offers().get(pony_id)
	if not _live(offer) or str((offer as Dictionary).get("kind", "")) != "buy": return {}
	if ITEM_CATALOG.canonical(str(offer.get("item", ""))) != ITEM_CATALOG.canonical(item_id): return {}
	return (offer as Dictionary).duplicate()

## hand_feeding asks before she takes the item: 0 no live [buy] offer for it (a gift), 1 she can
## still pay (a sale: no gift bond or memory), -1 her purse no longer covers it (the offer ends,
## Anon is told and keeps the item).
func buy_ready(pony_id: String, item_id: String) -> int:
	var offer := buy_offer_for(pony_id, item_id)
	if offer.is_empty(): return 0
	if _ledger_purse(pony_id) >= int(offer.get("price", 0)): return 1
	_end_offer(pony_id)
	var inventory: Variant = game.get("inventory") if is_instance_valid(game) else null
	if ledger != null and inventory is Node and is_instance_valid(inventory):
		ledger.call("say", inventory, "%s can't pay that now." % _name(pony_id))
	return -1

## Anon handed her the item she offered to buy (gifts.received): she pays him once (receipt
## "buy:<pony>:<key>") and it is a sale, not a gift. False when no offer matches or she cannot pay.
func complete_buy(pony: Node3D, pony_id: String, item_id: String) -> bool:
	var offer := buy_offer_for(pony_id, item_id)
	if offer.is_empty(): return false
	var price := int(offer.get("price", 0))
	var label := str(ITEM_CATALOG.definition(item_id).get("name", item_id)).to_lower()
	var why := _transfer(pony_id, "player", price, "trade", {"receipt": "buy:%s:%s" % [pony_id, str(offer.get("key", ""))], "pony": pony,
		"say": "%s paid you %d bits for the %s." % [_name(pony_id), price, label]})
	if not why.is_empty(): return false
	_end_offer(pony_id)
	var item := ITEM_CATALOG.canonical(item_id)
	_fact("sold", {"actor": "player", "target": pony_id, "item": item, "count": 1, "amount": price, "ref": "buy"},
		"Anon sold %s %s for %d bits." % [_name(pony_id), phrase(item), price], [pony_id, "player"])
	_fact("bought", {"actor": pony_id, "target": "player", "item": item, "count": 1, "amount": price, "ref": "buy"})
	var director: Variant = game.get("director") if is_instance_valid(game) else null
	if is_instance_valid(director) and (director as Node).has_method("told_paid"):
		(director as Node).call("told_paid", pony_id, "Anon handed you the %s you offered to buy; you paid him %d bits." % [label, price])
	return true

func _end_offer(pony_id: String) -> void:
	var offer: Variant = _offers().get(pony_id)
	if offer == null or not _writable(): return
	(_block().offers as Dictionary).erase(pony_id)
	context._changed()
	if offer is Dictionary and str((offer as Dictionary).get("kind", "")) == "sell":
		_refresh_card(str(offer.get("display", "")), str(offer.get("key", "")), -1)

## Ends offers that ran out or whose slot was taken.
func _expire_offers() -> void:
	var offers := _offers()
	for pony: Variant in offers.keys():
		var offer: Variant = offers[pony]
		var gone := not _live(offer)
		if not gone and str((offer as Dictionary).get("kind", "")) == "sell":
			gone = str(offer.get("key", "")) in _taken(str(offer.get("display", "")))
		if gone: _end_offer(str(pony))

# --- Ponies buying ------------------------------------------------------------------------------

## A pony shops at these displays: the first untaken item she likes (tastes) that her purse
## covers, else the first she can afford. Visible: the slot is taken (a loaded stall loses the
## item), she pays the keeper, food is eaten (facts only) and anything else becomes her belonging,
## with a "bought" fact (text and witnesses when given). `offscreen`: no stock change and no text
## (her purse, the keeper's, the fact and her belonging only). {} when nothing fits, else
## {"item", "price", "seller", "display"}.
func pony_buy(pony_id: String, display_ids: Array, offscreen := false, witnesses: Array = [], place := "") -> Dictionary:
	if not economy_on() or pony_id.is_empty(): return {}
	var purse := _ledger_purse(pony_id)
	var liked: Array = []
	var plain: Array = []
	for value: Variant in display_ids:
		var display := str(value)
		var seller := seller_for(display)
		if seller == pony_id: continue
		for row: Array in stock_rows(display):
			var id := str(row[1])
			var price := list_price(id)
			if price <= 0 or price > purse: continue
			var entry := [display, str(row[0]), id, price, seller]
			if is_instance_valid(gifts) and gifts.has_method("liking") and int(gifts.call("liking", pony_id, ITEM_CATALOG.canonical(id))) >= 1: liked.append(entry)
			else: plain.append(entry)
	var choices: Array = liked + plain
	for entry: Array in choices:
		var display := str(entry[0])
		var key := str(entry[1])
		var item := ITEM_CATALOG.canonical(str(entry[2]))
		var price := int(entry[3])
		var seller := str(entry[4])
		if not offscreen and not take_key(display, key): continue
		var why := _transfer(pony_id, seller, price, "sale", {})
		if not why.is_empty():
			if not offscreen: restock_keys(display, [key])
			return {}
		if not ITEM_CATALOG.has_tag(item, "food") and is_instance_valid(belongings) and belongings.has_method("add"):
			belongings.call("add", pony_id, item, "shop")
		var text := "" if offscreen else "%s bought %s%s." % [_name(pony_id), phrase(item), (" at " + place) if not place.is_empty() else ""]
		_fact("bought", {"actor": pony_id, "target": seller, "item": item, "count": 1, "amount": price, "ref": display}, text, witnesses if not text.is_empty() else [])
		return {"item": item, "price": price, "seller": seller, "display": display}
	return {}

# --- Restock and the daily round ------------------------------------------------------------

## The 06:00 hook (shop_world._restock_check, before refilling): per display the taken keys its
## keeper refills. Free when the display's supply (stations.supply) has the item, else the keeper
## pays the town ceil(value * RESTOCK_COST); a slot she cannot pay for stays taken today. One
## "restocked" fact per display that refilled anything (no text). {display_id: [keys]}.
func plan_restock() -> Dictionary:
	var plan := {}
	if not economy_on(): return plan
	for display: String in table():
		var taken := _taken(display)
		if taken.is_empty(): continue
		var owner := seller_for(display)
		var refill: Array = []
		var paid := 0
		var items := {}
		for row: Array in table()[display].rows: items[str(row[0])] = str(row[1])
		for value: Variant in taken:
			var key := str(value)
			var item := str(items.get(key, ""))
			if item.is_empty(): refill.append(key); continue   # an old key the menu dropped
			if is_instance_valid(stations) and stations.has_method("take_supply") and bool(stations.call("take_supply", display, item, 1)):
				refill.append(key); continue
			var cost := ceili(float(ITEM_CATALOG.value(item)) * RESTOCK_COST)
			if cost <= 0 or owner == "town" or _transfer(owner, "town", cost, "restock", {}).is_empty():
				refill.append(key); paid += maxi(cost, 0)
		plan[display] = refill
		if not refill.is_empty():
			_fact("restocked", {"actor": owner, "ref": display, "count": refill.size(), "amount": paid})
	return plan

## Residents who live here (the population's assignments), else residents_override.
func residents() -> Array[String]:
	var ids: Array[String] = []
	if not residents_override.is_empty():
		for id: Variant in residents_override: ids.append(str(id))
		return ids
	var population: Node = get_tree().get_first_node_in_group("pony_populations") if is_inside_tree() else null
	var config: Variant = population.get("config") if population != null else null
	var assignments: Variant = (config as Object).get("assignments") if config is Object else null
	if assignments is Dictionary:
		for id: Variant in assignments: ids.append(str(id))
	ids.sort()
	return ids

## Once a day: every resident's small income from the town (capped at the ledger's PURSE_CAP), then
## OFFSCREEN_TRADES deterministic buyer -> keeper purchases at item value with a "bought" fact, the
## first one mirrored as gossip ("Lyra bought a scarf from Rarity.").
func daily(day := -1) -> void:
	if not economy_on(): return
	if day < 0: day = _day()
	_block()["day"] = day
	context._changed()
	var people := residents()
	for id: String in people:
		var amount: int = int(DAILY_INCOME[0]) + absi(hash("income:%s:%d" % [id, day])) % (int(DAILY_INCOME[1]) - int(DAILY_INCOME[0]) + 1)
		_transfer("town", id, amount, "income", {"receipt": "income:%s:%d" % [id, day]})
	var keepers: Array[String] = []
	for display: String in shops().owners:
		var owner := str(shops().owners[display])
		if owner.begins_with("business:") or owner in keepers: continue
		if not people.is_empty() and not owner in people: continue
		if not table().has(display): continue
		keepers.append(owner)
	if keepers.is_empty() or people.size() < 2: return
	var told := false
	for n: int in OFFSCREEN_TRADES:
		var roll := absi(hash("trade:%d:%d" % [day, n]))
		var keeper := keepers[roll % keepers.size()]
		var goods: Array = []
		for display: String in displays_of(keeper):
			for row: Array in table().get(display, {}).get("rows", []): goods.append(str(row[1]))
		if goods.is_empty(): continue
		var item := ITEM_CATALOG.canonical(str(goods[(roll / 7) % goods.size()]))
		var price := list_price(item)
		if price <= 0: continue
		var buyer := ""
		for step: int in people.size():
			var candidate := people[(roll / 13 + step) % people.size()]
			if candidate != keeper and _ledger_purse(candidate) >= price: buyer = candidate; break
		if buyer.is_empty(): continue
		if not _transfer(buyer, keeper, price, "trade", {"receipt": "trade:%d:%d" % [day, n]}).is_empty(): continue
		var text := "" if told else "%s bought %s from %s." % [_name(buyer), phrase(item), _name(keeper)]
		_fact("bought", {"actor": buyer, "target": keeper, "item": item, "count": 1, "amount": price, "ref": "offscreen", "key": "trade:%d:%d" % [day, n]},
			text, [buyer, keeper] if not text.is_empty() else [])
		told = true

## 1 Hz: offers that ran out end; the first tick after 06:00 of a new day runs daily().
func tick() -> void:
	if not _writable(): return
	_expire_offers()
	var clock := FACTS.clock()
	var today: int = int(clock.day) - (0 if float(clock.hours) >= RESTOCK_HOUR else 1)
	var saved: Variant = _read().get("day")
	if not (saved is int or saved is float):
		_block()["day"] = today   # a new world or an old save: start counting from today
		context._changed()
		return
	if int(saved) < today: daily(today)

# --- AI surface (mechanics.gd ai_context) ------------------------------------------------------

func _camera() -> Node3D:
	var inventory: Variant = game.get("inventory") if is_instance_valid(game) else null
	var camera: Variant = (inventory as Node).get("camera") if is_instance_valid(inventory) and inventory is Node else null
	if camera is Node3D and is_instance_valid(camera): return camera
	return get_viewport().get_camera_3d() if is_inside_tree() and get_viewport() != null else null

## Sellable items in Anon's hands.
func anon_holding() -> Array[String]:
	var ids: Array[String] = []
	var inventory: Variant = game.get("inventory") if is_instance_valid(game) else null
	var held: Variant = (inventory as Node).get("held") if is_instance_valid(inventory) and inventory is Node else null
	if not held is Dictionary: return ids
	for side: Variant in held:
		var item: Variant = (held as Dictionary)[side]
		if not is_instance_valid(item) or not item is Node or not (item as Node).has_meta("item_id"): continue
		var id := ITEM_CATALOG.canonical(str((item as Node).get_meta("item_id")))
		if ITEM_CATALOG.has_tag(id, "sellable") and not id in ids: ids.append(id)
	return ids

## {"caps", "keys", "lines"} for [sell] (at her loaded stall with Anon there) and [buy] (Anon beside
## her holding something sellable, her purse not empty).
func ai_row(pony_id: String, actor: Node3D) -> Dictionary:
	var result := {"caps": [], "keys": {}, "lines": []}
	if not economy_on() or not is_instance_valid(actor) or not actor.is_inside_tree(): return result
	var camera := _camera()
	if camera == null or not camera.is_inside_tree(): return result
	var items: Array[String] = []
	var prices := {}
	for display: String in displays_of(pony_id):
		var node := _live_display(display)
		if node == null or not node.is_inside_tree(): continue
		if node.global_position.distance_to(actor.global_position) > SELL_RANGE or node.global_position.distance_to(camera.global_position) > SELL_RANGE: continue
		for row: Array in stock_rows(display):
			var id := ITEM_CATALOG.canonical(str(row[1]))
			if id in items or items.size() >= LIST_MAX: continue
			items.append(id); prices[id] = list_price(id)
	if not items.is_empty():
		result.caps.append("sell"); result.keys["sell_items"] = items; result.keys["sell_prices"] = prices
		var names: PackedStringArray = []
		for id: String in items: names.append("%s %d" % [str(ITEM_CATALOG.definition(id).get("name", id)).to_lower(), int(prices[id])])
		result.lines.append("- Your stall here (bits): %s ([sell: ITEM, BITS] your price for Anon)." % ", ".join(names))
	var purse := _ledger_purse(pony_id)
	if purse > 0 and camera.global_position.distance_to(actor.global_position) <= BUY_RANGE + 1.0:
		var holding := anon_holding()
		if not holding.is_empty():
			var values := {}
			for id: String in holding: values[id] = ITEM_CATALOG.value(id)
			result.caps.append("buy"); result.keys["anon_holding"] = holding; result.keys["holding_values"] = values; result.keys["buy_purse"] = purse
			var names: PackedStringArray = []
			for id: String in holding: names.append(str(ITEM_CATALOG.definition(id).get("name", id)).to_lower())
			result.lines.append("- Anon is holding: %s ([buy: ITEM, BITS] offer to buy it)." % ", ".join(names))
	return result
