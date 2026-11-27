extends RefCounted
## Performance trials (2026-11-24). A change that is built but not yet measured stays off until the
## game is started with the user argument `--try=<name>[,<name>]` (`--try=all` turns every trial on).
## The lead compares each trial against the plain game before anything becomes a default.
## A trial that became a default keeps an off switch: `--try=no_<name>` (see off(); `all` never
## turns a default off). Defaults so far: library_door_occluder (2026-11-25).
## The arguments are read once; nothing here runs per frame. Call as
##   const TRY := preload("res://world/perf/try_switch.gd")   ...   if TRY.on("my_trial"): ...
static var _names: PackedStringArray = PackedStringArray()
static var _read := false

static func on(trial: String) -> bool:
	_read_args()
	return trial in _names or "all" in _names


## A default-on change switched off for this launch with `--try=no_<name>`.
static func off(default_on: String) -> bool:
	_read_args()
	return ("no_" + default_on) in _names


static func _read_args() -> void:
	if _read: return
	_read = true
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--try="): _names.append_array(arg.trim_prefix("--try=").split(",", false))
