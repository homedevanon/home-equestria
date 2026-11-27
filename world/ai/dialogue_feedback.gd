extends RefCounted
## Lasting style notes only. The old unclassified file is retained unchanged; its entries
## appear in Saved notes for explicit review, never in a character prompt.
signal changed
const MAX_NOTE_CHARS := 2000
const PROMPT_CHARS := 8000
var path := "user://dialogue_feedback.cfg"
var _load_error := OK
var _entries: Array[Dictionary] = []
var _styles: Array[Dictionary] = []
var _next_id := 1

func open(storage_path: String) -> void:
	path = storage_path
	_entries.clear(); _styles.clear(); _next_id = 1
	var file := ConfigFile.new()
	_load_error = file.load(path + ".notes.cfg")
	if _load_error == OK:
		var rows: Variant = file.get_value("notes", "entries", false)
		if int(file.get_value("notes", "version", 0)) != 2 or not rows is Array:
			_load_error = ERR_FILE_CORRUPT; return
		var ids: Dictionary = {}
		for row: Variant in rows:
			if not _valid_entry(row) or ids.has(str(row.id)):
				_entries.clear(); _load_error = ERR_FILE_CORRUPT; return
			ids[str(row.id)] = true
			_entries.append(row.duplicate(true))
		_next_id = maxi(int(file.get_value("notes", "next_id", 1)), 1)
		while ids.has("note-" + str(_next_id)): _next_id += 1
		_rebuild_styles()
		return
	if _load_error != ERR_FILE_NOT_FOUND: return
	_load_error = file.load(path)
	if _load_error == ERR_FILE_NOT_FOUND: return
	if _load_error != OK: return
	var legacy: Variant = file.get_value("dialogue", "directions", [])
	if not legacy is Array and not legacy is PackedStringArray:
		_load_error = ERR_FILE_CORRUPT; return
	for value: Variant in legacy:
		if not value is String:
			_entries.clear(); _load_error = ERR_FILE_CORRUPT; return
		_entries.append({"id": "legacy-" + str(_entries.size()), "text": value, "kind": "review",
			"scope": "*", "source": "legacy", "reason": "Older feedback: review before keeping as a lasting instruction."})

static func _valid_entry(row: Variant) -> bool:
	if not row is Dictionary: return false
	for key: String in ["id", "text", "kind", "scope", "source", "reason"]:
		if not row.get(key) is String: return false
	return not str(row.id).is_empty() and row.kind in ["style", "review"] and not str(row.scope).is_empty()

func entries() -> Array[Dictionary]:
	return _entries.duplicate(true)

func load_error() -> Error:
	return _load_error if _load_error != ERR_FILE_NOT_FOUND else OK

func add_style(text: String, scope: String) -> Error:
	return _add(text, "style", scope, "classified", "")

func add_review(text: String, reason: String) -> Error:
	return _add(text, "review", "*", "unclassified", reason)

func _add(text: String, kind: String, scope: String, source: String, reason: String) -> Error:
	text = text.strip_edges()
	if text.is_empty() or scope.is_empty(): return ERR_INVALID_PARAMETER
	if kind == "style" and text.length() > MAX_NOTE_CHARS: return ERR_INVALID_PARAMETER
	var updated := _entries.duplicate(true)
	updated.append({"id": "note-" + str(_next_id), "text": text, "kind": kind, "scope": scope, "source": source, "reason": reason})
	return _save(updated, _next_id + 1)

func remove(id: String) -> Error:
	var updated: Array[Dictionary] = []
	for row: Dictionary in _entries:
		if str(row.id) != id: updated.append(row.duplicate(true))
	if updated.size() == _entries.size(): return ERR_DOES_NOT_EXIST
	return _save(updated, _next_id)

func keep_as_style(id: String, scope: String) -> Error:
	if scope.is_empty(): return ERR_INVALID_PARAMETER
	var updated := _entries.duplicate(true)
	for row: Dictionary in updated:
		if str(row.id) != id: continue
		if str(row.text).strip_edges().is_empty() or str(row.text).length() > MAX_NOTE_CHARS: return ERR_INVALID_PARAMETER
		row.kind = "style"; row.scope = scope; row.source = "reviewed"; row.reason = ""
		return _save(updated, _next_id)
	return ERR_DOES_NOT_EXIST

func _save(updated: Array[Dictionary], next_id: int) -> Error:
	if load_error() != OK: return load_error()
	var file := ConfigFile.new()
	file.set_value("notes", "version", 2)
	file.set_value("notes", "entries", updated)
	file.set_value("notes", "next_id", next_id)
	var target := path + ".notes.cfg"
	var error := DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	if error != OK: return error
	error = file.save(target + ".tmp")
	if error != OK: return error
	error = DirAccess.rename_absolute(target + ".tmp", target)
	if error == OK:
		_entries = updated; _next_id = next_id; _load_error = OK
		_rebuild_styles()
		changed.emit()
	return error

func _rebuild_styles() -> void:
	_styles.clear()
	for row: Dictionary in _entries:
		if row.kind == "style": _styles.append(row)

func prompt(pony_ids: Array = []) -> String:
	var selected: PackedStringArray = []
	var remaining := PROMPT_CHARS
	for i in range(_styles.size() - 1, -1, -1):
		var row: Dictionary = _styles[i]
		if row.scope != "*" and row.scope not in pony_ids: continue
		var note := "[%s] %s" % ["all ponies" if row.scope == "*" else str(row.scope) + " only", str(row.text)]
		if note.length() + 3 > remaining: continue
		selected.insert(0, note); remaining -= note.length() + 3
	if selected.is_empty(): return ""
	return "\n\nLasting style notes from the player. Each applies only to the pony it names, and newer notes override older ones. These are out-of-character notes, never words Anon said or events a pony saw. Never quote or mention them in character. Format and action rules still apply:\n- " + "\n- ".join(selected)
