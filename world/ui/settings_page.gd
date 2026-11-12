extends VBoxContainer
## The one settings page: a sidebar of tabs, the chosen tab's rows, a status line and host
## buttons (Back / Close) at the bottom. Rows come from Settings.TABS, so the home screen, the
## F7 panel, the desktop pause menu and the VR panel all show the same settings. Every control is
## a plain Button (steppers, switches, keycaps), which works with the mouse, the keyboard focus
## keys and a VR controller ray on a spatial panel alike. Look: world/ui/menu_style.gd (dev
## 2026-10-27: the grid of grey tab buttons and ◀ value ▶ rows were "not really design").
## Values are picked directly, never stepped through (dev 2026-10-27: "a choice direct instead
## of cycling by clicking"): numbers on a slider, a few short choices as pills side by side, the
## rest in a list that unfolds under the row.

signal back_requested

const STYLE := preload("res://world/ui/menu_style.gd")
const ICON := preload("res://world/ui/menu_icon.gd")
const PICKER := preload("res://world/ui/menu_picker.gd")
const CAPTION := preload("res://world/ui/speech_caption.gd")
## Sidebar order, captions and pictures; a tab missing here is listed at the end.
const GROUPS := [
	["Story & AI", [["AI Settings", "chat"], ["Prompts", "quill"], ["Saved notes", "note"]]],
	["Look & sound", [["Graphics", "sun"], ["Audio", "music"], ["Reading", "book"], ["World", "globe"]]],
	["Play", [["Controls", "keyboard"], ["Controls map", "map"], ["VR comfort", "headset"], ["Accessibility", "access"], ["Mods", "gem"]]],
]
## Choices side by side at most; more go in a list.
const MOST_SEGMENTS := 5

## Called after anything visible changes; a SubViewport panel passes its refresh().
var redraw := Callable()
var font_size := 20
var xr := false
var capturing := ""            # action waiting for a key press
var _tabs: Array[Button] = []          # by Settings.TABS index
var _tab_order: Array[Button] = []     # as the sidebar shows them
var _lists: Array[VBoxContainer] = []
## key -> keycap Button, switch CheckButton, slider value Label, pills HBox or picker.
var _values: Dictionary = {}
var _action_buttons: Dictionary = {}   # action -> [Button, default label]
var _sliders: Dictionary = {}  # key -> HSlider
var _row_cards: Dictionary = {}  # key -> the row's card (greyed out while it does not apply)
## Width a row's control may take beside its name.
var _room := 400.0
var _side_scroll: ScrollContainer
var _scroll: ScrollContainer
var _status: Label
var _quality_note: Label
var _tab := 0
var _lighting_controls: Control
var provider: Control
## Settings → Prompts (world/ui/prompt_settings.gd), shown in place of the rows like AI Settings.
var prompts: Control
var feedback_notes: Control
## Settings → Controls map (world/ui/controls_map/controls_map.gd): photos with callout wires.
var controls_map: Control
var footer: HBoxContainer
var _content: VBoxContainer
var _tab_title: Label
var _tab_icon: Control
var _row_idle: StyleBoxFlat
var _row_hover: StyleBoxFlat
## Settings > Debug's sidebar button, hidden until the Updates tab is pressed five times in a row.
var _debug_button: Button
var _updates_presses := 0
var _updates_pressed_at := -10.0
## Settings → Mods switches by pack file, so switching a scenario mod on shows the others go off.
var _mod_toggles: Dictionary = {}


## `size` is the page's full size; `back_text` names the host's button ("" for none).
func setup(page_size: Vector2, text_size: int, back_text: String, in_xr := false) -> void:
	theme = STYLE.theme()
	font_size = text_size; xr = in_xr
	size = page_size; custom_minimum_size = page_size
	add_theme_constant_override("separation", 10)
	_row_idle = STYLE.box(Color(1, 1, 1, 0.045), Color(1, 1, 1, 0.07), 1, 16, 16, 9)
	_row_hover = STYLE.box(Color(1, 1, 1, 0.085), Color(STYLE.PINK, 0.45), 1, 16, 16, 9)
	var body := HBoxContainer.new(); body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16); add_child(body)
	_build_sidebar(body, _sidebar_width(page_size.x))
	_room = _room_for(page_size.x)
	_content = VBoxContainer.new(); _content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 10); body.add_child(_content)
	var title_row := HBoxContainer.new(); title_row.add_theme_constant_override("separation", 10); _content.add_child(title_row)
	_tab_icon = ICON.make("gear", font_size + 8, STYLE.PINK); title_row.add_child(_tab_icon)
	_tab_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tab_title = STYLE.label("", "Subheading", font_size + 6); title_row.add_child(_tab_title)
	_scroll = ScrollContainer.new(); _scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; _scroll.follow_focus = true
	_scroll.get_v_scroll_bar().value_changed.connect(func(_value: float) -> void: _redraw())
	_content.add_child(_scroll)
	var holder := MarginContainer.new(); holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.add_theme_constant_override("margin_right", 14); _scroll.add_child(holder)
	# Room for a hovered button's lift and focus ring inside the scroll's clip.
	holder.add_theme_constant_override("margin_left", 6); holder.add_theme_constant_override("margin_top", 4)
	holder.add_theme_constant_override("margin_bottom", 4)
	var stack := VBoxContainer.new(); stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL; holder.add_child(stack)
	for t in Settings.TABS.size():
		var list := VBoxContainer.new(); list.add_theme_constant_override("separation", 6)
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL; stack.add_child(list); _lists.append(list)
		_fill_list(t, list)
	provider = preload("res://world/ui/provider_settings.gd").new()
	_content.add_child(provider); provider.setup(self, true)
	provider.custom_minimum_size = Vector2.ZERO
	provider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	provider.size_flags_vertical = Control.SIZE_EXPAND_FILL
	prompts = preload("res://world/ui/prompt_settings.gd").new()
	_content.add_child(prompts); prompts.setup(self, true)
	prompts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prompts.size_flags_vertical = Control.SIZE_EXPAND_FILL
	feedback_notes = preload("res://world/ui/feedback_notes.gd").new()
	_content.add_child(feedback_notes); feedback_notes.setup(self, true)
	feedback_notes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	feedback_notes.size_flags_vertical = Control.SIZE_EXPAND_FILL
	controls_map = preload("res://world/ui/controls_map/controls_map.gd").new()
	_content.add_child(controls_map); controls_map.setup(font_size, _redraw)
	controls_map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	controls_map.hide()
	_status = STYLE.label("", "Muted", font_size - 3); _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)
	footer = HBoxContainer.new(); footer.add_theme_constant_override("separation", 10); add_child(footer)
	if not back_text.is_empty():
		var back := _button(footer, back_text, func(): back_requested.emit())
		back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		back.icon = ICON.texture("back", font_size)
	Settings.changed.connect(_on_changed)
	show_tab("Graphics")


## One tab's rows (and its notes).
func _fill_list(t: int, list: VBoxContainer) -> void:
	var tab: Array = Settings.TABS[t]
	for row in tab[1]:
		_row(list, str(row[0]), str(row[1]))
		# A sample caption under its background row, as that row and Subtitle size make it.
		if str(row[1]) == "access/caption_opacity":
			var sample := CAPTION.new()
			sample.preview = true
			# Menus drawn on demand (title, VR) redraw once its row has its new height.
			sample.minimum_size_changed.connect(_redraw)
			list.add_child(sample)
	if str(tab[0]) == "Graphics" and "--debug" in preload("res://world/dev_tools.gd").user_args():
		_lighting_controls = load("res://world/debug/lighting_page.gd").new()
		list.add_child(_lighting_controls)
		_lighting_controls.setup(font_size, _redraw)
	if str(tab[0]) == "Mods": _build_mods(list)
	if str(tab[0]) == "Updates": _build_updates.call_deferred(list)
	if str(tab[0]) == "Debug": _build_debug(list)
	if str(tab[0]) == "VR comfort":
		_note(list, "A comfort vignette is not available yet.")
	if str(tab[0]) == "Controls":
		_note(list, "Other keys (E use, F fly, M map, I briefcase, J inspect, F5–F8) are fixed for now.")
		_note(list, "Wings or Hercules sandals: F takes off/lands. Space flaps; release to glide. S brakes, Shift powers stronger strokes, Ctrl dives. Left/right mouse banks left/right while flying. Wing stamina returns while gliding or resting. Room-scale VR: A takes off/flaps, B lands; pull the move stick back to brake.")


static func _sidebar_width(page_width: float) -> float:
	return clampf(page_width * 0.25, 188.0, 250.0)


## What a row's control may take: the page minus sidebar, gaps, scroll bar, row padding and a
## name column.
func _room_for(page_width: float) -> float:
	return page_width - _sidebar_width(page_width) - 16.0 - 14.0 - 12.0 - 32.0 - 12.0 - font_size * 10.0


## A new page size (a host resized in place: F7, the pause menu, the title): the sidebar and the
## setting rows are laid out again for it. The rows hold nothing unsaved (every value applies at
## once), unlike Prompts, AI Settings and Saved notes, which stay as they are.
func relayout(page_size: Vector2) -> void:
	custom_minimum_size = page_size
	_side_scroll.custom_minimum_size.x = _sidebar_width(page_size.x)
	var room := _room_for(page_size.x)
	if not is_equal_approx(room, _room):
		_room = room
		_values.clear(); _sliders.clear(); _row_cards.clear(); _quality_note = null; _lighting_controls = null
		for t in _lists.size():
			for child in _lists[t].get_children():
				# A row's own signal may be what resized the window (Window size): it is taken out
				# now and freed once that signal is done.
				_lists[t].remove_child(child); child.queue_free()
			_fill_list(t, _lists[t])
	# After the rows: set before, the old wider rows would stretch the page and it would stay so.
	size = page_size
	refresh()


func _build_sidebar(body: HBoxContainer, width: float) -> void:
	# It scrolls when the page is short (the VR panel shrinks it for its keyboard, settings_menu.gd).
	_side_scroll = ScrollContainer.new(); _side_scroll.custom_minimum_size.x = width
	_side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; _side_scroll.follow_focus = true
	_side_scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _redraw())
	body.add_child(_side_scroll)
	var side := VBoxContainer.new(); side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_theme_constant_override("separation", 3); _side_scroll.add_child(side)
	var heading := HBoxContainer.new(); heading.add_theme_constant_override("separation", 8); side.add_child(heading)
	heading.add_child(STYLE.label("Settings", "Heading", font_size + 12))
	var spark := ICON.make("sparkle", font_size, STYLE.BUTTER); spark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	heading.add_child(spark)
	_tabs.resize(Settings.TABS.size())
	var listed: Array[String] = []
	var groups: Array = GROUPS.duplicate(true)
	var rest: Array = []
	for t in Settings.TABS.size():
		var name := str(Settings.TABS[t][0])
		var known := false
		for group: Array in GROUPS:
			for entry: Array in group[1]: known = known or str(entry[0]) == name
		if not known: rest.append([name, "gear" if name == "Debug" else "sparkle"])
	if not rest.is_empty(): groups.append(["More", rest])
	for group: Array in groups:
		var caption := STYLE.label(str(group[0]).to_upper(), "Faint", maxi(12, font_size - 7))
		caption.add_theme_constant_override("line_spacing", 0)
		var gap := Control.new(); gap.custom_minimum_size.y = 6; side.add_child(gap)
		side.add_child(caption)
		for entry: Array in group[1]:
			var index := _tab_index(str(entry[0]))
			if index < 0 or str(entry[0]) in listed: continue
			listed.append(str(entry[0]))
			var button := _button(side, str(entry[0]), _show_tab.bind(index))
			button.theme_type_variation = "Tab"; button.toggle_mode = true
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT; button.clip_text = true
			button.custom_minimum_size = Vector2(0, font_size * 2.05)
			button.add_theme_font_size_override("font_size", font_size - 2)
			button.icon = _icon_texture(str(entry[1]))
			button.expand_icon = false
			button.set_meta("icon_kind", str(entry[1]))
			button.set_meta("no_sparkle", true)
			_tabs[index] = button; _tab_order.append(button)
			if str(entry[0]) == "Updates": button.pressed.connect(_on_updates_pressed)
			if str(entry[0]) == "Debug":
				_debug_button = button; button.visible = Settings.get_value("debug/unlocked") == true


func _tab_index(title: String) -> int:
	for i in Settings.TABS.size():
		if str(Settings.TABS[i][0]) == title: return i
	return -1


func _icon_texture(kind: String) -> Texture2D:
	return ICON.texture(kind, font_size + 4)


func _row(list: VBoxContainer, label_text: String, key: String) -> void:
	if key.begins_with("action:"):
		var action := key.get_slice(":", 1)
		# The controls map is a page of its own, not a Settings action.
		var run := (func(): show_tab("Controls map")) if action == "controls_map" else (func(): Settings.run_action(action))
		var button := _button(list, Settings.action_label(action, label_text), run)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		# The Great Evil button wears no icon (dev 2026-10-30).
		if action != "spawn_barbiepone": button.icon = _icon_texture("map" if action == "controls_map" else "sparkle")
		_action_buttons[action] = [button, label_text]
		return
	var card := PanelContainer.new(); card.add_theme_stylebox_override("panel", _row_idle)
	_row_cards[key] = card
	card.mouse_filter = Control.MOUSE_FILTER_PASS
	card.mouse_entered.connect(func() -> void: card.add_theme_stylebox_override("panel", _row_hover); _redraw())
	card.mouse_exited.connect(func() -> void: card.add_theme_stylebox_override("panel", _row_idle); _redraw())
	list.add_child(card)
	var stack := VBoxContainer.new(); stack.add_theme_constant_override("separation", 4); card.add_child(stack)
	var line := HBoxContainer.new(); line.add_theme_constant_override("separation", 12); stack.add_child(line)
	var texts := VBoxContainer.new(); texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.alignment = BoxContainer.ALIGNMENT_CENTER; texts.add_theme_constant_override("separation", 1); line.add_child(texts)
	var name_label := STYLE.label(label_text, "", font_size)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; texts.add_child(name_label)
	var note := str(Settings.SPECS.get(key, {}).get("note", ""))
	if not note.is_empty():
		var caption := STYLE.label(note[0].to_upper() + note.substr(1), "Faint", font_size - 5)
		texts.add_child(caption)
	if key == "video/quality":
		_quality_note = STYLE.label("", "Muted", font_size - 5); _quality_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		stack.add_child(_quality_note)
	if key.begins_with("bind:"):
		var action := key.get_slice(":", 1)
		var bind := _button(line, "", _capture.bind(action)); bind.theme_type_variation = "Key"
		bind.custom_minimum_size = Vector2(font_size * 7, font_size * 2.0); bind.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_values[key] = bind
		if xr: bind.disabled = true
		return
	var spec: Dictionary = Settings.SPECS.get(key, {})
	if str(spec.get("type", "")) == "bool" and Array(spec.get("labels", ["Off", "On"])) == ["Off", "On"]:
		var state := STYLE.label("", "Muted", font_size - 2); state.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		line.add_child(state)
		var switch := CheckButton.new(); switch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		switch.focus_mode = Control.FOCUS_ALL; switch.set_meta("no_lift", true)
		switch.toggled.connect(func(_on: bool) -> void: Settings.cycle(key, 1))
		switch.focus_entered.connect(_redraw); switch.mouse_entered.connect(_redraw); switch.mouse_exited.connect(_redraw)
		switch.set_meta("state_label", state)
		line.add_child(switch)
		_values[key] = switch
		return
	if str(spec.get("type", "")) in ["int", "float"]:
		_slider(line, key, spec)
		return
	var options := _options(key)
	if _segments_fit(options): _segments(line, key, options)
	else: _dropdown(stack, line, key, options)


## The [value, label] pairs a row chooses among (Window size: only the sizes this screen holds).
func _options(key: String) -> Array:
	var spec: Dictionary = Settings.SPECS.get(key, {})
	if key == "video/window_size": return Settings.window_sizes()
	if str(spec.get("type", "")) == "bool":
		var labels: Array = spec.get("labels", ["Off", "On"])
		return [[false, labels[0]], [true, labels[1]]]
	return spec.get("options", [])


## An option's words. Render scale adds the size the 3D world is drawn at in this window.
func _option_text(key: String, option: Array) -> String:
	# The main window's size, also while this page is still being built outside the tree.
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var quality := root.get_node_or_null("Quality")
	if key != "video/render_scale" or xr or quality == null or bool(quality.xr_mode): return str(option[1])
	var window := Vector2(root.get_visible_rect().size)
	var scale: float = int(option[0]) / 100.0 if int(option[0]) > 0 else quality.auto_render_scale(window)
	return "%s · %d × %d" % [option[1], roundi(window.x * scale), roundi(window.y * scale)]


func _text_width(text: String, size: int) -> float:
	return STYLE.BOLD.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


## A few short choices fit side by side.
func _segments_fit(options: Array) -> bool:
	if options.size() < 2 or options.size() > MOST_SEGMENTS: return false
	var width := 10.0 + 4.0 * (options.size() - 1)
	for option: Array in options: width += _text_width(str(option[1]), font_size - 3) + 30.0
	return width <= _room


## Every choice as a pill in one track; the chosen one is lit, one press picks another.
func _segments(line: HBoxContainer, key: String, options: Array) -> void:
	var track := PanelContainer.new(); track.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	track.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(0.05, 0.02, 0.09, 0.4), Color(1, 1, 1, 0.1), 1, 99, 4, 4)))
	line.add_child(track)
	var pills := HBoxContainer.new(); pills.add_theme_constant_override("separation", 4); track.add_child(pills)
	for option: Array in options:
		var pill := _button(pills, str(option[1]), func() -> void: Settings.set_value(key, option[0]); refresh())
		pill.theme_type_variation = "Segment"; pill.toggle_mode = true
		pill.custom_minimum_size = Vector2(0, font_size * 1.75)
		pill.add_theme_font_size_override("font_size", font_size - 3)
		pill.set_meta("value", option[0])
	_values[key] = pills


## A face showing the choice; pressing it unfolds every option under the row.
func _dropdown(stack: VBoxContainer, line: HBoxContainer, key: String, options: Array) -> void:
	var picker: Control = PICKER.new()
	picker.font_size = font_size - 2; picker.redraw = _redraw; picker.list_height = font_size * 15.0
	var widest := 0.0
	for option: Array in options:
		var text := _option_text(key, option)
		picker.add_item(text); picker.set_item_metadata(picker.item_count - 1, option[0])
		widest = maxf(widest, _text_width(text, font_size - 2))
	picker.set_meta("options", options)
	picker.item_selected.connect(func(index: int) -> void: Settings.set_value(key, picker.get_item_metadata(index)); refresh())
	stack.add_child(picker)
	picker.detach_head(line)
	var face: Button = picker.head()
	face.theme_type_variation = "Drop"; face.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	face.custom_minimum_size = Vector2(minf(_room, widest + 64.0), font_size * 1.9)
	face.focus_entered.connect(_redraw)
	_values[key] = picker


## Numbers on a slider, the value beside it (a list of presets slides by position).
func _slider(line: HBoxContainer, key: String, spec: Dictionary) -> void:
	var box := HBoxContainer.new(); box.add_theme_constant_override("separation", 14)
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER; line.add_child(box)
	var slider := HSlider.new(); slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.scrollable = false; slider.focus_mode = Control.FOCUS_ALL
	var presets: Array = spec.get("presets", [])
	var ends: Array = [spec.get("min", 0), spec.get("max", 0)]
	if not presets.is_empty():
		slider.min_value = 0; slider.max_value = presets.size() - 1; slider.step = 1
		ends = [presets[0], presets[-1]]
	else:
		slider.min_value = float(spec.min); slider.max_value = float(spec.max); slider.step = float(spec.get("step", 1))
	var value: Control
	var typed := bool(spec.get("typed", false)) and not xr
	if typed:
		# An exact value can be typed too (mouse sensitivity): Enter or leaving the field applies it.
		var field := LineEdit.new(); field.alignment = HORIZONTAL_ALIGNMENT_RIGHT
		field.text_submitted.connect(func(text: String) -> void: _apply_typed(key, text); field.release_focus())
		field.focus_exited.connect(func() -> void: _apply_typed(key, field.text))
		field.focus_entered.connect(_redraw)
		value = field
	else:
		var label := Label.new(); label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value = label
	value.add_theme_font_override("font", STYLE.BOLD); value.add_theme_font_size_override("font_size", font_size - 1)
	var widest := 0.0
	for end: Variant in ends + [0]:
		var text := str(spec.zero) if float(end) == 0.0 and spec.has("zero") else str(spec.get("fmt", "%d")) % end
		widest = maxf(widest, _text_width(text, font_size - 1))
	# Rows whose value is words (Anon's height: "6 ft 0 in (182.9 cm)") give their widest text.
	if spec.has("width_sample"): widest = maxf(widest, _text_width(str(spec.width_sample), font_size - 1))
	value.custom_minimum_size.x = widest + (32.0 if typed else 4.0)
	# The arrow keys move by `arrow_step` where a fine range has one (mouse sensitivity).
	# Godot 4.5's Slider has no custom_step: step here, before the slider's own 1-unit move.
	if spec.has("arrow_step"):
		slider.gui_input.connect(func(event: InputEvent) -> void:
			var direction := 1.0 if event.is_action_pressed("ui_right", true) else (-1.0 if event.is_action_pressed("ui_left", true) else 0.0)
			if direction == 0.0: return
			slider.value += direction * float(spec.arrow_step)
			slider.accept_event())
	slider.custom_minimum_size = Vector2(clampf(_room - widest - 14.0, font_size * 7.0, font_size * 14.0), font_size * 1.6)
	slider.value_changed.connect(func(at: float) -> void:
		Settings.set_value(key, presets[int(at)] if not presets.is_empty() else at))
	slider.mouse_entered.connect(_redraw); slider.mouse_exited.connect(_redraw); slider.focus_entered.connect(_redraw)
	box.add_child(slider); box.add_child(value)
	_values[key] = value; _sliders[key] = slider


## Greys a row out and turns its controls off (or back on) while its setting does not apply.
func _set_row_enabled(key: String, enabled: bool) -> void:
	var card: Control = _row_cards.get(key)
	if not is_instance_valid(card): return
	card.modulate.a = 1.0 if enabled else 0.45
	var node: Control = _values.get(key)
	if node != null and node.has_method("set_open"):
		if not enabled: node.set_open(false)
		(node.head() as Button).disabled = not enabled
	elif node != null:
		for button in node.find_children("*", "BaseButton", true, false): (button as BaseButton).disabled = not enabled
	var slider: HSlider = _sliders.get(key)
	if slider != null: slider.editable = enabled


## A row's options can mix kinds ("preset" beside 80 m): == between a String and an int is an
## error in a debug build, so the kinds are compared first.
static func _same(a: Variant, b: Variant) -> bool:
	return typeof(a) == typeof(b) and a == b


## Where `key`'s value sits among its choices, 0..count-1.
static func _option_index(key: String) -> int:
	var spec: Dictionary = Settings.SPECS.get(key, {})
	var value: Variant = Settings.get_value(key)
	match str(spec.get("type", "")):
		"choice":
			var options: Array = spec.options
			for i in options.size():
				if _same(options[i][0], value): return i
		"bool": return 1 if bool(value) else 0
		"float":
			var presets: Array = spec.get("presets", [])
			var best := 0
			for i in presets.size():
				if absf(float(presets[i]) - float(value)) < absf(float(presets[best]) - float(value)): best = i
			return best
		"int": return int((int(value) - int(spec.min)) / maxi(1, int(spec.step)))
	return 0


## Settings → Mods (world/modding/mod_loader.gd pack_rows()): two sections, the player's own mods
## and under them the mods included with the game, each pack with its name, version and author, an On/Off switch
## (kept in user://mods/mods.cfg; entry-only mods switch at once, Mods.switch()) and a muted line
## saying why it is held, superseded, waiting for another mod or patched. A patch pack has no
## switch of its own: it is listed under the pack it patches and follows it.
func _build_mods(list: VBoxContainer) -> void:
	var loader := preload("res://world/modding/mod_loader.gd")
	_note(list, "Mods can run code on your computer. Only install mods from people you trust. Most mods switch on and off at once; the rest apply the next time the game starts.")
	_button(list, "Open mods folder", _open_mods_folder).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var rows := loader.pack_rows()
	var shipped := rows.filter(func(row: Dictionary) -> bool: return bool(row.bundled) and str(row.patch_of).is_empty())
	var own := rows.filter(func(row: Dictionary) -> bool: return not bool(row.bundled) and str(row.patch_of).is_empty())
	# The player's own mods first, then the ones the game came with, told apart plainly (dev
	# 2026-11-11: a player may wonder why there are mods he did not install).
	_mods_heading(list, "Your mods", "Installed by you: %d" % own.size())
	if own.is_empty():
		_note(list, "You have not installed any mods. Put .pck mods in the mods folder, then restart the game.")
	for row: Dictionary in own: _mod_row(list, row)
	if shipped.is_empty(): return
	_mods_heading(list, "Included with the game", "%d community mods that are part of the game" % shipped.size())
	_note(list, "You did not install these. They are mods made by players that the game includes, and they update with it. Switch off any you do not want.")
	_mod_updates(list, shipped)
	for row: Dictionary in shipped: _mod_row(list, row)


## A section title in the heading font with a quiet line under it, set off from the rows above.
func _mods_heading(list: VBoxContainer, text: String, detail := "") -> void:
	var space := Control.new(); space.custom_minimum_size.y = font_size * 0.6; list.add_child(space)
	list.add_child(STYLE.label(text, "Heading", font_size + 4))
	if not detail.is_empty(): list.add_child(STYLE.label(detail, "Faint", maxi(12, font_size - 5)))


## One pack: its name and description, a muted line of reasons, and its switch.
func _mod_row(list: VBoxContainer, row: Dictionary) -> void:
	var loader := preload("res://world/modding/mod_loader.gd")
	var line := HBoxContainer.new(); line.add_theme_constant_override("separation", 6); list.add_child(line)
	var texts := VBoxContainer.new(); texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL; line.add_child(texts)
	var label := Label.new(); label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL; label.add_theme_font_size_override("font_size", font_size - 2)
	label.text = _mod_text(row, loader.mods); texts.add_child(label)
	var notes := _mod_notes(row)
	if not notes.is_empty():
		var muted := STYLE.label(notes, "Muted", font_size - 4); muted.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		muted.size_flags_horizontal = Control.SIZE_EXPAND_FILL; texts.add_child(muted)
	if not bool(row.get("switchable", true)): return
	var file := str(row.file)
	var toggle := _button(line, "", func() -> void: pass)
	toggle.custom_minimum_size.x = font_size * 6; toggle.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_mod_toggles[file] = toggle
	var show := func() -> void:
		var on: bool = loader.switched_on(file)
		toggle.text = "On" if on else "Off"
		if on != bool(row.enabled): Settings.message = "Restart the game to apply mod changes."
		refresh()
	toggle.pressed.connect(func() -> void:
		var on := not loader.switched_on(file)
		Mods.switch(file, on)
		var note := _one_scenario_switch(row, on) if on else ""
		for other: String in _mod_toggles:
			var button: Variant = _mod_toggles[other]
			if is_instance_valid(button) and button is Button: (button as Button).text = "On" if loader.switched_on(other) else "Off"
		show.call()
		if not note.is_empty(): Settings.message = note; refresh())
	toggle.text = "On" if loader.switched_on(file) else "Off"


## One scenario mod at a time (world/modding/scenario.gd): switching one on switches every other
## scenario mod off. Returns the one-line note ("" when nothing else changed). Scenario switches
## apply at the next launch only (mod_loader.gd switch()).
func _one_scenario_switch(row: Dictionary, on: bool) -> String:
	var loader := preload("res://world/modding/mod_loader.gd")
	if not on or (row.get("scenario", {}) as Dictionary).is_empty(): return ""
	var off := PackedStringArray()
	for other: Dictionary in loader.pack_rows():
		if other.file == row.file or (other.get("scenario", {}) as Dictionary).is_empty() or not bool(other.get("switchable", true)): continue
		if not loader.switched_on(str(other.file)): continue
		Mods.switch(str(other.file), false)
		off.append(str(other.scenario.name))
	var head := "%s switches on the next time the game starts." % str(row.scenario.name)
	if off.is_empty(): return head
	return head + " Switched off %s: only one scenario mod runs at a time." % ", ".join(off)


## Updates for bundled mods (world/update/mod_updates.gd): a check that asks the authors who
## publish an update address, and a button per update found. Nothing downloads until pressed.
func _mod_updates(list: VBoxContainer, shipped: Array) -> void:
	var path := "res://world/update/mod_updates.gd"
	if not shipped.any(func(row: Dictionary) -> bool: return not str(row.get("update_url", "")).is_empty()) or not ResourceLoader.exists(path): return
	var script := load(path) as GDScript
	if script == null or not script.can_instantiate(): return
	var updater: Variant = script.call("shared", self)
	if not updater is Node or not (updater as Node).has_method("available") or not (updater as Node).has_method("check_authors") or not (updater as Node).has_method("install"): return
	var node: Node = updater
	var box := VBoxContainer.new(); box.add_theme_constant_override("separation", 6); list.add_child(box)
	var fill := func() -> void:
		if not is_instance_valid(box): return
		for child in box.get_children(): child.queue_free()
		var busy: bool = node.get("busy") == true
		var check := _button(box, "Check for mod updates from their authors", func() -> void: node.call("check_authors"))
		check.size_flags_horizontal = Control.SIZE_EXPAND_FILL; check.disabled = busy
		for offer: Dictionary in node.call("available"):
			var id := str(offer.get("id", ""))
			var press := _button(box, "Update %s to %s (from the author)" % [str(offer.get("title", id)), str(offer.get("version", ""))], func() -> void: node.call("install", id))
			press.size_flags_horizontal = Control.SIZE_EXPAND_FILL; press.disabled = busy
		var status := str(node.get("status"))
		if not status.is_empty(): _note(box, status)
	fill.call()
	if node.has_signal("changed"):
		var again := func() -> void:
			fill.call()
			if is_inside_tree(): _redraw()
		node.connect("changed", again)
		box.tree_exiting.connect(func() -> void:
			if node.is_connected("changed", again): node.disconnect("changed", again))


## Which version this is, an update button while a newer one is out, and a check on demand
## (world/update/updater.gd, the same updater the title and the pause menu show).
func _build_updates(list: VBoxContainer) -> void:
	if not is_instance_valid(list) or not list.is_inside_tree(): return
	var updater: Node = preload("res://world/update/updater.gd").shared(self)
	updater.attach(list, Callable(), font_size)
	_button(list, "Check for updates now", func() -> void: updater.check()).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	updater.changed.connect(_redraw)


## Five presses of the Updates tab, each within 1.5 s of the last, show the Debug tab and turn the
## developer tools on at once (world/dev_tools.gd unlocked(), dev 2026-10-30).
func _on_updates_pressed() -> void:
	var now := Time.get_ticks_msec() * 0.001
	_updates_presses = _updates_presses + 1 if now - _updates_pressed_at < 1.5 else 1
	_updates_pressed_at = now
	if _updates_presses < 5 or Settings.get_value("debug/unlocked") == true: return
	Settings.set_value("debug/unlocked", true)
	Settings.message = "Debug tab enabled."
	if is_instance_valid(_debug_button): _debug_button.show()
	show_tab.call_deferred("Debug")


## Settings > Debug: buttons and a command line for the world's console (world/debug/command_console.gd).
func _build_debug(list: VBoxContainer) -> void:
	_note(list, "Developer tools. Also on: the ` console, debug fly (\\), noclip (Shift+\\) and the [ ] time skips, and full logging (the log file records everything, not only errors). Commands act on the open world.")
	var quick := [["Noclip on / off", "noclip"], ["Fly on / off", "fly"], ["Unstuck (stand on the ground here)", "unstuck"],
		["Back to the Ponyville spawn", "home"], ["Add 1000 bits", "bits 1000"], ["Bits to 999999", "bits"],
		["Morning (7:00)", "time 7"], ["Evening (19:00)", "time 19"], ["Night (23:00)", "time 23"]]
	for entry: Array in quick:
		var button := _button(list, str(entry[0]), _debug_run.bind(str(entry[1])))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL; button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_debug_field(list, "Pony name, e.g. rainbowdash", "Spawn pony", func(text: String) -> String: return "spawn " + text)
	_debug_field(list, "Any command: help, show, ponese …", "Run", func(text: String) -> String: return text)
	var hide_button := _button(list, "Hide the Debug tab", func() -> void:
		Settings.set_value("debug/unlocked", false)
		Settings.message = "Debug tab hidden. Press Updates five times to bring it back."
		if is_instance_valid(_debug_button): _debug_button.hide()
		show_tab("Updates"))
	hide_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _debug_field(list: VBoxContainer, hint: String, caption: String, command: Callable) -> void:
	var line := HBoxContainer.new(); line.add_theme_constant_override("separation", 6); list.add_child(line)
	var field := LineEdit.new(); field.placeholder_text = hint; field.max_length = 160
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL; field.add_theme_font_size_override("font_size", font_size - 1)
	field.focus_entered.connect(_redraw); line.add_child(field)
	var run := func() -> void:
		var text := field.text.strip_edges()
		if text.is_empty(): return
		field.clear(); _debug_run(str(command.call(text)))
	field.text_submitted.connect(func(_text: String) -> void: run.call())
	_button(line, caption, run)


func _debug_run(text: String) -> void:
	var console: Node = Settings.debug_console
	if not is_instance_valid(console): Settings.message = "Open a world first: commands act on it."; refresh(); return
	if console.get("_busy") == true: Settings.message = "A spawn is still loading."; refresh(); return
	Settings.message = "> " + text; refresh()
	var reply := str(await console.execute(text))
	if not is_inside_tree(): return
	Settings.message = reply if not reply.is_empty() else "Done."
	refresh()


## A pack's name, version, author and description (every mod in it), and its file name for the
## player's own packs.
func _mod_text(pack: Dictionary, mods: Array) -> String:
	var loader := preload("res://world/modding/mod_loader.gd")
	var lines := PackedStringArray()
	for mod: Dictionary in mods:
		if mod.file != pack.file: continue
		var head := str(mod.name) + ("  " + str(mod.version) if not str(mod.version).is_empty() else "")
		if not str(mod.author).is_empty(): head += "  by " + str(mod.author)
		lines.append(head)
		if loader.claims_game_author(str(mod.author)): lines.append("Third-party mod: its author field names the game itself.")
		if not str(mod.description).is_empty(): lines.append(str(mod.description))
	if lines.is_empty():
		var title := str(pack.get("title", ""))
		var version := str(pack.get("version", "")); var author := str(pack.get("author", ""))
		if not title.is_empty(): lines.append(title + ("  " + version if not version.is_empty() else "") + ("  by " + author if not author.is_empty() else ""))
	if not bool(pack.get("bundled", false)): lines.append(str(pack.file))
	return "\n".join(lines)


## The muted line under a pack (a mod_loader.gd pack_rows() row): why it is off, held, superseded
## or waiting for another mod, what patches it, cautions, and the game files it replaces. Old mods
## that replace game files hide newer game features (thread 43671981, mod_loader.gd is_old()).
func _mod_notes(row: Dictionary) -> String:
	var loader := preload("res://world/modding/mod_loader.gd")
	var lines := PackedStringArray()
	var reason := str(row.get("reason", ""))
	if not reason.is_empty(): lines.append(reason)
	var scenario: Dictionary = row.get("scenario", {}) if row.get("scenario") is Dictionary else {}
	if not scenario.is_empty():
		lines.append("Scenario: %s. It changes how new worlds start; its saves load only while it is on, and other saves only while it is off. Applies the next time the game starts." % str(scenario.get("name", "")))
	if bool(row.get("held", false)) and bool(row.get("switched_on", false)) and not bool(row.get("scenario_held", false)): lines.append("Switched on: it loads the next time the game starts.")
	elif bool(row.get("bundled", false)) and not bool(row.get("default_on", true)) and not bool(row.get("switched_on", false)) and reason.is_empty():
		lines.append("Off until you switch it on.")
	if loader.is_old(row) and not bool(row.get("held", false)):
		lines.append("Made for game %s, this is %s. Old mods that replace game files can hide newer features." % [row.game_version, loader.game_version()])
	for patch: Dictionary in row.get("patched_by", []):
		var name := ("%s %s" % [str(patch.get("title", "")), str(patch.get("version", ""))]).strip_edges()
		lines.append(("Includes devanon's patch %s." if bool(patch.get("bundled", false)) else "Patched by %s.") % name)
	match str(row.get("update", "")):
		"manifest": lines.append("Updated to %s with the game's updates." % str(row.get("version", "")))
		"author": lines.append("Updated to %s from its author." % str(row.get("version", "")))
	var warning := str(row.get("warning", ""))
	if not warning.is_empty(): lines.append(warning)
	var caution := str(row.get("caution", ""))
	if not caution.is_empty(): lines.append(caution)
	# Packs that are off never ran read_manifest(), so _mod_text() cannot flag them: their mod.json authors.
	var declared: Dictionary = row.get("declared", {}) if row.get("declared") is Dictionary else {}
	if not bool(row.get("mounted", false)):
		for id: Variant in declared:
			var info: Variant = declared[id]
			if info is Dictionary and loader.claims_game_author(str((info as Dictionary).get("author", ""))):
				lines.append("Third-party mod: its author field names the game itself."); break
	var overrides: PackedStringArray = row.get("overrides", PackedStringArray())
	if not overrides.is_empty():
		var shown := ", ".join(overrides.slice(0, 6)) + (" and %d more" % (overrides.size() - 6) if overrides.size() > 6 else "")
		lines.append("Replaces game files: " + shown)
	return "\n".join(lines)


## The "mods" folder beside the game on desktop (mod_loader.gd mod_dirs() reads it too; a player
## report 2026-10-29: easier to find than AppData), else the user-data one (Quest, source runs, or
## a game folder the player cannot write to).
func _open_mods_folder() -> void:
	var folder := ProjectSettings.globalize_path(preload("res://world/modding/mod_loader.gd").USER_DIR)
	if OS.has_feature("template") and not OS.has_feature("android"):
		var beside := OS.get_executable_path().get_base_dir().path_join("mods")
		if DirAccess.make_dir_recursive_absolute(beside) == OK: folder = beside
	DirAccess.make_dir_recursive_absolute(folder)
	Settings.message = ("Mods folder: " if OS.shell_open(folder) == OK else "Could not open a file manager. The mods folder is ") + folder
	refresh()


func _apply_typed(key: String, text: String) -> void:
	# Leaving the field untouched keeps the exact value (the height row shows it rounded).
	if text.strip_edges() == Settings.display(key):
		refresh(); return
	var typed: Variant = Settings.parse_typed(key, text)
	if typed != null: Settings.set_value(key, typed)
	refresh()


func _note(list: VBoxContainer, text: String) -> Label:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(STYLE.SKY, 0.07), Color(STYLE.SKY, 0.25), 1, 14, 14, 10)))
	list.add_child(card)
	var line := HBoxContainer.new(); line.add_theme_constant_override("separation", 10); card.add_child(line)
	var mark := ICON.make("info", font_size - 2, STYLE.SKY); mark.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	line.add_child(mark)
	var label := STYLE.label(text, "Muted", font_size - 4); label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(label)
	return label


func _button(parent: Node, text: String, callback: Callable) -> Button:
	var b := Button.new(); b.text = text; b.custom_minimum_size = Vector2(font_size * 2.4, font_size * 1.9)
	b.add_theme_font_size_override("font_size", font_size); b.pressed.connect(callback)
	b.focus_entered.connect(_redraw); b.mouse_entered.connect(_redraw); b.mouse_exited.connect(_redraw)
	parent.add_child(b)
	return b


func _show_tab(index: int) -> void:
	var changed := index != _tab
	_tab = index
	for i in _lists.size():
		_lists[i].visible = i == index
		if _tabs[i] != null: _tabs[i].set_pressed_no_signal(i == index)
	_scroll.scroll_vertical = 0
	feedback_notes.hide()
	controls_map.hide()
	var shown: Control = _scroll
	if current_tab() == "Controls map":
		_scroll.hide(); provider.hide(); prompts.hide(); controls_map.open(); shown = controls_map
	elif current_tab() == "AI Settings":
		_scroll.hide(); prompts.hide(); provider.open(); shown = provider
	elif current_tab() == "Prompts":
		_scroll.hide(); provider.hide(); prompts.open(); shown = prompts
	elif current_tab() == "Saved notes":
		_scroll.hide(); provider.hide(); prompts.hide(); feedback_notes.open(); shown = feedback_notes
	else:
		provider.hide(); prompts.hide(); _scroll.show()
	_tab_title.text = current_tab()
	if _tabs[index] != null: _tab_icon.kind = str(_tabs[index].get_meta("icon_kind", "gear"))
	if changed: _appear(shown)
	refresh()


## The newly shown tab drifts up into place.
func _appear(node: Control) -> void:
	if STYLE.still() or not is_inside_tree(): return
	node.modulate.a = 0.0
	var tween := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, "modulate:a", 1.0, 0.2)
	tween.parallel().tween_method(func(_v: float) -> void: _redraw(), 0.0, 1.0, 0.2)


func show_tab(title: String) -> void:
	for i in Settings.TABS.size():
		if str(Settings.TABS[i][0]) == title: _show_tab(i)


func current_tab() -> String:
	return str(Settings.TABS[_tab][0])


func refresh() -> void:
	if is_instance_valid(_lighting_controls): _lighting_controls.refresh()
	for action: String in _action_buttons:
		var entry: Array = _action_buttons[action]
		if is_instance_valid(entry[0]): (entry[0] as Button).text = Settings.action_label(action, str(entry[1]))
	for key: String in _values:
		var node: Control = _values[key]
		if not is_instance_valid(node): continue
		if key.begins_with("bind:"):
			var action := key.get_slice(":", 1)
			(node as Button).text = "Press a key…" if capturing == action else Settings.key_name(Settings.binding(action))
		elif node is CheckButton:
			var on := bool(Settings.get_value(key))
			(node as CheckButton).set_pressed_no_signal(on)
			(node.get_meta("state_label") as Label).text = Settings.display(key)
		elif node is Label or node is LineEdit:
			# A slider's value beside it; a typed one is left alone while it is being typed.
			if node is Label: (node as Label).text = Settings.display(key)
			elif not node.has_focus(): (node as LineEdit).text = Settings.display(key)
			var slider: HSlider = _sliders.get(key)
			if slider != null: slider.set_value_no_signal(_option_index(key) if Settings.SPECS[key].has("presets") else float(Settings.get_value(key)))
		elif node is HBoxContainer:
			for pill: Node in node.get_children(): (pill as Button).set_pressed_no_signal(_same(pill.get_meta("value"), Settings.get_value(key)))
		else:
			var options: Array = node.get_meta("options")
			var chosen := -1
			for i in options.size():
				if key == "video/render_scale": node.set_item_text(i, _option_text(key, options[i]))
				if _same(options[i][0], Settings.get_value(key)): chosen = i
			node.selected = chosen
	# Window size only means something for a window (dev 2026-10-27: "grey it out when not windowed").
	_set_row_enabled("video/window_size", str(Settings.get_value("video/window")) == "windowed")
	_set_row_enabled("access/caption_opacity", Settings.get_value("access/caption_card") == true)
	if is_instance_valid(_quality_note): _quality_note.text = _quality_description()
	_status.text = Settings.message
	_status.visible = not Settings.message.is_empty()
	_redraw()


func _quality_description() -> String:
	var chosen := str(Settings.get_value("video/quality"))
	var base := str(Settings.get_value("video/quality_base")) if chosen == "Custom" else chosen
	var detail := "More scenery and effects, with detailed ponies visible farther away."
	if base in ["Very Low", "Low"]:
		detail = "Simpler scenery and effects; distant ponies use simpler detail sooner."
	elif base == "Medium":
		detail = "Balanced scenery and effects, with simpler detail on distant ponies."
	var heading := "Custom, based on %s: " % base if chosen == "Custom" else ""
	return heading + detail + " Nearby interactions and pony population stay the same."


## Where keyboard and stick focus starts: the open tab's own button.
func first_focus() -> Control:
	return _tabs[_tab] if _tabs[_tab] != null else _tab_order[0]


## Focusable buttons of the visible tab, top to bottom (title screen / VR stick focus).
func focusables() -> Array:
	var out: Array = []
	out.append_array(_tab_order)
	if current_tab() == "AI Settings":
		out.append_array(provider.controls)
		out.append_array(footer.get_children())
		return out
	if current_tab() == "Prompts":
		out.append_array(prompts.controls)
		out.append_array(footer.get_children())
		return out
	if current_tab() == "Saved notes":
		out.append_array(feedback_notes.controls)
		out.append_array(footer.get_children())
		return out
	if current_tab() == "Controls map":
		out.append_array(controls_map.controls)
		out.append_array(footer.get_children())
		return out
	for node in _lists[_tab].find_children("*", "Control", true, false):
		if node is HSlider and (node as Control).is_visible_in_tree(): out.append(node)
		elif node is Button and not (node as Button).disabled and (node as Control).is_visible_in_tree(): out.append(node)
	out.append_array(footer.get_children())
	return out


func _on_changed(_key: String) -> void:
	if is_inside_tree(): refresh()


func _capture(action: String) -> void:
	capturing = action
	Settings.message = "Press a key for %s (Esc cancels)." % action.replace("_", " ")
	refresh()


func _input(event: InputEvent) -> void:
	if capturing.is_empty() or not is_visible_in_tree(): return
	if not (event is InputEventKey) or not event.pressed or event.echo: return
	var key := event as InputEventKey
	var code: int = key.physical_keycode if key.physical_keycode != 0 else key.keycode
	var action := capturing
	capturing = ""
	if code == KEY_ESCAPE:
		Settings.message = ""
	else:
		Settings.message = "%s → %s" % [action.replace("_", " "), Settings.key_name(code)]
		Settings.bind_key(action, code)
	get_viewport().set_input_as_handled()
	refresh()


func _redraw() -> void:
	if redraw.is_valid(): redraw.call()
