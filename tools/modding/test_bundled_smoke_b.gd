extends SceneTree
## Bundled packs B (overhaul 2026-11-08, W2-BUNDLE-SMOKE-B; M-MOD-14, MOD-07/08/11-16): Pegasus Ride
## 2.2.1 (+ devanon patch), Dance Mod 2.1.1 (the author's 2026-11-08 update of Pony Dances, shipped
## as-is), Mirror Pool 0.3.4, Pinkie's Pedal Copter 0.4.3, Sit Anywhere 1.1.0, Output Console 1.1.0,
## Watch Party 1.0.0 (default off, + devanon patch) and Anonfilly v2 (default off). The packs are
## the staged bundled files (<private root>/bundled_mods/, the new dance pack from the overhaul's
## quarantined downloads), copied into a scratch install and booted through the real loader
## (world/modding/mod_loader.gd) with every other staged pack, entry scripts started by the real
## Mods autoload, then the real world (world/main.tscn) booted around them.
## Per pack: mounted, entry started, script errors from its files, idle cost (us per physics tick and
## per process frame, each script of the mod called by a driver node while the engine's own call is
## off: with no world and a 5000-node tree, then in the world, unused) and its specific checks.
## Prints a table and SMOKE_B_DONE PASS|FAIL. OPEN lines are known gaps in files this package does
## not own (see the W2-BUNDLE-SMOKE-B report), not failures.
##   XDG_DATA_HOME=<scratch>/smoke-b GODOT=<godot> python3 tools/run_owned_godot.py --project home-equestria-public \
##       --wait-for-slot 1800 --timeout 900 --expect SMOKE_B_DONE --log LOG res://tools/modding/test_bundled_smoke_b.gd
## Modes (--arg=...): default = as shipped (Watch Party and Anonfilly off); --opt-in = Watch Party and
## Anonfilly switched on; --only=<mod id> = that pack and its patch alone, no world. Options:
## --ticks=N (idle ticks, 600), --filler=N (nodes in the no-world probe, 5000), --no-world,
## --no-clones (skip the Mirror Pool 0/5/20 copies), --no-patches (the authors' packs alone, for before/after),
## --dance-patch (also the unbundled Dance Mod patch), --world (boot the world in --only mode too),
## --exported-player=<desktop_player.gdc> (the game's player script as exported binary tokens behind a
## .remap, fixtures/smoke_b/exported_player.py; with --only=sit_anywhere --world: M-MOD-01 for Sit Anywhere).
const LOADER := preload("res://world/modding/mod_loader.gd")
const BUNDLED := preload("res://world/modding/bundled_mods.gd")
const BUILDER := preload("res://tools/modding/fixtures/smoke_b/build_patch_packs.gd")
const SET_B := ["pegasus_ride_v2", "dance_mod", "mirror_pool", "pinkie_copter", "sit_anywhere", "output_console", "watch_party", "anonfilly"]
## devanon patch pack id -> the mod it patches; its folder under <private root>/bundled_mods/.
const PATCHES := {"pegasus_ride_v2_patch": "pegasus_ride_v2", "watch_party_patch": "watch_party", "dance_mod_patch": "dance_mod", "mirror_pool_patch": "mirror_pool"}
const PATCH_FOLDER := {"pegasus_ride_v2_patch": "pegasus_ride_v2_patch", "watch_party_patch": "watch_party_patch", "dance_mod_patch": "pony_dances_patch", "mirror_pool_patch": "mirror_pool_patch"}
## A method only the patch adds, to tell its extension is the running entry.
const PATCH_MARK := {"pegasus_ride_v2_patch": "_patch_typing", "watch_party_patch": "_patch_search_now", "dance_mod_patch": "_patch_typing", "mirror_pool_patch": "_patch_world_closed"}
## Built but not bundled (DECISIONS.md: Pony Dances ships as-is); in the install only with --dance-patch.
const NOT_BUNDLED := ["dance_mod_patch"]
const DEFAULT_OFF := ["watch_party", "anonfilly"]
## The author's update of Pony Dances (DECISIONS.md, 2026-11-08 midday): mod id dance_mod 2.1.1.
const DANCE_PACK := "captures/overhaul-2026-11-08/mods/waltz_three_new/urygioca.pck"
const DANCE_SHA := ["d92ac9c4", "a7d5"]
## Log tags each mod prints with, for attributing warnings.
const TAGS := {"pegasus_ride_v2": "[PegasusRide]", "dance_mod": "[WaltzDance]", "mirror_pool": "[pool]",
	"output_console": "[Output Console]", "watch_party": "[watch_party]", "pinkie_copter": "[copter", "anonfilly": "[anonfilly"}
## perf/BASELINE.md: mean FPS at the saved bench spot (a frame in us), for FPS estimates.
const FRAME_US := 1000000.0 / 322.0

var failures := 0
var checks := 0
var opens := 0
var mode := "default"
var opt_in := false
var only := ""
var ticks := 600
var temp := ""
var install := ""
var root_dir := ""
var capture: Capture
var driver: Driver
var mods_node: Node
var game: Node
var table := {}   # mod id -> {field: value}


class Capture extends Logger:
	var mutex := Mutex.new()
	var lines: Array[String] = []

	func _log_message(message: String, error: bool) -> void:
		mutex.lock(); lines.append(("E " if error else "P ") + message.strip_edges()); mutex.unlock()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
		var text := rationale if code.is_empty() else (code if rationale.is_empty() else code + " : " + rationale)
		var where := "%s:%d %s" % [file, line, function]
		for trace: ScriptBacktrace in script_backtraces:
			if trace == null: continue
			for i in trace.get_frame_count(): where += " < %s:%d" % [trace.get_frame_file(i), trace.get_frame_line(i)]
		mutex.lock(); lines.append(("W " if error_type == Logger.ERROR_TYPE_WARNING else "E ") + text + " @ " + where); mutex.unlock()

	func count() -> int:
		mutex.lock(); var n := lines.size(); mutex.unlock()
		return n

	func since(start: int) -> Array[String]:
		mutex.lock(); var out: Array[String] = lines.slice(start); mutex.unlock()
		return out


## Calls each probed mod script's _physics_process / _process itself (the engine's call is off for
## those nodes meanwhile) and adds up the time per mod.
class Driver extends Node:
	var targets := {}   # mod id -> {"phys": Array, "proc": Array}
	var phys_us := {}
	var proc_us := {}
	var phys_samples := {}   # mod id -> PackedInt32Array of us per tick
	var physics_ticks := 0
	var frames := 0
	var on := false

	func _ready() -> void:
		process_physics_priority = 1000000
		process_priority = 1000000
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _physics_process(delta: float) -> void:
		if not on: return
		physics_ticks += 1
		for id: String in targets:
			var started := Time.get_ticks_usec()
			for node: Variant in targets[id].phys:
				if is_instance_valid(node): (node as Node).call("_physics_process", delta)
			var spent := Time.get_ticks_usec() - started
			phys_us[id] = int(phys_us.get(id, 0)) + spent
			var samples: PackedInt32Array = phys_samples.get(id, PackedInt32Array())
			samples.append(spent)
			phys_samples[id] = samples

	func _process(delta: float) -> void:
		if not on: return
		frames += 1
		for id: String in targets:
			var started := Time.get_ticks_usec()
			for node: Variant in targets[id].proc:
				if is_instance_valid(node): (node as Node).call("_process", delta)
			proc_us[id] = int(proc_us.get(id, 0)) + Time.get_ticks_usec() - started


func _initialize() -> void: run.call_deferred()

func check(ok: bool, text: String) -> void:
	checks += 1
	print("[smoke-b] ", "PASS " if ok else "FAIL ", text)
	if not ok: failures += 1

func open(text: String) -> void:
	opens += 1
	print("[smoke-b] OPEN ", text)

func note(text: String) -> void:
	print("[smoke-b] NOTE ", text)

func arg(prefix: String, fallback: String) -> String:
	for item: String in OS.get_cmdline_user_args():
		if item == prefix.trim_suffix("="): return "1"
		if item.begins_with(prefix): return item.trim_prefix(prefix)
	return fallback

func row(id: String) -> Dictionary:
	if not table.has(id): table[id] = {"version": "", "on": false, "mounted": false, "entry": "-", "errors": 0, "warnings": 0, "idle_title": "-", "idle_world": "-", "checks": []}
	return table[id]

func add_result(id: String, text: String) -> void:
	(row(id).checks as Array).append(text)

func frames(count: int) -> void:
	for i in count: await physics_frame


# ------------------------------------------------------------------------- install

## The folder holding `file` under <bundled>/<folder>/ (stage.py's layout), or "".
func find_staged(bundled: String, file: String) -> String:
	for sub: String in DirAccess.get_directories_at(bundled):
		if FileAccess.file_exists(bundled.path_join(sub).path_join(file)): return bundled.path_join(sub).path_join(file)
	return ""

## {id: mod.json} of a pack, read from its directory (nothing mounted).
func pack_mods(path: String) -> Dictionary:
	var out := {}
	var index := LOADER.pack_index(path)
	for item: String in index:
		var parts := item.trim_prefix("res://").split("/")
		if parts.size() == 3 and parts[0] == "mods" and parts[2] == "mod.json":
			var doc: Variant = LOADER.parse(LOADER.pack_text(path, index[item]))
			if doc is Dictionary: out[parts[1]] = doc
	return out

## The game's desktop_player.gd as the exported game holds it: binary tokens (made by the 4.5 export
## template, fixtures/smoke_b/exported_player.py) behind player/desktop_player.gd.remap, in a pack
## mounted over the source run before the loader boots (M-MOD-01: Sit Anywhere extends that file).
const PLAYER_PATH := "res://player/desktop_player.gd"

func mount_exported_player(gdc: String) -> bool:
	var bytes := FileAccess.get_file_as_bytes(gdc)
	if bytes.size() < 4 or bytes.slice(0, 4).get_string_from_ascii() != "GDSC":
		check(false, "--exported-player %s holds Godot binary tokens" % gdc.get_file()); return false
	check(not ResourceLoader.has_cached(PLAYER_PATH), "desktop_player.gd is not loaded before the loader boots (the tokens reach it)")
	var tokens := temp.path_join("player_tokens.gdc")
	var file := FileAccess.open(tokens, FileAccess.WRITE); file.store_buffer(bytes); file.close()
	var remap := temp.path_join("player_remap.txt")
	file = FileAccess.open(remap, FileAccess.WRITE); file.store_string("[remap]\n\npath=\"res://player/desktop_player.gdc\"\n"); file.close()
	var pack := temp.path_join("exported_player.pck")
	var packer := PCKPacker.new()
	packer.pck_start(pack)
	packer.add_file("res://player/desktop_player.gdc", tokens)
	packer.add_file(PLAYER_PATH + ".remap", remap)
	packer.flush()
	var mounted := ProjectSettings.load_resource_pack(pack, true)
	check(mounted, "the exported desktop_player.gd (%d bytes of tokens) mounts behind its .remap" % bytes.size())
	return mounted

func copy_in(source: String, file: String) -> String:
	var target := install.path_join(file)
	if DirAccess.copy_absolute(source, target) != OK: return ""
	return FileAccess.get_sha256(target)

## Writes the scratch install: every staged pack except the old Pony Dances (waltz_three, replaced by
## dance_mod 2.1.1), the devanon patch packs found beside them, the new dance pack, this package's
## patch packs. `--only` keeps that mod (and its patch) alone.
func write_install() -> bool:
	var bundled := root_dir.path_join("bundled_mods")
	var doc: Variant = LOADER.parse(FileAccess.get_file_as_string(bundled.path_join("bundled_mods.json")))
	if not doc is Dictionary or not (doc as Dictionary).get("mods") is Array:
		check(false, "staged bundled_mods.json readable"); return false
	DirAccess.make_dir_recursive_absolute(install)
	var rows: Array = []
	var listed := {}
	for item: Variant in (doc as Dictionary).mods:
		if not item is Dictionary: continue
		var entry: Dictionary = (item as Dictionary).duplicate(true)
		if str(entry.id) == "waltz_three": continue
		var source := find_staged(bundled, str(entry.file))
		if source.is_empty(): note("staged file missing: %s" % entry.file); continue
		entry.sha256 = copy_in(source, str(entry.file))
		listed[str(entry.id)] = true
		rows.append(entry)
	# Patch packs other packages built (board_games_compat, shove_improvements), when stage.py has not listed them yet.
	for folder: String in ["board_games_compat", "shove_improvements"]:
		if listed.has(folder): continue
		for file: String in DirAccess.get_files_at(bundled.path_join(folder)):
			if file.get_extension() != "pck": continue
			var mods := pack_mods(bundled.path_join(folder).path_join(file))
			for id: String in mods:
				var manifest: Dictionary = mods[id]
				if not manifest.get("patches") is Dictionary: continue
				rows.append({"id": id, "title": str(manifest.get("name", id)), "author": "devanon", "version": str(manifest.get("version", "")),
					"file": file, "sha256": copy_in(bundled.path_join(folder).path_join(file), file), "default_on": true,
					"patches": manifest.patches, "order": 15 if folder == "board_games_compat" else 105})
				listed[id] = true
	var dance := root_dir.path_join(DANCE_PACK)
	var dance_sha := FileAccess.get_sha256(dance) if FileAccess.file_exists(dance) else ""
	check(dance_sha.begins_with(DANCE_SHA[0]) and dance_sha.ends_with(DANCE_SHA[1]), "the new dance pack is the one DECISIONS.md names (sha256 %s)" % dance_sha.left(12))
	if not dance_sha.is_empty() and not listed.has("dance_mod"):   # stage.py lists it since W3
		rows.append({"id": "dance_mod", "title": "Dance Mod", "author": "Anon", "version": "2.1.1", "file": "dance_mod.pck",
			"sha256": copy_in(dance, "dance_mod.pck"), "default_on": true, "order": 90})
	for id: String in PATCHES:
		var folder := str(PATCH_FOLDER[id])
		var shipped := bundled.path_join(folder).path_join(id + ".pck")
		var rebuilt := temp.path_join("rebuilt").path_join(id + ".pck")
		var sha := BUILDER.build(bundled, folder, rebuilt)
		check(FileAccess.file_exists(shipped) and sha == FileAccess.get_sha256(shipped), "%s.pck is built from its sources (sha256 %s)" % [id, sha.left(12)])
		if id in NOT_BUNDLED and arg("--dance-patch=", "") != "1": continue
		if listed.has(id): continue   # stage.py lists the patch packs since W3
		var mods := pack_mods(shipped)
		var manifest: Dictionary = mods.get(id, {})
		var parent := str(PATCHES[id])
		var order := 0
		for entry: Dictionary in rows:
			if str(entry.id) == parent: order = int(entry.get("order", 0)) + 1
		rows.append({"id": id, "title": str(manifest.get("name", id)), "author": "devanon", "version": str(manifest.get("version", "")),
			"file": id + ".pck", "sha256": copy_in(shipped, id + ".pck"), "default_on": parent not in DEFAULT_OFF,
			"patches": manifest.get("patches", {}), "order": order})
	if arg("--no-patches=", "") == "1":
		rows = rows.filter(func(entry: Dictionary) -> bool: return not PATCHES.has(str(entry.id)))
	if not only.is_empty():
		rows = rows.filter(func(entry: Dictionary) -> bool:
			return str(entry.id) == only or str(PATCHES.get(str(entry.id), "")) == only)
	var file := FileAccess.open(install.path_join("bundled_mods.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"format": 1, "mods": rows}, "\t")); file.close()
	note("install: %d packs (%s)" % [rows.size(), ", ".join(rows.map(func(entry: Dictionary) -> String: return str(entry.id)))])
	return true


# ------------------------------------------------------------------------- probes

func script_has(node: Node, method: String) -> bool:
	var script := node.get_script() as Script
	while script != null:
		for item: Dictionary in script.get_script_method_list():
			if str(item.name) == method: return true
		script = script.get_base_script()
	return false

## The mod a node's script belongs to (its path or a base's under res://mods/<id>/), or "".
func owner_mod(node: Node) -> String:
	var script := node.get_script() as Script
	while script != null:
		var path := script.resource_path
		if path.begins_with("res://mods/"): return path.trim_prefix("res://mods/").get_slice("/", 0)
		script = script.get_base_script()
	return ""

## Every node in the tree running a mod's script, by mod id (an extension of a game script takes the
## game's path and is not counted: its cost is the game's).
func mod_nodes() -> Dictionary:
	var out := {}
	for node: Node in root.find_children("*", "", true, false):
		if node == driver: continue
		var id := owner_mod(node)
		if id.is_empty(): continue
		if not out.has(id): out[id] = []
		(out[id] as Array).append(node)
	return out

## us per physics tick and per process frame of each mod's scripts over `count` physics ticks.
func probe(count: int) -> Dictionary:
	var off: Array = []
	driver.targets.clear(); driver.phys_us.clear(); driver.proc_us.clear(); driver.phys_samples.clear(); driver.physics_ticks = 0; driver.frames = 0
	var nodes := mod_nodes()
	for id: String in nodes:
		var phys: Array = []; var proc: Array = []
		for node: Node in nodes[id]:
			if node.is_physics_processing() and script_has(node, "_physics_process"): phys.append(node)
			if node.is_processing() and script_has(node, "_process"): proc.append(node)
		for node: Node in phys: node.set_physics_process(false); off.append([node, true])
		for node: Node in proc: node.set_process(false); off.append([node, false])
		driver.targets[id] = {"phys": phys, "proc": proc}
	driver.targets["__floor__"] = {"phys": [], "proc": []}   # the harness's own cost, an empty mod
	driver.on = true
	await frames(count)
	driver.on = false
	for item: Array in off:
		if not is_instance_valid(item[0]): continue
		if item[1]: (item[0] as Node).set_physics_process(true)
		else: (item[0] as Node).set_process(true)
	var out := {}
	for id: String in driver.targets:
		var samples: PackedInt32Array = driver.phys_samples.get(id, PackedInt32Array())
		var sorted := samples.duplicate(); sorted.sort()
		out[id] = {"phys": float(driver.phys_us.get(id, 0)) / maxf(1.0, driver.physics_ticks),
			"median": float(sorted[sorted.size() / 2]) if not sorted.is_empty() else 0.0,
			"worst": float(sorted[sorted.size() - 1]) if not sorted.is_empty() else 0.0,
			"proc": float(driver.proc_us.get(id, 0)) / maxf(1.0, driver.frames),
			"phys_nodes": (driver.targets[id].phys as Array).size(), "proc_nodes": (driver.targets[id].proc as Array).size()}
	note("probe: %d physics ticks, %d process frames" % [driver.physics_ticks, driver.frames])
	return out

## A mod's idle cost less the harness floor (an empty target timed the same way).
func idle_text(result: Dictionary, id: String) -> String:
	if not result.has(id): return "0 (no per-frame script)"
	var item: Dictionary = result[id]
	var floor_item: Dictionary = result.get("__floor__", {"phys": 0.0, "median": 0.0, "proc": 0.0})
	return "%.1f us/tick (median %.0f, worst %.0f) + %.1f us/frame (%d+%d nodes)" % [maxf(0.0, item.phys - floor_item.phys), maxf(0.0, item.median - floor_item.median),
		item.worst, maxf(0.0, item.proc - floor_item.proc), item.phys_nodes, item.proc_nodes]

## Lines the mod's files or its log tag produced, by kind ("E" errors, "W" warnings).
func attributed(lines: Array[String], id: String, kind: String) -> Array[String]:
	var out: Array[String] = []
	var tag := str(TAGS.get(id, "\u0001"))
	for line: String in lines:
		if not line.begins_with(kind + " "): continue
		if line.contains("res://mods/%s/" % id) or line.contains(tag) or line.contains("[mods] %s " % id): out.append(line)
	return out


# ------------------------------------------------------------------------- run

func run() -> void:
	if not OS.get_environment("XDG_DATA_HOME").contains("smoke-b"):
		printerr("SMOKE_B_REFUSED requires an isolated XDG_DATA_HOME containing smoke-b"); quit(1); return
	opt_in = arg("--opt-in=", "") == "1"
	if opt_in: mode = "opt-in"
	only = arg("--only=", "")
	if not only.is_empty(): mode = "only:" + only + (" opt-in" if opt_in else "")
	ticks = int(arg("--ticks=", "600"))
	root_dir = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()
	temp = ProjectSettings.globalize_path("user://smoke_b")
	install = temp.path_join("install/mods/bundled")
	note("mode %s, root %s" % [mode, root_dir.get_file()])
	capture = Capture.new()
	OS.add_logger(capture)
	driver = Driver.new(); driver.name = "SmokeBDriver"; root.add_child(driver)
	mods_node = root.get_node_or_null("Mods")
	check(mods_node != null, "the Mods autoload runs in this fixture")
	if mods_node == null or not write_install(): finish(); return

	if opt_in:
		for id: String in DEFAULT_OFF: BUNDLED.set_on(id, false, true)
	var empty := temp.path_join("user_mods")
	DirAccess.make_dir_recursive_absolute(empty)
	if opt_in: fake_ffmpeg()
	var exported := arg("--exported-player=", "")
	if not exported.is_empty() and not mount_exported_player(exported): finish(); return
	var boot_mark := capture.count()
	var started := Time.get_ticks_usec()
	LOADER.boot([empty], [], PackedStringArray(), install)
	note("loader boot %.0f ms" % ((Time.get_ticks_usec() - started) / 1000.0))
	for item: Dictionary in LOADER.active(): mods_node.call("_start", item)
	await frames(5)
	loads(boot_mark)
	anonfilly_row()
	if mode == "default":
		watch_party_off()
		# Watch Party's goods in a briefcase restored while the mod is not loaded (as shipped: off).
		briefcase_without_watch_party()

	# No world (title screen, loading): a 5000-node tree, nothing of the player's.
	var filler := Node3D.new(); filler.name = "SmokeBFiller"; root.add_child(filler)
	var parent: Node = filler
	for i in int(arg("--filler=", "5000")):
		var node := Node3D.new(); node.name = "N%d" % i
		parent.add_child(node)
		if i % 50 == 49: parent = node
	await frames(30)
	var title := await probe(ticks)
	for id: String in table:
		row(id).idle_title = idle_text(title, id)
		note("%s idle (no world): %s" % [id, row(id).idle_title])
	note("harness floor (no world): " + idle_text({"x": title.get("__floor__", {})}, "x"))
	for id: String in title:
		if id == "__floor__": continue
		if not table.has(id): note("other pack %s idle (no world): %s" % [id, idle_text(title, id)])
	filler.queue_free()
	await frames(2)
	if opt_in and entry_of("watch_party") != null:
		check(not FileAccess.file_exists(temp.path_join("ffmpeg_runs.txt")), "watch_party on: no external process ran while it started (no world, %d ticks)" % ticks)

	if (mode.begins_with("only:") and arg("--world=", "") != "1") or arg("--no-world=", "") == "1":
		finish(); return
	if not await boot_world(): finish(); return
	var world_mark := capture.count()
	await to_town()
	await frames(120)
	var unused := await probe(ticks)
	for id: String in table:
		row(id).idle_world = idle_text(unused, id)
		note("%s idle (world, unused): %s" % [id, row(id).idle_world])
	for id: String in unused:
		if id == "__floor__": continue
		if not table.has(id): note("other pack %s idle (world): %s" % [id, idle_text(unused, id)])
	await output_console_checks()
	await sit_anywhere_checks()
	await pegasus_checks()
	await dance_checks()
	await copter_checks()
	if opt_in: await watch_party_on_checks()
	if mode == "default" and arg("--no-clones=", "") != "1": await mirror_pool_checks()
	world_errors(world_mark)
	await close_world()
	finish()

## Leaving the world (back to the title, or loading another save, frees the game node): for a few
## seconds after, no mod of this set may report an error (Mirror Pool 0.3.4 did, once a second).
func close_world() -> void:
	var mark := capture.count()
	game.queue_free()
	await frames(200)
	game = null
	check(mods_node.get("game") == null, "Mods.game is cleared when the world closes")
	var lines := capture.since(mark)
	for id: String in table:
		if not row(id).mounted: continue
		var errors := attributed(lines, id, "E")
		for line: String in errors.slice(0, 3): note("%s error after the world closed: %s" % [id, line.left(300)])
		row(id).errors = int(row(id).errors) + errors.size()
		check(errors.is_empty(), "%s: no script errors for %.1f s after the world closed (%d)" % [id, 200.0 / Engine.physics_ticks_per_second, errors.size()])
		if id == "mirror_pool": add_result(id, "after the world closed: %d errors" % errors.size())

func finish() -> void:
	print("[smoke-b] ---- per-pack table (%s) ----" % mode)
	print("[smoke-b] | pack | version | on | mounted | entry | script errors | warnings | idle, no world | idle, world unused | specific checks |")
	for id: String in SET_B + PATCHES.keys():
		if not table.has(id): continue
		var item: Dictionary = table[id]
		print("[smoke-b] | %s | %s | %s | %s | %s | %d | %d | %s | %s | %s |" % [id, item.version, item.on, item.mounted, item.entry,
			item.errors, item.warnings, item.idle_title, item.idle_world, "; ".join(PackedStringArray(item.checks))])
	print("SMOKE_B_DONE %s checks=%d failures=%d open=%d mode=%s" % ["PASS" if failures == 0 else "FAIL", checks, failures, opens, mode])
	if is_instance_valid(capture): OS.remove_logger(capture)
	if is_instance_valid(game):
		game.queue_free()
		await process_frame
		await process_frame
	quit(0 if failures == 0 else 1)


# ------------------------------------------------------------------------- loads

func loads(mark: int) -> void:
	var lines := capture.since(mark)
	var rows := LOADER.pack_rows()
	for pack: Dictionary in rows:
		var ids: Array = pack.ids if not (pack.ids as Array).is_empty() else [str(pack.file).get_file().get_basename()]
		for id: String in ids:
			if id not in SET_B and not PATCHES.has(id):
				if bool(pack.enabled) and not str(pack.reason).is_empty(): note("other pack %s: %s" % [pack.file, pack.reason])
				continue
			var item := row(id)
			item.version = str(pack.version)
			item.on = bool(pack.enabled)
			item.mounted = bool(pack.mounted)
			var expected_on := (id not in DEFAULT_OFF and str(PATCHES.get(id, "")) not in DEFAULT_OFF) or opt_in
			check(bool(pack.mounted) == expected_on, "%s %s mounted=%s as %s (%s)" % [id, pack.version, pack.mounted, "expected" if bool(pack.mounted) == expected_on else "NOT expected", pack.reason])
	for mod: Dictionary in LOADER.mods:
		var id := str(mod.id)
		if id not in SET_B and not PATCHES.has(id):
			if not (mod.errors as Array).is_empty(): note("other mod %s errors: %s" % [id, "; ".join(PackedStringArray(mod.errors))])
			continue
		check((mod.errors as Array).is_empty(), "%s loads without loader errors %s" % [id, mod.errors])
		if not str(mod.entry).is_empty() and mod.enabled:
			var started := entry_of(id) != null
			row(id).entry = "started" if started else "MISSING"
			check(started, "%s entry %s started" % [id, mod.entry])
	for id: String in PATCHES:
		if not row(id).mounted: continue
		var parent := entry_of(str(PATCHES[id]))
		var patched := parent != null and script_has(parent, str(PATCH_MARK[id]))
		check(patched, "%s extends the running %s entry" % [id, PATCHES[id]])
		add_result(str(PATCHES[id]), "patched by %s" % id if patched else "patch NOT applied")
	for id: String in table:
		var errors := attributed(lines, id, "E")
		row(id).errors = errors.size()
		row(id).warnings = attributed(lines, id, "W").size()
		for line: String in errors.slice(0, 5): note("%s boot error: %s" % [id, line.left(300)])
		if row(id).mounted: check(errors.is_empty(), "%s: no script errors while booting and starting" % id)

## A mod's entry node under the Mods autoload (entries may rename themselves: "PegasusRide").
func entry_of(id: String) -> Node:
	for child: Node in mods_node.get_children():
		if owner_mod(child) == id: return child
	return null

func world_errors(mark: int) -> void:
	var lines := capture.since(mark)
	for id: String in table:
		var errors := attributed(lines, id, "E")
		var warnings := attributed(lines, id, "W")
		row(id).errors = int(row(id).errors) + errors.size()
		row(id).warnings = int(row(id).warnings) + warnings.size()
		for line: String in errors.slice(0, 5): note("%s world error: %s" % [id, line.left(300)])
		for line: String in warnings.slice(0, 3): note("%s world warning: %s" % [id, line.left(200)])
		if row(id).mounted: check(errors.is_empty(), "%s: no script errors in the world" % id)

func boot_world() -> bool:
	var scene := load("res://world/main.tscn") as PackedScene
	if scene == null: check(false, "world/main.tscn loads"); return false
	# A world whose opening is over: a new world's arrival story would otherwise ask for a form, put
	# him in the Everfree pocket and move him away in the middle of the checks.
	var context: Node = preload("res://world/ai/world_context.gd").new()
	root.add_child(context)
	var context_root := OS.get_environment("EQ_CONTEXT_ROOT")
	if context_root.is_empty(): context_root = "user://test_context/" + str(OS.get_process_id())
	if context.open_world("smoke_b_world", context_root):
		context.state.arrival = {"stage": "done", "teleported": true, "shelter_explained": true}
		context._changed()
		context.flush()
	else:
		note("could not seed the world context: %s" % context.get("error"))
	context.free()
	game = scene.instantiate()
	game.set("inventory_save_path", "")
	game.set("context_world_id", "smoke_b_world")
	var started := Time.get_ticks_msec()
	root.add_child(game)
	while Time.get_ticks_msec() - started < 180000:
		var saves: Variant = game.get("saves")
		if saves is Object and bool((saves as Object).get("ready_to_save")): break
		await physics_frame
	var saves_now: Variant = game.get("saves")
	var ready := saves_now is Object and bool((saves_now as Object).get("ready_to_save"))
	check(ready, "the world boots with the packs (%.0f s)" % ((Time.get_ticks_msec() - started) / 1000.0))
	check(mods_node.get("game") == game, "Mods.world_ready reached the mods")
	return ready


## A new world wakes the player deep in the Everfree (arrival): the checks need ponies, so he is put
## in Ponyville and the population is given time to stream its residents in.
func to_town() -> void:
	var body := game.get("player") as CharacterBody3D
	var spot: Vector2 = WorldLayout.spawn("ponyville")
	var at := Vector3(spot.x, 0.0, spot.y)
	at.y = WorldTerrain.instance.height_at(at) + 0.5 if is_instance_valid(WorldTerrain.instance) else 1.0
	body.global_position = at
	body.velocity = Vector3.ZERO
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 60000:
		await frames(30)
		var near := 0
		for pony: Node in get_nodes_in_group("sim_ponies"):
			if pony is Node3D and (pony as Node3D).global_position.distance_to(body.global_position) < 80.0: near += 1
		if near >= 8: break
	note("in Ponyville after %.0f s: %d ponies in the world" % [(Time.get_ticks_msec() - started) / 1000.0, get_nodes_in_group("sim_ponies").size()])


# ------------------------------------------------------------------------- packs

func anonfilly_row() -> void:
	# The page builds its lists in _init, off the tree; Settings > Mods asks mod_updates.gd shared(self)
	# for the author-update rows, which needs a tree: hand it the one under the root first.
	var updates := load("res://world/update/mod_updates.gd") as GDScript
	if updates != null: updates.call("shared", driver)
	var page_script := load("res://world/ui/settings_page.gd") as GDScript
	var page: Object = page_script.new() if page_script != null else null
	if page == null: check(false, "settings_page.gd loads"); return
	for pack: Dictionary in LOADER.pack_rows():
		if str(pack.file) != "bundled/anonfilly.pck": continue
		var text := str(page.call("_mod_text", pack, LOADER.mods)) + "\n" + str(page.call("_mod_notes", pack))
		note("anonfilly Settings row (%s): %s" % [mode, text.replace("\n", " | ")])
		var author_flag := text.contains("author field names the game")
		var swear_flag := text.to_lower().contains("swear")
		if author_flag: check(true, "anonfilly: the 'Home: Equestria' author claim is flagged on its Settings row")
		else: open("anonfilly: the author claim is not flagged on its Settings row while the pack is %s (settings_page.gd reads it only from a loaded mod; hook note)" % ("off" if not pack.enabled else "on"))
		if swear_flag: check(true, "anonfilly: persona swearing flagged on its Settings row")
		else: open("anonfilly: persona swearing is not flagged on its Settings row (needs a manifest note the loader shows; hook note)")
		add_result("anonfilly", "author claim %s, swearing %s" % ["flagged" if author_flag else "NOT flagged", "flagged" if swear_flag else "NOT flagged"])
	if page is Node: (page as Node).free()

## As shipped Watch Party is off: nothing of it may load.
func watch_party_off() -> void:
	var nothing := not FileAccess.file_exists("res://mods/watch_party/main.gd") and entry_of("watch_party") == null \
		and not Engine.has_meta(&"watch_party_extensions") and not capture.since(0).any(func(line: String) -> bool: return line.contains("watch_party extends") or line.contains("[watch_party]"))
	check(nothing, "watch_party off: its pack is not mounted, no entry, no script extension, no log line")
	add_result("watch_party", "off: nothing loads" if nothing else "off: something LOADED")

## A briefcase holding Watch Party goods, restored without the mod: they are parked, the rest stays.
func briefcase_without_watch_party() -> void:
	var store_script := load("res://world/inventory/inventory_store.gd") as GDScript
	var store: Object = store_script.new()
	var slots: Array = []
	for i in int(store_script.get_script_constant_map().get("SLOT_COUNT", 27)): slots.append({})
	slots[0] = {"id": "apple", "count": 3}
	slots[2] = {"id": "goods:watch-tv-remote", "count": 1}
	slots[4] = {"id": "goods:watch-tv-vintage", "count": 1}
	var ok := bool(store.call("restore_document", {"version": 1, "bits": 321, "slots": slots, "checked_out": {}}))
	var kept_apple := false
	var tv_in_slots := false
	for slot: Variant in store.get("slots"):
		if slot is Dictionary and str((slot as Dictionary).get("id", "")) == "apple" and int((slot as Dictionary).get("count", 0)) == 3: kept_apple = true
		if slot is Dictionary and str((slot as Dictionary).get("id", "")).begins_with("goods:watch-tv"): tv_in_slots = true
	var parked: Variant = store.get("parked")
	var parked_ids: Array = []
	if parked is Array:
		for item: Variant in parked:
			var entry: Variant = (item as Dictionary).get("entry") if item is Dictionary else null
			if entry is Dictionary: parked_ids.append(str((entry as Dictionary).get("id", "")))
	var good := ok and int(store.get("bits")) == 321 and kept_apple and not tv_in_slots and "goods:watch-tv-remote" in parked_ids and "goods:watch-tv-vintage" in parked_ids
	check(good, "watch_party removed: the briefcase keeps its bits and apples, the TV and remote are parked (%s)" % [parked_ids])
	add_result("watch_party", "removed: briefcase kept, TVs parked" if good else "removed: briefcase NOT kept")

## A stand-in ffmpeg in the place Watch Party looks second (its data folder): each run leaves a line.
func fake_ffmpeg() -> void:
	var folder := ProjectSettings.globalize_path("user://mods/data/watch_party")
	DirAccess.make_dir_recursive_absolute(folder)
	var marker := temp.path_join("ffmpeg_runs.txt")
	if FileAccess.file_exists(marker): DirAccess.remove_absolute(marker)
	var path := folder.path_join("ffmpeg")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("#!/bin/sh\necho \"$@\" >> '%s'\necho 'ffmpeg version smoke-b'\nexit 0\n" % marker); file.close()
	OS.execute("chmod", PackedStringArray(["+x", path]))

func watch_party_on_checks() -> void:
	var marker := temp.path_join("ffmpeg_runs.txt")
	var hub := entry_of("watch_party")
	if hub == null: check(false, "watch_party on: its entry runs"); return
	await frames(60)
	var quiet := not FileAccess.file_exists(marker)
	check(quiet, "watch_party on: no external process ran at start or in the world before a TV was used")
	var base := (hub.get_script() as Script).get_base_script() as GDScript
	var author_searches := base != null and base.source_code.contains("\tfind_ffmpeg()\n\tMods.world_ready")
	note("watch_party 1.0.0 alone runs `ffmpeg -version` from main.gd _ready: %s" % author_searches)
	hub.call("ffmpeg_note")
	for i in 600:
		if FileAccess.file_exists(marker) and not str(hub.get("ffmpeg")).is_empty(): break
		await physics_frame
	var used := FileAccess.file_exists(marker) and not str(hub.get("ffmpeg")).is_empty()
	check(used, "watch_party on: the first TV menu's question (ffmpeg_note) starts the search and finds ffmpeg (%s)" % hub.get("ffmpeg"))
	var web: Variant = hub.get("web")
	var cef_idle := not (web is Node and is_instance_valid(web) and bool((web as Node).call("running") if (web as Node).has_method("running") else false))
	add_result("watch_party", "on: nothing external until a TV asks (%s), then ffmpeg found (%s)%s" % [quiet, used, "" if cef_idle else ", browser running"])

func output_console_checks() -> void:
	var console := entry_of("output_console")
	if console == null: return
	var logger: Variant = console.get("_logger")
	var panel: Variant = console.get("_panel")
	var label: Variant = console.get("_label")
	var closed := panel is Control and not (panel as Control).visible
	var count := 2000
	var started := Time.get_ticks_usec()
	for i in count: print("smoke-b logger probe %d" % i)
	var with_us := Time.get_ticks_usec() - started
	OS.remove_logger(logger as Logger)
	started = Time.get_ticks_usec()
	for i in count: print("smoke-b logger probe %d" % i)
	var without_us := Time.get_ticks_usec() - started
	OS.add_logger(logger as Logger)
	await frames(3)
	var drawn := label is RichTextLabel and (label as RichTextLabel).get_parsed_text().length() > 0
	var per := float(with_us - without_us) / count
	check(closed and not drawn, "output_console closed: the captured lines are queued, nothing is drawn")
	note("output_console logger: %.2f us per log line while closed (%d lines: %d us with, %d us without)" % [per, count, with_us, without_us])
	add_result("output_console", "closed: %.2f us per log line, no drawing" % per)

func sit_anywhere_checks() -> void:
	if entry_of("sit_anywhere") == null: return
	var player: Variant = game.get("player")
	if not player is CharacterBody3D: check(false, "sit_anywhere: a desktop player"); return
	var body := player as CharacterBody3D
	var script := body.get_script() as GDScript
	var chained := script != null and script.resource_path == "res://player/desktop_player.gd" and script_has(body, "_own_ground_seat")
	var base := script.get_base_script() as GDScript if script != null else null
	var standing := FileAccess.get_file_as_string("res://player/desktop_player.gd")
	var over_standing := base != null and LOADER._without_class_name(standing).strip_edges() == base.source_code.strip_edges()
	if not arg("--exported-player=", "").is_empty():
		# Tokens carry no source text: the base is the loader's N.gd copy behind N.gd.remap -> N.gdc.
		over_standing = base != null and base.source_code.is_empty() and FileAccess.file_exists(base.resource_path + ".remap")
		check(over_standing, "sit_anywhere extends the exported (binary token) desktop_player.gd through the loader's .remap copy (%s)" % (base.resource_path if base != null else "no base"))
	var compat := false
	for pack: Dictionary in LOADER.pack_rows():
		if "board_games_compat" in pack.ids and pack.mounted: compat = true
	check(chained and over_standing, "sit_anywhere extends the desktop_player.gd that stands at the game path (%s)" % ("the board_games_compat copy" if compat else "the game's own; board_games_compat not mounted"))
	for i in 180:
		if body.is_on_floor(): break
		await physics_frame
	var sit_mod := entry_of("sit_anywhere")
	note("sit_anywhere before Z: on floor %s, controls_locked %s, view_hold %s, seat %s, form %s, may toggle %s" % [body.is_on_floor(), body.get("controls_locked"),
		body.get("view_hold"), body.get("seat"), body.get("form_driver"), sit_mod.call("_can_toggle") if sit_mod != null else "-"])
	await press(KEY_Z)
	var seat: Variant = body.get("seat")
	var sat := seat is Node3D and (seat as Node3D).has_meta("sit_anywhere")
	check(sat, "sit_anywhere: Z sits desktop Anon on the ground")
	var moved := 0.0
	if sat:
		var from := (seat as Node3D).global_position
		Input.action_press("move_forward")
		await frames(60)
		Input.action_release("move_forward")
		var still: Variant = body.get("seat")
		moved = (seat as Node3D).global_position.distance_to(from) if is_instance_valid(seat) else -1.0
		check(still == seat and moved > 0.05, "sit_anywhere: W shuffles the seated player %.2f m and he stays seated" % moved)
		await press(KEY_Z)
		await frames(3)
		var collision := body.get_node_or_null("Collision") as CollisionShape3D
		check(body.get("seat") == null and (collision == null or not collision.disabled), "sit_anywhere: Z again stands him up with collision back on")
	add_result("sit_anywhere", "chain %s%s, Z sit %s, shuffle %.2f m" % [chained and over_standing, " over compat" if compat else "", sat, moved])

## The nearest pony in the world who has wings and can fly, or null.
func flier(near: Vector3) -> CharacterBody3D:
	var best: CharacterBody3D = null
	var distance := INF
	for pony: Node in get_nodes_in_group("sim_ponies"):
		if not pony is CharacterBody3D: continue
		var identity: Variant = pony.get("identity")
		if not identity is Object or not (identity as Object).has_method("has_wings") or not bool((identity as Object).call("has_wings")): continue
		if (identity as Object).get("can_fly") == false: continue
		if pony.has_method("_indoors") and bool(pony.call("_indoors", (pony as Node3D).global_position)): continue
		var d := (pony as Node3D).global_position.distance_to(near)
		if d < distance: best = pony; distance = d
	return best

func bonds() -> Object:
	var context: Variant = game.get("world_context")
	return (context as Object).get("player_bonds") as Object if context is Object else null

func set_stage(id: String, stage: String) -> void:
	var store := bonds()
	if store == null: return
	var record: Dictionary = store.call("record_for", id)
	record.stage = stage
	record.familiarity = maxf(float(record.get("familiarity", 0.0)), 25.0)
	record.trust = maxf(float(record.get("trust", 0.0)), 12.0)
	store.call("_save", id, record)

## Counts the key events that reach _input (whether Input.parse_input_event dispatches here).
class KeySpy extends Node:
	var seen := 0
	func _input(event: InputEvent) -> void:
		if event is InputEventKey: seen += 1

## -1 not probed yet, 0 the headless display server does not dispatch parsed events to the
## viewport (they still update Input's key state), 1 it does.
var dispatches := -1

func probe_dispatch() -> void:
	var spy := KeySpy.new(); root.add_child(spy)
	var key := InputEventKey.new(); key.keycode = KEY_F24; key.physical_keycode = KEY_F24; key.pressed = true
	Input.parse_input_event(key)
	await frames(2)
	var up := key.duplicate() as InputEventKey; up.pressed = false
	Input.parse_input_event(up)
	await frames(2)
	dispatches = 1 if spy.seen > 0 else 0
	spy.queue_free()
	note("parsed input events reach _input in this run: %s (otherwise the fixture also pushes them into the root viewport)" % (dispatches == 1))

## A key event as the keyboard gives it: Input's state (polled keys) and the viewport's _input.
func key_event(code: Key, pressed: bool) -> void:
	if dispatches < 0: await probe_dispatch()
	var key := InputEventKey.new(); key.keycode = code; key.physical_keycode = code; key.pressed = pressed
	Input.parse_input_event(key)
	if dispatches == 0: root.push_input(key)

func press(code: Key, hold_ticks := 3) -> void:
	await key_event(code, true)
	await frames(hold_ticks)
	await key_event(code, false)
	await frames(2)

func place_player_near(target: Node3D, metres: float) -> void:
	var body := game.get("player") as CharacterBody3D
	var away := Vector3(metres, 0.0, 0.0).rotated(Vector3.UP, target.global_rotation.y)
	body.global_position = target.global_position + away + Vector3.UP * 0.3
	body.velocity = Vector3.ZERO
	await frames(20)

## The game's flight refuses a take-off from uneven ground ("No safe landing footprint",
## pony_flight.gd landing_surface). Test setup: when she stands on such ground, she is set down on
## the nearest even spot so the ride itself can be checked.
func footing_for(mare: Node3D) -> void:
	if mare.has_method("_ensure_flight"): mare.call("_ensure_flight")
	var flight: Variant = mare.get("flight")
	if not flight is Object or not (flight as Object).has_method("landing_surface"): return
	# The ride asks to fly to where she stands, so her spot must pass as a landing (not a roof) too.
	if ((flight as Object).call("landing_surface", mare.global_position, false) as Vector3).is_finite(): return
	for radius: float in [1.5, 3.0, 5.0, 8.0, 12.0]:
		for i in 12:
			var at := mare.global_position + Vector3(radius, 0.0, 0.0).rotated(Vector3.UP, TAU * i / 12.0)
			if is_instance_valid(WorldTerrain.instance): at.y = WorldTerrain.instance.height_at(at)
			var ground: Vector3 = (flight as Object).call("landing_surface", at, false)
			if not ground.is_finite(): continue
			mare.global_position = ground + Vector3.UP * 0.05
			(mare as CharacterBody3D).velocity = Vector3.ZERO
			note("pegasus_ride_v2: her spot was not even enough to take off; set down %.1f m away for the ride check" % radius)
			await frames(20)
			return
	note("pegasus_ride_v2: no even spot near her for the ride check")

## She may be on a flight of her own (a day-plan errand): wait for her to land, else end it on the spot.
func grounded(mare: Node3D) -> void:
	for i in 1200:
		var flight: Variant = mare.get("flight")
		if not flight is Object or not bool((flight as Object).call("active")): return
		await physics_frame
	var flight_now: Variant = mare.get("flight")
	if flight_now is Object and (flight_now as Object).has_method("cancel"):
		note("pegasus_ride_v2: her own flight did not end in 20 s; ended it for the check")
		(flight_now as Object).call("cancel")
		await frames(90)

func pegasus_checks() -> void:
	var ride := entry_of("pegasus_ride_v2")
	if ride == null: return
	var body := game.get("player") as CharacterBody3D
	# Typing: a focused LineEdit has the keyboard.
	var layer := CanvasLayer.new(); root.add_child(layer)
	var line := LineEdit.new(); layer.add_child(line)
	await frames(2)
	line.grab_focus()
	var mark := capture.count()
	await press(KEY_N)
	var typed_quiet := not bool(ride.get("_mounted")) and capture.since(mark).filter(func(text: String) -> bool: return text.contains("[PegasusRide]")).is_empty()
	check(line.has_focus() and typed_quiet, "pegasus_ride_v2: N while typing in a text field does nothing")
	line.release_focus()
	layer.queue_free()
	var mare := flier(body.global_position)
	if mare == null:
		open("pegasus_ride_v2: no winged pony who can fly is in the fixture world; mount checks skipped")
		add_result("pegasus_ride_v2", "typing guard %s; no flier in the world" % typed_quiet)
		return
	var id := str((mare.get("identity") as Object).get("id"))
	set_stage(id, "acquaintance")
	await place_player_near(mare, 2.5)
	mark = capture.count()
	await press(KEY_N)
	var refused_stranger := not bool(ride.get("_mounted")) and capture.since(mark).any(func(text: String) -> bool: return text.contains("No winged friend"))
	check(refused_stranger, "pegasus_ride_v2: N reaches the mod when not typing, and an acquaintance (%s) does not carry him" % id)
	set_stage(id, "friend")
	check(bool(ride.call("_friend_ok", mare)), "pegasus_ride_v2: a Friend (bond stage 'friend': familiarity 20, trust 10) may carry him")
	# Held: the game's flight request refuses; 2.2.1 hovered anyway.
	await grounded(mare)
	mare.set("_held", true)
	await frames(100)
	await place_player_near(mare, 2.5)
	mark = capture.count()
	await press(KEY_N)
	var fly: Variant = mare.get("flight")
	var held_refused := not bool(ride.get("_mounted")) and not (fly is Object and bool((fly as Object).call("active"))) \
		and capture.since(mark).any(func(text: String) -> bool: return text.contains("can't take off"))
	var held_said := ""
	for text: String in capture.since(mark):
		if text.contains("[PegasusRide]"): held_said = text.left(140)
	note("pegasus_ride_v2 held: %.1f m away, friend %s, mounted %s, said: %s" % [mare.global_position.distance_to(body.global_position),
		ride.call("_friend_ok", mare), ride.get("_mounted"), held_said])
	check(held_refused, "pegasus_ride_v2: a held pony refuses the take-off with the game's reason")
	mare.set("_held", false)
	await frames(100)
	await grounded(mare)
	await place_player_near(mare, 2.5)
	mark = capture.count()
	await press(KEY_N)
	await frames(30)
	var mounted := bool(ride.get("_mounted"))
	var reason := ""
	for text: String in capture.since(mark):
		if text.contains("[PegasusRide]"): reason = text.left(160)
	if not mounted and reason.contains("footprint"):
		# Neither her spot nor his passes as an even landing here: once more from even ground.
		note("pegasus_ride_v2: refused here (%s); trying again from even ground" % reason)
		await footing_for(mare)
		await grounded(mare)
		await place_player_near(mare, 2.5)
		var flight_for_note: Variant = mare.get("flight")
		if flight_for_note is Object:
			var fo := flight_for_note as Object
			note("pegasus_ride_v2 footing before the retry: her spot as take-off %s, as landing %s; his spot as landing %s; she is %.1f m from him" % [
				fo.call("landing_surface", mare.global_position, true), fo.call("landing_surface", mare.global_position, false),
				fo.call("landing_surface", body.global_position, false), mare.global_position.distance_to(body.global_position)])
		mark = capture.count()
		await press(KEY_N)
		await frames(30)
		mounted = bool(ride.get("_mounted"))
		for text: String in capture.since(mark):
			if text.contains("[PegasusRide]"): reason = text.left(160)
	fly = mare.get("flight")
	if mounted:
		check(fly is Object and bool((fly as Object).call("active")), "pegasus_ride_v2: a free, standing Friend takes off with him (the game's flight, or the ride's own hover where only the footing was uneven)")
		await press(KEY_N)
		for i in 900:
			if not bool(ride.get("_mounted")): break
			await physics_frame
		var landed := not bool(ride.get("_mounted")) and body.collision_layer != 0
		check(landed, "pegasus_ride_v2: N again lands; he is let go with his collision back")
	else:
		open("pegasus_ride_v2: the friend did not take off at this spot (%s)" % reason)
	# Scootaloo: wings but no flight.
	var scootaloo := load("res://world/characters/background/scootaloo.tres") as Resource
	var stand_in_script := GDScript.new()
	stand_in_script.source_code = "extends Node\nvar identity: Resource\n"
	stand_in_script.reload()
	var stand_in: Node = stand_in_script.new()
	stand_in.set("identity", scootaloo)
	var patched_says := bool(ride.call("_is_pegasus", stand_in))
	var base_script := (ride.get_script() as Script).get_base_script() as GDScript
	var author: Node = base_script.new() if base_script != null else null
	var author_says := bool(author.call("_is_pegasus", stand_in)) if author != null else false
	check(scootaloo != null and scootaloo.get("can_fly") == false and not patched_says, "pegasus_ride_v2: Scootaloo (wings, can_fly false) is not a ride (2.2.1 alone: %s)" % author_says)
	if author != null: author.free()
	stand_in.free()
	add_result("pegasus_ride_v2", "typing %s, stranger refused %s, held refused %s, ride %s, Scootaloo %s (2.2.1: %s)" % [typed_quiet, refused_stranger, held_refused, "ok" if mounted else "not here: " + reason, "refused" if not patched_says else "FLIES", "flies" if author_says else "refused"])

## The largest rotation (radians) by which a limited joint's skeleton pose is outside its limits.
var last_joint := ""

func limit_violation(mare: Node) -> float:
	var limits: Variant = mare.get("joint_limits")
	var skeleton: Variant = mare.get("skeleton")
	if not limits is Object or not skeleton is Skeleton3D: return -1.0
	var worst := 0.0
	var joints: Dictionary = (limits as Object).get("joints")
	for index: int in joints:
		var basis := Basis((skeleton as Skeleton3D).get_bone_pose_rotation(index))
		var limited: Basis = (limits as Object).call("constrain", index, basis)
		var off := basis.get_rotation_quaternion().angle_to(limited.orthonormalized().get_rotation_quaternion())
		if off > worst:
			worst = off
			last_joint = str((joints[index] as Dictionary).get("name", index)) if joints[index] is Dictionary else str(index)
	return worst

func adult_partner(near: Vector3) -> CharacterBody3D:
	var best: CharacterBody3D = null
	var distance := INF
	for pony: Node in get_nodes_in_group("sim_ponies"):
		var identity: Variant = pony.get("identity")
		if not pony is CharacterBody3D or not identity is Object or (identity as Object).get("filly") == true or pony.get("pivot") == null: continue
		var flight: Variant = pony.get("flight")
		if flight is Object and bool((flight as Object).call("active")): continue
		var d := (pony as Node3D).global_position.distance_to(near)
		# One with nopony else within 4 m first: the mod dances with the nearest pony it allows.
		for other: Node in get_nodes_in_group("sim_ponies"):
			if other != pony and other is Node3D and (other as Node3D).global_position.distance_to((pony as Node3D).global_position) < 4.0:
				d += 1000.0; break
		if d < distance: best = pony; distance = d
	return best

func dance_checks() -> void:
	var dance := entry_of("dance_mod")
	if dance == null: return
	var body := game.get("player") as CharacterBody3D
	var mare := adult_partner(body.global_position)
	if mare == null: open("dance_mod: no pony to dance with in the fixture world"); return
	var id := str((mare.get("identity") as Object).get("id"))
	set_stage(id, "dating")   # test data: Waltz and Caramelldansen need rank 3
	var results: Array[String] = []
	for style: String in ["bounce", "shake", "caramel"]:
		await place_player_near(mare, 1.3)
		body.look_at(Vector3(mare.global_position.x, body.global_position.y, mare.global_position.z), Vector3.UP)
		var pivot := mare.get("pivot") as Node3D
		var locked_before := bool(body.get("controls_locked"))
		var mask_before := body.collision_mask
		var nav_before: Node = mare.get_node_or_null("Navigator")
		var wander_before: Variant = nav_before.get("wander_enabled") if nav_before != null else null
		var baseline := 0.0
		for i in 30:
			await physics_frame
			baseline = maxf(baseline, limit_violation(mare))
		var influences := {}
		for node: Node in mare.find_children("*", "SkeletonModifier3D", true, false): influences[node] = (node as SkeletonModifier3D).influence
		dance.call("_set_style", style)
		var pivot_before := pivot.transform   # the game's pivot the frame the dance starts
		var dance_mark := capture.count()
		var started := Time.get_ticks_usec()
		dance.call("_toggle")
		var start_ms := (Time.get_ticks_usec() - started) / 1000.0
		if not bool(dance.get("_dancing")):
			open("dance_mod %s: did not start here (see the [WaltzDance] warning)" % style); continue
		# The mod dances with the nearest pony it allows (2.1.1 _nearest, 3 m), not always the one chosen.
		var dancer: Variant = dance.get("_pony")
		if dancer != mare:
			dance.call("_stop", false)
			await frames(10)
			open("dance_mod %s: the mod took another pony (%s) nearer the player than %s; not measured" % [style,
				(dancer as Node).name if dancer is Node else "none", id])
			continue
		var worst := 0.0; var tilt := 0.0; var lift := 0.0; var worst_joint := ""
		for i in 240:
			await physics_frame
			var now := limit_violation(mare)
			if now > worst: worst = now; worst_joint = last_joint
			# Pitch and roll only: facing the player turns the model half round about its up axis.
			var turned := pivot.transform.basis.orthonormalized() * pivot_before.basis.orthonormalized().inverse()
			tilt = maxf(tilt, rad_to_deg((turned * Vector3.UP).angle_to(Vector3.UP)))
			lift = maxf(lift, pivot.transform.origin.y - pivot_before.origin.y)
		var ended_alone := not bool(dance.get("_dancing"))
		if ended_alone:
			var why := ""
			for text: String in capture.since(dance_mark):
				if text.contains("[WaltzDance]"): why = text.left(160)
			note("dance_mod %s: the dance had already ended on its own (%s)" % [style, why if not why.is_empty() else "no log line"])
		dance.call("_stop", false)
		# Every stop path of 2.1.1 (_stop) puts back the pivot it saved as the dance began; the game's own
		# locomotion and posture write it again afterwards. So: the saved pivot is the one from before
		# the dance, and once the game has had her for a second she is not left tilted.
		var saved: Variant = dance.get("_saved_piv")
		var saved_ok := saved is Transform3D and (saved as Transform3D).origin.distance_to(pivot_before.origin) < 0.05 \
			and rad_to_deg(((saved as Transform3D).basis.orthonormalized() * Vector3.UP).angle_to(pivot_before.basis.orthonormalized() * Vector3.UP)) < 3.0
		await frames(60)
		var tilt_before := rad_to_deg((pivot_before.basis.orthonormalized() * Vector3.UP).angle_to(Vector3.UP))
		var tilt_after := rad_to_deg((pivot.transform.basis.orthonormalized() * Vector3.UP).angle_to(Vector3.UP))
		var posture: Variant = mare.get("posture")
		var posture_now := str((posture as Object).get("requested")) if posture is Object else "?"
		var left: Array[String] = []
		if not saved_ok: left.append("saved pivot %s is not the one before the dance %s" % [saved, pivot_before])
		if tilt_after > tilt_before + 3.0 and posture_now == "stand":
			left.append("still tilted %.1f deg a second after the stop (%.1f before), standing" % [tilt_after, tilt_before])
		if posture_now != "stand": note("dance_mod %s: a second after the stop her pivot is tilted %.1f deg (%.1f before; posture %s), written by the game's locomotion" % [style, tilt_after, tilt_before, posture_now])
		if mare.has_meta("dancing_with_player"): left.append("meta")
		if str(mare.get("_interaction")) != "": left.append("interaction " + str(mare.get("_interaction")))
		if bool(body.get("controls_locked")) != locked_before: left.append("player lock")
		if body.collision_mask != mask_before: left.append("player collision")
		var nav := mare.get_node_or_null("Navigator")
		# Dance Mod 2.1.1 _stop() sets wander_enabled true whatever it was (ships as-is: reported, not failed).
		if nav != null and wander_before != null and nav.get("wander_enabled") != wander_before:
			open("dance_mod %s: the stop left her navigator's wander %s; it was %s before the dance (2.1.1 always turns it on)" % [style, nav.get("wander_enabled"), wander_before])
		for node: Variant in influences:
			if is_instance_valid(node) and not is_equal_approx((node as SkeletonModifier3D).influence, float(influences[node])): left.append("modifier " + str((node as Node).name))
		var restored := left.is_empty()
		if not restored: note("dance_mod %s: left over after the stop: %s" % [style, "; ".join(PackedStringArray(left))])
		check(worst <= baseline + 0.02, "dance_mod %s: the limited joints stay inside pony_joint_limits (worst %.3f rad at %s, %.3f before the dance)" % [style, worst, worst_joint, baseline])
		check(restored, "dance_mod %s: the pony is let go cleanly (model pivot, meta, hooves, navigator, tail modifiers, player lock and collision)" % style)
		note("dance_mod %s: model turned up to %.1f deg about her hips, lifted %.2f m; starting took %.1f ms (song load)" % [style, tilt, lift, start_ms])
		results.append("%s: joints %.3f rad (base %.3f), pivot %.0f deg/%.2f m, released %s, start %.0f ms" % [style, worst, baseline, tilt, lift, restored, start_ms])
	set_stage(id, "friend")
	add_result("dance_mod", ", ".join(results))

func copter_checks() -> void:
	if entry_of("pinkie_copter") == null: return
	var model := load("res://mods/pinkie_copter/models/pinkie_copter.glb") as PackedScene
	var sound := load("res://mods/pinkie_copter/sounds/copter_putter_loop.wav") as AudioStream
	check(model != null and sound != null, "pinkie_copter: its model and putter sound load")
	add_result("pinkie_copter", "model %s, sound %s" % [model != null, sound != null])

## Mirror Pool with 0, 5 and 20 copies: the world save's size, the mod's own script time and the
## frame's physics/process time (the copies are real resident ponies).
func mirror_pool_checks() -> void:
	var pool := entry_of("mirror_pool")
	if pool == null: return
	var clones: Variant = pool.get("clones")
	var context: Object = game.get("world_context") as Object
	var population: Variant = game.get("population")
	if not clones is Node or context == null or not population is Object:
		open("mirror_pool: no clone keeper or world context"); return
	var body := game.get("player") as CharacterBody3D
	var available: Dictionary = (population as Object).get("available")
	var actor: Node3D = null
	for pony: Node in get_nodes_in_group("sim_ponies"):
		var identity: Variant = pony.get("identity")
		if identity is Object and available.has(str((identity as Object).get("id"))) and pony.get("pivot") != null:
			actor = pony as Node3D; break
	if actor == null: open("mirror_pool: no resident to copy"); return
	var results: Array[String] = []
	var made := 0
	for wanted: int in [0, 5, 20]:
		while made < wanted:
			var angle := TAU * float(made) / 20.0
			var at := body.global_position + Vector3(cos(angle), 0.0, sin(angle)) * (8.0 + float(made % 5))
			var copy: Variant = await (clones as Node).call("make", actor, at)
			if copy == null: break
			made += 1
		await frames(180)
		var physics_ms := 0.0; var process_ms := 0.0
		for i in 240:
			await physics_frame
			physics_ms += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			process_ms += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		var scripts: Dictionary = await probe(240)
		var section := JSON.stringify(mods_node.call("state", "mirror_pool")).length()
		var whole := JSON.stringify(context.get("state")).length()
		var files := 0
		var folder := ProjectSettings.globalize_path("user://mods/data/mirror_pool/copies")
		if DirAccess.dir_exists_absolute(folder):
			for file: String in DirAccess.get_files_at(folder): files += FileAccess.get_file_as_bytes(folder.path_join(file)).size()
		var own: Dictionary = scripts.get("mirror_pool", {"phys": 0.0, "proc": 0.0})
		var line := "%d copies (%d live): save section %d B, world state %d B, profile files %d B, mod scripts %.1f us/tick + %.1f us/frame, physics step %.2f ms, process %.2f ms" % [
			made, ((clones as Node).get("live") as Dictionary).size(), section, whole, files, own.phys, own.proc, physics_ms / 240.0, process_ms / 240.0]
		note("mirror_pool " + line)
		results.append(line)
		if wanted == 0: check(float(own.phys) + float(own.proc) < 15.0, "mirror_pool with no copies costs ~0 (%.1f us)" % (float(own.phys) + float(own.proc)))
		if made < wanted: open("mirror_pool: only %d of %d copies could be made here" % [made, wanted]); break
	add_result("mirror_pool", " | ".join(results))
