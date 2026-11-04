extends Node
## The facts stream (P1 of docs/MECHANICS_ARCHITECTURE_2026_11_01.md, section 3.1): every mechanic
## emits typed facts here ("gave", "paid", "made", "caught", "worked"...) and everything else reacts
## to facts instead of to each other (asks complete on them, bonds, gossip, events, achievements).
## Saved in world_context.state.facts: a ring of recent rows, idempotency keys and permanent
## counters. A fact with text is mirrored into world_context.record, so ponies remember it through
## the ordinary memory path (no extra prompt line). A fact without text only counts.
signal fact_added(row: Dictionary)
const ITEM_CATALOG := preload("res://world/inventory/item_catalog.gd")
const STATE_KEY := "facts"
const VERSION := 1
const GROUP := "mechanics_facts"
const MAX_ROWS := 600
const MAX_KEYS := 1024
const MAX_COUNTS := 2048
const TYPES := ["gave", "received", "paid", "bought", "sold", "made", "caught", "harvested", "planted",
	"watered", "grew", "worked", "hired", "asked", "ask_done", "ask_failed", "attended",
	"event_started", "event_ended", "restocked"]
## world_context.record kinds for facts that carry text and witnesses.
const MIRROR_KINDS := {"gave": "gift", "received": "gift", "paid": "payment", "bought": "trade", "sold": "trade",
	"made": "made", "caught": "catch", "harvested": "orchard", "planted": "farm", "watered": "farm", "grew": "farm",
	"worked": "work", "hired": "work", "asked": "favour", "ask_done": "favour", "ask_failed": "favour",
	"attended": "town_event", "event_started": "town_event", "event_ended": "town_event", "restocked": "trade"}
const ID_CHARS := 96
const TEXT_CHARS := 120

var context: Node

func _init() -> void:
	add_to_group(GROUP)

func bind(world_context: Node) -> void:
	context = world_context

static func of(tree: SceneTree) -> Node:
	return tree.get_first_node_in_group(GROUP) if tree != null else null

## For adapters in existing systems: adds the fact through the running Facts node, if any.
## Returns the fact id, or "" (no mechanics hub, read-only world, duplicate key).
static func note(from: Node, type: String, data: Dictionary, text := "", witnesses: Array = []) -> String:
	var tree: SceneTree = from.get_tree() if is_instance_valid(from) and from.is_inside_tree() else Engine.get_main_loop() as SceneTree
	var facts: Node = of(tree)
	return str(facts.call("add", type, data, text, witnesses)) if facts != null else ""

## Absolute game time: {"day", "hours", "at"} (at = day * 24 + hours).
static func clock() -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var time: Node = tree.root.get_node_or_null("TimeOfDay") if tree != null and tree.root != null else null
	if time == null: return {"day": 0, "hours": 0.0, "at": 0.0}
	var day: int = int(time.get("day"))
	var hours: float = float(time.get("hours"))
	return {"day": day, "hours": hours, "at": float(day) * 24.0 + hours}

static func _cut(value: Variant, size: int) -> String:
	return str(value).left(size) if value != null else ""

static func _number(value: Variant, fallback: int) -> int:
	return int(value) if (value is int or value is float) and is_finite(float(value)) else fallback

## Same rule as world_context.valid_id; businesses and the town never witness.
static func _witness_ok(id: Variant) -> bool:
	if not id is String or str(id).is_empty() or str(id).length() > 64 or str(id) == "town": return false
	for c: String in str(id):
		if not c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-": return false
	return true

func _writable() -> bool:
	return is_instance_valid(context) and not bool(context.get("_read_only")) and context.get("state") is Dictionary

## The saved block, read with type guards; {} when absent or malformed (never written here).
func _read() -> Dictionary:
	if not is_instance_valid(context) or not context.get("state") is Dictionary: return {}
	var block: Variant = (context.state as Dictionary).get(STATE_KEY)
	if not block is Dictionary: return {}
	var facts: Dictionary = block
	if not facts.get("rows") is Array or not facts.get("keys") is Dictionary or not facts.get("counts") is Dictionary: return {}
	return facts

## The block inside a state dictionary (the live world_context.state or a checkpoint copy of it),
## created (or replaced when malformed) for a write.
static func _state_block(state: Dictionary) -> Dictionary:
	var block: Variant = state.get(STATE_KEY)
	if block is Dictionary and (block as Dictionary).get("rows") is Array and (block as Dictionary).get("keys") is Dictionary and (block as Dictionary).get("counts") is Dictionary:
		return block
	var facts := {"version": VERSION, "serial": 0, "rows": [], "keys": {}, "counts": {}}
	state[STATE_KEY] = facts
	return facts

## The saved block, created (or replaced when malformed) for a write.
func _block() -> Dictionary:
	return _state_block(context.state)

## Writes the row a later add(type, data) will write into a checkpoint copy of the state (the
## snapshot_state() a durable save is about to write), so the checkpoint already holds the fact it
## goes with. Rows and counters only: memory text follows with the live add. False on a duplicate.
static func stage(state: Dictionary, type: String, data: Dictionary) -> bool:
	if not type in TYPES: return false
	return not _append(_state_block(state), type, data).is_empty()

## Appends one row to a facts block (ring, idempotency key, counters); {} on a duplicate key.
static func _append(facts: Dictionary, type: String, data: Dictionary) -> Dictionary:
	var key := _cut(data.get("key", ""), TEXT_CHARS)
	if not key.is_empty() and (facts.keys as Dictionary).has(key): return {}
	var serial: int = _number(facts.get("serial"), 0) + 1
	facts.serial = serial
	var time := clock()
	var row := {"id": "F%d" % serial, "type": type,
		"actor": _cut(data.get("actor", ""), ID_CHARS), "target": _cut(data.get("target", ""), ID_CHARS),
		"item": _cut(data.get("item", ""), ID_CHARS), "count": maxi(0, _number(data.get("count"), 1)),
		"amount": _number(data.get("amount"), 0), "place": _cut(data.get("place", ""), TEXT_CHARS),
		"ref": _cut(data.get("ref", ""), TEXT_CHARS), "day": int(time.day), "hours": float(time.hours), "at": float(time.at)}
	var rows: Array = facts.rows
	rows.append(row)
	while rows.size() > MAX_ROWS: rows.pop_front()
	if not key.is_empty():
		var keys: Dictionary = facts.keys
		keys[key] = row.at
		while keys.size() > MAX_KEYS: keys.erase(keys.keys()[0])
	_count(facts.counts, row)
	return row

## Adds one fact. `data` keys (all optional): actor, target, item, count, amount, place, ref, key.
## `key` makes it idempotent. Non-empty `text` with valid witnesses (default actor and target) is
## also remembered as a world event. Returns the fact id, or "" (read-only, unknown type, duplicate).
func add(type: String, data: Dictionary, text := "", witnesses: Array = []) -> String:
	if not type in TYPES or not _writable(): return ""
	var row := _append(_block(), type, data)
	if row.is_empty(): return ""
	context._changed()
	if not text.strip_edges().is_empty():
		var who: Array = []
		for id: Variant in (witnesses if not witnesses.is_empty() else [row.actor, row.target]):
			if _witness_ok(id) and id not in who: who.append(str(id))
		if not who.is_empty() and context.has_method("record"):
			context.record(str(MIRROR_KINDS.get(type, type)), text, who, who, "f-%s" % row.id, str(row.place).left(80))
	fact_added.emit(row.duplicate())
	return str(row.id)

## Permanent counters for "type||", "type|actor|" and "type|actor|item". When full, the most
## specific (item) counters go first, so the per-type and per-actor totals last longest.
static func _count(counts: Dictionary, row: Dictionary) -> void:
	var names: Array[String] = []
	for name: String in ["%s||" % row.type, "%s|%s|" % [row.type, row.actor], "%s|%s|%s" % [row.type, row.actor, row.item]]:
		if name not in names: names.append(name)
	for name: String in names:
		counts[name] = _number(counts.get(name), 0) + int(row.count)
	while counts.size() > MAX_COUNTS:
		var drop: String = str(counts.keys()[0])
		for name: Variant in counts:
			if not str(name).get_slice("|", 2).is_empty(): drop = str(name); break
		counts.erase(drop)

## Rows matching the filter, newest first. Filter keys (all optional): type (String or Array),
## actor, target, item, tag (the item carries it), ref, since_hours (absolute game hours).
func query(filter: Dictionary, limit := 32) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var facts := _read()
	if facts.is_empty() or limit <= 0: return result
	var types: Variant = filter.get("type")
	var since: float = float(filter.get("since_hours", -INF)) if (filter.get("since_hours") is int or filter.get("since_hours") is float) else -INF
	var rows: Array = facts.rows
	for index: int in range(rows.size() - 1, -1, -1):
		if not rows[index] is Dictionary: continue
		var row: Dictionary = rows[index]
		if types is String and str(row.get("type", "")) != types: continue
		if types is Array and not str(row.get("type", "")) in types: continue
		var skip := false
		for field: String in ["actor", "target", "item", "ref"]:
			if filter.has(field) and str(row.get(field, "")) != str(filter[field]): skip = true; break
		if skip: continue
		if filter.has("tag") and not ITEM_CATALOG.has_tag(str(row.get("item", "")), str(filter.tag)): continue
		if float(row.get("at", 0.0)) < since: continue
		result.append(row.duplicate())
		if result.size() >= limit: break
	return result

## Permanent counter "type|actor|item" (empty parts allowed); survives the ring.
func count(type: String, actor := "", item := "") -> int:
	var facts := _read()
	if facts.is_empty(): return 0
	return _number((facts.counts as Dictionary).get("%s|%s|%s" % [type, actor, item]), 0)

## Calls handler(row) for each new fact whose type is in `types` (empty = every type).
func subscribe(types: PackedStringArray, handler: Callable) -> void:
	fact_added.connect(func(row: Dictionary) -> void:
		if handler.is_valid() and (types.is_empty() or str(row.get("type", "")) in types): handler.call(row))
