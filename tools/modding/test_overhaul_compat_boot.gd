extends SceneTree
## Ponyville Overhaul with its compat pack, booted in the real game (2026-11-24). The loader mounts the
## packs of the --bundled-dir fixture (the normal bundled packs plus ponyville_overhaul and
## ponyville_overhaul_compat), a fresh world loads behind its loading cover, and the ponies are counted
## for --watch seconds. Checks: both packs are mounted and not held; the overhaul's town code ran (its
## watch node under the root); ponies are out at the end; no parse or script error comes from a file of
## the two packs (--pack-files: a text file of their res:// paths, one per line, written by the fixture
## script). Every distinct engine error is printed with its count either way.
## Run: captures/ponyville-overhaul-2026-11-24/tools/boot_overhaul_fixture.sh (fixture, isolated data,
## owned runner). Needs XDG_DATA_HOME containing smoke-a-test. Marker: OVERHAUL_BOOT_DONE.
## --overhaul=off: the fixture lists the overhaul switched off (make_overhaul_fixture.py --off); the
## checks turn round: the overhaul and its patch packs stay unmounted, its files are not visible, its
## town code does not run, and the old town still loads with ponies. Game scripts are loaded at run
## time, never preloaded: a preload compiles before the loader mounts the packs, so the game's own copy
## of a replaced script (world_context.gd pulls in place_directory.gd, living_world.gd ...) would run.
const LOADER := preload("res://world/modding/mod_loader.gd")
const LOGGER_SOURCE := """extends Logger
var errors: Dictionary = {}
var order: Array = []
var files: Dictionary = {}
var lock := Mutex.new()
func _log_error(function: String, file: String, line: int, code: String, rationale: String, editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	var where := file
	if error_type == ERROR_TYPE_SCRIPT and not script_backtraces.is_empty() and script_backtraces[0].get_frame_count() > 0:
		where = script_backtraces[0].get_frame_file(0)
	var key := "%s | %s:%d %s | %s" % [["ERROR", "WARNING", "SCRIPT ERROR", "SHADER ERROR"][clampi(error_type, 0, 3)], where, line, function, rationale if not rationale.is_empty() else code]
	lock.lock()
	if not errors.has(key): errors[key] = 0; order.append(key); files[key] = [error_type, where, file, rationale + " " + code]
	errors[key] += 1
	lock.unlock()
func _log_message(message: String, error: bool) -> void:
	pass
"""

var logger: Object
var game: Node
var failures := 0


func _initialize() -> void:
	var script := GDScript.new()
	script.source_code = LOGGER_SOURCE
	if script.reload() == OK:
		logger = script.new()
		OS.add_logger(logger)
	run.call_deferred()


func arg(name: String, fallback := "") -> String:
	for item: String in OS.get_cmdline_user_args():
		if item.begins_with("--" + name + "="): return item.substr(name.length() + 3)
	return fallback


func check(ok: bool, what: String) -> void:
	print("OVERHAUL_BOOT %s %s" % ["PASS" if ok else "FAIL", what])
	if not ok: failures += 1


func run() -> void:
	if not OS.get_environment("XDG_DATA_HOME").contains("smoke-a-test"):
		printerr("OVERHAUL_BOOT_REFUSED requires an isolated XDG_DATA_HOME containing smoke-a-test"); quit(2); return
	print("OVERHAUL_BOOT game version ", LOADER.game_version())
	var rows := {}
	for row: Dictionary in LOADER.pack_rows():
		rows[str(row.file).get_file()] = row
		if str(row.file).contains("overhaul") or str(row.file).contains("board_games"):
			print("OVERHAUL_BOOT pack %s mounted=%s enabled=%s held=%s game_version=%s overrides=%d reason=%s error=%s" % [row.file, row.mounted,
				row.enabled, row.held, row.game_version, (row.overrides as PackedStringArray).size(), row.reason, row.error])
	var on := arg("overhaul", "on") != "off"
	for file: String in ["ponyville_overhaul.pck", "ponyville_overhaul_compat.pck", "ponyville_overhaul_fixes.pck"]:
		var row: Dictionary = rows.get(file, {})
		if row.is_empty() and file == "ponyville_overhaul_fixes.pck": continue
		if on: check(not row.is_empty() and bool(row.mounted) and not bool(row.held), "%s is mounted and not held" % file)
		else: check(not row.is_empty() and not bool(row.mounted), "%s is listed and not mounted" % file)
	check(FileAccess.file_exists("res://world/towns/ponyville/overhaul_migration.gd") == on, "the overhaul's files are %s" % ["visible" if on else "not visible"])
	var watch := float(arg("watch", "60"))
	var started := Time.get_ticks_msec()
	var loaded := await _load_world(arg("world", "overhaul_compat_boot"))
	check(loaded, "the world finishes loading")
	if loaded:
		print("OVERHAUL_BOOT world loaded after %.1f s" % ((Time.get_ticks_msec() - started) / 1000.0))
		check((root.get_node_or_null("WatchDay") != null) == on, "the overhaul's town code %s (its WatchDay node)" % ["ran" if on else "did not run"])
		var t0 := Time.get_ticks_msec()
		var next := 0.0
		var last := 0
		while (Time.get_ticks_msec() - t0) / 1000.0 < watch:
			var t := (Time.get_ticks_msec() - t0) / 1000.0
			if t >= next:
				last = _census("t=%.0f" % t); next += 10.0
			await process_frame
		last = _census("end")
		check(last > 0, "ponies are out after %.0f s (%d)" % [watch, last])
	_errors()
	print("OVERHAUL_BOOT %s (%d failed)" % ["PASS" if failures == 0 else "FAIL", failures])
	print("OVERHAUL_BOOT_DONE")
	if is_instance_valid(game): game.queue_free()
	for frame in 5: await process_frame
	quit(0 if failures == 0 else 1)


func _census(label: String) -> int:
	if not is_instance_valid(game): print("OVERHAUL_BOOT census ", label, " no game"); return 0
	var alive := 0
	var ids: Array = []
	for actor: Variant in game.get("mares"):
		if not is_instance_valid(actor): continue
		alive += 1
		var identity: Resource = (actor as Node).get("identity")
		ids.append(str(identity.id) if identity != null else str((actor as Node).name))
	var pop: Node = game.get("population")
	var live := (pop.get("live") as Dictionary).size() if is_instance_valid(pop) and pop.get("live") is Dictionary else -1
	print("OVERHAUL_BOOT census %s mares=%d live=%d spawn_failure=%s ids=%s" % [label, alive, live, game.get("spawn_failure"), ids.slice(0, 12)])
	return alive


func _load_world(world_id: String) -> bool:
	var context: Node = (load("res://world/ai/world_context.gd") as GDScript).new()
	root.add_child(context)
	var opened: bool = context.open_world(world_id, OS.get_environment("EQ_CONTEXT_ROOT"))
	if opened:
		if not context.state.has("arrival"): context.state.arrival = {"stage": "done"}
		context._changed()
		context.flush()
	context.free()
	if not opened: return false
	var settings: Node = root.get_node("Settings")
	settings._values["setup/completed"] = true
	settings._values["ponies/max_nearby"] = 8
	settings._values["video/quality"] = "Low"
	game = load("res://world/main.tscn").instantiate()
	game.context_world_id = world_id
	root.add_child(game)
	current_scene = game
	var deadline := Time.get_ticks_msec() + 300000
	while Time.get_ticks_msec() < deadline:
		if not is_instance_valid(game): return false
		var cover := game.get_node_or_null("LoadingCover")
		if is_instance_valid(game.get("saves")) and game.saves.ready_to_save and cover == null: return true
		await process_frame
	return false


## Every distinct engine error; parse and script errors from a file of the two packs fail the run.
func _errors() -> void:
	if logger == null: check(false, "the error logger is installed"); return
	var ours := {}
	var listed := arg("pack-files")
	if not listed.is_empty() and FileAccess.file_exists(listed):
		for line: String in FileAccess.get_file_as_string(listed).split("\n", false): ours[line.strip_edges()] = true
	check(not ours.is_empty(), "the packs' file list was read (--pack-files)")
	var bad := 0
	print("OVERHAUL_BOOT errors: %d distinct" % (logger.order as Array).size())
	for key: String in logger.order:
		print("OVERHAUL_BOOT error x%d %s" % [logger.errors[key], key])
		var info: Array = logger.files[key]
		var from_pack := ours.has(str(info[1])) or ours.has(str(info[2]))
		var parse := str(info[3]).contains("Parse Error") or str(info[3]).contains("Compile Error")
		if from_pack and (int(info[0]) == 2 or parse): bad += 1; print("OVERHAUL_BOOT pack script error: ", key)
	check(bad == 0, "no parse or script error from a file of the overhaul or its compat pack (%d)" % bad)
