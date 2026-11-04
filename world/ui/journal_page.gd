extends Control
## Journal page (dev 2026-10-28: "export in PNG format to show other our discussions/adventures",
## recent or older lines, one character or a group): a world's talk read back as scenes, newest
## first (world/ui/journal_data.gd), narrowed to some ponies, a day, with or without the moments
## between. Click lines to pick them, or take a whole scene; "Make picture" opens the picture
## studio: the look, layout, width, text size, a title and which parts show, with a live preview
## (world/ui/journal_picture.gd), then Save puts the PNG in Pictures/Home Equestria. Same embedding as the
## AI context page: `setup(surface)`, `open(world)`, `closed`, `controls`, `relayout()`; the title
## stands it on its panel, the pause menu on a card.
signal closed
const DATA := preload("res://world/ui/journal_data.gd")
const PICTURE := preload("res://world/ui/journal_picture.gd")
const CATALOGUE := preload("res://world/saves/save_catalogue.gd")
const SHELF := preload("res://world/saves/save_shelf.gd")
const CONTEXT := preload("res://world/ui/ai_context_page.gd")
const STYLE := preload("res://world/ui/menu_style.gd")
const ICON := preload("res://world/ui/menu_icon.gd")
const PONY_DATA := preload("res://world/ui/pony_map_data.gd")
const OVERHEAD := preload("res://world/ai/overhead_dialogue.gd")
const FONT := 20
## Scenes shown at first, newest first; a button adds as many older ones.
const SCENES_SHOWN := 10
## Pony chips shown before "+N more".
const CHIPS_SHOWN := 10
## [option, label, tooltip] for the studio's Show switches.
const PARTS := [["logo", "Logo", "The game's logo on top"], ["world", "World name", "The world's name on top and in the footer"],
	["when", "When & where", "The day, time and place under the title"], ["cast", "Who was there", "Every pony in the picture, with her cutie mark"],
	["headings", "Scene headings", "A heading where each scene starts"], ["portraits", "Cutie marks", "Each speaker's cutie mark beside her words"],
	["times", "Times", "The time beside each name"], ["addressee", "Who they spoke to", "\"to Twilight Sparkle\" beside each name"],
	["moments", "Moments", "Arrivals, rumours and other moments between the lines"],
	["footer", "Footer", "\"Home: Equestria\" at the bottom"], ["date", "Date", "Today's date in the footer"]]
const LAYOUTS := [["bubbles", "Bubbles"], ["script", "Script"]]
## Icon colours for the looks whose chip shows an icon rather than a cutie mark.
const LOOK_TINTS := {"celestia": Color("ffd77a"), "luna": Color("aabdff"), "spike": Color("8fdc6e"), "zecora": Color("f3c35a")}
const WIDTH_NAMES := [["phone", "Phone"], ["standard", "Standard"], ["wide", "Wide"]]
const TEXT_NAMES := [["small", "Small"], ["medium", "Medium"], ["large", "Large"]]
## The picture choices (journal_picture.gd DEFAULTS), read once from their file.
static var options := {}
var worlds_root := CATALOGUE.ROOT
var controls: Array[Control] = []
var panel: Node
var worlds: Array[String] = []
var world_index := 0
var _world: Dictionary = {}
var _chosen: Array[String] = []
var _day := -1
var _moments := true
var _all_chips := false
var _limit := SCENES_SHOWN
## Picked entry ids -> true.
var _picked: Dictionary = {}
var _shown: Array = []
var _busy := false
var _page: VBoxContainer
var _world_box: HBoxContainer
var _world_badge: Panel
var _world_name: Label
var _world_line: Label
var _previous: Button
var _next: Button
var _chips: HFlowContainer
var _chips_scroll: ScrollContainer
var _day_label: Label
var _day_back: Button
var _day_on: Button
var _moments_chip: Button
var _count: Label
var _scroll: ScrollContainer
var _body: VBoxContainer
var _picked_label: Label
var _clear: Button
var _make: Button
var _back: Button
var _filters: Array[Control] = []
var _extra: Array[Control] = []
var _saved: Array[String] = []
## The studio: its entries and scenes, its choices and the preview.
var _studio: Control
var _studio_entries: Array = []
var _studio_scenes: Array = []
var _studio_line: Label
var _studio_status: Label
var _studio_picture: TextureRect
var _studio_reel: ScrollContainer
var _studio_pages: Label
var _studio_controls: Array[Control] = []
var _choice_buttons: Dictionary = {}   # option -> {value: Button}
var _part_chips: Dictionary = {}       # option -> Button
var _title_edit: LineEdit
var _folder_button: Button
var _save_button: Button
var _rendering := false
## Counts studio openings, so a save that finishes after another selection was opened says nothing.
var _studio_generation := 0
var _render_again := false


func setup(surface: Node) -> void:
	panel = surface; mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = STYLE.theme()
	_page = VBoxContainer.new(); _page.add_theme_constant_override("separation", 10)
	_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); add_child(_page)
	var head := HBoxContainer.new(); head.add_theme_constant_override("separation", 12)
	head.custom_minimum_size.y = FONT * 2.6; _page.add_child(head)
	var mark := ICON.make("book", FONT + 10, STYLE.PINK); mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(mark)
	var title := STYLE.label("Journal", "Heading", FONT + 14); title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL; head.add_child(title)
	_world_box = HBoxContainer.new(); _world_box.add_theme_constant_override("separation", 10); head.add_child(_world_box)
	_previous = _round(_world_box, "back", "Previous world", _step_world.bind(-1))
	_world_badge = Panel.new(); _world_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_world_badge.custom_minimum_size = Vector2.ONE * FONT * 2.2; _world_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_world_box.add_child(_world_badge)
	var names := VBoxContainer.new(); names.add_theme_constant_override("separation", 0)
	names.custom_minimum_size.x = FONT * 13; names.size_flags_vertical = Control.SIZE_SHRINK_CENTER; _world_box.add_child(names)
	_world_name = _clipped(STYLE.label("", "Subheading", FONT + 1)); names.add_child(_world_name)
	_world_line = _clipped(STYLE.label("", "Faint", FONT - 5)); names.add_child(_world_line)
	_next = _round(_world_box, "forward", "Next world", _step_world.bind(1))
	# Who: everypony or some of them; then the day and the moments.
	# Many speakers would push the list off the page: past three rows the chips scroll.
	_chips_scroll = ScrollContainer.new(); _chips_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_chips_scroll.follow_focus = true; _page.add_child(_chips_scroll)
	_chips = HFlowContainer.new(); _chips.add_theme_constant_override("h_separation", 6); _chips.add_theme_constant_override("v_separation", 6)
	_chips.size_flags_horizontal = Control.SIZE_EXPAND_FILL; _chips_scroll.add_child(_chips)
	_chips.minimum_size_changed.connect(_fit_chips)
	var when := HBoxContainer.new(); when.add_theme_constant_override("separation", 8); _page.add_child(when)
	_day_back = _round(when, "back", "Earlier day", _step_day.bind(-1))
	_day_label = STYLE.label("", "Subheading", FONT - 2); _day_label.custom_minimum_size.x = FONT * 5.5
	_day_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; _day_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	when.add_child(_day_label)
	_day_on = _round(when, "forward", "Later day", _step_day.bind(1))
	_moments_chip = _button(when, "Moments", _toggle_moments, "Chip")
	_moments_chip.toggle_mode = true; _moments_chip.icon = ICON.texture("sparkle", FONT - 4)
	_moments_chip.tooltip_text = "Arrivals, rumours, a Sonic Rainboom and other moments between the lines"
	_moments_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER; _moments_chip.custom_minimum_size.y = FONT * 1.8
	_count = STYLE.label("", "Faint", FONT - 5); _count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; _count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	when.add_child(_count)
	_filters = [_day_back, _day_on, _moments_chip]
	_scroll = ScrollContainer.new(); _scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; _scroll.follow_focus = true
	_scroll.get_v_scroll_bar().value_changed.connect(func(_value: float) -> void: _refresh_panel())
	_page.add_child(_scroll)
	var holder := MarginContainer.new(); holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side: String in ["left", "top", "bottom"]: holder.add_theme_constant_override("margin_" + side, 4)
	holder.add_theme_constant_override("margin_right", 16); _scroll.add_child(holder)
	_body = VBoxContainer.new(); _body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 12); holder.add_child(_body)
	_body.resized.connect(_refresh_panel)
	_build_footer()
	_build_studio()
	hide()


## Back, what is picked, and Make picture.
func _build_footer() -> void:
	var footer := HBoxContainer.new(); footer.add_theme_constant_override("separation", 10); _page.add_child(footer)
	_back = _button(footer, "Back", func() -> void: closed.emit())
	_back.icon = ICON.texture("back", FONT); _back.custom_minimum_size = Vector2(FONT * 6, FONT * 2.2)
	_back.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_picked_label = STYLE.label("", "Muted", FONT - 4); _picked_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picked_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; _picked_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	footer.add_child(_picked_label)
	_clear = _button(footer, "Clear", _clear_picks, "Ghost")
	_clear.icon = ICON.texture("close", FONT - 4); _clear.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_make = _button(footer, "Make picture", _make_from_picks, "Primary")
	_make.icon = ICON.texture("image", FONT); _make.custom_minimum_size.y = FONT * 2.2
	_make.size_flags_vertical = Control.SIZE_SHRINK_CENTER


## The picture studio over the page: the choices on the left, the first page as it will come out
## on the right, Back to the lines, Open folder and Save picture under them.
func _build_studio() -> void:
	_studio = Control.new(); _studio.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); _studio.hide()
	add_child(_studio)
	var shade := Panel.new(); shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(0.07, 0.04, 0.12, 0.98), Color(STYLE.PINK, 0.35), 1, 22, 0, 0)))
	_studio.add_child(shade)
	var box := VBoxContainer.new(); box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 20; box.offset_right = -20; box.offset_top = 16; box.offset_bottom = -16
	box.add_theme_constant_override("separation", 10); _studio.add_child(box)
	var head := HBoxContainer.new(); head.add_theme_constant_override("separation", 10); box.add_child(head)
	var mark := ICON.make("image", FONT + 6, STYLE.PINK); mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER; head.add_child(mark)
	head.add_child(STYLE.label("Picture", "Heading", FONT + 8))
	_studio_line = _clipped(STYLE.label("", "Faint", FONT - 5)); _studio_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_studio_line.size_flags_vertical = Control.SIZE_SHRINK_CENTER; _studio_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(_studio_line)
	var middle := HBoxContainer.new(); middle.add_theme_constant_override("separation", 16)
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL; box.add_child(middle)
	var choices_scroll := ScrollContainer.new(); choices_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	choices_scroll.follow_focus = true; choices_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	choices_scroll.size_flags_stretch_ratio = 0.9; middle.add_child(choices_scroll)
	choices_scroll.get_v_scroll_bar().value_changed.connect(func(_value: float) -> void: _refresh_panel())
	var choices := VBoxContainer.new(); choices.add_theme_constant_override("separation", 6)
	choices.size_flags_horizontal = Control.SIZE_EXPAND_FILL; choices_scroll.add_child(choices)
	_caption(choices, "LOOK")
	var looks := HFlowContainer.new(); looks.add_theme_constant_override("h_separation", 6); looks.add_theme_constant_override("v_separation", 6)
	choices.add_child(looks)
	_choice_buttons.look = {}
	for item: Array in PICTURE.LOOK_NAMES:
		var chip := _button(looks, str(item[1]), _set_option.bind("look", str(item[0])), "Chip")
		chip.toggle_mode = true; chip.icon = _look_icon(item, chip); chip.custom_minimum_size.y = FONT * 1.8
		chip.tooltip_text = "%s's look" % item[1]
		_choice_buttons.look[str(item[0])] = chip; _studio_controls.append(chip)
	for row: Array in [["LAYOUT", "layout", LAYOUTS], ["WIDTH", "width", WIDTH_NAMES], ["TEXT", "text", TEXT_NAMES]]:
		_caption(choices, str(row[0]))
		_segments(choices, str(row[1]), row[2])
	_caption(choices, "TITLE")
	_title_edit = LineEdit.new(); _title_edit.placeholder_text = "The world's name"; _title_edit.max_length = 80
	_title_edit.clear_button_enabled = true; _title_edit.add_theme_font_size_override("font_size", FONT - 3)
	_title_edit.text_changed.connect(func(text: String) -> void: _set_option("title", text))
	_title_edit.focus_entered.connect(_refresh_panel)
	choices.add_child(_title_edit); _studio_controls.append(_title_edit)
	_caption(choices, "SHOW")
	var parts := HFlowContainer.new(); parts.add_theme_constant_override("h_separation", 6); parts.add_theme_constant_override("v_separation", 6)
	choices.add_child(parts)
	for item: Array in PARTS:
		var chip := _button(parts, str(item[1]), Callable(), "Chip")
		chip.toggle_mode = true; chip.tooltip_text = str(item[2]); chip.custom_minimum_size.y = FONT * 1.7
		chip.add_theme_font_size_override("font_size", FONT - 5)
		chip.toggled.connect(func(on: bool) -> void: _set_option(str(item[0]), on))
		_part_chips[str(item[0])] = chip; _studio_controls.append(chip)
	var reset := _button(choices, "Reset to default", _reset_options, "Ghost")
	reset.icon = ICON.texture("refresh", FONT - 4); reset.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_studio_controls.append(reset)
	var frame := PanelContainer.new(); frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL; frame.size_flags_stretch_ratio = 1.1
	frame.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(0, 0, 0, 0.25), Color(1, 1, 1, 0.08), 1, 16, 10, 10)))
	middle.add_child(frame)
	var shown := VBoxContainer.new(); shown.add_theme_constant_override("separation", 6); frame.add_child(shown)
	# The first page as wide as the frame, scrolled to read it; a whole tall page would be too small.
	var reel := ScrollContainer.new(); reel.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	reel.size_flags_vertical = Control.SIZE_EXPAND_FILL; shown.add_child(reel)
	reel.get_v_scroll_bar().value_changed.connect(func(_value: float) -> void: _refresh_panel())
	_studio_picture = TextureRect.new(); _studio_picture.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_studio_picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE; _studio_picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	reel.add_child(_studio_picture)
	reel.resized.connect(_fit_preview)
	_studio_reel = reel
	_studio_pages = STYLE.label("", "Faint", FONT - 6); _studio_pages.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	shown.add_child(_studio_pages)
	var footer := HBoxContainer.new(); footer.add_theme_constant_override("separation", 10); box.add_child(footer)
	var back_button := _button(footer, "Lines", _close_studio)
	back_button.icon = ICON.texture("back", FONT); back_button.custom_minimum_size = Vector2(FONT * 6, FONT * 2.2)
	back_button.tooltip_text = "Back to the lines"; back_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_studio_status = STYLE.label("", "Muted", FONT - 5); _studio_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_studio_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; _studio_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	footer.add_child(_studio_status)
	_folder_button = _button(footer, "Open folder", _open_folder)
	_folder_button.icon = ICON.texture("folder", FONT - 2); _folder_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_folder_button.custom_minimum_size.y = FONT * 2.2
	_save_button = _button(footer, "Save picture", _save_picture, "Primary")
	_save_button.icon = ICON.texture("save", FONT); _save_button.custom_minimum_size.y = FONT * 2.2
	_save_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_studio_controls.append_array([back_button, _folder_button, _save_button])


## The preview as tall as the frame's width makes it.
func _fit_preview() -> void:
	var texture := _studio_picture.texture
	var wide := _studio_reel.size.x - 12.0
	_studio_picture.custom_minimum_size.y = wide * texture.get_height() / texture.get_width() if texture != null and wide > 0.0 else 0.0


func _caption(parent: Control, text: String) -> void:
	var words := STYLE.label(text, "Faint", FONT - 7)
	if parent.get_child_count() > 0: parent.add_child(_spacer(4))
	parent.add_child(words)


## A choice among a few, side by side in a track.
func _segments(parent: Control, option: String, items: Array) -> void:
	var track := PanelContainer.new(); track.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	track.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(0.05, 0.02, 0.09, 0.4), Color(1, 1, 1, 0.12), 1, 99, 4, 4)))
	parent.add_child(track)
	var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 2); track.add_child(row)
	_choice_buttons[option] = {}
	for item: Array in items:
		var segment := _button(row, str(item[1]), _set_option.bind(option, str(item[0])), "Segment")
		segment.toggle_mode = true
		_choice_buttons[option][str(item[0])] = segment; _studio_controls.append(segment)


## A look's chip: its pony's cutie mark, or its icon in the look's colour (the princesses' marks are
## blank in the map icons; Spike and Zecora have none).
func _look_icon(item: Array, chip: Button) -> Texture2D:
	var mark := _mark_texture(str(item[2])) if str(item[2]) != "" else null
	if mark != null: return mark
	var tint: Color = LOOK_TINTS.get(str(item[0]), STYLE.CREAM)
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]: chip.add_theme_color_override("icon_%s_color" % state, tint)
	return ICON.texture(str(item[3]), FONT - 2)


## The page's size inside its card or panel.
func relayout(page_size: Vector2) -> void:
	size = page_size


## Opens on `world` when it has a journal (the game being played), else the newest world.
func open(world := "") -> void:
	worlds = CONTEXT.world_ids(worlds_root)
	var at := worlds.find(world)
	world_index = at if at >= 0 else clampi(world_index, 0, maxi(0, worlds.size() - 1))
	_studio.hide()
	_load_world()
	show(); _show()
	(controls[0] if not controls.is_empty() else _back).grab_focus()


## The studio's title field has the keyboard (the title forwards keys to it, also in a headset).
func typing() -> bool:
	return visible and _studio.visible and _title_edit.has_focus()


## Escape and the grip: the studio closes first, then the page.
func back() -> void:
	if _studio.visible: _close_studio()
	else: closed.emit()


# ------------------------------------------------------------------ choosing
func _load_world() -> void:
	_world = DATA.read_world(worlds_root, worlds[world_index]) if not worlds.is_empty() else {}
	_chosen.clear(); _day = -1; _picked.clear(); _limit = SCENES_SHOWN; _all_chips = false


func _step_world(direction: int) -> void:
	if worlds.size() < 2: return
	world_index = posmod(world_index + direction, worlds.size())
	_load_world(); _show()


func _step_day(direction: int) -> void:
	var days: Array = _world.get("days", [])
	if days.is_empty(): return
	# All days, then each day in turn.
	var at := days.find(_day)
	at = clampi((at if at >= 0 else days.size()) + direction, 0, days.size())
	_day = days[at] if at < days.size() else -1
	_limit = SCENES_SHOWN; _show()


func _toggle_moments() -> void:
	_moments = _moments_chip.button_pressed; _show()


func _choose(id: String) -> void:
	if id == "": _chosen.clear()
	elif id in _chosen: _chosen.erase(id)
	else: _chosen.append(id)
	_limit = SCENES_SHOWN; _show()


func _toggle_pick(entry: Dictionary, row: Control) -> void:
	if _picked.has(int(entry.id)): _picked.erase(int(entry.id))
	else: _picked[int(entry.id)] = true
	_style_row(row, _picked.has(int(entry.id)), true)
	_update_picks()


## Picks a whole scene, or unpicks it when every line of it was picked.
func _pick_scene(scene: Dictionary, rows: Array[Control], button: Button) -> void:
	var all := (scene.entries as Array).all(func(e: Dictionary) -> bool: return _picked.has(int(e.id)))
	for i in scene.entries.size():
		var id := int(scene.entries[i].id)
		if all: _picked.erase(id)
		else: _picked[id] = true
		_style_row(rows[i], not all, false)
	button.text = "Pick all" if all else "Unpick"
	_update_picks()


func _clear_picks() -> void:
	_picked.clear(); _show()


# ------------------------------------------------------------------ the page
func _show() -> void:
	for child in _body.get_children():
		_body.remove_child(child); child.queue_free()
	_extra.clear()
	_show_world()
	_show_chips()
	var days: Array = _world.get("days", [])
	_day_label.text = "All days" if _day < 0 else "Day %d" % (_day + 1)
	_day_back.disabled = days.is_empty() or _day == days[0]
	_day_on.disabled = _day < 0
	_moments_chip.set_pressed_no_signal(_moments)
	if worlds.is_empty():
		_empty("book", "No worlds yet", "Each world keeps a journal of everything said in it. Start a new game, talk with the ponies, and the conversations show here.")
	elif str(_world.get("error", "")) != "" or (_world.entries as Array).is_empty():
		_empty("chat", "Nothing said yet", str(_world.error) if str(_world.get("error", "")) != "" else "Talk with the ponies in this world and the conversations show here.")
	else:
		_shown = DATA.filtered(_world.scenes, _chosen, _day, _moments)
		var lines := 0
		for scene: Dictionary in _shown: lines += scene.entries.size()
		_count.text = "%d %s · %d %s" % [_shown.size(), "scene" if _shown.size() == 1 else "scenes", lines, "line" if lines == 1 else "lines"]
		if _shown.is_empty():
			_empty("search", "Nothing here", "No conversation matches. Choose other ponies or another day.")
		for scene: Dictionary in _shown.slice(0, _limit): _scene_card(scene)
		if _shown.size() > _limit:
			var older := _button(_body, "Show older scenes (%d more)" % (_shown.size() - _limit), Callable(), "Ghost")
			older.icon = ICON.texture("plus", FONT); older.custom_minimum_size.y = FONT * 2.2
			older.pressed.connect(func() -> void:
				var keep := _scroll.scroll_vertical
				_limit += SCENES_SHOWN; _show()
				_scroll.set_deferred("scroll_vertical", keep))
			_extra.append(older)
	if _shown.is_empty() or worlds.is_empty(): _count.text = ""
	_scroll.scroll_vertical = 0
	_update_picks()


func _update_picks() -> void:
	var count := _picked.size()
	_make.disabled = count == 0
	_clear.visible = count > 0
	if count == 0: _picked_label.text = "Click lines to pick them, or use a scene's Picture button."
	else: _picked_label.text = "%d %s picked" % [count, "line" if count == 1 else "lines"]
	_list_controls()
	_refresh_panel()


func _list_controls() -> void:
	controls = []
	for chip in _chips.get_children(): if chip is Button: controls.append(chip)
	controls.append_array(_filters)
	if worlds.size() > 1: controls.append_array([_previous, _next])
	controls.append_array(_extra)
	if _clear.visible: controls.append(_clear)
	controls.append_array([_make, _back])
	if _studio.visible: controls = _studio_controls.filter(func(c: Control) -> bool: return c.visible)


func _show_world() -> void:
	_previous.disabled = worlds.size() < 2; _next.disabled = worlds.size() < 2
	_previous.visible = worlds.size() > 1; _next.visible = worlds.size() > 1
	var tint := _tint()
	if worlds.is_empty():
		_world_name.text = "No worlds yet"; _world_line.text = ""
	else:
		var id := worlds[world_index]
		_world_name.text = _world_title()
		var bits: Array[String] = []
		if CATALOGUE.world_started(id) != "": bits.append("started " + CATALOGUE.world_started(id))
		if worlds.size() > 1: bits.append("world %d of %d" % [world_index + 1, worlds.size()])
		_world_line.text = " · ".join(bits)
	_world_name.add_theme_color_override("font_color", tint.lerp(Color.WHITE, 0.25))
	for child in _world_badge.get_children(): child.queue_free()
	_world_badge.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(tint, 0.22), Color(tint, 0.7), 1, 99, 0, 0)))
	var kind := "sparkle"
	if not worlds.is_empty(): kind = str(SHELF.world_look(worlds[world_index], SHELF.read(worlds_root.path_join(worlds[world_index]))).icon)
	var picture := ICON.make(kind, _world_badge.custom_minimum_size.x * 0.62, tint)
	picture.position = _world_badge.custom_minimum_size * 0.19
	_world_badge.add_child(picture)


func _tint() -> Color:
	if worlds.is_empty(): return STYLE.FAINT
	var look_of := SHELF.world_look(worlds[world_index], SHELF.read(worlds_root.path_join(worlds[world_index])))
	return STYLE.SWATCHES[int(look_of.color) % STYLE.SWATCHES.size()]


func _world_title() -> String:
	if worlds.is_empty(): return ""
	var id := worlds[world_index]
	var named := str(SHELF.world_look(id, SHELF.read(worlds_root.path_join(id))).name)
	return named if named != "" else CATALOGUE.world_title(worlds_root, id)


## Everypony, then a chip per pony who spoke (most lines first) with her cutie mark.
func _show_chips() -> void:
	for child in _chips.get_children():
		_chips.remove_child(child); child.queue_free()
	var ponies: Array = _world.get("ponies", [])
	if ponies.is_empty(): _chips_scroll.hide(); return
	_chips_scroll.show()
	var everypony := _chip("Everypony", "", _chosen.is_empty())
	everypony.icon = ICON.texture("heart", FONT - 4)
	var shown := ponies if _all_chips else ponies.slice(0, CHIPS_SHOWN)
	for pony: Dictionary in shown:
		var chip := _chip(str(pony.name), str(pony.id), str(pony.id) in _chosen)
		chip.tooltip_text = "%s · %d %s" % [pony.name, pony.lines, "line" if int(pony.lines) == 1 else "lines"]
		chip.icon = _mark_texture(str(pony.id))
	for id in _chosen:
		if not shown.any(func(p: Dictionary) -> bool: return str(p.id) == id): _chip(DATA.name_of(id), id, true).icon = _mark_texture(id)
	if ponies.size() > CHIPS_SHOWN:
		var more := _button(_chips, "Fewer" if _all_chips else "+%d more" % (ponies.size() - CHIPS_SHOWN), func() -> void:
			_all_chips = not _all_chips; _show_chips(); _list_controls(); _refresh_panel(), "Ghost")
		more.custom_minimum_size.y = FONT * 1.8


func _fit_chips() -> void:
	_chips_scroll.custom_minimum_size.y = minf(_chips.get_combined_minimum_size().y, FONT * 1.8 * 3 + 12 + 2)


func _chip(text: String, id: String, on: bool) -> Button:
	var chip := _button(_chips, text, _choose.bind(id), "Chip")
	chip.toggle_mode = true; chip.set_pressed_no_signal(on)
	chip.custom_minimum_size.y = FONT * 1.8; chip.add_theme_font_size_override("font_size", FONT - 4)
	chip.expand_icon = false
	return chip


## Her cutie mark as a small icon, or none.
func _mark_texture(id: String) -> Texture2D:
	PONY_DATA.load_icons()
	var icon: Dictionary = PONY_DATA.icons.get(id, {})
	if icon.is_empty() or PONY_DATA.atlas == null or bool(icon.get("blank", false)): return null
	var region := AtlasTexture.new(); region.atlas = PONY_DATA.atlas
	var rect: Array = icon.rect
	region.region = Rect2(rect[0], rect[1], rect[2], rect[3])
	var image := region.get_image()
	if image == null: return null
	image.resize(FONT, FONT, Image.INTERPOLATE_LANCZOS)
	return ImageTexture.create_from_image(image)


## A scene: when and where and who, Pick all and Picture, then its lines to click.
func _scene_card(scene: Dictionary) -> void:
	var card := PanelContainer.new(); card.mouse_filter = Control.MOUSE_FILTER_PASS
	card.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(1, 1, 1, 0.045), Color(1, 1, 1, 0.08), 1, 16, 14, 12)))
	_body.add_child(card)
	var rows := VBoxContainer.new(); rows.add_theme_constant_override("separation", 4); card.add_child(rows)
	var top := HBoxContainer.new(); top.add_theme_constant_override("separation", 10); rows.add_child(top)
	var about := VBoxContainer.new(); about.add_theme_constant_override("separation", 0)
	about.size_flags_horizontal = Control.SIZE_EXPAND_FILL; top.add_child(about)
	about.add_child(_clipped(STYLE.label(DATA.scene_line(scene), "Subheading", FONT - 1)))
	var cast := (scene.cast as Array).map(func(id: String) -> String: return DATA.name_of(id))
	about.add_child(_clipped(STYLE.label(", ".join(cast) if not cast.is_empty() else "Around town", "Faint", FONT - 6)))
	var lines: Array[Control] = []
	var all := (scene.entries as Array).all(func(e: Dictionary) -> bool: return _picked.has(int(e.id)))
	var pick := _button(top, "Unpick" if all else "Pick all", Callable(), "Chip")
	pick.icon = ICON.texture("check", FONT - 4); pick.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pick.pressed.connect(_pick_scene.bind(scene, lines, pick))
	var picture := _button(top, "Picture", _open_studio.bind(scene.entries, [scene]), "Chip")
	picture.icon = ICON.texture("image", FONT - 4); picture.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	picture.tooltip_text = "Make a picture of this whole scene"
	_extra.append_array([pick, picture])
	rows.add_child(_spacer(4))
	var last := ""
	for entry: Dictionary in scene.entries:
		var row := _line_row(entry, str(entry.speaker) != last)
		rows.add_child(row); lines.append(row)
		last = str(entry.speaker) if entry.kind == "say" else ""


## One line: her disc and name on the first of a run, the words; click to pick it.
func _line_row(entry: Dictionary, first: bool) -> Control:
	var row := PanelContainer.new(); row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var line := HBoxContainer.new(); line.add_theme_constant_override("separation", 10); line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(line)
	if entry.kind == "moment":
		var spark := ICON.make("sparkle", FONT - 2, STYLE.BUTTER); spark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		line.add_child(spark)
		var words := STYLE.label(str(entry.text), "", FONT - 4); words.add_theme_font_override("font", STYLE.ITALIC)
		words.add_theme_color_override("font_color", STYLE.BUTTER.lerp(STYLE.MUTED, 0.3))
		words.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(words)
	else:
		var speaker := str(entry.speaker)
		var disc := _disc(speaker, FONT * 1.6) if first else Control.new()
		disc.custom_minimum_size = Vector2.ONE * FONT * 1.6; disc.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		line.add_child(disc)
		var column := VBoxContainer.new(); column.add_theme_constant_override("separation", 0)
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL; column.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(column)
		if first:
			var head := HBoxContainer.new(); head.add_theme_constant_override("separation", 8); column.add_child(head)
			var called := STYLE.label(DATA.name_of(speaker, str(_world.player)), "", FONT - 1)
			called.add_theme_font_override("font", STYLE.HEADING); called.add_theme_color_override("font_color", _name_colour(speaker))
			head.add_child(called)
			var to := DATA.name_of(str(entry.listener), str(_world.player))
			var note := STYLE.label(("to %s · " % to if to != "" else "") + DATA.clock(int(entry.minute)), "Faint", FONT - 7)
			note.size_flags_vertical = Control.SIZE_SHRINK_CENTER; head.add_child(note)
		var words := STYLE.label(str(entry.text), "", FONT - 3); words.add_theme_color_override("font_color", STYLE.CREAM)
		words.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		column.add_child(words)
	var tick := ICON.make("check", FONT - 2, STYLE.PINK); tick.name = "Tick"; tick.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(tick)
	_style_row(row, _picked.has(int(entry.id)), false)
	row.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_toggle_pick(entry, row); row.accept_event())
	row.mouse_entered.connect(func() -> void: _style_row(row, _picked.has(int(entry.id)), true))
	row.mouse_exited.connect(func() -> void: _style_row(row, _picked.has(int(entry.id)), false))
	return row


func _style_row(row: Control, picked: bool, hovered: bool) -> void:
	var fill := Color(STYLE.PINK, 0.16) if picked else (Color(1, 1, 1, 0.05) if hovered else Color.TRANSPARENT)
	var rim := Color(STYLE.PINK, 0.65) if picked else (Color(1, 1, 1, 0.1) if hovered else Color.TRANSPARENT)
	row.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(fill, rim, 1, 12, 10, 6)))
	var tick: Control = row.find_child("Tick", true, false)
	if tick != null: tick.modulate.a = 1.0 if picked else (0.25 if hovered else 0.0)
	_refresh_panel()


func _name_colour(id: String) -> Color:
	if id == DATA.PLAYER: return STYLE.LILAC.lerp(Color.WHITE, 0.3)
	return OVERHEAD._readable(PONY_DATA.appearance(id).coat)


func _disc(id: String, side: float) -> Control:
	var disc := Panel.new(); disc.custom_minimum_size = Vector2(side, side); disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if id == DATA.PLAYER:
		disc.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color("6b3f9c"), STYLE.LILAC, 1, 99, 0, 0)))
		var letter := STYLE.label(str(_world.player).left(1).to_upper(), "", int(side * 0.55))
		letter.add_theme_font_override("font", STYLE.HEADING); letter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		letter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER; letter.size = Vector2(side, side); disc.add_child(letter)
		return disc
	var coat: Color = PONY_DATA.appearance(id).coat
	disc.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(coat, Color(1, 1, 1, 0.7), 1, 99, 0, 0)))
	var mark := _mark_texture(id)
	if mark != null:
		var picture := TextureRect.new(); picture.texture = mark; picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
		picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE; picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		picture.size = Vector2.ONE * side * 0.66; picture.position = Vector2.ONE * side * 0.17
		disc.add_child(picture)
	else:
		# The princesses' marks are blank in the atlas: their sun / moon instead of an empty disc.
		preload("res://world/ui/pony_symbol.gd").add_to(disc, id, side)
	return disc


# ------------------------------------------------------------------ the picture
func _make_from_picks() -> void:
	var entries: Array = []
	var scenes: Array = []
	for scene: Dictionary in _world.get("scenes", []):
		var kept: Array = (scene.entries as Array).filter(func(e: Dictionary) -> bool: return _picked.has(int(e.id)))
		if kept.is_empty(): continue
		entries.append_array(kept)
		var copy := scene.duplicate(); copy.entries = kept
		scenes.append(copy)
	_open_studio(entries, scenes)


## The studio for these entries, with the choices as last left.
func _open_studio(entries: Array, scenes: Array) -> void:
	if entries.is_empty(): return
	if options.is_empty(): options = PICTURE.load_options()
	_studio_generation += 1
	_studio_entries = entries; _studio_scenes = scenes
	var says := entries.filter(func(e: Dictionary) -> bool: return e.kind == "say").size()
	_studio_line.text = "%s · %d %s" % [_world_title(), says, "line" if says == 1 else "lines"]
	_saved.clear(); _studio_status.text = "Still saving the last picture…" if _busy else ""; _folder_button.hide()
	_studio_status.tooltip_text = ""
	_save_button.disabled = _busy
	_studio_picture.texture = null; _studio_pages.text = ""
	_show_options()
	_studio.show(); _list_controls()
	_save_button.grab_focus()
	_refresh_preview()


func _close_studio() -> void:
	_studio.hide(); _studio_picture.texture = null
	_list_controls(); _make.grab_focus(); _refresh_panel()


func _show_options() -> void:
	for option: String in _choice_buttons:
		for value: String in _choice_buttons[option]: (_choice_buttons[option][value] as Button).set_pressed_no_signal(str(options[option]) == value)
	for option: String in _part_chips: (_part_chips[option] as Button).set_pressed_no_signal(bool(options[option]))
	_part_chips.date.disabled = not bool(options.footer)
	if _title_edit.text != str(options.title): _title_edit.text = str(options.title)


func _set_option(option: String, value: Variant) -> void:
	options[option] = value
	PICTURE.save_options(options)
	_show_options()
	_refresh_preview()


func _reset_options() -> void:
	options = PICTURE.DEFAULTS.duplicate()
	PICTURE.save_options(options)
	_show_options(); _refresh_preview()


func _spec(preview: bool) -> Dictionary:
	return {"entries": _studio_entries, "scenes": _studio_scenes, "world": _world_title(), "tint": _tint(),
		"player": str(_world.player), "options": options.duplicate(), "preview": preview}


## Draws the first page again; changes made while it draws are drawn once it is done.
func _refresh_preview() -> void:
	if _rendering: _render_again = true; return
	_rendering = true
	while true:
		_render_again = false
		var picture := PICTURE.new(); add_child(picture)
		var images: Array[Image] = await picture.render(_spec(true))
		var pages := picture.page_count
		picture.queue_free()
		if not _studio.visible: break
		if not _render_again and not images.is_empty():
			_studio_picture.texture = ImageTexture.create_from_image(images[0]); _fit_preview()
			_studio_pages.text = "%d × %d pixels" % [images[0].get_width(), images[0].get_height()] + ("" if pages <= 1 else "  ·  page 1 of %d" % pages)
			_refresh_panel()
		if not _render_again: break
	_rendering = false


func _save_picture() -> void:
	if _busy or _studio_entries.is_empty(): return
	_busy = true
	var generation := _studio_generation
	_save_button.disabled = true; _studio_status.text = "Drawing the picture…"; _studio_status.tooltip_text = ""; _refresh_panel()
	var spec := _spec(false)
	var first: Dictionary = _studio_entries[0]
	var when := "Day %d %s" % [int(first.day) + 1, DATA.clock(int(first.minute)).replace(":", "h")]
	var picture := PICTURE.new(); add_child(picture)
	var images: Array[Image] = await picture.render(spec)
	picture.queue_free()
	var saved := PICTURE.save(images, str(spec.world), when) if not images.is_empty() else ([] as Array[String])
	_busy = false
	if not is_inside_tree(): return
	_save_button.disabled = false
	# Another selection was opened meanwhile: this picture is saved, but the studio shows that one.
	if generation != _studio_generation:
		if _studio_status.text == "Still saving the last picture…": _studio_status.text = ""
		_refresh_panel(); return
	_saved = saved
	if _saved.is_empty():
		_studio_status.text = "The picture could not be saved in %s." % PICTURE.folder()
	else:
		# Short enough for one line: the folder's last two names; the full path and files in the tooltip.
		var folder := _saved[0].get_base_dir()
		var short := folder.get_base_dir().get_file().path_join(folder.get_file())
		_studio_status.text = "Saved in %s" % short if _saved.size() == 1 else "Saved %d pages in %s" % [_saved.size(), short]
		_studio_status.tooltip_text = folder + "\n" + "\n".join(_saved.map(func(path: String) -> String: return path.get_file()))
		_studio_status.mouse_filter = Control.MOUSE_FILTER_STOP
		_folder_button.visible = not OS.has_feature("android")
	_list_controls(); _refresh_panel()


func _open_folder() -> void:
	if _saved.is_empty(): OS.shell_open(PICTURE.folder())
	else: OS.shell_show_in_file_manager(_saved[0])


# ------------------------------------------------------------------ parts
func _empty(kind: String, title: String, text: String) -> void:
	var box := VBoxContainer.new(); box.add_theme_constant_override("separation", 10); _body.add_child(box)
	box.add_child(_spacer(FONT * 3))
	var picture := ICON.make(kind, FONT * 2.6, STYLE.FAINT); picture.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(picture)
	var heading := STYLE.label(title, "Subheading", FONT + 2); heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; box.add_child(heading)
	var words := STYLE.label(text, "Muted", FONT - 3); words.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	words.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; box.add_child(words)


func _spacer(height: float) -> Control:
	var gap := Control.new(); gap.custom_minimum_size.y = height; gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return gap


func _clipped(node: Label) -> Label:
	node.clip_text = true; node.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return node


func _button(parent: Node, text: String, action: Callable, variation := "") -> Button:
	var node := Button.new(); node.text = text; node.theme_type_variation = variation
	if action.is_valid(): node.pressed.connect(action)
	node.focus_entered.connect(_refresh_panel)
	node.mouse_entered.connect(_refresh_panel); node.mouse_exited.connect(_refresh_panel)
	parent.add_child(node); return node


func _round(parent: Node, kind: String, tip: String, action: Callable) -> Button:
	var node := _button(parent, "", action, "Round"); node.tooltip_text = tip
	node.icon = ICON.texture(kind, FONT); node.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	node.custom_minimum_size = Vector2.ONE * FONT * 2; node.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return node


func _refresh_panel() -> void:
	if panel != null and panel.has_method("refresh"): panel.refresh()
