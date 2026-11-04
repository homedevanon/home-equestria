extends RefCounted
## Buying a shop good by picking it up (world/shop/shop_display.gd), one persisted transaction
## like world/food/food_interaction.gd take_world: the bits are paid and the good becomes an
## owned loose item in the same commit, so a failed write never takes money or duplicates it.
##
## Anon's human clothes (outfits, wing sandals; dev 2026-10-14) are not carried: paying unlocks
## them for good in his wardrobe (world/customization/clothing_profile.gd buy_unlock), the shelf
## sample stays and its card reads "In your wardrobe". Only human Anon can buy them. Pony wear
## is a normal carried good that only AnonPony can buy ("make sure they don't cross over"); she
## wears it or gives it to a mare. The shelves hide the other form's goods (shop_display.gd).
## For whoever builds on this (food/items): `take_world` is the one entry for every shop good;
## add new carried goods to shop_items.gd and they take the carried path below unchanged.
const ITEMS := preload("res://world/shop/shop_items.gd")
const STORE := preload("res://world/inventory/inventory_store.gd")
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
const LEDGER := preload("res://world/mechanics/ledger.gd")
const MARKET := preload("res://world/mechanics/market/market.gd")
const TIDY := preload("res://world/inventory/loose_tidy.gd")
const WRONG_FORM := "Tailored for Anon's human form. Come back on two legs to buy it."
const WRONG_FORM_PONY := "Pony wear, made for ponies. Come back in pony form to buy it."
const MESSAGE_SECONDS := 4.0

static func take_world(inventory: Node, side: String, item: RigidBody3D, pose: Transform3D) -> bool:
	if not is_instance_valid(item) or not item.is_in_group("shop_items") or bool(item.get_meta("shop_claiming", false)): return false
	if ITEMS.wardrobe_only(str(item.get_meta("item_id", ""))): return _buy_for_wardrobe(inventory, side, item)
	if not pose.is_finite(): return false
	# These refusals used to be silent: a click on a good did nothing (thread report 2026-10-30).
	if inventory.hand_busy(side) or inventory.held.has(side):
		_say(inventory, "Hands full. Press E to buy it straight into the briefcase." if side == "desktop" else "That hand is full."); return false
	if is_instance_valid(inventory.player_body) and "controls_locked" in inventory.player_body and inventory.player_body.controls_locked: return false
	# At the cap an empty mug or photo left lying about goes back in the briefcase by itself
	# (world/inventory/loose_tidy.gd); otherwise the refusal says why (thread report 2026-11-03).
	if not TIDY.make_room(inventory):
		_say(inventory, TIDY.full_text(inventory)); return false
	var id := str(item.get_meta("item_id", ""))
	if not ITEMS.has(id): return false
	var store: RefCounted = inventory.inventory
	# Pony wear sells to human Anon too (dev 2026-10-22: "ponies still need to buy it"; bought as a
	# gift, held up to a pony to give it: world/relationships/hand_feeding.gd).
	var display: Node = item.get_meta("shop_display") if item.has_meta("shop_display") else null
	var display_id: String = str(display.get("display_id")) if is_instance_valid(display) and display.get("display_id") != null else ""
	# A keeper's live [sell] offer on this good (world/mechanics/market/market.gd) is its price now.
	var price := MARKET.live_price(inventory, display_id, id, ITEMS.price_bits(id))
	if store.bits < price:
		store.last_error = "insufficient funds!"
		inventory._error(); return false
	# What comes with it (the cider keg's two mugs) goes into the briefcase in the same payment,
	# as far as there is room; then the good itself takes a home slot.
	var next: Array = store.slots.duplicate(true)
	var extras := 0
	for extra: String in ITEMS.extras(id):
		var at: int = STORE._place(next, extra, -1)
		if at < 0: break
		if next[at].is_empty(): next[at] = {"id": extra, "count": 0}
		next[at].count += 1
		extras += 1
	var slot: int = STORE._place(next, id, -1)
	if slot < 0:
		_say(inventory, "No room in your briefcase."); return false
	var token := "shop_%d_%d" % [Time.get_ticks_usec(), item.get_instance_id()]
	var checked: Dictionary = store.loans.duplicate(true)
	checked[token] = {"id": id, "slot": slot}
	item.set_meta("shop_claiming", true)
	# One commit takes the bits with the good; the shopkeeper keeps them (world/mechanics/ledger.gd).
	if not LEDGER.commit_purchase(inventory, next, checked, price, display_id, id):
		item.remove_meta("shop_claiming"); return false
	item.remove_from_group("shop_items")
	if is_instance_valid(display): display.sold(str(item.get_meta("shop_key", "")))
	item.remove_meta("shop_claiming"); item.remove_meta("for_sale")
	item.set_meta("token", token)
	item.reparent(inventory, true)
	item.top_level = false
	item.freeze = true
	item.set_meta("hold_offset", inventory.hold_local(id))
	item.set_meta("hold_from", item.global_transform)
	item.set_meta("hold_blend", 0.0)
	inventory.loose[token] = item
	inventory.held[side] = item
	inventory._track.erase(side)
	inventory._claim(side, true)
	inventory._refresh_holding()
	inventory._clear_purchase_error()
	inventory._haptic(side)
	if price > 0: SFX.play_purchase(item)
	if extras > 0: _say(inventory, "%s bought. %s in your briefcase." % [str(ITEMS.definition(id).name), "Two cider mugs" if extras == 2 else "A cider mug"])
	return true

## Pays for a human garment and keeps it in the wardrobe; nothing goes into the hand.
static func _buy_for_wardrobe(inventory: Node, side: String, item: RigidBody3D) -> bool:
	if is_instance_valid(inventory.player_body) and "controls_locked" in inventory.player_body and inventory.player_body.controls_locked: return false
	var id := str(item.get_meta("item_id", ""))
	var store: RefCounted = inventory.inventory
	var clothing: RefCounted = inventory.get("clothing")
	if clothing == null: return false
	if PLAYER_FORM.is_pony(PLAYER_FORM.active(inventory.get_tree())):
		store.last_error = WRONG_FORM; inventory._error(); return false
	var price := ITEMS.price_bits(id)
	if store.bits < price:
		store.last_error = "insufficient funds!"
		inventory._error(); return false
	item.set_meta("shop_claiming", true)
	var error: String = clothing.buy_unlock(store, id, price)
	item.remove_meta("shop_claiming")
	if not error.is_empty():
		store.last_error = error; inventory._error(); return false
	var display: Node = item.get_meta("shop_display") if item.has_meta("shop_display") else null
	if is_instance_valid(display): LEDGER.note_sale(inventory, price, str(display.get("display_id")) if display.get("display_id") != null else "", id)
	if is_instance_valid(display) and display.has_method("refresh_owned"): display.refresh_owned()
	inventory._clear_purchase_error()
	var text := "%s: in your wardrobe now." % str(ITEMS.definition(id).name)
	if id == ITEMS.WING_SANDALS: text = "Wing sandals: in your wardrobe now. Choose them as footwear there."
	_say(inventory, text)
	inventory._haptic(side)
	SFX.play_purchase(item)
	print("[shop] bought %s for the wardrobe" % id)
	return true

## A short note on the wrist/HUD message line that clears itself unless replaced.
static func _say(inventory: Node, text: String) -> void:
	var bar: Node = inventory.get("hotbar")
	if not is_instance_valid(bar) or not bar.has_method("set_message"): return
	bar.set_message(text)
	if not inventory.is_inside_tree(): return
	inventory.get_tree().create_timer(MESSAGE_SECONDS).timeout.connect(func() -> void:
		if is_instance_valid(bar) and str(bar.get("message")) == text: bar.set_message(""))
