extends RefCounted
## Save discovery shared by the title (Continue, Load game), the in-game saved games panel and
## GameSaves.catalogue(): what each checkpoint is, never whether it validates (GameSaves does
## that when one is chosen). Lightweight on purpose: the idle title must not load gameplay.
##
## Beside each checkpoint `<name>.json` (docs/ALPHA_SAVES.md):
##   <name>.preview.jpg   the last frame the player saw when it was written (world/saves/save_preview.gd)
##   <name>.preview.meta  a small JSON header (world, day/time, place, form, play time, kind) so menus
##                        need not parse megabyte documents. Trusted only while the checkpoint still
##                        has the length and modified time recorded in it; otherwise the checkpoint is
##                        parsed once and the header rewritten (old saves get one the first time).
## Neither ends in .json, so older builds' catalogues never mistake them for checkpoints.
##
## Continue and the top of every list are the same entry: newest() below.
const SAVE_FILE := preload("res://world/save_file.gd")
const LAYOUT := preload("res://world/world_layout.gd")
const FORM := preload("res://world/life/player_form.gd")
## The player's names, tags and stars, and each world folder's look (dev 2026-10-27).
const SHELF := preload("res://world/saves/save_shelf.gd")
const ROOT := "user://worlds"
## Keep aligned with GameSaves.FORMAT (tools/title/test_continue_latest.gd checks the title copy).
const HEADER_FORMAT := 5
const MAX_BYTES := 16 * 1024 * 1024
const META_VERSION := 1
const KINDS := ["manual", "autosave", "quit"]
## Whether reading an old checkpoint writes its header sidecar. Off under the owned test runner
## (it always sets EQ_CONTEXT_ROOT), so fixtures that only look at a catalogue never write into
## a real user folder.
static var backfill := OS.get_environment("EQ_CONTEXT_ROOT").is_empty()
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
## World names: a stable two-word name from the world id (worlds are stored by id only).
const NAME_A := ["Sunny", "Clover", "Apple", "Bluebell", "Honey", "Starlight", "Willow", "Daisy", "Maple", "Misty",
	"Rosy", "Silver", "Golden", "Cotton", "Berry", "Lilac", "Amber", "Breezy", "Cherry", "Dewdrop", "Hazel", "Juniper", "Pebble", "Sugar"]
const NAME_B := ["Meadow", "Hollow", "Glade", "Brook", "Hill", "Vale", "Orchard", "Grove", "Dell", "Field", "Creek", "Ridge",
	"Green", "Pond", "Lane", "Downs", "Spring", "Thicket", "Knoll", "Copse", "Bend", "Haven", "Heath", "Bluff"]


static func preview_path(save_path: String) -> String:
	return save_path.get_basename() + ".preview.jpg"


static func meta_path(save_path: String) -> String:
	return save_path.get_basename() + ".preview.meta"


static func _number(value: Variant) -> float:
	return float(value) if (value is int or value is float) and is_finite(float(value)) else 0.0


static func format_of(doc: Dictionary) -> int:
	var value: Variant = doc.get("format", doc.get("version"))
	return int(value) if (value is int or value is float) and is_finite(float(value)) and float(value) >= 1 else 0


# ------------------------------------------------------------------ describing one checkpoint
## The light header of a parsed checkpoint: what menus show. Pure (runs on save workers too).
static func header_from_doc(doc: Dictionary, path: String) -> Dictionary:
	var summary: Dictionary = doc.get("summary") if doc.get("summary") is Dictionary else {}
	var kind := str(summary.get("kind", ""))
	if kind not in KINDS: kind = _kind_from_path(path)
	var place := str(summary.get("place", ""))
	if place.is_empty(): place = region_text(doc.get("position"))
	var context: Dictionary = doc.get("context") if doc.get("context") is Dictionary else {}
	var clock: Dictionary = doc.get("clock") if doc.get("clock") is Dictionary else {}
	return {"format": format_of(doc), "world_id": str(doc.get("world_id", _world_of(path))),
		"saved_at": _number(doc.get("saved_at")), "day": _number(doc.get("day")), "hours": _number(doc.get("hours")),
		"kind": kind, "place": place, "form": form_text(FORM.saved(context)),
		"play_seconds": _number(clock.get("active_seconds")),
		"first_day": _number(clock.get("first_day"))}


static func _kind_from_path(path: String) -> String:
	var name := path.get_file().get_basename()
	return "autosave" if name.begins_with("autosave") else "manual"


static func _world_of(path: String) -> String:
	# <root>/<world>/saves/<file> or <root>/<world>/saves/archive/<file>
	var folder := path.get_base_dir()
	if folder.get_file() == "archive": folder = folder.get_base_dir()
	return folder.get_base_dir().get_file()


## "Human", "Pegasus mare", "Earth pony filly". A world without a chosen form is human.
static func form_text(form: Dictionary) -> String:
	if not FORM.is_pony(form): return "Human"
	var race: String = FORM.RACE_WORDS.get(str(form.get("race", "")), FORM.RACE_WORDS.earth)
	var text := "%s %s" % [race, FORM.pronouns(form).noun]
	return text.left(1).to_upper() + text.substr(1)


## The nearest named region of a saved position (old checkpoints carry no place name).
static func region_text(position: Variant) -> String:
	if not (position is Array and position.size() == 3): return ""
	for n: Variant in position:
		if not (n is int or n is float) or not is_finite(float(n)): return ""
	var at := Vector3(float(position[0]), float(position[1]), float(position[2]))
	var best: Dictionary = {}
	var best_distance := INF
	for region: Dictionary in LAYOUT.regions():
		if bool(region.get("future_island", false)) or not region.has("center"): continue
		var distance := LAYOUT.distance_to(region, at)
		if distance < best_distance: best_distance = distance; best = region
	if best.is_empty(): return ""
	return str(best.get("name", best.get("id", ""))) if best_distance <= 0.0 else "Near " + str(best.get("name", best.get("id", "")))


static func world_name(world_id: String) -> String:
	if world_id == "default": return "First world"
	var digest := world_id.md5_text()
	var a := ("0x" + digest.substr(0, 6)).hex_to_int()
	var b := ("0x" + digest.substr(6, 6)).hex_to_int()
	return "%s %s" % [NAME_A[a % NAME_A.size()], NAME_B[b % NAME_B.size()]]


## The name a world goes by: the player's own (world/saves/save_shelf.gd), else world_name().
static func world_title(root: String, world_id: String) -> String:
	var name := str(SHELF.read(root.path_join(world_id)).world.get("name", ""))
	return name if not name.is_empty() else world_name(world_id)


## "Sep 22, 2026" for world-20260922-… / world-2026-09-22-… ids (local time of New game), else "".
static func world_started(world_id: String) -> String:
	var found := RegEx.create_from_string("^world-(\\d{4})-?(\\d{2})-?(\\d{2})").search(world_id)
	if found == null: return ""
	var month := int(found.get_string(2))
	if month < 1 or month > 12: return ""
	return "%s %d, %s" % [MONTHS[month - 1], int(found.get_string(3)), found.get_string(1)]


# ------------------------------------------------------------------ text for menus
## "Day 5, 14:20": the day of the player's stay (the world's own first day reads Day 1).
static func game_time_text(entry: Dictionary) -> String:
	var hours := clampf(float(entry.get("hours", 0.0)), 0.0, 23.99)
	return "Day %d, %02d:%02d" % [maxi(1, int(entry.get("day", 0)) - int(entry.get("first_day", 0)) + 1), int(hours), int((hours - int(hours)) * 60.0)]


## Local wall-clock time of a save: "today 21:03", "yesterday 08:10", "Oct 12, 21:03", "Oct 12 2025, 21:03".
static func when_text(unix: float) -> String:
	if unix <= 0.0: return "unknown time"
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var at := Time.get_datetime_dict_from_unix_time(int(unix) + bias)
	var now := Time.get_datetime_dict_from_unix_time(int(Time.get_unix_time_from_system()) + bias)
	var clock := "%02d:%02d" % [at.hour, at.minute]
	var day_index := floori((unix + bias) / 86400.0)
	var today_index := floori((Time.get_unix_time_from_system() + bias) / 86400.0)
	if day_index == today_index: return "today " + clock
	if day_index == today_index - 1: return "yesterday " + clock
	var date := "%s %d" % [MONTHS[clampi(int(at.month) - 1, 0, 11)], at.day]
	if at.year != now.year: date += " %d" % at.year
	return date + ", " + clock


static func play_text(seconds: float) -> String:
	var minutes := int(seconds / 60.0)
	if minutes < 1: return "played under a minute"
	if minutes < 60: return "played %d min" % minutes
	return "played %d h %d min" % [floori(minutes / 60.0), minutes % 60]


## "Quit save", "Autosave", "Manual save · Slot 2", "Archived manual save".
static func kind_text(entry: Dictionary) -> String:
	var kind := str(entry.get("kind", "manual"))
	var text: String = {"quit": "Quit save", "autosave": "Autosave"}.get(kind, "Manual save")
	if bool(entry.get("archived", false)): text = "Archived " + text.to_lower()
	elif kind == "manual" and str(entry.get("label", "")).begins_with("Slot "): text += " · " + str(entry.label).get_slice(" (", 0)
	if bool(entry.get("newer", false)): text += " (newer version)"
	elif bool(entry.get("backup", false)): text += " (backup copy)"
	return text


## The save's own name when the player gave it one, else what kind of save it is.
static func title_text(entry: Dictionary) -> String:
	var name := str(entry.get("name", ""))
	return name if not name.is_empty() else kind_text(entry)


## One line for Continue: "Clover Hollow · Ponyville · Day 5, 14:20 · Quit save, today 21:03".
static func line(entry: Dictionary) -> String:
	var parts: Array[String] = [str(entry.get("world_name", ""))]
	if not str(entry.get("place", "")).is_empty(): parts.append(str(entry.place))
	parts.append(game_time_text(entry))
	parts.append(title_text(entry) + ", " + when_text(float(entry.get("saved_at", 0.0))))
	return " · ".join(parts)


# ------------------------------------------------------------------ headers on disk
## The trusted sidecar header, or {} when it is missing or older than the checkpoint.
static func _read_meta(path: String) -> Dictionary:
	var meta: Variant = SAVE_FILE.parse(meta_path(path), 64 * 1024)
	if not meta is Dictionary or int(_number(meta.get("meta_version"))) != META_VERSION: return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	var length := file.get_length()
	file.close()
	if int(_number(meta.get("doc_bytes"))) != length or int(_number(meta.get("doc_mtime"))) != FileAccess.get_modified_time(path): return {}
	for key in ["world_id", "kind", "place", "form"]:
		if not meta.get(key) is String: return {}
	return meta


## Records `header` for the checkpoint at `path` as it is on disk now. Any thread.
static func write_meta(path: String, header: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return
	var meta := header.duplicate()
	meta.meta_version = META_VERSION
	meta.doc_bytes = file.get_length()
	file.close()
	meta.doc_mtime = FileAccess.get_modified_time(path)
	var target := meta_path(path)
	var temporary := target + ".%d.tmp" % (randi() % 1000000)
	var out := FileAccess.open(temporary, FileAccess.WRITE)
	if out == null: return
	out.store_string(JSON.stringify(meta))
	out.close()
	DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(target))


## Header of one checkpoint path, as the loader would see it: the file itself, else (missing or
## unreadable main file) its .previous copy, which GameSaves.open_save recovers. {} = not a save.
static func _header(path: String) -> Dictionary:
	if FileAccess.file_exists(path):
		var meta := _read_meta(path)
		if not meta.is_empty(): return meta
		var doc: Variant = SAVE_FILE.parse(path, MAX_BYTES)
		if doc is Dictionary:
			if doc.get("empty", false) or format_of(doc) < 1: return {}
			var header := header_from_doc(doc, path)
			if backfill: write_meta(path, header)
			return header
	var backup: Variant = SAVE_FILE.parse(path + ".previous", MAX_BYTES)
	if not backup is Dictionary or backup.get("empty", false) or format_of(backup) < 1: return {}
	var recovered := header_from_doc(backup, path)
	recovered.backup = true
	return recovered


## Checkpoint paths in one world's saves folder (and its archive), each once: a backup-only
## file is listed under its main name.
static func _paths(folder: String) -> Array[String]:
	var files: Array[String] = []
	for dir: String in [folder, folder.path_join("archive")]:
		if not DirAccess.dir_exists_absolute(dir): continue
		for file: String in DirAccess.get_files_at(dir):
			if file.ends_with(".json"): files.append(dir.path_join(file))
			elif file.ends_with(".json.previous") and not FileAccess.file_exists(dir.path_join(file.trim_suffix(".previous"))):
				files.append(dir.path_join(file.trim_suffix(".previous")))
	return files


static func _entry(path: String, header: Dictionary, shelf: Dictionary = {}) -> Dictionary:
	var name := path.get_file().get_basename()
	var archived := path.get_base_dir().get_file() == "archive"
	var label := "Autosave" if name == "autosave" and not archived else ("Slot " + name.trim_prefix("slot_") if name.begins_with("slot_") and not archived else
		("Save" if name.begins_with("save_") and not archived else "Archive " + name))
	var newer := int(header.get("format", 0)) > HEADER_FORMAT
	if newer: label += " (newer version)"
	var world_id := str(header.get("world_id", _world_of(path)))
	var preview := preview_path(path)
	var look := SHELF.world_look(world_id, shelf)
	var own: Dictionary = (shelf.get("saves", {}) as Dictionary).get(SHELF.key_of(path), {})
	return {"path": path, "world_id": world_id, "label": label, "saved_at": _number(header.get("saved_at")),
		"hours": _number(header.get("hours")), "day": _number(header.get("day")), "archived": archived, "newer": newer,
		"backup": bool(header.get("backup", false)), "kind": str(header.get("kind", _kind_from_path(path))),
		"place": str(header.get("place", "")), "form": str(header.get("form", "Human")),
		"play_seconds": _number(header.get("play_seconds")),
		"world_name": str(look.name) if not str(look.name).is_empty() else world_name(world_id),
		"world_icon": str(look.icon), "world_color": int(look.color),
		"name": str(own.get("name", "")), "tags": Array(own.get("tags", [])), "star": bool(own.get("star", false)),
		"world_started": world_started(world_id), "preview": preview if FileAccess.file_exists(preview) else ""}


static func _newest_first(entries: Array[Dictionary]) -> Array[Dictionary]:
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.saved_at) > float(b.saved_at))
	return entries


## One world's checkpoints (its saves folder), newest first.
static func world_entries(folder: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if folder.is_empty() or not DirAccess.dir_exists_absolute(folder): return result
	if RESCUE_SET_ASIDE: rescue_set_aside(folder)
	var shelf := SHELF.read(folder.get_base_dir())
	for path in _paths(folder):
		var header := _header(path)
		if not header.is_empty(): result.append(_entry(path, header, shelf))
	return _newest_first(result)


## Rollback switch for rescue_set_aside (docs/THREAD_FIX_SAVES_2026_11_19.md).
const RESCUE_SET_ASIDE := true

## Older builds (0.3.1 and before) renamed a checkpoint they refused to "<name>.json.corrupt-<time>",
## which no list shows: one bad briefcase entry hid a whole save for good (thread 2026-11-16). Such a
## file that still holds a save document is moved, byte for byte, into the archive as
## "<name>_not_loaded_<time>.json", where the Load list shows it and this version (which repairs bad
## briefcase entries) can try it. Damaged bytes stay where they are. Only the file moves: the
## journal and picture beside it belong to whatever save took its name since. Returns how many moved.
static func rescue_set_aside(folder: String) -> int:
	var moved := 0
	var archive := folder.path_join("archive")
	for dir: String in [folder, archive]:
		if not DirAccess.dir_exists_absolute(dir): continue
		for file: String in DirAccess.get_files_at(dir):
			var at := file.find(".json.corrupt-")
			if at <= 0: continue
			var source := dir.path_join(file)
			if not _holds_save(source): continue
			var stem := "%s_not_loaded_%s" % [file.left(at), file.substr(at + 14).validate_filename()]
			var target := archive.path_join(stem + ".json")
			var n := 2
			while FileAccess.file_exists(target) or FileAccess.file_exists(target + ".previous"):
				target = archive.path_join("%s_%d.json" % [stem, n]); n += 1
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(archive))
			if DirAccess.rename_absolute(ProjectSettings.globalize_path(source), ProjectSettings.globalize_path(target)) == OK:
				moved += 1
				print("[saves] %s, set aside by an older version, is back in the archive as %s" % [file, target.get_file()])
	return moved


## A set-aside file worth showing again: a JSON object that is a save document. One over the read
## cap is judged by its braces only (a later version may read it); a cheap brace check comes first
## so damaged files are not parsed on every listing.
static func _holds_save(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 2: return false
	var length := file.get_length()
	var head := file.get_buffer(mini(64, length)).get_string_from_utf8().strip_edges().trim_prefix("﻿")
	file.seek(maxi(0, length - 64))
	var tail := file.get_buffer(mini(64, length)).get_string_from_utf8().strip_edges()
	file.close()
	if not head.begins_with("{") or not tail.ends_with("}"): return false
	if length > MAX_BYTES: return true
	var doc: Variant = SAVE_FILE.parse(path, MAX_BYTES)
	return doc is Dictionary and not doc.get("empty", false) and format_of(doc) >= 1


## Every checkpoint of every world under `root`, newest first.
static func catalogue(root := ROOT) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not DirAccess.dir_exists_absolute(root): return result
	for world: String in DirAccess.get_directories_at(root):
		result.append_array(world_entries(root.path_join(world).path_join("saves")))
	return _newest_first(result)


## What Continue resumes and every list shows first: the newest checkpoint that is not archived
## (manual, autosave or quit save, of any world). A newer-version file stays the candidate so
## Continue explains it instead of silently entering an older world. {} when there is none.
static func newest(entries: Array[Dictionary]) -> Dictionary:
	for entry in entries:
		if not bool(entry.archived): return entry
	return {}


## Entries grouped by world for lists: [{world_id, world_name, world_started, form, entries}].
## Worlds are ordered by their newest unarchived checkpoint (worlds with only archives last);
## inside a world, current checkpoints newest first, then its archives newest first.
static func groups(entries: Array[Dictionary]) -> Array[Dictionary]:
	var by_world: Dictionary = {}
	var order: Array[Dictionary] = []
	for entry in entries:
		var id := str(entry.world_id)
		if not by_world.has(id):
			by_world[id] = {"world_id": id, "world_name": entry.world_name, "world_started": entry.world_started,
				"world_icon": entry.get("world_icon", "heart"), "world_color": int(entry.get("world_color", 0)),
				"form": entry.form, "entries": [], "archived": [], "newest": -1.0}
			order.append(by_world[id])
		var group: Dictionary = by_world[id]
		if bool(entry.archived): group.archived.append(entry)
		else:
			group.entries.append(entry)
			if group.newest < 0.0: group.newest = float(entry.saved_at); group.form = entry.form
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.newest) > float(b.newest))
	var result: Array[Dictionary] = []
	for group in order:
		var combined: Array = group.entries + group.archived
		group.erase("archived"); group.erase("newest")
		group.entries = combined
		result.append(group)
	return result


## Moves or removes a checkpoint's sidecars along with it (archive, delete).
static func sidecars(save_path: String) -> Array[String]:
	return SHELF.sidecars(save_path)
