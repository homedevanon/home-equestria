extends RefCounted
## In-memory counter shift. Preload this script directly; no global class cache needed.
## Recipes and tray are ordered bottom-to-top. Only the front order can be served.
## clear discards the tray and a burnt patty, preserving a cooking/ready patty.
## start retries the same seed; quit resets to idle. No currency or save integration.
## Set external_customers before starting to admit only actual arrived ponies.
## earned_bits is a local tally. reward_sink(REWARD_BITS) must succeed before a serve commits;
## served_order is informational only and must never pay the wallet a second time.
## tips is a local service/score bonus, never an additional currency reward.

signal changed
signal event(kind: String, message: String)
signal served_order(order: Dictionary, reward: int)

const MAX_ADVANCE_SECONDS: float = 60.0 # Bound catch-up after a suspend; never end work.
const COOK_SECONDS: float = 5.0
const BURN_SECONDS: float = 17.0 # Total time on grill; twelve seconds to collect.
const QUEUE_LIMIT: int = 3
## A small tip per burger served; the shift wage is the real pay (player bug board #17: 20 bits
## for a 10-bit burger on top of the wage made no sense).
const REWARD_BITS: int = 3
const CUSTOMER_NAMES: Array[String] = [
	"Derpy", "Applejack", "Pinkie Pie", "Rainbow Dash", "Rarity", "Fluttershy",
	"Lyra", "Bon Bon", "Minuette", "Twilight Sparkle",
]
const MENU: Array[Dictionary] = [
	{"title": "Classic Hayburger", "recipe": ["bun", "patty", "lid"]},
	{"title": "Cheesy Hayburger", "recipe": ["bun", "patty", "cheese", "lid"]},
	{"title": "Garden Hayburger", "recipe": ["bun", "patty", "lettuce", "tomato", "lid"]},
	{"title": "Crunchy Hayburger", "recipe": ["bun", "patty", "lettuce", "lid"]},
	{"title": "Tomato Melt", "recipe": ["bun", "patty", "tomato", "cheese", "lid"]},
	{"title": "The Works", "recipe": ["bun", "patty", "lettuce", "tomato", "cheese", "lid"]},
	# Order variants (M-ACT-02; thread 2026-10-31: "Lyra asks for just hay, Rarity asks for only
	# the vegetables, Fluttershy asks for bread", three patties, a nothingburger). Rolled after the
	# base menu (VARIANT_CHANCE, or FAN_CHANCE for a pony in "fans", by customer id or display
	# name), from their own seeded generator so the base tickets of a seed stay the same.
	{"title": "Just Hay", "recipe": ["patty"], "variant": true, "fans": ["lyra", "lyra_heartstrings"]},
	{"title": "Veggie Stack", "recipe": ["bun", "lettuce", "tomato", "lid"], "variant": true, "fans": ["rarity"]},
	{"title": "Triple Hay Stack", "recipe": ["bun", "patty", "patty", "patty", "lid"], "variant": true, "fans": ["big_mcintosh", "rainbow_dash", "applejack"]},
	{"title": "Nothingburger", "recipe": ["bun", "lid"], "variant": true, "fans": ["fluttershy", "derpy", "derpy_hooves"]},
]
## The first BASE_MENU rows are the everyday menu the base roll picks from.
const BASE_MENU: int = 6
const VARIANT_CHANCE: float = 0.15
const FAN_CHANCE: float = 0.5

var external_customers: bool = false
var reward_sink: Callable

var _state: String = "idle"
var _elapsed: float = 0.0
var _score: int = 0
var _tips: int = 0
var _earned_bits: int = 0
var _served: int = 0
var _missed: int = 0
var _combo: int = 0
var _best_combo: int = 0
var _grill_state: String = "empty"
var _grill_started: float = -1.0
var _tray: Array[String] = []
var _orders: Array[Dictionary] = []
var _message: String = "Welcome to Hayburger! Work for as long as you like."
var _seed_value: int = 0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _next_arrival: float = 0.0
var _customer_count: int = 0
var _shift_number: int = 0
var _customer_names: Array[String] = CUSTOMER_NAMES.duplicate()


func start_shift(seed_value: int = 0) -> void:
	_reset()
	_seed_value = seed_value
	_rng.seed = seed_value
	_shift_number += 1
	_state = "playing"
	if external_customers:
		_notify("started", "Counter open! Waiting for a pony to arrive. Each correct hayburger earns a %d-bit tip." % REWARD_BITS)
	else:
		_add_automatic_order()
		_next_arrival = _arrival_delay()
		_notify("started", "%s would like a Classic: bottom bun, grilled hay patty, top bun. Take your time!" % _orders[0]["name"])


func set_customer_names(names: Array[String]) -> void:
	_customer_names.clear()
	for value: String in names:
		var customer_name: String = value.strip_edges()
		if not customer_name.is_empty() and not _customer_names.has(customer_name):
			_customer_names.append(customer_name)
	if _customer_names.is_empty():
		_customer_names = CUSTOMER_NAMES.duplicate()


func add_customer(customer_id: String, display_name: String) -> bool:
	if _state != "playing":
		return _reject("Start working before taking an order.")
	if customer_id.strip_edges().is_empty() or display_name.strip_edges().is_empty():
		return _reject("A customer needs an identity and a name.")
	for order: Dictionary in _orders:
		if String(order["customer_id"]) == customer_id:
			return _reject("That pony already has an order at the counter.")
	if _orders.size() >= QUEUE_LIMIT:
		return _reject("The counter has three orders already.")
	_add_order(customer_id, display_name.strip_edges())
	var newest: Dictionary = _orders.back()
	_notify("arrival", "%s would like a %s. Follow the first ticket in numbered order." % [newest["name"], newest["recipe_name"]])
	return true


func remove_customer(customer_id: String) -> void:
	# Runtime interruptions are not patience failures. No-op removals stay silent,
	# allowing the population bridge to reconcile its deferred queue snapshot.
	for index: int in range(_orders.size()):
		var order: Dictionary = _orders[index]
		if String(order["customer_id"]) == customer_id:
			_orders.remove_at(index)
			_notify("departed", "%s left the counter. Their ticket has been put away." % order["name"])
			return


func advance(delta: float) -> void:
	if _state != "playing" or not is_finite(delta) or delta <= 0.0:
		return
	# Visit timer boundaries chronologically, so a hitch cannot skip an arrival,
	# over-age a new customer, or turn a fresh patty straight into a ready one.
	# Clamp before addition to avoid overflow even for enormous finite deltas.
	var target: float = _elapsed + minf(delta, MAX_ADVANCE_SECONDS)
	# A bounded catch-up slice has fewer than 64 arrival, expiry and grill
	# boundaries. Huge deltas never create an unbounded event loop.
	for _step: int in range(64):
		if _elapsed >= target:
			break
		var boundary: float = target if external_customers else minf(target, _next_arrival)
		if _grill_state == "cooking":
			boundary = minf(boundary, _grill_started + COOK_SECONDS)
		elif _grill_state == "ready":
			boundary = minf(boundary, _grill_started + BURN_SECONDS)
		for order: Dictionary in _orders:
			boundary = minf(boundary, float(order["deadline"]))
		_elapsed = maxf(_elapsed, boundary)
		if _grill_state == "cooking" and _elapsed >= _grill_started + COOK_SECONDS:
			_grill_state = "ready"
			_notice("ready", "Hay patty is golden! Put a bottom bun down, then take the patty.")
		elif _grill_state == "ready" and _elapsed >= _grill_started + BURN_SECONDS:
			_grill_state = "burnt"
			_combo = 0
			_notice("burnt", "That patty got a little crispy. Clear it and grill a fresh one!")
		for index: int in range(_orders.size() - 1, -1, -1):
			var order: Dictionary = _orders[index]
			if _elapsed >= float(order["deadline"]):
				_orders.remove_at(index)
				_missed += 1
				_combo = 0
				_notice("missed", "%s had to head out. The next burger is a fresh start." % order["name"])
		if not external_customers and _elapsed >= _next_arrival:
			if _orders.size() < QUEUE_LIMIT:
				_add_automatic_order()
				var newest: Dictionary = _orders.back()
				_notice("arrival", "%s would like a %s. Serve the first ticket on the counter." % [newest["name"], newest["recipe_name"]])
			_next_arrival = _elapsed + _arrival_delay()
	changed.emit()


func act(action: String) -> bool:
	if action == "start":
		start_shift(_seed_value)
		return true
	if action == "quit":
		_reset()
		_notify("quit", "Counter closed. Come back for another shift whenever you like.")
		return true
	if _state != "playing":
		return _reject("Start a shift to open the counter.")
	match action:
		"grill":
			if _grill_state != "empty":
				return _reject("Clear the burnt patty first." if _grill_state == "burnt" else "There is already a patty on the grill.")
			_grill_state = "cooking"
			_grill_started = _elapsed
			_notify("grill", "One hay patty sizzling! It will be ready in five seconds.")
			return true
		"lift_patty":
			if _grill_state != "ready": return _reject("Only a golden patty is ready to lift.")
			_grill_state = "held"
			_notify("lifted", "Take the golden patty to the bottom bun.")
			return true
		"discard_patty":
			if _grill_state not in ["held", "burnt"]: return false
			_empty_grill()
			_notify("cleared", "Grill ready for a fresh patty.")
			return true
		"discard_tray":
			if _tray.is_empty(): return false
			_tray.clear()
			_notify("cleared", "Fresh tray ready.")
			return true
		"take_patty":
			if _grill_state not in ["ready", "held"]:
				return _reject("Only a golden, ready patty can go on a burger.")
			# A bun then one patty, or wherever the first ticket wants a patty next (just hay,
			# three patties).
			if (_tray.size() != 1 or _tray[0] != "bun") and not _fits_front("patty"):
				return _reject("Put a fresh bottom bun on the tray first.")
			_tray.append("patty")
			_empty_grill()
			_notify("ingredient", "Golden hay patty added. Follow the ticket in numbered order.")
			return true
		"bun":
			if not _tray.is_empty():
				return _reject("One burger per tray. Serve it or clear it first.")
			_tray.append("bun")
			_notify("ingredient", "Bottom bun ready. Add a golden hay patty next.")
			return true
		"lettuce", "tomato", "cheese", "lid":
			# Toppings need a patty, unless the first ticket is built without one (vegetables only,
			# a nothingburger).
			if (not _tray.has("patty") or _tray[0] != "bun") and not _fits_front(action):
				return _reject("Start with a bottom bun and a cooked hay patty.")
			if _tray.has("lid"):
				return _reject("The top bun closes this burger. Serve it or clear it.")
			if _tray.has(action):
				return _reject("That ingredient is already on the burger.")
			_tray.append(action)
			_notify("ingredient", "Top bun on! Ready to serve." if action == "lid" else "%s added." % action.capitalize())
			return true
		"serve":
			return _serve()
		"clear":
			if _tray.is_empty() and _grill_state != "burnt":
				return _reject("The tray is already clear.")
			_tray.clear()
			if _grill_state == "burnt":
				_empty_grill()
			_notify("cleared", "Fresh tray! Check the first ticket and try again.")
			return true
		_:
			return _reject("That is not a counter action.")


func snapshot() -> Dictionary:
	var orders: Array[Dictionary] = []
	for order: Dictionary in _orders:
		orders.append(_snapshot_order(order))
	var grill_age: float = maxf(0.0, _elapsed - _grill_started) if _grill_started >= 0.0 else 0.0
	return {
		"state": _state, "time_left": -1.0, "elapsed": _elapsed, "untimed": true,
		"score": _score, "tips": _tips, "earned_bits": _earned_bits,
		"served": _served, "missed": _missed,
		"combo": _combo, "best_combo": _best_combo,
		"grill_state": _grill_state,
		# Progress is cooking completion (0..1), held at 1 when ready/burnt.
		"grill_progress": clampf(grill_age / COOK_SECONDS, 0.0, 1.0),
		"grill_ready_in": maxf(0.0, COOK_SECONDS - grill_age) if _grill_state == "cooking" else 0.0,
		"grill_burn_in": maxf(0.0, BURN_SECONDS - grill_age) if _grill_state in ["cooking", "ready"] else 0.0,
		"tray": _tray.duplicate(), "orders": orders, "message": _message,
	}


func _serve() -> bool:
	if _orders.is_empty():
		return _reject("No customer at the counter yet. Another will be along soon.")
	var order: Dictionary = _orders[0]
	var wanted: Array[String] = []
	wanted.assign(order["recipe"])
	if not _tray.has("lid") and _tray != wanted:
		return _reject("Finish the burger with its top bun before serving.")
	var completed_order: Dictionary = _snapshot_order(order)
	var recipe: Array[String] = []
	recipe.assign(order["recipe"])
	if _tray != recipe:
		return _reject("That is not %s's order. Clear the tray and follow the first ticket, in numbered order." % order["name"])
	# Payment precedes all gameplay mutations. A failed atomic wallet save leaves
	# this exact burger/customer available for a retry, without a success signal.
	if reward_sink.is_valid() and not bool(reward_sink.call(REWARD_BITS)):
		return _reject("Payment save failed. Your burger and order are still here; try serving again.")
	var patience_ratio: float = clampf((float(order["deadline"]) - _elapsed) / float(order["patience_max"]), 0.0, 1.0)
	var tip: int = 2 + int(floor(patience_ratio * 10.0))
	_combo += 1
	_best_combo = maxi(_best_combo, _combo)
	var points: int = 100 + 15 * (recipe.size() - 3) + tip * 5 + mini(_combo - 1, 5) * 10
	_score += points
	_tips += tip
	_earned_bits += REWARD_BITS
	_served += 1
	_orders.pop_front()
	_tray.clear()
	if _orders.is_empty() and not external_customers:
		_next_arrival = minf(_next_arrival, _elapsed + 3.0)
	_notice("served", "%s loved it! %d-bit tip." % [order["name"], REWARD_BITS])
	served_order.emit(completed_order, REWARD_BITS)
	changed.emit()
	return true


func _add_automatic_order() -> void:
	var available_names: Array[String] = _customer_names.duplicate()
	for order: Dictionary in _orders:
		available_names.erase(String(order["name"]))
	if available_names.is_empty():
		available_names = _customer_names.duplicate()
	var customer: String = _customer_names[0] if _customer_count == 0 else available_names[_rng.randi_range(0, available_names.size() - 1)]
	var customer_id: String = "hayburger_guest_%d_%d" % [_shift_number, _customer_count + 1]
	_add_order(customer_id, customer)


func _add_order(customer_id: String, display_name: String) -> void:
	# The first three tickets teach plain, cheese, then two vegetables.
	var menu_index: int = _customer_count if _customer_count < 3 else _rng.randi_range(0, BASE_MENU - 1)
	if _customer_count >= 3:
		var variant: int = variant_for(customer_id, display_name, _seed_value, _shift_number, _customer_count)
		if variant >= 0: menu_index = variant
	var menu_item: Dictionary = MENU[menu_index]
	var recipe: Array[String] = []
	recipe.assign(menu_item["recipe"])
	var patience: float = 70.0 if _customer_count == 0 else _rng.randf_range(55.0, 70.0)
	_orders.append({
		"id": "hayburger_%d_%d" % [_shift_number, _customer_count + 1],
		"customer_id": customer_id, "name": display_name,
		"recipe_name": menu_item["title"], "recipe": recipe,
		"patience_max": patience, "deadline": _elapsed + patience,
	})
	_customer_count += 1


## The MENU index of an order variant for this customer's ticket, or -1 for the base menu. Its own
## generator (seed, shift, ticket number, customer), so the base roll's sequence is unchanged.
static func variant_for(customer_id: String, display_name: String, seed_value: int, shift_number: int, ticket: int) -> int:
	var roll := RandomNumberGenerator.new()
	roll.seed = hash("hayburger_variant:%d:%d:%d:%s" % [seed_value, shift_number, ticket, customer_id])
	var who := display_name.to_lower().strip_edges().replace(" ", "_")
	var variants: Array[int] = []
	for index: int in range(BASE_MENU, MENU.size()):
		var fans: Array = MENU[index].get("fans", [])
		if customer_id in fans or who in fans:
			return index if roll.randf() < FAN_CHANCE else -1
		variants.append(index)
	if variants.is_empty() or roll.randf() >= VARIANT_CHANCE: return -1
	return variants[roll.randi_range(0, variants.size() - 1)]


## True when the tray plus `piece` is still the first ticket's recipe from the bottom up.
func _fits_front(piece: String) -> bool:
	if _orders.is_empty(): return false
	var recipe: Array = _orders[0]["recipe"]
	if _tray.size() + 1 > recipe.size(): return false
	for index: int in range(_tray.size()):
		if _tray[index] != recipe[index]: return false
	return recipe[_tray.size()] == piece


func _snapshot_order(order: Dictionary) -> Dictionary:
	var recipe: Array[String] = []
	recipe.assign(order["recipe"])
	return {
		"id": order["id"], "customer_id": order["customer_id"], "name": order["name"],
		"recipe_name": order["recipe_name"], "recipe": recipe,
		"patience": maxf(0.0, float(order["deadline"]) - _elapsed),
		"patience_max": order["patience_max"],
	}


func _arrival_delay() -> float:
	var stage: int = mini(int(_elapsed / 60.0), 2)
	return _rng.randf_range(18.0, 23.0) - 3.0 * stage


func _reset() -> void:
	_state = "idle"
	_elapsed = 0.0
	_score = 0
	_tips = 0
	_earned_bits = 0
	_served = 0
	_missed = 0
	_combo = 0
	_best_combo = 0
	_customer_count = 0
	_next_arrival = 0.0
	_orders.clear()
	_tray.clear()
	_empty_grill()


func _empty_grill() -> void:
	_grill_state = "empty"
	_grill_started = -1.0


func _reject(message: String) -> bool:
	_notify("rejected", message)
	return false


func _notify(kind: String, message: String) -> void:
	_notice(kind, message)
	changed.emit()


func _notice(kind: String, message: String) -> void:
	_message = message
	event.emit(kind, message)
