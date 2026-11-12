extends VBoxContainer
## The saved games browser (dev 2026-10-27: "the load and save game menu is really bad, we need
## more place with folders and tag for save"), shared by the title's Load game and the in-game
## saved games panel (world/ui/save_menu.gd). Worlds are folders down the side, each with a name,
## colour and picture of the player's choosing (world/saves/save_shelf.gd), beside "All saves"
## and "Starred"; the open folder's saves are cards with their screenshot; a card opens the save's
## own page: every detail, its name, tags and star, and what can be done with it. In the game it
## also makes new saves and saves over manual ones.
##
## Data: world/saves/save_catalogue.gd (headers only). Loading is the host's (load_requested):
## the title stages and enters, the game reloads. Moves and deletes in the running world go
## through GameSaves; every other world's files are moved by the shelf directly.
signal closed
signal load_requested(entry: Dictionary)

const STYLE := preload("res://world/ui/menu_style.gd")
const ICON := preload("res://world/ui/menu_icon.gd")
const CATALOGUE := preload("res://world/saves/save_catalogue.gd")
const SHELF := preload("res://world/saves/save_shelf.gd")
const PREVIEW := preload("res://world/saves/save_preview.gd")
const CURRENCY := preload("res://world/ui/currency.gd")
## Scenario mods (world/modding/scenario.gd): a save that cannot load with this launch's mods is
## shown greyed out with the plain reason ("Needs the <Name> mod", "Turn off the <Name> mod to load
## this"), never hidden; its Load is off. Read from the header only (entry "blocked").
const SCENARIO := preload("res://world/modding/scenario.gd")
const ALL := "*all"
const STARRED := "*starred"
const CARD_MIN := 230.0
const GAP := 12.0
## Rounded corners for screenshots (a TextureRect cannot round its own).
const ROUNDED := """
shader_type canvas_item;
uniform vec2 size_px = vec2(100.0, 56.0);
uniform float radius = 12.0;
varying vec2 local;
void vertex() { local = VERTEX; }
void fragment() {
	vec2 q = abs(local - size_px * 0.5) - size_px * 0.5 + vec2(radius);
	float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
	COLOR.a *= clamp(0.5 - d, 0.0, 1.0);
}
"""
static var _rounded: Shader
## Screenshot textures by path: [modified time, texture]; kept while the game runs.
static var _textures: Dictionary = {}

## Called after anything visible changes; a SubViewport panel passes its refresh().
var redraw := Callable()
## The host's flourishes (world/ui/menu_fx.gd), for the sparkle on a fresh save.
var fx: Control
var font_size := 20
## GameSaves of the running world (null on the title).
var saves: Node
## The SubViewport panel the browser is drawn on (VR keyboard), or null.
var panel: Node
var xr := false
var root := CATALOGUE.ROOT
var heading := "Saved games"

var _entries: Array[Dictionary] = []
var _groups: Array[Dictionary] = []
var _here := ""
var _folder := ALL
var _tag := ""
var _starred_only := false
var _archived := false
var _query := ""
var _selected: Dictionary = {}
var _asking := ""          # "delete", "delete_world" while a confirmation shows
var _editing := ""         # "rename_world", "look", "rename_save", "tag" while an editor shows
var _fresh_path := ""      # a save just made: its card sparkles once
var _known_saves: Dictionary = {}
var _known_loaded := false        # the saves were read once: anything new after that sparkles

var _page_size := Vector2(860, 800)
var _sidebar_width := 230.0
var _columns := 3
var _search: LineEdit
var _close: Button
var _new_save: Button
var _body: HBoxContainer
var _side_scroll: ScrollContainer
var _side: VBoxContainer
var _main: VBoxContainer
var _detail: VBoxContainer
## The save's page scrolls (a VR panel's keyboard takes the bottom of it).
var _detail_scroll: ScrollContainer
var _grid: GridContainer
var _grid_scroll: ScrollContainer
var _status: Label
var _keyboard: Control
## Quick actions (dev 2026-10-27: "delete in bulk, edit the name without going fully into a particular
## save ... any quality of life change"): a card's own buttons and its right-click menu, renaming in
## place, picking several saves at once, sorting, and the keys F2, Delete and Ctrl+A.
const SORTS := [["newest", "Newest first"], ["oldest", "Oldest first"], ["name", "By name"],
	["played", "Most played"], ["day", "Furthest in the game"]]
static var _sort := "newest"
var _selecting := false
var _picked: Dictionary = {}      # path -> true
var _last_picked := ""            # where a Shift range starts
var _renaming := ""               # the save whose card shows a name field
var _rename_draft := ""           # what was typed there, kept if the page is redrawn meanwhile
var _tearing_down := false        # _clear() is emptying part of the page
var _shown: Array[Dictionary] = []
var _bulk: VBoxContainer
var _overlay: Control             # an open menu, over the page
var _refresh_queued := false
var _batch := false               # a bulk action is running: GameSaves' changes wait for its end


func setup(page_size: Vector2, text_size: int, store: Node = null, in_xr := false) -> void:
	theme = STYLE.theme()
	_page_size = page_size; font_size = text_size; saves = store; xr = in_xr
	size = page_size; custom_minimum_size = page_size
	add_theme_constant_override("separation", 10)
	if saves != null and str(saves.directory) != "":
		_here = str(saves.directory).get_base_dir().get_file()
		root = str(saves.directory).get_base_dir().get_base_dir()
	_measure()
	var top := HBoxContainer.new(); top.add_theme_constant_override("separation", 10); add_child(top)
	var mark := ICON.make("folder", font_size + 10, STYLE.PINK); mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(mark)
	var title := STYLE.label(heading, "Heading", font_size + 12); title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.name = "Title"; top.add_child(title)
	_search = LineEdit.new(); _search.placeholder_text = "Search saves…"; _search.clear_button_enabled = true
	_search.custom_minimum_size = Vector2(_search_width(), font_size * 2.0)
	_search.right_icon = ICON.texture("search", font_size)
	_search.text_changed.connect(func(text: String) -> void: _query = text.strip_edges().to_lower(); _show_folder())
	top.add_child(_search)
	if saves != null:
		_new_save = _button(top, "New save", _save_new, "Primary", "plus")
	_close = _button(top, "Close", func() -> void: closed.emit(), "Ghost", "close")
	var stack := MarginContainer.new(); stack.size_flags_vertical = Control.SIZE_EXPAND_FILL; add_child(stack)
	_body = HBoxContainer.new(); _body.add_theme_constant_override("separation", 18); stack.add_child(_body)
	_side_scroll = ScrollContainer.new(); _side_scroll.custom_minimum_size.x = _sidebar_width
	_side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; _side_scroll.follow_focus = true
	_side_scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _redraw())
	_body.add_child(_side_scroll)
	_side = VBoxContainer.new(); _side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_side.add_theme_constant_override("separation", 3)
	# Room for a hovered row's lift and focus ring inside the scroll's clip.
	var side_pad := MarginContainer.new(); side_pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side: String in ["left", "right", "top", "bottom"]: side_pad.add_theme_constant_override("margin_" + side, 5)
	_side_scroll.add_child(side_pad); side_pad.add_child(_side)
	_main = VBoxContainer.new(); _main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main.add_theme_constant_override("separation", 10); _body.add_child(_main)
	_detail_scroll = ScrollContainer.new(); _detail_scroll.hide(); stack.add_child(_detail_scroll)
	_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; _detail_scroll.follow_focus = true
	_detail_scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _redraw())
	_detail = VBoxContainer.new(); _detail.add_theme_constant_override("separation", 12)
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL; _detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Room inside the scroll's clip for the focused Load button's ring and glow (shadow 10).
	var detail_pad := MarginContainer.new()
	detail_pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL; detail_pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side: String in ["left", "right", "bottom"]: detail_pad.add_theme_constant_override("margin_" + side, 12)
	detail_pad.add_theme_constant_override("margin_top", 4)
	_detail_scroll.add_child(detail_pad); detail_pad.add_child(_detail)
	_status = STYLE.label("", "Muted", font_size - 3); _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)
	if xr and panel != null:
		_keyboard = preload("res://world/ui/panel_keyboard.gd").new()
		_keyboard.setup(panel, page_size.x, font_size - 2); _keyboard.hide(); add_child(_keyboard)
	if saves != null and saves.has_signal("changed"): saves.changed.connect(_on_saves_changed)


## The sidebar's width and how many cards fit in a row, for the page size.
func _measure() -> void:
	_sidebar_width = clampf(_page_size.x * 0.26, 200.0, 290.0)
	var main_width := _page_size.x - _sidebar_width - 18.0 - 14.0
	_columns = maxi(1, int((main_width + GAP) / (CARD_MIN + GAP)))


func _search_width() -> float:
	return clampf(_page_size.x * 0.24, 170.0, 300.0)


## A new page size (the title's panel widens with the window): the sidebar, the rows of cards
## and whatever is open follow it.
func relayout(page_size: Vector2) -> void:
	if page_size == _page_size: return
	_page_size = page_size
	custom_minimum_size = page_size; size = page_size
	_measure()
	_side_scroll.custom_minimum_size.x = _sidebar_width
	_search.custom_minimum_size.x = _search_width()
	if not is_visible_in_tree(): return
	# Cards and the save's page are rebuilt: focus inside them moves to the new ones.
	var owner := get_viewport().gui_get_focus_owner()
	var rebuilt := owner != null and (_main.is_ancestor_of(owner) or _detail.is_ancestor_of(owner))
	_redisplay()
	if rebuilt: first_focus().grab_focus()


# ------------------------------------------------------------------ opening and data
## Re-reads every save and shows `world` (a world id; "" keeps the folder, or picks the running
## world in the game and the most recent one on the title).
func open(world := "") -> void:
	_selected = {}; _asking = ""; _editing = ""
	_reload()
	if world != "" and _has_world(world): _folder = world
	elif _folder in [ALL, STARRED] or not _has_world(_folder):
		_folder = _here if _has_world(_here) else (str(_groups[0].world_id) if not _groups.is_empty() else ALL)
	_tag = ""; _starred_only = false; _archived = false
	_selecting = false; _picked.clear(); _renaming = ""; _close_menu()
	# Before the folder is drawn: setting the field's text does not emit text_changed.
	_query = ""
	if _search != null: _search.text = ""
	_build_sidebar(); _show_folder()
	_status.text = ""


## Re-reads the saves and redraws what is open (after a save, a move, a rename).
func refresh() -> void:
	_reload()
	if not _folder in [ALL, STARRED] and not _has_world(_folder): _folder = ALL
	if not _selected.is_empty():
		var again := _find(str(_selected.path))
		if again.is_empty(): _selected = {}
		else: _selected = again
	_build_sidebar()
	if _selected.is_empty(): _show_folder()
	else: _show_save(_selected)


func _reload() -> void:
	_entries = CATALOGUE.catalogue(root)
	for entry in _entries: entry["blocked"] = SCENARIO.entry_block(entry)
	_groups = CATALOGUE.groups(_entries)
	# The running world is a folder even before its first save.
	if _here != "" and not _has_world(_here):
		var look := SHELF.world_look(_here, SHELF.read(root.path_join(_here)))
		_groups.push_front({"world_id": _here, "world_name": str(look.name) if str(look.name) != "" else CATALOGUE.world_name(_here),
			"world_started": CATALOGUE.world_started(_here), "world_icon": str(look.icon), "world_color": int(look.color),
			"form": "", "entries": []})
	var paths := {}
	for entry in _entries: paths[str(entry.path)] = true
	# A save that appeared since the last look (New save) sparkles once.
	if _known_loaded:
		for path: String in paths:
			if not _known_saves.has(path): _fresh_path = path
	_known_saves = paths; _known_loaded = true


func _has_world(id: String) -> bool:
	for group in _groups:
		if str(group.world_id) == id: return true
	return false


func _group(id: String) -> Dictionary:
	for group in _groups:
		if str(group.world_id) == id: return group
	return {}


func _find(path: String) -> Dictionary:
	for entry in _entries:
		if str(entry.path) == path: return entry
	return {}


func _on_saves_changed() -> void:
	# A bulk action changes many saves: it says what it did, and redraws once at the end.
	if _batch: return
	if is_visible_in_tree(): _queue_refresh()
	_status.text = CURRENCY.text(str(saves.message))
	CURRENCY.apply(_status)


## Any number of changes in one frame redraw once (and never under the signal that asked).
func _queue_refresh() -> void:
	if _refresh_queued: return
	_refresh_queued = true
	_run_queued_refresh.call_deferred()


func _run_queued_refresh() -> void:
	_refresh_queued = false
	if is_inside_tree(): refresh()


# ------------------------------------------------------------------ sidebar
func _build_sidebar() -> void:
	_clear(_side)
	var unarchived := _entries.filter(func(e: Dictionary) -> bool: return not bool(e.archived)).size()
	var starred := _entries.filter(func(e: Dictionary) -> bool: return bool(e.star)).size()
	_folder_row("All saves", "%d save%s" % [unarchived, "" if unarchived == 1 else "s"], "sparkle", STYLE.BUTTER, ALL)
	_folder_row("Starred", "%d save%s" % [starred, "" if starred == 1 else "s"], "star_filled", STYLE.BUTTER, STARRED)
	var caption := STYLE.label("WORLDS", "Faint", maxi(12, font_size - 7))
	var gap := Control.new(); gap.custom_minimum_size.y = 8; _side.add_child(gap)
	_side.add_child(caption)
	for group in _groups:
		var count := (group.entries as Array).filter(func(e: Dictionary) -> bool: return not bool(e.archived)).size()
		var details := "%d save%s" % [count, "" if count == 1 else "s"] + (" · " + str(group.form) if str(group.form) != "" else "")
		if str(group.world_id) == _here: details = "You are here · " + details
		_folder_row(str(group.world_name), details, str(group.world_icon), STYLE.SWATCHES[int(group.world_color) % STYLE.SWATCHES.size()], str(group.world_id))
	if _groups.is_empty(): _side.add_child(STYLE.label("No worlds yet.", "Muted", font_size - 3))


func _folder_row(title: String, details: String, icon_kind: String, tint: Color, id: String) -> void:
	var row := Button.new(); row.theme_type_variation = "Tab"; row.toggle_mode = true
	row.set_pressed_no_signal(id == _folder)
	row.custom_minimum_size = Vector2(0, font_size * 2.9)
	row.set_meta("no_sparkle", true)
	row.pressed.connect(_choose_folder.bind(id))
	if not id in [ALL, STARRED]: row.gui_input.connect(_world_row_input.bind(id, row))
	_hover_redraw(row)
	_side.add_child(row)
	var line := HBoxContainer.new(); line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_constant_override("separation", 10)
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	line.offset_left = 12; line.offset_right = -8
	row.add_child(line)
	var badge := _badge(icon_kind, tint, font_size * 1.9)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(badge)
	var texts := VBoxContainer.new(); texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL; texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.add_theme_constant_override("separation", 0); line.add_child(texts)
	var name_label := STYLE.label(title, "", font_size - 2); name_label.add_theme_font_override("font", STYLE.BOLD)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS; name_label.clip_text = true
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_child(name_label)
	var small := STYLE.label(details, "Faint", font_size - 7)
	small.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS; small.clip_text = true
	small.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.add_child(small)


## A round coloured disc with a picture on it: a world's folder mark.
func _badge(icon_kind: String, tint: Color, side: float) -> Control:
	var disc := Panel.new(); disc.custom_minimum_size = Vector2(side, side); disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	disc.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(tint, 0.22), Color(tint, 0.7), 1, 99, 0, 0)))
	var picture := ICON.make(icon_kind, side * 0.62, tint)
	picture.position = Vector2(side, side) * 0.19
	disc.add_child(picture)
	return disc


func _choose_folder(id: String) -> void:
	_folder = id; _tag = ""; _starred_only = false; _archived = false; _selected = {}; _asking = ""; _editing = ""
	_selecting = false; _picked.clear(); _renaming = ""
	for row in _side.get_children():
		if row is Button: (row as Button).set_pressed_no_signal(false)
	_build_sidebar(); _show_folder()


# ------------------------------------------------------------------ the open folder
func _folder_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in _entries:
		if _folder == STARRED:
			if not bool(entry.star): continue
		elif _folder == ALL:
			if bool(entry.archived): continue
		else:
			if str(entry.world_id) != _folder or bool(entry.archived) != _archived: continue
		if _starred_only and not bool(entry.star): continue
		if _tag != "" and _tag not in entry.tags: continue
		if _query != "" and not _matches(entry): continue
		out.append(entry)
	return out


func _matches(entry: Dictionary) -> bool:
	var text := " ".join([CATALOGUE.title_text(entry), str(entry.place), str(entry.world_name), str(entry.form),
		" ".join(entry.tags), CATALOGUE.game_time_text(entry)]).to_lower()
	for word in _query.split(" ", false):
		if not text.contains(word): return false
	return true


func _show_folder() -> void:
	if _main == null: return
	# An open menu points at cards about to be rebuilt.
	_close_menu()
	_detail_scroll.hide(); _body.show()
	_clear(_main)
	_grid = null
	_folder_header()
	var chips := HFlowContainer.new(); chips.add_theme_constant_override("h_separation", 6)
	chips.add_theme_constant_override("v_separation", 6); _main.add_child(chips)
	var pool: Array[Dictionary] = []
	for entry in _entries:
		if _folder == ALL or _folder == STARRED or str(entry.world_id) == _folder: pool.append(entry)
	_chip(chips, "All", _tag == "" and not _starred_only, func() -> void: _tag = ""; _starred_only = false; _show_folder())
	if _folder != STARRED:
		_chip(chips, "Starred", _starred_only, func() -> void: _starred_only = not _starred_only; _show_folder(), "star_filled")
	var tags: Array[String] = []
	for entry in pool:
		for tag: String in entry.tags:
			if tag not in tags: tags.append(tag)
	tags.sort()
	for tag in tags:
		var chip := _chip(chips, tag, _tag == tag, func() -> void: _tag = "" if _tag == tag else tag; _show_folder(), "tag")
		chip.add_theme_color_override("icon_normal_color", STYLE.swatch_for(tag))
	if not _folder in [ALL, STARRED]:
		var archived := pool.filter(func(e: Dictionary) -> bool: return bool(e.archived)).size()
		if archived > 0 or _archived:
			_chip(chips, "Archive · %d" % archived, _archived, func() -> void: _archived = not _archived; _show_folder(), "archive")
	_chip(chips, "Select", _selecting, _toggle_selecting, "check")
	var sort_chip := _chip(chips, _sort_label(), false, func() -> void: pass, "sort")
	sort_chip.pressed.connect(func() -> void: sort_chip.set_pressed_no_signal(false); _open_sort_menu(sort_chip))
	_grid_scroll = ScrollContainer.new(); _grid_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; _grid_scroll.follow_focus = true
	_grid_scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _redraw())
	_main.add_child(_grid_scroll)
	var pad := MarginContainer.new(); pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_theme_constant_override("margin_right", 12); pad.add_theme_constant_override("margin_top", 6)
	pad.add_theme_constant_override("margin_left", 6); pad.add_theme_constant_override("margin_bottom", 6)
	_grid_scroll.add_child(pad)
	_grid = GridContainer.new(); _grid.columns = _columns
	_grid.add_theme_constant_override("h_separation", int(GAP)); _grid.add_theme_constant_override("v_separation", int(GAP))
	pad.add_child(_grid)
	var shown := _sorted(_folder_entries())
	_shown = shown
	# Picks stay among the saves shown (a filter or a search hides the others from bulk actions).
	var visible_paths := {}
	for entry in shown: visible_paths[str(entry.path)] = true
	for path: String in _picked.keys():
		if not visible_paths.has(path): _picked.erase(path)
	var card_width := floorf((_page_size.x - _sidebar_width - 18.0 - 32.0 - GAP * (_columns - 1)) / _columns)
	for entry in shown: _card(entry, card_width)
	if shown.is_empty():
		var empty := STYLE.label(_empty_text(), "Muted", font_size - 2)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; empty.custom_minimum_size.x = card_width * _columns
		_grid.add_child(empty)
	_bulk = null
	if _selecting:
		_bulk = VBoxContainer.new(); _bulk.add_theme_constant_override("separation", 8); _main.add_child(_bulk)
		_fill_bulk()
	_appear(_main)
	_redraw()
	if _fresh_path != "": _sparkle_fresh.call_deferred()


func _empty_text() -> String:
	if _query != "": return "No save matches “%s”." % _query
	if _tag != "": return "No save here carries the tag “%s”." % _tag
	if _folder == STARRED or _starred_only: return "Nothing starred yet. Open a save and press its star to keep it here."
	if _archived: return "The archive is empty."
	if saves != null and _folder == _here: return "No saves in this world yet. Press New save; autosaves also happen every minute."
	return "No saved games yet."


func _folder_header() -> void:
	var head := HBoxContainer.new(); head.add_theme_constant_override("separation", 12); _main.add_child(head)
	var group := _group(_folder)
	var tint: Color = STYLE.BUTTER if group.is_empty() else STYLE.SWATCHES[int(group.world_color) % STYLE.SWATCHES.size()]
	var icon_kind := "sparkle" if _folder == ALL else ("star_filled" if _folder == STARRED else str(group.world_icon))
	var badge := _badge(icon_kind, tint, font_size * 2.6); badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(badge)
	var texts := VBoxContainer.new(); texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.add_theme_constant_override("separation", 0); head.add_child(texts)
	var title := "All saves" if _folder == ALL else ("Starred" if _folder == STARRED else str(group.world_name))
	var name_label := STYLE.label(title, "Heading", font_size + 6); name_label.add_theme_color_override("font_color", tint.lerp(Color.WHITE, 0.25))
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS; name_label.clip_text = true
	texts.add_child(name_label)
	if not group.is_empty():
		name_label.mouse_filter = Control.MOUSE_FILTER_STOP; name_label.tooltip_text = "Click to rename"
		name_label.mouse_default_cursor_shape = Control.CURSOR_IBEAM
		name_label.gui_input.connect(_world_title_input)
	var details: Array[String] = []
	if group.is_empty():
		details.append("Every world, newest first" if _folder == ALL else "Your starred saves from every world")
	else:
		if str(group.form) != "": details.append(str(group.form))
		if str(group.world_started) != "": details.append("started " + str(group.world_started))
		var archived := (group.entries as Array).filter(func(e: Dictionary) -> bool: return bool(e.archived)).size()
		var count := (group.entries as Array).size() - archived
		details.append("%d save%s" % [count, "" if count == 1 else "s"] + (", %d archived" % archived if archived > 0 else ""))
		if str(group.world_id) == _here: details.append("you are here")
	texts.add_child(STYLE.label(" · ".join(details), "Muted", font_size - 4))
	if not group.is_empty():
		_icon_button(head, "pencil", "Rename this world", func() -> void: _toggle_editor("rename_world"))
		_icon_button(head, "palette", "Folder colour and picture", func() -> void: _toggle_editor("look"))
		if str(group.world_id) != _here:
			_icon_button(head, "trash", "Delete this world", func() -> void: _asking = "delete_world" if _asking != "delete_world" else ""; _show_folder())
		if _editing == "rename_world":
			_rename_editor(str(group.world_name), _rename_world)
		elif _editing == "look":
			_look_editor(group)
		if _asking == "delete_world":
			_confirm_world(group)


func _rename_world(text: String) -> void:
	SHELF.set_world(root.path_join(_folder), {"name": text})
	_editing = ""
	refresh()


func _toggle_editor(which: String) -> void:
	_editing = "" if _editing == which else which
	_asking = ""
	_redisplay()


func _rename_editor(current: String, done: Callable) -> void:
	var line := HBoxContainer.new(); line.add_theme_constant_override("separation", 8)
	(_detail if _detail_scroll.visible else _main).add_child(line)
	var field := LineEdit.new(); field.text = current; field.max_length = SHELF.MAX_NAME
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL; field.custom_minimum_size.y = font_size * 2.0
	field.select_all_on_focus = true
	field.text_submitted.connect(func(text: String) -> void: done.call(SHELF.clean_name(text)))
	line.add_child(field)
	_button(line, "Save", func() -> void: done.call(SHELF.clean_name(field.text)), "", "check")
	_button(line, "Cancel", func() -> void: _toggle_editor(_editing), "Ghost")
	field.grab_focus.call_deferred()


func _look_editor(group: Dictionary) -> void:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.1), 1, 16, 14, 10)))
	_main.add_child(box)
	var rows := VBoxContainer.new(); rows.add_theme_constant_override("separation", 8); box.add_child(rows)
	var tint: Color = STYLE.SWATCHES[int(group.world_color) % STYLE.SWATCHES.size()]
	var pictures := HFlowContainer.new(); pictures.add_theme_constant_override("h_separation", 6); rows.add_child(pictures)
	for kind: String in SHELF.ICONS:
		var b := Button.new(); b.theme_type_variation = "Round"; b.toggle_mode = true
		b.set_pressed_no_signal(kind == str(group.world_icon))
		b.icon = ICON.texture(kind, font_size + 4); b.custom_minimum_size = Vector2(font_size * 2.2, font_size * 2.2)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.add_theme_color_override("icon_normal_color", tint); b.add_theme_color_override("icon_pressed_color", Color.WHITE)
		b.pressed.connect(func() -> void: SHELF.set_world(root.path_join(str(group.world_id)), {"icon": kind}); refresh())
		_hover_redraw(b); pictures.add_child(b)
	var colors := HFlowContainer.new(); colors.add_theme_constant_override("h_separation", 8); rows.add_child(colors)
	for i in STYLE.SWATCHES.size():
		var dot := Button.new(); dot.custom_minimum_size = Vector2(font_size * 1.8, font_size * 1.8)
		var chosen := i == int(group.world_color)
		for state: String in ["normal", "hover", "pressed", "focus"]:
			dot.add_theme_stylebox_override(state, STYLE.rounded(STYLE.box(STYLE.SWATCHES[i], Color.WHITE if chosen or state == "hover" else Color(1, 1, 1, 0.2), 3 if chosen else 1, 99, 0, 0)))
		dot.pressed.connect(func() -> void: SHELF.set_world(root.path_join(str(group.world_id)), {"color": i}); refresh())
		_hover_redraw(dot); colors.add_child(dot)


func _confirm_world(group: Dictionary) -> void:
	var count := (group.entries as Array).size()
	_confirm_bar(_main, "Delete “%s” for good? Its %d save%s and everything its ponies remember go with it." % [group.world_name, count, "" if count == 1 else "s"],
		"Delete world", func() -> void:
			var problem := SHELF.delete_world(root, str(group.world_id))
			_asking = ""
			_status.text = "“%s” is gone." % group.world_name if problem == "" else "Could not delete the world: %s." % problem
			_folder = ALL; refresh())


func _confirm_bar(parent: Control, text: String, yes: String, action: Callable) -> void:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(STYLE.CORAL, 0.12), Color(STYLE.CORAL, 0.5), 1, 16, 16, 10)))
	parent.add_child(bar)
	var line := HBoxContainer.new(); line.add_theme_constant_override("separation", 10); bar.add_child(line)
	var words := STYLE.label(text, "", font_size - 3); words.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	words.size_flags_horizontal = Control.SIZE_EXPAND_FILL; line.add_child(words)
	_button(line, yes, action, "Danger", "trash").size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_button(line, "Keep it", func() -> void: _asking = ""; _redisplay(), "Ghost").size_flags_vertical = Control.SIZE_SHRINK_CENTER


## Shows again whatever is open: the folder, or the save's page.
func _redisplay() -> void:
	if _selected.is_empty(): _show_folder()
	else: _show_save(_selected)


# ------------------------------------------------------------------ cards
func _card(entry: Dictionary, width: float) -> Button:
	var path := str(entry.path)
	var card := Button.new(); card.theme_type_variation = "Card"
	var picture_height := roundf(width * 9.0 / 16.0)
	card.custom_minimum_size = Vector2(width, picture_height + font_size * 3.6 + 16)
	card.set_meta("path", path)
	if _selecting:
		# Picking: a press picks or unpicks the save (Shift: everything since the last one).
		card.toggle_mode = true; card.set_pressed_no_signal(_picked.has(path))
		card.pressed.connect(_pick_card.bind(entry))
	else:
		card.pressed.connect(_show_save.bind(entry))
		card.gui_input.connect(_card_input.bind(entry, card))
	_hover_redraw(card)
	_grid.add_child(card)
	var pad := 6.0
	var picture := _picture(str(entry.get("preview", "")), Vector2(width - pad * 2, picture_height - pad), 13.0)
	picture.position = Vector2(pad, pad)
	card.add_child(picture)
	var kind := _kind_badge(entry)
	kind.position = Vector2(pad + 8, pad + 8)
	card.add_child(kind)
	if _selecting:
		var mark := _pick_mark(_picked.has(path))
		mark.position = Vector2(pad + 8, pad + 8); card.add_child(mark); card.set_meta("pick_mark", mark)
		kind.position.x += mark.custom_minimum_size.x + 6
	if bool(entry.star):
		var star := ICON.make("star_filled", font_size + 2, STYLE.BUTTER)
		star.position = Vector2(width - pad - font_size - 12, pad + 8)
		card.add_child(star); card.set_meta("star_mark", star)
	if not _selecting and _renaming != path: _add_quick(card, entry)
	if not (entry.tags as Array).is_empty():
		var tags := HBoxContainer.new(); tags.add_theme_constant_override("separation", 4); tags.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tags.position = Vector2(pad + 8, picture_height - font_size * 1.35 - 4)
		card.add_child(tags)
		var list: Array = entry.tags
		for i in mini(2, list.size()): tags.add_child(_tag_pill(str(list[i]), font_size - 7))
		if list.size() > 2: tags.add_child(_tag_pill("+%d" % (list.size() - 2), font_size - 7, STYLE.MUTED))
	var texts := VBoxContainer.new(); texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.position = Vector2(pad + 6, picture_height + 6); texts.size = Vector2(width - pad * 2 - 12, font_size * 3.4)
	texts.add_theme_constant_override("separation", 0)
	card.add_child(texts)
	var title: Control
	if _renaming == path:
		# Renamed in place: Enter (or leaving the field) keeps it, Escape leaves it as it was.
		var field := LineEdit.new(); field.max_length = SHELF.MAX_NAME
		field.text = _rename_draft if _rename_draft != "" else str(entry.get("name", ""))
		field.placeholder_text = CATALOGUE.title_text(entry); field.select_all_on_focus = true
		field.add_theme_font_size_override("font_size", font_size - 3); field.custom_minimum_size.y = font_size * 1.6
		field.text_submitted.connect(func(text: String) -> void: _finish_rename(path, text))
		field.focus_exited.connect(func() -> void: _finish_rename(path, field.text, field))
		field.gui_input.connect(_rename_field_input.bind(field))
		title = field
		field.grab_focus.call_deferred()
	else:
		title = STYLE.label(CATALOGUE.title_text(entry), "", font_size - 2); title.add_theme_font_override("font", STYLE.BOLD)
	var lines: Array = [title, STYLE.label(CATALOGUE.game_time_text(entry) + (" · " + str(entry.place) if str(entry.place) != "" else ""), "Muted", font_size - 5),
		STYLE.label(_saved_line(entry), "Faint", font_size - 6) if _blocked(entry).is_empty() else STYLE.label(_blocked(entry), "Warn", font_size - 6)]
	for line: Control in lines:
		if line is Label:
			(line as Label).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS; (line as Label).clip_text = true
			line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.custom_minimum_size.x = texts.size.x
		texts.add_child(line)
	if bool(entry.archived) or bool(entry.newer): card.modulate = Color(1, 1, 1, 0.78)
	if not _blocked(entry).is_empty(): card.modulate = Color(0.78, 0.78, 0.78, 0.55); card.tooltip_text = _blocked(entry)
	return card


## Why this save cannot load with this launch's mods ("" when it can).
func _blocked(entry: Dictionary) -> String:
	return str(entry.get("blocked", ""))


## Load is off for a newer-version save, a save the mods running now cannot load, or while busy.
func _cannot_load(entry: Dictionary, busy: bool) -> bool:
	return bool(entry.newer) or busy or not _blocked(entry).is_empty()


## A card's own buttons (Load, Star, More), shown while the pointer or the focus is on it.
func _add_quick(card: Button, entry: Dictionary) -> void:
	var width := card.custom_minimum_size.x
	var pad := 6.0
	var quick := HBoxContainer.new(); quick.add_theme_constant_override("separation", 4); quick.visible = false
	card.add_child(quick); card.set_meta("quick", quick)
	var busy := saves != null and bool(saves.busy)
	var play := _small_round(quick, "play", "Load this save" if _blocked(entry).is_empty() else _blocked(entry), func() -> void: load_requested.emit(entry))
	play.disabled = _cannot_load(entry, busy)
	var star_button := _small_round(quick, "star_filled" if bool(entry.star) else "star", "Unstar" if bool(entry.star) else "Star", _star.bind(entry))
	star_button.add_theme_color_override("icon_normal_color", STYLE.BUTTER)
	var more := _small_round(quick, "dots", "More", func() -> void: pass)
	more.pressed.connect(func() -> void: _open_save_menu(entry, more, Vector2(0, more.size.y + 4), more.size.y + 8))
	quick.position = Vector2(width - pad - 8 - quick.get_combined_minimum_size().x, pad + 6)
	for node: Control in [card, play, star_button, more]:
		node.mouse_entered.connect(_quick.bind(card, true)); node.mouse_exited.connect(_quick.bind(card, false))
		node.focus_entered.connect(_quick.bind(card, true)); node.focus_exited.connect(_quick.bind(card, false))


func _saved_line(entry: Dictionary) -> String:
	var where := "" if _folder != ALL and _folder != STARRED else str(entry.world_name) + " · "
	return where + CATALOGUE.when_text(float(entry.saved_at)) + " · " + CATALOGUE.play_text(float(entry.play_seconds))


func _kind_badge(entry: Dictionary) -> Control:
	var kind := str(entry.kind)
	var text: String = {"quit": "Quit save", "autosave": "Autosave"}.get(kind, "Manual")
	var tint: Color = {"quit": STYLE.LILAC, "autosave": STYLE.SKY}.get(kind, STYLE.PINK)
	if bool(entry.archived): text = "Archived"; tint = STYLE.FAINT
	if bool(entry.newer): text = "Newer version"; tint = STYLE.CORAL
	elif not _blocked(entry).is_empty(): text = "Needs a mod" if _blocked(entry).begins_with("Needs") else "Turn a mod off"; tint = STYLE.CORAL
	var pill := PanelContainer.new(); pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(0.08, 0.04, 0.14, 0.78), Color(tint, 0.9), 1, 99, 9, 1)))
	var label := STYLE.label(text, "", font_size - 8); label.add_theme_color_override("font_color", tint.lerp(Color.WHITE, 0.35))
	label.add_theme_font_override("font", STYLE.BOLD); label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.add_child(label)
	return pill


func _tag_pill(text: String, size_px: int, tint := Color(0, 0, 0, 0)) -> Control:
	var color := STYLE.swatch_for(text) if tint.a == 0.0 else tint
	var pill := PanelContainer.new(); pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(0.08, 0.04, 0.14, 0.8), Color(color, 0.85), 1, 99, 8, 1)))
	var label := STYLE.label(text, "", size_px); label.add_theme_color_override("font_color", color.lerp(Color.WHITE, 0.4))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.add_child(label)
	return pill


func _picture(path: String, picture_size: Vector2, radius: float) -> Control:
	var texture := _texture(path)
	if texture == null:
		var empty := Panel.new(); empty.size = picture_size; empty.custom_minimum_size = picture_size
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		empty.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(1, 1, 1, 0.06), Color.TRANSPARENT, 0, int(radius), 0, 0)))
		var mark := ICON.make("image", picture_size.y * 0.32, Color(STYLE.MUTED, 0.5))
		mark.position = (picture_size - mark.size) * 0.5
		empty.add_child(mark)
		return empty
	var rect := TextureRect.new(); rect.texture = texture
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE; rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	rect.size = picture_size; rect.custom_minimum_size = picture_size; rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _rounded == null:
		_rounded = Shader.new(); _rounded.code = ROUNDED
	var mat := ShaderMaterial.new(); mat.shader = _rounded
	mat.set_shader_parameter("size_px", picture_size); mat.set_shader_parameter("radius", radius)
	rect.material = mat
	return rect


func _texture(path: String) -> Texture2D:
	if path == "": return null
	var stamp := FileAccess.get_modified_time(path)
	var cached: Array = _textures.get(path, [])
	if not cached.is_empty() and int(cached[0]) == stamp: return cached[1]
	var texture := PREVIEW.texture(path)
	_textures[path] = [stamp, texture]
	return texture


func _sparkle_fresh() -> void:
	if _grid == null or fx == null: _fresh_path = ""; return
	for card in _grid.get_children():
		if card is Button and str(card.get_meta("path", "")) == _fresh_path:
			var centre: Vector2 = card.get_global_transform_with_canvas().origin + card.size * 0.5 - fx.get_global_transform_with_canvas().origin
			fx.burst_at(centre, 14)
	_fresh_path = ""


# ------------------------------------------------------------------ one save's page
func _show_save(entry: Dictionary) -> void:
	_close_menu()
	_selected = entry
	_body.hide(); _detail_scroll.show()
	_clear(_detail)
	var top := HBoxContainer.new(); top.add_theme_constant_override("separation", 10); _detail.add_child(top)
	_button(top, "Back to " + ("all saves" if _folder == ALL else ("starred" if _folder == STARRED else str(entry.world_name))),
		_back_to_folder, "Ghost", "back")
	var spring := Control.new(); spring.size_flags_horizontal = Control.SIZE_EXPAND_FILL; top.add_child(spring)
	var star := _chip(top, "Starred" if bool(entry.star) else "Star", bool(entry.star), func() -> void:
		SHELF.set_save(str(entry.path), {"star": not bool(entry.star)}); refresh(), "star_filled")
	star.add_theme_color_override("icon_normal_color", STYLE.BUTTER); star.add_theme_color_override("icon_pressed_color", STYLE.BUTTER)
	var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 18); _detail.add_child(row)
	var picture_width := roundf(minf(_page_size.x * 0.56, 720.0))
	var holder := Control.new(); holder.custom_minimum_size = Vector2(picture_width, roundf(picture_width * 9.0 / 16.0))
	row.add_child(holder)
	holder.add_child(_picture(str(entry.get("preview", "")), holder.custom_minimum_size, 18.0))
	var badge := _kind_badge(entry); badge.position = Vector2(12, 12); holder.add_child(badge)
	var info := VBoxContainer.new(); info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 6); row.add_child(info)
	var title_row := HBoxContainer.new(); title_row.add_theme_constant_override("separation", 6); info.add_child(title_row)
	var title := STYLE.label(CATALOGUE.title_text(entry), "Heading", font_size + 6)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	_icon_button(title_row, "pencil", "Rename this save", func() -> void: _toggle_editor("rename_save"))
	var facts: Array = [
		[CATALOGUE.game_time_text(entry), "clock"],
		[str(entry.place) if str(entry.place) != "" else "Somewhere in Equestria", "map"],
		["As %s · in %s" % [str(entry.form).to_lower() if str(entry.form) != "Human" else "a human", str(entry.world_name)], "pony"],
		["Saved %s · %s" % [CATALOGUE.when_text(float(entry.saved_at)), CATALOGUE.play_text(float(entry.play_seconds))], "save"]]
	for fact: Array in facts:
		var line := HBoxContainer.new(); line.add_theme_constant_override("separation", 8); info.add_child(line)
		var mark := ICON.make(str(fact[1]), font_size - 2, STYLE.LILAC); mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		line.add_child(mark)
		var text := STYLE.label(str(fact[0]), "Muted", font_size - 3); text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL; line.add_child(text)
	if bool(entry.newer): info.add_child(STYLE.label("Made by a newer version of the game: it cannot be loaded here.", "Warn", font_size - 4))
	elif not _blocked(entry).is_empty():
		var why := STYLE.label(_blocked(entry) + ".", "Warn", font_size - 4); why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.add_child(why)
	elif bool(entry.backup): info.add_child(STYLE.label("Recovered from its backup copy.", "Warn", font_size - 4))
	if _editing == "rename_save":
		_rename_editor(str(entry.get("name", "")), _rename_save.bind(entry))
	var tags := HFlowContainer.new(); tags.add_theme_constant_override("h_separation", 6); tags.add_theme_constant_override("v_separation", 6)
	_detail.add_child(tags)
	var tag_mark := ICON.make("tag", font_size, STYLE.MUTED); tag_mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tags.add_child(tag_mark)
	for tag: String in entry.tags:
		var chip := _chip(tags, tag + "  ×", true, func() -> void:
			SHELF.set_save(str(entry.path), {"tags": (entry.tags as Array).filter(func(t: String) -> bool: return t != tag)}); refresh())
		chip.tooltip_text = "Remove the tag"
		chip.add_theme_stylebox_override("pressed", STYLE.rounded(STYLE.box(Color(STYLE.swatch_for(tag), 0.28), STYLE.swatch_for(tag), 1, 99, 12, 4)))
	_chip(tags, "Add a tag", _editing == "tag", func() -> void: _toggle_editor("tag"), "plus")
	if _editing == "tag": _tag_editor(entry)
	var spring2 := Control.new(); spring2.size_flags_vertical = Control.SIZE_EXPAND_FILL; _detail.add_child(spring2)
	if _asking == "delete":
		_confirm_bar(_detail, "Delete “%s” for good? It cannot come back." % CATALOGUE.title_text(entry), "Delete forever", _delete.bind(entry))
	var actions := HBoxContainer.new(); actions.add_theme_constant_override("separation", 10); _detail.add_child(actions)
	var busy := saves != null and bool(saves.busy)
	var load_button := _button(actions, "Load this save", func() -> void: load_requested.emit(entry), "Primary", "play")
	load_button.disabled = _cannot_load(entry, busy)
	load_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var here := saves != null and str(entry.world_id) == _here
	if here and str(entry.kind) == "manual" and not bool(entry.archived) and not bool(entry.newer):
		_button(actions, "Save over it", func() -> void: _save_over(entry), "", "save").disabled = busy
	if bool(entry.archived): _button(actions, "Take out of archive", _unarchive.bind(entry), "", "archive").disabled = busy
	else: _button(actions, "Archive", _archive.bind(entry), "", "archive").disabled = busy
	_button(actions, "Delete", func() -> void: _asking = "delete" if _asking != "delete" else ""; _show_save(entry), "Danger", "trash").disabled = busy
	_appear(_detail)
	_redraw()
	load_button.grab_focus.call_deferred()


func _rename_save(text: String, entry: Dictionary) -> void:
	SHELF.set_save(str(entry.path), {"name": text})
	_editing = ""
	refresh()


func _tag_editor(entry: Dictionary) -> void:
	_tag_strip(_detail, entry.tags, func(tag: String) -> void: _add_tag(entry, tag))


## Tag ideas as chips and a field for a new one; `apply` takes the chosen tag. `have`: tags already on.
func _tag_strip(parent: Control, have: Array, apply: Callable) -> void:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.1), 1, 16, 14, 10)))
	parent.add_child(box)
	var rows := VBoxContainer.new(); rows.add_theme_constant_override("separation", 8); box.add_child(rows)
	var known := SHELF.all_tags(root).filter(func(t: String) -> bool: return t not in have)
	for idea: String in ["Favourite", "Before a big choice", "Cozy", "Adventure", "Funny", "Test"]:
		if idea not in known and idea not in have: known.append(idea)
	var ideas := HFlowContainer.new(); ideas.add_theme_constant_override("h_separation", 6); ideas.add_theme_constant_override("v_separation", 6)
	rows.add_child(ideas)
	for tag: String in known.slice(0, 14):
		var chip := _chip(ideas, tag, false, apply.bind(tag), "tag")
		chip.add_theme_color_override("icon_normal_color", STYLE.swatch_for(tag))
	var line := HBoxContainer.new(); line.add_theme_constant_override("separation", 8); rows.add_child(line)
	var field := LineEdit.new(); field.placeholder_text = "A new tag…"; field.max_length = SHELF.MAX_TAG
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL; field.custom_minimum_size.y = font_size * 2.0
	field.text_submitted.connect(func(text: String) -> void: apply.call(text))
	line.add_child(field)
	_button(line, "Add", func() -> void: apply.call(field.text), "", "plus")


func _add_tag(entry: Dictionary, tag: String) -> void:
	var clean := SHELF.clean_tag(tag)
	if clean.is_empty(): return
	var tags: Array = (entry.tags as Array).duplicate()
	if clean in tags: return
	if tags.size() >= SHELF.MAX_TAGS: _status.text = "A save keeps at most %d tags." % SHELF.MAX_TAGS; return
	tags.append(clean)
	SHELF.set_save(str(entry.path), {"tags": tags})
	refresh()


func _back_to_folder() -> void:
	_selected = {}; _asking = ""; _editing = ""
	_show_folder()


# ------------------------------------------------------------------ doing things
func _save_new() -> void:
	if saves == null: return
	if saves.save_new(""):
		_folder = _here; _selected = {}; _tag = ""; _archived = false; _starred_only = false
		_status.text = "Saving…"
	else:
		_status.text = CURRENCY.text(str(saves.message)) if str(saves.message) != "" else "Cannot save right now."


func _save_over(entry: Dictionary) -> void:
	if saves == null: return
	var name := str(entry.get("name", ""))
	if not saves.save_to(str(entry.path), "“%s”" % name if name != "" else "Game", "manual"): _status.text = CURRENCY.text(str(saves.message))
	_fresh_path = str(entry.path)


## One save into the archive (the running world's through GameSaves): "" when done, else why not.
func _archive_one(entry: Dictionary) -> String:
	if saves != null and str(entry.world_id) == _here:
		return "" if saves.archive(str(entry.path)) else _saves_problem()
	return SHELF.move_checkpoint(str(entry.path), SHELF.archive_target(str(entry.path)))


func _unarchive_one(entry: Dictionary) -> String:
	if saves != null and str(entry.world_id) == _here:
		return "" if saves.unarchive(str(entry.path)) else _saves_problem()
	return SHELF.move_checkpoint(str(entry.path), SHELF.restore_target(str(entry.path)))


func _delete_one(entry: Dictionary) -> String:
	if saves != null and str(entry.world_id) == _here:
		return "" if saves.delete(str(entry.path)) else _saves_problem()
	return SHELF.delete_checkpoint(str(entry.path))


func _saves_problem() -> String:
	return str(saves.message).trim_suffix(".") if str(saves.message) != "" else "the game is busy saving"


func _archive(entry: Dictionary) -> void:
	var problem := _archive_one(entry)
	_status.text = "Moved to the archive." if problem == "" else "Could not archive it: %s." % problem
	_selected = {}; refresh()


func _unarchive(entry: Dictionary) -> void:
	var problem := _unarchive_one(entry)
	_status.text = "Back among the saves." if problem == "" else "Could not take it out: %s." % problem
	_archived = false; _selected = {}; refresh()


func _delete(entry: Dictionary) -> void:
	_asking = ""
	var problem := _delete_one(entry)
	_status.text = "Save deleted." if problem == "" else "Could not delete it: %s." % problem
	_selected = {}; refresh()


# ------------------------------------------------------------------ quick actions
## A card's buttons show while the pointer or the focus is on it (or on one of them).
func _quick(card: Control, on: bool) -> void:
	if not is_instance_valid(card) or not card.has_meta("quick"): return
	var quick: Control = card.get_meta("quick")
	if not on:
		var owner := get_viewport().gui_get_focus_owner()
		if owner != null and (owner == card or card.is_ancestor_of(owner)): return
		if card.get_global_rect().has_point(card.get_global_mouse_position()): return
	if quick.visible == on: return
	quick.visible = on
	if card.has_meta("star_mark"): (card.get_meta("star_mark") as Control).visible = not on
	_redraw()


func _small_round(parent: Node, icon_kind: String, tip: String, action: Callable) -> Button:
	var b := Button.new(); b.theme_type_variation = "Round"; b.icon = ICON.texture(icon_kind, font_size - 4)
	b.tooltip_text = tip; b.custom_minimum_size = Vector2(font_size * 1.7, font_size * 1.7)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.add_theme_stylebox_override("normal", STYLE.rounded(STYLE.box(Color(0.08, 0.04, 0.14, 0.85), Color(1, 1, 1, 0.3), 1, 99, 4, 4)))
	b.pressed.connect(action)
	_hover_redraw(b)
	parent.add_child(b)
	return b


## Right click: the card's menu. Shift or Ctrl click: start picking with this save.
func _card_input(event: InputEvent, entry: Dictionary, card: Control) -> void:
	if not (event is InputEventMouseButton) or not event.pressed: return
	var click := event as InputEventMouseButton
	if click.button_index == MOUSE_BUTTON_RIGHT:
		card.accept_event(); _open_save_menu(entry, card, card.get_local_mouse_position())
	elif click.button_index == MOUSE_BUTTON_LEFT and (click.shift_pressed or click.ctrl_pressed or Input.is_key_pressed(KEY_SHIFT) or Input.is_key_pressed(KEY_CTRL)):
		card.accept_event(); _select_from.call_deferred(str(entry.path))


func _open_save_menu(entry: Dictionary, anchor: Control, at: Vector2, flip := 0.0, confirm_delete := false) -> void:
	var path := str(entry.path)
	var busy := saves != null and bool(saves.busy)
	if confirm_delete:
		_open_menu(anchor, at, [{"label": "Delete “%s” for good? It cannot come back." % CATALOGUE.title_text(entry)},
			{"text": "Delete forever", "icon": "trash", "do": _delete.bind(entry), "danger": true, "off": busy},
			{"text": "Keep it", "icon": "back", "do": Callable()}], flip)
		return
	var items: Array = [
		{"text": "Load", "icon": "play", "do": load_requested.emit.bind(entry), "off": _cannot_load(entry, busy)},
		{"text": "Open", "icon": "image", "do": _show_save.bind(entry)},
		{"text": "Rename", "icon": "pencil", "do": _start_rename.bind(path)},
		{"text": "Unstar" if bool(entry.star) else "Star", "icon": "star_filled", "do": _star.bind(entry)},
		{"text": "Add a tag…", "icon": "tag", "do": _show_tags_for.bind(entry)}]
	if saves != null and str(entry.world_id) == _here and str(entry.kind) == "manual" and not bool(entry.archived) and not bool(entry.newer):
		items.append({"text": "Save over it", "icon": "save", "do": _save_over.bind(entry), "off": busy})
	items.append({"text": "Take out of archive" if bool(entry.archived) else "Archive", "icon": "archive",
		"do": (_unarchive if bool(entry.archived) else _archive).bind(entry), "off": busy})
	items.append({"text": "Select", "icon": "check", "do": _select_from.bind(path)})
	items.append({})
	items.append({"text": "Delete…", "icon": "trash", "danger": true, "off": busy, "do": _open_save_menu.bind(entry, anchor, at, flip, true)})
	_open_menu(anchor, at, items, flip)


## Right click on a world in the sidebar: what can be done with it.
func _world_row_input(event: InputEvent, id: String, row: Control) -> void:
	if event is InputEventMouseButton and event.pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT:
		row.accept_event(); _open_world_menu(id, row, row.get_local_mouse_position())


func _open_world_menu(id: String, anchor: Control, at: Vector2) -> void:
	var group := _group(id)
	if group.is_empty(): return
	var items: Array = [{"label": str(group.world_name)},
		{"text": "Open", "icon": "folder", "do": _choose_folder.bind(id)},
		{"text": "Rename", "icon": "pencil", "do": _world_edit.bind(id, "rename_world")},
		{"text": "Colour and picture", "icon": "palette", "do": _world_edit.bind(id, "look")},
		{"text": "Pick its saves", "icon": "check", "do": _world_edit.bind(id, "select")}]
	if id != _here:
		items.append({})
		items.append({"text": "Delete world…", "icon": "trash", "danger": true, "do": _world_edit.bind(id, "delete")})
	_open_menu(anchor, at, items)


func _world_edit(id: String, what: String) -> void:
	_choose_folder(id)
	match what:
		"rename_world", "look": _editing = what
		"delete": _asking = "delete_world"
		"select": _selecting = true
	_show_folder()


## A click on the open world's name renames it.
func _world_title_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_toggle_editor.call_deferred("rename_world")


func _open_sort_menu(anchor: Control) -> void:
	var items: Array = [{"label": "Show the saves"}]
	for sort: Array in SORTS:
		items.append({"text": str(sort[1]), "icon": "check" if _sort == sort[0] else "", "on": _sort == sort[0], "do": _set_sort.bind(str(sort[0]))})
	_open_menu(anchor, Vector2(0, anchor.size.y + 4), items, anchor.size.y + 8)


func _set_sort(sort: String) -> void:
	_sort = sort; _show_folder()


func _sort_label() -> String:
	for sort: Array in SORTS:
		if sort[0] == _sort: return "Sort: " + str(sort[1])
	return "Sort"


func _sorted(list: Array[Dictionary]) -> Array[Dictionary]:
	var out := list.duplicate()
	match _sort:
		"oldest": out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.saved_at) < float(b.saved_at))
		"name": out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return CATALOGUE.title_text(a).naturalnocasecmp_to(CATALOGUE.title_text(b)) < 0)
		"played": out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.play_seconds) > float(b.play_seconds))
		"day": out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.day) * 24.0 + float(a.hours) > float(b.day) * 24.0 + float(b.hours))
		_: out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.saved_at) > float(b.saved_at))
	return out


func _star(entry: Dictionary) -> void:
	SHELF.set_save(str(entry.path), {"star": not bool(entry.star)})
	_queue_refresh()


func _show_tags_for(entry: Dictionary) -> void:
	_editing = "tag"; _asking = ""; _show_save(entry)


# ------------------------------------------------------------------ renaming in place
func _start_rename(path: String) -> void:
	_close_menu()
	_rename_draft = ""
	_renaming = path; _selected = {}; _editing = ""; _asking = ""
	_show_folder()


func _finish_rename(path: String, text: String, field: LineEdit = null) -> void:
	if _renaming != path: return
	if _tearing_down:
		# The page is being redrawn under the field (an autosave, say): still renaming, with what was
		# typed; the new card shows the field again.
		_rename_draft = text; return
	_renaming = ""; _rename_draft = ""
	var clean := SHELF.clean_name(text)
	SHELF.set_save(path, {"name": clean})
	if field == null:
		_queue_refresh(); return
	# Left by clicking something else: that click must still land, so only this card changes, in
	# place, instead of the page being rebuilt under the pointer.
	var entry := _find(path)
	if not entry.is_empty(): entry.name = clean
	var label := STYLE.label(CATALOGUE.title_text(entry) if not entry.is_empty() else clean, "", font_size - 2)
	label.add_theme_font_override("font", STYLE.BOLD); label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS; label.clip_text = true
	label.custom_minimum_size.x = field.custom_minimum_size.x
	var holder := field.get_parent()
	holder.add_child(label); holder.move_child(label, field.get_index())
	field.hide(); field.queue_free()
	# Its own buttons were left out while it was being renamed.
	var card := holder.get_parent() as Button
	if card != null and not entry.is_empty() and not card.has_meta("quick"): _add_quick(card, entry)
	_redraw()


func _rename_field_input(event: InputEvent, field: LineEdit) -> void:
	if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
		field.accept_event(); _renaming = ""; _rename_draft = ""; _show_folder.call_deferred()


# ------------------------------------------------------------------ picking several saves
func _toggle_selecting() -> void:
	_selecting = not _selecting; _picked.clear(); _last_picked = ""; _asking = ""; _editing = ""
	_show_folder.call_deferred()


func _select_from(path: String) -> void:
	_close_menu()
	_selecting = true; _picked.clear(); _picked[path] = true; _last_picked = path; _asking = ""; _editing = ""
	_show_folder()


func _index_of(path: String) -> int:
	for i in _shown.size():
		if str(_shown[i].path) == path: return i
	return -1


func _pick_card(entry: Dictionary) -> void:
	var path := str(entry.path)
	var from := _index_of(_last_picked)
	var to := _index_of(path)
	if Input.is_key_pressed(KEY_SHIFT) and from >= 0 and to >= 0 and from != to:
		for i in range(mini(from, to), maxi(from, to) + 1): _picked[str(_shown[i].path)] = true
	elif _picked.has(path): _picked.erase(path)
	else: _picked[path] = true
	_last_picked = path
	_refresh_picks()


func _pick_all() -> void:
	for entry in _shown: _picked[str(entry.path)] = true
	_refresh_picks()


func _pick_none() -> void:
	_picked.clear(); _asking = ""; _editing = ""
	_refresh_picks()


func _picked_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in _shown:
		if _picked.has(str(entry.path)): out.append(entry)
	return out


## The cards show what is picked, and the bar under them what can be done with it.
func _refresh_picks() -> void:
	if _grid != null:
		for card in _grid.get_children():
			if not card is Button or not card.has_meta("path"): continue
			var on := _picked.has(str(card.get_meta("path")))
			(card as Button).set_pressed_no_signal(on)
			var old: Variant = card.get_meta("pick_mark") if card.has_meta("pick_mark") else null
			if is_instance_valid(old):
				var mark := _pick_mark(on); mark.position = (old as Control).position
				card.add_child(mark); card.set_meta("pick_mark", mark); (old as Node).queue_free()
	_fill_bulk()


func _pick_mark(on: bool) -> Control:
	var side := font_size * 1.5
	var disc := Panel.new(); disc.custom_minimum_size = Vector2(side, side); disc.size = disc.custom_minimum_size
	disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	disc.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(STYLE.ROSE if on else Color(0.08, 0.04, 0.14, 0.7),
		Color.WHITE if on else Color(1, 1, 1, 0.75), 2, 99, 0, 0)))
	if on:
		var tick := ICON.make("check", side * 0.62, Color.WHITE); tick.position = Vector2(side, side) * 0.19
		disc.add_child(tick)
	return disc


func _fill_bulk() -> void:
	if not is_instance_valid(_bulk): return
	for child in _bulk.get_children():
		# One of these may be what was just pressed: out now, freed after its signal.
		_bulk.remove_child(child); child.queue_free()
	var picked := _picked_entries()
	var none := picked.is_empty()
	var busy := saves != null and bool(saves.busy)
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(STYLE.PINK, 0.08), Color(STYLE.PINK, 0.35), 1, 16, 12, 8)))
	_bulk.add_child(bar)
	var line := HFlowContainer.new(); line.add_theme_constant_override("h_separation", 8); line.add_theme_constant_override("v_separation", 6)
	bar.add_child(line)
	var count := STYLE.label("Click saves to pick them · Shift picks a range" if none else "%d picked" % picked.size(), "", font_size - 3)
	count.add_theme_font_override("font", STYLE.BOLD); count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(count)
	_chip(line, "All", false, _pick_all, "check")
	_chip(line, "None", false, _pick_none)
	var all_starred := not none and picked.all(func(e: Dictionary) -> bool: return bool(e.star))
	_button(line, "Unstar" if all_starred else "Star", _bulk_star, "", "star_filled").disabled = none
	_button(line, "Tag", _bulk_toggle.bind("bulk_tag"), "", "tag").disabled = none
	var in_archive := not none and picked.all(func(e: Dictionary) -> bool: return bool(e.archived))
	_button(line, "Take out of archive" if in_archive else "Archive", _bulk_do.bind("unarchive" if in_archive else "archive"), "", "archive").disabled = none or busy
	_button(line, "Delete", _bulk_toggle.bind("bulk_delete"), "Danger", "trash").disabled = none or busy
	_button(line, "Done", _toggle_selecting, "Ghost", "close")
	if _asking == "bulk_delete" and not none:
		_confirm_bar(_bulk, "Delete %d save%s for good? They cannot come back." % [picked.size(), "" if picked.size() == 1 else "s"],
			"Delete %d" % picked.size(), _bulk_do.bind("delete"))
	if _editing == "bulk_tag" and not none:
		_tag_strip(_bulk, [], _bulk_tag)
	_redraw()


## Opens or closes the bar's question (bulk_delete) or tag strip (bulk_tag).
func _bulk_toggle(which: String) -> void:
	if which == "bulk_delete":
		_asking = "" if _asking == which else which; _editing = ""
	else:
		_editing = "" if _editing == which else which; _asking = ""
	_fill_bulk()


func _bulk_star() -> void:
	var picked := _picked_entries()
	var on := not picked.all(func(e: Dictionary) -> bool: return bool(e.star))
	for entry in picked: SHELF.set_save(str(entry.path), {"star": on})
	_status.text = "%s %d save%s." % ["Starred" if on else "Unstarred", picked.size(), "" if picked.size() == 1 else "s"]
	_queue_refresh()


func _bulk_tag(tag: String) -> void:
	var clean := SHELF.clean_tag(tag)
	if clean.is_empty(): return
	var tagged := 0
	for entry in _picked_entries():
		var tags: Array = (entry.tags as Array).duplicate()
		if clean in tags or tags.size() >= SHELF.MAX_TAGS: continue
		tags.append(clean); SHELF.set_save(str(entry.path), {"tags": tags}); tagged += 1
	_editing = ""
	_status.text = "Tagged %d save%s “%s”." % [tagged, "" if tagged == 1 else "s", clean]
	_queue_refresh()


func _bulk_do(what: String) -> void:
	var done := 0
	var problems: Array[String] = []
	_batch = true
	for entry in _picked_entries():
		var problem := ""
		if what == "archive" and not bool(entry.archived): problem = _archive_one(entry)
		elif what == "unarchive" and bool(entry.archived): problem = _unarchive_one(entry)
		elif what == "delete": problem = _delete_one(entry)
		else: continue
		if problem == "": done += 1
		else: problems.append(problem)
	_batch = false
	var verb: String = {"archive": "Moved %d save%s to the archive.", "unarchive": "Took %d save%s out of the archive.", "delete": "Deleted %d save%s."}[what]
	_status.text = verb % [done, "" if done == 1 else "s"]
	if not problems.is_empty(): _status.text += " %d could not be: %s." % [problems.size(), problems[0]]
	_picked.clear(); _asking = ""; _editing = ""; _selecting = false; _selected = {}
	if what == "unarchive": _archived = false
	_queue_refresh()


# ------------------------------------------------------------------ the small menu
## A small menu over the page, at `at` in `anchor`'s own coordinates (above it when there is no
## room below: `flip` more up); a click elsewhere or Escape closes it. Items: {"text", "icon",
## "do": Callable, "danger", "on", "off"}, {"label": text}, or {} for a line.
func _open_menu(anchor: Control, at: Vector2, items: Array, flip := 0.0) -> void:
	_close_menu()
	if not is_instance_valid(anchor) or not is_ancestor_of(anchor): anchor = self; at = size * 0.5
	var host := get_parent() as Control
	if host == null: return
	_overlay = Control.new(); _overlay.name = "SaveMenu"; _overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.position = position; _overlay.size = size
	_overlay.gui_input.connect(_overlay_input)
	host.add_child(_overlay)
	var menu := PanelContainer.new()
	var style := STYLE.box(Color(0.16, 0.1, 0.25, 0.98), Color(STYLE.PINK, 0.55), 1, 14, 6, 6)
	style.shadow_color = Color(0, 0, 0, 0.35); style.shadow_size = 12
	menu.add_theme_stylebox_override("panel", style)
	_overlay.add_child(menu)
	var list := VBoxContainer.new(); list.add_theme_constant_override("separation", 1); menu.add_child(list)
	var first: Button = null
	for item: Dictionary in items:
		if item.is_empty(): list.add_child(HSeparator.new()); continue
		if item.has("label"):
			var words := STYLE.label(str(item.label), "Muted", font_size - 4); words.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			words.custom_minimum_size.x = font_size * 11; list.add_child(words); continue
		var b := Button.new(); b.theme_type_variation = "Ghost"; b.text = str(item.text); b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		if str(item.get("icon", "")) != "": b.icon = ICON.texture(str(item.icon), font_size - 2)
		b.add_theme_font_size_override("font_size", font_size - 2)
		b.custom_minimum_size = Vector2(font_size * 10, font_size * 1.85)
		var tint := STYLE.CORAL if bool(item.get("danger", false)) else (STYLE.PINK if bool(item.get("on", false)) else Color(0, 0, 0, 0))
		if tint.a > 0.0:
			for state: String in ["font_color", "font_focus_color", "icon_normal_color", "icon_focus_color"]: b.add_theme_color_override(state, tint)
		b.disabled = bool(item.get("off", false))
		b.set_meta("no_sparkle", true)
		b.pressed.connect(_menu_pick.bind(item.get("do", Callable())))
		_hover_redraw(b); list.add_child(b)
		if first == null and not b.disabled: first = b
	var spot: Vector2 = get_global_transform().affine_inverse() * (anchor.get_global_transform() * at)
	var menu_size := menu.get_combined_minimum_size()
	if spot.y + menu_size.y > size.y - 6.0: spot.y = maxf(6.0, spot.y - menu_size.y - flip)
	spot.x = clampf(spot.x, 6.0, maxf(6.0, size.x - menu_size.x - 6.0))
	menu.position = spot; menu.size = menu_size
	if first != null: first.grab_focus()
	_redraw()


func _overlay_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_overlay.accept_event(); _close_menu()


func _menu_pick(action: Callable) -> void:
	_close_menu()
	if action.is_valid(): action.call()


func _close_menu() -> void:
	if is_instance_valid(_overlay): _overlay.queue_free()
	_overlay = null
	_redraw()


## F2 renames the focused save, Delete deletes it (or the picked ones, after asking), Ctrl+A
## picks every save shown.
func _unhandled_key_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not (event is InputEventKey) or not event.pressed or event.echo: return
	var key := event as InputEventKey
	var owner := get_viewport().gui_get_focus_owner()
	if owner is LineEdit or owner is TextEdit: return
	var card: Control = owner
	while card != null and not card.has_meta("path"): card = card.get_parent() as Control
	var path := str(card.get_meta("path")) if card != null and is_ancestor_of(card) else ""
	if key.keycode == KEY_F2:
		if path != "": _start_rename(path)
		elif not _selected.is_empty(): _toggle_editor("rename_save")
		else: return
	elif key.keycode == KEY_DELETE:
		if _selecting and not _picked.is_empty(): _bulk_toggle("bulk_delete")
		elif path != "" and not _find(path).is_empty(): _open_save_menu(_find(path), card, Vector2(0, card.size.y * 0.5), 0.0, true)
		elif not _selected.is_empty(): _asking = "delete"; _show_save(_selected)
		else: return
	elif key.keycode == KEY_A and (key.ctrl_pressed or key.meta_pressed) and not _detail_scroll.visible:
		_selecting = true
		for entry in _shown: _picked[str(entry.path)] = true
		_show_folder()
	else: return
	get_viewport().set_input_as_handled()


func set_status(text: String) -> void:
	_status.text = text
	_redraw()


# ------------------------------------------------------------------ small parts
func _button(parent: Node, text: String, action: Callable, variation := "", icon_kind := "") -> Button:
	var b := Button.new(); b.text = text; b.theme_type_variation = variation
	b.custom_minimum_size.y = font_size * (2.3 if variation == "Primary" else 2.0)
	b.add_theme_font_size_override("font_size", font_size + (2 if variation == "Primary" else -2))
	if icon_kind != "": b.icon = ICON.texture(icon_kind, font_size)
	b.pressed.connect(action)
	_hover_redraw(b)
	parent.add_child(b)
	return b


func _icon_button(parent: Node, icon_kind: String, tip: String, action: Callable) -> Button:
	var b := Button.new(); b.theme_type_variation = "Round"; b.icon = ICON.texture(icon_kind, font_size)
	b.tooltip_text = tip; b.custom_minimum_size = Vector2(font_size * 2.1, font_size * 2.1)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER; b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.pressed.connect(action)
	_hover_redraw(b)
	parent.add_child(b)
	return b


func _chip(parent: Node, text: String, on: bool, action: Callable, icon_kind := "") -> Button:
	var b := Button.new(); b.theme_type_variation = "Chip"; b.text = text; b.toggle_mode = true
	b.set_pressed_no_signal(on)
	b.add_theme_font_size_override("font_size", font_size - 4)
	b.custom_minimum_size.y = font_size * 1.6
	if icon_kind != "": b.icon = ICON.texture(icon_kind, font_size - 4)
	b.pressed.connect(action)
	b.set_meta("no_lift", true)
	_hover_redraw(b)
	parent.add_child(b)
	return b


## Empties a part of the page that is about to be drawn again. What was pressed to ask for it is
## often in there, still in its own signal: out of the tree now, freed once that is over.
func _clear(container: Node) -> void:
	_tearing_down = true
	for child in container.get_children():
		container.remove_child(child); child.queue_free()
	_tearing_down = false


func _hover_redraw(control: Control) -> void:
	control.mouse_entered.connect(_redraw); control.mouse_exited.connect(_redraw)
	control.focus_entered.connect(_redraw)


## The newly shown folder or page drifts in.
func _appear(node: Control) -> void:
	if STYLE.still() or not is_inside_tree(): return
	node.modulate.a = 0.0
	var tween := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, "modulate:a", 1.0, 0.18)
	tween.parallel().tween_method(func(_v: float) -> void: _redraw(), 0.0, 1.0, 0.18)


## Escape: closes an editor or a question, then a save's page. False when only the folder shows
## (the host closes the browser).
func back() -> bool:
	if is_instance_valid(_overlay): _close_menu(); return true
	if _renaming != "": _renaming = ""; _rename_draft = ""; _show_folder(); return true
	if _editing != "" or _asking != "":
		_editing = ""; _asking = ""; _redisplay(); return true
	if not _selected.is_empty():
		_back_to_folder(); return true
	if _selecting:
		_selecting = false; _picked.clear(); _show_folder(); return true
	return false


## Where keyboard and stick focus starts: the first save, else the folder list.
func first_focus() -> Control:
	if _detail_scroll.visible:
		for node in _detail.find_children("*", "Button", true, false):
			if (node as Button).theme_type_variation == "Primary" and not (node as Button).disabled: return node
	if _grid != null:
		for card in _grid.get_children():
			if card is Button: return card
	for row in _side.get_children():
		if row is Button and (row as Button).button_pressed: return row
	return _close


## Visible, usable controls top to bottom (title screen / VR stick focus).
func focusables() -> Array:
	var out: Array = []
	# An open menu is all there is to choose from.
	if is_instance_valid(_overlay):
		for node in _overlay.find_children("*", "Button", true, false):
			if not (node as Button).disabled: out.append(node)
		return out
	for node in find_children("*", "", true, false):
		if not (node is BaseButton or node is LineEdit): continue
		var control := node as Control
		if not control.is_visible_in_tree() or control.focus_mode == Control.FOCUS_NONE: continue
		if control is BaseButton and (control as BaseButton).disabled: continue
		if _keyboard != null and _keyboard.is_ancestor_of(control): continue
		out.append(control)
	return out


func _process(_delta: float) -> void:
	if _keyboard == null or not is_visible_in_tree(): return
	var owner: Control = get_viewport().gui_get_focus_owner()
	var wanted := owner is LineEdit and is_ancestor_of(owner)
	if wanted != _keyboard.visible:
		_keyboard.visible = wanted
		_redraw()
		if wanted: _reveal_focused.call_deferred(owner)


## The keyboard came in after the field took focus (the scroll followed it before the page got
## shorter): once laid out again, the field being typed in scrolls back into view.
func _reveal_focused(field: Control) -> void:
	await get_tree().process_frame
	if not is_instance_valid(field): return
	# The save's page or the card list (a card renamed in place), whichever holds it.
	var scroll: Node = field.get_parent()
	while scroll != null and scroll != self and not scroll is ScrollContainer: scroll = scroll.get_parent()
	if scroll is ScrollContainer: (scroll as ScrollContainer).ensure_control_visible(field); _redraw()


func _redraw() -> void:
	if redraw.is_valid(): redraw.call()
