extends RefCounted
## Every letter Anon writes and every reply or note a pony writes back, kept in the world save
## (world_context.state.letters = {"serial", "rows": {id: row}}) beside celestia_replies, so every
## save slot carries its own post. Rows are never deleted: inventory "letter:<id>" items point at
## them. Past MAX_ROWS rows the oldest delivered or read letters from Anon lose their text and keep
## their one-line gist. Row fields: docs/LETTERS_PLAN_2026_10_29.md section 3.2.
const STATE_KEY := "letters"
const MAX_ROWS := 200
const KINDS := ["letter", "reply", "note"]
const DEFAULTS := {"id": "", "kind": "letter", "from": "player", "to": "", "stationery": "plain", "text": "",
	"status": "draft", "written_at": -1.0, "sent_at": -1.0, "delivered_at": -1.0, "due_at": -1.0,
	"craft": -1, "heart": -1, "score": -1, "gist": "", "reply_to": "", "reply_id": "", "appointment": "",
	"pinned": false, "pin_until": -1.0, "gift": "", "ai": "",
	# false: her reply booked a meeting he could not know of before reading it (letter_post.gd meeting_known).
	"meet_known": true,
	# M-AI-16: a relationship offer her reply makes in person when they next meet ("" none), its
	# state ("" waiting, "asked", "lapsed") and when he opened the reply; the letter waits on her
	# doorstep until she is home (letter_props.gd).
	"offer": "", "offer_state": "", "opened_at": -1.0, "doorstep": false}

## The live rows dictionary (created on first use); {} when there is no writable world.
static func rows(context: Node) -> Dictionary:
	var store: Variant = _store(context)
	return (store as Dictionary).rows if store is Dictionary else {}

## A copy of one row, {} if missing.
static func row(context: Node, id: String) -> Dictionary:
	var found: Variant = rows(context).get(id)
	return (found as Dictionary).duplicate(true) if found is Dictionary else {}

## A new row from DEFAULTS plus the known `fields`; returns its id ("" while read-only).
static func create(context: Node, fields: Dictionary) -> String:
	var store: Variant = _store(context)
	if not store is Dictionary or bool(context.get("_read_only")): return ""
	store.serial = int(store.get("serial", 0)) + 1
	var at := float(fields.get("written_at", fields.get("delivered_at", 0.0)))
	var id := "L%d-%d" % [maxi(0, int(floorf(at))), int(store.serial)]
	var made: Dictionary = DEFAULTS.duplicate(true)
	for key: String in fields:
		if made.has(key): made[key] = fields[key]
	made.id = id
	if str(made.kind) not in KINDS: made.kind = "letter"
	store.rows[id] = made
	_prune(store.rows)
	context.call("_changed")
	return id

## Merges known `fields` into row `id`; false when missing or read-only.
static func update(context: Node, id: String, fields: Dictionary) -> bool:
	var found: Variant = rows(context).get(id)
	if not found is Dictionary or bool(context.get("_read_only")): return false
	for key: String in fields:
		if DEFAULTS.has(key) and key != "id": found[key] = fields[key]
	context.call("_changed")
	return true

## The serial number in an id ("L12-7" -> 7), for oldest-first order.
static func serial_of(id: String) -> int:
	return id.get_slice("-", 1).to_int()

static func _prune(all: Dictionary) -> void:
	var excess := all.size() - MAX_ROWS
	if excess <= 0: return
	var ids: Array = all.keys()
	ids.sort_custom(func(a: String, b: String) -> bool: return serial_of(a) < serial_of(b))
	for id: String in ids:
		if excess <= 0: return
		var r: Dictionary = all[id]
		if r.kind != "letter" or r.from != "player" or str(r.status) not in ["delivered", "read"] or bool(r.pinned): continue
		r.text = ""
		excess -= 1

static func _store(context: Node) -> Variant:
	if not is_instance_valid(context) or not context.get("state") is Dictionary: return null
	var state: Dictionary = context.get("state")
	var store: Variant = state.get(STATE_KEY)
	if not store is Dictionary or not (store as Dictionary).get("rows") is Dictionary:
		if bool(context.get("_read_only")): return null
		store = {"serial": int((store as Dictionary).get("serial", 0)) if store is Dictionary else 0, "rows": {}}
		state[STATE_KEY] = store
	return store
