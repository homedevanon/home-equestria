extends RefCounted
## Developer tools gate (dev 2026-10-20: player builds show no debug or dev tools). Player
## exports carry the "player_build" feature (tools/build/make_export_presets.py): no command
## console, noclip, weather/visit keys, profilers or developer launch flags. Editor runs, dev
## launches and tester builds keep everything. The plain FPS counter and quick saves stay.

## Launch arguments a player may pass (launchers, VR restart, seated play).
const PLAYER_ARGS := ["--require-vr", "--seated", "--room-scale", "--verbose-log"]


static func enabled() -> bool:
	return built_in() or unlocked()


static func built_in() -> bool:
	return not OS.has_feature("player_build")


## Settings > Updates pressed five times (world/ui/settings_page.gd) opens the console, noclip and
## the debug keys in a player build too, at once and on later launches (dev 2026-10-30).
static func unlocked() -> bool:
	var loop := Engine.get_main_loop() as SceneTree
	var settings: Node = loop.root.get_node_or_null("Settings") if loop != null and loop.root != null else null
	return settings != null and settings.has_method("get_value") and settings.call("get_value", "debug/unlocked") == true


## Exported debug builds for testers (dev 2026-10-20: "debug build so he can get all his ai
## logs ... optimize token usage") record full AI traffic without launch flags: the same as
## `-- --ai-trace-full`. The editor and release exports do not.
static func tester_capture() -> bool:
	return built_in() and OS.has_feature("template") and OS.is_debug_build()


## Game arguments after "--". Player builds keep only PLAYER_ARGS.
static func user_args() -> PackedStringArray:
	var args := OS.get_cmdline_user_args()
	if built_in(): return args
	var kept := PackedStringArray()
	for arg in args:
		if arg in PLAYER_ARGS: kept.append(arg)
	return kept
