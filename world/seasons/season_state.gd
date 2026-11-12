extends Node
## The season state (W1-SEAS-A 2026-11-08; design captures/overhaul-2026-11-08/seasons/
## AUDIT_AND_DESIGN.md 6.1). Child "SeasonState" of the game, group "season_state", added by
## world/game.gd right after Weather. It is the one season formula (with the F1 debug offset), the
## only writer of every season_* global shader uniform (world/seasons/season.gdshaderinc) and the
## owner of the saved season quantities.
##
## Quantities (0..1):
## - palettes (season_leaf, season_ground, season_flowers): one look per season, arriving whole on
##   its first day (dev 2026-10-01: no hour-by-hour drift).
## - leaf_drop, leaf_litter, blossom: stepped once per in-game day across the season.
## - snow_cover: grows while snow falls (blizzard twice as fast), melts slowly in winter sun,
##   steadily outside winter and fast while town_calendar.effect("snow_melt") is live (Winter Wrap
##   Up: true or a rate per game hour); held to 0 outside winter except a rare late-autumn dusting.
##   season_snow stays equal to it for older shaders.
## - snow_fresh: 1 while snowing, fades over a day. wetness: rises in rain, dries in sun and wind.
## - ice: builds in sustained winter cold after the first real snow, thaws at Winter Wrap Up and
##   outside winter.
## Continuous quantities follow in-game time (a sleep skip integrates up to 48 game hours), and
## each uniform is written only when it moves by STEP (or reaches exactly 0 or 1), at most 4 Hz.
##
## Saved in world_context.state.seasons (like town_calendar: context.state + context._changed()):
## {"version", "snow_cover", "snow_fresh", "wetness", "ice", "had_snow", "weather": {...}}. Wave-2
## features keep their own keys in the same block (block() / mark_changed()).
##
## API for feature nodes: season(), season_index(), progress(), day_into_season(), season_days(),
## is_winter(), snow_cover(), snow_fresh(), wetness(), ice(), leaf_drop(), leaf_litter(), blossom(),
## climate(xz, channel), effects_level() (0 off, 1 reduced, 2 full), block(), mark_changed();
## signals day_stepped(day), season_changed(season), effects_changed(level).
## Optional feature nodes in FEATURES are instantiated as children when their script exists, so
## wave-2 packages need no game.gd edit; each gets setup(self) when it has one.
##
## Bench pins (dev builds): --season=<name> holds the season (as an offset, so the calendar and
## the orchard agree), --snow-cover=<0..1> holds the cover.
signal day_stepped(day: int)
## The Running of the Leaves happened (dev 2026-11-09, canon): every deciduous tree is bare at once.
signal leaves_ran()
signal season_changed(season: String)
signal effects_changed(level: int)

const GROUP := "season_state"
const STATE_KEY := "seasons"
const VERSION := 1
const SEASONS := ["spring", "summer", "autumn", "winter"]
const DEFAULT_SEASON_DAYS := 20
const TICK := 0.25
## Smallest change worth a uniform write (exact 0 and 1 are always written).
const STEP := 0.01
const CLIMATE := preload("res://world/seasons/climate_map.gd")
const DEV_TOOLS := preload("res://world/dev_tools.gd")
## Moved from weather.gd (unchanged values).
const SEASON_LOOK := {
	"spring": {"leaf": Color(0.45, 0.85, 0.35), "leaf_amount": 0.25, "ground": Color(0.5, 0.85, 0.35), "ground_amount": 0.2, "snow": 0.0, "flowers": 1.8},
	"summer": {"leaf": Color(0.3, 0.6, 0.2), "leaf_amount": 0.0, "ground": Color(0.55, 0.75, 0.3), "ground_amount": 0.0, "snow": 0.0, "flowers": 1.0},
	"autumn": {"leaf": Color(1.0, 0.42, 0.08), "leaf_amount": 0.9, "ground": Color(0.82, 0.66, 0.28), "ground_amount": 0.6, "snow": 0.0, "flowers": 0.25},
	"winter": {"leaf": Color(0.55, 0.5, 0.42), "leaf_amount": 0.55, "ground": Color(0.7, 0.7, 0.62), "ground_amount": 0.5, "snow": 0.0, "flowers": 0.0},
}
## Rates per in-game hour (one hour is 2.5 real minutes at the default 60-minute day).
const SNOW_GROWTH := 0.25          # x snowfall intensity; a blizzard doubles it
const WINTER_SUN_MELT := 0.015     # clear winter midday
const WARM_MELT := 0.06            # outside winter, plus up to 0.1 more in sun
const CAP_MELT := 0.12             # cover above the season's cap (spring thaw, summer)
const RAIN_MELT := 0.1
const SNOW_MELT_EVENT := 0.25      # town_calendar effect "snow_melt": true
const WET_RISE := 0.6
const ICE_RISE := 0.05
const ICE_THAW := 0.1
const LATE_AUTUMN := 0.75          # progress after which a light dusting may lie
const LATE_AUTUMN_CAP := 0.3
const MAX_CATCH_UP_HOURS := 48.0
## Optional wave-2 feature scripts, instantiated when present.
const FEATURES := [
	"res://world/seasons/snow_trail.gd",
	"res://world/seasons/snow_materials.gd",
	"res://world/seasons/season_particles.gd",
	"res://world/seasons/leaf_piles.gd",
	"res://world/seasons/leaf_carpet.gd",
	"res://world/seasons/snow_play/snow_play.gd",
	"res://world/seasons/ice_slabs.gd",
	# Event decor by calendar day (W2-SEAS-I H1): Hearth's Warming arch, square tree, lanterns.
	"res://world/events/seasonal_decor.gd",
]
const EFFECT_LEVELS := {"off": 0, "reduced": 1, "full": 2}

var game: Node
var context: Node
var auto_tick := true
## Test hooks: a fixed clock {"day", "hours"}, a season length, a weather node.
var clock_override: Dictionary = {}
var season_days_override := 0
var weather_override: Node
## The F1 debug season steps (session only, never saved).
var offset := 0
## Number of uniform writes so far (tests).
var uniform_writes := 0

var _season := ""
var _index := -1
var _day := -2147483648
var _into := 0
var _look: Dictionary = {}
var _cover := 0.0
var _fresh := 0.0
var _wet := 0.0
var _ice := 0.0
var _drop := 0.0
var _litter := 0.0
## Autumn colour 0..1 (season_leaf_turn). Crowns stay full all autumn and only change colour
## (dev 2026-11-09): green on the first day, each tree's own colour by the middle, fully brown on
## the day before the fall. The Running of the Leaves is the last day of autumn, the day before
## winter: when that day begins every leaf is down (dev 2026-11-10: "as it approaches winter it
## should turn fully brown and then fall the day before winter"). Before that date it ran on any
## night Anon slept in the last quarter of autumn. Winter is bare; spring grows them back.
## _ran_count = the season count of the autumn whose Running has happened (-1 = not yet), saved as
## seasons.leaves_ran.
const WRAP_UP_END := 0.2
var _turn := 0.0
## Spring's day ramp for the shaders (season_spring): 0 outside spring, else 0.001 on the first day
## .. 1 on the last. Spring is a calendar the player watches (dev 2026-11-10: "blossoming over
## time, leaves growing each day slowly ... over the course of a week or so"). With the default
## 20-day season:
## - days 1 to 4: Winter Wrap Up, bare trees, the first blossom buds open on the last of them;
## - days 4 to 8: the flowering trees come into full bloom, each a day or two apart;
## - days 5 to 13: the other trees leaf out, twigs first, a little more each day;
## - days 11 to 16: the petals fall, and the flowering trees leaf out as they do;
## - meadow flowers come up from day 3 and are at their most from day 10 to the end.
## The curves themselves are in world/foliage/vegetation_color.gdshaderinc (vegetation_spring_tree)
## and world/foliage/grass/ground_flowers.gdshader; blossom_curve / petal_fall here are the same
## curves for the script side (petal particles, petal carpet).
var _spring := 0.0
var _ran_count := -1
var _blossom := 0.0
var _had_snow := false
var _last_at := -1.0
var _pin_season := ""
var _pin_cover := -1.0
var _written: Dictionary = {}
var _climate_set := false
var _probe := [-1.0, -1.0, Color(-1, -1, -1)]   # snow, ground amount, ground colour the grass last rendered
var _pending_weather: Dictionary = {}
var _saved_signature: Array = []
var _weather_save_timer := 0.0
var _effects := 2
var _timer: Timer

func _init() -> void:
	add_to_group(GROUP)

func _ready() -> void:
	_read_pins()
	_refresh_effects(false)
	if not auto_tick: return
	_timer = Timer.new(); _timer.name = "SeasonTick"; _timer.wait_time = TICK; _timer.autostart = true
	_timer.timeout.connect(tick)
	add_child(_timer)

## Game hookup: the saved state, the weather it restores, settings and the optional features.
func setup(host: Node) -> void:
	game = host
	var ctx: Variant = host.get("world_context") if host != null else null
	context = ctx as Node if ctx is Node and is_instance_valid(ctx) else null
	if context != null and context.has_signal("reopened") and not context.is_connected("reopened", _on_reopened):
		context.connect("reopened", _on_reopened)
	var settings: Node = get_node_or_null("/root/Settings")
	if settings != null and settings.has_signal("changed") and not settings.is_connected("changed", _on_setting_changed):
		settings.connect("changed", _on_setting_changed)
	_read_pins()
	_restore()
	_add_features()
	tick()

# ------------------------------------------------------------------ the one season formula

## D-02 (dev 2026-11-08): changing the season length mid-save never makes the season jump. The world
## keeps an anchor: on anchor_day it was anchor_count seasons in, anchor_into days into the season.
## Seasons are counted from there with the current length. The defaults (0, 0, 0) give the old
## formula, floor(day / length), so old saves and fresh worlds read exactly as before; the live
## season_state sets them from the save and resets them when the world closes.
static var anchor_day := 0
static var anchor_count := 0
static var anchor_into := 0

static func index_for(day: int, length: int, steps := 0) -> int:
	return posmod(count_for(day, length, steps), 4)

## Seasons since day 0 (not wrapped): the orchard's crop cycle.
static func count_for(day: int, length: int, steps := 0) -> int:
	var days := maxi(1, length)
	return anchor_count + floori(float(anchor_into + day - anchor_day + steps * days) / float(days))

static func into_for(day: int, length: int, steps := 0) -> int:
	var days := maxi(1, length)
	return posmod(anchor_into + day - anchor_day + steps * days, days)

static func reset_anchor() -> void:
	anchor_day = 0; anchor_count = 0; anchor_into = 0

## The season length the anchor was made with (0 = not known yet: set at the first tick).
var _anchor_length := 0

## Keeps the current season and the share of it already gone when the length setting changes.
func _check_length(day: int, length: int) -> void:
	if _anchor_length <= 0: _anchor_length = length; return
	if length == _anchor_length: return
	var count := count_for(day, _anchor_length, 0)
	var into := into_for(day, _anchor_length, 0)
	anchor_day = day; anchor_count = count
	anchor_into = clampi(floori(float(into) / float(_anchor_length) * float(length)), 0, length - 1)
	print("[season] length %d -> %d days: still %s, day %d of %d" % [_anchor_length, length, SEASONS[posmod(count, 4)], anchor_into + 1, length])
	_anchor_length = length
	var saved := block()
	if not saved.is_empty():
		saved["anchor"] = {"day": anchor_day, "count": anchor_count, "into": anchor_into, "length": _anchor_length}
		mark_changed()

## "early "/"late " by thirds of the season, whatever its length (M-SEA-03).
static func part_of(into: int, length: int) -> String:
	if into * 3 < maxi(1, length): return "early "
	if into * 3 >= 2 * maxi(1, length): return "late "
	return ""

## The live season_state's offset (0 without one), for static callers (harvest_state.gd).
static func current_offset() -> int:
	var tree := Engine.get_main_loop() as SceneTree
	var node: Node = tree.get_first_node_in_group(GROUP) if tree != null else null
	return int(node.get("offset")) if node != null else 0

static func current_season_days() -> int:
	var tree := Engine.get_main_loop() as SceneTree
	var settings: Node = tree.root.get_node_or_null("Settings") if tree != null and tree.root != null else null
	return maxi(1, int(settings.call("season_days"))) if settings != null and settings.has_method("season_days") else DEFAULT_SEASON_DAYS

func season_days() -> int:
	return season_days_override if season_days_override > 0 else current_season_days()

func _clock() -> Dictionary:
	var day := 0; var hours := 12.0
	if not clock_override.is_empty():
		day = int(clock_override.get("day", 0)); hours = float(clock_override.get("hours", 0.0))
	else:
		var clock: Node = get_node_or_null("/root/TimeOfDay")
		if clock != null: day = int(clock.get("day")); hours = float(clock.get("hours"))
	return {"day": day, "hours": hours, "at": float(day) * 24.0 + hours}

func today() -> int:
	return int(_clock().day)

func season_index(day := -1) -> int:
	return index_for(day if day >= 0 else today(), season_days(), offset)

func season(day := -1) -> String:
	return SEASONS[season_index(day)]

func day_into_season(day := -1) -> int:
	return into_for(day if day >= 0 else today(), season_days(), offset)

## Fraction of the season gone, stepped by whole days (0 on its first day).
func progress() -> float:
	return float(day_into_season()) / float(season_days())

func describe_season() -> String:
	return part_of(day_into_season(), season_days()) + season()

func is_winter() -> bool: return season() == "winter"
func snow_cover() -> float: return _cover
func snow_fresh() -> float: return _fresh
func wetness() -> float: return _wet
func ice() -> float: return _ice
func leaf_drop() -> float: return _drop
func leaf_turn() -> float: return _turn
func leaf_litter() -> float: return _litter
func blossom() -> float: return _blossom
## Spring's day ramp (0 outside spring).
func spring() -> float: return _spring
## How much of a flowering tree's crown is in flower on spring day ramp p, for a tree that is
## `late` (0..1, world/seasons/leaf_carpet.gd autumn_tree().x). The shader's curve.
static func blossom_curve(p: float, late := 0.5) -> float:
	var off := late * 0.1
	return smoothstep(0.13 + off, 0.30 + off, p) * (1.0 - smoothstep(0.68 + off, 0.86 + off * 0.6, p))
## How hard the petals come down on spring day ramp p (0..1): a few while in full flower, most
## while the blossom goes over.
static func petal_fall_curve(p: float) -> float:
	var falling := smoothstep(0.64, 0.74, p) * (1.0 - smoothstep(0.9, 0.97, p))
	return maxf(falling, 0.25 * blossom_curve(p))
func petal_fall() -> float: return petal_fall_curve(_spring) if _spring > 0.0 else 0.0
## Fallen petals lying under the flowering trees (0..1): a few from full bloom, most as the
## blossom goes over; they lie until summer.
static func petal_litter_curve(p: float) -> float:
	return smoothstep(0.28, 0.85, p)
func petal_litter() -> float: return petal_litter_curve(_spring) if _spring > 0.0 else 0.0
func look() -> Dictionary: return _look
func climate(xz: Vector2, channel: int) -> float: return CLIMATE.sample(xz, channel)
func effects_level() -> int: return _effects

## F1: the next season now. Stepping into winter lays a preview snow (debug only).
func step_season(steps := 1) -> void:
	offset += steps
	if season() == "winter" and _pin_cover < 0.0:
		_cover = maxf(_cover, 0.7); _fresh = 1.0; _had_snow = true; _ice = maxf(_ice, 0.6)
	tick()
	_refresh_grass(true)

# ------------------------------------------------------------------ the tick

func tick() -> void:
	if not _pin_season.is_empty(): _hold_pinned_season()
	var clock := _clock()
	var length := season_days()
	var day: int = clock.day
	_check_length(day, length)
	var index := index_for(day, length, offset)
	var now_season: String = SEASONS[index]
	var into := into_for(day, length, offset)
	var season_moved := now_season != _season
	var day_moved := day != _day or into != _into or season_moved
	if season_moved and _season == "winter": _had_snow = false
	_season = now_season; _index = index; _day = day; _into = into
	if day_moved:
		var ramp := float(into) / float(maxi(1, length - 1))
		var daily := daily_quantities(now_season, ramp)
		_drop = daily[0]; _litter = daily[1]; _blossom = daily[2]
		# 1.0 on the last day that still has leaves (the day before the Running).
		_turn = clampf(float(into) / float(maxi(1, length - 2)), 0.0, 1.0) if now_season == "autumn" else 0.0
		_spring = maxf(ramp, 0.001) if now_season == "spring" else 0.0
		if now_season == "autumn" and _ran_count == count_for(day, length, offset): _leaves_down()
	if now_season == "autumn" and _ran_count != count_for(day, length, offset) and into >= length - 1:
		_ran_count = count_for(day, length, offset)
		_leaves_down()
		var saved := block()
		if not saved.is_empty(): saved["leaves_ran"] = _ran_count; mark_changed()
		print("[season] the Running of the Leaves: every tree is bare")
		leaves_ran.emit()
	var at: float = clock.at
	var hours := 0.0 if _last_at < 0.0 else clampf(at - _last_at, 0.0, MAX_CATCH_UP_HOURS)
	_last_at = at
	if hours > 0.0: _integrate(hours, now_season, float(into) / float(length), float(clock.hours))
	if _pin_cover >= 0.0: _cover = _pin_cover
	if season_moved or _look.is_empty(): _look = (SEASON_LOOK[now_season] as Dictionary).duplicate()
	_look.snow = _cover
	_write_uniforms()
	_refresh_grass(season_moved)
	_save(day_moved)
	if season_moved:
		print("[season] ", now_season)
		season_changed.emit(now_season)
	if day_moved: day_stepped.emit(day)

## [leaf_drop, leaf_litter, blossom] for a season and its day ramp (0 first day .. 1 last day).
## Autumn keeps every leaf until the Running of the Leaves (_leaves_down), while the ground under
## the trees fills with fallen ones (dev 2026-11-10: "why are there no leaves on the floor");
## winter is bare; spring regrows over its first third.
static func daily_quantities(which: String, ramp: float) -> Array:
	var p := clampf(ramp, 0.0, 1.0)
	match which:
		"autumn":
			return [0.0, 0.15 + 0.5 * p, 0.0]
		"winter":
			return [1.0, 0.9 * (1.0 - smoothstep(0.0, 0.3, p)), 0.0]
		"spring":
			# The crowns stand bare until Winter Wrap Up ends (its window is spring 0..0.2). From then
			# the leaves grow back a little each day (season_spring; every card grows, none is
			# switched on card by card: dev 2026-11-09, "reads as tile grids").
			# Blossom: the middle tree's curve (was a bell round 0.35).
			return [1.0 if p < WRAP_UP_END else 0.0, 0.0, blossom_curve(p)]
	return [0.0, 0.0, 0.0]

func _leaves_down() -> void:
	_drop = 1.0; _litter = 0.95; _turn = 1.0

func leaves_have_run() -> bool:
	return _season == "winter" or (_season == "autumn" and _ran_count == count_for(_day, season_days(), offset))

## Most snow the season lets lie (melts down to it at CAP_MELT).
static func cover_cap(which: String, progress_now: float) -> float:
	if which == "winter": return 1.0
	if which == "autumn" and progress_now >= LATE_AUTUMN: return LATE_AUTUMN_CAP
	return 0.0

func _weather() -> Node:
	if weather_override != null and is_instance_valid(weather_override): return weather_override
	return get_tree().get_first_node_in_group("weather") if is_inside_tree() else null

func _calendar() -> Node:
	return get_tree().get_first_node_in_group("town_calendar") if is_inside_tree() else null

## Extra melt per game hour from a live town event (Winter Wrap Up).
func _event_melt() -> float:
	var cal := _calendar()
	if cal == null or not cal.has_method("effect"): return 0.0
	var value: Variant = cal.call("effect", "snow_melt", 0.0)
	if value is bool: return SNOW_MELT_EVENT if value else 0.0
	return maxf(0.0, float(value)) if value is float or value is int else 0.0

## Winter Wrap Up's days outside its hours (the first spring dawn): the snow waits for the ponies.
func _event_waiting() -> bool:
	var cal := _calendar()
	if cal == null or not cal.has_method("today_events"): return false
	for event: Variant in cal.call("today_events"):
		if event is Dictionary and (event as Dictionary).get("effects") is Dictionary and ((event as Dictionary).effects as Dictionary).has("snow_melt"): return true
	return false

func _integrate(total_hours: float, which: String, progress_now: float, hour_of_day: float) -> void:
	var weather := _weather()
	var params: Dictionary = weather.get("params") if weather != null and weather.get("params") is Dictionary else {}
	var kind := str(weather.get("kind")) if weather != null else "clear"
	var snowing := float(params.get("snow", 0.0))
	var rain := maxf(float(params.get("rain", 0.0)), float(params.get("hail", 0.0)) * 0.5)
	var sun := float(params.get("sun", 1.0))
	var gust := float(params.get("gust", 0.0))
	var event_melt := _event_melt()
	# Winter Wrap Up's days hold the winter rules until the event is live (W2-SEAS-I H2): without
	# this the first spring dawn melted a full cover by about 05:30, before the ponies start at 07:00.
	var held := which == "spring" and event_melt <= 0.0 and _event_waiting()
	var cap := 1.0 if held else cover_cap(which, progress_now)
	var remaining := total_hours
	while remaining > 0.0:
		var dt := minf(remaining, 1.0)
		remaining -= dt
		var hour := fposmod(hour_of_day - remaining, 24.0)   # catch-ups reach back up to 48 h
		var midday := smoothstep(9.0, 11.0, hour) * (1.0 - smoothstep(15.0, 17.0, hour))
		var before := _cover
		if snowing > 0.05 and _cover < cap:
			_cover = minf(cap, _cover + SNOW_GROWTH * snowing * (2.0 if kind == "blizzard" else 1.0) * dt)
		var melt := event_melt + RAIN_MELT * rain
		if _cover > cap: melt += CAP_MELT
		if snowing <= 0.05:
			melt += (WINTER_SUN_MELT * sun * midday) if (which == "winter" or held) else (WARM_MELT + 0.1 * sun * midday)
		_cover = maxf(0.0, _cover - melt * dt)
		var melted := maxf(0.0, before - _cover)
		_fresh = 1.0 if snowing > 0.2 else maxf(0.0, _fresh - dt / 24.0)
		if rain > 0.05: _wet = minf(1.0, _wet + WET_RISE * rain * dt)
		else:
			var dry := (0.05 + 0.1 * sun * midday + 0.08 * gust) * (0.5 if which == "winter" else 1.0)
			_wet = maxf(0.0, _wet - dry * dt)
		_wet = minf(1.0, _wet + melted * 1.5)
		if which == "winter" and _cover > 0.25: _had_snow = true
		if which == "winter" and _had_snow and event_melt <= 0.0 and progress_now < 0.9:
			_ice = minf(1.0, _ice + ICE_RISE * (0.5 + 0.5 * (1.0 - midday)) * dt)
		else:
			var thaw := ICE_THAW if (which != "winter" and not held) else (0.03 if progress_now >= 0.9 else 0.0)
			_ice = maxf(0.0, _ice - (thaw + event_melt) * dt)

# ------------------------------------------------------------------ uniforms

func _put(param: String, value: Variant) -> void:
	var last: Variant = _written.get(param)
	if value is float:
		var v: float = value
		if last is float:
			var l: float = last
			if absf(v - l) < STEP and not ((v == 0.0 or v == 1.0) and v != l): return
	elif last != null and last == value: return
	_written[param] = value
	uniform_writes += 1
	RenderingServer.global_shader_parameter_set(param, value)

## How far the ground's green has gone over to the season's ground colour. Autumn grass dries
## with the leaves (dev 2026-11-10, autumn step 2 "ground"): at a fixed 0.6 two fifths of summer's
## green stayed all season, and every patch of shade read as green grass under orange trees.
## LOOK_AUTUMN_DRY = Vector2(0.6, 0.6) is the old fixed amount.
const LOOK_AUTUMN_DRY := Vector2(0.5, 0.95)   # first day of autumn .. last day with leaves
func _ground_amount() -> float:
	if _season == "autumn" and _look.has("ground_amount"): return lerpf(LOOK_AUTUMN_DRY.x, LOOK_AUTUMN_DRY.y, _turn)
	return float(_look.get("ground_amount", 0.0))

## Meadow flowers (season_flowers): spring's come up over its first half instead of standing at
## full count from the first day (still under snow then).
func _flowers() -> float:
	var full := float(_look.get("flowers", 1.0))
	if _season != "spring" or _spring <= 0.0: return full
	return lerpf(0.3, full, smoothstep(0.1, 0.45, _spring))

func _write_uniforms() -> void:
	var leaf: Color = _look.leaf; var ground: Color = _look.ground
	_put("season_leaf", Vector4(leaf.r, leaf.g, leaf.b, float(_look.leaf_amount)))
	_put("season_ground", Vector4(ground.r, ground.g, ground.b, _ground_amount()))
	_put("season_flowers", _flowers())
	_put("season_snow", _cover)
	_put("season_snow_cover", _cover)
	_put("season_snow_fresh", _fresh)
	_put("season_leaf_drop", _drop)
	_put("season_leaf_turn", _turn)
	_put("season_leaf_litter", _litter)
	_put("season_blossom", _blossom)
	_put("season_spring", _spring)
	_put("season_wetness", _wet)
	_put("season_ice", _ice)
	if not _climate_set:
		_climate_set = true
		var texture := CLIMATE.texture()
		if texture != null: RenderingServer.global_shader_parameter_set("season_climate_map", texture)
		_put("season_climate_rect", CLIMATE.shader_rect())

## Grass takes its colour from a render of the ground: re-render it for a new look and when the
## snow moves by more than 0.08 (moved from weather.gd).
func _refresh_grass(force: bool) -> void:
	var ground: Color = _look.get("ground", Color.BLACK)
	var amount := _ground_amount()
	var probe_ground: Color = _probe[2]
	var tint := maxf(absf(ground.r - probe_ground.r), maxf(absf(ground.g - probe_ground.g), absf(ground.b - probe_ground.b)))
	if not force and absf(_cover - float(_probe[0])) <= 0.08 and absf(amount - float(_probe[1])) <= 0.08 and tint <= 0.08: return
	_probe = [_cover, amount, ground]
	if not is_inside_tree(): return
	var grass_nodes: Array = []
	var own: Node = WorldTerrain.instance.get_node_or_null("GroundGrass") if is_instance_valid(WorldTerrain.instance) else null
	if own != null: grass_nodes = [own]
	else: grass_nodes = get_tree().root.find_children("GroundGrass", "", true, false)
	for grass: Node in grass_nodes:
		if grass.has_method("refresh_colour"): grass.refresh_colour()

# ------------------------------------------------------------------ saves

func _writable() -> bool:
	return is_instance_valid(context) and not bool(context.get("_read_only")) and context.get("state") is Dictionary

## The saved seasons block, created when missing (callers check _writable() first via block()).
func block() -> Dictionary:
	if not _writable(): return {}
	var state: Dictionary = context.get("state")
	if not state.get(STATE_KEY) is Dictionary: state[STATE_KEY] = {"version": VERSION}
	return state[STATE_KEY]

func mark_changed() -> void:
	if _writable(): context.call("_changed")

func _save(force: bool) -> void:
	var saved := block()
	if saved.is_empty(): return
	# String keys (dotted writes would store StringName keys in the saved world state).
	saved["version"] = VERSION
	saved["snow_cover"] = snappedf(_cover, 0.001); saved["snow_fresh"] = snappedf(_fresh, 0.001)
	saved["wetness"] = snappedf(_wet, 0.001); saved["ice"] = snappedf(_ice, 0.001); saved["had_snow"] = _had_snow
	var weather := _weather()
	_weather_save_timer -= TICK
	var kind := str(weather.get("kind")) if weather != null else ""
	var saved_weather: Dictionary = saved.get("weather") if saved.get("weather") is Dictionary else {}
	if weather != null and weather.has_method("save_state") and (force or _weather_save_timer <= 0.0 or str(saved_weather.get("kind", "")) != kind):
		_weather_save_timer = 2.0
		saved["weather"] = weather.call("save_state")
	var signature := [snappedf(_cover, 0.05), snappedf(_wet, 0.05), snappedf(_ice, 0.05), snappedf(_fresh, 0.25), kind, _day]
	if force or signature != _saved_signature:
		_saved_signature = signature
		mark_changed()

func _restore() -> void:
	_last_at = -1.0
	reset_anchor(); _anchor_length = 0; _ran_count = -1
	if not _writable(): return
	var saved: Variant = (context.get("state") as Dictionary).get(STATE_KEY)
	if saved is Dictionary and (saved as Dictionary).get("anchor") is Dictionary:
		var anchor: Dictionary = (saved as Dictionary).get("anchor")
		anchor_day = int(anchor.get("day", 0)); anchor_count = int(anchor.get("count", 0))
		_anchor_length = maxi(0, int(anchor.get("length", 0)))
		anchor_into = clampi(int(anchor.get("into", 0)), 0, maxi(0, _anchor_length - 1))
	if saved is Dictionary and (saved as Dictionary).get("leaves_ran") is int or (saved is Dictionary and (saved as Dictionary).get("leaves_ran") is float):
		_ran_count = int((saved as Dictionary).get("leaves_ran"))
	if saved is Dictionary:
		var data: Dictionary = saved
		_cover = _unit(data.get("snow_cover"), 0.0); _fresh = _unit(data.get("snow_fresh"), 0.0)
		_wet = _unit(data.get("wetness"), 0.0); _ice = _unit(data.get("ice"), 0.0)
		_had_snow = bool(data.get("had_snow", false)) if data.get("had_snow") is bool else false
		_pending_weather = data.get("weather") if data.get("weather") is Dictionary else {}
	else:
		# A save from before the seasons block: a winter world keeps the snow it showed then. A
		# reopened slot must not inherit the last slot's snow, ice or wet ground.
		_pending_weather = {}
		_cover = 0.0; _fresh = 0.0; _wet = 0.0; _ice = 0.0; _had_snow = false
		if season() == "winter":
			_cover = 0.6; _had_snow = true; _ice = 0.5 if progress() > 0.2 else 0.0
	_apply_weather()

static func _unit(value: Variant, fallback: float) -> float:
	if not (value is float or value is int): return fallback
	var v := float(value)
	return clampf(v, 0.0, 1.0) if is_finite(v) else fallback

func _apply_weather() -> void:
	if _pending_weather.is_empty(): return
	var weather := _weather()
	if weather == null or not weather.has_method("restore_state"): return
	weather.call("restore_state", _pending_weather)
	_pending_weather = {}

## A save slot was loaded (world_context.restore_checkpoint reopens the world). game_saves restores
## the clock after the context in the same call, so the clock is re-based at the end of the frame:
## the jump to the slot's time must not melt or pile snow.
func _on_reopened(_world_id: String) -> void:
	_restore()
	_saved_signature = []
	_after_reopen.call_deferred()

func _after_reopen() -> void:
	_last_at = -1.0
	tick()

# ------------------------------------------------------------------ pins, settings, features

func _read_pins() -> void:
	var args := DEV_TOOLS.user_args()
	var wanted := _arg(args, "--season")
	_pin_season = wanted if wanted in SEASONS else ""
	var cover := _arg(args, "--snow-cover")
	_pin_cover = clampf(float(cover), 0.0, 1.0) if cover.is_valid_float() else -1.0
	if not _pin_season.is_empty() or _pin_cover >= 0.0:
		print("[season] pinned season=%s snow_cover=%s" % [_pin_season if _pin_season != "" else "-", str(_pin_cover) if _pin_cover >= 0.0 else "-"])

## "--name=value" or "--name value".
static func _arg(args: PackedStringArray, flag: String) -> String:
	for i in args.size():
		if args[i].begins_with(flag + "="): return args[i].trim_prefix(flag + "=")
		if args[i] == flag and i + 1 < args.size(): return args[i + 1]
	return ""

## Test hook: pin as if from the command line ("" / -1 clear the pin).
func pin(season_name: String, cover := -1.0) -> void:
	_pin_season = season_name if season_name in SEASONS else ""
	_pin_cover = clampf(cover, 0.0, 1.0) if cover >= 0.0 else -1.0

func _hold_pinned_season() -> void:
	var natural := index_for(today(), season_days(), 0)
	offset = posmod(SEASONS.find(_pin_season) - natural, 4)

func _on_setting_changed(key: String) -> void:
	if key == "video/seasonal_effects": _refresh_effects(true)

func _refresh_effects(announce: bool) -> void:
	var settings: Node = get_node_or_null("/root/Settings")
	var value := str(settings.call("get_value", "video/seasonal_effects")) if settings != null and settings.has_method("get_value") else "full"
	var level := int(EFFECT_LEVELS.get(value, 2))
	if level == _effects and announce: return
	_effects = level
	if announce: effects_changed.emit(level)

func _add_features() -> void:
	for path: String in FEATURES:
		if not ResourceLoader.exists(path): continue
		var script: Variant = load(path)
		if not script is Script or not (script as Script).can_instantiate(): continue
		var made: Variant = (script as Script).new()
		if not made is Node:
			push_warning("season_state: %s is not a Node script" % path); continue
		var node: Node = made
		node.name = path.get_file().get_basename().to_pascal_case()
		add_child(node)
		if node.has_method("setup"): node.call("setup", self)


## The world closed: the next world (or the title screen's new-game season) starts from the plain formula.
func _exit_tree() -> void:
	reset_anchor()
