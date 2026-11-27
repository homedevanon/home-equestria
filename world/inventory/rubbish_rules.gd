extends RefCounted
## What may be thrown away for good, and the throwing away itself, shared by Anon's rubbish bucket
## (world/inventory/assets/rubbish_bucket_item.gd) and the fixed rubbish bins at his door and in the
## market (world/props/rubbish_bin.gd, player board card 69).
##
## Refused, so they stay in the hand (or lie in the bin to be taken out again): books (their shelves
## own them), letters (the post keeps them, undelivered ones included), the notebook where open
## favours are written, the photo journal, the rubbish bucket, tools the game hands out and does not
## sell (the spa's hoof file, the leaf rake, the wagon wheel of the wheel errand), and clothes kept in
## the wardrobe for good. Money is bits, not an item, and the briefcase and the house key are not
## items, so none of them can reach a bin.
##
## A thing taken from a briefcase stack takes the rest of that stack with it (the dev's design for
## card 69: "a stack goes in whole"); units the other hand holds stay. Nothing is refunded.
const CATALOG := preload("res://world/inventory/item_catalog.gd")
const SHOP := preload("res://world/shop/shop_items.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
## Ids that are always kept.
const KEEP := ["photo-journal", "notebook", "rubbish-bucket"]
## Meta on an item body: [slot, msec], the briefcase slot it was drawn from while it hung over a bin's
## mouth in a hand (a drop takes the unit out of its stack first, so the slot is remembered before).
## A VR hand's held thing is frozen, which the mouth's Area3D does not see under Jolt, so the bin's
## hint (shown while the hand is over the mouth) renews it; it counts for STACK_MEMORY_MSEC after.
const STACK_META := &"rubbish_stack_slot"
const STACK_MEMORY_MSEC := 1500
const MESSAGE_SECONDS := 4.0

## "" when `id` may be thrown away, else the hotbar line that says why not.
static func refusal(id: String) -> String:
	if id.begins_with("book:"): return "Books go back on a shelf, not in the bin."
	if id.begins_with("letter:"): return "Letters are kept; put it away in the briefcase."
	if id in KEEP: return "That one is kept."
	if CATALOG.has_tag(id, "wardrobe"): return "Clothes are kept in the wardrobe."
	if CATALOG.has_tag(id, "tool") and SHOP.price_bits(id) <= 0: return "That one is needed; it is kept."
	return ""

## The briefcase inventory (briefcase_inventory.gd) that owns this item body, or null. Owned item
## bodies are its children, loose or in a hand.
static func bag_of(body: Node) -> Node:
	var bag: Node = body.get_parent() if is_instance_valid(body) else null
	if bag == null or not "inventory" in bag or not "loose" in bag or not "held" in bag: return null
	return bag

## A held body over a bin's mouth: remember the slot it came from while it is still drawn from it.
static func remember(body: Node) -> void:
	var bag := bag_of(body)
	if bag == null or not body.has_meta("token"): return
	var store: Object = bag.get("inventory")
	var loan: Variant = (store.get("loans") as Dictionary).get(str(body.get_meta("token", ""))) if store != null else null
	if loan is Dictionary and bool((loan as Dictionary).get("equipped", false)): body.set_meta(STACK_META, [int((loan as Dictionary).get("slot", -1)), Time.get_ticks_msec()])

## How many units go if `body` is thrown away now: it and the rest of the stack it is drawn from
## (units another hand holds stay). 1 for a thing that is not drawn from a stack.
static func stack_count(bag: Node, body: Node) -> int:
	var store: Object = bag.get("inventory") if bag != null else null
	var token := str(body.get_meta("token", "")) if is_instance_valid(body) else ""
	# An older store copy (a bundled mod pack not rebuilt yet) throws away one unit only.
	if store == null or not store.has_method("consume_stack") or not (store.get("loans") as Dictionary).has(token): return 1
	var loans: Dictionary = store.get("loans")
	var loan: Dictionary = loans[token]
	var slot := _stack_slot(loan, body)
	var slots: Array = store.get("slots")
	if slot < 0 or slot >= slots.size() or not slots[slot] is Dictionary or (slots[slot] as Dictionary).is_empty(): return 1
	if str((slots[slot] as Dictionary).get("id", "")) != str(loan.get("id", "")): return 1
	var count := int((slots[slot] as Dictionary).get("count", 0))
	for other: Variant in loans.values():
		if other is Dictionary and bool((other as Dictionary).get("equipped", false)) and int((other as Dictionary).get("slot", -1)) == slot: count -= 1
	return maxi(count, 0) + 1

## The slot whose stack goes with this thing: its own while it is drawn from it (in a hand), else the
## one remembered over the mouth just before it was let go; -1 for none.
static func _stack_slot(loan: Dictionary, body: Node) -> int:
	if bool(loan.get("equipped", false)): return int(loan.get("slot", -1))
	var memory: Variant = body.get_meta(STACK_META) if body.has_meta(STACK_META) else null
	if memory is Array and (memory as Array).size() == 2 and Time.get_ticks_msec() - int((memory as Array)[1]) <= STACK_MEMORY_MSEC:
		return int((memory as Array)[0])
	return -1

## The body left the mouth without being thrown away: forget the slot.
static func forget(body: Node) -> void:
	if is_instance_valid(body) and body.has_meta(STACK_META): body.remove_meta(STACK_META)

## Throws away `body` (an owned item, loose or in a hand) and the rest of its stack, through one
## saved briefcase transaction. Returns the hotbar line that was shown, "" when nothing happened
## (not owned, placed, or the store refused). A refused kind shows its line and stays as it is.
static func throw_away(bag: Node, body: RigidBody3D, at: Vector3, sound_from: Node3D) -> String:
	if bag == null or not is_instance_valid(body): return ""
	var store: Object = bag.get("inventory")
	var token := str(body.get_meta("token", ""))
	if store == null or token.is_empty() or not (store.get("loans") as Dictionary).has(token): return ""
	var loan: Dictionary = (store.get("loans") as Dictionary)[token]
	for key: String in ["furnishing_home", "picnic_deployed", "easel_open", "cooking"]:
		if loan.has(key): return ""
	var id := str(loan.get("id", ""))
	var refused := refusal(id)
	if not refused.is_empty():
		say(bag, refused)
		return refused
	var slot := _stack_slot(loan, body)
	var gone := 0
	if store.has_method("consume_stack"): gone = int(store.call("consume_stack", token, slot))
	# An older copy of the store (a bundled mod pack not rebuilt yet): one unit, as before.
	elif bool(store.call("consume", token)): gone = 1
	if gone <= 0: return ""
	_let_go(bag, body, token)
	SOUNDS.play_event(sound_from, "prop_harvest_deposit", {"intensity": 0.6}, at)
	var shown := _shown_name(id)
	print("[inventory] threw away %d x %s (%s)" % [gone, shown, id])
	var line := "Thrown away: %s." % shown if gone == 1 else "Thrown away: %s x%d." % [shown, gone]
	say(bag, line)
	return line

## The hand and loose-body clean-up after the loan ended (the steps of
## world/mechanics/stations/held_items.gd use_up).
static func _let_go(bag: Node, body: RigidBody3D, token: String) -> void:
	var held: Dictionary = bag.get("held")
	var side := ""
	for key: Variant in held:
		if held[key] == body: side = str(key)
	var loose: Variant = bag.get("loose")
	if loose is Dictionary: (loose as Dictionary).erase(token)
	if not side.is_empty():
		held.erase(side)
		var track: Variant = bag.get("_track")
		if track is Dictionary: (track as Dictionary).erase(side)
		if bag.has_method("_claim"): bag.call("_claim", side, false)
		if bag.has_method("_haptic"): bag.call("_haptic", side)
	body.queue_free()
	if not side.is_empty() and bag.has_method("_refresh_holding"): bag.call("_refresh_holding")

static func _shown_name(id: String) -> String:
	var shown := str(CATALOG.definition(id).get("name", ""))
	return shown if not shown.is_empty() else id

static func say(bag: Node, text: String) -> void:
	var bar: Variant = bag.get("hotbar")
	if not bar is Node or not is_instance_valid(bar) or not (bar as Node).has_method("set_message"): return
	(bar as Node).call("set_message", text, false, MESSAGE_SECONDS)
