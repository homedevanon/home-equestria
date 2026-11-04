extends RefCounted
## Station spec rules (P3 of docs/MECHANICS_ARCHITECTURE_2026_11_01.md, section 6.1): loading
## world/mechanics/data/stations.json, rejecting malformed rows, and matching items against a
## row's {tag|id, count} entries. Pure and static; the runner (stations.gd) owns the state.
const ITEM_CATALOG := preload("res://world/inventory/item_catalog.gd")
const KINDS := ["process", "grow", "adapter"]
const NEED_KEYS := ["season", "season_not", "hours", "event", "water"]
const SEASONS := ["spring", "summer", "autumn", "winter"]

## {"rows": Array[Dictionary] (valid rows in file order), "errors": PackedStringArray}.
static func load_file(path: String) -> Dictionary:
	var empty: Array[Dictionary] = []
	var result := {"rows": empty, "errors": PackedStringArray()}
	if not FileAccess.file_exists(path):
		result.errors.append("missing " + path); return result
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary or not (parsed as Dictionary).get("stations") is Array:
		result.errors.append("no stations list in " + path); return result
	return parse_rows((parsed as Dictionary).stations)

## Validates a list of rows; malformed rows and duplicate ids are left out with a reason.
static func parse_rows(list: Array) -> Dictionary:
	var rows: Array[Dictionary] = []
	var errors := PackedStringArray()
	var seen := {}
	for raw: Variant in list:
		var why := row_error(raw)
		if why.is_empty() and seen.has(str((raw as Dictionary).id)): why = "duplicate id"
		if not why.is_empty():
			errors.append("%s: %s" % [str((raw as Dictionary).get("id", "?")) if raw is Dictionary else "?", why]); continue
		seen[str((raw as Dictionary).id)] = true
		rows.append(raw)
	return {"rows": rows, "errors": errors}

## "" when the row is a usable station spec, else why not.
static func row_error(raw: Variant) -> String:
	if not raw is Dictionary: return "not an object"
	var row: Dictionary = raw
	if not valid_id(row.get("id")): return "id must be [a-z0-9_]"
	if not row.get("kind") in KINDS: return "kind must be process, grow or adapter"
	if not row.get("driver") is String or str(row.driver).is_empty(): return "driver missing"
	if not row.get("workers") is Array or (row.workers as Array).is_empty(): return "workers missing"
	for worker: Variant in row.workers:
		if not worker is String or str(worker).is_empty(): return "bad worker"
	for key: String in ["inputs", "outputs"]:
		if not row.get(key, []) is Array: return key + " must be a list"
		for entry: Variant in row.get(key, []):
			if not entry is Dictionary: return key + " rows must be objects"
			var item: Dictionary = entry
			var named: bool = item.get("id") is String and ITEM_CATALOG.has(str(item.id))
			var tagged: bool = item.get("tag") is String and not str(item.tag).is_empty()
			if not named and not tagged and not (key == "outputs" and item.has("orchard_tree")): return "%s row needs a known id or a tag" % key
			if item.has("count") and not (_number(item.count) and int(item.count) >= 1): return key + " count must be >= 1"
	if not row.get("copper") is Dictionary: return "copper block missing"
	match str(row.kind):
		"process":
			if not _number(row.get("seconds")) or float(row.seconds) <= 0.0: return "process needs seconds > 0"
			if (row.get("inputs", []) as Array).is_empty() or (row.get("outputs", []) as Array).is_empty(): return "process needs inputs and outputs"
			if not where(row).is_finite(): return "process needs where.world"
		"grow":
			if not _number(row.get("days")) or float(row.days) <= 0.0: return "grow needs days > 0"
			if not where(row).is_finite(): return "grow needs where.world"
	var needs: Variant = row.get("needs", {})
	if not needs is Dictionary: return "needs must be an object"
	for key: Variant in needs:
		if not str(key) in NEED_KEYS: return "unknown need " + str(key)
	var hours: Variant = (needs as Dictionary).get("hours")
	if hours != null and not (hours is Array and (hours as Array).size() == 2 and _number(hours[0]) and _number(hours[1])): return "hours must be [a, b]"
	return ""

static func valid_id(value: Variant) -> bool:
	if not value is String or str(value).is_empty() or str(value).length() > 64: return false
	for c: String in str(value):
		if not c in "abcdefghijklmnopqrstuvwxyz0123456789_": return false
	return true

static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

## The spec's world point (y 0 until the ground is known), or INF.
static func where(row: Dictionary) -> Vector3:
	var place: Variant = row.get("where")
	if not place is Dictionary: return Vector3.INF
	var world: Variant = (place as Dictionary).get("world")
	if not world is Array or (world as Array).size() != 3: return Vector3.INF
	for value: Variant in world:
		if not _number(value): return Vector3.INF
	return Vector3(float(world[0]), float(world[1]), float(world[2]))

## True when `item_id` fits an {id|tag} entry.
static func matches(entry: Dictionary, item_id: String) -> bool:
	item_id = ITEM_CATALOG.canonical(item_id)
	if entry.get("id") is String: return ITEM_CATALOG.canonical(str(entry.id)) == item_id
	if entry.get("tag") is String: return ITEM_CATALOG.has_tag(item_id, str(entry.tag))
	return false

static func count(entry: Dictionary) -> int:
	return maxi(1, int(entry.get("count", 1))) if _number(entry.get("count", 1)) else 1

## The output ids of a row, one per unit ("goods:cider-keg" x1 -> ["goods:cider-keg"]). Tag-only
## and orchard rows make nothing a runner can hand out (their adapters report what they make).
static func output_ids(row: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	for entry: Variant in row.get("outputs", []):
		if entry is Dictionary and (entry as Dictionary).get("id") is String:
			for i: int in count(entry): ids.append(ITEM_CATALOG.canonical(str((entry as Dictionary).id)))
	return ids

## Which input entry (index) the item can still fill, given what is already loaded; -1 if none.
static func free_input(row: Dictionary, loaded: Array, item_id: String) -> int:
	var used := allocate(row, loaded)
	var inputs: Array = row.get("inputs", [])
	for index: int in inputs.size():
		if inputs[index] is Dictionary and matches(inputs[index], item_id) and int(used[index]) < count(inputs[index]): return index
	return -1

## How many loaded items each input entry holds (first fitting entry wins, in order).
static func allocate(row: Dictionary, loaded: Array) -> Array[int]:
	var inputs: Array = row.get("inputs", [])
	var used: Array[int] = []
	used.resize(inputs.size())
	used.fill(0)
	for item: Variant in loaded:
		for index: int in inputs.size():
			if inputs[index] is Dictionary and matches(inputs[index], str(item)) and used[index] < count(inputs[index]):
				used[index] += 1; break
	return used

static func inputs_ready(row: Dictionary, loaded: Array) -> bool:
	var inputs: Array = row.get("inputs", [])
	var used := allocate(row, loaded)
	for index: int in inputs.size():
		if not inputs[index] is Dictionary or used[index] < count(inputs[index]): return false
	return true

## "" when the season/hours/event needs hold. `season` is a SEASONS name, `hours` 0..24,
## `active` a Callable(event_id) -> bool (or an invalid Callable when no calendar runs).
static func needs_error(row: Dictionary, season: String, hours: float, active: Callable) -> String:
	var needs: Variant = row.get("needs", {})
	if not needs is Dictionary: return ""
	var name := str(row.get("name", row.get("id", "station")))
	var wanted: Variant = (needs as Dictionary).get("season")
	if wanted != null:
		var allowed: Array = wanted if wanted is Array else [wanted]
		if not season in allowed: return "The %s only works in %s" % [name, ", ".join(PackedStringArray(allowed))]
	var not_in: Variant = (needs as Dictionary).get("season_not")
	if not_in is Array and season in not_in: return "The %s does not work in %s" % [name, season]
	var window: Variant = (needs as Dictionary).get("hours")
	if window is Array and (window as Array).size() == 2:
		var a := float(window[0])
		var b := float(window[1])
		var inside := (hours >= a and hours < b) if a <= b else (hours >= a or hours < b)
		if not inside: return "The %s is open %02d:00-%02d:00" % [name, int(a), int(b)]
	var event: Variant = (needs as Dictionary).get("event")
	if event is String and not str(event).is_empty():
		if not active.is_valid() or not bool(active.call(str(event))): return "The %s needs %s" % [name, str(event).replace("_", " ")]
	return ""
