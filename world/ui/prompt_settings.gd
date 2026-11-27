extends Control
## Settings → Prompts (dev 2026-10-22: "add a settings tab for prompts and make every prompt
## editable", PonyPonyParadise parity, player builds included). Two kinds of prompt:
## - fragments from res://world/ai/prompts/catalog.json (rules, reply format, memory, events),
##   edited through world/ai/prompt_overrides.gd and applied when a request is sent;
## - whole files: system.md and every pony persona, a mod's ponies included, saved as the existing
##   user://mods/prompts/<file name> override that ai_config.prompt_text already prefers.
## A fragment with fill-in slots (%s, %d) refuses an edit that drops or reorders them.
const OVERRIDES := preload("res://world/ai/prompt_overrides.gd")
const CONFIG := preload("res://world/ai/ai_config.gd")
const BOND := preload("res://world/relationships/bond_rules.gd")
const POPULATION := preload("res://world/population/pony_population_config.gd")
## The note on a catalogue entry the relationship overhaul replaced (BOND.RETIRED_PROMPTS).
const RETIRED_NOTE := "Replaced in this version. Your edit is kept, and is used again if the old system is switched back on."
const PERSONA_DIRS := ["res://world/ai/prompts", "res://world/characters/princesses", "res://world/characters/background/ai"]
## Where mounted mods keep their files; a character profile there is a small JSON file, looked for
## PROFILE_DEPTH folders deep (the merge folder holds game data, not profiles).
const MOD_ROOT := "res://mods"
const PROFILE_DEPTH := 2
const PROFILE_BYTES := 65536
const ALL := "All prompts"
const EDITED := "Edited only"
const PERSONAS := "Personas"
const CHARS_PER_TOKEN := 2.6   # measured on the tester capture (docs/AI_TOKENS_PROMPT_2026_10_22.md)
var panel: Node
var controls: Array[Control] = []
var editor: TextEdit
var _search: LineEdit
var _group: Control
var _list: ItemList
var _info: Label
var _status: Label
var _entries: Array = []      # {kind: "fragment"|"persona", id, group, label, path?}
var _shown: Array = []
var _current: Dictionary = {}
var _scroll: ScrollContainer
var _buttons_only: Array[Control] = []

func setup(surface: Node, in_tab := true) -> void:
	panel = surface
	theme = preload("res://world/ui/menu_style.gd").theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Scrolls when the unfolded group list makes the page taller than its room.
	_scroll = ScrollContainer.new(); add_child(_scroll); _scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; _scroll.follow_focus = true
	_scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _refresh())
	var margin := MarginContainer.new(); _scroll.add_child(margin)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL; margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["left", "right"]: margin.add_theme_constant_override("margin_" + side, 24)
	margin.add_theme_constant_override("margin_top", 12); margin.add_theme_constant_override("margin_bottom", 12)
	var box := VBoxContainer.new(); box.add_theme_constant_override("separation", 8); margin.add_child(box)
	# Inside the settings page the tab's own title names it.
	var title := Label.new(); title.text = "Prompts"; title.add_theme_font_size_override("font_size", 28); box.add_child(title)
	title.visible = not in_tab
	var note := Label.new(); note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; note.add_theme_font_size_override("font_size", 17)
	note.text = "Every instruction the ponies receive. Edits apply to the next request and are kept across saves. Longer prompts cost more tokens on every request; Revert restores the shipped text."
	box.add_child(note)
	var filters := HBoxContainer.new(); filters.add_theme_constant_override("separation", 8); box.add_child(filters)
	_search = LineEdit.new(); _search.placeholder_text = "Search prompts"; _search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.custom_minimum_size.y = 44; _search.text_changed.connect(func(_t: String): _fill_list()); filters.add_child(_search)
	# An in-page dropdown (world/ui/menu_picker.gd): an OptionButton's popup is a bare window on a
	# panel. Its face sits beside the search; its list unfolds under the whole row.
	_group = preload("res://world/ui/menu_picker.gd").new(); _group.item_selected.connect(func(_i: int): _fill_list())
	_group.redraw = func() -> void: _refresh()
	_group.list_height = 220.0; box.add_child(_group)
	_group.detach_head(filters); _group.head().custom_minimum_size = Vector2(260, 44)
	_group.toggled_open.connect(_group_toggled)
	_group.entries_changed.connect(_order_controls)
	_list = ItemList.new(); _list.custom_minimum_size.y = 150; _list.add_theme_font_size_override("font_size", 17)
	_list.item_selected.connect(_pick); box.add_child(_list)
	_info = Label.new(); _info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; _info.add_theme_font_size_override("font_size", 16)
	_info.theme_type_variation = "Muted"; box.add_child(_info)
	editor = TextEdit.new(); editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY; editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor.custom_minimum_size.y = 160; editor.add_theme_font_size_override("font_size", 17)
	editor.text_changed.connect(_edited); box.add_child(editor)
	var buttons := HBoxContainer.new(); buttons.add_theme_constant_override("separation", 8); box.add_child(buttons)
	for entry in [["Save prompt", _save], ["Revert to default", _revert], ["Revert all edits", _revert_all]]:
		var b := Button.new(); b.text = entry[0]; b.custom_minimum_size.y = 44; b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(entry[1]); buttons.add_child(b); controls.append(b)
	_status = Label.new(); _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; _status.add_theme_font_size_override("font_size", 17); box.add_child(_status)
	_buttons_only = controls.duplicate()
	_order_controls()
	hide()

## Stick focus order; an unfolded list's entries follow its face.
func _order_controls() -> void:
	controls.clear()
	controls.append_array([_search, _group.head()])
	if _group.is_open(): controls.append_array(_group.controls)
	controls.append_array([_list, editor]); controls.append_array(_buttons_only)

## An unfolded list scrolls into view.
func _group_toggled(open: bool) -> void:
	_order_controls()
	_refresh()
	if not open: return
	await get_tree().process_frame
	if is_instance_valid(_group) and _group.is_open(): _scroll.ensure_control_visible(_group); _refresh()

func open() -> void:
	_load_entries()
	var groups := [ALL, EDITED, PERSONAS]
	for e: Dictionary in _entries:
		if not str(e.group) in groups: groups.append(str(e.group))
	var keep: String = _group.get_item_text(_group.selected) if _group.item_count > 0 else ALL
	_group.clear()
	for g: String in groups: _group.add_item(g)
	_group.select(maxi(0, groups.find(keep)))
	_fill_list()
	show(); _refresh()

func _load_entries() -> void:
	_entries.clear()
	for f: Dictionary in OVERRIDES.catalog():
		_entries.append({"kind": "fragment", "id": str(f.id), "group": str(f.group), "label": str(f.label).capitalize() if str(f.label) == str(f.label).to_upper() else str(f.label),
			"where": str(f.file), "slots": int(f.placeholders)})
	var seen := {}
	for dir: String in PERSONA_DIRS:
		for file: String in DirAccess.get_files_at(dir):
			if file.get_extension() != "md": continue
			var path := dir.path_join(file)
			seen[path] = true
			_entries.append({"kind": "persona", "id": path, "group": PERSONAS, "where": path,
				"label": "System prompt (all ponies)" if file == "system.md" else file.get_basename().capitalize()})
	_mod_personas(seen)

## A mod's ponies (2026-11-24: they were missing here). Looked for each time this page opens, and
## anything already listed is skipped:
## - every character the running world's director knows (her profile's "prompt" is her persona file);
## - every character profile in a mounted mod's folder (the JSON object a pony's ai_profile names);
## - every .md file in a mod's folder named after a character (a pony id from the catalogue or the
##   director, as in anonfilly.md), for a mod that keeps a persona without a profile beside it.
func _mod_personas(seen: Dictionary) -> void:
	var names := {}
	for id: String in POPULATION.catalogue(): names[id] = true
	var director: Node = get_tree().get_first_node_in_group("conversation_director") if is_inside_tree() else null
	var known: Variant = director.get("characters") if director != null else null
	if known is Dictionary:
		for id: Variant in known:
			names[str(id)] = true
			var row: Variant = (known as Dictionary)[id]
			if row is Dictionary and (row as Dictionary).get("profile") is Dictionary: _add_persona((row as Dictionary).profile, seen)
	for folder: String in DirAccess.get_directories_at(MOD_ROOT):
		_scan_profiles(MOD_ROOT.path_join(folder), PROFILE_DEPTH, seen, names)

func _scan_profiles(dir: String, depth: int, seen: Dictionary, names: Dictionary) -> void:
	var files := DirAccess.get_files_at(dir)
	for file: String in files:
		if file.get_extension() != "json": continue
		var path := dir.path_join(file)
		var handle := FileAccess.open(path, FileAccess.READ)
		if handle == null or handle.get_length() > PROFILE_BYTES: continue
		var data: Variant = JSON.parse_string(handle.get_as_text())
		if data is Dictionary: _add_persona(data, seen)
	# After the profiles, so a profile's own name for her wins over the file name.
	for file: String in files:
		if file.get_extension() == "md" and names.has(file.get_basename().to_lower()):
			_add_persona({"prompt": dir.path_join(file)}, seen)
	if depth <= 0: return
	for sub: String in DirAccess.get_directories_at(dir):
		if sub != "merge": _scan_profiles(dir.path_join(sub), depth - 1, seen, names)

func _add_persona(profile: Dictionary, seen: Dictionary) -> void:
	if not profile.get("prompt") is String: return
	var path := str(profile.prompt)
	if seen.has(path) or path.get_extension() != "md" or not FileAccess.file_exists(path): return
	seen[path] = true
	var label := str(profile.get("name", "")).strip_edges()
	if label.is_empty(): label = path.get_file().get_basename().capitalize()
	_entries.append({"kind": "persona", "id": path, "group": PERSONAS, "where": path, "label": label})

func _fill_list() -> void:
	var group: String = _group.get_item_text(_group.selected) if _group.item_count > 0 else ALL
	var needle := _search.text.strip_edges().to_lower()
	_list.clear(); _shown.clear()
	for e: Dictionary in _entries:
		var edited := _is_edited(e)
		if group == EDITED and not edited: continue
		if group not in [ALL, EDITED] and str(e.group) != group: continue
		if not needle.is_empty() and not (needle in str(e.label).to_lower() or needle in _default_text(e).to_lower()): continue
		_shown.append(e)
		_list.add_item(("● " if edited else "") + str(e.label) + ("" if group != ALL else "  · " + str(e.group)))
	if not _shown.is_empty() and (_current.is_empty() or _shown.find(_current) < 0): _list.select(0); _pick(0)
	elif _shown.find(_current) >= 0: _list.select(_shown.find(_current))
	_refresh()

func _pick(index: int) -> void:
	if index < 0 or index >= _shown.size(): return
	_current = _shown[index]
	editor.text = _current_text(_current)
	editor.clear_undo_history()
	_status.text = ""
	_describe()

func _describe() -> void:
	if _current.is_empty(): _info.text = ""; return
	var tokens := int(ceil(editor.text.length() / CHARS_PER_TOKEN))
	var bits := ["~%d tokens" % tokens, "edited" if _is_edited(_current) else "default", str(_current.where)]
	if int(_current.get("slots", 0)) > 0: bits.append("keep its %d fill-in slot(s) like %%s" % int(_current.slots))
	_info.text = " · ".join(bits)
	var note := entry_note(_current)
	if not note.is_empty(): _info.text = note + "\n" + _info.text
	_refresh()

## RETIRED_NOTE for a fragment the overhaul replaced while it is on; "" otherwise.
static func entry_note(e: Dictionary) -> String:
	if BOND.DYNAMIC and str(e.get("kind", "")) == "fragment" and str(e.get("id", "")) in BOND.RETIRED_PROMPTS: return RETIRED_NOTE
	return ""

func _edited() -> void:
	_describe()

func _save() -> void:
	if _current.is_empty(): return
	var why := ""
	if str(_current.kind) == "fragment":
		why = OVERRIDES.save(str(_current.id), editor.text)
	else:
		why = _write_persona(str(_current.id), editor.text)
		_reload_director()
	_status.text = why if not why.is_empty() else "Saved. The next request uses it."
	_fill_list_keep()

func _revert() -> void:
	if _current.is_empty(): return
	if str(_current.kind) == "fragment": OVERRIDES.revert(str(_current.id))
	else:
		var path := _persona_override(str(_current.id))
		if FileAccess.file_exists(path): DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		_reload_director()
	editor.text = _current_text(_current)
	_status.text = "Back to the shipped text."
	_fill_list_keep()

func _revert_all() -> void:
	OVERRIDES.revert_all()
	for e: Dictionary in _entries:
		if str(e.kind) == "persona" and _is_edited(e):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(_persona_override(str(e.id))))
	_reload_director()
	if not _current.is_empty(): editor.text = _current_text(_current)
	_status.text = "Every prompt is back to the shipped text."
	_fill_list_keep()

func _fill_list_keep() -> void:
	var keep := _current
	_fill_list()
	var index := _shown.find(keep)
	if index >= 0: _list.select(index)
	_describe()

func _is_edited(e: Dictionary) -> bool:
	if str(e.kind) == "fragment": return OVERRIDES.is_edited(str(e.id))
	return FileAccess.file_exists(_persona_override(str(e.id)))

func _default_text(e: Dictionary) -> String:
	if str(e.kind) == "fragment": return str(OVERRIDES.entry(str(e.id)).get("text", ""))
	return FileAccess.get_file_as_string(str(e.id)) if FileAccess.file_exists(str(e.id)) else ""

func _current_text(e: Dictionary) -> String:
	if str(e.kind) == "fragment": return OVERRIDES.text(str(e.id))
	return CONFIG.prompt_text(str(e.id))

func _persona_override(path: String) -> String:
	return CONFIG.MOD_PROMPTS.path_join(path.get_file())

func _write_persona(path: String, text: String) -> String:
	if text == _default_text({"kind": "persona", "id": path}):
		var existing := _persona_override(path)
		if FileAccess.file_exists(existing): DirAccess.remove_absolute(ProjectSettings.globalize_path(existing))
		return ""
	DirAccess.make_dir_recursive_absolute(CONFIG.MOD_PROMPTS)
	var file := FileAccess.open(_persona_override(path), FileAccess.WRITE)
	if file == null: return "Could not save (%s)." % error_string(FileAccess.get_open_error())
	file.store_string(text); file.close()
	return ""

## Persona and system files are read when the director (re)loads its configuration.
func _reload_director() -> void:
	if not is_inside_tree(): return
	var director: Node = get_tree().get_first_node_in_group("conversation_director")
	if director != null and director.has_method("reload_config"): director.reload_config()

func _refresh() -> void:
	if panel != null and panel.has_method("refresh"): panel.refresh()
