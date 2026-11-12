extends Node
## Agreed meetings with Anon (docs/LETTERS_PLAN_2026_10_29.md sections 3.3, 8, 9; dev 2026-10-29:
## "'show up tomorrow at town hall at 3:00' should actually work"). A pony agrees in conversation
## ([meet: landmark:town_hall, tomorrow, 15:00], pony_action_executor.gd) or in her reply to a
## letter (world/letters/letter_post.gd); the row is kept in the world save
## (world_context.state.appointments). On the day her day plan gets a fixed step to walk there a
## bit early and wait (appointment_steps.gd, actions/appointment.gd). When Anon comes within 5 m of
## her there the meeting starts: she greets him knowing why he came. If he never shows, she waits
## an hour, leaves, and remembers being stood up (a little trust, an annoyed mood, maybe a letter).
## She has at most one open meeting with him; a new [meet] moves it, [meet_cancel] calls it off.
## Created by relationship_runtime.gd setup.

signal appointment_changed(row: Dictionary)
## met | stood_up | lapsed | cancelled
signal appointment_resolved(row: Dictionary)

const MEET_TIME := preload("res://world/life/appointments/meet_time.gd")
const PLACES := preload("res://world/navigation/place_directory.gd")
const ESSENCE := preload("res://world/life/essence.gd")
const STATE_KEY := "appointments"
const GROUP := "appointments"
const OPEN := ["planned", "waiting"]
const WAIT_HOURS := 1.0
## The window opens this long before the hour (matches the day step's earliest start).
const EARLY_HOURS := 0.75
const SEEN_M := 20.0
const MEET_M := 5.0
## An unloaded pony's essence this close to the place counts as there and waiting.
const ESSENCE_THERE_M := 15.0
const KEEP_DAYS := 7.0
const NOTE_CHARS := 120
const PROMPT_CHARS := 300
const HISTORY := 4
const POLL := 1.0
## Retrying her greeting while he stands with her (the director may be busy for a moment).
const GREET_RETRY_S := 30.0
const UNKNOWN_PLACE := "Unknown place; ask Anon which place he means"
## M-AI-18: "come to me" by letter. The meeting place is where Anon was when she read it: a mapped
## place within NEAR_PLACE_M, else the spot itself as "anon_at:X:Z" (remembered for her essence,
## essence.gd known places, so an unloaded pony travels there too).
const SPOT_PREFIX := "anon_at:"
const NEAR_PLACE_M := 40.0
## She sets off at once; the meeting hour is when she should be there (travel at about this pace,
## at least COME_MIN_HOURS from now, rounded up to 5 game minutes). COME_MIN_HOURS stays just past
## meet_time.gd SOONEST_HOURS (20 min), or a pony close by was refused as "already passed".
const COME_SPEED := 2.5
const COME_MIN_HOURS := 0.35

var game: Node
## /root/TimeOfDay, or a test double with `day: int` and `hours: float`.
var clock: Node
var _poll := 0.0
var _last_now := -1.0
## pony id -> {"text", "until"} session-only greeting retries after a met.
var _greet: Dictionary = {}

func setup(host: Node) -> void:
	game = host
	if clock == null: clock = get_node_or_null("/root/TimeOfDay") if is_inside_tree() else null
	add_to_group(GROUP)
	add_to_group("pony_prompt_notes")
	var context := _context()
	if context != null and context.has_signal("reopened") and not context.is_connected("reopened", _reopened):
		context.connect("reopened", _reopened)

## Rows live in world_context.state and are read fresh every time; only session state resets.
func _reopened(_world_id: String) -> void:
	_greet.clear()
	_last_now = -1.0

# --- API ----------------------------------------------------------------------------------------

## Agree a meeting, or move her open one. {"ok", "id", "error", "row"}.
func propose(pony: String, place: String, day_word: String, time_text: String, source: String, note := "") -> Dictionary:
	var rows: Variant = _rows(true)
	if rows == null or pony.is_empty(): return {"ok": false, "id": "", "error": "Appointments unavailable", "row": {}}
	var spot := _place(place)
	if spot.is_empty(): return {"ok": false, "id": "", "error": UNKNOWN_PLACE, "row": {}}
	var when := MEET_TIME.parse(day_word, time_text, _day(), _hours())
	if not bool(when.ok): return {"ok": false, "id": "", "error": str(when.error), "row": {}}
	var day := int(when.day)
	var hour := float(when.hour)
	var clean_note := note.strip_edges().replace("\n", " ").left(NOTE_CHARS)
	var row: Dictionary = open_for(pony)
	var today := _card_day()
	var touches_today := day == today
	if not row.is_empty():
		var stored: Dictionary = rows[row.id]
		if str(stored.place) == str(spot.id) and int(stored.day) == day and is_equal_approx(float(stored.hour), hour):
			# The same meeting said again: nothing moves.
			if not clean_note.is_empty() and str(stored.note).is_empty(): stored.note = clean_note; _changed()
			return {"ok": true, "id": str(row.id), "error": "", "row": stored.duplicate(true)}
		touches_today = touches_today or int(stored.day) == today
		var history: Array = stored.get("history", [])
		history.append(("moved from %s day %d %s (%s)" % [str(stored.place_label), int(stored.day), MEET_TIME.clock_text(float(stored.hour)), _source_kind(source)]).left(120))
		while history.size() > HISTORY: history.pop_front()
		stored.merge({"place": spot.id, "place_label": spot.label, "day": day, "hour": hour, "source": source, "status": "planned",
			"wait_until": float(day) + (hour + WAIT_HOURS) / 24.0, "player_seen": false, "history": history}, true)
		if not clean_note.is_empty(): stored.note = clean_note
		# A moved meeting keeps the usual lead (M-AI-18 come() sets it again for a new call).
		stored.erase("leave_at")
		row = stored
		_record(pony, "appointment", "You and Anon moved your meeting: now at %s %s at %s." % [spot.label, MEET_TIME.day_words(day, _day()), MEET_TIME.clock_text(hour)], "appt:%s:%d" % [row.id, history.size()])
	else:
		var store: Dictionary = game.world_context.state[STATE_KEY]
		store.serial = int(store.get("serial", 0)) + 1
		var id := "A%d-%d" % [_day(), int(store.serial)]
		row = {"id": id, "pony": pony, "with": "player", "place": spot.id, "place_label": spot.label, "day": day, "hour": hour,
			"made_at": _now(), "source": source, "note": clean_note, "status": "planned",
			"wait_until": float(day) + (hour + WAIT_HOURS) / 24.0, "player_seen": false, "history": []}
		rows[id] = row
		_record(pony, "appointment", "You agreed to meet Anon at %s %s at %s%s." % [spot.label, MEET_TIME.day_words(day, _day()), MEET_TIME.clock_text(hour), (" (" + clean_note + ")") if not clean_note.is_empty() else ""], "appt:" + id)
	_prune(rows)
	_changed()
	appointment_changed.emit(row.duplicate(true))
	if touches_today: _refresh_day(pony)
	return {"ok": true, "id": str(row.id), "error": "", "row": row.duplicate(true)}

## Calls off her open meeting; false when she has none.
func cancel(pony: String, source: String, reason := "") -> bool:
	var rows: Variant = _rows(true)
	var open := open_for(pony)
	if rows == null or open.is_empty(): return false
	var row: Dictionary = rows[open.id]
	var history: Array = row.get("history", [])
	history.append(("cancelled (%s)%s" % [_source_kind(source), (": " + reason) if not reason.is_empty() else ""]).left(120))
	while history.size() > HISTORY: history.pop_front()
	row.history = history
	_record(pony, "appointment", "Your meeting with Anon at %s on day %d at %s is called off%s." % [row.place_label, int(row.day), MEET_TIME.clock_text(float(row.hour)), (": " + reason.left(80)) if not reason.is_empty() else ""], "appt:%s:cancel" % row.id)
	_resolve(row, "cancelled")
	if int(row.day) == _card_day(): _refresh_day(pony)
	return true

## Her planned or waiting meeting with Anon (a copy), or {}.
func open_for(pony: String) -> Dictionary:
	var rows: Variant = _rows(false)
	if rows == null: return {}
	for row: Dictionary in rows.values():
		if str(row.get("pony", "")) == pony and str(row.get("status", "")) in OPEN: return row.duplicate(true)
	return {}

func row(id: String) -> Dictionary:
	var rows: Variant = _rows(false)
	return (rows[id] as Dictionary).duplicate(true) if rows != null and rows.has(id) else {}

## Planned/waiting rows on that day, for the day-card merge (appointment_steps.gd).
func rows_for_day(pony: String, day: int) -> Array:
	var out: Array = []
	var rows: Variant = _rows(false)
	if rows == null: return out
	for r: Dictionary in rows.values():
		if str(r.get("pony", "")) == pony and int(r.get("day", -1)) == day and str(r.get("status", "")) in OPEN: out.append(r.duplicate(true))
	return out

## Her day step reached the place (actions/appointment.gd), or her essence is there.
func mark_waiting(id: String) -> void:
	var rows: Variant = _rows(true)
	if rows == null or not rows.has(id) or str(rows[id].status) != "planned": return
	rows[id].status = "waiting"
	_changed()
	appointment_changed.emit((rows[id] as Dictionary).duplicate(true))

## Metres from her home to the place (the day step leaves earlier for a far one); 0 unknown.
func home_distance(pony: String, place: String) -> float:
	var population: Node = game.get("population") if game != null else null
	if population == null or not population.has_method("home_position"): return 0.0
	var home: Vector3 = population.home_position(pony, true)
	var there := place_point(place)
	if not home.is_finite() or not there.is_finite(): return 0.0
	return Vector2(home.x - there.x, home.z - there.z).length()

## The meeting point: a house means outside its front door, never inside.
func place_point(place: String) -> Vector3:
	if place.begins_with(SPOT_PREFIX): return _spot(place)
	if not is_inside_tree(): return Vector3.INF
	var entry := PLACES.find(get_tree(), place)
	if entry.is_empty():
		# Its zone is not loaded: where the living world last saw it (essence.gd known places).
		var population: Node = game.get("population") if game != null else null
		return ESSENCE.known(population, place) if population != null else Vector3.INF
	if str(entry.kind) == PLACES.HOUSE_KIND and is_instance_valid(entry.get("node")) and entry.node.has_method("outside"): return entry.node.outside()
	return PLACES.resolve(get_tree(), place)

## One line for her prompt (director_prompts.gd situation_block via group pony_prompt_notes).
func prompt_note(pony: String) -> String:
	var rows: Variant = _rows(false)
	if rows == null or rows.is_empty(): return ""
	var open := open_for(pony)
	var text := ""
	if not open.is_empty():
		var at := MEET_TIME.clock_text(float(open.hour))
		if str(open.status) == "waiting":
			text = "- You are at %s to meet Anon as agreed for %s (now %s)." % [open.place_label, at, MEET_TIME.clock_text(_hours())]
		else:
			var note := str(open.get("note", ""))
			text = "- You agreed to meet Anon at %s %s at %s%s. [meet: ...] moves it, [meet_cancel] calls it off." % [open.place_label, MEET_TIME.day_words(int(open.day), _day()), at, (" (" + note + ")") if not note.is_empty() else ""]
	else:
		var newest := {}
		for r: Dictionary in rows.values():
			if str(r.get("pony", "")) != pony or str(r.get("status", "")) not in ["met", "stood_up"]: continue
			if newest.is_empty() or float(r.get("resolved_at", 0.0)) > float(newest.get("resolved_at", 0.0)): newest = r
		var age := _now() - float(newest.get("resolved_at", -INF))
		if str(newest.get("status", "")) == "met" and age <= 1.0 / 24.0:
			text = "- You and Anon met at %s as you agreed." % newest.place_label
		elif str(newest.get("status", "")) == "stood_up" and age <= 2.0:
			text = "- Anon stood you up at %s on day %d." % [newest.place_label, int(newest.day)]
	return text.left(PROMPT_CHARS)

## M-AI-18: she read his letter asking her to come and agreed. A meeting where he is now (a mapped
## place near him, else his spot), at the hour she can be there; her day plan walks her there at
## once. {"ok", "id", "error", "row"} like propose().
func come(pony: String, source: String, note := "") -> Dictionary:
	var player := _player_position()
	if not player.is_finite(): return {"ok": false, "id": "", "error": "Anon's whereabouts are unknown", "row": {}}
	var place := _place_near(player)
	var there := place_point(place)
	var from := _pony_point(pony)
	var hours := COME_MIN_HOURS
	if from.is_finite() and there.is_finite():
		hours = maxf(hours, _flat(from, there) / COME_SPEED / 60.0 * (24.0 / maxf(_day_length_minutes(), 1.0)))
	# Meetings keep meet_time.gd's hours: before 06:00 she comes at 06:00; after 21:00 not today.
	var at := maxf(ceilf((_hours() + hours) * 12.0) / 12.0, MEET_TIME.EARLIEST)
	if at > MEET_TIME.LATEST: return {"ok": false, "id": "", "error": "Too late in the day to come now", "row": {}}
	var made := propose(pony, place, "today", MEET_TIME.clock_text(at), source, note)
	if not bool(made.get("ok", false)): return made
	if place.begins_with(SPOT_PREFIX):
		var population: Node = game.get("population") if game != null else null
		if population != null: ESSENCE.remember(population, place, there)
	# She leaves now, not the usual lead before the hour (appointment_steps.gd step_for "leave_at").
	var rows: Variant = _rows(true)
	if rows is Dictionary and (rows as Dictionary).has(str(made.id)):
		var stored: Dictionary = rows[str(made.id)]
		stored.leave_at = _hours()
		made.row = stored.duplicate(true)
		_changed()
		_refresh_day(pony)
	return made

## A mapped place within NEAR_PLACE_M of `at` (nearest first), else "anon_at:X:Z".
func _place_near(at: Vector3) -> String:
	var best := ""
	var best_d := NEAR_PLACE_M
	if is_inside_tree():
		for e: Dictionary in PLACES.entries(get_tree()):
			# A region ("Ponyville") is no meeting point; landmarks and houses are.
			if str(e.get("kind", "")).begins_with("region"): continue
			var p: Variant = e.get("position")
			if not p is Vector3 or not (p as Vector3).is_finite(): continue
			var d := _flat(p, at)
			if d < best_d: best = str(e.id); best_d = d
	return best if not best.is_empty() else "%s%d:%d" % [SPOT_PREFIX, roundi(at.x), roundi(at.z)]

## The ground point of an "anon_at:X:Z" spot, or INF.
static func _spot(place: String) -> Vector3:
	var parts := place.trim_prefix(SPOT_PREFIX).split(":")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int(): return Vector3.INF
	var at := Vector3(float(parts[0].to_int()), 0.0, float(parts[1].to_int()))
	var height := 0.0
	if is_instance_valid(WorldTerrain.instance):
		var h: float = WorldTerrain.instance.height_at(at)
		if is_finite(h): height = h
	at.y = height
	return at

## Her body, else her essence.
func _pony_point(pony: String) -> Vector3:
	var actor := _actor(pony)
	if actor != null: return actor.global_position
	var population: Node = game.get("population") if game != null else null
	return ESSENCE.position(ESSENCE.record(population, pony)) if population != null else Vector3.INF

func _day_length_minutes() -> float:
	var minutes: Variant = clock.get("day_length_minutes") if clock != null else null
	return float(minutes) if (minutes is float or minutes is int) and float(minutes) > 0.0 else 60.0

# --- Window tracking ----------------------------------------------------------------------------

func _process(delta: float) -> void:
	_poll -= delta
	if _poll > 0.0: return
	_poll = POLL
	tick()

## One poll: player seen near the place, met, stood up or lapsed. Public for tests.
func tick() -> void:
	var rows: Variant = _rows(false)
	var now := _now()
	var skipped_from := _last_now
	_last_now = now
	if rows == null or rows.is_empty() or (game.world_context.get("_read_only") == true): return
	var player := _player_position()
	for id: String in rows.keys():
		var r: Dictionary = rows[id]
		if str(r.get("status", "")) not in OPEN: continue
		var hour := float(r.hour)
		var start := float(r.day) + (hour - EARLY_HOURS) / 24.0
		if now < start: continue
		var pony := str(r.pony)
		var there := place_point(str(r.place))
		var actor := _actor(pony)
		if str(r.status) == "planned" and there.is_finite():
			# An unloaded pony's essence walked there on her day plan: she is waiting too.
			var essence_at := ESSENCE.position(ESSENCE.record(game.population, pony)) if actor == null and game.get("population") != null else Vector3.INF
			if essence_at.is_finite() and _flat(essence_at, there) < ESSENCE_THERE_M: mark_waiting(id)
		if player.is_finite() and there.is_finite() and _flat(player, there) < SEEN_M and not bool(r.player_seen):
			r.player_seen = true
			_changed()
		if str(r.status) == "waiting" and actor != null and player.is_finite() and _flat(player, actor.global_position) < MEET_M:
			_met(r)
			continue
		if now <= float(r.wait_until): continue
		# Slept or skipped through the whole window: she went and waited without him.
		var jumped: bool = skipped_from >= 0.0 and skipped_from < float(r.day) + hour / 24.0
		if (str(r.status) == "waiting" or jumped) and not bool(r.player_seen) and _known(r): _stood_up(r)
		elif (str(r.status) == "waiting" or jumped) and not bool(r.player_seen):
			# Her reply naming this meeting had not reached him: no blame (letter_post.gd meeting_known).
			_record(pony, "appointment_missed", "Anon never came to %s on day %d at %s; your letter about it may not have reached him in time." % [r.place_label, int(r.day), MEET_TIME.clock_text(hour)], "appt:%s:unread" % id)
			_resolve(r, "lapsed")
		elif bool(r.player_seen):
			_record(pony, "appointment_missed", "Anon came by %s around the time you agreed (day %d, %s), but you two missed each other." % [r.place_label, int(r.day), MEET_TIME.clock_text(hour)], "appt:%s:missed" % id)
			_resolve(r, "lapsed")
		else:
			_record(pony, "appointment_lapsed", "You could not make it to meet Anon at %s on day %d at %s as agreed." % [r.place_label, int(r.day), MEET_TIME.clock_text(hour)], "appt:%s:lapsed" % id)
			_resolve(r, "lapsed")
	_greet_pending()
	if randf() < .02: _prune(rows)

func _met(r: Dictionary) -> void:
	var pony := str(r.pony)
	var why := str(r.get("note", ""))
	# M-AI-16 (player board #49: Dash came "but said she never got the letter"): a meeting made by
	# letter says so, with what it was about; the letter itself stays pinned through the meeting.
	var by_letter := str(r.source).begins_with("letter:")
	var letter_note := ""
	if why.is_empty(): why = "you agreed by letter" if by_letter else "you agreed when you talked"
	elif by_letter: letter_note = "; you arranged it in your letters, so you got his letter"
	var text := "[Observed situation, not player speech] Anon has come to meet you at %s as you two agreed (%s)%s. Greet him and start what you planned. One or two short sentences." % [r.place_label, why, letter_note]
	_greet[pony] = {"text": text, "until": Time.get_ticks_msec() * .001 + GREET_RETRY_S}
	var bonds := _bonds()
	if bonds != null and bonds.has_method("kept_appointment"): bonds.kept_appointment(pony, str(r.id))
	_record(pony, "appointment_met", "Anon came to meet you at %s on day %d at %s, as you two agreed." % [r.place_label, int(r.day), MEET_TIME.clock_text(float(r.hour))], "appt:%s:met" % r.id)
	_resolve(r, "met")
	_greet_pending()

## Her greeting starts the meeting; a busy director gets a few more tries while he is with her.
func _greet_pending() -> void:
	if _greet.is_empty(): return
	var director: Node = game.get("director") if game != null else null
	var player := _player_position()
	for pony: String in _greet.keys():
		var entry: Dictionary = _greet[pony]
		var actor := _actor(pony)
		var near: bool = actor != null and player.is_finite() and _flat(player, actor.global_position) < MEET_M + 2.0
		if Time.get_ticks_msec() * .001 > float(entry.until) or not near or not is_instance_valid(director):
			_greet.erase(pony); continue
		if director.has_method("begin_player_greeting") and bool(director.call("begin_player_greeting", pony, str(entry.text))): _greet.erase(pony)

func _stood_up(r: Dictionary) -> void:
	var pony := str(r.pony)
	var left_at := MEET_TIME.clock_text(minf(float(r.hour) + WAIT_HOURS, 23.99))
	var sentence := "Anon did not come to meet you at %s on day %d at %s as agreed. You waited until %s." % [r.place_label, int(r.day), MEET_TIME.clock_text(float(r.hour)), left_at]
	var bonds := _bonds()
	if bonds != null and bonds.has_method("stood_up"): bonds.stood_up(pony, str(r.id))
	var context := _context()
	if context != null and is_instance_valid(context.get("impressions")):
		context.impressions.commit(pony, {"friendship": -2, "mood": "annoyed", "thought": "I waited at %s and Anon never came." % r.place_label}, "appt:" + str(r.id))
	_record(pony, "stood_up", sentence, "appt:%s:stood_up" % r.id)
	_resolve(r, "stood_up")
	if write_roll(str(r.id)) < 0.5:
		var post: Node = get_tree().get_first_node_in_group("letter_post") if is_inside_tree() else null
		if post != null and post.has_method("pony_writes"): post.pony_writes(pony, sentence, "annoyed")

## Whether Anon could know of this meeting: one made in a letter's reply counts once that reply
## reached him in time or he took it (letter_post.gd meeting_known); a spoken one always does.
func _known(r: Dictionary) -> bool:
	var source := str(r.get("source", ""))
	if not source.begins_with("letter:") or not is_inside_tree(): return true
	var post: Node = get_tree().get_first_node_in_group("letter_post")
	return post == null or not post.has_method("meeting_known") or bool(post.call("meeting_known", source.trim_prefix("letter:")))

## A stable roll in [0, 1) per meeting: whether she writes him an annoyed note.
static func write_roll(id: String) -> float:
	return float(absi(hash(id + ":write")) % 1000) / 1000.0

func _resolve(r: Dictionary, status: String) -> void:
	r.status = status
	r.resolved_at = _now()
	_changed()
	appointment_resolved.emit(r.duplicate(true))

# --- Helpers ------------------------------------------------------------------------------------

## {"id", "label"} for an id or a free-form name over the mapped places, or {}.
func _place(place: String) -> Dictionary:
	if place.begins_with(SPOT_PREFIX) and _spot(place).is_finite(): return {"id": place, "label": "the spot where Anon wrote from"}
	if not is_inside_tree() or place.strip_edges().is_empty(): return {}
	var ids: Array = []
	var labels := {}
	for e: Dictionary in PLACES.entries(get_tree()):
		ids.append(e.id)
		labels[e.id] = str(e.get("label", "")) + (" " + str(e.alt) if e.has("alt") else "")
	var id := PLACES.match_name(place, ids, labels)
	if id.is_empty(): return {}
	var entry := PLACES.find(get_tree(), id)
	return {"id": id, "label": str(entry.get("label", id))}

func _refresh_day(pony: String) -> void:
	var runner: Node = get_tree().get_first_node_in_group("day_runner") if is_inside_tree() else null
	if runner != null and runner.has_method("refresh_appointments"): runner.refresh_appointments(pony)

func _prune(rows: Variant) -> void:
	var now := _now()
	for id: String in rows.keys():
		var r: Dictionary = rows[id]
		if str(r.get("status", "")) not in OPEN and now - float(r.get("resolved_at", r.get("wait_until", now))) > KEEP_DAYS: rows.erase(id)

func _record(pony: String, kind: String, text: String, event_id: String) -> void:
	var context := _context()
	if context != null and context.get("_read_only") != true: context.record(kind, text, [pony, "player"], [pony, "player"], event_id)

func _rows(write: bool) -> Variant:
	var context := _context()
	if context == null or (write and context.get("_read_only") == true): return null
	var store: Variant = context.state.get(STATE_KEY)
	if not store is Dictionary or not (store as Dictionary).get("rows") is Dictionary:
		if not write: return null
		store = {"serial": 0, "rows": {}}
		context.state[STATE_KEY] = store
	return (store as Dictionary).rows

func _changed() -> void:
	var context := _context()
	if context != null: context._changed()

func _context() -> Node:
	return game.get("world_context") if game != null and is_instance_valid(game.get("world_context")) else null

func _bonds() -> Node:
	var context := _context()
	return context.get("player_bonds") if context != null and is_instance_valid(context.get("player_bonds")) else null

func _actor(pony: String) -> Node3D:
	var population: Node = game.get("population") if game != null else null
	if population == null: return null
	var entry: Variant = population.live.get(pony, {})
	var actor: Variant = (entry as Dictionary).get("actor") if entry is Dictionary else null
	return actor if is_instance_valid(actor) and (actor as Node3D).is_inside_tree() else null

func _player_position() -> Vector3:
	var player: Variant = game.get("player") if game != null else null
	if not is_instance_valid(player) or not (player as Node3D).is_inside_tree(): return Vector3.INF
	var camera: Variant = game.call("_find_camera", player) if game.has_method("_find_camera") else null
	return (camera as Node3D).global_position if is_instance_valid(camera) else (player as Node3D).global_position

static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

static func _source_kind(source: String) -> String:
	return source.get_slice(":", 0) if not source.is_empty() else "talk"

func _day() -> int:
	return int(clock.day) if clock != null else 0

func _hours() -> float:
	return float(clock.hours) if clock != null else 12.0

func _now() -> float:
	return float(_day()) + _hours() / 24.0

## The day card's day (day_runner.gd _day_key): past midnight belongs to yesterday until 05:00.
func _card_day() -> int:
	return _day() - (1 if _hours() < 5.0 else 0)
