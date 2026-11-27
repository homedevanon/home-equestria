extends Control
## "Who lives where" (its own Settings tab under World, 2026-11-24; captures plan population_manager.md section 3):
## a full-screen setup page that chooses which region every pony lives in, or that she is not
## spawned. Big cards in a grid (world/ui/population/population_card.gd); select any number
## (click, shift-click for a range, "Select all shown"), then press one place in the right column
## and they all move there at once. No per-pony dropdown. Presets, one-step undo and plain
## warnings at the bottom. Every change is written at once by world/population/population_choices.gd
## and the running game takes it within seconds; pictures come from world/ui/population/pictures.gd.
##
## Where it draws: on desktop (and seated VR, whose virtual screen adopts every CanvasLayer) a
## CanvasLayer over the whole window, laid out for 1600 x 900 and scaled like the other menus;
## the hosts underneath stop taking input until it closes. With a headset on and the settings
## page on a spatial panel (standing VR, the title in a headset), it covers that panel's page and
## the panel's own ray reaches it. It works while the game is paused and frees itself on Close.

const STYLE := preload("res://world/ui/menu_style.gd")
const ICON := preload("res://world/ui/menu_icon.gd")
const CARD := preload("res://world/ui/menu_card.gd")
const PONY_CARD := preload("res://world/ui/population/population_card.gd")
const PANEL := preload("res://world/ui/spatial_menu_panel.gd")
const CATALOGUE := preload("res://world/saves/save_catalogue.gd")
const SELF_PATH := "res://world/ui/population/population_window.gd"
const CHOICES_PATH := "res://world/population/population_choices.gd"
const PICTURES_PATH := "res://world/ui/population/pictures.gd"
const SETTINGS_PAGE := "res://world/ui/settings_page.gd"
const WORLDS_ROOT := "user://worlds"
## Above the settings panel (150) and the pause menu (140).
const LAYER := 160
const FONT := 20
const GAP := 12
const FILTERS := [["All", "all"], ["Not spawned", "not_spawned"], ["Fillies", "fillies"], ["Earth ponies", "tribe:earth"],
	["Pegasi", "tribe:pegasus"], ["Unicorns", "tribe:unicorn"], ["Alicorns", "tribe:alicorn"]]
const HELP := "Select ponies, then press a place on the right: they all move there. Ponies arrive when you come near and leave once out of sight."

## Test stand-ins (tools/population/shot_population_window.gd); the game leaves them null.
static var choices_script: Variant = null
static var pictures_script: Variant = null

var choices: Variant = null
## World folders this window can edit: "user://worlds/<id>", or "" for the ponies new worlds start with.
var world_dirs: Array[String] = []
var world_index := 0
var _running := false
var _closed := false
var _host: Node
var _panel: Node
var _layer: CanvasLayer
var _silenced: Array[Node] = []
var _mouse_mode := Input.MOUSE_MODE_VISIBLE
var _oversampling := 0.0
var _pictures: Variant = null
var _ponies: Array[Dictionary] = []
var _region_names: Dictionary = {}
var _cards: Dictionary = {}          # pony id -> population_card
var _shown: Array[String] = []       # ids of the cards the filter shows, in grid order
var _selected: Dictionary = {}       # pony id -> true
var _anchor := ""
var _filter := "all"
var _reload_queued := false
var _more_open := false

var _world_name: Label
var _world_line: Label
var _previous: Button
var _next: Button
var _search: LineEdit
var _count: Label
var _chips: HFlowContainer
var _scroll: ScrollContainer
var _grid: GridContainer
var _side: VBoxContainer
var _regions: VBoxContainer
var _not_spawned: Button
var _status: Label
var _warnings: Label
var _presets: HFlowContainer
var _preset_name: LineEdit
var _undo: Button
var _close: Button


## Builds and shows the window over `parent` (the settings page that asked, or any node in the
## tree). `world_dir` "" edits the running world, or on the title the newest saved world.
static func open(parent: Node, world_dir: String = "") -> Node:
	if parent == null or not parent.is_inside_tree(): return null
	var window: Control = (load(SELF_PATH) as GDScript).new()
	if not bool(window.call("_start", parent, world_dir)):
		window.free(); return null
	return window


## The settings page whose "Who lives where" button was pressed: the visible one holding its
## viewport's focus, else the first visible one; null when none shows.
static func settings_host(tree: SceneTree) -> Node:
	if tree == null: return null
	var first: Node = null
	for node: Node in tree.root.find_children("*", "VBoxContainer", true, false):
		var script := node.get_script() as Script
		if script == null or script.resource_path != SETTINGS_PAGE or not (node as Control).is_visible_in_tree(): continue
		var focus: Control = node.get_viewport().gui_get_focus_owner()
		if focus != null and node.is_ancestor_of(focus): return node
		if first == null: first = node
	return first


func _start(parent: Node, world_dir: String) -> bool:
	if choices_script == null: choices_script = load(CHOICES_PATH)
	_pictures = pictures_script if pictures_script != null else load(PICTURES_PATH)
	if choices_script == null or _pictures == null:
		push_error("[population] window needs %s and %s" % [CHOICES_PATH, PICTURES_PATH]); return false
	_host = parent
	name = "PopulationWindow"
	theme = STYLE.theme()
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	var headset := XRServer.primary_interface != null and XRServer.primary_interface.is_initialized()
	_panel = _panel_of(parent) if headset else null
	if _panel != null:
		var content: Control = _panel.get("content")
		position = Vector2.ZERO; size = content.size
		content.add_child(self)
	else:
		_layer = CanvasLayer.new(); _layer.name = "PopulationWindowLayer"; _layer.layer = LAYER
		_layer.process_mode = Node.PROCESS_MODE_ALWAYS
		parent.get_tree().root.add_child(_layer)
		_layer.add_child(self)
		_oversampling = get_viewport().oversampling_override
		_fit_window()
		get_viewport().size_changed.connect(_fit_window)
		_mouse_mode = Input.mouse_mode; Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		# The menus underneath (settings, pause, title) would take the keys and the mouse first.
		var at := parent
		while at != null:
			if not (at is Viewport) and at.is_processing_input():
				at.set_process_input(false); _silenced.append(at)
			at = at.get_parent()
	_build()
	_find_worlds(world_dir)
	_load_world()
	var first: Control = _cards.get(_shown[0]) if not _shown.is_empty() else _search
	first.grab_focus()
	_redraw()
	return true


static func _panel_of(node: Node) -> Node:
	var at := node
	while at != null:
		if at is PANEL: return at
		at = at.get_parent()
	return null


func _fit_window() -> void:
	var window := Vector2(get_viewport().get_visible_rect().size)
	var k := STYLE.window_scale(window)
	scale = Vector2.ONE * k; position = Vector2.ZERO; size = (window / k).floor()
	STYLE.sharpen(get_viewport(), k)


func close() -> void:
	if _closed: return
	_closed = true
	for node in _silenced:
		if is_instance_valid(node): node.set_process_input(true)
	_silenced.clear()
	if _layer != null:
		Input.mouse_mode = _mouse_mode
		get_viewport().oversampling_override = _oversampling
		_layer.queue_free()
	else:
		queue_free()
	if is_instance_valid(_panel): _panel.call("refresh")


func _process(_delta: float) -> void:
	# The menu that opened it went away (Back, quit to title, the headset panel put down).
	var gone := not is_instance_valid(_host) or (_host is CanvasItem and not (_host as CanvasItem).is_visible_in_tree())
	if _panel != null: gone = gone or not is_instance_valid(_panel) or not (_panel as Node3D).is_visible_in_tree()
	if gone: close()


func _input(event: InputEvent) -> void:
	if _closed or _layer == null: return
	if event.is_action_pressed("ui_cancel"):
		close(); get_viewport().set_input_as_handled()


## Keys nothing here used stay here: the game's hotkeys sleep while the window shows.
func _unhandled_input(event: InputEvent) -> void:
	if not _closed and _layer != null and event is InputEventKey: get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ building
func _build() -> void:
	if _layer != null:
		var shade := ColorRect.new(); shade.color = Color(0.04, 0.01, 0.07, 0.55)
		shade.set_anchors_preset(Control.PRESET_FULL_RECT); shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(shade)
	var card: Control = CARD.new(); card.set_anchors_preset(Control.PRESET_FULL_RECT); card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(card)
	var page := VBoxContainer.new(); page.set_anchors_preset(Control.PRESET_FULL_RECT)
	page.offset_left = 38; page.offset_top = 30; page.offset_right = -38; page.offset_bottom = -30
	page.add_theme_constant_override("separation", 10); add_child(page)
	# ---- top bar: the title and the world being edited
	var head := HBoxContainer.new(); head.add_theme_constant_override("separation", GAP); page.add_child(head)
	var mark := ICON.make("pony", FONT + 12, STYLE.PINK); mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER; head.add_child(mark)
	var title := STYLE.label("Who lives where", "Heading", FONT + 12); title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL; head.add_child(title)
	_previous = _round(head, "back", "Previous world", _step_world.bind(-1))
	var names := VBoxContainer.new(); names.add_theme_constant_override("separation", 0)
	names.custom_minimum_size.x = 260; names.size_flags_vertical = Control.SIZE_SHRINK_CENTER; head.add_child(names)
	_world_name = _clipped(STYLE.label("", "Subheading", FONT)); names.add_child(_world_name)
	_world_line = _clipped(STYLE.label("", "Faint", FONT - 5)); names.add_child(_world_line)
	_next = _round(head, "forward", "Next world", _step_world.bind(1))
	# ---- body: cards on the left, places on the right
	var body := HBoxContainer.new(); body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 18); page.add_child(body)
	var left := VBoxContainer.new(); left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 8); body.add_child(left)
	var tools := HBoxContainer.new(); tools.add_theme_constant_override("separation", 8); left.add_child(tools)
	_search = LineEdit.new(); _search.placeholder_text = "Search by name"; _search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL; _search.custom_minimum_size = Vector2(160, 42)
	_search.text_changed.connect(func(_text: String) -> void: _apply_filter())
	_search.focus_entered.connect(_redraw); tools.add_child(_search)
	_small(_button(tools, "Select all shown", _select_shown))
	_small(_button(tools, "Clear selection", _clear_selection))
	_count = STYLE.label("", "Muted", FONT - 4); _count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_count.custom_minimum_size.x = 100; tools.add_child(_count)
	_chips = HFlowContainer.new(); _chips.add_theme_constant_override("h_separation", 6)
	_chips.add_theme_constant_override("v_separation", 6); left.add_child(_chips)
	_scroll = ScrollContainer.new(); _scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; _scroll.follow_focus = true
	_scroll.get_v_scroll_bar().value_changed.connect(func(_value: float) -> void: _redraw())
	left.add_child(_scroll)
	# Room for a focused card's ring inside the scroll's clip, and for the scroll bar.
	var holder := MarginContainer.new(); holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side: String in ["left", "top", "bottom"]: holder.add_theme_constant_override("margin_" + side, 5)
	holder.add_theme_constant_override("margin_right", 18); _scroll.add_child(holder)
	_grid = GridContainer.new(); _grid.add_theme_constant_override("h_separation", GAP)
	_grid.add_theme_constant_override("v_separation", GAP); holder.add_child(_grid)
	_scroll.resized.connect(_fit_columns)
	_side = VBoxContainer.new(); _side.custom_minimum_size.x = 300 if _layer != null else 236
	_side.add_theme_constant_override("separation", 8); body.add_child(_side)
	_side.add_child(STYLE.label("Move selected to", "Subheading", FONT))
	var region_scroll := ScrollContainer.new(); region_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	region_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; region_scroll.follow_focus = true
	region_scroll.get_v_scroll_bar().value_changed.connect(func(_value: float) -> void: _redraw())
	_side.add_child(region_scroll)
	var region_holder := MarginContainer.new(); region_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side: String in ["left", "top", "bottom"]: region_holder.add_theme_constant_override("margin_" + side, 4)
	region_holder.add_theme_constant_override("margin_right", 14); region_scroll.add_child(region_holder)
	_regions = VBoxContainer.new(); _regions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_regions.add_theme_constant_override("separation", 6); region_holder.add_child(_regions)
	_not_spawned = _button(_side, "Not spawned", _move_to.bind(""), "Danger")
	_not_spawned.custom_minimum_size.y = 50; _not_spawned.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_not_spawned.icon = ICON.texture("close", FONT)
	_counter(_not_spawned)
	# ---- what to look out for, presets, then what happened beside Undo and Close
	_warnings = STYLE.label("", "Warn", FONT - 3); _warnings.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_warnings)
	var presets_row := HBoxContainer.new(); presets_row.add_theme_constant_override("separation", 10); page.add_child(presets_row)
	var presets_label := STYLE.label("Presets", "Muted", FONT - 3); presets_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	presets_row.add_child(presets_label)
	_presets = HFlowContainer.new(); _presets.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_presets.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_presets.add_theme_constant_override("h_separation", 6); _presets.add_theme_constant_override("v_separation", 6)
	presets_row.add_child(_presets)
	_preset_name = LineEdit.new(); _preset_name.placeholder_text = "New preset name"; _preset_name.custom_minimum_size = Vector2(200, 40)
	_preset_name.size_flags_vertical = Control.SIZE_SHRINK_CENTER; _preset_name.focus_entered.connect(_redraw)
	presets_row.add_child(_preset_name)
	var save := _button(presets_row, "Save current as preset", _save_preset); save.icon = ICON.texture("save", FONT - 2)
	_small(save); save.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var footer := HBoxContainer.new(); footer.add_theme_constant_override("separation", 10); page.add_child(footer)
	_status = STYLE.label(HELP, "Muted", FONT - 3); _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.max_lines_visible = 2; _status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER; footer.add_child(_status)
	_undo = _button(footer, "Undo last change", _undo_change); _undo.icon = ICON.texture("refresh", FONT)
	_close = _button(footer, "Close", close, "Primary"); _close.custom_minimum_size.x = 130


func _button(parent: Node, text: String, action: Callable, variation := "") -> Button:
	var node := Button.new(); node.text = text; node.theme_type_variation = variation
	node.custom_minimum_size.y = 44
	if action.is_valid(): node.pressed.connect(action)
	node.focus_entered.connect(_redraw); node.mouse_entered.connect(_redraw); node.mouse_exited.connect(_redraw)
	parent.add_child(node)
	return node


func _small(node: Button) -> void:
	node.add_theme_font_size_override("font_size", FONT - 3)


func _round(parent: Node, kind: String, tip: String, action: Callable) -> Button:
	var node := _button(parent, "", action, "Round"); node.tooltip_text = tip
	node.icon = ICON.texture(kind, FONT); node.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	node.custom_minimum_size = Vector2.ONE * FONT * 2; node.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return node


func _clipped(node: Label) -> Label:
	node.clip_text = true; node.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return node


## A count at the right end of a place button.
func _counter(button: Button) -> Label:
	var count := STYLE.label("", "Muted", FONT - 3); count.name = "Count"
	count.set_anchors_preset(Control.PRESET_RIGHT_WIDE); count.offset_left = -64; count.offset_right = -14
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(count)
	return count


func _fit_columns() -> void:
	var room := _scroll.size.x - 23.0
	var columns := maxi(1, int((room + GAP) / (PONY_CARD.SIZE.x + GAP)))
	if columns != _grid.columns: _grid.columns = columns; _redraw()


## Rebuilt rows go at once (a pressed button may be among them, so it is freed after its signal).
func _empty(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child); child.queue_free()


func _redraw() -> void:
	if is_instance_valid(_panel): _panel.call("refresh")


# ------------------------------------------------------------------ worlds
func _find_worlds(wanted: String) -> void:
	world_dirs.clear()
	var running := _running_world()
	_running = not running.is_empty()
	if _running:
		world_dirs.append(running)
	else:
		var found: Array = []
		var dir := DirAccess.open(WORLDS_ROOT)
		if dir != null:
			for id: String in dir.get_directories():
				var file := WORLDS_ROOT.path_join(id).path_join("population.json")
				if FileAccess.file_exists(file): found.append({"dir": WORLDS_ROOT.path_join(id), "stamp": FileAccess.get_modified_time(file)})
		found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.stamp) > int(b.stamp))
		for row: Dictionary in found: world_dirs.append(str(row.dir))
		world_dirs.append("")
	if not wanted.is_empty() and not world_dirs.has(wanted): world_dirs.push_front(wanted)
	world_index = maxi(0, world_dirs.find(wanted)) if not wanted.is_empty() else 0


## The world the game is playing ("user://worlds/<id>"), "" on the title screen.
func _running_world() -> String:
	var population: Node = get_tree().get_first_node_in_group("pony_populations")
	if population == null or not ("config_path" in population): return ""
	var path := str(population.get("config_path"))
	return path.get_base_dir() if path.begins_with(WORLDS_ROOT + "/") else ""


func _step_world(step: int) -> void:
	if world_dirs.size() < 2: return
	world_index = posmod(world_index + step, world_dirs.size())
	_load_world()


func _load_world() -> void:
	if choices != null and (choices as Object).is_connected("changed", _queue_reload):
		(choices as Object).disconnect("changed", _queue_reload)
	var dir := world_dirs[world_index]
	choices = choices_script.call("open", dir)
	(choices as Object).connect("changed", _queue_reload)
	_selected.clear(); _anchor = ""
	_previous.visible = world_dirs.size() > 1; _next.visible = world_dirs.size() > 1
	if dir.is_empty():
		_world_name.text = "New worlds"; _world_line.text = "The ponies every new world starts with"
	else:
		_world_name.text = CATALOGUE.world_title(WORLDS_ROOT, dir.get_file())
		_world_line.text = "The world you are playing" if _running else "Saved world %d of %d" % [world_index + 1, world_dirs.size() - 1]
	_empty(_grid)
	_cards.clear()
	_reload()
	for pony: Dictionary in _ponies:
		var id := str(pony.id)
		var picture: Texture2D = _pictures.call("card_texture", id)
		var photo: Texture2D = _pictures.call("photo_texture", id)
		var card: PONY_CARD = PONY_CARD.new()
		card.setup(pony, picture, photo if photo != picture else null)
		card.show_place(pony, str(_region_names.get(str(pony.region), "")))
		card.pressed.connect(_on_card.bind(id))
		card.focus_entered.connect(_redraw); card.mouse_entered.connect(_redraw); card.mouse_exited.connect(_redraw)
		_grid.add_child(card); _cards[id] = card
	_status.text = HELP
	_apply_filter()


# ------------------------------------------------------------------ showing the choices
func _queue_reload() -> void:
	if _reload_queued: return
	_reload_queued = true
	_reload.call_deferred()


## Everything that follows the data: tags, counts, places, chips, presets, warnings, undo.
func _reload() -> void:
	_reload_queued = false
	if _closed or choices == null: return
	_ponies.clear()
	var listed: Array = choices.call("ponies")
	for pony: Dictionary in listed: _ponies.append(pony)
	var regions: Array = choices.call("regions")
	_region_names.clear()
	for region: Dictionary in regions: _region_names[str(region.id)] = str(region.name)
	# Rebuilt buttons hand the focus on to their replacement (keyboard and gamepad keep their place).
	var focused := get_viewport().gui_get_focus_owner()
	var keep := str(focused.get_meta(&"key")) if focused != null and focused.has_meta(&"key") else ""
	var off := 0
	for pony: Dictionary in _ponies:
		if bool(pony.not_spawned): off += 1
		var card: PONY_CARD = _cards.get(str(pony.id))
		if card != null: card.show_place(pony, str(_region_names.get(str(pony.region), "")))
	_build_places(regions)
	(_not_spawned.get_node("Count") as Label).text = str(off)
	_build_chips(regions)
	_build_presets()
	var warned: PackedStringArray = choices.call("warnings")
	var lines := PackedStringArray()
	var homes := int(choices.call("free_homes"))
	if homes >= 0: lines.append("Ponyville has %d free %s." % [homes, "home" if homes == 1 else "homes"])
	lines.append_array(warned)
	_warnings.text = "\n".join(lines)
	_warnings.visible = not lines.is_empty()
	_warnings.remove_theme_color_override("font_color")
	if homes >= 0 and lines.size() == 1: _warnings.add_theme_color_override("font_color", STYLE.MUTED)
	_undo.disabled = not bool(choices.call("can_undo"))
	if not keep.is_empty():
		for row: Node in [_regions, _chips, _presets]:
			for child in row.get_children():
				if str(child.get_meta(&"key", "")) == keep: (child as Control).grab_focus()
	_apply_filter()


func _build_places(regions: Array) -> void:
	_empty(_regions)
	var others: Array[Dictionary] = []
	for region: Dictionary in regions:
		if bool(region.common): _place(_regions, region)
		else: others.append(region)
	others.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.name) < str(b.name))
	if not others.is_empty():
		var more := _button(_regions, "More places" if not _more_open else "Fewer places", _toggle_more, "Ghost")
		more.icon = ICON.texture("forward" if not _more_open else "back", FONT - 2); more.alignment = HORIZONTAL_ALIGNMENT_LEFT
		more.set_meta(&"key", "more")
		if _more_open:
			for region in others: _place(_regions, region)


func _place(parent: Node, region: Dictionary) -> void:
	var id := str(region.id)
	var count := int(region.count)
	var button := _button(parent, str(region.name), _move_to.bind(id))
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT; button.clip_text = true
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL; button.set_meta(&"key", "place:" + id)
	button.tooltip_text = "%s: %d %s" % [region.name, count, "pony" if count == 1 else "ponies"]
	# Its colour is the cards' tag colour; the name stops short of the count at the right end.
	var tint := STYLE.swatch_for(id)
	for state: Array in [["normal", Color(tint, 0.13), Color(tint, 0.5), 1], ["hover", Color(tint, 0.3), STYLE.PINK, 2],
			["pressed", Color(STYLE.LILAC, 0.5), Color.WHITE, 2], ["hover_pressed", Color(STYLE.LILAC, 0.6), Color.WHITE, 2]]:
		var style := STYLE.box(state[1], state[2], int(state[3]), 14)
		style.content_margin_right = 64
		button.add_theme_stylebox_override(str(state[0]), STYLE.rounded(style))
	_counter(button).text = str(count)


func _toggle_more() -> void:
	_more_open = not _more_open
	_reload()


func _build_chips(regions: Array) -> void:
	_empty(_chips)
	var entries: Array = FILTERS.duplicate()
	for region: Dictionary in regions:
		if int(region.count) > 0: entries.append([str(region.name), "region:" + str(region.id)])
	var group := ButtonGroup.new()
	for entry: Array in entries:
		var chip := _button(_chips, str(entry[0]), _set_filter.bind(str(entry[1])), "Chip")
		chip.toggle_mode = true; chip.button_group = group; chip.custom_minimum_size.y = 34
		chip.set_pressed_no_signal(str(entry[1]) == _filter); chip.set_meta(&"key", "filter:" + str(entry[1]))
	if _filter.begins_with("region:") and not entries.any(func(e: Array) -> bool: return str(e[1]) == _filter):
		_filter = "all"
		(_chips.get_child(0) as Button).set_pressed_no_signal(true)


func _build_presets() -> void:
	_empty(_presets)
	var listed: Array = choices.call("presets")
	for preset: Dictionary in listed:
		var chip := _button(_presets, str(preset.name), _apply_preset.bind(str(preset.id), str(preset.name)), "Chip")
		chip.custom_minimum_size.y = 34; chip.set_meta(&"key", "preset:" + str(preset.id))
		if not bool(preset.get("builtin", false)): chip.icon = ICON.texture("heart", FONT - 6)


func _set_filter(id: String) -> void:
	_filter = id
	_apply_filter()


func _matches(pony: Dictionary) -> bool:
	var words := _search.text.strip_edges().to_lower()
	if not words.is_empty() and not str(pony.name).to_lower().contains(words): return false
	if _filter == "not_spawned": return bool(pony.not_spawned)
	if _filter == "fillies": return bool(pony.filly)
	if _filter.begins_with("tribe:"): return str(pony.tribe) == _filter.trim_prefix("tribe:")
	if _filter.begins_with("region:"): return not bool(pony.not_spawned) and str(pony.region) == _filter.trim_prefix("region:")
	return true


func _apply_filter() -> void:
	_shown.clear()
	for pony: Dictionary in _ponies:
		var card: Button = _cards.get(str(pony.id))
		if card == null: continue
		card.visible = _matches(pony)
		if card.visible: _shown.append(str(pony.id))
	_show_selection()


func _show_selection() -> void:
	for id: String in _cards: (_cards[id] as PONY_CARD).set_selected(_selected.has(id))
	_count.text = "%d selected" % _selected.size() if not _selected.is_empty() else "%d shown" % _shown.size()
	_redraw()


# ------------------------------------------------------------------ choosing
func _on_card(id: String) -> void:
	var card: PONY_CARD = _cards.get(id)
	if card == null: return
	if card.locked:
		_say("%s stays where she is in this version." % card.tooltip_text); return
	if Input.is_key_pressed(KEY_SHIFT) and _shown.has(_anchor) and _shown.has(id):
		var from := _shown.find(_anchor); var to := _shown.find(id)
		for i in range(mini(from, to), maxi(from, to) + 1):
			if not (_cards[_shown[i]] as PONY_CARD).locked: _selected[_shown[i]] = true
	elif _selected.has(id): _selected.erase(id)
	else: _selected[id] = true
	_anchor = id
	_show_selection()


func _select_shown() -> void:
	for id in _shown:
		if not (_cards[id] as PONY_CARD).locked: _selected[id] = true
	_show_selection()


func _clear_selection() -> void:
	_selected.clear(); _anchor = ""
	_show_selection()


## The bulk tool: every selected pony goes to `region` ("" is not spawned), then the selection clears.
func _move_to(region: String) -> void:
	if _selected.is_empty():
		_say("Select ponies first, then press a place."); return
	var ids := PackedStringArray(_selected.keys())
	if region.is_empty(): choices.call("set_not_spawned", ids)
	else: choices.call("move", ids, region)
	var many := "%d ponies" % ids.size() if ids.size() != 1 else str((_cards[ids[0]] as Button).tooltip_text)
	_say(("%s will not be spawned." % many) if region.is_empty() else ("%s now %s in %s." % [many, "lives" if ids.size() == 1 else "live", _region_names.get(region, region)]))
	_selected.clear(); _anchor = ""
	_reload()


func _apply_preset(id: String, preset_name: String) -> void:
	if bool(choices.call("apply_preset", id)):
		_selected.clear(); _anchor = ""
		_say("Preset \"%s\" applied. Undo last change puts everypony back." % preset_name)
		_reload()
	else:
		_say("Preset \"%s\" could not be applied." % preset_name)


func _save_preset() -> void:
	var wanted := _preset_name.text.strip_edges()
	if wanted.is_empty():
		var listed: Array = choices.call("presets")
		var own := 0
		for preset: Dictionary in listed:
			if not bool(preset.get("builtin", false)): own += 1
		wanted = "My ponies %d" % (own + 1)
	var id := str(choices.call("save_preset", wanted))
	_say(("Saved preset \"%s\"." % wanted) if not id.is_empty() else "The preset could not be saved.")
	_preset_name.text = ""
	_reload()


func _undo_change() -> void:
	if bool(choices.call("undo")):
		_selected.clear(); _anchor = ""
		_say("Last change undone.")
		_reload()


func _say(text: String) -> void:
	_status.text = text
	_redraw()
