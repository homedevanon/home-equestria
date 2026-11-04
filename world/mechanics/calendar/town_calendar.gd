extends Node
## The town calendar (P6 of docs/MECHANICS_ARCHITECTURE_2026_11_01.md, section 9): data-driven town
## events (world/mechanics/data/events.json) and the one season source. Season rows (Applebuck
## Season, Cider Season) run on a fraction of a season, optionally within daily hours; driver rows
## (Trixie's stage show) are run by their own runtime, which asks the calendar whether today's
## event is due (`due_hour`). Anti-copper: events change other systems through `effect()` (the
## orchard's daily baskets and basket pay), `jobs_open()` (the cider stand), event asks (asks.gd),
## `[invite: EVENT]` (the AI), map markers and the facts `event_started`, `event_ended` and
## `attended` (asks complete on attendance, gossip and memory read them).
##
## Saved in world_context.state.town_events.calendar = {"started": {event_id: occurrence_day},
## "ended": {event_id: occurrence_day}, "invited": {event_id: day}}. The sibling
## town_events.trixie_show stays owned by show_runtime.gd. 1 Hz tick from a Timer; nothing per frame.
signal event_started(event_id: String, day: int)   # each time an event goes live (daily hours included)
signal event_ended(event_id: String, day: int)     # each time it stops being live
const FACTS := preload("res://world/mechanics/facts.gd")
const PLACES := preload("res://world/navigation/place_directory.gd")
const DATA_PATH := "res://world/mechanics/data/events.json"
const STATE_KEY := "town_events"
const SUB_KEY := "calendar"
const GROUP := "town_calendar"
const SEASONS := ["spring", "summer", "autumn", "winter"]
const TICK := 1.0
const MARKER_OWNER := "town_calendar"
const DEFAULT_SEASON_DAYS := 20
## Driver rows: the runtime node (a child of the game) that owns the event's state and memory.
const DRIVER_NODES := {"trixie_show": "TrixieShow"}
## A driver's own daily window ends this long before its roll range does (show_runtime._roll).
const ROLL_TAIL_HOURS := 0.5
const EPSILON := 0.000001

var game: Node
var context: Node
var facts: Node          # facts.gd, or null (fixtures)
var asks: Node           # asks.gd when set directly (tests); else the hub's
var hub: Node            # mechanics.gd, or null
var rows: Array[Dictionary] = []
var auto_tick := true    # tests clear it and call tick() themselves
## Test hooks: a fixed clock {"day", "hours"}, a season length, a seed source for driver rolls.
var clock_override: Dictionary = {}
var season_days_override := 0
var config_path_override: Variant = null
var _by_id: Dictionary = {}
var _live: Dictionary = {}       # event id -> true while live (memory only)
var _rolled: Dictionary = {}     # "event:day" -> roll hour (INF = no event)
var _places: Dictionary = {}     # place id -> Vector3
var _marker_sig := "-"
var _timer: Timer

func _init() -> void:
	add_to_group(GROUP)
	load_rows()

func _ready() -> void:
	if not auto_tick: return
	_timer = Timer.new(); _timer.name = "CalendarTick"; _timer.wait_time = TICK; _timer.autostart = true
	_timer.timeout.connect(tick)
	add_child(_timer)

## Loads events.json (or `path`) into `rows`. Malformed rows are skipped with a warning.
func load_rows(path := DATA_PATH) -> void:
	rows.clear(); _by_id.clear()
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text) if not text.is_empty() else null
	if not parsed is Dictionary or not (parsed as Dictionary).get("events") is Array:
		push_warning("town_calendar: no events in %s" % path); return
	for value: Variant in (parsed as Dictionary).events:
		if not value is Dictionary or not (value as Dictionary).get("id") is String or str((value as Dictionary).id).is_empty(): continue
		var entry: Dictionary = value
		if not entry.has("season") and not entry.has("driver"): continue
		if entry.has("season") and str(entry.season) not in SEASONS: continue
		rows.append(entry); _by_id[str(entry.id)] = entry

func row(event_id: String) -> Dictionary:
	return _by_id.get(event_id, {})

# ------------------------------------------------------------------ clock and seasons

func _clock() -> Dictionary:
	if not clock_override.is_empty():
		var day: int = int(clock_override.get("day", 0)); var hours: float = float(clock_override.get("hours", 0.0))
		return {"day": day, "hours": hours, "at": float(day) * 24.0 + hours}
	return FACTS.clock()

func today() -> int:
	return int(_clock().day)

func season_days() -> int:
	if season_days_override > 0: return season_days_override
	var tree := Engine.get_main_loop() as SceneTree
	var settings: Node = tree.root.get_node_or_null("Settings") if tree != null and tree.root != null else null
	return maxi(1, int(settings.call("season_days"))) if settings != null and settings.has_method("season_days") else DEFAULT_SEASON_DAYS

func _weather() -> Node:
	var tree := get_tree() if is_inside_tree() else Engine.get_main_loop() as SceneTree
	return tree.get_first_node_in_group("weather") if tree != null else null

## The F1 debug season steps (weather.gd `_season_offset`), 0 without a Weather node.
func _season_offset() -> int:
	var weather := _weather()
	var offset: Variant = weather.get("_season_offset") if weather != null else null
	return int(offset) if offset is int or offset is float else 0

## The one season source: the same formula and F1 offset as weather.gd _update_season (Weather.season
## for today), else posmod(floor(day / Settings.season_days()), 4).
func season_index(day := -1) -> int:
	var d: int = day if day >= 0 else today()
	var length := season_days()
	return posmod(floori(float(d + _season_offset() * length) / float(length)), 4)

func season_name(day := -1) -> String:
	return SEASONS[season_index(day)]

## Days into the current season (0 .. season_days - 1).
func day_into_season(day := -1) -> int:
	var d: int = day if day >= 0 else today()
	var length := season_days()
	return posmod(d + _season_offset() * length, length)

func _first_day(fraction: float) -> int:
	return floori(fraction * float(season_days()) + EPSILON)

## Season rows: the day lies in the row's season between from and to.
func _in_window(event: Dictionary, day: int) -> bool:
	if not event.has("season") or season_name(day) != str(event.season): return false
	var into := day_into_season(day)
	return into >= _first_day(float(event.get("from", 0.0))) and into < _first_day(float(event.get("to", 1.0)))

## The absolute day this occurrence of a season row began (its started/ended key).
func _occurrence(event: Dictionary, day: int) -> int:
	if event.has("driver"): return day
	return day - day_into_season(day) + _first_day(float(event.get("from", 0.0)))

func _hours(event: Dictionary) -> Vector2:
	var span: Variant = event.get("hours")
	if span is Array and (span as Array).size() == 2: return Vector2(float(span[0]), float(span[1]))
	return Vector2(0.0, 24.0)

# ------------------------------------------------------------------ driver rows (Trixie)

func _driver(event: Dictionary) -> Node:
	var path := str(DRIVER_NODES.get(str(event.get("driver", "")), ""))
	return game.get_node_or_null(path) if not path.is_empty() and is_instance_valid(game) else null

func _driver_state(event: Dictionary) -> Dictionary:
	var events := _events_block()
	var state: Variant = events.get(str(event.get("driver", ""))) if not events.is_empty() else null
	return state if state is Dictionary else {}

func _config_path() -> Variant:
	if config_path_override != null: return str(config_path_override)
	var population: Variant = game.get("population") if is_instance_valid(game) else null
	return str((population as Node).get("config_path")) if population is Node and is_instance_valid(population) else null

## The hour today's event of a rolled row starts, or INF: off its cooldown (the driver's
## last_day) and the day's deterministic roll hits. The same formula, seed and order of draws as
## show_runtime._roll, so the same days fire as before the move (tools/mechanics/test_calendar.gd).
func due_hour(event_id: String, day: int) -> float:
	var event := row(event_id)
	var roll: Variant = event.get("roll")
	if not roll is Dictionary: return INF
	var last_day: int = int(_driver_state(event).get("last_day", -1000))
	if day - last_day < int((roll as Dictionary).get("cooldown_days", 0)): return INF
	return roll_hour(event_id, day)

## The deterministic roll alone (no cooldown): the start hour, or INF on a day without the event.
func roll_hour(event_id: String, day: int) -> float:
	var key := "%s:%d" % [event_id, day]
	if _rolled.has(key): return float(_rolled[key])
	var event := row(event_id)
	var roll: Variant = event.get("roll")
	var seed_text: Variant = _config_path()
	if not roll is Dictionary or seed_text == null: return INF
	var span := _hours(event)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(seed_text) + "%s:%d" % [event_id, day])
	var at := rng.randf_range(span.x, span.y - ROLL_TAIL_HOURS) if rng.randf() < float((roll as Dictionary).get("chance", 0.0)) else INF
	_rolled[key] = at
	if _rolled.size() > 256: _rolled.erase(_rolled.keys()[0])
	return at

func is_due(event_id: String, day: int) -> bool:
	return is_finite(due_hour(event_id, day))

## A driver event belongs to today when it is on, booked (forced_day), already happened today or due.
func _driver_today(event: Dictionary, day: int) -> bool:
	var node := _driver(event)
	if node != null and node.has_method("active") and bool(node.call("active")): return true
	var state := _driver_state(event)
	if int(state.get("forced_day", -1)) == day or int(state.get("last_day", -1000)) == day: return true
	return is_due(str(event.id), day)

# ------------------------------------------------------------------ queries

## Live now: in its window today and within its hours (season rows), or running (driver rows).
func active(event_id: String) -> bool:
	var event := row(event_id)
	if event.is_empty(): return false
	if event.has("driver"):
		var node := _driver(event)
		return node != null and node.has_method("active") and bool(node.call("active"))
	var clock := _clock()
	if not _in_window(event, int(clock.day)): return false
	var span := _hours(event)
	return float(clock.hours) >= span.x and float(clock.hours) < span.y

func active_events() -> Array[String]:
	var ids: Array[String] = []
	for event: Dictionary in rows:
		if active(str(event.id)): ids.append(str(event.id))
	return ids

## Rows active at any time today.
func today_events() -> Array[Dictionary]:
	var day := today()
	var found: Array[Dictionary] = []
	for event: Dictionary in rows:
		if (_driver_today(event, day) if event.has("driver") else _in_window(event, day)): found.append(event)
	return found

## Live now or starting later today (an invitation still makes sense).
func _still_today(event: Dictionary) -> bool:
	var id := str(event.id)
	if active(id): return true
	var clock := _clock()
	var span := _hours(event)
	if float(clock.hours) >= span.y: return false
	if event.has("driver"):
		var day := int(clock.day)
		var state := _driver_state(event)
		return int(state.get("forced_day", -1)) == day or is_due(id, day)
	return true

## Events she could invite Anon to now: today's, with a place, hosted by her (or by anypony when
## hosts is empty), live now or later today, not yet invited to today, and not already attended
## today (his `attended` fact is keyed per day, so a later invitation could never complete).
func invitable(pony_id: String) -> Array[String]:
	var ids: Array[String] = []
	var day := today()
	var invited: Dictionary = _calendar_read().get("invited", {})
	for event: Dictionary in today_events():
		var hosts: Array = event.get("hosts", []) if event.get("hosts") is Array else []
		if not hosts.is_empty() and pony_id not in hosts: continue
		if str(event.get("place", "")).is_empty() or int(invited.get(str(event.id), -1)) == day: continue
		if _still_today(event) and not attended_today(str(event.id)): ids.append(str(event.id))
	return ids

## Anon already counted at the event today: the same once-a-day key _attend gives its fact.
func attended_today(event_id: String) -> bool:
	var stream := _facts()
	var block: Variant = stream.call("_read") if stream != null and stream.has_method("_read") else null
	var keys: Variant = (block as Dictionary).get("keys") if block is Dictionary else null
	return keys is Dictionary and (keys as Dictionary).has("attend:%s:%d" % [event_id, today()])

## An invitation to `event_id` made at absolute game hour `since_at` whose occurrence never
## started (a rained-out or skipped show): asks.gd cancels it instead of failing Anon. Season rows
## always take place, so only driver rows can be missed.
func missed(event_id: String, since_at: float) -> bool:
	var event := row(event_id)
	if event.is_empty() or not event.has("driver"): return false
	var started: Dictionary = _calendar_read().get("started", {})
	return int(started.get(event_id, -1)) < floori(since_at / 24.0)

## The value of an effect while an event that sets it is live; the last such row wins.
func effect(key: String, fallback: Variant) -> Variant:
	var value: Variant = fallback
	for event: Dictionary in rows:
		var effects: Variant = event.get("effects")
		if effects is Dictionary and (effects as Dictionary).has(key) and active(str(event.id)): value = effects[key]
	return value

## Jobs that live events open now (jobs.gd reads its `open.event` through `active`, or this).
func jobs_open() -> Array[String]:
	var ids: Array[String] = []
	for event: Dictionary in rows:
		if not active(str(event.id)) or not event.get("jobs_open") is Array: continue
		for job: Variant in event.jobs_open:
			if str(job) not in ids: ids.append(str(job))
	return ids

func job_open(job_id: String) -> bool:
	return job_id in jobs_open()

## "Cider Season at Sweet Apple Acres, 10:00-18:00" (notebook pages and the AI line).
func describe(event_id: String) -> String:
	var event := row(event_id)
	if event.is_empty(): return event_id
	var text := str(event.get("name", event_id))
	if not str(event.get("place_name", "")).is_empty(): text += " at " + str(event.place_name)
	if event.get("hours") is Array:
		var span := _hours(event)
		text += ", %s-%s" % [_hhmm(span.x), _hhmm(span.y)]
	return text

static func _hhmm(hours: float) -> String:
	var minutes := roundi(hours * 60.0)
	return "%02d:%02d" % [posmod(minutes / 60, 24), posmod(minutes, 60)]

## Game hours from now until the event's occurrence ends (at least 1).
func hours_left(event_id: String) -> float:
	var event := row(event_id)
	var clock := _clock()
	var span := _hours(event)
	var end_at := float(clock.day) * 24.0 + span.y
	if not event.has("driver") and not event.has("hours"):
		end_at = float(_occurrence(event, int(clock.day)) - _first_day(float(event.get("from", 0.0))) + _first_day(float(event.get("to", 1.0)))) * 24.0
	return maxf(1.0, end_at - float(clock.at))

# ------------------------------------------------------------------ state

func _writable() -> bool:
	return is_instance_valid(context) and not bool(context.get("_read_only")) and context.get("state") is Dictionary

func _events_block() -> Dictionary:
	if not is_instance_valid(context) or not context.get("state") is Dictionary: return {}
	var events: Variant = (context.state as Dictionary).get(STATE_KEY)
	return events if events is Dictionary else {}

## The saved calendar sub-dict for reading ({} when absent).
func _calendar_read() -> Dictionary:
	var block: Variant = _events_block().get(SUB_KEY)
	if not block is Dictionary: return {}
	for key: String in ["started", "ended", "invited"]:
		if not (block as Dictionary).get(key, {}) is Dictionary: return {}
	return block

## The saved calendar sub-dict, created (or repaired) for a write. Callers check _writable() first.
func _calendar_block() -> Dictionary:
	var state: Dictionary = context.state
	if not state.get(STATE_KEY) is Dictionary: state[STATE_KEY] = {}
	var events: Dictionary = state[STATE_KEY]
	if not events.get(SUB_KEY) is Dictionary: events[SUB_KEY] = {}
	var block: Dictionary = events[SUB_KEY]
	for key: String in ["started", "ended", "invited"]:
		if not block.get(key) is Dictionary: block[key] = {}
	return block

func _facts() -> Node:
	if facts != null and is_instance_valid(facts): return facts
	var from_hub: Variant = hub.get("facts") if is_instance_valid(hub) else null
	return from_hub as Node if from_hub is Node and is_instance_valid(from_hub) else null

func _asks() -> Node:
	if asks != null and is_instance_valid(asks): return asks
	var from_hub: Variant = hub.get("asks") if is_instance_valid(hub) else null
	return from_hub as Node if from_hub is Node and is_instance_valid(from_hub) else null

func _add_fact(type: String, data: Dictionary, text := "", witnesses: Array = []) -> void:
	var stream := _facts()
	if stream != null: stream.call("add", type, data, text, witnesses)

# ------------------------------------------------------------------ the tick

## Once a second: starts and ends events, records attendance and refreshes the map markers.
func tick() -> void:
	var day := today()
	for event: Dictionary in rows:
		var id := str(event.id)
		var on := active(id)
		if on and not _live.has(id):
			_live[id] = true
			_begin(event, day)
			event_started.emit(id, day)
		elif not on and _live.has(id):
			_live.erase(id)
			event_ended.emit(id, day)
		if on:
			_retry_asks(event, day)
			_attend(event, day)
	_close_finished(day)
	_publish_markers()

## First time an occurrence goes live: the fact (once, keyed) and the row's asks (once, through
## calendar.started, so a restart on the same day does not duplicate them).
func _begin(event: Dictionary, day: int) -> void:
	if not _writable(): return
	var id := str(event.id)
	var occurrence := _occurrence(event, day)
	var block := _calendar_block()
	if int(block.started.get(id, -1)) == occurrence: return
	block.started[id] = occurrence
	context._changed()
	var hosts: Array = event.get("hosts", []) if event.get("hosts") is Array else []
	# Driver rows (the show) write their own memory; season rows tell their hosts.
	var text := "" if event.has("driver") else "%s began in town." % str(event.get("name", id))
	_add_fact("event_started", {"actor": "town", "ref": id, "place": str(event.get("place", "")),
		"key": "event_started:%s:%d" % [id, occurrence]}, text, hosts)
	if not event.get("asks") is Array: return
	# calendar.asked[id] = {"occurrence", "made": [ask indices]}: a refused ask (her capped favour
	# slot is taken) is tried again on later ticks while the occurrence is live. Saves from before
	# this record simply have no retries.
	if not block.get("asked") is Dictionary: block["asked"] = {}
	block.asked[id] = {"occurrence": occurrence, "made": []}
	_make_asks(event, block.asked[id], true)

## Creates the row's event asks not yet made this occurrence; true when one was made.
func _make_asks(event: Dictionary, record: Dictionary, first: bool) -> bool:
	var favours: Node = _asks()
	if favours == null or not favours.has_method("create"): return false
	if not record.get("made") is Array: record["made"] = []
	var made_any := false
	for index: int in (event.asks as Array).size():
		var value: Variant = event.asks[index]
		if not value is Dictionary or index in record.made or float(index) in record.made: continue
		var ask: Dictionary = value
		var made: Variant = favours.call("create", str(ask.get("from", "")), str(ask.get("want", "")), str(ask.get("reward", "thanks")),
			str(ask.get("why", "")), "event", float(ask.get("hours", 24.0)))
		if made is Dictionary and bool((made as Dictionary).get("ok", false)):
			(record.made as Array).append(index)
			made_any = true
		elif first and made is Dictionary:
			print("[calendar] %s: event ask from %s not created yet: %s" % [str(event.id), str(ask.get("from", "")), str((made as Dictionary).get("error", ""))])
	if made_any: context._changed()
	return made_any

## While an occurrence is live, retries its event asks that were refused when it began.
func _retry_asks(event: Dictionary, day: int) -> void:
	if not event.get("asks") is Array or not _writable(): return
	var asked: Variant = _calendar_read().get("asked")
	var record: Variant = (asked as Dictionary).get(str(event.id)) if asked is Dictionary else null
	if not record is Dictionary or int((record as Dictionary).get("occurrence", -1)) != _occurrence(event, day): return
	var made: Variant = (record as Dictionary).get("made")
	if made is Array and (made as Array).size() >= (event.asks as Array).size(): return
	_make_asks(event, record, false)

## An occurrence that is over gets its event_ended fact once.
func _close_finished(day: int) -> void:
	var started: Dictionary = _calendar_read().get("started", {})
	if started.is_empty() or not _writable(): return
	for id: Variant in started.keys():
		var event := row(str(id))
		var block := _calendar_block()
		if event.is_empty() or int(block.ended.get(id, -1)) == int(started[id]): continue
		if _live.has(str(id)) or not _over(event, int(started[id]), day): continue
		block.ended[id] = int(started[id])
		context._changed()
		_add_fact("event_ended", {"actor": "town", "ref": str(id), "place": str(event.get("place", "")),
			"key": "event_ended:%s:%d" % [str(id), int(started[id])]})

func _over(event: Dictionary, occurrence: int, day: int) -> bool:
	if event.has("driver"): return true   # not live any more (checked by the caller)
	if not _in_window(event, day) or _occurrence(event, day) != occurrence: return true
	# Its last day, past its hours.
	var last_day := occurrence - _first_day(float(event.get("from", 0.0))) + _first_day(float(event.get("to", 1.0))) - 1
	return event.has("hours") and day >= last_day and float(_clock().hours) >= _hours(event).y

## One `attended` fact per event-day while Anon is within the event's radius of its place.
func _attend(event: Dictionary, day: int) -> void:
	var at := place_position(str(event.get("place", "")))
	var anon := anon_position()
	if not at.is_finite() or not anon.is_finite(): return
	if Vector2(anon.x - at.x, anon.z - at.z).length() > float(event.get("radius", 30.0)): return
	var id := str(event.id)
	var hosts: Array = event.get("hosts", []) if event.get("hosts") is Array else []
	var text := "" if event.has("driver") else "Anon came to %s." % str(event.get("name", id))
	_add_fact("attended", {"actor": "player", "ref": id, "place": str(event.get("place", "")), "key": "attend:%s:%d" % [id, day]}, text, hosts)

## Anon's camera position (the same camera the Trixie show uses), INF without one.
func anon_position() -> Vector3:
	if not is_instance_valid(game) or not game.has_method("_find_camera"): return Vector3.INF
	var player: Variant = game.get("player")
	if not player is Node or not is_instance_valid(player): return Vector3.INF
	var camera: Variant = game.call("_find_camera", player)
	return (camera as Node3D).global_position if camera is Node3D and is_instance_valid(camera) and (camera as Node3D).is_inside_tree() else Vector3.INF

## A place id to a world point: "activity:<driver>" is the driver's stage front, anything else
## goes through the place directory (landmarks). Cached; INF while unresolved.
func place_position(place: String) -> Vector3:
	if place.is_empty(): return Vector3.INF
	if _places.has(place): return _places[place]
	var at := Vector3.INF
	if place.begins_with("activity:"):
		var node := _driver({"driver": place.trim_prefix("activity:")})
		if node != null and node.has_method("stage_front"): at = node.call("stage_front")
	elif is_inside_tree():
		at = PLACES.resolve(get_tree(), place)
	if at.is_finite(): _places[place] = at
	return at

## Map markers for live season events (driver rows publish their own, like the show's flashing
## icon). Sent only when they change.
func _publish_markers() -> void:
	if not is_inside_tree(): return
	var markers: Array[Dictionary] = []
	for event: Dictionary in rows:
		if event.has("driver") or not active(str(event.id)): continue
		var at := place_position(str(event.get("place", "")))
		if not at.is_finite(): continue
		var hosts: Array = event.get("hosts", []) if event.get("hosts") is Array else []
		var marker := {"id": "activity:%s" % str(event.id), "name": str(event.get("name", event.id)), "kind": "activity",
			"activity": str(event.id), "position": Vector2(at.x, at.z)}
		if not hosts.is_empty(): marker["icon_id"] = str(hosts[0])
		markers.append(marker)
	var signature := str(markers)
	if signature == _marker_sig: return
	_marker_sig = signature
	for map_view: Node in get_tree().get_nodes_in_group("world_map_views"):
		if map_view.has_method("set_activity_markers"): map_view.set_activity_markers(MARKER_OWNER, markers)

# ------------------------------------------------------------------ [invite: EVENT]

## The [invite] dispatch (mechanics.gd _dispatch_invite, architecture 5.4) wrote the invitation
## into Anon's notebook as an `event:` ask (asks.gd, completed by his `attended` fact); this marks
## today's invitation so she does not invite him to the same event twice in a day.
func note_invited(event_id: String, _pony_id := "") -> void:
	if row(event_id).is_empty() or not _writable(): return
	_calendar_block().invited[event_id] = today()
	context._changed()

## The prompt line for her invitable events, "" when none (mechanics.gd prompt_note).
func prompt_line(ids: Array[String]) -> String:
	if ids.is_empty(): return ""
	var names: PackedStringArray = []
	for id: String in ids.slice(0, 3): names.append("%s (%s)" % [describe(id), id])
	return "- Town events today: %s ([invite: EVENT])." % "; ".join(names)
