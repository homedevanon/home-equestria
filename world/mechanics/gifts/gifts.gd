extends Node
## Gifts (P2a, docs/MECHANICS_ARCHITECTURE_2026_11_01.md 4.2): any giftable item Anon holds out to a
## pony (world/relationships/hand_feeding.gd) and what ponies hand back with [give: ITEM]. One rule
## for every gift: her taste for the item's tags (data/tastes.json) and its value set the bond it
## earns, with per-pony per-day diminishing returns; gifts only ever add friendship, never romance
## (fillies and spa clients take gifts as kind gestures). Her model hears one compact observed line
## and reacts in character. What she keeps becomes her belonging (belongings.gd), shown in her
## home and available to give back. Every gift is a "gave" fact; every give-back a "received" fact.
const ITEM_CATALOG := preload("res://world/inventory/item_catalog.gd")
const FACTS := preload("res://world/mechanics/facts.gd")
const LEDGER := preload("res://world/mechanics/ledger.gd")
const HAND_OVER := preload("res://world/mechanics/hand_over.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
const AWARENESS := preload("res://world/ai/pony_awareness.gd")
const STORE := preload("res://world/inventory/inventory_store.gd")
const TASTES_PATH := "res://world/mechanics/data/tastes.json"
const LOG_KEY := "gift_log"               # {pony_id: {"day": int, "count": int}}
const SIGNATURE_KEY := "signature_given"  # {pony_id: day}
const DIMINISH := [1.0, 0.5, 0.25]        # 1st, 2nd, 3rd gift to her today; 4th+ = 0
const MAX_POINTS := 5
const MAX_VALUE := 500
const GIVE_RANGE := 3.0                   # Anon's camera to her, for [give]
const GAZE_RELEASE := 2.5
## The kind word in her note: the first of these tags the item carries.
const KIND_WORDS := [["home_good", "home good"], ["book", "book"], ["painting", "painting"], ["photo", "photo"],
	["sweet", "sweet"], ["drink", "drink"], ["meal", "meal"], ["wear", "wear"], ["apple", "apple"], ["cider", "cider"],
	["fabric", "fabric"], ["tea", "tea"], ["plant", "plant"]]
const TASTE_LINES := {2: "You love that kind of thing.", 1: "You like that kind of thing.", 0: "", -1: "It is not really your thing."}
static var _tastes: Dictionary = {}

var context: Node      # world_context
var game: Node         # inventory, director (both optional)
var belongings: Node   # belongings.gd
var facts: Node        # facts.gd
var market: Node       # market.gd (stock from WP8)

## Per-pony taste rows {love, like, dislike, signature} plus "default"; signature ids that are not
## catalogue items are dropped with a warning.
static func tastes() -> Dictionary:
	if not _tastes.is_empty(): return _tastes
	_tastes = {"default": {"love": [], "like": [], "dislike": [], "signature": []}}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(TASTES_PATH))
	if not parsed is Dictionary:
		push_warning("tastes.json is missing or invalid; every pony has the default taste")
		return _tastes
	for pony: Variant in parsed:
		var row: Variant = (parsed as Dictionary)[pony]
		if not pony is String or not row is Dictionary: continue
		var clean := {}
		for field: String in ["love", "like", "dislike", "signature"]:
			var list: Array[String] = []
			var given: Variant = (row as Dictionary).get(field, [])
			if given is Array:
				for value: Variant in given:
					if not value is String: continue
					if field == "signature" and not ITEM_CATALOG.has(str(value)):
						push_warning("tastes.json: %s signature %s is not an item" % [pony, value]); continue
					list.append(str(value))
			clean[field] = list
		_tastes[str(pony)] = clean
	return _tastes

static func taste(pony_id: String) -> Dictionary:
	var table := tastes()
	return table.get(pony_id, table.default)

## -1 dislike, 0 neutral, 1 like, 2 love (love beats dislike beats like).
static func liking(pony_id: String, item_id: String) -> int:
	var row := taste(pony_id)
	var tags := ITEM_CATALOG.tags(item_id)
	var found := {"love": false, "dislike": false, "like": false}
	for field: String in found:
		for tag: String in row.get(field, []):
			if tag in tags: found[field] = true; break
	return 2 if found.love else (-1 if found.dislike else (1 if found.like else 0))

## Bond points before diminishing returns: liking times a value bonus, 0..5.
static func base_points(liking_value: int, value: int) -> float:
	var mult: float = [0.0, 1.0, 2.0, 3.0][clampi(liking_value, -1, 2) + 1]
	var v := clampi(value, 0, MAX_VALUE)
	return mult * (1.0 + log(1.0 + float(v)) / log(2.0) / 3.0)

func _day() -> int:
	return int(FACTS.clock().day)

func _writable() -> bool:
	return is_instance_valid(context) and not bool(context.get("_read_only")) and context.get("state") is Dictionary

func _state_dict(key: String) -> Dictionary:
	if not is_instance_valid(context) or not context.get("state") is Dictionary: return {}
	var block: Variant = (context.state as Dictionary).get(key)
	return block if block is Dictionary else {}

## Gifts Anon already gave her today (the log resets when the day changes).
func gifts_today(pony_id: String) -> int:
	var row: Variant = _state_dict(LOG_KEY).get(pony_id)
	if not row is Dictionary or int(FACTS._number((row as Dictionary).get("day"), -1)) != _day(): return 0
	return maxi(0, FACTS._number((row as Dictionary).get("count"), 0))

## Bond points (0..5) this gift is worth now, before it is logged.
func points(pony_id: String, item_id: String) -> int:
	var n := gifts_today(pony_id)
	var factor: float = DIMINISH[n] if n < DIMINISH.size() else 0.0
	return clampi(roundi(base_points(liking(pony_id, item_id), ITEM_CATALOG.value(item_id)) * factor), 0, MAX_POINTS)

## True when handing her this item serves her open job order (a leased job customer, meta
## "job_customer", with an open "job" ask for exactly this item or tag): a sale, not a gift.
## Anything else handed to a customer (a book, a scarf) is still a real gift.
func is_sale(pony: Node, pony_id: String, item_id: String) -> bool:
	if not is_instance_valid(pony) or not pony.has_meta("job_customer") or pony_id.is_empty(): return false
	var asks: Variant = get_parent().get("asks") if get_parent() != null else null
	if not asks is Node or not (asks as Node).has_method("open_rows"): return false
	var item := ITEM_CATALOG.canonical(item_id)
	for row: Dictionary in (asks as Node).call("open_rows"):
		if str(row.get("from", "")) != pony_id or str(row.get("source", "")) != "job": continue
		var want := str(row.get("want", ""))
		var rest := want.substr(want.get_slice(":", 0).length() + 1)
		var at := rest.rfind(":")
		var wanted := rest.left(at) if at > 0 and rest.substr(at + 1).is_valid_int() else rest
		if want.begins_with("item:") and item == wanted: return true
		if want.begins_with("tag:") and ITEM_CATALOG.has_tag(item, wanted): return true
	return false

## Called by hand_feeding after any successful gift (food "feed", wear "wear", other "gift"): the
## bond, the "gave" fact, her observed line and her gaze back to her own business.
func received(pony: Node3D, pony_id: String, item_id: String, ref := "gift") -> void:
	if pony_id.is_empty(): return
	# A paying customer being served at a job (the cider stand, P5: meta "job_customer"): the "gave"
	# fact completes her order ask; it is a sale, not a gift (no bond points, no paid model line).
	if is_sale(pony, pony_id, item_id):
		if is_instance_valid(facts):
			facts.add("gave", {"actor": "player", "target": pony_id, "item": item_id, "count": 1, "amount": ITEM_CATALOG.value(item_id), "ref": "serve"})
		_release_gaze(pony)
		return
	# Her live [buy] offer for this item (market.gd, P7): she pays Anon; a sale is not a gift, so no
	# bond points and no "gave" fact (the market writes "sold"/"bought").
	if is_instance_valid(market) and market.has_method("complete_buy") and bool(market.call("complete_buy", pony, pony_id, item_id)):
		_release_gaze(pony)
		return
	var like := liking(pony_id, item_id)
	var worth := points(pony_id, item_id)
	var n := gifts_today(pony_id)
	var day := _day()
	if _writable():
		var gift_log: Variant = context.state.get(LOG_KEY)
		if not gift_log is Dictionary:
			gift_log = {}
			context.state[LOG_KEY] = gift_log
		(gift_log as Dictionary)[pony_id] = {"day": day, "count": n + 1}
		context._changed()
		var impressions: Variant = context.get("impressions")
		if worth > 0 and is_instance_valid(impressions):
			impressions.commit(pony_id, {"friendship": worth}, "gift:%s:%d:%d" % [pony_id, day, n])
	if is_instance_valid(facts):
		facts.add("gave", {"actor": "player", "target": pony_id, "item": item_id, "count": 1, "amount": ITEM_CATALOG.value(item_id), "ref": ref})
	# Every told line is a paid model request: past the third gift of her day (worth nothing more)
	# she just takes it, and the gift record already tells her model next time they talk.
	if n < DIMINISH.size(): _tell(pony, pony_id, note(pony, item_id, like))
	_release_gaze(pony)

## Her one observed line: "Anon gave you a tea set (home good, worth 25 bits). You like that kind of thing."
static func note(pony: Node3D, item_id: String, like: int) -> String:
	var tags := ITEM_CATALOG.tags(item_id)
	var kind := "a gift"
	for pair: Array in KIND_WORDS:
		if str(pair[0]) in tags: kind = str(pair[1]); break
	var value := ITEM_CATALOG.value(item_id)
	var detail := "%s, worth %d bits" % [kind, value] if value > 0 else kind
	var text := "Anon gave you %s (%s). %s" % [phrase(item_id), detail, str(TASTE_LINES.get(clampi(like, -1, 2), ""))]
	if is_instance_valid(pony) and pony.has_meta("spa_client"): text = text.strip_edges() + " It is a kind gesture, not romance."
	return text.strip_edges()

## "a tea set", "an apple", "some oats", a book or painting by its title.
static func phrase(item_id: String) -> String:
	var name := str(ITEM_CATALOG.definition(item_id).get("name", "something"))
	if ITEM_CATALOG.is_book(item_id): return "a book, \"%s\"" % name
	if name.begins_with("Painting: "): return "a painting, \"%s\"" % name.substr(10)
	var lower := name.to_lower()
	for article: String in ["a ", "an ", "the ", "some "]:
		if lower.begins_with(article): return lower
	if lower.ends_with("s") and not lower.ends_with("ss"): return "some " + lower
	return ("an " if lower.left(1) in ["a", "e", "i", "o", "u"] else "a ") + lower

func _director() -> Node:
	var director: Variant = game.get("director") if is_instance_valid(game) else null
	return director as Node if is_instance_valid(director) else null

func _tell(_pony: Node3D, pony_id: String, line: String) -> void:
	var director := _director()
	if director != null and director.has_method("told_paid"): director.told_paid(pony_id, line)

## Her gaze stays on Anon while she takes it, then returns to her own business.
func _release_gaze(pony: Node3D) -> void:
	if not is_instance_valid(pony) or not pony.has_method("set_action_gaze") or not is_inside_tree(): return
	var camera: Node = get_viewport().get_camera_3d() if get_viewport() != null else null
	get_tree().create_timer(GAZE_RELEASE).timeout.connect(func() -> void:
		if not is_instance_valid(pony): return
		var target: Variant = pony.get("action_gaze_target")
		if target == null or (is_instance_valid(target) and (target == camera or target is Camera3D)): pony.set_action_gaze(null))

# --- give-back: [give: ITEM] -----------------------------------------------------------------

func _signature_today(pony_id: String) -> bool:
	return int(FACTS._number(_state_dict(SIGNATURE_KEY).get(pony_id), -1)) == _day()

## Things she could hand Anon now: {"id", "source": "belonging"|"stock"|"signature", "ref"} rows,
## one per id, belongings first.
func givables(pony_id: String) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var seen: Array[String] = []
	if is_instance_valid(belongings):
		for row: Dictionary in belongings.items(pony_id):
			var id := ITEM_CATALOG.canonical(str(row.id))
			if id in seen: continue
			seen.append(id); rows.append({"id": id, "source": "belonging", "ref": str(row.get("n", ""))})
	if is_instance_valid(market) and market.has_method("stock_of"):
		var stock: Variant = market.call("stock_of", pony_id)
		if stock is Array:
			for value: Variant in stock:
				var id := ITEM_CATALOG.canonical(str(value))
				if id in seen or not ITEM_CATALOG.has(id): continue
				seen.append(id); rows.append({"id": id, "source": "stock", "ref": ""})
	if not _signature_today(pony_id):
		for value: String in taste(pony_id).get("signature", []):
			var id := ITEM_CATALOG.canonical(value)
			if id in seen: continue
			seen.append(id); rows.append({"id": id, "source": "signature", "ref": ""})
	return rows

## The ids of givables() Anon can receive now: he is within GIVE_RANGE of her and his briefcase has
## room for that id. [] means no [give] capability.
func offerable(pony_id: String, pony: Node3D) -> Array[String]:
	var result: Array[String] = []
	if not _writable() or not is_instance_valid(pony) or not pony.is_inside_tree(): return result
	var inventory: Node = game.get("inventory") as Node if is_instance_valid(game) else null
	var store: Object = inventory.get("inventory") if is_instance_valid(inventory) else null
	if store == null or not bool(store.get("writable")): return result
	var camera: Node3D = inventory.get("camera") as Node3D
	if camera == null and get_viewport() != null: camera = get_viewport().get_camera_3d()
	if camera == null or not camera.is_inside_tree() or camera.global_position.distance_to(AWARENESS.point(pony)) > GIVE_RANGE: return result
	for row: Dictionary in givables(pony_id):
		if STORE._place(store.get("slots"), str(row.id), -1) >= 0: result.append(str(row.id))
	return result

## [give] dispatch: takes the item from its source, hands it to Anon (free hand, else briefcase).
## {"status": "completed"|"failed", "reason"}; a failed hand-over puts the source back.
func give_to_anon(pony_id: String, pony: Node3D, item_id: String) -> Dictionary:
	item_id = ITEM_CATALOG.canonical(item_id)
	var inventory: Node = game.get("inventory") as Node if is_instance_valid(game) else null
	if not _writable() or not is_instance_valid(inventory): return {"status": "failed", "reason": "Nothing can change hooves right now"}
	var source := ""
	var entry: Dictionary = {}
	for row: Dictionary in givables(pony_id):
		if str(row.id) == item_id: source = str(row.source); break
	if source == "belonging":
		entry = belongings.take_entry(pony_id, item_id)
		if entry.is_empty(): source = ""
	elif source == "stock":
		if not bool(market.call("take_from_stock", pony_id, item_id)): source = ""
	if source.is_empty(): return {"status": "failed", "reason": "You do not have that to give"}
	var where := HAND_OVER.give_to_anon(inventory, item_id)
	if where.is_empty():
		if source == "belonging": belongings.restore(pony_id, entry)
		elif source == "stock" and market.has_method("untake"): market.call("untake", pony_id, item_id)
		var store: Object = inventory.get("inventory")
		var why := str(store.get("last_error")) if store != null else ""
		return {"status": "failed", "reason": "Anon could not take it: " + (why if not why.is_empty() else "no room in his briefcase")}
	if source == "signature":
		var given: Variant = context.state.get(SIGNATURE_KEY)
		if not given is Dictionary:
			given = {}
			context.state[SIGNATURE_KEY] = given
		(given as Dictionary)[pony_id] = _day()
		context._changed()
	var name := pony_id.replace("_", " ").capitalize()
	var what := phrase(item_id)
	var text := "%s gave Anon %s." % [name, what]
	if is_instance_valid(facts):
		facts.add("received", {"actor": pony_id, "target": "player", "item": item_id, "count": 1, "amount": ITEM_CATALOG.value(item_id), "ref": source}, text, [pony_id, "player"])
	elif context.has_method("record"):
		context.record("gift", text, [pony_id, "player"], [pony_id, "player"])
	if is_instance_valid(pony): SFX.play_purchase(pony)
	LEDGER.say(inventory, "%s gave you %s." % [name, what])
	var label := str(ITEM_CATALOG.definition(item_id).get("name", item_id)).to_lower()
	return {"status": "completed", "reason": "Anon now has the %s in his %s" % [label, "hand" if where == "hand" else "briefcase"]}
