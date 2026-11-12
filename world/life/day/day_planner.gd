extends RefCounted
## Rolls a pony's day (dev 2026-09-26): "every action/place/visit is on a loot table of sorts and
## every day its rolled randomly on what the pony will do that day". A day card is a few steps,
## each a mad-libs line: an action (verb), a target (place, pony or item) and a reason, with a
## start hour and a deadline. Free time lies between the steps. Pure and deterministic: the same
## pony on the same day always gets the same card. docs/DAY_PLANS.md describes the table format.

const TABLES_PATH := "res://world/life/day/day_tables.json"
## Extra table files (seasonal.json from the seasons work, mods' own rows), merged over the main
## table in file-name order: "actions", "targets" and "reasons" add or replace whole rows,
## "overrides" merge per pony. Read once, with the main table.
const EXTRA_DIR := "res://world/life/day/tables/"
const MERGED_KEYS := ["actions", "targets", "reasons"]
static var _tables := {}

static func tables() -> Dictionary:
	if _tables.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(TABLES_PATH))
		_tables = parsed if parsed is Dictionary else {"day": {}, "actions": {}, "targets": {}, "reasons": {}}
		for file: String in extra_files(): merge_table(_tables, JSON.parse_string(FileAccess.get_file_as_string(EXTRA_DIR + file)))
	return _tables

## The *.json files in EXTRA_DIR, sorted (an exported pack lists them the same way).
static func extra_files() -> PackedStringArray:
	var files := PackedStringArray()
	if not DirAccess.dir_exists_absolute(EXTRA_DIR): return files
	for file: String in DirAccess.get_files_at(EXTRA_DIR):
		if file.get_extension().to_lower() == "json": files.append(file)
	files.sort()
	return files

## Merges one extra table into `into` (see EXTRA_DIR). A file that is not an object, or a section
## that is not one, is skipped.
static func merge_table(into: Dictionary, extra: Variant) -> void:
	if not extra is Dictionary: return
	var table: Dictionary = extra
	for key: String in MERGED_KEYS:
		if not table.get(key) is Dictionary: continue
		if not into.get(key) is Dictionary: into[key] = {}
		(into[key] as Dictionary).merge(table[key] as Dictionary, true)
	if table.get("overrides") is Dictionary:
		if not into.get("overrides") is Dictionary: into["overrides"] = {}
		var overrides: Dictionary = into["overrides"]
		for pony: Variant in table.overrides:
			var row: Variant = table.overrides[pony]
			if not row is Dictionary: continue
			if not overrides.get(pony) is Dictionary: overrides[pony] = {}
			(overrides[pony] as Dictionary).merge(row as Dictionary, true)

## info: {"wings": bool, "friends": [ids], "others": [ids], "wake": hour, "bed": hour (may be
## past 24 for a night owl), "season", "events": [ids], "station_needs": [ids] (the mechanics hub,
## optional)}. Returns [{action, handler, target, item, reason, posture, minutes,
## start, until, night}], ordered by start hour.
static func roll(id: String, day: int, info: Dictionary) -> Array:
	var t := tables()
	var d: Dictionary = t.get("day", {})
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("day:%s:%d" % [id, day])
	var steps_range: Array = d.get("steps", [3, 5])
	var count := rng.randi_range(int(steps_range[0]), int(steps_range[1]))
	var start_range: Array = d.get("start_hour", [7.5, 9.5])
	var wake := maxf(float(info.get("wake", 7.0)), float(start_range[0]))
	var first := maxf(wake, rng.randf_range(float(start_range[0]), float(start_range[1])))
	var bed := float(info.get("bed", 21.5))
	var last := bed - 0.5
	if last <= first + 1.0: return []
	var window := float(d.get("window_hours", 2.0))
	var card: Array = []
	var previous := ""
	# One step in each slice of the waking day, at a random point of its slice.
	for i in count:
		var slice_start := lerpf(first, last, float(i) / count)
		var slice_end := lerpf(first, last, float(i + 1) / count)
		var at := rng.randf_range(slice_start, lerpf(slice_start, slice_end, 0.6))
		var step := _roll_step(id, at, bed, previous, info, rng)
		if step.is_empty(): continue
		step.start = at
		step.until = minf(at + window, bed)
		card.append(step)
		previous = str(step.action)
	return card

static func _roll_step(id: String, hour: float, bed: float, previous: String, info: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var t := tables()
	var overrides: Dictionary = t.get("overrides", {}).get(id, {})
	var choices: Array = []
	var total := 0.0
	for action: String in t.get("actions", {}):
		if action == previous: continue
		var a: Dictionary = t.actions[action]
		if not _fits_hour(a, hour, bed): continue
		if not _fits(a.get("when", {}), id, info): continue
		var weight := float(a.get("weight", 1.0)) * float(overrides.get(action, 1.0))
		if weight <= 0.0: continue
		choices.append([action, weight])
		total += weight
	if choices.is_empty(): return {}
	var roll_at := rng.randf() * total
	var action: String = choices[-1][0]
	for c: Array in choices:
		roll_at -= float(c[1])
		if roll_at <= 0.0: action = c[0]; break
	var a: Dictionary = t.actions[action]
	var target := ""
	var item := ""
	var pool: Dictionary = t.get("targets", {}).get(str(a.get("target", "")), {})
	if pool.has("places"):
		var places: Array = pool.places
		target = str(places[rng.randi_range(0, places.size() - 1)])
		var items: Array = pool.get("items", {}).get(target, [])
		if not items.is_empty(): item = str(items[rng.randi_range(0, items.size() - 1)])
	elif pool.has("ponies"):
		var ponies: Array = info.get("friends", []) if str(pool.ponies) == "friends" else pool.ponies
		ponies = ponies.filter(func(p): return str(p) != id)
		if ponies.is_empty() and str(pool.ponies) == "friends": ponies = info.get("others", []).filter(func(p): return str(p) != id)
		if ponies.is_empty(): return {}
		target = str(ponies[rng.randi_range(0, ponies.size() - 1)])
	elif a.has("target"):
		return {}
	# A reason may carry hours ("for lunch" only at midday).
	var reasons: Array = t.get("reasons", {}).get(str(a.get("reasons", "")), []).filter(func(r):
		return not (r is Dictionary) or (hour >= float(r.hours[0]) and hour <= float(r.hours[1]))).map(func(r): return str(r.text) if r is Dictionary else str(r))
	var postures: Array = a.get("posture", ["stand"])
	var minutes: Array = a.get("minutes", [15, 30])
	return {"action": action, "handler": str(a.get("handler", action)), "target": target, "item": item,
		"reason": str(reasons[rng.randi_range(0, reasons.size() - 1)]) if not reasons.is_empty() else "",
		"posture": str(postures[rng.randi_range(0, postures.size() - 1)]),
		"minutes": rng.randf_range(float(minutes[0]), float(minutes[1])),
		"phrase": str(a.get("phrase", action)), "night": bool(a.get("night_only", false))}

static func _fits_hour(a: Dictionary, hour: float, bed: float) -> bool:
	if bool(a.get("night_only", false)) and bed < 24.0: return false   # only night owls stay up for it
	for key in ["hours", "also_hours"]:
		if not a.has(key): continue
		var h: Array = a[key]
		if hour >= float(h[0]) and hour <= float(h[1]): return true
	return not a.has("hours")

static func _fits(when: Dictionary, id: String, info: Dictionary) -> bool:
	if when.has("spot"):
		var required: Array = when.spot if when.spot is Array else [str(when.spot)]
		var available: Dictionary = info.get("spots", {})
		for kind: String in required:
			if not available.get(kind.trim_prefix("spot:"), false): return false
	if when.has("wings") and bool(when.wings) != bool(info.get("wings", false)): return false
	if when.has("horn") and bool(when.horn) != bool(info.get("horn", false)): return false
	if when.has("only_id") and id not in when.only_id: return false
	if when.has("not_id") and id in when.not_id: return false
	# The shared mechanics (docs/MECHANICS_ARCHITECTURE_2026_11_01.md 10.1): today's season, town
	# events and station work, filled by day_runner._info (absent = none, so old cards stay the same).
	if when.has("season"):
		var seasons: Array = when.season if when.season is Array else [str(when.season)]
		if str(info.get("season", "")) not in seasons: return false
	var events: Array = info.get("events", []) if info.get("events") is Array else []
	if when.has("event") and str(when.event) not in events: return false
	if when.has("not_event") and str(when.not_event) in events: return false
	if when.has("station_needs"):
		var needs: Array = info.get("station_needs", []) if info.get("station_needs") is Array else []
		if str(when.station_needs) not in needs: return false
	return true

## "visit Fluttershy for tea" with the place/pony names filled in by `label`.
static func describe(step: Dictionary, label: Callable) -> String:
	var text := str(step.phrase).replace("{target}", str(label.call(step.target)) if not str(step.target).is_empty() else "")
	text = text.replace("{item}", str(step.item))
	if not str(step.reason).is_empty(): text += " " + str(step.reason)
	return text
