class_name PonySchedule
extends Node
## A pony's day: PonyPonyParadise-format schedule (world/ai/schedules/<id>.json: per weekday and
## time slot, weighted {location_id, activity_hint}) resolved against the zone's painted hot
## spots (MapLayers ids = location ids). When the chosen location is painted she walks there
## (navigator.go_to_spot) and idles around it; otherwise the wander behaviour stands. The
## activity hint feeds the conversation situation block.

const SLOTS := {"morning": Vector2(6.0, 12.0), "afternoon": Vector2(12.0, 18.0), "evening": Vector2(18.0, 22.0), "night": Vector2(22.0, 30.0)}
const DAYS := ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

@export var schedule_path := ""
## Re-evaluate this often (seconds of game time do not exist yet; wall seconds).
@export var review_seconds := 45.0
var data: Dictionary = {}
var layers: MapLayers
var location_id := ""
var activity := ""
var rng := RandomNumberGenerator.new()
var _timer := 0.0
var _slot := ""
var _day := ""


func _ready() -> void:
	rng.randomize()
	if schedule_path != "" and FileAccess.file_exists(schedule_path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(schedule_path))
		if parsed is Dictionary:
			data = parsed
	_timer = rng.randf_range(2.0, 8.0)


func bind_layers(zone_layers: MapLayers) -> void:
	layers = zone_layers


static func slot_for(hours: float) -> String:
	var h := fmod(hours, 24.0)
	if h < 6.0: h += 24.0
	for slot in SLOTS:
		var span: Vector2 = SLOTS[slot]
		if h >= span.x and h < span.y:
			return slot
	return "night"


static func day_name() -> String:
	var tree := Engine.get_main_loop() as SceneTree
	var clock: Node = tree.root.get_node_or_null("TimeOfDay") if tree != null else null
	return DAYS[posmod(int(clock.day),7)] if clock != null else DAYS[0]


## Weighted choice for the slot/day, or the default location outside the schedule.
func choose(hours: float, day := "") -> Dictionary:
	if day == "": day = day_name()
	var slot := slot_for(hours)
	var best: Dictionary = {}
	var best_priority := -INF
	for entry in data.get("schedules", []):
		if (day not in entry.get("days", []) and "any" not in entry.get("days", [])) or (slot not in entry.get("time_slots", []) and "any" not in entry.get("time_slots", [])):
			continue
		var priority := float(entry.get("priority", 0))
		if priority > best_priority:
			best_priority = priority
			best = entry
	if best.is_empty():
		return {"location_id": String(data.get("default_location", "")), "activity_hint": "Resting at home.", "weight": 1}
	if best.has("location_id"): return best
	var choices: Array = best.get("choices",[])
	if choices.is_empty(): return {"location_id":String(data.get("default_location","")),"activity_hint":"Resting at home."}
	var total := 0.0
	for choice in choices: total += maxf(0,float(choice.get("weight", 1)))
	var pick := rng.randf() * total
	for choice in choices:
		pick -= maxf(0,float(choice.get("weight", 1)))
		if pick <= 0.0:
			return choice
	return choices.back()


func _physics_process(delta: float) -> void:
	_timer -= delta
	var tod: Node = get_node_or_null("/root/TimeOfDay")
	var hours := float(tod.hours) if tod != null and "hours" in tod else 12.0
	var slot := slot_for(hours)
	var day := day_name()
	if _timer > 0.0 and slot == _slot and day == _day:
		return
	_timer = review_seconds
	if slot != _slot or day != _day:
		_slot = slot
		_day = day
		var choice := choose(hours, day)
		location_id = String(choice.get("location_id", ""))
		activity = String(choice.get("activity_hint", ""))
	_apply()


## Walk to the chosen spot when the map has it painted; wander otherwise.
func _apply() -> void:
	if get_parent().get_meta("living_world", false): return
	var navigator: Node = get_parent().get_node_or_null("Navigator")
	if navigator == null:
		return
	if "command_owner" in navigator and not navigator.command_owner.is_empty(): return
	if navigator.has_method("map_layers") and navigator.map_layers() != null:
		layers = navigator.map_layers()
	if layers != null and not layers.hot_spot(location_id).is_empty() and navigator.has_method("go_to_spot"):
		navigator.go_to_spot(location_id)
	elif "wander_enabled" in navigator:
		navigator.wander_enabled = true


func situation_line() -> String:
	if activity == "":
		return ""
	var where := location_id.replace("_", " ")
	var painted := layers != null and not layers.hot_spot(location_id).is_empty()
	return "- What you plan to do: %s (%s%s). This is only a plan, so it doesn't mean you got there or did it." % [activity, where, "" if painted else ", though that place is not on the map yet"]
