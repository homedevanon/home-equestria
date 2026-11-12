extends Node
## Choosing when to wake (player_sleep.gd). After the sleep hold the eyes grow heavy and Anon
## thinks when he will get up; the time moves in half hours.
##   Desktop: scroll wheel or the move forward/back keys (W/S, arrows) change it, tap Jump (Space)
##   sleeps, "Get up / stay awake" (Q) stays awake; all follow Settings → Controls.
##   VR: either stick up/down changes it, tap A sleeps, B stays awake.
## At night, holding Space/A instead fills a moon and drifts into Luna's dream (luna_dream.gd);
## letting go before it fills is an ordinary sleep.
## Defaults: at night the wake hour last chosen at night (kept in the save, first 07:00); by day
## a two-hour nap.
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const STEP_HOURS := 0.5
const NAP_HOURS := 2.0
const MIN_HOURS := 0.5
const MAX_HOURS := 24.0
## Holding Space/A this long chooses Luna; the moon starts filling after LUNA_SHOW.
const LUNA_HOLD := 1.0
const LUNA_SHOW := 0.15
const STICK_ON := 0.6
const STICK_FIRST_REPEAT := 0.4
const STICK_REPEAT := 0.15
const NIGHT_WAKE := 7.0

var game: Node
var _cover: Node
var _start := 0.0          # absolute hours (day * 24 + hours) when the picker opened
var _wake := 0.0           # absolute hours of the chosen wake time
var _night := false
var _armed := false        # the hold that opened the picker has been released
var _held := 0.0
var _steps := 0            # wheel / key steps since the last frame
var _stick_wait := 0.0
var _stick_dir := 0
var _done := false
var _result := {}

## Shows the picker on `cover` and waits. Returns {} when he stays awake, else
## {"target": [day, hours], "luna": bool, "night": bool}.
func pick(host: Node, cover: Node) -> Dictionary:
	game = host; _cover = cover
	var clock := get_node_or_null("/root/TimeOfDay")
	_start = float(clock.day) * 24.0 + float(clock.hours)
	_night = bool(clock.is_night())
	_wake = _default_wake(float(clock.hours))
	_done = false; _result = {}; _armed = false; _held = 0.0; _steps = 0
	cover.drowse()
	_refresh()
	while not _done:
		if not await SHUTDOWN.frame(self) or not is_instance_valid(_cover): return {}
		_tick(get_process_delta_time())
	if _result.is_empty():
		# Staying awake: the cancel button must be let go before the bed takes it as "get up".
		while _cancel_pressed():
			if not await SHUTDOWN.frame(self): return {}
	elif _night:
		_remember(fposmod(snappedf(_wake, STEP_HOURS), 24.0))
	return _result

func _default_wake(now: float) -> float:
	if _night:
		var hour := _remembered()
		var ahead := fposmod(hour - now, 24.0)
		return _start + clampf(ahead, MIN_HOURS, MAX_HOURS)
	var wake := snappedf(_start + NAP_HOURS, STEP_HOURS)
	return wake if wake - _start >= MIN_HOURS else wake + STEP_HOURS

## The night wake hour lives in the world state, so it saves with the game (like luna_dream.gd).
func _remembered() -> float:
	var context: Node = game.get("world_context")
	var value: Variant = context.state.get("wake_hour") if context != null else null
	return clampf(float(value), 0.0, 23.5) if value is float or value is int else NIGHT_WAKE

func _remember(hour: float) -> void:
	var context: Node = game.get("world_context")
	if context == null: return
	context.state["wake_hour"] = hour
	if context.has_method("_changed"): context._changed()

func _tick(delta: float) -> void:
	var steps := _steps + _stick_steps(delta)
	_steps = 0
	if steps != 0: _move(steps)
	if _cancel_pressed():
		_done = true
		return
	var pressed := _confirm_pressed()
	if not pressed:
		if _armed and _held > 0.0:
			_finish(false)
			return
		_armed = true; _held = 0.0
	elif _armed:
		_held += delta
		if not _night:
			_finish(false)
			return
		if _held >= LUNA_HOLD:
			_finish(true)
			return
	_refresh()

func _move(steps: int) -> void:
	var wake := snappedf(_wake + steps * STEP_HOURS, STEP_HOURS)
	while wake - _start < MIN_HOURS: wake += STEP_HOURS
	while wake - _start > MAX_HOURS: wake -= STEP_HOURS
	_wake = wake

func _finish(luna: bool) -> void:
	_done = true
	_result = {"target": [floori(_wake / 24.0), fposmod(_wake, 24.0)], "luna": luna, "night": _night}

func _refresh() -> void:
	var moon := -1.0
	if _night: moon = clampf((_held - LUNA_SHOW) / (LUNA_HOLD - LUNA_SHOW), 0.0, 1.0) if _armed else 0.0
	_cover.show_picker("I'll get up at %s." % spoken_time(fposmod(_wake, 24.0)), _hint(), moon)

func _hint() -> String:
	var hours := snappedf(_wake - _start, 0.5)
	var length := "%d" % roundi(hours) if is_equal_approx(hours, roundf(hours)) else "%.1f" % hours
	var slept := "%s hour%s of sleep" % [length, "" if length == "1" else "s"]
	var vr := bool(game.get("xr_active"))
	var sleep_key := "A" if vr else Settings.key_label("move_jump", "Space")
	var keys := PackedStringArray(["Tap %s · Sleep" % sleep_key if _night else "%s · Sleep" % sleep_key])
	if _night: keys.append("Hold %s · Visit Luna" % sleep_key)
	keys.append("Stick · Change time" if vr else "Scroll or %s/%s · Change time" % [Settings.key_label("move_forward", "W"), Settings.key_label("move_back", "S")])
	keys.append("B · Stay awake" if vr else "%s · Stay awake" % Settings.key_label("stand_up", "Q"))
	return slept + "\n" + "    ".join(keys)

## "7:00 in the morning", "2:30 in the afternoon", "12:00 midnight".
static func spoken_time(hours: float) -> String:
	var minutes := roundi(hours * 60.0) % (24 * 60)
	var h := floori(minutes / 60.0)
	var m := minutes % 60
	var clock := "%d:%02d" % [12 if h % 12 == 0 else h % 12, m]
	if h == 0 and m == 0: return clock + " midnight"
	if h == 12 and m == 0: return clock + " noon"
	if h < 5 or h >= 21: return clock + " at night"
	if h < 12: return clock + " in the morning"
	if h < 17: return clock + " in the afternoon"
	return clock + " in the evening"

# ------------------------------------------------------------------ input
func _input(event: InputEvent) -> void:
	if event is InputEventKey and preload("res://world/ui/typing_guard.gd").active(): return  # typing never drives the game
	if _done or game == null or _cover == null: return
	if event is InputEventMouseButton and event.pressed:
		var button := (event as InputEventMouseButton).button_index
		if button == MOUSE_BUTTON_WHEEL_UP: _steps += 1
		elif button == MOUSE_BUTTON_WHEEL_DOWN: _steps -= 1
		else: return
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed:
		var key := event as InputEventKey
		if event.is_action_pressed("move_forward") or key.physical_keycode == KEY_UP: _steps += 1
		elif event.is_action_pressed("move_back") or key.physical_keycode == KEY_DOWN: _steps -= 1
		else: return
		get_viewport().set_input_as_handled()

func _controller(side: String) -> XRController3D:
	if not bool(game.get("xr_active")): return null
	return game.player.find_child("XRController" + side, true, false) as XRController3D

func _confirm_pressed() -> bool:
	var right := _controller("Right")
	if right != null: return right.is_button_pressed("ax_button")
	return Input.is_action_pressed("move_jump")

func _cancel_pressed() -> bool:
	var right := _controller("Right")
	if right != null: return right.is_button_pressed("by_button")
	return InputMap.has_action("stand_up") and Input.is_action_pressed("stand_up")

## Either stick pushed up or down steps the time, repeating while held.
func _stick_steps(delta: float) -> int:
	var y := 0.0
	for side: String in ["Left", "Right"]:
		var controller := _controller(side)
		if controller != null:
			var v := controller.get_vector2("primary").y
			if absf(v) > absf(y): y = v
	var dir := 0 if absf(y) < STICK_ON else (1 if y > 0.0 else -1)
	if dir == 0:
		_stick_dir = 0
		return 0
	if dir != _stick_dir:
		_stick_dir = dir; _stick_wait = STICK_FIRST_REPEAT
		return dir
	_stick_wait -= delta
	if _stick_wait > 0.0: return 0
	_stick_wait = STICK_REPEAT
	return dir
