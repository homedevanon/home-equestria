extends Node
## Stations (P3 of docs/MECHANICS_ARCHITECTURE_2026_11_01.md, section 6): one process spec for
## every physical place that turns inputs into outputs with someone working it. Rows live in
## world/mechanics/data/stations.json (station_rules.gd validates them):
##   process  inputs loaded, then `seconds` of work (crank turns, pony time) -> outputs;
##   grow     planted input -> output after `days` (the plot node owns its slots, state "plots");
##   adapter  an existing system (cooking, keg pour, orchard, fishing) that only declares itself
##            and reports what it made through note_made(); no state here.
## Anon and ponies run the same rules. A player output becomes an owned drop at the station; a
## pony's goes to the row's `stock_to` supply, else to the owner's belongings. Every completion is
## a "made" fact. Ponies are sent with [use: STATION] (request_use -> day_runner.inject_now ->
## world/life/day/actions/use_station.gd); unloaded ponies complete facts-only (offscreen_work).
## Saved in world_context.state.stations: {"version", "rows", "plots", "supply"}.
## Ticks at 1 Hz (pending player drops, the `ticked` signal for growers); no per-frame work.
signal produced(station_id: String, outputs: Array, worker: String)
## Once a second with the absolute game hour; grow stations (planting_plot.gd) check here.
signal ticked(at_hours: float)
const RULES := preload("res://world/mechanics/stations/station_rules.gd")
const FACTS := preload("res://world/mechanics/facts.gd")
const SEASON_STATE := preload("res://world/seasons/season_state.gd")
const ITEM_CATALOG := preload("res://world/inventory/item_catalog.gd")
const STATE_KEY := "stations"
const VERSION := 1
const DATA := "res://world/mechanics/data/stations.json"
const PLOT_SCRIPT := "res://world/mechanics/stations/planting_plot.gd"   # grow-slot rules (water_slot, tree_id)
const TICK := 1.0
const GROUP := "mechanics_stations"
## Physical station nodes (cider press, plot...) join this group; see station_input.gd.
const NODE_GROUP := "mechanics_station_nodes"
## Another worker's claim on a station lapses after this many game hours without work.
const BUSY_HOURS := 0.5
## A pony can be sent to a station this close (metres, ground plane).
const WORK_RANGE := 80.0
const WITNESS_RANGE := 15.0
const SUPPLY_CAP := 99
const PENDING_CAP := 8
## Each paid harvest basket (fact "harvested") puts this many apples into the press supply (6.6).
const APPLES_PER_BASKET := 8
const PRESS := "cider_press"
## Steps a [use] sends her on last this long (game minutes / hours until dropped).
const USE_MINUTES := 20.0
const USE_HOURS := 1.0

var context: Node
var game: Node
var facts: Node
var belongings: Node
var calendar: Node      # town_calendar.gd (WP7); looked up lazily when unset
var population: Node    # optional (tests); else group "pony_populations"
var inventory: Node     # optional (tests); else game.inventory
var errors := PackedStringArray()
var _specs: Dictionary = {}       # id -> row
var _order: Array[String] = []
var _subscribed: Node
var _timer: Timer

func _init() -> void:
	add_to_group(GROUP)
	load_specs(DATA)

static func of(tree: SceneTree) -> Node:
	return tree.get_first_node_in_group(GROUP) if tree != null else null

## For adapters in existing systems (cooking, keg pour, fishing): reports through the running
## Stations node; without one (no hub) it adds the same facts as before, if a Facts node runs.
static func note(from: Node, station_id: String, worker: String, outputs: Array, type := "made") -> void:
	var tree: SceneTree = from.get_tree() if is_instance_valid(from) and from.is_inside_tree() else Engine.get_main_loop() as SceneTree
	var stations: Node = of(tree)
	if stations != null:
		stations.note_made(station_id, worker, outputs, "", type); return
	for id: Variant in outputs:
		FACTS.note(from, type, {"actor": worker, "item": str(id), "ref": station_id})

func bind(world_context: Node, facts_node: Node = null) -> void:
	context = world_context
	if facts_node != null: facts = facts_node
	if is_instance_valid(facts) and _subscribed != facts and facts.has_method("subscribe"):
		_subscribed = facts
		facts.subscribe(PackedStringArray(["harvested"]), _on_harvested)

func _ready() -> void:
	_timer = Timer.new(); _timer.wait_time = TICK; _timer.autostart = true
	_timer.timeout.connect(_tick)
	add_child(_timer)

## Loads the rows from a file (the game's data, or a test's).
func load_specs(path: String) -> void:
	var loaded: Dictionary = RULES.load_file(path)
	_set_rows(loaded.rows, loaded.errors)

## Replaces the rows with a list (tests); malformed rows are left out (see `errors`).
func set_specs(list: Array) -> void:
	var parsed: Dictionary = RULES.parse_rows(list)
	_set_rows(parsed.rows, parsed.errors)

func _set_rows(rows: Array, problems: PackedStringArray) -> void:
	_specs.clear(); _order.clear()
	errors = problems
	for row: Dictionary in rows:
		_specs[str(row.id)] = row; _order.append(str(row.id))
	if not errors.is_empty(): print("[stations] rows left out: ", ", ".join(errors))

func spec(id: String) -> Dictionary:
	return _specs.get(id, {})

func specs() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for id: String in _order: rows.append(_specs[id])
	return rows

func display_name(id: String) -> String:
	return str(spec(id).get("name", id.replace("_", " ")))

# --- State ---------------------------------------------------------------------------------------

func _writable() -> bool:
	return is_instance_valid(context) and not bool(context.get("_read_only")) and context.get("state") is Dictionary

## The saved block for reading; {} when absent or malformed.
func _read() -> Dictionary:
	if not is_instance_valid(context) or not context.get("state") is Dictionary: return {}
	var block: Variant = (context.state as Dictionary).get(STATE_KEY)
	return block if block is Dictionary else {}

## The saved block for a write, created (or its parts repaired) lazily.
func _block() -> Dictionary:
	var state: Dictionary = context.state
	if not state.get(STATE_KEY) is Dictionary: state[STATE_KEY] = {"version": VERSION}
	var block: Dictionary = state[STATE_KEY]
	for key: String in ["rows", "plots", "supply"]:
		if not block.get(key) is Dictionary: block[key] = {}
	return block

static func _blank_row() -> Dictionary:
	return {"loaded": [], "worker": "", "started": 0.0, "touched": 0.0, "progress": 0.0, "pending": []}

## The live row for a write (writable world only).
func _row_live(id: String) -> Dictionary:
	var rows: Dictionary = _block().rows
	var current: Variant = rows.get(id)
	var row: Dictionary = current if current is Dictionary else {}
	var blank := _blank_row()
	for key: String in blank:
		if typeof(row.get(key)) != typeof(blank[key]) or (blank[key] is float and not is_finite(float(row.get(key)))): row[key] = blank[key]
	rows[id] = row
	return row

## The station's current state (a copy): loaded, worker, started, touched, progress, pending.
func row(id: String) -> Dictionary:
	var result := _blank_row()
	var rows: Variant = _read().get("rows")
	var saved: Variant = (rows as Dictionary).get(id) if rows is Dictionary else null
	if saved is Dictionary:
		for key: String in result:
			var value: Variant = (saved as Dictionary).get(key)
			if value is Array and result[key] is Array: result[key] = (value as Array).duplicate()
			elif value is String and result[key] is String: result[key] = value
			elif (value is float or value is int) and result[key] is float and is_finite(float(value)): result[key] = float(value)
	return result

## The live per-station block for a grow station's slots (planting_plot.gd), {} when read-only.
func plot_state(station_id: String) -> Dictionary:
	if not _writable(): return {}
	var plots: Dictionary = _block().plots
	if not plots.get(station_id) is Dictionary: plots[station_id] = {"slots": []}
	return plots[station_id]

## Marks the world changed after a writer edited plot_state() in place.
func changed() -> void:
	if _writable(): context._changed()

func _now() -> float:
	return float(FACTS.clock().at)

# --- Rules ---------------------------------------------------------------------------------------

func _calendar() -> Node:
	if is_instance_valid(calendar): return calendar
	var hub: Node = get_parent()
	var from_hub: Variant = hub.get("calendar") if hub != null else null
	if from_hub is Node and is_instance_valid(from_hub): return from_hub
	return get_tree().get_first_node_in_group("town_calendar") if is_inside_tree() else null

## The season name: the town calendar's (WP7), else the weather's, else season_state's formula on
## the day count (its offset and Settings season length; the old 7-day fallback is gone, M-SEA-04).
func season() -> String:
	var cal := _calendar()
	if cal != null and cal.has_method("season_name"): return str(cal.season_name())
	var weather: Node = get_tree().get_first_node_in_group("weather") if is_inside_tree() else null
	if weather != null and str(weather.get("season")) in RULES.SEASONS: return str(weather.get("season"))
	var index := SEASON_STATE.index_for(int(FACTS.clock().day), SEASON_STATE.current_season_days(), SEASON_STATE.current_offset())
	return str(RULES.SEASONS[index])

## "" when the station's season, hours and event needs hold now, else the reason.
func needs_met(id: String) -> String:
	var row_spec := spec(id)
	if row_spec.is_empty(): return "No such station"
	var cal := _calendar()
	var active := Callable(cal, "active") if cal != null and cal.has_method("active") else Callable()
	return RULES.needs_error(row_spec, season(), float(FACTS.clock().hours), active)

## "" when `worker` ("player" or a pony id) may work the station now, else the reason.
func can_work(id: String, worker: String) -> String:
	var row_spec := spec(id)
	if row_spec.is_empty(): return "No such station"
	if str(row_spec.kind) == "adapter": return "The %s is not worked that way" % display_name(id)
	var workers: Array = row_spec.get("workers", [])
	if not (worker in workers or (worker != "player" and "any_pony" in workers)): return "You do not work the %s" % display_name(id)
	var why := needs_met(id)
	if not why.is_empty(): return why
	var current := row(id)
	var other := str(current.worker)
	if not other.is_empty() and other != worker and _now() - float(current.touched) < BUSY_HOURS:
		return "%s is working the %s" % [_who(other), display_name(id)]
	# What it made for Anon waits while his briefcase is full; past PENDING_CAP he takes it first.
	if worker == "player" and (current.get("pending", []) as Array).size() >= PENDING_CAP:
		return "Take what the %s made first" % display_name(id)
	return ""

## "" when load_input would take `item_id` from `worker` now, else the reason; changes nothing.
## Callers check this BEFORE removing the item from its owner (Anon's loan, a pony's supply).
func can_load(id: String, worker: String, item_id: String) -> String:
	var row_spec := spec(id)
	if row_spec.is_empty() or str(row_spec.kind) != "process": return "Nothing goes into that"
	var why := can_work(id, worker)
	if not why.is_empty(): return why
	if not _writable(): return "The world cannot change right now"
	var loaded: Array = [] if _lapsed_player_load(id, worker) else row(id).loaded
	if RULES.free_input(row_spec, loaded, ITEM_CATALOG.canonical(item_id)) < 0:
		return "The %s is full" % display_name(id) if RULES.inputs_ready(row_spec, loaded) else "The %s does not take that" % display_name(id)
	return ""

## Process stations: an input already removed from its owner (Anon's loan consumed, or a pony
## supply decremented) goes in. "" or the reason it does not fit (can_load first: then never).
func load_input(id: String, worker: String, item_id: String) -> String:
	var why := can_load(id, worker, item_id)
	if not why.is_empty(): return why
	item_id = ITEM_CATALOG.canonical(item_id)
	_take_over(id, worker)
	var live := _row_live(id)
	(live.loaded as Array).append(item_id)
	_claim(live, worker)
	context._changed()
	return ""

func inputs_ready(id: String) -> bool:
	var row_spec := spec(id)
	return not row_spec.is_empty() and str(row_spec.kind) == "process" and RULES.inputs_ready(row_spec, row(id).loaded)

## Anon loaded it and his claim lapsed (BUSY_HOURS): a pony taking it over first.
func _lapsed_player_load(id: String, worker: String) -> bool:
	var current := row(id)
	return worker != "player" and str(current.worker) == "player" and not (current.loaded as Array).is_empty()

## A pony takes over a station Anon half loaded and left: his inputs come back to him (owned drops
## at the station, else waiting in pending) instead of going into her output.
func _take_over(id: String, worker: String) -> void:
	if not _lapsed_player_load(id, worker): return
	var live := _row_live(id)
	for item: Variant in (live.loaded as Array).duplicate():
		if not _drop_for_player(id, str(item)): (live.pending as Array).append(str(item))
	live.loaded = []; live.progress = 0.0; live.worker = ""; live.started = 0.0
	context._changed()

func _claim(live: Dictionary, worker: String) -> void:
	if str(live.worker) != worker or float(live.started) <= 0.0: live.started = maxf(_now(), 0.001)
	live.worker = worker
	live.touched = _now()

## Adds work seconds (crank turns, pony time); completes when progress reaches the row's seconds.
## Returns the outputs when this call completed it, else [].
func work(id: String, worker: String, seconds: float) -> Array[String]:
	var done: Array[String] = []
	if not is_finite(seconds) or seconds <= 0.0 or not can_work(id, worker).is_empty() or not _writable(): return done
	_take_over(id, worker)
	if not inputs_ready(id): return done
	var row_spec := spec(id)
	var live := _row_live(id)
	_claim(live, worker)
	live.progress = float(live.progress) + seconds
	if float(live.progress) < float(row_spec.seconds):
		context._changed()
		return done
	done = RULES.output_ids(row_spec)
	live.loaded = []; live.progress = 0.0; live.worker = ""; live.started = 0.0
	_route(row_spec, worker, done)
	context._changed()
	_made(id, worker, done, _witnesses(id, worker))
	return done

## Where outputs go: Anon's become owned drops at the station (pending while his briefcase is full);
## a pony's go to the row's `stock_to` supply, else to the owner's (or her own) belongings.
func _route(row_spec: Dictionary, worker: String, outputs: Array[String]) -> void:
	var id := str(row_spec.id)
	if worker == "player":
		for output: String in outputs:
			if not _drop_for_player(id, output):
				(_row_live(id).pending as Array).append(output)   # never discarded (can_work caps it)
		return
	var stock_to := str(row_spec.get("stock_to", ""))
	var keeper := str(row_spec.get("owner", "")) if not str(row_spec.get("owner", "")).is_empty() else worker
	for output: String in outputs:
		if not stock_to.is_empty(): add_supply(stock_to, output, 1)
		elif is_instance_valid(belongings) and belongings.has_method("add"): belongings.add(keeper, output, "self")
		else: add_supply(id, output, 1)

func _inventory() -> Node:
	if is_instance_valid(inventory): return inventory
	var found: Variant = game.get("inventory") if is_instance_valid(game) else null
	return found as Node if found is Node and is_instance_valid(found) else null

func _drop_for_player(id: String, output: String) -> bool:
	var inv := _inventory()
	if inv == null or not inv.has_method("spawn_owned_drop"): return false
	return inv.spawn_owned_drop(output, output_pose(id)) != null

## The physical node of a station (group mechanics_station_nodes, `station_id` property), or null.
func station_node(id: String) -> Node3D:
	if not is_inside_tree(): return null
	for node: Node in get_tree().get_nodes_in_group(NODE_GROUP):
		if node is Node3D and str(node.get("station_id")) == id: return node
	return null

## Where a pony stands to work it: the node's station_work_point(), else the spec's ground point.
func work_point(id: String) -> Vector3:
	var node := station_node(id)
	if node != null and node.has_method("station_work_point"):
		var at: Variant = node.call("station_work_point")
		if at is Vector3 and (at as Vector3).is_finite(): return at
	var point := RULES.where(spec(id))
	if not point.is_finite(): return point
	var ground: Variant = spec(id).get("where", {}).get("ground", false) if spec(id).get("where") is Dictionary else false
	if bool(ground) and is_instance_valid(WorldTerrain.instance):
		var height: float = WorldTerrain.instance.height_at(point)
		if is_finite(height): point.y = height
	return point

## Where Anon's output appears: the node's station_output_pose(), else just above the work point.
func output_pose(id: String) -> Transform3D:
	var node := station_node(id)
	if node != null and node.has_method("station_output_pose"):
		var pose: Variant = node.call("station_output_pose")
		if pose is Transform3D and (pose as Transform3D).is_finite(): return pose
	var at := work_point(id)
	return Transform3D(Basis(), (at if at.is_finite() else Vector3.ZERO) + Vector3.UP * 0.5)

func _tick() -> void:
	if _writable():
		var rows: Variant = _read().get("rows")
		if rows is Dictionary:
			for id: Variant in (rows as Dictionary):
				var saved: Variant = (rows as Dictionary)[id]
				if not saved is Dictionary or not (saved as Dictionary).get("pending") is Array or ((saved as Dictionary).pending as Array).is_empty(): continue
				var pending: Array = (saved as Dictionary).pending
				while not pending.is_empty() and _drop_for_player(str(id), str(pending[0])):
					pending.pop_front()
					context._changed()
	ticked.emit(_now())

# --- Ponies --------------------------------------------------------------------------------------

## Process stations a pony could be sent to now ([use]): she is a listed worker (or any_pony is),
## within WORK_RANGE of it, it is free with its needs met, and its inputs are loaded or in supply.
func workable(pony_id: String, at: Vector3) -> Array[String]:
	var ids: Array[String] = []
	for id: String in _order:
		var row_spec: Dictionary = _specs[id]
		if str(row_spec.kind) != "process" or str(row_spec.driver) != "native": continue
		var point := RULES.where(row_spec)
		if at.is_finite() and Vector2(at.x - point.x, at.z - point.z).length() > WORK_RANGE: continue
		if not can_work(id, pony_id).is_empty(): continue
		if not _fillable(id, pony_id): continue
		ids.append(id)
	return ids

## Her inputs are loaded (not Anon's left-behind ones, which go back to him) or in supply.
func _fillable(id: String, worker: String) -> bool:
	return (inputs_ready(id) and not _lapsed_player_load(id, worker)) or _supply_missing(id, worker).is_empty()

## What the supply still lacks to fill the station's inputs ("" when it can): "apples".
func _supply_missing(id: String, worker := "") -> String:
	var row_spec := spec(id)
	var used := RULES.allocate(row_spec, [] if _lapsed_player_load(id, worker) else row(id).loaded)
	var stock := supply_items(id)
	var inputs: Array = row_spec.get("inputs", [])
	for index: int in inputs.size():
		var need: int = RULES.count(inputs[index]) - used[index]
		if need <= 0: continue
		for item: String in stock:
			if RULES.matches(inputs[index], item):
				var take := mini(need, int(stock[item]))
				stock[item] = int(stock[item]) - take
				need -= take
		if need > 0: return _input_label(inputs[index])
	return ""

static func _input_label(entry: Dictionary) -> String:
	if entry.get("tag") is String: return str(entry.tag).replace("_", " ") + "s"
	return str(ITEM_CATALOG.definition(str(entry.get("id", ""))).get("name", "the right things")).to_lower()

## Fills the missing inputs from the station's own supply. "" or why not ("No apples for the
## cider press"); takes nothing unless everything is there.
func load_from_supply(id: String, worker: String) -> String:
	var row_spec := spec(id)
	if row_spec.is_empty() or str(row_spec.kind) != "process": return "Nothing goes into that"
	var why := can_work(id, worker)
	if not why.is_empty(): return why
	if inputs_ready(id) and not _lapsed_player_load(id, worker): return ""
	var missing := _supply_missing(id, worker)
	if not missing.is_empty(): return "No %s for the %s" % [missing, display_name(id)]
	if not _writable(): return "The world cannot change right now"
	_take_over(id, worker)   # Anon's left-behind inputs go back to him first
	var inputs: Array = row_spec.get("inputs", [])
	var live := _row_live(id)
	var used := RULES.allocate(row_spec, live.loaded)
	for index: int in inputs.size():
		var need: int = RULES.count(inputs[index]) - used[index]
		for item: String in supply_items(id):
			while need > 0 and RULES.matches(inputs[index], item) and take_supply(id, item, 1):
				(live.loaded as Array).append(item)
				need -= 1
	_claim(live, worker)
	context._changed()
	return ""

## Facts-only completion for an unloaded pony (her essence did the step): takes the inputs from
## supply, adds the outputs to supply/belongings and the fact "made" (no memory text). False when
## she cannot work it or the supply is short.
func offscreen_work(id: String, pony_id: String) -> bool:
	var row_spec := spec(id)
	if row_spec.is_empty() or str(row_spec.kind) != "process" or pony_id == "player": return false
	if not load_from_supply(id, pony_id).is_empty() or not inputs_ready(id): return false
	var live := _row_live(id)
	var done := RULES.output_ids(row_spec)
	live.loaded = []; live.progress = 0.0; live.worker = ""; live.started = 0.0
	_route(row_spec, pony_id, done)
	context._changed()
	_made(id, pony_id, done, [])
	return true

## Station ids with pony work today (P7 day plans, `when.station_needs`): a grow station with a
## planted, ungrown slot not watered today. Reads only.
func pending_work() -> Array[String]:
	var ids: Array[String] = []
	for id: String in _order:
		if str(_specs[id].get("kind", "")) == "grow" and not _dry_slots(id).is_empty(): ids.append(id)
	return ids

## Slot indices of a grow station's saved plot that hold a sapling (stage < 3) not watered today.
func _dry_slots(id: String) -> Array[int]:
	var found: Array[int] = []
	var plots: Variant = _read().get("plots")
	var plot: Variant = (plots as Dictionary).get(id) if plots is Dictionary else null
	var slots: Variant = (plot as Dictionary).get("slots") if plot is Dictionary else null
	if not slots is Array: return found
	var today := int(FACTS.clock().day)
	for index: int in (slots as Array).size():
		var slot: Variant = slots[index]
		if not slot is Dictionary or str((slot as Dictionary).get("item", "")).is_empty(): continue
		var stage: Variant = (slot as Dictionary).get("stage", 0)
		if (stage is int or stage is float) and int(stage) >= 3: continue
		var watered: Variant = (slot as Dictionary).get("watered", [])
		var done := false
		if watered is Array:
			for day: Variant in watered:
				if (day is int or day is float) and int(day) == today: done = true; break
		if not done: found.append(index)
	return found

## A pony waters every dry slot of a grow station today (her water_saplings step, loaded or not).
## A loaded plot node waters through its own path (planting_plot.water_all: stage, trimming, the
## sapling visual, its "watered" fact). Unloaded, the same slot rule (planting_plot.water_slot) and
## the same fact with the plot's key "water:<plot>:<slot>:<day>" (a spray the same day never counts
## twice). Returns how many slots she watered.
func water_plot(id: String, worker: String) -> int:
	if not _writable() or str(spec(id).get("kind", "")) != "grow": return 0
	if is_inside_tree():
		for node: Node in get_tree().get_nodes_in_group(NODE_GROUP):
			var plot: Variant = node.get("plot")
			if str(node.get("station_id")) == id and plot is Node and (plot as Node).has_method("water_all"):
				return int((plot as Node).call("water_all", worker))
	var dry := _dry_slots(id)
	if dry.is_empty(): return 0
	var rules: Script = load(PLOT_SCRIPT)   # not preloaded: planting_plot.gd preloads this file
	var slots: Array = plot_state(id).get("slots", [])
	var today := int(FACTS.clock().day)
	var short := id.trim_suffix("_plot")
	var count := 0
	for index: int in dry:
		var slot: Dictionary = slots[index]
		if not slot.get("watered") is Array: slot["watered"] = []
		if not bool(rules.call("water_slot", slot, today)): continue
		count += 1
		if is_instance_valid(facts):
			facts.add("watered", {"actor": worker, "item": str(slot.get("item", "")), "ref": id, "place": str(rules.call("tree_id", index)), "count": 1, "key": "water:%s:%d:%d" % [short, index, today]})
	if count > 0: changed()
	return count

## [use: STATION]: sends her to work it now (a fixed step in her day card). {"status", "reason"}.
func request_use(pony_id: String, station_id: String) -> Dictionary:
	var row_spec := spec(station_id)
	if row_spec.is_empty() or str(row_spec.kind) != "process": return {"status": "failed", "reason": "No station you can work here"}
	var why := can_work(station_id, pony_id)
	if why.is_empty() and not _fillable(station_id, pony_id):
		var missing := _supply_missing(station_id, pony_id)
		if not missing.is_empty(): why = "No %s for the %s" % [missing, display_name(station_id)]
	if not why.is_empty(): return {"status": "failed", "reason": why}
	var runner: Node = get_tree().get_first_node_in_group("day_runner") if is_inside_tree() else null
	if runner == null or not runner.has_method("inject_now"): return {"status": "failed", "reason": "You cannot head off right now"}
	if not bool(runner.call("inject_now", pony_id, use_step(station_id))): return {"status": "failed", "reason": "You cannot head off right now"}
	return {"status": "accepted", "reason": "Walking to the %s" % display_name(station_id)}

## The day-card step a [use] inserts (handler use_station.gd); `ai` lets it start mid-chat.
func use_step(station_id: String) -> Dictionary:
	return {"action": "use_station", "handler": "use_station", "target": "station:" + station_id, "minutes": USE_MINUTES,
		"hours": USE_HOURS, "phrase": "work the " + display_name(station_id), "item": "", "reason": "", "posture": "stand", "ai": true}

# --- Supply --------------------------------------------------------------------------------------

## Stock a station or job draws from (pony presses, the cider stand): {target_id: {item_id: int}}.
func supply(target_id: String, item_id: String) -> int:
	var all: Variant = _read().get("supply")
	var stock: Variant = (all as Dictionary).get(target_id) if all is Dictionary else null
	var value: Variant = (stock as Dictionary).get(ITEM_CATALOG.canonical(item_id)) if stock is Dictionary else null
	return maxi(0, int(value)) if (value is int or value is float) and is_finite(float(value)) else 0

func supply_items(target_id: String) -> Dictionary:
	var result := {}
	var all: Variant = _read().get("supply")
	var stock: Variant = (all as Dictionary).get(target_id) if all is Dictionary else null
	if stock is Dictionary:
		for item: Variant in stock:
			var n := supply(target_id, str(item))
			if n > 0: result[str(item)] = n
	return result

func add_supply(target_id: String, item_id: String, n: int) -> void:
	item_id = ITEM_CATALOG.canonical(item_id)
	if n <= 0 or target_id.is_empty() or not ITEM_CATALOG.has(item_id) or not _writable(): return
	var all: Dictionary = _block().supply
	if not all.get(target_id) is Dictionary: all[target_id] = {}
	(all[target_id] as Dictionary)[item_id] = mini(SUPPLY_CAP, supply(target_id, item_id) + n)
	context._changed()

func take_supply(target_id: String, item_id: String, n: int) -> bool:
	item_id = ITEM_CATALOG.canonical(item_id)
	var have := supply(target_id, item_id)
	if n <= 0 or have < n or not _writable(): return false
	var stock: Dictionary = _block().supply[target_id]
	if have == n: stock.erase(item_id)
	else: stock[item_id] = have - n
	context._changed()
	return true

func _on_harvested(fact: Dictionary) -> void:
	if spec(PRESS).is_empty(): return
	add_supply(PRESS, "apple", APPLES_PER_BASKET * maxi(1, int(fact.get("count", 1))))

# --- Facts ---------------------------------------------------------------------------------------

## Adapters call this (cooking finish, keg pour, catch): the facts and the produced signal; no
## state. `type` is "made" ("caught" for the fishing dock). One fact per distinct output id.
func note_made(station_id: String, worker: String, outputs: Array, text := "", type := "made") -> void:
	var counts := {}
	for output: Variant in outputs: counts[str(output)] = int(counts.get(str(output), 0)) + 1
	if is_instance_valid(facts):
		for item: String in counts:
			facts.add(type, {"actor": worker, "item": item, "count": int(counts[item]), "ref": station_id}, text)
	produced.emit(station_id, outputs.duplicate(), worker)

func _made(id: String, worker: String, outputs: Array[String], witnesses: Array) -> void:
	if outputs.is_empty(): return
	var text := ""
	if not witnesses.is_empty():
		text = "%s made %s at the %s." % [_who(worker), _phrase(outputs[0]), display_name(id)]
	var counts := {}
	for output: String in outputs: counts[output] = int(counts.get(output, 0)) + 1
	if is_instance_valid(facts):
		for item: String in counts:
			facts.add("made", {"actor": worker, "item": item, "count": int(counts[item]), "ref": id}, text, witnesses)
	produced.emit(id, outputs.duplicate(), worker)

## "a cider keg", "some apples" (the same wording as gifts.gd phrase, without its book/painting cases).
static func _phrase(item_id: String) -> String:
	var lower := str(ITEM_CATALOG.definition(item_id).get("name", "something")).to_lower()
	for article: String in ["a ", "an ", "the ", "some "]:
		if lower.begins_with(article): return lower
	if lower.ends_with("s") and not lower.ends_with("ss"): return "some " + lower
	return ("an " if lower.left(1) in ["a", "e", "i", "o", "u"] else "a ") + lower

static func _who(worker: String) -> String:
	return "Anon" if worker == "player" else worker.replace("_", " ").capitalize()

func _population() -> Node:
	if is_instance_valid(population): return population
	return get_tree().get_first_node_in_group("pony_populations") if is_inside_tree() else null

## The worker and the ponies within WITNESS_RANGE of the station (loaded bodies only).
func _witnesses(id: String, worker: String) -> Array:
	var who: Array = [worker]
	var at := work_point(id)
	var people := _population()
	var live: Variant = people.get("live") if people != null else null
	if live is Dictionary and at.is_finite():
		for other: Variant in live:
			var entry: Variant = (live as Dictionary)[other]
			var body: Variant = (entry as Dictionary).get("actor") if entry is Dictionary else null
			if str(other) != worker and is_instance_valid(body) and body is Node3D and (body as Node3D).is_inside_tree() \
					and (body as Node3D).global_position.distance_to(at) <= WITNESS_RANGE:
				who.append(str(other))
	return who
