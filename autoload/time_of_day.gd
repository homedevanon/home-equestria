extends Node
## Day/night clock.
##
## Pure state plus curve evaluation -- this node never touches the Environment.
## SkyController samples it and does the writing, so atmosphere has one writer.
## Sun rides a tilted orbit (never passes through zenith) which keeps look_at
## well-conditioned and gives a temperate-latitude arc instead of an equatorial one.

signal time_changed(hours: float)
signal phase_changed(phase: int)

enum Phase { NIGHT, DAWN, DAY, DUSK }

const ORBIT_TILT_DEG := 32.0
## Actual full-cycle duration, including the slower sunset.
const DEFAULT_DAY_LENGTH_MINUTES := 60.0

var day_length_minutes := DEFAULT_DAY_LENGTH_MINUTES
var _last_clock_usec := 0
## The clock stands still while anything holds it (player report 2026-11-01: time stopped for
## good after loading a save from the in-game menu). Each owner holds and releases its own key, so
## the pause menu, the loading screen and the title can no longer restore each other's stale
## "was paused" copy. `paused` reads true while any hold is on; writing it sets the "manual"
## hold (tools, tests and the capture harness write it directly).
var _holds: Dictionary = {}
var paused: bool:
	get: return not _holds.is_empty()
	set(value):
		if value: hold("manual")
		else: release("manual")

func hold(owner: String) -> void:
	if _holds.has(owner): return
	var was := paused
	_holds[owner] = true
	if not was: _last_clock_usec = _clock_usec()

func release(owner: String) -> void:
	if not _holds.has(owner): return
	_holds.erase(owner)
	if not paused: _last_clock_usec = _clock_usec()

## Who is holding the clock, for logs and tests.
func holders() -> Array:
	return _holds.keys()
## Broad evening slowdown, with smooth entry/exit rather than a clock pause.
var sunset_clock_rate := 0.4
var active_seconds := 0.0
var _fractions := PackedFloat64Array()
var _curve_rate := -1.0
## Days elapsed since launch; drives the moon's phase (dev, 2026-09-07: "moon
## cycles"). Day 0 starts on a full moon.
var day := 0
const MOON_CYCLE_DAYS := 29.5
## World seconds skipped in one go (sleeping sets the clock straight to morning). Real-time "a
## moment ago" windows add it (conversation_director._now, player_bonds.now) so a night's sleep
## reads as a night, not as 30 seconds (dev 2026-10-29). Saved with the clock.
var skipped_seconds := 0.0
var _seen_hours := -1.0

var hours: float = 8.5:
	set(value):
		hours = fposmod(value, 24.0)
		time_changed.emit(hours)
		var p := _compute_phase()
		if p != phase:
			phase = p
			phase_changed.emit(phase)

var phase: int = Phase.DAY


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_last_clock_usec = _clock_usec()
	phase = _compute_phase()
	var settings := get_node_or_null("/root/Settings")
	if settings != null:
		day_length_minutes = float(settings.get_value("world/day_length_minutes"))
		settings.changed.connect(func(key: String):
			if key == "world/day_length_minutes": day_length_minutes = float(settings.get_value(key)))


func _process(_delta: float) -> void:
	# Godot also clamps process delta when the physics catch-up cap is reached.
	# The day still follows elapsed play time; physical movement keeps fixed steps.
	var now := _clock_usec()
	var elapsed := maxf(0.0, (now - _last_clock_usec) * 0.000001)
	_last_clock_usec = now
	# Half a game hour between two frames is a skip: the shortest day (15 minutes) runs an hour in 37 s.
	var total := day * 24.0 + hours
	if _seen_hours >= 0.0 and total - _seen_hours >= 0.5: skipped_seconds += (total - _seen_hours) * 3600.0
	advance(elapsed * Engine.time_scale)
	_seen_hours = day * 24.0 + hours


## skipped_seconds of the clock in the running game, 0 without one (tests, tools).
static func skipped() -> float:
	var loop := Engine.get_main_loop() as SceneTree
	var clock: Node = loop.root.get_node_or_null("TimeOfDay") if loop != null else null
	return float(clock.skipped_seconds) if clock != null else 0.0


func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED or what == NOTIFICATION_UNPAUSED:
		_last_clock_usec = _clock_usec()


func _clock_usec() -> int:
	return Time.get_ticks_usec()


## Invert a normalized elapsed-time curve. A whole cycle is exactly the chosen
## duration, even across midnight, large steps, or changing pace mid-afternoon.
func advance(seconds: float) -> void:
	if paused or not is_finite(seconds) or seconds <= 0.0 or day_length_minutes <= 0.0: return
	_ensure_curve()
	var index := clampi(int(hours * 60), 0, 1439)
	var fraction := lerpf(_fractions[index], _fractions[index+1], hours * 60 - index)
	var total := fraction + seconds / (day_length_minutes * 60.0)
	var elapsed_days := int(floor(total + 1e-12))
	day += elapsed_days
	fraction = maxf(0.0, total - elapsed_days)
	var low := 0; var high := 1440
	while high - low > 1:
		var mid := (low + high) / 2
		if _fractions[mid] <= fraction: low = mid
		else: high = mid
	active_seconds += seconds
	hours = (low + (fraction-_fractions[low]) / (_fractions[high]-_fractions[low])) / 60.0


func _ensure_curve() -> void:
	if _fractions.size() == 1441 and is_equal_approx(_curve_rate, sunset_clock_rate): return
	_curve_rate = sunset_clock_rate
	_fractions.resize(1441); _fractions[0] = 0.0
	for i in range(1, 1441):
		_fractions[i] = _fractions[i-1] + 0.5 / clock_rate((i-1)/60.0) + 0.5 / clock_rate(i/60.0)
	var duration := _fractions[1440]
	for i in 1441: _fractions[i] /= duration


func snapshot() -> Dictionary:
	return {"version":1,"day":day,"hours":hours,"day_length_minutes":day_length_minutes,
		"active_seconds":active_seconds,"sunset_clock_rate":sunset_clock_rate,"skipped_seconds":skipped_seconds}


static func valid_state(value: Variant) -> bool:
	if not value is Dictionary or value.get("version") != 1: return false
	for key in ["day","hours","day_length_minutes","active_seconds","sunset_clock_rate"]:
		if not (value.get(key) is int or value.get(key) is float) or not is_finite(float(value[key])): return false
	return value.day >= 0 and value.day == floor(value.day) and value.hours >= 0 and value.hours < 24 \
		and value.day_length_minutes >= 15 and value.day_length_minutes <= 720 \
		and value.active_seconds >= 0 and value.sunset_clock_rate >= .1 and value.sunset_clock_rate <= 1


func restore_state(value: Dictionary) -> bool:
	if not valid_state(value): return false
	day = int(value.day); hours = float(value.hours)
	# Day length is a player setting (Settings), not part of the world: a save made with
	# another length must not override it.
	var settings := get_node_or_null("/root/Settings")
	day_length_minutes = float(settings.get_value("world/day_length_minutes")) if settings != null else float(value.day_length_minutes)
	active_seconds = float(value.active_seconds)
	sunset_clock_rate = float(value.sunset_clock_rate)
	var skip: Variant = value.get("skipped_seconds", 0.0)
	skipped_seconds = float(skip) if (skip is float or skip is int) and is_finite(float(skip)) and float(skip) >= 0.0 else 0.0
	_seen_hours = -1.0   # loading another day is not a skip
	_last_clock_usec = _clock_usec()
	return true


func clock_rate(hour:float) -> float:
	var evening := smoothstep(15.8,17.0,hour) * (1.0-smoothstep(19.0,20.2,hour))
	return lerpf(1.0,clampf(sunset_clock_rate,.1,1.0),evening)


## Unit vector pointing from the world toward the sun.
func sun_direction() -> Vector3:
	var a := (hours - 6.0) / 24.0 * TAU
	var tilt := deg_to_rad(ORBIT_TILT_DEG)
	return Vector3(cos(a), sin(a) * cos(tilt), sin(a) * sin(tilt)).normalized()


## The moon lags the sun by a growing angle, one full turn per cycle: opposite
## the sun on day 0 (full), alongside it half a cycle later (new).
func moon_phase_angle() -> float:
	return TAU * fposmod((float(day) + hours / 24.0) / MOON_CYCLE_DAYS, 1.0)


## 1 at full moon, 0 at new.
func moon_lit_fraction() -> float:
	return 0.5 + 0.5 * cos(moon_phase_angle())


func moon_direction() -> Vector3:
	var a := (hours - 6.0) / 24.0 * TAU + PI + moon_phase_angle()
	var tilt := deg_to_rad(ORBIT_TILT_DEG)
	return Vector3(cos(a), sin(a) * cos(tilt), sin(a) * sin(tilt)).normalized()


## -1 (nadir) .. 1 (peak). Zero is exactly the horizon.
func sun_elevation() -> float:
	return sun_direction().y


## 0 at night, 1 in full day, smooth through the horizon band. This is the
## master blend factor most atmosphere lerps hang off.
func daylight() -> float:
	return smoothstep(-0.12, 0.22, sun_elevation())


## Broad warm shoulder before the horizon, followed by a gentle dusk release.
## Smooth derivatives avoid the old sharp, triangular flash of orange at sunset.
func golden_amount() -> float:
	var e := sun_elevation()
	return (1.0-smoothstep(0.08,0.42,e))*smoothstep(-0.24,-0.04,e)


func is_night() -> bool:
	return sun_elevation() < -0.05


func set_phase_time(p: int) -> void:
	match p:
		Phase.DAWN: hours = 6.2
		Phase.DAY: hours = 12.0
		Phase.DUSK: hours = 18.6
		Phase.NIGHT: hours = 0.5


func time_string() -> String:
	var h := int(hours)
	var m := int((hours - h) * 60.0)
	return "%02d:%02d" % [h, m]


func _compute_phase() -> int:
	var e := sun_elevation()
	if e < -0.10:
		return Phase.NIGHT
	if e < 0.10:
		return Phase.DAWN if hours < 12.0 else Phase.DUSK
	return Phase.DAY


func _unhandled_input(event: InputEvent) -> void:
	if not preload("res://world/dev_tools.gd").enabled(): return  # [ and ] time skips: developer builds only
	if event.is_action_pressed("debug_time_forward"):
		hours += 1.0
		print("[time] ", time_string())
	elif event.is_action_pressed("debug_time_back"):
		hours -= 1.0
		print("[time] ", time_string())
