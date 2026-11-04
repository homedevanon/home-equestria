extends RefCounted
## Anon's day so far, as one compact prompt line (thread report 2026-11-01: Anon left in the
## morning, worked a Hayburger shift, bought socks, came home in the evening, and his waifu said
## "Oh anon, you'll be late for work!"). The clock line told her the time, but nothing told her what
## he had done, so the model continued the morning thread. The facts stream
## (world/mechanics/facts.gd) already records his work, purchases, gifts and catches with game
## times; this reads today's rows about him.
##
## What she knows: a pony he dates, is engaged or married to, or lives with knows his whole day;
## anyone else only what involved her (she was the customer, the gift was hers). Gossip can widen
## this later. One line, a few clauses, so it costs a few dozen tokens.
const FACTS := preload("res://world/mechanics/facts.gd")
const CATALOG := preload("res://world/inventory/item_catalog.gd")
const KINDS := ["worked", "bought", "paid", "gave", "caught", "made", "harvested", "planted", "attended", "sold"]
const CLOSE_STAGES := ["dating", "engaged", "married"]
const WORK_PLACES := {"hayburger": "the Hayburger", "spa": "the day spa", "apple_bucking": "Sweet Apple Acres",
	"orchard": "Sweet Apple Acres", "orchard_bucking": "Sweet Apple Acres", "cider_stand": "the cider stand", "cider_press": "the cider press"}
const MAX_CLAUSES := 4
## Work that ended at least this long ago (game hours) is called over for the day.
const DONE_AFTER := 0.5

static func knows_all(tree: SceneTree, id: String) -> bool:
	var game: Node = _game(tree)
	var context: Node = game.get("world_context") if game != null else null
	var bonds: Node = context.get("player_bonds") if is_instance_valid(context) else null
	if not is_instance_valid(bonds) or not bonds.has_method("record_for"): return false
	var record: Dictionary = bonds.record_for(id)
	return str(record.get("stage", "")) in CLOSE_STAGES or not str(record.get("shared_home_id", "")).is_empty()

## Today's facts about Anon that pony `id` knows, newest first, since absolute game hour `since`
## (default: the start of today).
static func known_rows(tree: SceneTree, id: String, since := -1.0) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var facts: Node = FACTS.of(tree) if tree != null else null
	if facts == null: return result
	var now: Dictionary = FACTS.clock()
	var from: float = since if since >= 0.0 else float(now.day) * 24.0
	var all := knows_all(tree, id)
	for row: Dictionary in facts.query({"type": KINDS, "actor": "player", "since_hours": from}, 64):
		if all or str(row.get("target", "")) == id: result.append(row)
	return result

## "- Anon's day so far (as far as you know): worked at the Hayburger 09:10-12:40 (14 orders); bought
## striped socks (13:05). His work is over for today." or "" when she knows nothing of it.
static func line(tree: SceneTree, id: String) -> String:
	var rows := known_rows(tree, id)
	if rows.is_empty(): return ""
	var text := describe(rows)
	var now: Dictionary = FACTS.clock()
	var last_work := -1.0
	for row: Dictionary in rows:
		if str(row.get("type", "")) == "worked": last_work = maxf(last_work, float(row.get("at", 0.0)))
	if last_work >= 0.0 and float(now.at) - last_work >= DONE_AFTER:
		text += " His work is over for today; he is not due back at work until another day."
	return "- Anon's day so far (as far as you know): " + text

## Since a time (for the "hours have passed" note): "; meanwhile he worked at the Hayburger ..." or "".
static func since(tree: SceneTree, id: String, since_at: float) -> String:
	var rows := known_rows(tree, id, since_at)
	return "" if rows.is_empty() else describe(rows)

## Clauses for rows (newest first in, oldest first out), at most MAX_CLAUSES, ending in a full stop.
static func describe(rows: Array[Dictionary]) -> String:
	var clauses: Array[String] = []
	var work := {}      # place -> [first at, last at, count]
	var order: Array[String] = []
	var other: Array[Dictionary] = []
	for index: int in range(rows.size() - 1, -1, -1):
		var row: Dictionary = rows[index]
		if str(row.get("type", "")) == "worked":
			var place := _work_place(str(row.get("ref", "")))
			if not work.has(place): work[place] = [float(row.at), float(row.at), 0]; order.append("work:" + place)
			work[place][1] = float(row.at); work[place][2] = int(work[place][2]) + maxi(1, int(row.get("count", 1)))
		else:
			other.append(row); order.append("row:%d" % (other.size() - 1))
	for key: String in order:
		if clauses.size() >= MAX_CLAUSES: break
		if key.begins_with("work:"):
			var place := key.trim_prefix("work:")
			var span: Array = work[place]
			var times := _time(float(span[0])) if is_equal_approx(float(span[0]), float(span[1])) else "%s-%s" % [_time(float(span[0])), _time(float(span[1]))]
			clauses.append("worked at %s %s (%d %s)" % [place, times, int(span[2]), "job" if int(span[2]) == 1 else "jobs"])
		else:
			var clause := _clause(other[int(key.trim_prefix("row:"))])
			if not clause.is_empty(): clauses.append(clause)
	return "" if clauses.is_empty() else "; ".join(clauses) + "."

static func _clause(row: Dictionary) -> String:
	var item := _item_name(str(row.get("item", "")))
	var who := _name(str(row.get("target", "")))
	var at := " (%s)" % _time(float(row.get("at", 0.0)))
	match str(row.get("type", "")):
		"bought": return "bought %s%s" % [item if not item.is_empty() else "something", at]
		"sold": return "sold %s%s" % [item if not item.is_empty() else "something", at]
		"paid": return "paid %s %d bits%s" % [who if not who.is_empty() else "someone", int(row.get("amount", 0)), at]
		"gave": return "gave %s %s%s" % [who if not who.is_empty() else "someone", item if not item.is_empty() else "a gift", at]
		"caught": return "caught %s%s" % [item if not item.is_empty() else "a fish", at]
		"made": return "made %s%s" % [item if not item.is_empty() else "something", at]
		"harvested": return "harvested %s%s" % [item if not item.is_empty() else "apples", at]
		"planted": return "planted %s%s" % [item if not item.is_empty() else "something", at]
		"attended": return "went to %s%s" % [_place(str(row.get("ref", ""))), at]
	return ""

static func _work_place(ref: String) -> String:
	var key := ref.get_slice(":", 0)
	return str(WORK_PLACES.get(key, key.replace("_", " ") if not key.is_empty() else "a job"))

static func _place(ref: String) -> String:
	return ref.get_slice(":", 0).replace("_", " ") if not ref.is_empty() else "a town event"

static func _item_name(id: String) -> String:
	if id.is_empty(): return ""
	if CATALOG.has(id): return str(CATALOG.definition(id).get("name", id)).to_lower()
	return id.get_slice(":", id.get_slice_count(":") - 1).replace("-", " ").replace("_", " ")

static func _name(id: String) -> String:
	return id.replace("_", " ").capitalize() if not id.is_empty() and id != "player" else ""

static func _time(at: float) -> String:
	var minutes := posmod(roundi(at * 60.0), 24 * 60)
	return "%02d:%02d" % [minutes / 60, minutes % 60]

static func _game(tree: SceneTree) -> Node:
	if tree == null: return null
	var populations: Node = tree.get_first_node_in_group("pony_populations")
	return populations.get("host") if populations != null else null
