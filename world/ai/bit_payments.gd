extends RefCounted
## Paying ponies (dev 2026-10-28: "pay ponies needs to be a UI thing that causes a prompt letting
## the AI know it has the money now and every pony needs to have a wallet with how many bits they
## have. Models interpreting shit incorrectly can't affect gameplay like that"). Only the Pay panel
## (world/ui/pay_panel.gd) moves Anon's bits; the pony's model is told afterwards. Her model may
## pay Anon from her own purse with [pay_player: N] (pay_player below). Every pony's purse is saved with the world (world_context.state.pony_wallets) and her
## prompt shows what she holds (situation_line).
const LEDGER := preload("res://world/mechanics/ledger.gd")
const STATE_KEY := LEDGER.PURSES_KEY
const MAX_PURSE := LEDGER.MAX_PURSE

## What a pony carries before Anon ever pays her: 20-200 bits, the same in every world.
static func starting(id: String) -> int:
	return LEDGER.starting(id)

static func balance(context: Node, id: String) -> int:
	return LEDGER.purse(context, id)

## Moves `amount` bits from Anon's purse to pony `id`. Returns "" when paid, else why not.
## The move itself is world/mechanics/ledger.gd transfer() (one path for every payment, which also
## records the payment as a "paid" fact and her memory).
static func pay(game: Node, pony: Node3D, id: String, amount: int) -> String:
	if not is_instance_valid(game) or id.is_empty(): return "Nobody to pay."
	if amount <= 0: return "Nothing to pay."
	var context: Node = game.get("world_context")
	if not is_instance_valid(context) or bool(context.get("_read_only")): return "Bits cannot change hooves right now."
	var before := balance(context, id)
	var name := id.replace("_", " ").capitalize()
	var error: String = str(LEDGER.transfer(game, "player", id, amount, "pay_panel",
		{"pony": pony, "text": "Anon paid %s %d bits." % [name, amount], "witnesses": [id, "player"]}))
	if not error.is_empty(): return error
	print("[bits] Anon paid %s %d bits (her purse %d -> %d)" % [id, amount, before, balance(context, id)])
	return ""

## A pony pays Anon from her own purse ([pay_player: N], dev 2026-11-01: "add the ability for the
## ai to make ponies pay the player"). Her model chooses to pay; the game still bounds it: only bits
## she actually holds move, never more, and only into a writable world. Returns "" when paid.
static func pay_player(game: Node, pony: Node3D, id: String, amount: int) -> String:
	if not is_instance_valid(game) or id.is_empty(): return "Nobody to pay you."
	if amount <= 0: return "Name how many bits to give him."
	var context: Node = game.get("world_context")
	if not is_instance_valid(context) or bool(context.get("_read_only")): return "Bits cannot change hooves right now."
	var before := balance(context, id)
	var name := id.replace("_", " ").capitalize()
	var error: String = str(LEDGER.transfer(game, id, "player", amount, "pay_player",
		{"pony": pony, "say": "%s gave you %d bits." % [name, amount], "text": "%s paid Anon %d bits." % [name, amount], "witnesses": [id, "player"]}))
	if not error.is_empty(): return error
	print("[bits] %s paid Anon %d bits (her purse %d -> %d)" % [id, amount, before, balance(context, id)])
	return ""

## A short note on the wrist/HUD message line (same line as shop messages).
static func _say(inventory: Node, text: String) -> void:
	LEDGER.say(inventory, text)

## Her purse in her prompt's situation block.
static func situation_line(context: Node, id: String) -> String:
	return "- Your purse holds %d bits (Ponyville's money)." % balance(context, id)
