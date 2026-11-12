extends PanelContainer
## Shared desktop and spatial-panel credits. Plain text preserves complete notices;
## entry selection and page-sized scroll buttons work with a controller ray too.
signal back_requested

const DATA := preload("res://world/ui/credits.gd")
## The /mlp/ team crest from the 4chan Cup.
const BOARD_CREST := preload("res://world/ui/credits/mlp_crest.png")
const SECTIONS := [["Creators", "assets"], ["Libraries", "libraries"], ["Fonts", "fonts"], ["Engine", "engine"], ["Terms", "terms"]]
var redraw := Callable()
var back_button: Button
var _tabs: Array[Button] = []
var _entries: Array[Dictionary] = []
var _entry_buttons: Array[Button] = []
var _section := "assets"
var _entry := 0
var _index_open := false
var _scroll: ScrollContainer
var _body: Label
var _list: VBoxContainer
var _title: Label
var _counter: Label
var _previous: Button
var _next: Button
var _contents: Button
var _up: Button
var _down: Button
var _font_size := 23


func setup(page_size: Vector2, text_size: int = 23) -> void:
	_font_size = text_size
	size = page_size; custom_minimum_size = page_size
	theme = preload("res://world/ui/menu_style.gd").theme()
	# The host's menu card (world/ui/menu_card.gd) is the background.
	var background := StyleBoxEmpty.new()
	background.content_margin_left = 20; background.content_margin_right = 20
	background.content_margin_top = 16; background.content_margin_bottom = 16
	add_theme_stylebox_override("panel", background)
	var layout := VBoxContainer.new(); layout.add_theme_constant_override("separation", 12); add_child(layout)
	var heading := Label.new(); heading.text = "Credits & licences"; heading.theme_type_variation = "Heading"
	heading.add_theme_font_size_override("font_size", text_size + 13); layout.add_child(heading)
	# dev 2026-11-08: the board credit stands front and centre, above every tab.
	var board := HBoxContainer.new(); board.alignment = BoxContainer.ALIGNMENT_CENTER
	board.add_theme_constant_override("separation", 16); layout.add_child(board)
	var crest := TextureRect.new(); crest.texture = BOARD_CREST
	crest.expand_mode = TextureRect.EXPAND_IGNORE_SIZE; crest.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	crest.custom_minimum_size = Vector2.ONE * (text_size * 4); board.add_child(crest)
	var board_label := Label.new(); board_label.text = DATA.BOARD_CREDIT; board_label.theme_type_variation = "Heading"
	board_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	board_label.add_theme_font_size_override("font_size", text_size + 9); board.add_child(board_label)
	var tabs := HBoxContainer.new(); tabs.add_theme_constant_override("separation", 6); layout.add_child(tabs)
	for section: Array in SECTIONS:
		var button := _button(tabs, str(section[0]), _show_section.bind(str(section[1])))
		button.toggle_mode = true; button.theme_type_variation = "Chip"; _tabs.append(button)
	var navigation := HBoxContainer.new(); navigation.add_theme_constant_override("separation", 8); layout.add_child(navigation)
	_previous = _button(navigation, "Previous", _step.bind(-1))
	_counter = Label.new(); _counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_counter.size_flags_horizontal = Control.SIZE_EXPAND_FILL; _counter.add_theme_font_size_override("font_size", text_size - 2)
	navigation.add_child(_counter)
	_next = _button(navigation, "Next", _step.bind(1))
	_title = Label.new(); _title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; _title.theme_type_variation = "Subheading"
	_title.add_theme_font_size_override("font_size", text_size + 3); layout.add_child(_title)
	_scroll = ScrollContainer.new(); _scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; _scroll.follow_focus = true
	layout.add_child(_scroll)
	var holder := VBoxContainer.new(); holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL; _scroll.add_child(holder)
	_body = Label.new(); _body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_theme_font_size_override("font_size", text_size); _body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.add_child(_body)
	_list = VBoxContainer.new(); _list.add_theme_constant_override("separation", 6); holder.add_child(_list)
	var footer := HBoxContainer.new(); footer.add_theme_constant_override("separation", 8); layout.add_child(footer)
	_contents = _button(footer, "Entry list", _show_index)
	_up = _button(footer, "Scroll up", _scroll_page.bind(-1))
	_down = _button(footer, "Scroll down", _scroll_page.bind(1))
	back_button = _button(footer, "Back", func(): back_requested.emit())
	_scroll.get_v_scroll_bar().value_changed.connect(func(_value: float): _refresh())
	_show_section("assets")


func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new(); button.text = text
	button.custom_minimum_size.y = 50; button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", _font_size - 2)
	button.pressed.connect(action); button.focus_entered.connect(_refresh)
	parent.add_child(button)
	return button


func _show_section(section: String) -> void:
	_section = section; _entries = DATA.entries(section)
	for index: int in _tabs.size(): _tabs[index].set_pressed_no_signal(str(SECTIONS[index][1]) == section)
	for button: Button in _entry_buttons: button.free()
	_entry_buttons.clear()
	for index: int in _entries.size():
		var button := _button(_list, str(_entries[index].title), _show_entry.bind(index))
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_entry_buttons.append(button)
	_show_entry(0)


func _show_entry(index: int) -> void:
	_entry = clampi(index, 0, _entries.size() - 1); _index_open = false
	_body.show(); _list.hide()
	_title.text = str(_entries[_entry].title)
	_body.text = str(_entries[_entry].text)
	_counter.text = "%d / %d" % [_entry + 1, _entries.size()]
	_previous.disabled = _entry == 0; _next.disabled = _entry == _entries.size() - 1
	_contents.disabled = false
	_scroll.scroll_vertical = 0
	_refresh.call_deferred()


func _show_index() -> void:
	_index_open = true; _body.hide(); _list.show()
	_title.text = "Choose an entry"; _counter.text = "%d entries" % _entries.size()
	_previous.disabled = true; _next.disabled = true; _contents.disabled = true
	_scroll.scroll_vertical = 0
	_refresh.call_deferred()


func _step(direction: int) -> void:
	_show_entry(_entry + direction)


func _scroll_page(direction: int) -> void:
	_scroll.scroll_vertical += direction * maxi(1, int(_scroll.size.y) - _font_size * 2)
	_refresh()


func focusables() -> Array:
	var result: Array = []
	for button: Button in _tabs + [_previous, _next] + (_entry_buttons if _index_open else []) + [_contents, _up, _down, back_button]:
		if not button.disabled and button.is_visible_in_tree(): result.append(button)
	return result


func _refresh() -> void:
	if redraw.is_valid(): redraw.call()
