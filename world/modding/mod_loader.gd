extends RefCounted
## Mods (dev 2026-10-26: "anything moddable. ANYTHING"). A mod is a resource pack (.pck) that
## carries res://mods/<id>/mod.json and anything else. Settings._init calls boot() right after
## the game's own packs (tools/build/packs.gd) and before any other game script loads, so a mod can:
## - replace any game file (a file in the pack at the game's own path; fragile across updates),
## - deep-merge JSON into game data (res://mods/<id>/merge/<path under res://>),
## - extend any game script (mod.json "extends": scripts that `extends "res://<game script>"`),
## - run its own code (mod.json "entry": a Node the Mods autoload adds, world/modding/mods.gd).
## Packs come from three places and mount in this order, after the game's packs:
## 1. bundled mods: the install's mods/bundled/ folder with bundled_mods.json (world/modding/
##    bundled_mods.gd; dev 2026-11-08), each default on or off, in the manifest's order, a newer
##    downloaded update (user://mods/bundled_updates/) in place of the shipped file;
## 2. the mods folders (user://mods/, and mods/ beside the executable), in file name order;
## 3. loose .pck files beside the executable that are not the game's own (the older way).
## A patch pack (bundled_mods.json or mod.json "patches": {"<mod id>": "<exact version>"}) mounts
## right after the pack it patches and switches with it. When a bundled mod and a pack the player
## installed carry the same mod id, the higher version loads and the other is "superseded".
## Switches in Settings → Mods are kept in user://mods/mods.cfg ([mods] disabled: file names of
## the player's packs; bundled_on / bundled_off: bundled mod ids) and apply at once for mods that
## only run an entry script (switch()); anything else applies on the next launch. Guide for modders
## and their AI agents: res://mods/README.md, res://mods/AGENTS.md (source repository only).
## Scenario mods (mod.json "scenario", world/modding/scenario.gd): at most one runs; a second one
## switched on is held with a reason (_one_scenario()), and their switches apply at the next launch.

const USER_DIR := "user://mods"
const SETTINGS := "user://mods/mods.cfg"
const MERGED := "user://mods/.merged"
const CHECK_DIR := "user://mods/.check"
const MODS_ROOT := "res://mods"
const PACKS := preload("res://tools/build/packs.gd")
const BUNDLED := preload("res://world/modding/bundled_mods.gd")
const ID_PATTERN := "^[a-z0-9_]{1,40}$"
## Marker the build tool adds to a mod's folder inside its pack.
const BUILT := "mod.built.json"
## Bundled packs are listed under this prefix ("bundled/grooming.pck"), so their switches never
## mix with a pack of the same file name in the player's mods folder.
const BUNDLED_PREFIX := "bundled/"
## Game scripts whose replacement breaks new worlds, saving and loading when it is out of date.
const CORE_SCRIPTS := ["res://world/game.gd", "res://world/game_saves.gd"]
## The scenario rules (mod.json "scenario"); loaded when first needed (it preloads this script).
const SCENARIO_PATH := "res://world/modding/scenario.gd"

## Every pack seen this launch: {file, path, enabled, loose, ids, mounted, error, overrides, game_version,
## title, author, version, held, bundled, bundle_id, default_on, superseded_by, reason, patches,
## patch_of, patched_by, covered, update, update_url, declared, scenario_held}. overrides: the game files the pack replaces (read from its
## directory before it mounts); game_version: the oldest game version its mods were made for; held:
## switched off this launch because it is an old mod that replaces game files (see is_old()), or
## its copy of a game script does not compile, or (scenario_held) another scenario mod is on; reason: why it is off or held, for the Mods screen.
## Read it through pack_rows() (the Mods autoload's Mods.pack_rows()), which is the stable shape.
static var packs: Array = []
## Every mod found: {id, name, version, author, description, game_version, entry, extends, depends,
## patches, update_url, scenario ({} or the parsed mod.json "scenario", world/modding/scenario.gd parse()),
## file, bundled, enabled, errors: Array[String]}. Only mods with no errors run.
static var mods: Array = []
static var booted := false
## The bundled-mods folder used this launch ("" when the install has none).
static var bundled_dir := ""
## Where downloaded bundled-mod updates live (tests point it elsewhere).
static var updates_dir := BUNDLED.UPDATES
## Tests: true/false in place of the developer-tools check for debug-only bundled mods (null = check).
static var debug_override: Variant = null

## `bundled`: the bundled-mods folder (null = BUNDLED.dir(); "" = none).
static func boot(dirs: Array = [], loose_dirs: Array = [], disabled_override: Variant = null, bundled: Variant = null) -> void:
	booted = true
	var clock := _Clock.new()
	packs.clear(); mods.clear()
	if dirs.is_empty(): dirs = mod_dirs()
	if loose_dirs.is_empty() and OS.has_feature("template") and not OS.has_feature("android"):
		loose_dirs = [OS.get_executable_path().get_base_dir()]
	var disabled: PackedStringArray = disabled_override if disabled_override is PackedStringArray else disabled_files()
	bundled_dir = str(bundled) if bundled is String else BUNDLED.dir()
	var rows: Array = []
	var dev_tools := debug_mods_allowed()
	for entry: Dictionary in BUNDLED.entries(bundled_dir):
		# D-36: debug-only bundled mods (modChad's teleports) are neither mounted nor listed for players.
		if entry.get("debug_only", false) == true and not dev_tools: continue
		var row := _new_row(BUNDLED_PREFIX + str(entry.file), str(entry.path), false)
		row.bundled = true; row.bundle_id = entry.id; row.default_on = entry.default_on
		row.title = entry.title; row.author = entry.author; row.version = entry.version; row.patches = entry.patches
		row.update_url = entry.update_url; row.caution = str(entry.get("caution", ""))
		var update := BUNDLED.update_for(str(entry.id), str(entry.version), updates_dir)
		if not update.is_empty():
			row.path = update.path; row.version = update.version; row.update = update.source
			print("[mods] %s %s: the downloaded update loads instead of the bundled %s" % [entry.id, update.version, entry.version])
		row.enabled = BUNDLED.is_on(str(entry.id), bool(entry.default_on))
		if not FileAccess.file_exists(str(row.path)):
			row.enabled = false; row.error = "missing from the game folder"
		else: _inspect(row)
		rows.append(row)
	var seen := {}
	for dir: String in dirs + loose_dirs:
		if not DirAccess.dir_exists_absolute(dir): continue
		var names := DirAccess.get_files_at(dir)
		names.sort()
		var loose := dir in loose_dirs
		for name: String in names:
			if name.get_extension().to_lower() != "pck" or seen.has(name) or (loose and PACKS.is_game_pack(name)): continue
			seen[name] = true
			var row := _new_row(name, dir.path_join(name), loose)
			row.enabled = name not in disabled
			_inspect(row)
			rows.append(row)
	clock.mark("inspect %d packs" % rows.size())
	_supersede(rows)
	_link_patches(rows)
	for row: Dictionary in rows: _hold(row)
	var ordered: Array = BUNDLED.mount_order(rows)
	_one_scenario(ordered)
	_settle_patches(rows)
	clock.mark("rules")
	for row: Dictionary in ordered:
		if row.enabled and not row.overrides.is_empty() and not row.held:
			print("[mods] %s replaces %d game file(s): %s" % [row.file, row.overrides.size(), ", ".join(row.overrides.slice(0, 8))])
		packs.append(row)
		if row.enabled: _mount(row)
		clock.mark("mount " + str(row.file), 20.0)
		if row.mounted and row.has("checked"): _refresh_checked(row)
		row.erase("index"); row.erase("checked")
	# Source runs (development, mod authors): `-- --mod-src <id>` runs res://mods/<id> unpacked.
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--mod-src" and i + 1 < args.size() and DirAccess.dir_exists_absolute(MODS_ROOT.path_join(args[i + 1])):
			var row := _new_row("(source) " + args[i + 1], "", false)
			row.ids = [args[i + 1]]; row.mounted = true
			packs.append(row)
	clock.mark("mount")
	for row: Dictionary in packs:
		for id: String in row.ids: mods.append(read_manifest(id, row))
	_one_scenario_mod()
	_check_depends()
	clock.mark("manifests")
	for mod: Dictionary in mods:
		if mod.enabled and mod.errors.is_empty(): print("[mods] %s %s (%s)" % [mod.id, mod.version, mod.file])
		elif not mod.errors.is_empty(): push_warning("[mods] %s not loaded: %s" % [mod.id, "; ".join(mod.errors)])
	apply_merges(active())
	clock.mark("merges")
	apply_extensions(active())
	clock.mark("extensions")

## Boot timings, printed when the environment has EQ_MODS_PROFILE=1.
class _Clock:
	var on := OS.get_environment("EQ_MODS_PROFILE") == "1"
	var last := Time.get_ticks_usec()
	func mark(what: String, over_ms := 0.0) -> void:
		if not on: return
		var now := Time.get_ticks_usec()
		if (now - last) / 1000.0 >= over_ms: print("[mods] boot %s: %.1f ms" % [what, (now - last) / 1000.0])
		last = now

static func _new_row(file: String, path: String, loose: bool) -> Dictionary:
	return {"file": file, "path": path, "enabled": true, "loose": loose, "ids": [], "mounted": false, "error": "",
		"overrides": PackedStringArray(), "game_version": "", "title": "", "author": "", "version": "", "held": false,
		"bundled": false, "bundle_id": "", "default_on": false, "superseded_by": "", "reason": "", "patches": {},
		"patched_by": [], "patch_of": "", "covered": false, "update": "", "update_url": "", "declared": {}, "scenario_held": false, "caution": ""}

## Whether debug-only bundled mods load this launch (world/dev_tools.gd enabled()). Boot runs inside
## Settings._init, before the Settings node exists, so the player's Settings > Updates unlock is read
## from the settings file itself; an unlock made mid-game applies at the next start.
static func debug_mods_allowed() -> bool:
	if debug_override is bool: return debug_override
	var dev: GDScript = load("res://world/dev_tools.gd")
	if dev == null: return false
	if bool(dev.call("enabled")): return true
	var config := ConfigFile.new()
	return config.load("user://settings.cfg") == OK and config.get_value("debug", "unlocked", false) == true

## Mods that load and run this launch.
static func active() -> Array:
	return mods.filter(func(mod: Dictionary) -> bool: return mod.enabled and mod.errors.is_empty())

static func mod_dirs() -> Array:
	var dirs: Array = [ProjectSettings.globalize_path(USER_DIR)]
	if OS.has_feature("template") and not OS.has_feature("android"):
		dirs.append(OS.get_executable_path().get_base_dir().path_join("mods"))
	if OS.has_feature("android"):
		for dir: String in PACKS.android_directories(OS.get_user_data_dir()):
			var mods_dir := dir.path_join("mods")
			if mods_dir not in dirs: dirs.append(mods_dir)
	return dirs


static func disabled_files() -> PackedStringArray:
	var config := ConfigFile.new()
	if config.load(SETTINGS) != OK: return PackedStringArray()
	var value: Variant = config.get_value("mods", "disabled", PackedStringArray())
	return PackedStringArray(value) if value is Array or value is PackedStringArray else PackedStringArray()

## The stable read API for the Mods screen and for mods (Mods.pack_rows()): one Dictionary per
## pack seen this launch, in mount order: {file, ids, title, author, version, bundled, default_on,
## enabled (loaded this launch), mounted, switched_on (the switch for the next launch), switchable (has its
## own On/Off switch; patch packs and superseded packs follow another row), held, superseded_by,
## reason ("" or why it is off, held, or a mod in it does not run), warning ("" or a caution such as
## replacing world/game.gd), overrides, patches {mod id: version}, patch_of (the file of the pack
## this patch pack follows, or ""), patched_by [{file, title, version, bundled}],
## update ("" | "manifest" | "author": a downloaded update is loaded), update_url, game_version, error,
## covered (an enabled patch pack replaces all its game files again, so it is not held as old),
## scenario ({} or {id, name} of the scenario a mod in it declares, world/modding/scenario.gd),
## scenario_held (held because another scenario mod is on), declared ({mod id: {name, version,
## author, scenario}} from the pack's mod.json files, also for a pack that is off), caution ("" or
## the bundled manifest's caution line)}.
static func pack_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row: Dictionary in packs:
		var reason := str(row.reason)
		if reason.is_empty() and not str(row.error).is_empty(): reason = str(row.error)
		if reason.is_empty() and row.enabled:
			for mod: Dictionary in mods:
				if mod.file == row.file and not mod.errors.is_empty():
					reason = "%s does not run: %s" % [mod.name, "; ".join(PackedStringArray(mod.errors))]; break
		var title := str(row.title)
		var author := str(row.author); var version := str(row.version)
		for mod: Dictionary in mods:
			if mod.file != row.file: continue
			if title.is_empty(): title = str(mod.name)
			if author.is_empty(): author = str(mod.author)
			if version.is_empty(): version = str(mod.version)
			break
		if title.is_empty(): title = str(row.file).get_file().get_basename()
		var warning := ""
		var core: Array = CORE_SCRIPTS.filter(func(path: String) -> bool: return path in (row.overrides as PackedStringArray))
		if not core.is_empty(): warning = "Replaces the game's %s: new worlds, saving and loading may break when the game updates." % " and ".join(PackedStringArray(core.map(func(path: String) -> String: return path.trim_prefix("res://"))))
		out.append({"file": row.file, "ids": (row.ids as Array).duplicate() if not (row.ids as Array).is_empty() else (row.declared as Dictionary).keys(),
			"title": title, "author": author, "version": version, "bundled": row.bundled, "default_on": row.default_on,
			"enabled": row.enabled, "mounted": row.mounted, "switched_on": switched_on(str(row.file)), "switchable": switchable(row), "held": row.held,
			"superseded_by": row.superseded_by, "reason": reason, "warning": warning, "overrides": (row.overrides as PackedStringArray).duplicate(),
			"patches": (row.patches as Dictionary).duplicate(), "patch_of": row.patch_of, "patched_by": (row.patched_by as Array).duplicate(true), "update": row.update,
			"update_url": row.update_url, "game_version": row.game_version, "error": row.error, "covered": row.covered,
			"scenario": scenario_of_row(row), "scenario_held": bool(row.get("scenario_held", false)),
			"declared": (row.get("declared", {}) as Dictionary).duplicate(true), "caution": str(row.get("caution", ""))})
	return out

## The scenario a pack declares ({id, name} from its mod.json files), {} when none.
static func scenario_of_row(row: Dictionary) -> Dictionary:
	for mod: Dictionary in mods:
		if mod.file == row.file and mod.get("scenario") is Dictionary and not (mod.scenario as Dictionary).is_empty():
			return {"id": str(mod.scenario.id), "name": str(mod.scenario.name)}
	for id: String in row.get("declared", {}):
		var info: Variant = row.declared[id]
		if info is Dictionary and info.get("scenario") is Dictionary and not (info.scenario as Dictionary).is_empty(): return (info.scenario as Dictionary).duplicate()
	return {}

## One scenario mod at a time (dev 2026-11-08): of the switched-on packs that declare a scenario,
## the first in load order runs; the others are held with a reason (they stay switched on, so the
## player sees why). Runs before mounting, on the scenarios read from the packs' directories.
static func _one_scenario(ordered: Array) -> void:
	var kept: Dictionary = {}
	for row: Dictionary in ordered:
		if not row.enabled: continue
		var scenario := scenario_of_row(row)
		if scenario.is_empty(): continue
		if kept.is_empty(): kept = {"title": row.title if not str(row.title).is_empty() else str(row.file).get_file().get_basename(), "scenario": scenario}; continue
		row.enabled = false; row.held = true; row.scenario_held = true
		row.reason = "Held: %s (%s) is the scenario mod that runs. Only one scenario mod runs at a time; switch that one off to use this one." % [kept.title, kept.scenario.name]
		push_warning("[mods] %s is off: %s" % [row.file, row.reason])

## The same rule for mods found only after mounting (a pack whose directory could not be read,
## `--mod-src` source runs): the later scenario mod gets an error and does not run.
static func _one_scenario_mod() -> void:
	var first := ""
	for mod: Dictionary in mods:
		if not mod.enabled or not mod.errors.is_empty() or not mod.get("scenario") is Dictionary or (mod.scenario as Dictionary).is_empty(): continue
		if first.is_empty(): first = str(mod.scenario.name); continue
		(mod.errors as Array).append("held: the %s scenario mod is on; only one scenario mod runs at a time" % first)

## Whether a pack carries a scenario mod (its switch applies at the next launch only).
static func is_scenario_row(row: Dictionary) -> bool:
	return not scenario_of_row(row).is_empty()

## Whether a pack row has its own On/Off switch: not a source run, not a patch pack (it follows
## the pack it patches), not superseded by another copy of its mod.
static func switchable(row: Dictionary) -> bool:
	return not str(row.file).begins_with("(source)") and str(row.get("patch_of", "")).is_empty() and str(row.get("superseded_by", "")).is_empty()

static func _row(file: String) -> Dictionary:
	for row: Dictionary in packs:
		if row.file == file: return row
	return {}

## Settings → Mods switch. Saves it for the next launch, then applies it now when every mod in the
## pack only runs an entry script: a pack first switched on mid-game is mounted without replacing
## game files, so its own res://mods/<id> files arrive now and any game-file replacements wait for
## the next launch. Packs that extend scripts, merge data, only replace game files or carry a patch
## pack keep their current state until then. Returns true when the mods' enabled flags changed now;
## the Mods autoload then starts or stops their entry scripts. `file` is a pack row's file
## ("bundled/<file>" for a bundled mod).
static func switch(file: String, enabled: bool) -> bool:
	set_enabled(file, enabled)
	var row := _row(file)
	if row.is_empty() or row.enabled == enabled or not switchable(row) or not (row.patched_by as Array).is_empty(): return false
	# A scenario changes how worlds start and which saves load: never mid-game.
	if is_scenario_row(row): return false
	if enabled and not row.mounted:
		var folders := _mod_folders()
		if not ProjectSettings.load_resource_pack(row.path, false):
			row.error = "could not be read as a resource pack"; return false
		row.mounted = true
		var declared: Array = (row.declared as Dictionary).keys()
		for id: String in _mod_folders():
			if (id not in folders or id in declared) and id not in row.ids:
				row.ids.append(id)
				mods.append(read_manifest(id, row))
		_check_depends()
	var list := mods.filter(func(mod: Dictionary) -> bool: return mod.file == file)
	if list.is_empty() or not list.all(_entry_only): return false
	row.enabled = enabled
	for mod: Dictionary in list: mod.enabled = enabled
	return true

static func _entry_only(mod: Dictionary) -> bool:
	return (mod.extends as Array).is_empty() and not DirAccess.dir_exists_absolute(MODS_ROOT.path_join(mod.id).path_join("merge"))

## Saves a Settings → Mods switch for the next launch. Switching on an old mod that replaces game
## files (is_old()) also lets it load for this game version; the next game update asks again.
## A bundled mod's switch is kept by its mod id (bundled_mods.gd set_on()).
static func set_enabled(file: String, enabled: bool) -> void:
	var row := _row(file)
	if not row.is_empty() and row.bundled:
		BUNDLED.set_on(str(row.bundle_id), bool(row.default_on), enabled)
	elif not file.begins_with(BUNDLED_PREFIX):
		var disabled := disabled_files()
		if enabled:
			if file in disabled: disabled.remove_at(disabled.find(file))
		elif file not in disabled: disabled.append(file)
		var list := ConfigFile.new()
		list.load(SETTINGS)
		list.set_value("mods", "disabled", disabled)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(USER_DIR))
		list.save(SETTINGS)
	var config := ConfigFile.new()
	config.load(SETTINGS)
	var allowed := _allowed_old(config)
	if enabled and not row.is_empty() and is_old(row): allowed[file] = game_version()
	else: allowed.erase(file)
	config.set_value("mods", "allowed_old", allowed)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(USER_DIR))
	config.save(SETTINGS)

## Mounts one pack and notes which mods it brought: the mods its directory declares (a
## res://mods/<id>/mod.json in the pack), or, when the directory cannot be read, res://mods/<id>
## folders that are new or that gained a BUILT marker (tools/modding/build_mod.gd writes it into
## the pack only, so a pack built from a source project that also holds res://mods/<id> is still
## recognised).
static func _mount(row: Dictionary) -> void:
	var folders := _mod_folders()
	var built := _built_ids()
	if not ProjectSettings.load_resource_pack(row.path, true):
		row.error = "could not be read as a resource pack"; push_warning("[mods] could not load %s" % row.path); return
	row.mounted = true
	if not (row.declared as Dictionary).is_empty():
		for id: String in row.declared:
			if FileAccess.file_exists(MODS_ROOT.path_join(id).path_join("mod.json")): row.ids.append(id)
		return
	for id: String in _mod_folders():
		if id not in folders or (id not in built and FileAccess.file_exists(MODS_ROOT.path_join(id).path_join(BUILT))): row.ids.append(id)

## Settings → Mods: whether the pack is switched on for the next launch (not switched off, and
## not an old game-file replacer the player has not allowed for this game version). A patch pack
## follows the pack it patches.
static func switched_on(file: String) -> bool:
	var row := _row(file)
	if not str(row.get("patch_of", "")).is_empty(): return switched_on(str(row.patch_of))
	if not row.is_empty() and row.bundled:
		if not BUNDLED.is_on(str(row.bundle_id), bool(row.default_on)): return false
	elif file in disabled_files(): return false
	return row.is_empty() or not is_old(row) or _allowed(file)

## Old mods that replace game files (/mlp/ thread 43671981, 2026-11-03: an old menu and subtitle
## overhaul still mounted after updates hid the spa and the pause menu's Journal button, and
## reinstalling did not help because the mods folder survived). Like an update pack made for
## another version (tools/build/packs.gd patch_fits()), such a pack stays off until the player
## switches it on in Settings → Mods; that choice holds until the next game version. A mod that
## replaces no game file, declares no version, or declares this one is never held back, and
## neither is a pack whose replaced game files are all covered by an enabled patch pack made for
## exactly its version (covered, _link_patches()).
static func is_old(row: Dictionary) -> bool:
	return not bool(row.get("covered", false)) and not (row.get("overrides", PackedStringArray()) as PackedStringArray).is_empty() \
		and version_older(str(row.get("game_version", "")), game_version())

static func game_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", ""))

## True when `a` names an older game version than `b` by their leading numbers ("0.1.0-maredev"
## is older than "0.1.1.1", and equal to "0.1.0"). False when either has no version number.
static func version_older(a: String, b: String) -> bool:
	var x := _version_numbers(a); var y := _version_numbers(b)
	if x.is_empty() or y.is_empty(): return false
	for i in maxi(x.size(), y.size()):
		var p: int = x[i] if i < x.size() else 0
		var q: int = y[i] if i < y.size() else 0
		if p != q: return p < q
	return false

static func _version_numbers(text: String) -> Array:
	var found := RegEx.create_from_string("^\\s*v?(\\d+(?:\\.\\d+)*)").search(text)
	if found == null: return []
	return Array(found.get_string(1).split(".")).map(func(part: String) -> int: return int(part))

## A mod whose author field names the game itself ("Home: Equestria"); the Mods screen says it is
## a third-party mod (thread 43671981: the "Anonfilly (NPC)" mod did this).
static func claims_game_author(author: String) -> bool:
	var plain := RegEx.create_from_string("[^a-z]").sub(author.to_lower(), "", true)
	var game := RegEx.create_from_string("[^a-z]").sub(str(ProjectSettings.get_setting("application/config/name", "Home: Equestria")).to_lower(), "", true)
	return not plain.is_empty() and (plain == game or plain == "homeequestria")

static func _allowed(file: String) -> bool:
	var config := ConfigFile.new()
	if config.load(SETTINGS) != OK: return false
	return str(_allowed_old(config).get(file, "")) == game_version()

static func _allowed_old(config: ConfigFile) -> Dictionary:
	var value: Variant = config.get_value("mods", "allowed_old", {})
	return (value as Dictionary).duplicate() if value is Dictionary else {}

## Reads a pack's directory without mounting it: the game files it replaces, the mods it declares
## (declared: {id: {name, version, author, patches}} from each res://mods/<id>/mod.json), the game
## version its mod.json files declare (or, failing that, the version tools/modding/build_mod.gd
## stamped into its BUILT marker), and the first mod's name, author and version.
static func _inspect(row: Dictionary) -> void:
	var index := pack_index(str(row.path))
	row.index = index
	var manifests := {}   # id -> {json, built}
	var overrides: PackedStringArray = row.overrides
	for path: String in index:
		if path.begins_with(MODS_ROOT + "/"):
			if path.get_base_dir().get_base_dir() == MODS_ROOT and path.get_file() in ["mod.json", BUILT]:
				var id := path.get_base_dir().get_file()
				if not manifests.has(id): manifests[id] = {}
				manifests[id][path.get_file()] = parse(pack_text(str(row.path), index[path]))
			continue
		if path.begins_with("res://.godot/"): continue
		var shown := _game_file(path)
		if not shown.is_empty() and shown not in overrides: overrides.append(shown)
	overrides.sort()
	var ids := manifests.keys(); ids.sort()
	var patches: Dictionary = row.patches
	for id: String in ids:
		var doc: Variant = manifests[id].get("mod.json")
		var built: Variant = manifests[id].get(BUILT)
		var version := ""
		if doc is Dictionary and doc.get("game_version") is String: version = str(doc.game_version).strip_edges()
		if version.is_empty() and built is Dictionary: version = str(built.get("game_version", "")).strip_edges()
		if not version.is_empty() and (str(row.game_version).is_empty() or version_older(version, str(row.game_version))): row.game_version = version
		if not doc is Dictionary: continue
		var info := {"name": str(doc.get("name", id)), "version": str(doc.get("version", "")).strip_edges(), "author": str(doc.get("author", "")), "scenario": {}}
		if doc.get("scenario") is Dictionary and doc.scenario.get("id") is String and RegEx.create_from_string(ID_PATTERN).search(str(doc.scenario.id)) != null:
			info.scenario = {"id": str(doc.scenario.id), "name": str(doc.scenario.get("name", doc.scenario.id)) if doc.scenario.get("name", doc.scenario.id) is String else str(doc.scenario.id)}
		row.declared[id] = info
		if str(row.title).is_empty() and doc.get("name") is String: row.title = str(doc.name).strip_edges()
		if str(row.author).is_empty() and doc.get("author") is String: row.author = str(doc.author).strip_edges()
		if str(row.version).is_empty() or (row.bundled and id == row.bundle_id and not str(info.version).is_empty()): row.version = info.version
		if doc.get("patches") is Dictionary:
			for target: Variant in doc.patches:
				if not patches.has(str(target)): patches[str(target)] = str(doc.patches[target]).strip_edges()

## The version of mod `id` a row carries (its mod.json, else the bundled manifest's).
static func _version_of(row: Dictionary, id: String) -> String:
	var info: Variant = (row.declared as Dictionary).get(id)
	if info is Dictionary and not str(info.version).is_empty(): return str(info.version)
	return str(row.version) if row.bundled and row.bundle_id == id else ""

static func _ids_of(row: Dictionary) -> Array:
	var out: Array = (row.declared as Dictionary).keys()
	if row.bundled and str(row.bundle_id) not in out: out.append(str(row.bundle_id))
	return out

## A bundled mod and a pack the player installed with the same mod id: the higher version loads;
## the other is not mounted and says "superseded by <title> <version>". Equal versions keep the
## bundled one.
static func _supersede(rows: Array) -> void:
	for user: Dictionary in rows:
		if user.bundled: continue
		for bundled: Dictionary in rows:
			if not bundled.bundled or not str(bundled.superseded_by).is_empty(): continue
			for id: String in _ids_of(user):
				if id not in _ids_of(bundled): continue
				var mine := _version_of(user, id); var theirs := _version_of(bundled, id)
				var loser: Dictionary = bundled if BUNDLED.newer(mine, theirs) else user
				var winner: Dictionary = user if loser == bundled else bundled
				loser.superseded_by = "%s %s" % [winner.title, _version_of(winner, id)]
				loser.enabled = false
				loser.reason = "Superseded by %s %s%s." % [winner.title, _version_of(winner, id), " (bundled with the game)" if winner.bundled else " (in your mods folder)"]
				break
			if not str(user.superseded_by).is_empty(): break

## Patch packs: each finds the pack it patches (the copy of that mod that is not superseded). It
## loads only while that pack is on and carries exactly the version it was made for; a pack whose
## replaced game files are all replaced again by such a patch is "covered" and never held as old.
static func _link_patches(rows: Array) -> void:
	for patch: Dictionary in rows:
		var targets: Dictionary = patch.patches
		if targets.is_empty(): continue
		for target: String in targets:
			var parent: Dictionary = {}
			for row: Dictionary in rows:
				if row != patch and target in _ids_of(row) and str(row.superseded_by).is_empty(): parent = row; break
			if parent.is_empty():
				patch.reason = "Patch for %s %s, which is not installed." % [target, targets[target]]
				patch.enabled = false; continue
			patch.patch_of = parent.file
			(parent.patched_by as Array).append({"file": patch.file, "title": patch.title, "version": patch.version, "bundled": patch.bundled})
			var found := _version_of(parent, target)
			if patch.bundled: patch.enabled = bool(parent.enabled)
			else: patch.enabled = patch.enabled and bool(parent.enabled)
			if not BUNDLED.satisfies(found, "=" + str(targets[target])):
				patch.enabled = false
				patch.reason = "Made for %s %s; %s is installed, so it stays off." % [parent.title, targets[target], found if not found.is_empty() else "another version"]
			elif not parent.enabled:
				patch.reason = "Off while %s is off." % parent.title
			elif patch.enabled and not is_old(patch):
				var mine: PackedStringArray = patch.overrides
				if not (parent.overrides as PackedStringArray).is_empty() and Array(parent.overrides).all(func(path: String) -> bool: return path in mine):
					parent.covered = true
			break

## After holding: a patch pack whose parent was held stays off with it.
static func _settle_patches(rows: Array) -> void:
	for patch: Dictionary in rows:
		if str(patch.patch_of).is_empty(): continue
		for parent: Dictionary in rows:
			if parent.file == patch.patch_of and not parent.enabled and patch.enabled:
				patch.enabled = false
				patch.reason = "Off while %s is held: %s" % [parent.title, parent.reason]

## Old packs that replace game files: held off unless the player allowed them for this game
## version; an allowed one whose copies of game scripts do not compile any more is held too.
static func _hold(row: Dictionary) -> void:
	if not row.enabled or not is_old(row): return
	if not _allowed(str(row.file)):
		row.enabled = false; row.held = true
		row.reason = "Made for game %s (this is %s) and replaces %d game file(s). Kept off; switch it on to use it anyway." % [row.game_version, game_version(), row.overrides.size()]
		push_warning("[mods] %s is off: made for game %s (this is %s) and replaces %d game file(s): %s. Switch it on in Settings → Mods to use it anyway." % [row.file, row.game_version, game_version(), row.overrides.size(), ", ".join(row.overrides.slice(0, 8))])
		return
	row.checked = true
	var broken := compile_check(row)
	if broken.is_empty(): return
	row.enabled = false; row.held = true
	row.reason = "Kept off: its copy of %s does not work with this game version." % broken.trim_prefix("res://")
	push_warning("[mods] %s is off: its copy of %s does not work with this game version (%s)" % [row.file, broken, game_version()])

## Compiles each game script an old pack replaces from the pack's own text, before the pack
## replaces anything. The pack's new files (paths the game does not have) are mounted first, copied
## into a small pack of their own, so the copies can reach them; nothing at a game path changes.
## (load_resource_pack(replace_files = false) is not enough: in a source run the game's files are
## not in a pack, so it would replace them.) Returns the first script that does not compile, or "".
## Copies kept only as binary tokens cannot be checked and pass.
static func compile_check(row: Dictionary) -> String:
	var index: Dictionary = row.get("index", {})
	var scripts: Array = []
	for path: String in row.overrides:
		if path.get_extension() != "gd": continue
		var text := ""
		if index.has(path): text = pack_text(str(row.path), index[path])
		if not text.is_empty(): scripts.append([path, text])
	if scripts.is_empty(): return ""
	_mount_new_files(row)
	for item: Array in scripts:
		var check := GDScript.new()
		check.source_code = RegEx.create_from_string("(?m)^class_name\\s+\\w+\\s*").sub(str(item[1]), "", true)
		if check.reload() != OK: return str(item[0])
	return ""

## Mounts the files of a pack that the game does not have (none of its replacements) as a pack of
## their own in user://mods/.check/.
static func _mount_new_files(row: Dictionary) -> void:
	var index: Dictionary = row.get("index", {})
	var source := FileAccess.open(str(row.path), FileAccess.READ)
	if source == null: return
	var folder := ProjectSettings.globalize_path(CHECK_DIR)
	DirAccess.make_dir_recursive_absolute(folder)
	var target := folder.path_join("%d.pck" % _serial); _serial += 1
	var packer := PCKPacker.new()
	if packer.pck_start(target) != OK: return
	var n := 0
	for path: String in index:
		var entry: Array = index[path]
		if (int(entry[2]) & 3) != 0 or FileAccess.file_exists(path) or not _game_file(path).is_empty(): continue
		source.seek(int(entry[0]))
		var copy := folder.path_join("%s_%d" % [target.get_file().get_basename(), n]); n += 1
		var file := FileAccess.open(copy, FileAccess.WRITE)
		if file == null: continue
		file.store_buffer(source.get_buffer(int(entry[1]))); file.close()
		packer.add_file(path, copy)
	packer.flush()
	if n > 0: ProjectSettings.load_resource_pack(target, true)

## A compile check (compile_check()) may have loaded game scripts this pack replaces; once the pack
## is mounted, those cached scripts are recompiled from the pack's copies so they do not shadow them.
static func _refresh_checked(row: Dictionary) -> void:
	var index: Dictionary = row.get("index", {})
	for path: String in row.overrides:
		if path.get_extension() != "gd" or not index.has(path) or not ResourceLoader.has_cached(path): continue
		var script := ResourceLoader.get_cached_ref(path) as GDScript
		var text := pack_text(str(row.path), index[path])
		if script == null or text.is_empty(): continue
		script.source_code = text
		if script.reload() != OK: push_warning("[mods] %s: %s did not recompile from the pack" % [row.file, path])

## The game file a pack path replaces, or "" when the game has none there. Exported games keep
## scripts as .gdc behind a .remap and assets behind a .import, so either form counts.
static func _game_file(path: String) -> String:
	var base := path.trim_suffix(".remap").trim_suffix(".import")
	if base.get_extension() == "gdc": base = base.get_basename() + ".gd"
	for candidate: String in [base, base + ".remap", base + ".import"]:
		if FileAccess.file_exists(candidate): return base
	if base.get_extension() == "gd" and FileAccess.file_exists(base.get_basename() + ".gdc"): return base
	return ""

## A pack's directory, {res:// path: [offset, size, flags]}, read from its header (Godot's
## PackedSourcePCK format 2 and 3); empty when the file is not a plain pack or its directory is
## encrypted.
static func pack_index(path: String) -> Dictionary:
	var out := {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 40 or file.get_32() != 0x43504447: return out   # "GDPC"
	var format := file.get_32()
	file.get_32(); file.get_32(); file.get_32()   # Godot version
	var flags := file.get_32()
	if format < 2 or format > 3 or (flags & 1) != 0: return out
	var base := file.get_64()   # the pack starts at 0, so a relative file base needs no shift
	if format == 3: file.seek(file.get_64())
	else:
		for i in 16: file.get_32()
	var count := file.get_32()
	if count > 1000000: return out
	for i in count:
		var length := file.get_32()
		if length > 4096 or file.eof_reached(): break
		var bytes := file.get_buffer(length)
		var end := bytes.find(0)
		var name := (bytes.slice(0, end) if end >= 0 else bytes).get_string_from_utf8()
		var offset := file.get_64(); var size := file.get_64()
		file.get_buffer(16)   # md5
		var file_flags := file.get_32()
		if not name.begins_with("res://"): name = "res://" + name
		out[name] = [base + offset, size, file_flags]
	return out

## The text of one file in a pack's directory (pack_index()), or "" when it is encrypted or a
## removal entry.
static func pack_text(path: String, entry: Array) -> String:
	if (int(entry[2]) & 3) != 0 or int(entry[1]) > 1 << 20: return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return ""
	file.seek(int(entry[0]))
	return file.get_buffer(int(entry[1])).get_string_from_utf8()

static func _built_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for id: String in _mod_folders():
		if FileAccess.file_exists(MODS_ROOT.path_join(id).path_join(BUILT)): out.append(id)
	return out

static func _mod_folders() -> PackedStringArray:
	return DirAccess.get_directories_at(MODS_ROOT) if DirAccess.dir_exists_absolute(MODS_ROOT) else PackedStringArray()

static func read_manifest(id: String, row: Dictionary) -> Dictionary:
	var mod := {"id": id, "name": id, "version": "", "author": "", "description": "", "game_version": "",
		"entry": "", "extends": [], "depends": {}, "patches": {}, "update_url": "", "scenario": {}, "file": row.file,
		"bundled": bool(row.get("bundled", false)), "enabled": row.enabled, "errors": []}
	var errors: Array = mod.errors
	var regex := RegEx.create_from_string(ID_PATTERN)
	if regex.search(id) == null: errors.append("folder name must be lower-case letters, digits or _")
	var path := MODS_ROOT.path_join(id).path_join("mod.json")
	var doc: Variant = parse(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	if not doc is Dictionary: errors.append("no readable %s" % path); return mod
	for key: String in ["name", "version", "author", "description", "game_version", "entry"]:
		if doc.has(key):
			if doc[key] is String: mod[key] = str(doc[key]).strip_edges()
			else: errors.append("%s must be text" % key)
	if doc.has("id") and str(doc.id) != id: errors.append("id \"%s\" does not match its folder" % str(doc.id))
	if doc.has("extends"):
		if doc.extends is Array and (doc.extends as Array).all(func(p: Variant) -> bool: return p is String): mod.extends = doc.extends.duplicate()
		else: errors.append("extends must be a list of script paths")
	# Dependencies and patch targets: {"<mod id>": "<version spec>"} (bundled_mods.gd satisfies()).
	for key: String in ["depends", "patches"]:
		if not doc.has(key): continue
		if doc[key] is Dictionary and (doc[key] as Dictionary).keys().all(func(k: Variant) -> bool: return regex.search(str(k)) != null) \
				and (doc[key] as Dictionary).values().all(func(v: Variant) -> bool: return v is String):
			mod[key] = (doc[key] as Dictionary).duplicate()
		else: errors.append("%s must map mod ids to versions, like {\"other_mod\": \">=1.0.0\"}" % key)
	if doc.get("update_url") is String and str(doc.update_url).begins_with("https://"): mod.update_url = str(doc.update_url)
	# A scenario (world/modding/scenario.gd): a broken one stops the mod, like a broken entry.
	if doc.has("scenario"):
		var scenario_script := load(SCENARIO_PATH) as GDScript
		var parsed: Dictionary = scenario_script.call("parse", doc.scenario, id) if scenario_script != null else {"scenario": {}, "error": "scenario support is missing"}
		if not str(parsed.error).is_empty(): errors.append(str(parsed.error))
		else: mod.scenario = parsed.scenario
	# Any other key is the mod's own business (or a newer game's): ignored.
	if not str(mod.entry).is_empty() and not ResourceLoader.exists(str(mod.entry)): errors.append("entry %s is missing" % mod.entry)
	return mod

## mod.json "depends": a mod whose dependency is not running, or runs an older version than it
## needs, gets an error and does not run (repeated until stable: that can stop its dependants).
static func _check_depends() -> void:
	var changed := true
	while changed:
		changed = false
		var running := {}
		for mod: Dictionary in mods:
			if mod.enabled and mod.errors.is_empty(): running[mod.id] = str(mod.version)
		for mod: Dictionary in mods:
			if not mod.enabled or not mod.errors.is_empty(): continue
			for id: String in mod.depends:
				var spec := str(mod.depends[id])
				var need := "needs %s%s" % [id, (" " + spec) if not spec.strip_edges().is_empty() and spec != "*" else ""]
				if not running.has(id):
					var present := mods.any(func(other: Dictionary) -> bool: return other.id == id)
					mod.errors.append(need + (" (it is switched off or not loaded)" if present else " (not installed)"))
				elif not BUNDLED.satisfies(str(running[id]), spec):
					mod.errors.append(need + " (%s is installed)" % running[id])
				else: continue
				changed = true
				break

## Deep-merges each mod's res://mods/<id>/merge/<path>.json over the game's res://<path>.json
## (dictionaries merge key by key, lists append, anything else replaces; later mods win) and mounts
## the results as one more pack, so every reader sees the merged data.
static func apply_merges(list: Array) -> void:
	var merged := {}   # res:// target -> Variant
	for mod: Dictionary in list:
		var root := MODS_ROOT.path_join(mod.id).path_join("merge")
		for source: String in _files_under(root):
			if source.get_extension().to_lower() != "json": continue
			var target := "res://" + source.trim_prefix(root + "/")
			var patch: Variant = parse(FileAccess.get_file_as_string(source))
			if patch == null: push_warning("[mods] %s: %s is not valid JSON" % [mod.id, source]); continue
			var base: Variant = merged.get(target, JSON.parse_string(FileAccess.get_file_as_string(target)) if FileAccess.file_exists(target) else null)
			merged[target] = deep_merge(base, patch)
	if merged.is_empty(): return
	var folder := ProjectSettings.globalize_path(MERGED)
	DirAccess.make_dir_recursive_absolute(folder)
	var packer := PCKPacker.new()
	var pack := folder.path_join("merged.pck")
	if packer.pck_start(pack) != OK: push_warning("[mods] could not write %s" % pack); return
	var n := 0
	for target: String in merged:
		var file_path := folder.path_join("%d.json" % n); n += 1
		var file := FileAccess.open(file_path, FileAccess.WRITE)
		if file == null: continue
		file.store_string(JSON.stringify(merged[target], "\t")); file.close()
		packer.add_file(target, file_path)
	packer.flush()
	if not ProjectSettings.load_resource_pack(pack, true): push_warning("[mods] could not mount merged data")
	else: print("[mods] merged %d data file(s)" % merged.size())

## JSON text, or null when it is not valid (quietly: a broken mod must not flood the log).
static func parse(text: String) -> Variant:
	var json := JSON.new()
	return json.data if json.parse(text) == OK else null

static func deep_merge(base: Variant, patch: Variant) -> Variant:
	if base is Dictionary and patch is Dictionary:
		var out: Dictionary = (base as Dictionary).duplicate(true)
		for key: Variant in patch: out[key] = deep_merge(out.get(key), patch[key])
		return out
	if base is Array and patch is Array: return (base as Array) + (patch as Array)
	return patch

## Script extensions: each listed script `extends "res://<game script>"` and takes over that path,
## so everything that loads the game script afterwards gets the mod's subclass. Two mods extending
## one script chain in load order. Scripts already loaded before boot() (Settings' own preloads,
## XR tools) cannot be extended.
##
## A plain take_over_path() left the subclass named after the mod's file while the parser read
## the game's file for that path, so every later `preload()` of the game script failed to parse
## (player board #40). Instead what stands at the game path is copied to BASES as N.gd, the mod's
## source is compiled at the game path extending that copy, and preloads find the class they expect.
## In an exported game the game script is binary tokens (x.gdc behind x.gd.remap): the copy is
## then N.gdc behind an N.gd.remap and the mod extends N.gd, the way the exported game reaches its
## own scripts (Godot names a script's class after its .gd path, so extending "N.gdc" directly
## cannot compile; the remap technique comes from HorseBucker's Watch Party loader, ported here).
## A copy never keeps the game script's global class_name: source copies drop the line, token
## copies rename the class (_tokens_renamed()). When an extension cannot compile, the game script
## stays the game's own, every extension that mod already applied is undone, and the mod gets the
## error "could not extend <path> in this build" and does not run. A listed script that extends
## no script path (a mod's own boot script) is only loaded, as before. Relative paths in an
## extending script resolve against the game path.
const BASES := "user://mods/.bases"
## The resource cache does not own what it lists: an extension nothing references is freed and
## the next load() reads the game script from disk again.
static var extensions: Array[Script] = []
## Numbers the copies across boots in one run, so a new copy never meets a cached older one.
static var _serial := 0

static func apply_extensions(list: Array) -> void:
	var standing := {}   # game path -> [source text compiled there, Script]
	for mod: Dictionary in list:
		var applied: Array = []   # [target, previous standing entry or null, own path, Script]
		var failed := ""
		# mod.extends is read live: a mod's earlier extension may reorder later lists (homestead).
		for path: String in mod.extends:
			var text := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
			var target := _extends_target(text, path)
			if text.is_empty() or target.is_empty():
				var script := load(path) as Script
				var base: Script = script.get_base_script() if script != null else null
				if base == null or base.resource_path.is_empty():
					push_warning("[mods] %s: %s does not extend a game script" % [mod.id, path]); continue
				failed = "could not extend %s in this build (%s has no source text)" % [base.resource_path, path]; break
			var index := _serial; _serial += 1
			var before: Resource = ResourceLoader.get_cached_ref(target) if ResourceLoader.has_cached(target) else null
			var result: Variant = _compile_at(text, target, standing, index, before)
			if result is String:
				failed = "could not extend %s in this build (%s)" % [target, result]; break
			var previous: Variant = standing.get(target)
			standing[target] = [_with_head(text, BASES.path_join("%d.gd" % index)), result]
			applied.append([target, previous, BASES.path_join("%d_extension.gd" % index), result, before])
			print("[mods] %s extends %s" % [mod.id, target])
		if failed.is_empty():
			for item: Array in applied: extensions.append(item[3])
			continue
		# Undo this mod's extensions, newest first: each game path gets back what stood there.
		applied.reverse()
		for item: Array in applied:
			if item[1] is Array: standing[item[0]] = item[1]
			else: standing.erase(item[0])
			if item[4] != null: (item[4] as Resource).take_over_path(str(item[0]))
			else: (item[3] as Script).take_over_path(str(item[2]))
		(mod.errors as Array).append(failed)
		push_warning("[mods] %s not loaded: %s; the game's scripts are unchanged" % [mod.id, failed])

## The res:// path a script's source extends by path, resolved against the script's folder; "".
static func _extends_target(text: String, path: String) -> String:
	var found := RegEx.create_from_string("(?m)^extends\\s+[\"']([^\"']+)[\"']").search(text)
	if found == null: return ""
	var target := found.get_string(1)
	if not target.begins_with("res://"): target = path.get_base_dir().path_join(target).simplify_path()
	return target

## The source with its `extends "<game path>"` line pointing at `base` instead.
static func _with_head(text: String, base: String) -> String:
	var found := RegEx.create_from_string("(?m)^extends\\s+[\"']([^\"']+)[\"']").search(text)
	if found == null: return text
	return text.substr(0, found.get_start()) + 'extends "%s"' % base + text.substr(found.get_end())

## Compiles the mod's source at `target` over a copy of what stands there now. Returns the compiled
## Script, or a String saying why it could not (nothing at `target` has changed then: `before`, the
## script cached there, gets its path back).
static func _compile_at(text: String, target: String, standing: Dictionary, index: int, before: Resource) -> Variant:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BASES))
	var copy := _copy_base(target, standing, index)
	if copy.is_empty(): return "the game's script cannot be read"
	# Loaded from a file first so GDScript's own cache holds it; taking over the path then moves
	# that cache entry onto the game path (a new GDScript() would leave the game script there),
	# and the reload compiles it under the game path's class name.
	var own := BASES.path_join("%d_extension.gd" % index)
	if not _write(own, _with_head(text, copy)): return "cannot write %s" % own
	var sub := ResourceLoader.load(own, "", ResourceLoader.CACHE_MODE_REPLACE) as GDScript
	if sub == null: return "the extension did not compile"
	sub.take_over_path(target)
	if sub.reload() != OK:
		# Gives the game path back: what stood there, else the game's own script loads from disk.
		if before != null: before.take_over_path(target)
		else: sub.take_over_path(own)
		return "the extension did not compile over it"
	return sub

## Copies what stands at `target` now to BASES/N.gd: as source (an earlier mod's extension, a
## source run, or a pack that replaced the file with source), else as binary tokens N.gdc behind
## N.gd.remap. Returns "user://mods/.bases/N.gd", or "" when the script cannot be read.
static func _copy_base(target: String, standing: Dictionary, index: int) -> String:
	var copy := BASES.path_join("%d.gd" % index)
	var tokens := BASES.path_join("%d.gdc" % index)
	if FileAccess.file_exists(copy + ".remap"): DirAccess.remove_absolute(ProjectSettings.globalize_path(copy + ".remap"))
	if standing.has(target): return copy if _write(copy, _without_class_name(str(standing[target][0]))) else ""
	var real := target
	if FileAccess.file_exists(target + ".remap"):
		var remap := ConfigFile.new()
		if remap.load(target + ".remap") == OK: real = str(remap.get_value("remap", "path", target))
	elif not FileAccess.file_exists(target) and FileAccess.file_exists(target.get_basename() + ".gdc"):
		real = target.get_basename() + ".gdc"
	if real.get_extension() == "gdc":
		var bytes := _tokens_renamed(FileAccess.get_file_as_bytes(real), _global_name(target))
		if bytes.is_empty(): return ""
		var file := FileAccess.open(tokens, FileAccess.WRITE)
		if file == null: return ""
		file.store_buffer(bytes); file.close()
		return copy if _write(copy + ".remap", "[remap]\n\npath=\"%s\"\n" % tokens) else ""
	var source := FileAccess.get_file_as_string(real)
	if source.is_empty(): return ""
	return copy if _write(copy, _without_class_name(source)) else ""

## The global class_name the game declares at `path` ("" when none).
static func _global_name(path: String) -> String:
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		if str(entry.get("path", "")) == path: return str(entry.get("class", ""))
	return ""

## A copy must not claim the game script's global class name.
static func _without_class_name(text: String) -> String:
	return RegEx.create_from_string("(?m)^class_name\\s+\\w+\\s*").sub(text, "", true)

## Binary tokens (Godot 4.5 GDScriptTokenizerBuffer: "GDSC", version, decompressed size, then
## the zstd-compressed or plain contents: four u32 counts (identifiers, constants, lines, tokens),
## then the identifiers, each a u32 length and UTF-32 characters xor 0xb6; checked against a 4.5
## export, tools/modding/fixtures/loader/exported/) with the identifier `class_name`
## renamed to <name>__mod_base everywhere the script uses it, so the copy compiles under its own
## path (Godot refuses a script that "hides a global script class"). Returned uncompressed when
## renamed, unchanged when `class_name` is ""; [] when they cannot be read.
static func _tokens_renamed(bytes: PackedByteArray, class_name_: String) -> PackedByteArray:
	if bytes.size() < 12 or bytes.slice(0, 4).get_string_from_ascii() != "GDSC": return PackedByteArray()
	if class_name_.is_empty(): return bytes
	var size := bytes.decode_u32(8)
	var contents := bytes.slice(12) if size == 0 else bytes.slice(12).decompress(size, FileAccess.COMPRESSION_ZSTD)
	if contents.size() < 16: return PackedByteArray()
	var count := contents.decode_u32(0)
	var at := 16
	for i in count:
		if at + 4 > contents.size(): return PackedByteArray()
		var length := contents.decode_u32(at)
		if at + 4 + length * 4 > contents.size(): return PackedByteArray()
		var name := ""
		for j in length:
			var code := 0
			for k in 4: code |= (contents[at + 4 + j * 4 + k] ^ 0xb6) << (8 * k)
			name += String.chr(code)
		if name != class_name_:
			at += 4 + length * 4; continue
		var renamed := (name + "__mod_base").to_utf32_buffer()
		var encoded := PackedByteArray()
		encoded.resize(4); encoded.encode_u32(0, renamed.size() >> 2)
		for b in renamed: encoded.append(b ^ 0xb6)
		var out := bytes.slice(0, 8)
		out.append_array(PackedByteArray([0, 0, 0, 0]))
		out.append_array(contents.slice(0, at))
		out.append_array(encoded)
		out.append_array(contents.slice(at + 4 + length * 4))
		return out
	return bytes

static func _write(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_string(text)
	file.close()
	return true

static func _escape(text: String) -> String:
	var out := ""
	for c in text: out += ("\\" + c) if c in ".^$*+?()[]{}|\\/" else c
	return out

static func _files_under(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir): return out
	for name: String in DirAccess.get_files_at(dir): out.append(dir.path_join(name))
	for sub: String in DirAccess.get_directories_at(dir): out.append_array(_files_under(dir.path_join(sub)))
	return out
