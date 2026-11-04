extends RefCounted
## One way bits move (P1 of docs/MECHANICS_ARCHITECTURE_2026_11_01.md, section 3.2): Anon's
## briefcase purse, every pony's purse (world_context.state.pony_wallets; owned here since P1,
## bit_payments.gd forwards to it), business tills and the town (an unlimited source and sink). transfer() checks balances, keeps the existing
## write order and checkpoints, plays the purchase sound, shows the hotbar note, writes a receipt
## when asked and emits a "paid" fact. The Pay panel, [pay_player], hayburger tips and wages, spa
## pay, orchard baskets, the arrival welcome and every shop purchase go through here.
const SFX := preload("res://world/audio/interaction_sounds.gd")
const FACTS := preload("res://world/mechanics/facts.gd")
const MARKET := preload("res://world/mechanics/market/market.gd")
const STATE_KEY := "ledger"
## Pony purses (bit_payments.gd STATE_KEY/MAX_PURSE forward here).
const PURSES_KEY := "pony_wallets"
const MAX_PURSE := 999999
const VERSION := 1
## Commerce credits to a pony (sales, wages, income, trade) stop here; the rest goes to the town.
const PURSE_CAP := 1500
const TILL_START := 500
const MAX_RECEIPTS := 2048
const REASONS := ["pay_panel", "pay_player", "wage", "tip", "sale", "restock", "reward", "harvest", "service", "income", "trade"]
const CAPPED_REASONS := ["sale", "wage", "income", "trade"]
const PLAYER := "player"
const TOWN := "town"
const BUSINESS := "business:"
const TOWN_FUNDS := 1 << 30
const BUSY := "Bits cannot change hooves right now."

## What a pony carries before Anon ever pays her: 20-200 bits, the same in every world.
static func starting(id: String) -> int:
	return 20 + absi(hash("wallet:" + id)) % 181

## A pony's purse, read with type guards (her starting purse until she has a saved one).
static func purse(context: Node, id: String) -> int:
	if not is_instance_valid(context) or id.is_empty(): return 0
	var wallets: Variant = context.state.get(PURSES_KEY)
	if not wallets is Dictionary: return starting(id)
	var held: Variant = (wallets as Dictionary).get(id)
	if not (held is int or held is float) or not is_finite(float(held)): return starting(id)
	return clampi(int(held), 0, MAX_PURSE)

## A short note on the wrist/HUD message line (same line as shop messages).
static func say(inventory: Node, text: String) -> void:
	var bar: Node = inventory.get("hotbar")
	if not is_instance_valid(bar) or not bar.has_method("set_message"): return
	bar.set_message(text)
	if not inventory.is_inside_tree(): return
	inventory.get_tree().create_timer(4.0).timeout.connect(func() -> void:
		if is_instance_valid(bar) and str(bar.get("message")) == text: bar.set_message(""))

static func _id_ok(id: String, size: int) -> bool:
	if id.is_empty() or id.length() > size: return false
	for c: String in id:
		if not c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-": return false
	return true

## "player", "town", "business:<id>" or a pony id.
static func valid_endpoint(who: String) -> bool:
	if who == PLAYER or who == TOWN: return true
	if who.begins_with(BUSINESS): return _id_ok(who.substr(BUSINESS.length()), 48)
	return _id_ok(who, 64)

static func _is_pony(who: String) -> bool:
	return who != PLAYER and who != TOWN and not who.begins_with(BUSINESS)

static func _context(game: Node) -> Node:
	return game.get("world_context") as Node if is_instance_valid(game) else null

static func _writable(context: Node) -> bool:
	return is_instance_valid(context) and not bool(context.get("_read_only")) and context.get("state") is Dictionary

static func _store(game: Node) -> RefCounted:
	var inventory: Node = game.get("inventory") as Node if is_instance_valid(game) else null
	var store: Variant = inventory.get("inventory") if is_instance_valid(inventory) else null
	return store as RefCounted

static func _number(value: Variant, fallback: int) -> int:
	return int(value) if (value is int or value is float) and is_finite(float(value)) else fallback

## The saved ledger block, read with guards ({} when absent or malformed).
static func _read(context: Node) -> Dictionary:
	if not is_instance_valid(context) or not context.get("state") is Dictionary: return {}
	var block: Variant = (context.state as Dictionary).get(STATE_KEY)
	if not block is Dictionary or not (block as Dictionary).get("receipts") is Dictionary or not (block as Dictionary).get("tills") is Dictionary: return {}
	return block

static func _block(context: Node) -> Dictionary:
	return _state_block(context.state)

## The block inside a state dictionary (live world_context.state or a checkpoint copy of it).
static func _state_block(state: Dictionary) -> Dictionary:
	var block: Variant = state.get(STATE_KEY)
	if block is Dictionary and (block as Dictionary).get("receipts") is Dictionary and (block as Dictionary).get("tills") is Dictionary:
		return block
	var fresh := {"version": VERSION, "receipts": {}, "tills": {}}
	state[STATE_KEY] = fresh
	return fresh

static func _till(context: Node, who: String) -> int:
	var block := _read(context)
	var held: Variant = (block.get("tills", {}) as Dictionary).get(who) if not block.is_empty() else null
	return clampi(_number(held, TILL_START), 0, MAX_PURSE)

static func balance(game: Node, who: String) -> int:
	if who == TOWN: return TOWN_FUNDS
	if who == PLAYER:
		var store := _store(game)
		return _number(store.get("bits"), 0) if store != null else 0
	var context := _context(game)
	if not is_instance_valid(context): return 0
	if who.begins_with(BUSINESS): return _till(context, who)
	return purse(context, who)

static func _context_balance(context: Node, who: String) -> int:
	if who == TOWN: return TOWN_FUNDS
	if who.begins_with(BUSINESS): return _till(context, who)
	return purse(context, who)

## Sets a purse or till inside a state dictionary (a checkpoint copy of world_context.state).
static func _put_state(state: Dictionary, who: String, value: int) -> void:
	if who == TOWN or who == PLAYER: return
	if who.begins_with(BUSINESS):
		_state_block(state).tills[who] = clampi(value, 0, MAX_PURSE)
		return
	if not state.get(PURSES_KEY) is Dictionary: state[PURSES_KEY] = {}
	state[PURSES_KEY][who] = clampi(value, 0, MAX_PURSE)

## Sets a purse or till (town swallows); the caller calls context._changed().
static func _put(context: Node, who: String, value: int) -> void:
	if who == TOWN or who == PLAYER: return
	if who.begins_with(BUSINESS):
		_block(context).tills[who] = clampi(value, 0, MAX_PURSE)
		return
	if not context.state.get(PURSES_KEY) is Dictionary: context.state[PURSES_KEY] = {}
	context.state[PURSES_KEY][who] = clampi(value, 0, MAX_PURSE)

## How much of a credit `who` keeps (a capped pony keeps up to PURSE_CAP; the town takes the rest).
static func _kept(context: Node, who: String, amount: int, capped: bool) -> int:
	if who == TOWN or who == PLAYER: return amount
	var before := _context_balance(context, who)
	var room := MAX_PURSE - before
	if capped and _is_pony(who): room = mini(room, PURSE_CAP - before)
	return clampi(amount, 0, maxi(room, 0))

static func receipt_done(game: Node, receipt: String) -> bool:
	if receipt.is_empty(): return false
	var block := _read(_context(game))
	return not block.is_empty() and (block.receipts as Dictionary).has(receipt)

static func _write_receipt(context: Node, receipt: String) -> void:
	_put_receipt(_block(context), receipt)

static func _put_receipt(block: Dictionary, receipt: String) -> void:
	var receipts: Dictionary = block.receipts
	receipts[receipt] = float(FACTS.clock().at)
	while receipts.size() > MAX_RECEIPTS: receipts.erase(receipts.keys()[0])

## The running Facts node when it serves this world (none in fixtures without the hub).
static func _facts(context: Node) -> Node:
	var facts: Node = FACTS.of(Engine.get_main_loop() as SceneTree)
	return facts if facts != null and facts.get("context") == context else null

## A fact, or (no Facts node) the same memory the old pay paths recorded directly.
static func _fact(context: Node, type: String, data: Dictionary, text: String, witnesses: Array) -> void:
	if not _writable(context): return
	var facts := _facts(context)
	if facts != null:
		facts.add(type, data, text, witnesses)
	elif not text.strip_edges().is_empty() and context.has_method("record"):
		var who: Array = witnesses if not witnesses.is_empty() else [str(data.get("actor", "")), str(data.get("target", ""))]
		var valid: Array = []
		for id: Variant in who:
			if FACTS._witness_ok(id) and id not in valid: valid.append(id)
		if not valid.is_empty(): context.record(str(FACTS.MIRROR_KINDS.get(type, type)), text, valid, valid)

## Moves bits. Returns "" on success (or when `receipt` was already applied), else why not.
## opts (all optional): receipt (idempotency key), payers (try these "from" endpoints in order),
## persist (Callable: a credit to "player" goes through credit_bits_with_checkpoint), pony (Node3D:
## purchase sound at her), say (hotbar note), text and witnesses (fact/memory), item (fact item),
## cap (default true for sale/wage/income/trade: a pony credit stops at PURSE_CAP, the rest to town),
## facts (Array of [type, data]: more facts that go with this payment, added after the "paid" fact),
## checkpoint (Dictionary: the snapshot_state() copy that `persist` writes; the receipt, the "paid"
## fact and `facts` are staged into it first, so the one durable checkpoint holds them too).
static func transfer(game: Node, from: String, to: String, amount: int, reason: String, opts := {}) -> String:
	if not is_instance_valid(game): return "Nobody to pay."
	if amount <= 0: return "Nothing to pay."
	if not reason in REASONS: return BUSY
	var payers: Array = []
	var listed: Variant = opts.get("payers")
	if listed is Array and not (listed as Array).is_empty():
		for payer: Variant in listed: payers.append(str(payer))
	else:
		payers.append(from)
	for who: String in payers + [to]:
		if not valid_endpoint(who): return BUSY
	var context := _context(game)
	var writable := _writable(context)
	var receipt := str(opts.get("receipt", ""))
	# Anon <-> town needs no world write (the old tips and wages paid even then); purses, tills and
	# receipts live in the world.
	var touches_world := not receipt.is_empty() or (to != PLAYER and to != TOWN)
	for who: String in payers:
		if who != PLAYER and who != TOWN: touches_world = true
	if touches_world and not writable: return BUSY
	if not receipt.is_empty() and receipt_done(game, receipt): return ""
	var store := _store(game)
	if (PLAYER in payers or to == PLAYER) and store == null: return BUSY
	var payer := ""
	for who: String in payers:
		if who == to: continue
		if balance(game, who) >= amount: payer = who; break
	if payer.is_empty(): return "You only have %d bits." % balance(game, payers[0])
	var paid_data := {"actor": payer, "target": to, "amount": amount, "ref": reason, "item": str(opts.get("item", ""))}
	var extra: Array = []
	var listed_facts: Variant = opts.get("facts")
	if listed_facts is Array:
		for entry: Variant in listed_facts:
			if entry is Array and (entry as Array).size() == 2 and entry[0] is String and entry[1] is Dictionary: extra.append(entry)
	var capped: bool = bool(opts.get("cap", reason in CAPPED_REASONS))
	var kept := amount
	if to != PLAYER and to != TOWN:
		kept = _kept(context, to, amount, capped)
		if kept < amount and not capped: return "Her purse is full." if _is_pony(to) else "The till is full."
	if payer == PLAYER:
		if not bool(store.call("debit_bits", amount)):
			return str(store.get("last_error")) if not str(store.get("last_error")).is_empty() else "Could not pay."
		if to != TOWN:
			_put(context, to, _context_balance(context, to) + kept)
	elif to == PLAYER:
		var persist: Variant = opts.get("persist")
		var staged: Variant = opts.get("checkpoint")
		if persist is Callable and staged is Dictionary and writable:
			if not receipt.is_empty(): _put_receipt(_state_block(staged), receipt)
			# The payer's side too (P4: Applejack pays the orchard basket), so a reload of this
			# checkpoint never finds Anon paid and her purse full.
			if payer != TOWN: _put_state(staged, payer, _context_balance(context, payer) - amount)
			if _facts(context) != null:
				FACTS.stage(staged, "paid", paid_data)
				for entry: Array in extra: FACTS.stage(staged, str(entry[0]), entry[1])
		var paid: bool = bool(store.call("credit_bits_with_checkpoint", amount, persist)) if persist is Callable else bool(store.call("credit_bits", amount))
		if not paid:
			if persist is Callable: return "Could not save the payment."
			return str(store.get("last_error")) if not str(store.get("last_error")).is_empty() else "His purse cannot take that many bits."
		if payer != TOWN:
			_put(context, payer, _context_balance(context, payer) - amount)
	else:
		if payer != TOWN: _put(context, payer, _context_balance(context, payer) - amount)
		if to != TOWN: _put(context, to, _context_balance(context, to) + kept)
	if writable:
		if not receipt.is_empty(): _write_receipt(context, receipt)
		context._changed()
		if payer == PLAYER and context.has_method("save_soon"): context.save_soon()
	var pony: Variant = opts.get("pony")
	if is_instance_valid(pony) and pony is Node3D: SFX.play_purchase(pony)
	var note := str(opts.get("say", ""))
	if not note.is_empty():
		var inventory: Node = game.get("inventory") as Node
		if is_instance_valid(inventory): say(inventory, note)
	var witnesses: Variant = opts.get("witnesses", [])
	_fact(context, "paid", paid_data, str(opts.get("text", "")), witnesses if witnesses is Array else [])
	for entry: Array in extra: _fact(context, str(entry[0]), entry[1], "", [])
	return ""

## One briefcase _commit that takes Anon's `price` with the item loan(s), then pays the display's
## seller (purse capped, the rest to the town) and adds a "bought" fact. False when the commit fails.
static func commit_purchase(inventory: Node, next_slots: Array, loans: Dictionary, price: int, display_id: String, item_id: String) -> bool:
	var store: RefCounted = inventory.get("inventory") as RefCounted if is_instance_valid(inventory) else null
	if store == null or not bool(store.call("_commit", next_slots, loans, int(store.get("bits")) - price)): return false
	note_sale(inventory, price, display_id, item_id)
	return true

## The seller's side of a purchase Anon already paid for (shop goods, food, wardrobe clothes). Needs
## the mechanics hub's world; without one (fixtures) the bits simply leave Anon, as before.
static func note_sale(from: Node, price: int, display_id: String, item_id: String) -> void:
	if price <= 0 or display_id.is_empty() or not is_instance_valid(from): return
	var tree: SceneTree = from.get_tree() if from.is_inside_tree() else Engine.get_main_loop() as SceneTree
	var hub: Node = tree.get_first_node_in_group("mechanics") if tree != null else null
	var context: Node = hub.call("context") as Node if hub != null and hub.has_method("context") else null
	if not _writable(context): return
	var seller := seller_for(display_id)
	if not valid_endpoint(seller): seller = MARKET.DEFAULT_OWNER
	if seller != TOWN:
		var kept := _kept(context, seller, price, true)
		_put(context, seller, _context_balance(context, seller) + kept)
	context._changed()
	if context.has_method("save_soon"): context.save_soon()
	_fact(context, "bought", {"actor": PLAYER, "target": seller, "item": item_id, "amount": price, "ref": display_id}, "", [])

static func seller_for(display_id: String) -> String:
	return MARKET.seller_for(display_id)
