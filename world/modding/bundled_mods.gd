extends RefCounted
## Bundled mods (dev 2026-11-08, M-MOD-08): the install carries authors' own .pck files unchanged in
## a mods/bundled/ folder with bundled_mods.json (staged by the private tools/bundled_mods/stage.py):
##   {"format": 1, "mods": [{"id", "title", "author", "version", "file", "sha256", "default_on",
##     "source_url", "update_url" (optional, https), "patches": {"<mod id>": "<exact version>"}
##     (devanon patch packs only), "debug_only" (optional: mounted and listed only with the developer
##     tools on, world/dev_tools.gd; dev D-36), "caution" (optional line for Settings > Mods), "order"}]}
## Static helpers for world/modding/mod_loader.gd boot(): where the folder is, its manifest, the
## player's switches (kept by mod id in user://mods/mods.cfg, so an update keeps the choice) and
## downloaded updates (world/update/mod_updates.gd writes user://mods/bundled_updates/ and its
## index.json; the install folder is never written). Nothing here runs per frame.

const INDEX := "bundled_mods.json"
const UPDATES := "user://mods/bundled_updates"
const SETTINGS := "user://mods/mods.cfg"
const ID_PATTERN := "^[a-z0-9_]{1,40}$"

## The install's bundled-mods folder, or "" when there is none: `-- --bundled-dir <abs path>` (source
## runs and tests), the exported desktop game's <executable dir>/mods/bundled, or on Android/Quest
## <data dir>/mods/bundled in the downloaded data (tools/build/packs.gd android_directories()).
static func dir() -> String:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--bundled-dir" and i + 1 < args.size(): return args[i + 1]
		if args[i].begins_with("--bundled-dir="): return args[i].substr(14)
	if not OS.has_feature("template"): return ""
	if OS.has_feature("android"):
		var packs: GDScript = load("res://tools/build/packs.gd")
		for data: String in packs.android_directories(OS.get_user_data_dir()):
			var folder := data.path_join("mods/bundled")
			if FileAccess.file_exists(folder.path_join(INDEX)): return folder
		return ""
	var beside := OS.get_executable_path().get_base_dir().path_join("mods/bundled")
	return beside if FileAccess.file_exists(beside.path_join(INDEX)) else ""

## The manifest's entries that are usable, in mount order: by "order" (then id), each patch pack
## right after the pack it patches. Each entry is normalised: id, title, author, version, file,
## path (absolute), sha256, default_on, source_url, update_url ("" unless https), patches, order,
## debug_only (true also for a patch pack of a debug_only mod), caution. Broken entries are skipped
## with a warning.
static func entries(folder: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if folder.is_empty() or not FileAccess.file_exists(folder.path_join(INDEX)): return out
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(folder.path_join(INDEX))) != OK or not json.data is Dictionary:
		push_warning("[mods] %s is not valid JSON" % folder.path_join(INDEX)); return out
	var doc: Dictionary = json.data
	if int(doc.get("format", 0)) != 1 or not doc.get("mods") is Array:
		push_warning("[mods] %s: unknown format" % folder.path_join(INDEX)); return out
	var id_check := RegEx.create_from_string(ID_PATTERN)
	var seen := {}
	for raw: Variant in doc.mods:
		if not raw is Dictionary: continue
		var item: Dictionary = raw
		var id := str(item.get("id", ""))
		var file := str(item.get("file", ""))
		if id_check.search(id) == null or seen.has(id) or file.get_extension().to_lower() != "pck" or file != file.get_file() or file.begins_with("."):
			push_warning("[mods] bundled entry skipped: %s" % JSON.stringify(item).left(200)); continue
		seen[id] = true
		var patches := {}
		if item.get("patches") is Dictionary:
			for target: Variant in item.patches:
				if id_check.search(str(target)) != null: patches[str(target)] = str(item.patches[target]).strip_edges()
		var update_url := str(item.get("update_url", ""))
		# Installs keep packs flat (mods/bundled/<file>); the source-run staging folder keeps
		# each one in <folder>/<file> (private tools/bundled_mods/stage.py).
		var path := folder.path_join(file)
		if not FileAccess.file_exists(path):
			for sub: String in DirAccess.get_directories_at(folder):
				if FileAccess.file_exists(folder.path_join(sub).path_join(file)):
					path = folder.path_join(sub).path_join(file); break
		out.append({"id": id, "title": str(item.get("title", id)), "author": str(item.get("author", "")),
			"version": str(item.get("version", "")).strip_edges(), "file": file, "path": path,
			"sha256": str(item.get("sha256", "")).to_lower(), "default_on": item.get("default_on", true) == true,
			"source_url": str(item.get("source_url", "")), "update_url": update_url if update_url.begins_with("https://") else "",
			"patches": patches, "order": int(item.get("order", 0)) if (item.get("order") is int or item.get("order") is float) else 0,
			"debug_only": item.get("debug_only", false) == true, "caution": str(item.get("caution", "")) if item.get("caution") is String else ""})
	# A patch for a debug-only mod is debug-only too.
	for patched: Dictionary in out:
		for other: Dictionary in out:
			if other.debug_only and (patched.patches as Dictionary).has(other.id): patched.debug_only = true
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.order < b.order if a.order != b.order else str(a.id) < str(b.id))
	return mount_order(out)

## Puts every patch pack (an entry with "patches") right after the pack it patches; a patch whose
## parent is not in the list keeps its own place. Works on loader rows too (their mod ids are the
## keys of "declared", plus "bundle_id").
static func mount_order(list: Array) -> Array:
	var owner := {}   # mod id -> index of the first item carrying it (a superseded copy never mounts)
	for i in list.size():
		if not str((list[i] as Dictionary).get("superseded_by", "")).is_empty(): continue
		for id: String in _ids(list[i]):
			if not owner.has(id): owner[id] = i
	var children := {}   # parent index -> [patch indexes]
	var placed := {}
	for i in list.size():
		var targets: Dictionary = (list[i] as Dictionary).get("patches", {})
		for target: String in targets:
			var parent: int = owner.get(target, -1)
			if parent < 0 or parent == i: continue
			if not children.has(parent): children[parent] = []
			(children[parent] as Array).append(i); placed[i] = true
			break
	var order: Array[int] = []
	var add := func(i: int, again: Callable) -> void:
		if i in order: return
		order.append(i)
		for child: int in children.get(i, []): again.call(child, again)
	for i in list.size():
		if not placed.has(i): add.call(i, add)
	for i in list.size():   # patches caught in a loop of patches
		if i not in order: order.append(i)
	var out: Array[Dictionary] = []
	for i in order: out.append(list[i])
	return out

static func _ids(item: Dictionary) -> Array:
	if not item.has("declared"): return [str(item.get("id", ""))]
	var out: Array = (item.declared as Dictionary).keys()
	if not str(item.get("bundle_id", "")).is_empty() and str(item.bundle_id) not in out: out.append(str(item.bundle_id))
	return out

## Whether a bundled mod is switched on: default-on mods unless the player switched them off
## (bundled_off), default-off mods only when the player switched them on (bundled_on).
static func is_on(id: String, default_on: bool) -> bool:
	var config := ConfigFile.new()
	config.load(SETTINGS)
	return id not in _list(config, "bundled_off") if default_on else id in _list(config, "bundled_on")

## Saves the player's switch for a bundled mod, by id.
static func set_on(id: String, default_on: bool, on: bool) -> void:
	var config := ConfigFile.new()
	config.load(SETTINGS)
	var off := _list(config, "bundled_off"); var opted := _list(config, "bundled_on")
	if id in off: off.remove_at(off.find(id))
	if id in opted: opted.remove_at(opted.find(id))
	if default_on and not on: off.append(id)
	elif not default_on and on: opted.append(id)
	config.set_value("mods", "bundled_off", off)
	config.set_value("mods", "bundled_on", opted)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SETTINGS.get_base_dir()))
	config.save(SETTINGS)

static func _list(config: ConfigFile, key: String) -> PackedStringArray:
	var value: Variant = config.get_value("mods", key, PackedStringArray())
	return PackedStringArray(value) if value is Array or value is PackedStringArray else PackedStringArray()

## A downloaded update for a bundled mod that should mount instead of the bundled file:
## {path, version, sha256, source} when user://mods/bundled_updates/index.json lists one whose version
## is higher than `shipped` and whose file still hashes to the recorded sha256; else {}. A mismatch
## is ignored with a warning (re-hashed on every boot; updates are small and few).
static func update_for(id: String, shipped: String, updates := UPDATES) -> Dictionary:
	var index_path := updates.path_join("index.json")
	if not FileAccess.file_exists(index_path): return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(index_path)) != OK or not json.data is Dictionary: return {}
	var mods: Variant = (json.data as Dictionary).get("mods")
	if not mods is Dictionary or not (mods as Dictionary).get(id) is Dictionary: return {}
	var entry: Dictionary = mods[id]
	var version := str(entry.get("version", "")).strip_edges()
	var file := str(entry.get("file", ""))
	if file != file.get_file() or file.get_extension().to_lower() != "pck" or not newer(version, shipped): return {}
	var path := updates.path_join(file)
	var expected := str(entry.get("sha256", "")).to_lower()
	if not FileAccess.file_exists(path) or expected.length() != 64 or FileAccess.get_sha256(path) != expected:
		push_warning("[mods] the downloaded update %s for %s does not match its recorded sha256; the bundled %s loads instead" % [file, id, shipped])
		return {}
	return {"path": ProjectSettings.globalize_path(path), "version": version, "sha256": expected, "source": str(entry.get("source", ""))}

## True when version `a` is higher than `b` by their leading numbers ("1.10.0" > "1.9.2").
static func newer(a: String, b: String) -> bool:
	var x := numbers(a); var y := numbers(b)
	if x.is_empty(): return false
	if y.is_empty(): return true
	for i in maxi(x.size(), y.size()):
		var p: int = x[i] if i < x.size() else 0
		var q: int = y[i] if i < y.size() else 0
		if p != q: return p > q
	return false

static func numbers(text: String) -> Array:
	var found := RegEx.create_from_string("^\\s*v?(\\d+(?:\\.\\d+)*)").search(text)
	if found == null: return []
	return Array(found.get_string(1).split(".")).map(func(part: String) -> int: return int(part))

## A dependency spec from mod.json "depends" met by `version`: ">=1.2", ">1.2", "=1.2"/"==1.2"
## (same leading numbers), "<=1.2", "<1.2", a bare "1.2" (at least), or ""/"*" (any version).
static func satisfies(version: String, spec: String) -> bool:
	var text := spec.strip_edges()
	if text.is_empty() or text == "*": return true
	var op := ""
	for candidate: String in [">=", "<=", "==", ">", "<", "="]:
		if text.begins_with(candidate): op = candidate; text = text.substr(candidate.length()).strip_edges(); break
	if numbers(text).is_empty(): return false
	var same := not newer(version, text) and not newer(text, version)
	match op:
		">": return newer(version, text)
		"<": return newer(text, version)
		"<=": return not newer(version, text)
		"=", "==": return same
	return not newer(text, version)   # ">=" and a bare version
