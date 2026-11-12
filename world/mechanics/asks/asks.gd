extends Node
## Favours (P2b, docs/MECHANICS_ARCHITECTURE_2026_11_01.md 5.1): one request type for every source.
## A pony asks Anon for items or a kind of thing (2 apples, 3 sweets), to come to a place, to fetch
## another pony, to help at a job, or (an invitation) to come to a town event; she offers bits from
## her purse, something she really has, or thanks. Sources: her model ([ask], ask_rules.gd checks
## the words), a pony walking up to Anon with a favour, letters, town events, day-plan shortfalls
## and job orders. Completion comes only from facts (a "gave" fact to her, "worked", "attended")
## or from what the game sees (Anon at the place, the fetched pony beside her), never from the
## model's word. The reward runs through ledger.gd transfer (receipt "ask:<id>", so it pays once)
## or gifts.gd give_to_anon. Open favours are written in Anon's notebook (notebook_tool.gd).
## Saved in world_context.state.asks; old worlds simply have none.
signal changed
const ASK_RULES := preload("res://world/mechanics/asks/ask_rules.gd")
const FACTS := preload("res://world/mechanics/facts.gd")
const LEDGER := preload("res://world/mechanics/ledger.gd")
const PLACES := preload("res://world/navigation/place_directory.gd")
const ITEM_CATALOG := preload("res://world/inventory/item_catalog.gd")
const GROUP := "mechanics_asks"
const STATE_KEY := "asks"   # {"version":1, "serial":int, "rows":[open rows], "history":[last 32 closed], "ai_day": {pony: {"day":int,"n":int}}}
const VERSION := 1
const MAX_OPEN := 6
const MAX_OPEN_PER_PONY := 1
const MAX_AI_PER_PONY_PER_DAY := 2
const DEFAULT_HOURS := 6.0     # game hours
const MIN_HOURS := 0.25
const MAX_HOURS := 48.0
const HISTORY := 32
const TICK := 1.0
const COOLDOWN_HOURS := 1.0
const WHY_CHARS := 120
const PLACE_RADIUS := 6.0
## A finished favour whose reward could not be paid (her purse ran low, Anon's hooves and briefcase
## full) stays open as "owed"; she retries every OWED_RETRY game hours and gives up after OWED_HOURS.
const OWED_RETRY := 0.25
const OWED_HOURS := 48.0
const FETCH_RADIUS := 5.0
const FETCH_ANON_RADIUS := 12.0
## A non-AI favour while she is this far from Anon also comes as a note by Derpy's post.
const LETTER_RANGE := 60.0
const SOURCES := ["ai", "day_plan", "event", "letter", "job", "invite"]
## Job orders (cider stand) and invitations neither count against the caps nor block her favour.
const UNCAPPED := ["job", "invite"]
const NOTEBOOK_DONE := 4
const NOTEBOOK_EMPTY := "No favours asked yet."

var context: Node   # world_context
var game: Node      # inventory, director (optional)
var facts: Node     # facts.gd
var gifts: Node     # gifts/gifts.gd (item rewards)
## Tests: a fixed absolute game hour instead of TimeOfDay; Callable(location_id) -> Vector3.
var clock_override: Variant = null
var resolve_place := Callable()
var _tick := 0.0
var _subscribed := false
var _place_at: Dictionary = {}   # ask id -> resolved place point (houses and landmarks do not move)
var _owed_try: Dictionary = {}   # ask id -> game hour of the last payment try (not saved)

func _init() -> void:
	add_to_group(GROUP)

static func of(tree: SceneTree) -> Node:
	return tree.get_first_node_in_group(GROUP) if tree != null else null

## Completion by facts: Anon's gifts, his work and his attendance.
func connect_facts() -> void:
	if _subscribed or not is_instance_valid(facts): return
	_subscribed = true
	facts.subscribe(PackedStringArray(["gave", "worked", "attended"]), _on_fact)

func _now() -> float:
	if clock_override is float or clock_override is int: return float(clock_override)
	return float(FACTS.clock().at)

func _day() -> int:
	return int(floorf(_now() / 24.0))

func _writable() -> bool:
	return is_instance_valid(context) and not bool(context.get("_read_only")) and context.get("state") is Dictionary

## The saved block, read with type guards ({} when absent or malformed; never written here).
func _read() -> Dictionary:
	if not is_instance_valid(context) or not context.get("state") is Dictionary: return {}
	var block: Variant = (context.state as Dictionary).get(STATE_KEY)
	if not block is Dictionary or not (block as Dictionary).get("rows") is Array or not (block as Dictionary).get("history") is Array: return {}
	return block

func _block() -> Dictionary:
	var block := _read()
	if not block.is_empty():
		if not block.get("ai_day") is Dictionary: block["ai_day"] = {}
		return block
	block = {"version": VERSION, "serial": 0, "rows": [], "history": [], "ai_day": {}}
	context.state[STATE_KEY] = block
	return block

static func _valid_row(row: Variant) -> bool:
	return row is Dictionary and (row as Dictionary).get("id") is String and (row as Dictionary).get("from") is String \
		and (row as Dictionary).get("want") is String and (row as Dictionary).get("reward") is String

## Open rows, oldest first (copies).
func open_rows() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for row: Variant in _read().get("rows", []):
		if _valid_row(row): result.append((row as Dictionary).duplicate())
	return result

## Closed rows, newest first (copies).
func history_rows() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var rows: Array = _read().get("history", [])
	for index: int in range(rows.size() - 1, -1, -1):
		if _valid_row(rows[index]): result.append((rows[index] as Dictionary).duplicate())
	return result

## Her open favour (not job orders or invitations), or {}.
func open_for(pony_id: String) -> Dictionary:
	for row: Dictionary in open_rows():
		if str(row.from) == pony_id and not str(row.get("source", "")) in UNCAPPED: return row
	return {}

func _open_count() -> int:
	var n := 0
	for row: Dictionary in open_rows():
		if not str(row.get("source", "")) in UNCAPPED: n += 1
	return n

func ai_today(pony_id: String) -> int:
	var days: Variant = _read().get("ai_day")
	var row: Variant = (days as Dictionary).get(pony_id) if days is Dictionary else null
	if not row is Dictionary or FACTS._number((row as Dictionary).get("day"), -1) != _day(): return 0
	return maxi(0, FACTS._number((row as Dictionary).get("n"), 0))

## "" when she may ask Anon a favour with [ask] now, else the reason.
func can_ask(pony_id: String) -> String:
	var why := room_for(pony_id)
	if not why.is_empty(): return why
	if ai_today(pony_id) >= MAX_AI_PER_PONY_PER_DAY: return "You already asked Anon for two favours today"
	for row: Dictionary in history_rows():
		if str(row.from) != pony_id: continue
		if _now() - float(row.get("closed", -INF)) < COOLDOWN_HOURS: return "You just had a favour from Anon; give it an hour"
		break
	var bonds: Variant = context.get("player_bonds")
	if is_instance_valid(bonds) and (bonds as Node).has_method("knowledge"):
		var known: Variant = bonds.knowledge(pony_id)
		if known is Dictionary and not bool((known as Dictionary).get("met", false)): return "You have not met Anon yet"
	return ""

## Room for one more capped favour from her: "" or why not.
func room_for(pony_id: String) -> String:
	if not _writable(): return "Favours cannot be noted right now"
	var open := open_for(pony_id)
	if not open.is_empty():
		if str(open.get("status", "")) == "owed": return "You still owe Anon %s for a favour" % ASK_RULES.reward_words(str(open.reward))
		return "You already asked Anon a favour: " + ASK_RULES.describe(str(open.want), str(open.reward))
	if _open_count() >= MAX_OPEN: return "Anon already has plenty of favours to do"
	return ""

## The decode keys a letter reply needs for [ask] (letter_post.gd): {} when she has no room for a
## favour, else her purse, what she could give, her name and the ponies she knows.
func letter_context(pony_id: String) -> Dictionary:
	if not room_for(pony_id).is_empty(): return {}
	var items: Array = []
	if is_instance_valid(gifts) and gifts.has_method("givables"):
		for entry: Dictionary in gifts.givables(pony_id): items.append(str(entry.id))
	return {"purse": LEDGER.purse(context, pony_id), "ask_items": items, "ask_from": pony_id, "ask_ponies": _labels()}

## Returns {"ok": bool, "id": String, "error": String}. `want`/`reward` are normalised strings
## (ask_rules.gd); `hours` is how long it stays open, in game hours.
func create(from: String, want: String, reward: String, why: String, source: String, hours := DEFAULT_HOURS) -> Dictionary:
	if not source in SOURCES: return {"ok": false, "id": "", "error": "Unknown favour source"}
	if not FACTS._witness_ok(from): return {"ok": false, "id": "", "error": "Unknown pony"}
	if not _writable(): return {"ok": false, "id": "", "error": "Favours cannot be noted right now"}
	var bad := ASK_RULES.check_normal(want, reward)
	if not bad.is_empty(): return {"ok": false, "id": "", "error": bad}
	if want.begins_with("fetch:") and want.substr(6) == from: return {"ok": false, "id": "", "error": "Anon cannot fetch you to yourself"}
	# Nothing to do is no favour: Anon already at the place, the pony already beside her.
	if want.begins_with("place:"):
		var at: Variant = _place_point(want.substr(6))
		if at is Vector3 and _anon() != Vector3.INF and _anon().distance_to(at) <= PLACE_RADIUS: return {"ok": false, "id": "", "error": "Anon is already there"}
	if want.begins_with("fetch:") and _beside(from, want.substr(6)): return {"ok": false, "id": "", "error": "%s is already beside you" % _name(want.substr(6))}
	if source == "ai":
		var refused := can_ask(from)
		if not refused.is_empty(): return {"ok": false, "id": "", "error": refused}
	elif not source in UNCAPPED:
		var full := room_for(from)
		if not full.is_empty(): return {"ok": false, "id": "", "error": full}
	for row: Dictionary in open_rows():
		if str(row.from) == from and str(row.want) == want: return {"ok": false, "id": "", "error": "That is already in Anon's notebook"}
	if not is_finite(hours): hours = DEFAULT_HOURS
	var block := _block()
	var serial: int = FACTS._number(block.get("serial"), 0) + 1
	block.serial = serial
	var now := _now()
	var row := {"id": "A%d" % serial, "from": from, "want": want, "reward": reward, "why": why.strip_edges().left(WHY_CHARS),
		"source": source, "created": now, "until": now + clampf(hours, MIN_HOURS, MAX_HOURS), "progress": 0, "status": "open"}
	(block.rows as Array).append(row)
	if source == "ai":
		block.ai_day[from] = {"day": _day(), "n": ai_today(from) + 1}
	context._changed()
	var words := ASK_RULES.describe(want, reward, _labels())
	if is_instance_valid(facts):
		var item := _want_id(want) if want.begins_with("item:") else ""
		facts.add("asked", {"actor": from, "target": "player", "item": item, "count": _want_count(want), "ref": str(row.id)},
			"" if source == "job" else "%s asked Anon a favour: %s." % [_name(from), words], [from, "player"])
	if source in ["day_plan", "event"] and _far_from_anon(from):
		var post: Node = get_tree().get_first_node_in_group("letter_post") if is_inside_tree() else null
		if post != null and post.has_method("pony_writes"): post.call("pony_writes", from, "favour: " + words, "hopeful")
	changed.emit()
	return {"ok": true, "id": str(row.id), "error": ""}

## An invitation to a town event ([invite]): open until the event ends, completed by "attended".
## An event's own driver (the Trixie show runtime, group "event_drivers") may refuse: no
## invitation to a show the weather is spoiling (M-MEC-03, 2026-11-08).
func invite(from: String, event_id: String, why: String, hours := DEFAULT_HOURS) -> Dictionary:
	if is_inside_tree():
		for driver: Node in get_tree().get_nodes_in_group("event_drivers"):
			if not driver.has_method("invite_block"): continue
			var blocked := str(driver.call("invite_block", event_id))
			if not blocked.is_empty(): return {"ok": false, "id": "", "error": blocked}
	return create(from, "event:" + event_id, "thanks", why, "invite", hours)

func cancel(id: String, reason: String) -> bool:
	var row := _close(id, "cancelled")
	if row.is_empty(): return false
	row["outcome"] = reason.left(WHY_CHARS)
	return true

# --- Completion --------------------------------------------------------------------------------

func _process(delta: float) -> void:
	_tick -= delta
	if _tick > 0.0: return
	_tick = TICK
	tick()

## Once a second: expiry, and the place and fetch favours the game checks by looking.
func tick() -> void:
	var rows := open_rows()
	if rows.is_empty() or not _writable(): return
	var now := _now()
	for row: Dictionary in rows:
		if str(row.get("status", "")) == "owed":
			_retry_owed(row, now); continue
		if float(row.get("until", INF)) < now:
			_expire(row); continue
		var want := str(row.want)
		if want.begins_with("place:") and _anon_at_place(str(row.id), want.substr(6)): _done(str(row.id))
		elif want.begins_with("fetch:") and _fetched(str(row.from), want.substr(6)): _done(str(row.id))

func _on_fact(fact: Dictionary) -> void:
	if str(fact.get("actor", "")) != "player": return
	var type := str(fact.get("type", ""))
	for row: Dictionary in open_rows():
		if str(row.get("status", "")) == "owed": continue
		var want := str(row.want)
		var kind := want.get_slice(":", 0)
		var adds := 0
		match type:
			"gave":
				if str(fact.get("target", "")) != str(row.from): continue
				var item := ITEM_CATALOG.canonical(str(fact.get("item", "")))
				if kind == "item" and item == _want_id(want): adds = maxi(1, int(fact.get("count", 1)))
				elif kind == "tag" and ITEM_CATALOG.has_tag(item, _want_id(want)): adds = maxi(1, int(fact.get("count", 1)))
			"worked":
				var ref := str(fact.get("ref", ""))
				var job := _want_id(want)
				if kind == "job" and (ref == job or ref.begins_with(job + ":")): adds = maxi(1, int(fact.get("count", 1)))
			"attended":
				var event := want.substr(6)
				if kind == "event" and event in [str(fact.get("ref", "")), str(fact.get("target", "")), str(fact.get("item", ""))]: adds = 1
		if adds <= 0: continue
		var progress := _add_progress(str(row.id), adds)
		if progress >= _want_count(want): _done(str(row.id))
		# One fact serves one favour: two ponies who both want apples each need their own.
		return

func _add_progress(id: String, adds: int) -> int:
	for row: Variant in _block().rows:
		if _valid_row(row) and str(row.id) == id:
			row.progress = FACTS._number(row.get("progress"), 0) + adds
			context._changed()
			changed.emit()
			return int(row.progress)
	return 0

## Removes an open row into the history with `status`; returns the closed row ({} when not open).
func _close(id: String, status: String) -> Dictionary:
	if not _writable(): return {}
	var block := _block()
	var rows: Array = block.rows
	for index: int in rows.size():
		if not _valid_row(rows[index]) or str(rows[index].id) != id: continue
		var row: Dictionary = rows[index]
		rows.remove_at(index)
		row.status = status
		row.closed = _now()
		var history: Array = block.history
		history.append(row)
		while history.size() > HISTORY: history.pop_front()
		_place_at.erase(id)
		_owed_try.erase(id)
		context._changed()
		if context.has_method("save_soon"): context.save_soon()
		changed.emit()
		return row
	return {}

## Anon did it: she pays first; the row closes only once paid, else it stays open as "owed".
func _done(id: String) -> void:
	var row := _open_row(id)
	if row.is_empty(): return
	var from := str(row.from)
	var words := ASK_RULES.want_words(str(row.want), _labels())
	var paid := _pay(row)
	var outcome := str(paid.line)
	if bool(paid.ok):
		var closed := _close(id, "done")
		closed["outcome"] = outcome.left(WHY_CHARS)
	else:
		_set_owed(id, outcome)
	if str(row.get("source", "")) == "job":
		if is_instance_valid(facts): facts.add("ask_done", {"actor": "player", "target": from, "ref": str(row.id)})
		return
	var impressions: Variant = context.get("impressions")
	if is_instance_valid(impressions): impressions.commit(from, {"friendship": 1}, "askdone:" + str(row.id))
	if is_instance_valid(facts):
		facts.add("ask_done", {"actor": "player", "target": from, "ref": str(row.id), "item": _want_id(str(row.want)) if str(row.want).begins_with("item:") else ""},
			"Anon did %s's favour: %s." % [_name(from), words], [from, "player"])
	_tell(from, "Anon did the favour you asked: %s. %s" % [words, outcome])

## Pays the promised reward once (receipt "ask:<id>"). Returns the line her model hears.
func pay_reward(row: Dictionary) -> String:
	return str(_pay(row).line)

## {ok, line}: ok false when the bits or the item could not be handed over (she still owes him).
func _pay(row: Dictionary) -> Dictionary:
	var from := str(row.from)
	var id := str(row.id)
	var given := str(row.reward)
	var pony := _pony(from)
	if given.begins_with("bits:"):
		var n := int(given.substr(5))
		var why := LEDGER.transfer(game, from, "player", n, "reward", {"receipt": "ask:" + id, "pony": pony,
			"say": "%s paid you %d bits for the favour." % [_name(from), n], "text": "%s paid Anon %d bits for a favour." % [_name(from), n],
			"witnesses": [from, "player"]})
		if why.is_empty(): return {"ok": true, "line": "You paid him the %d bits you promised." % n}
		return {"ok": false, "line": "You could not pay him the %d bits you promised (%s); you still owe him." % [n, why.trim_suffix(".")]}
	if given.begins_with("item:"):
		var item := given.substr(5)
		var name := ASK_RULES.reward_words(given)
		if is_instance_valid(gifts) and gifts.has_method("give_to_anon"):
			var result: Dictionary = gifts.give_to_anon(from, pony, item)
			if str(result.get("status", "")) == "completed": return {"ok": true, "line": "You gave him %s as promised." % name}
		return {"ok": false, "line": "You could not hand him %s yet; you still owe him." % name}
	var impressions: Variant = context.get("impressions")
	if is_instance_valid(impressions): impressions.commit(from, {"friendship": 2}, "ask:" + id)
	return {"ok": true, "line": "He did it for your thanks."}

func _open_row(id: String) -> Dictionary:
	for row: Dictionary in open_rows():
		if str(row.id) == id: return row
	return {}

func _set_owed(id: String, outcome: String) -> void:
	for row: Variant in _block().rows:
		if _valid_row(row) and str(row.id) == id:
			row.status = "owed"
			row.owed = _now()
			row.outcome = outcome.left(WHY_CHARS)
			_owed_try[id] = _now()
			context._changed()
			if context.has_method("save_soon"): context.save_soon()
			changed.emit()
			return

## A favour Anon finished but she has not paid for yet: try again now and then, give up in time.
func _retry_owed(row: Dictionary, now: float) -> void:
	var id := str(row.id)
	if now - float(row.get("owed", now)) > OWED_HOURS:
		var closed := _close(id, "unpaid")
		if not closed.is_empty() and str(row.get("source", "")) != "job":
			_tell(str(row.from), "You never paid Anon the %s you owed him for his favour." % ASK_RULES.reward_words(str(row.reward)))
		return
	if now - float(_owed_try.get(id, -INF)) < OWED_RETRY: return
	_owed_try[id] = now
	var paid := _pay(row)
	if not bool(paid.ok): return
	var closed := _close(id, "done")
	closed["outcome"] = str(paid.line).left(WHY_CHARS)
	if str(row.get("source", "")) != "job": _tell(str(row.from), "You settled the favour you owed Anon. " + str(paid.line))

func _expire(row: Dictionary) -> void:
	# An invitation to an event that never took place (a rained-out show) is not Anon's failure.
	if str(row.get("source", "")) == "invite" and _event_missed(row):
		cancel(str(row.id), "The event did not take place")
		return
	var closed := _close(str(row.id), "expired")
	if closed.is_empty() or str(row.get("source", "")) == "job": return
	if is_instance_valid(facts):
		facts.add("ask_failed", {"actor": "player", "target": str(row.from), "ref": str(row.id)},
			"Anon did not manage %s's favour in time." % _name(str(row.from)), [str(row.from), "player"])

## The town calendar (town_calendar.gd missed) says the invited occurrence never started.
func _event_missed(row: Dictionary) -> bool:
	var calendar: Node = get_tree().get_first_node_in_group("town_calendar") if is_inside_tree() else null
	if calendar == null or not calendar.has_method("missed"): return false
	return bool(calendar.call("missed", str(row.want).trim_prefix("event:"), float(row.get("created", 0.0))))

func _anon_at_place(id: String, place: String) -> bool:
	var anon := _anon()
	if anon == Vector3.INF: return false
	if not _place_at.has(id):
		var at: Variant = _place_point(place)
		if at == null: return false
		_place_at[id] = at
	return anon.distance_to(_place_at[id]) <= PLACE_RADIUS

## The place's point, or null when it cannot be found.
func _place_point(place: String) -> Variant:
	var at: Variant = resolve_place.call(place) if resolve_place.is_valid() else (PLACES.resolve(get_tree(), place) if is_inside_tree() else Vector3.INF)
	return at if at is Vector3 and (at as Vector3).is_finite() else null

## The other pony already within FETCH_RADIUS of the asker (both loaded).
func _beside(asker: String, fetched: String) -> bool:
	var her := _pony(asker)
	var other := _pony(fetched)
	return her != null and other != null and other.global_position.distance_to(her.global_position) <= FETCH_RADIUS

## Both ponies loaded, the fetched one beside the asker and Anon with them.
func _fetched(asker: String, fetched: String) -> bool:
	var her := _pony(asker)
	var other := _pony(fetched)
	var anon := _anon()
	if her == null or other == null or anon == Vector3.INF: return false
	return other.global_position.distance_to(her.global_position) <= FETCH_RADIUS and anon.distance_to(her.global_position) <= FETCH_ANON_RADIUS

func _far_from_anon(pony_id: String) -> bool:
	var her := _pony(pony_id)
	var anon := _anon()
	return her == null or anon == Vector3.INF or anon.distance_to(her.global_position) > LETTER_RANGE

# --- Words ---------------------------------------------------------------------------------------

## Her one prompt line while she has an open favour: "- Your open favour for Anon: 2 apples for
## 10 bits, until 18:00." ("" otherwise).
func prompt_note(pony_id: String) -> String:
	var row := open_for(pony_id)
	if row.is_empty(): return ""
	if str(row.get("status", "")) == "owed":
		return "- Anon did your favour (%s); you still owe him %s." % [ASK_RULES.want_words(str(row.want), _labels()), ASK_RULES.reward_words(str(row.reward))]
	var so_far := ""
	var n := _want_count(str(row.want))
	if FACTS._number(row.get("progress"), 0) > 0 and n > 1: so_far = " (%d of %d so far)" % [int(row.progress), n]
	return "- Your open favour for Anon: %s%s, until %s." % [ASK_RULES.describe(str(row.want), str(row.reward), _labels()), so_far, _when(float(row.get("until", 0.0)))]

## The notebook's pages: open favours, invitations and the latest finished ones.
func notebook_text() -> String:
	var favours: PackedStringArray = []
	var invitations: PackedStringArray = []
	var labels := _labels()
	for row: Dictionary in open_rows():
		var source := str(row.get("source", ""))
		if source == "job": continue
		var until := _when(float(row.get("until", 0.0)))
		if source == "invite" or str(row.want).begins_with("event:"):
			var today := int(floorf(float(row.get("until", 0.0)) / 24.0)) == _day()
			invitations.append("- %s, %s (%s)." % [ASK_RULES.want_words(str(row.want), labels), ("today until " if today else "until ") + until, _name(str(row.from))])
			continue
		var reward := ASK_RULES.reward_words(str(row.reward))
		if str(row.get("status", "")) == "owed":
			favours.append("- %s: %s. Done; she still owes you %s." % [_name(str(row.from)), ASK_RULES.want_words(str(row.want), labels), reward])
			continue
		var n := _want_count(str(row.want))
		var so_far := ", %d done" % int(row.get("progress", 0)) if FACTS._number(row.get("progress"), 0) > 0 and n > 1 else ""
		favours.append("- %s: %s%s, %s. By %s." % [_name(str(row.from)), ASK_RULES.want_words(str(row.want), labels), so_far, reward.capitalize() if reward == "thanks" else reward, until])
	var done: PackedStringArray = []
	for row: Dictionary in history_rows():
		if done.size() >= NOTEBOOK_DONE: break
		if str(row.get("source", "")) == "job" or str(row.get("status", "")) == "cancelled": continue
		var how := ASK_RULES.reward_words(str(row.reward)) if str(row.status) == "done" else ("Never paid" if str(row.status) == "unpaid" else "missed")
		done.append("- %s: %s. %s." % [_name(str(row.from)), ASK_RULES.want_words(str(row.want), labels), how.capitalize() if how in ["thanks", "missed"] else how])
	if favours.is_empty() and invitations.is_empty() and done.is_empty(): return NOTEBOOK_EMPTY
	var lines: PackedStringArray = ["Favours"]
	if favours.is_empty(): lines.append("- None open.")
	lines.append_array(favours)
	if not invitations.is_empty():
		lines.append("Invitations"); lines.append_array(invitations)
	if not done.is_empty():
		lines.append("Done lately"); lines.append_array(done)
	return "\n".join(lines)

## "18:00" today, "day 4, 18:00" another day.
func _when(at: float) -> String:
	var day := int(floorf(at / 24.0))
	var hours := fposmod(at, 24.0)
	var clock := "%02d:%02d" % [int(hours), int(fmod(hours, 1.0) * 60.0)]
	return clock if day == _day() else "day %d, %s" % [day, clock]

static func _want_id(want: String) -> String:
	var rest := want.substr(want.get_slice(":", 0).length() + 1)
	var at := rest.rfind(":")
	return rest.left(at) if at > 0 and rest.substr(at + 1).is_valid_int() else rest

static func _want_count(want: String) -> int:
	if not (want.begins_with("item:") or want.begins_with("tag:") or want.begins_with("job:")): return 1
	var tail := want.get_slice(":", want.get_slice_count(":") - 1)
	return maxi(1, int(tail)) if tail.is_valid_int() else 1

# --- Lookups -------------------------------------------------------------------------------------

func _director() -> Node:
	var director: Variant = game.get("director") if is_instance_valid(game) else null
	return director as Node if is_instance_valid(director) else null

func _characters() -> Dictionary:
	var director := _director()
	var characters: Variant = director.get("characters") if director != null else null
	return characters if characters is Dictionary else {}

func _pony(id: String) -> Node3D:
	var entry: Variant = _characters().get(id)
	var node: Variant = (entry as Dictionary).get("node") if entry is Dictionary else null
	return node as Node3D if is_instance_valid(node) and node is Node3D and (node as Node3D).is_inside_tree() else null

func _name(id: String) -> String:
	var entry: Variant = _characters().get(id)
	var profile: Variant = (entry as Dictionary).get("profile") if entry is Dictionary else null
	if profile is Dictionary and (profile as Dictionary).get("name") is String: return str(profile.name)
	return id.replace("_", " ").capitalize()

## Pony display names, for "fetch Fluttershy" in the notebook.
func _labels() -> Dictionary:
	var labels := {}
	for id: Variant in _characters(): labels[str(id)] = _name(str(id))
	return labels

## Anon's eyes (the inventory's camera, else the viewport's), or INF.
func _anon() -> Vector3:
	var inventory: Variant = game.get("inventory") if is_instance_valid(game) else null
	var camera: Variant = (inventory as Node).get("camera") if is_instance_valid(inventory) else null
	if not (is_instance_valid(camera) and camera is Node3D and (camera as Node3D).is_inside_tree()):
		camera = get_viewport().get_camera_3d() if is_inside_tree() and get_viewport() != null else null
	return (camera as Node3D).global_position if is_instance_valid(camera) and (camera as Node3D).is_inside_tree() else Vector3.INF

## Her model hears it once ([Observed]); she reacts when free, else with his next line.
func _tell(pony_id: String, line: String) -> void:
	var director := _director()
	if director != null and director.has_method("told_paid"): director.told_paid(pony_id, line)
