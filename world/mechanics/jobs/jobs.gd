extends Node
## Jobs (P4 of docs/MECHANICS_ARCHITECTURE_2026_11_01.md, section 7): one work contract for every
## job. A row in data/jobs.json names the employers, the unit of work, the wage and who pays it,
## the hours and the open condition; the shared parts are written once: the customer lease
## (customer_queue.gd), the shift clock and wage (job_shift.gd) and pay_unit(), the one unit pay
## call every job uses (wage to the worker through ledger.transfer with a receipt, the customer's
## payment to the employer or till, a "worked" fact). Hayburger, spa and apple bucking are rows;
## a cider stand is one more row. [offer_job: JOB] hires Anon for the day through hire().
## Developer flag `-- --old-jobs` (legacy.gd) keeps the pre-port venue code.
##
## Saved in world_context.state.jobs (created lazily, old saves load with defaults):
## {"version": 1, "hired": {job_id: {"day": int, "by": String}},
##  "units": {job_id: {"day": int, "player": int, "ponies": {id: int}}}, "shift_serial": int}
const LEDGER := preload("res://world/mechanics/ledger.gd")
const FACTS := preload("res://world/mechanics/facts.gd")
const STATE_KEY := "jobs"
const VERSION := 1
const GROUP := "mechanics_jobs"
const DATA_PATH := "res://world/mechanics/data/jobs.json"
const NAME_CHARS := 64

var context: Node
var game: Node
var facts: Node
var calendar: Node
var _specs: Dictionary = {}
var _order: Array[String] = []

func _init() -> void:
	add_to_group(GROUP)
	load_specs(DATA_PATH)

static func of(tree: SceneTree) -> Node:
	return tree.get_first_node_in_group(GROUP) if tree != null else null

func bind(world_context: Node, host: Node = null) -> void:
	context = world_context
	game = host

## Reads the job rows (malformed rows are skipped). Returns how many loaded.
func load_specs(path: String) -> int:
	_specs.clear(); _order.clear()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return 0
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or not (parsed as Dictionary).get("jobs") is Array: return 0
	for row: Variant in (parsed as Dictionary).jobs:
		if not row is Dictionary or not (row as Dictionary).get("id") is String or str((row as Dictionary).id).is_empty(): continue
		_specs[str(row.id)] = row
		_order.append(str(row.id))
	return _order.size()

func spec(id: String) -> Dictionary:
	var row: Variant = _specs.get(id)
	return row if row is Dictionary else {}

func ids() -> Array[String]:
	return _order.duplicate()

## The job whose id or name the model wrote ("cider stand", "Cider-Stand", "the spa"), or "".
func find_by_name(text: String) -> String:
	var wanted := text.strip_edges().to_lower().replace("-", " ").replace("_", " ").trim_prefix("the ").strip_edges()
	if wanted.is_empty(): return ""
	for id: String in _order:
		var row := spec(id)
		if wanted == id.replace("_", " ") or wanted == str(row.get("name", "")).to_lower(): return id
	for id: String in _order:
		if str(spec(id).get("name", "")).to_lower().contains(wanted) or wanted.contains(id.replace("_", " ")): return id
	return ""

# ------------------------------------------------------------------ state

func _writable() -> bool:
	return is_instance_valid(context) and not bool(context.get("_read_only")) and context.get("state") is Dictionary

static func _number(value: Variant, fallback: int) -> int:
	return int(value) if (value is int or value is float) and is_finite(float(value)) else fallback

## The saved block, read with guards ({} when absent or malformed; never written here).
func _read() -> Dictionary:
	if not is_instance_valid(context) or not context.get("state") is Dictionary: return {}
	var block: Variant = (context.state as Dictionary).get(STATE_KEY)
	if not block is Dictionary: return {}
	var jobs: Dictionary = block
	if not jobs.get("hired") is Dictionary or not jobs.get("units") is Dictionary: return {}
	return jobs

## The block for a write (created, or replaced when malformed). Callers check _writable() first.
func _block() -> Dictionary:
	var jobs := _read()
	if not jobs.is_empty(): return jobs
	var fresh := {"version": VERSION, "hired": {}, "units": {}, "shift_serial": 0}
	context.state[STATE_KEY] = fresh
	return fresh

func _today() -> int:
	return int(FACTS.clock().day)

func _hours() -> float:
	return float(FACTS.clock().hours)

## The next shift/unit serial, saved so a receipt never repeats after a reload (0 without a world).
func next_serial() -> int:
	if not _writable(): return 0
	var block := _block()
	var serial := _number(block.get("shift_serial"), 0) + 1
	block["shift_serial"] = serial
	context._changed()
	return serial

func units_today(job_id: String, worker := "player") -> int:
	var row: Variant = (_read().get("units", {}) as Dictionary).get(job_id)
	if not row is Dictionary or _number((row as Dictionary).get("day"), -1) != _today(): return 0
	if worker == "player": return maxi(_number((row as Dictionary).get("player"), 0), 0)
	var ponies: Variant = (row as Dictionary).get("ponies")
	return maxi(_number((ponies as Dictionary).get(worker), 0), 0) if ponies is Dictionary else 0

## Counts one unit of work done today (pay_unit does it; the orchard's checkpointed basket too).
func count_unit(job_id: String, worker := "player") -> void:
	if not _writable() or spec(job_id).is_empty(): return
	var units: Dictionary = _block().units
	var row: Variant = units.get(job_id)
	if not row is Dictionary or _number((row as Dictionary).get("day"), -1) != _today() or not (row as Dictionary).get("ponies") is Dictionary:
		row = {"day": _today(), "player": 0, "ponies": {}}
		units[job_id] = row
	if worker == "player": row["player"] = maxi(_number(row.get("player"), 0), 0) + 1
	else:
		var ponies: Dictionary = row.ponies
		ponies[worker] = maxi(_number(ponies.get(worker), 0), 0) + 1
		while ponies.size() > 32: ponies.erase(ponies.keys()[0])
	context._changed()

func hired(job_id: String) -> bool:
	var row: Variant = (_read().get("hired", {}) as Dictionary).get(job_id)
	return row is Dictionary and _number((row as Dictionary).get("day"), -1) == _today()

## Who hired Anon for this job today ("" when nobody did).
func hired_by(job_id: String) -> String:
	return str(((_read().get("hired", {}) as Dictionary).get(job_id, {}) as Dictionary).get("by", "")) if hired(job_id) else ""

# ------------------------------------------------------------------ open, offer, hire

## The town calendar (WP7): the bound one, else the hub's (it may be created after this module).
func _calendar() -> Node:
	if is_instance_valid(calendar): return calendar
	var parent := get_parent()
	var found: Variant = parent.get("calendar") if parent != null else null
	return found as Node if is_instance_valid(found) else null

func _season() -> String:
	var cal := _calendar()
	if cal != null and cal.has_method("season_name"): return str(cal.call("season_name"))
	var tree: SceneTree = get_tree() if is_inside_tree() else Engine.get_main_loop() as SceneTree
	var weather: Node = tree.get_first_node_in_group("weather") if tree != null else null
	return str(weather.get("season")) if is_instance_valid(weather) and weather.get("season") is String else ""

func _event_active(event_id: String) -> bool:
	var cal := _calendar()
	return cal != null and cal.has_method("active") and bool(cal.call("active", event_id))

## "" when the job takes work now, else why not: unknown job, its hours, its season, its event
## (an offer_any_day job is open on any non-winter day while Anon is hired for it) or the daily cap.
func is_open(id: String) -> String:
	var row := spec(id)
	if row.is_empty(): return "No such work"
	var hours: Variant = row.get("hours")
	if hours is Array and (hours as Array).size() == 2:
		var now := _hours()
		if now < float(hours[0]) or now >= float(hours[1]): return "Closed until %d:00" % int(hours[0])
	var open: Variant = row.get("open", {})
	var season := _season()
	var winter := season == "winter"
	if open is Dictionary:
		var not_in: Variant = (open as Dictionary).get("season_not")
		if not_in is Array and season in (not_in as Array): return "Not in %s" % season
		var event := str((open as Dictionary).get("event", ""))
		var cal := _calendar()
		var listed: bool = cal != null and cal.has_method("job_open") and bool(cal.call("job_open", id))
		if not event.is_empty() and not _event_active(event) and not listed:
			if not (bool(row.get("offer_any_day", false)) and not winter and hired(id)): return "Only during %s" % event.replace("_", " ")
	var cap := _number(row.get("daily_cap"), 0)
	if cap > 0 and units_today(id) >= cap: return "Enough work for today"
	return ""

## The jobs she could offer Anon now: she is an employer, the job is open (or offer_any_day and
## not winter), today's cap is not reached and Anon is not already hired for or working it today.
func offerable(pony_id: String) -> Array[String]:
	var found: Array[String] = []
	for id: String in _order:
		var row := spec(id)
		var employers: Variant = row.get("employers", [])
		if not employers is Array or not pony_id in (employers as Array): continue
		if hired(id) or units_today(id) > 0: continue
		var why := is_open(id)
		if not why.is_empty() and not (bool(row.get("offer_any_day", false)) and why.begins_with("Only during") and _season() != "winter"): continue
		found.append(id)
	return found

## [offer_job] dispatch: records "hired" for today and the fact. {"status", "reason"}.
func hire(job_id: String, by: String) -> Dictionary:
	var row := spec(job_id)
	if row.is_empty(): return {"status": "failed", "reason": "You have no such work to offer now"}
	if not job_id in offerable(by): return {"status": "failed", "reason": "Anon is already hired for that today" if hired(job_id) else "You have no such work to offer now"}
	if not _writable(): return {"status": "failed", "reason": LEDGER.BUSY}
	var block := _block()
	(block.hired as Dictionary)[job_id] = {"day": _today(), "by": by}
	context._changed()
	var name := str(row.get("name", job_id.replace("_", " ")))
	var who := by.replace("_", " ").capitalize()
	_fact("hired", {"actor": by, "target": "player", "ref": job_id, "key": "hired:%s:%d" % [job_id, _today()]},
		"%s hired Anon for the %s today." % [who, name], [by, "player"])
	return {"status": "completed", "reason": "Anon is hired for the %s today" % name}

func _fact(type: String, data: Dictionary, text := "", witnesses: Array = []) -> void:
	if is_instance_valid(facts): facts.call("add", type, data, text, witnesses)
	else: FACTS.note(self, type, data, text, witnesses)

# ------------------------------------------------------------------ pay

## The unit wage of a row: wage.per_unit (int, or a table keyed by `kind`), else wage.tip.
static func unit_amount(row: Dictionary, kind := "") -> int:
	var wage: Variant = row.get("wage", {})
	if not wage is Dictionary: return 0
	var per_unit: Variant = (wage as Dictionary).get("per_unit")
	if per_unit is Dictionary: return _number((per_unit as Dictionary).get(kind), 0)
	if per_unit is int or per_unit is float: return _number(per_unit, 0)
	return _number((wage as Dictionary).get("tip"), 0)

## A payer list with "customer" replaced by the customer being served (dropped when there is none).
static func payers_for(listed: Variant, customer: String) -> Array:
	var payers: Array = []
	if listed is Array:
		for who: Variant in listed:
			var id := customer if str(who) == "customer" else str(who)
			if not id.is_empty() and id not in payers: payers.append(id)
	if payers.is_empty(): payers.append(LEDGER.TOWN)
	return payers

## The one unit pay call every job uses. Pays the unit wage (or `amount_override` when >= 0) to the
## worker ("player" or a pony id) from the row's payers ("tip_payers" for a tip job), "customer"
## meaning the customer pony; then, for a priced row, the customer's payment from customer_payers
## to the till or the employer. Receipt "job:<id>:<day>:<unit_ref>" (a repeated unit_ref pays once;
## an empty unit_ref takes the next saved serial). Adds the "worked" fact {actor: worker, target:
## customer, ref: job_id, count: 1} and counts the unit. Without a writable world (fixtures) the town
## pays the worker with no receipt, as the old venue paths did. Returns "" when paid, else why not.
func pay_unit(job_id: String, worker: String, unit_ref: String, customer := "", amount_override := -1, opts := {}) -> String:
	var row := spec(job_id)
	if row.is_empty(): return "No such work"
	var cap := _number(row.get("daily_cap"), 0)
	if cap > 0 and units_today(job_id, worker) >= cap: return "Enough work for today"
	var amount := amount_override if amount_override >= 0 else unit_amount(row, str(opts.get("kind", "")))
	var listed: Variant = row.get("tip_payers") if row.get("tip_payers") is Array else row.get("payers")
	var payers := payers_for(listed, customer)
	var host: Node = game if is_instance_valid(game) else _host()
	var pay_reason := str(opts.get("reason", "wage" if worker != "player" else ("tip" if row.get("tip_payers") is Array else "service")))
	var worked := {"actor": worker, "target": customer, "ref": job_id, "count": 1, "item": str(opts.get("item", "")), "amount": amount}
	# opts.extra: a payment inside a unit already counted (a spa feather): paid, but no "worked" fact or unit.
	var counts := not bool(opts.get("extra", false))
	if not _writable():
		if amount <= 0 or not LEDGER.TOWN in payers: return "Nothing to pay." if amount <= 0 else LEDGER.BUSY
		var plain := LEDGER.transfer(host, LEDGER.TOWN, worker, amount, pay_reason, {"payers": [LEDGER.TOWN]})
		if plain.is_empty() and counts: _fact("worked", worked)
		return plain
	var ref := unit_ref if not unit_ref.is_empty() else "s%d" % next_serial()
	var receipt := "job:%s:%d:%s" % [job_id, _today(), ref]
	if LEDGER.receipt_done(host, receipt): return ""
	var reason := ""
	if amount > 0:
		var pay_opts := {"payers": payers, "receipt": receipt, "facts": [["worked", worked]] if counts else []}
		for key: String in ["pony", "say", "text", "witnesses", "item"]:
			if opts.has(key): pay_opts[key] = opts[key]
		reason = LEDGER.transfer(host, str(payers[0]), worker, amount, pay_reason, pay_opts)
		if not reason.is_empty(): return reason
	elif counts:
		_fact("worked", worked)
	var price := _number(row.get("price"), 0)
	if price > 0 and not customer.is_empty():
		var till := str(row.get("till", ""))
		if till.is_empty():
			till = hired_by(job_id)
			var employers: Variant = row.get("employers", [])
			if till.is_empty() and employers is Array and not (employers as Array).is_empty(): till = str(employers[0])
		# A pony keeper serving at her own stand (P7 work_job.gd) still takes the customer's bits.
		if not till.is_empty() and till != customer:
			LEDGER.transfer(host, customer, till, price, "sale", {"payers": payers_for(row.get("customer_payers", ["customer", "town"]), customer),
				"receipt": receipt + ":sale", "item": str(opts.get("item", ""))})
	if counts: count_unit(job_id, worker)
	return reason

func _host() -> Node:
	var tree: SceneTree = get_tree() if is_inside_tree() else null
	var hub: Node = tree.get_first_node_in_group("mechanics") if tree != null else null
	return hub.get("game") as Node if hub != null else null

# ------------------------------------------------------------------ AI surface

## The hub's capability row: the jobs she can offer and one note line, or {} when none.
func ai_row(pony_id: String) -> Dictionary:
	var ids := offerable(pony_id)
	if ids.is_empty(): return {}
	var names: PackedStringArray = []
	var job_names := {}
	for id: String in ids:
		job_names[id] = str(spec(id).get("name", id))
		names.append("%s (%s)" % [id, job_names[id]])
	return {"jobs": ids, "job_names": job_names, "line": "- Work you could offer Anon today: %s ([offer_job: JOB])." % ", ".join(names)}
