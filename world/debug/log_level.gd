extends RefCounted
## Log level (thread suggestion, dev 2026-11-01 "include this in the next patch"): player builds
## log only errors and warnings, which is cheaper and keeps the log file short. Debug mode
## (Settings > Updates pressed five times, world/dev_tools.gd unlocked()) turns every info print
## back on at once, so a player can switch it on, reproduce a problem and send the full log.
## Source runs, the editor and tester builds always print everything; `-- --verbose-log` forces
## it in any build (release smoke tests wait for printed markers such as TITLE READY).
##
## Mechanism: Engine.print_to_stdout gates print()/print_rich() for both the terminal and the
## log file. push_error/push_warning, printerr and engine errors are not gated and always land.
const DEV := preload("res://world/dev_tools.gd")
const FLAG := "--verbose-log"

static func verbose() -> bool:
	return DEV.enabled() or FLAG in OS.get_cmdline_user_args()

## Apply now; Quality calls it at start and whenever debug/unlocked changes.
static func apply() -> void:
	var on := verbose()
	if Engine.print_to_stdout == on: return
	if not on: print("[log] Player build: only errors and warnings are logged. Turn on debug mode (press Settings > Updates five times) for full logs.")
	Engine.print_to_stdout = on
	if on: print("[log] Full logging on (debug mode).")
