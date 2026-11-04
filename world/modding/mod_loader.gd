extends RefCounted
## Mods (dev 2026-10-26: "anything moddable. ANYTHING"). A mod is a resource pack (.pck) that
## carries res://mods/<id>/mod.json and anything else. Settings._init calls boot() right after
## the game's own packs (tools/build/packs.gd) and before any other game script loads, so a mod can:
## - replace any game file (a file in the pack at the game's own path; fragile across updates),
## - deep-merge JSON into game data (res://mods/<id>/merge/<path under res://>),
## - extend any game script (mod.json "extends": scripts that `extends "res://<game script>"`),
## - run its own code (mod.json "entry": a Node the Mods autoload adds, world/modding/mods.gd).
## Packs come from the mods folders (user://mods/, and mods/ beside the executable) and, as
## before, loose .pck files beside the executable that are not the game's own. They load in file
## name order, after the game's packs. Switches in Settings → Mods are kept in user://mods/mods.cfg
## and apply at once for mods that only run an entry script (switch()); anything else applies on
## the next launch. Guide for modders and their AI agents: res://mods/README.md,
## res://mods/AGENTS.md (source repository only).

const USER_DIR := "user://mods"
const SETTINGS := "user://mods/mods.cfg"
const MERGED := "user://mods/.merged"
const MODS_ROOT := "res://mods"
const PACKS := preload("res://tools/build/packs.gd")
const ID_PATTERN := "^[a-z0-9_]{1,40}$"
## Marker the build tool adds to a mod's folder inside its pack.
const BUILT := "mod.built.json"

## Every pack seen this launch: {file, path, enabled, loose, ids, mounted, error, overrides, game_version,
## title, held}. overrides: the game files the pack replaces (read from its directory before it
## mounts); game_version: the oldest game version its mods were made for; held: switched off this
## launch because it is an old mod that replaces game files (see is_old()).
static var packs: Array = []
## Every mod found: {id, name, version, author, description, game_version, entry, extends, file,
## enabled, errors: Array[String]}. Only mods with no errors run.
static var mods: Array = []
static var booted := false

static func boot(dirs: Array = [], loose_dirs: Array = [], disabled_override: Variant = null) -> void:
	booted = true
	packs.clear(); mods.clear()
	if dirs.is_empty(): dirs = mod_dirs()
	if loose_dirs.is_empty() and OS.has_feature("template") and not OS.has_feature("android"):
		loose_dirs = [OS.get_executable_path().get_base_dir()]
	var disabled: PackedStringArray = disabled_override if disabled_override is PackedStringArray else disabled_files()
	var seen := {}
	for dir: String in dirs + loose_dirs:
		if not DirAccess.dir_exists_absolute(dir): continue
		var names := DirAccess.get_files_at(dir)
		names.sort()
		var loose := dir in loose_dirs
		for name: String in names:
			if name.get_extension().to_lower() != "pck" or seen.has(name) or (loose and PACKS.is_game_pack(name)): continue
			seen[name] = true
			var row := {"file": name, "path": dir.path_join(name), "enabled": name not in disabled, "loose": loose, "ids": [], "mounted": false, "error": "",
				"overrides": PackedStringArray(), "game_version": "", "title": "", "held": false}
			_inspect(row)
			if row.enabled and is_old(row) and not _allowed(name):
				row.enabled = false; row.held = true
				push_warning("[mods] %s is off: made for game %s (this is %s) and replaces %d game file(s): %s. Switch it on in Settings → Mods to use it anyway." % [name, row.game_version, game_version(), row.overrides.size(), ", ".join(row.overrides.slice(0, 8))])
			elif row.enabled and not row.overrides.is_empty():
				print("[mods] %s replaces %d game file(s): %s" % [name, row.overrides.size(), ", ".join(row.overrides.slice(0, 8))])
			packs.append(row)
			if row.enabled: _mount(row)
	# Source runs (development, mod authors): `-- --mod-src <id>` runs res://mods/<id> unpacked.
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--mod-src" and i + 1 < args.size() and DirAccess.dir_exists_absolute(MODS_ROOT.path_join(args[i + 1])):
			var row := {"file": "(source) " + args[i + 1], "path": "", "enabled": true, "loose": false, "ids": [args[i + 1]], "mounted": true, "error": "",
				"overrides": PackedStringArray(), "game_version": "", "title": "", "held": false}
			packs.append(row)
	for row: Dictionary in packs:
		for id: String in row.ids: mods.append(read_manifest(id, row))
	for mod: Dictionary in mods:
		if mod.enabled and mod.errors.is_empty(): print("[mods] %s %s (%s)" % [mod.id, mod.version, mod.file])
		elif not mod.errors.is_empty(): push_warning("[mods] %s not loaded: %s" % [mod.id, "; ".join(mod.errors)])
	apply_merges(active())
	apply_extensions(active())

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

## Settings → Mods switch. Saves it for the next launch, then applies it now when every mod in the
## pack only runs an entry script: a pack first switched on mid-game is mounted without replacing
## game files, so its own res://mods/<id> files arrive now and any game-file replacements wait for
## the next launch. Packs that extend scripts, merge data or only replace game files keep their
## current state until then. Returns true when the mods' enabled flags changed now; the Mods
## autoload then starts or stops their entry scripts.
static func switch(file: String, enabled: bool) -> bool:
	set_enabled(file, enabled)
	var found := packs.filter(func(row: Dictionary) -> bool: return row.file == file)
	if found.is_empty(): return false
	var row: Dictionary = found[0]
	if row.enabled == enabled: return false
	if enabled and not row.mounted:
		var folders := _mod_folders()
		if not ProjectSettings.load_resource_pack(row.path, false):
			row.error = "could not be read as a resource pack"; return false
		row.mounted = true
		for id: String in _mod_folders():
			if id not in folders:
				row.ids.append(id)
				mods.append(read_manifest(id, row))
	var list := mods.filter(func(mod: Dictionary) -> bool: return mod.file == file)
	if list.is_empty() or not list.all(_entry_only): return false
	row.enabled = enabled
	for mod: Dictionary in list: mod.enabled = enabled
	return true

static func _entry_only(mod: Dictionary) -> bool:
	return (mod.extends as Array).is_empty() and not DirAccess.dir_exists_absolute(MODS_ROOT.path_join(mod.id).path_join("merge"))

## Saves a Settings → Mods switch for the next launch. Switching on an old mod that replaces game
## files (is_old()) also lets it load for this game version; the next game update asks again.
static func set_enabled(file: String, enabled: bool) -> void:
	var disabled := disabled_files()
	if enabled:
		if file in disabled: disabled.remove_at(disabled.find(file))
	elif file not in disabled: disabled.append(file)
	var config := ConfigFile.new()
	config.load(SETTINGS)
	config.set_value("mods", "disabled", disabled)
	var allowed := _allowed_old(config)
	if enabled and packs.any(func(row: Dictionary) -> bool: return row.file == file and is_old(row)): allowed[file] = game_version()
	else: allowed.erase(file)
	config.set_value("mods", "allowed_old", allowed)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(USER_DIR))
	config.save(SETTINGS)

## Mounts one pack and notes which mods it brought: res://mods/<id> folders that are new, or that
## gained a BUILT marker (tools/modding/build_mod.gd writes it into the pack only, so a pack built
## from a source project that also holds res://mods/<id> is still recognised).
static func _mount(row: Dictionary) -> void:
	var folders := _mod_folders()
	var built := _built_ids()
	if not ProjectSettings.load_resource_pack(row.path, true):
		row.error = "could not be read as a resource pack"; push_warning("[mods] could not load %s" % row.path); return
	row.mounted = true
	for id: String in _mod_folders():
		if id not in folders or (id not in built and FileAccess.file_exists(MODS_ROOT.path_join(id).path_join(BUILT))): row.ids.append(id)

## Settings → Mods: whether the pack is switched on for the next launch (not switched off, and
## not an old game-file replacer the player has not allowed for this game version).
static func switched_on(file: String) -> bool:
	if file in disabled_files(): return false
	var found := packs.filter(func(row: Dictionary) -> bool: return row.file == file)
	return found.is_empty() or not is_old(found[0]) or _allowed(file)

## Old mods that replace game files (/mlp/ thread 43671981, 2026-11-03: an old menu and subtitle
## overhaul still mounted after updates hid the spa and the pause menu's Journal button, and
## reinstalling did not help because the mods folder survived). Like an update pack made for
## another version (tools/build/packs.gd patch_fits()), such a pack stays off until the player
## switches it on in Settings → Mods; that choice holds until the next game version. A mod that
## replaces no game file, declares no version, or declares this one is never held back.
static func is_old(row: Dictionary) -> bool:
	return not (row.get("overrides", PackedStringArray()) as PackedStringArray).is_empty() \
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

## Reads a pack's directory without mounting it: the game files it replaces, the game version its
## mod.json files declare (or, failing that, the version tools/modding/build_mod.gd stamped into
## its BUILT marker), and the first mod's name.
static func _inspect(row: Dictionary) -> void:
	var index := pack_index(str(row.path))
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
	for id: String in ids:
		var doc: Variant = manifests[id].get("mod.json")
		var built: Variant = manifests[id].get(BUILT)
		var version := ""
		if doc is Dictionary and doc.get("game_version") is String: version = str(doc.game_version).strip_edges()
		if version.is_empty() and built is Dictionary: version = str(built.get("game_version", "")).strip_edges()
		if not version.is_empty() and (str(row.game_version).is_empty() or version_older(version, str(row.game_version))): row.game_version = version
		if str(row.title).is_empty() and doc is Dictionary and doc.get("name") is String: row.title = str(doc.name).strip_edges()

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
		"entry": "", "extends": [], "file": row.file, "enabled": row.enabled, "errors": []}
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
	if not str(mod.entry).is_empty() and not ResourceLoader.exists(str(mod.entry)): errors.append("entry %s is missing" % mod.entry)
	return mod

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
## (player board #40). Instead the game script below is copied to BASES (its class_name line
## blanked), the mod's source is compiled at the game path extending that copy, and preloads find
## the class they expect. A mod script without source text, or a base with a global class_name
## kept only as binary tokens, falls back to the plain take-over. Relative paths in an extending
## script resolve against the game path.
const BASES := "user://mods/.bases"
## The resource cache does not own what it lists: an extension nothing references is freed and
## the next load() reads the game script from disk again.
static var extensions: Array[Script] = []

static func apply_extensions(list: Array) -> void:
	var standing := {}   # game path -> source text compiled there by an earlier extension
	var count := 0
	for mod: Dictionary in list:
		for path: String in mod.extends:
			var script := load(path) as Script
			var base: Script = script.get_base_script() if script != null else null
			if base == null or base.resource_path.is_empty():
				push_warning("[mods] %s: %s does not extend a game script" % [mod.id, path]); continue
			var target := base.resource_path
			var compiled := _compile_at(script, base, target, standing, count)
			count += 1
			if compiled.is_empty():
				script.take_over_path(target)
				extensions.append(script)
			else:
				standing[target] = compiled
				extensions.append(load(target))
			print("[mods] %s extends %s" % [mod.id, target])

## The mod's source compiled at `target` over a copy of what stands there now; its source text,
## or "" when this cannot be done (the caller takes the path over plainly).
static func _compile_at(script: Script, base: Script, target: String, standing: Dictionary, index: int) -> String:
	var text := script.source_code
	if text.is_empty(): return ""
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BASES))
	var copy := ""
	if standing.has(target):
		copy = BASES.path_join("%d.gd" % index)
		_write(copy, standing[target], PackedByteArray())
	elif FileAccess.file_exists(target):
		copy = BASES.path_join("%d.gd" % index)
		_write(copy, FileAccess.get_file_as_string(target), PackedByteArray())
	elif FileAccess.file_exists(target.get_basename() + ".gdc") and base.get_global_name() == &"":
		# Exported game scripts are binary tokens; with no class_name the bytes copy as they are.
		copy = BASES.path_join("%d.gdc" % index)
		_write(copy, "", FileAccess.get_file_as_bytes(target.get_basename() + ".gdc"))
	if copy.is_empty(): return ""
	var head := RegEx.create_from_string("(?m)^extends\\s+[\"']" + _escape(target) + "[\"']")
	if head.search(text) == null: return ""
	text = head.sub(text, 'extends "%s"' % copy)
	# Loaded from a file first so GDScript's own cache holds it; taking over the path then moves
	# that cache entry onto the game path (a new GDScript() would leave the game script there),
	# and the reload compiles it under the game path's class name.
	var own := BASES.path_join("%d_extension.gd" % index)
	_write(own, text, PackedByteArray(), false)
	var sub := load(own) as GDScript
	if sub == null: return ""
	sub.take_over_path(target)
	if sub.reload() != OK:
		push_warning("[mods] %s did not compile over its game script; plain take-over instead" % script.resource_path)
		return ""
	return text

static func _write(path: String, text: String, bytes: PackedByteArray, base := true) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return
	if not base:
		file.store_string(text)
	elif bytes.is_empty():
		# A copy must not claim the game script's global class name.
		file.store_string(RegEx.create_from_string("(?m)^class_name\\s+\\w+\\s*").sub(text, "", true))
	else:
		file.store_buffer(bytes)
	file.close()

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
