extends Node
## Before he wakes (dev 2026-10-01, docs/ANONPONY_DESIGN_2026_10_01.md section 7): in the black
## before the ringing, a small panel asks "Who are you?": Anon (human), Anonmare, Anonfilly, Anoncolt
## or Anonstallion (dev 2026-10-01), then a race and eye colour for a pony. Everything else about
## AnonPony is fixed. run() answers with a form for
## world/life/player_form.gd, which world/life/arrival_story.gd stores and applies.
##
## ArrivalStory adds it with game.add_child, so it is the last child of game and its _input sees
## every key before the save and settings hotkeys (F5 to F8), the inventory, kisser and cuddle.
## While open it consumes all keys and mouse events (Escape still opens the pause menu on the
## desktop). Consumed mouse events never reach its own Controls, so it hit-tests its options
## itself. Desktop draws on its own CanvasLayer; a headset view (seated VR) gets a world-locked
## panel inside the wake's eyelid sphere, pointed at with the mouse ray.
signal chosen(form: Dictionary)
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const PANEL := preload("res://world/ui/spatial_menu_panel.gd")
## Runs that drive the game themselves answer human without showing anything (the playtest
## bridge injects real input, which the creator would eat). A pony run passes --player-form.
## A --lab fixture answers human unless it passes --player-form (labs never wait at the creator).
const AUTOMATION_ARGS := ["--playtest-bridge", "--capture", "--probe", "--perf", "--perf-stereo", "--profile-runtime", "--lab"]
const ROWS := ["kind", "race", "eyes", "opening", "confirm"]
const PONY_ROWS := ["race", "eyes"]
const ROW_TITLES := {"kind": "You are", "race": "Race", "eyes": "Eyes", "opening": "Start"}
## New game's opening choice (dev 2026-10-23: the skip must be offered on New game, not only in
## Settings). It reads and writes Settings "world/opening", which arrival_story.gd checks right
## after this panel answers, so the choice also stays the default for the next new game.
const OPENINGS := ["play", "skip"]
const OPENING_KEY := "world/opening"
## The "You are" choices: Anon is the human; the others set the form's sex and age.
const KINDS := ["anon", "anonmare", "anonfilly", "anoncolt", "anonstallion"]
const KIND_FORMS := {"anonmare": ["mare", "adult"], "anonfilly": ["mare", "young"],
	"anoncolt": ["stallion", "young"], "anonstallion": ["stallion", "adult"]}
const LABELS := {"anon": "Anon", "anonmare": "Anonmare", "anonfilly": "Anonfilly", "anoncolt": "Anoncolt",
	"anonstallion": "Anonstallion", "earth": "Earth pony", "unicorn": "Unicorn", "pegasus": "Pegasus",
	"play": "Everfree forest opening (Tutorial/controls, recommended!)", "skip": "Skip, wake in Golden Oak"}
const GOLD := Color("edd6a2")
const INK := Color("1d2330")
const TEXT := Color(0.92, 0.92, 0.88)
const MUTED := Color(0.64, 0.67, 0.72)
const WIDTH := 840.0
## Above the wake's black (121) and the loading cover (120), below the pause menu (140).
const LAYER := 125
## Headset panel: inside the wake's 0.5 m eyelid sphere (priority 110), about 0.40 m wide.
const PANEL_DISTANCE := 0.45
const PANEL_DROP := 0.05
const PANEL_SCALE := 0.32
const PANEL_PRIORITY := 115
const POINTER_PRIORITY := 116
const RECENTRE_DEGREES := 60.0
## Enter or Space held over from before the panel opened must not answer it at once.
const GRACE := 0.35
## The last answer given in this panel, the next new game's starting choice (player board #46:
## a new game started on Anonmare). Human Anon until something is saved.
const LAST_PATH := "user://creator_last.cfg"
var game: Node
var _pony := false
var _form: Dictionary = PLAYER_FORM.default_pony()
var _row := "kind"
var _hover := ""
var _open := false
var _done := false
var _elapsed := 0.0
var _headset := false
var _camera: Camera3D
var _rig: Node
var _locked_rig := false
var _saved_locked := false
var _hid_hud := false
var _saved_hud := false
var _saved_mouse := Input.MOUSE_MODE_VISIBLE
var _layer: CanvasLayer
var _panel: PANEL
var _pointer: MeshInstance3D
var _panel_forward := Vector3.ZERO
var _redraw := 0
var _row_boxes := {}     # row id -> PanelContainer behind the row
var _row_titles := {}    # row id -> Label
var _options := {}       # row id -> Array of [value, PanelContainer, Label or null for a swatch]
var _eye_name: Label
var _summary: Label
var _pony_notice: Label
var _confirm_box: PanelContainer
var _confirm_label: Label

## The player's answer: PLAYER_FORM.human() or a pony form. A valid --player-form answers without
## any UI, and so do automated and headless runs (human). {} when it cannot ask (room-scale VR,
## which plays as Anon and stores nothing).
func run(host: Node) -> Dictionary:
	game = host
	var given: Dictionary = _command_line_form()
	if not given.is_empty():
		print("[creator] command line: ", PLAYER_FORM.describe(given))
		return given
	if not is_instance_valid(game) or bool(game.get("xr_active")): return {}
	if _automated():
		print("[creator] automation: human")
		return PLAYER_FORM.human()
	_open_ui()
	var form: Dictionary = await chosen
	_close()
	print("[creator] chosen: ", PLAYER_FORM.describe(form))
	return form

static func _command_line_form() -> Dictionary:
	var args := preload("res://world/dev_tools.gd").user_args()
	for i in args.size():
		var text := ""
		if args[i] == "--player-form" and i + 1 < args.size(): text = args[i + 1]
		elif args[i].begins_with("--player-form="): text = args[i].trim_prefix("--player-form=")
		else: continue
		var form: Dictionary = PLAYER_FORM.from_arg(text)
		if not form.is_empty(): return form
		push_warning("[creator] --player-form '%s' is not human or pony:<race>,<sex>,<age>,<eyes>; asking instead" % text)
	return {}

static func _automated() -> bool:
	if DisplayServer.get_name() == "headless": return true
	var args := preload("res://world/dev_tools.gd").user_args()
	for flag: String in AUTOMATION_ARGS:
		if flag in args: return true
	return false

# ---------------------------------------------------------------- open and close
func _open_ui() -> void:
	_open = true; _done = false; _elapsed = 0.0
	_load_last()
	_rig = game.get("player")
	_camera = game._find_camera(_rig) as Camera3D if is_instance_valid(_rig) else null
	_headset = _camera is XRCamera3D
	# The world holds still and the hotbar stays hidden underneath; restored on every exit.
	if is_instance_valid(_rig) and "controls_locked" in _rig:
		_saved_locked = bool(_rig.get("controls_locked")); _rig.set("controls_locked", true); _locked_rig = true
	var inventory: Node = game.get("inventory")
	if is_instance_valid(inventory) and "hud_hidden" in inventory:
		_saved_hud = bool(inventory.get("hud_hidden")); inventory.set("hud_hidden", true); _hid_hud = true
	_saved_mouse = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _headset: _build_headset()
	else: _build_desktop()
	_refresh()

func _close() -> void:
	if not _open: return
	_open = false
	if _locked_rig and is_instance_valid(_rig): _rig.set("controls_locked", _saved_locked)
	_locked_rig = false
	var inventory: Node = game.get("inventory") if is_instance_valid(game) else null
	if _hid_hud and is_instance_valid(inventory): inventory.set("hud_hidden", _saved_hud)
	_hid_hud = false
	Input.mouse_mode = _saved_mouse
	for node: Variant in [_layer, _panel, _pointer]:
		if is_instance_valid(node): (node as Node).queue_free()
	_layer = null; _panel = null; _pointer = null

func _exit_tree() -> void:
	_close()

# ---------------------------------------------------------------- input
func _input(event: InputEvent) -> void:
	if not _open or not (event is InputEventKey or event is InputEventMouse): return
	# The pause menu (and the save or settings pages it opens) owns input while it is up.
	if _menu_open(): return
	var key := event as InputEventKey
	if key != null and not _headset and (key.keycode == KEY_ESCAPE or key.physical_keycode == KEY_ESCAPE): return
	get_viewport().set_input_as_handled()
	if _done: return
	if key != null:
		if key.pressed and not key.echo: _key(key)
		return
	var mouse := event as InputEventMouse
	if _headset: _headset_mouse(mouse)
	else: _mouse_at(mouse, mouse.position)

func _menu_open() -> bool:
	var pause: Node = get_tree().get_first_node_in_group("pause_menu")
	if pause != null and pause.get("opened") == true: return true
	if is_instance_valid(game):
		for menu: Variant in [game.get("save_menu"), game.get("settings_menu")]:
			if is_instance_valid(menu) and menu is Node and (menu as Node).get("opened") == true: return true
	return false

func _key(key: InputEventKey) -> void:
	match key.keycode:
		KEY_UP: _move_row(-1)
		KEY_DOWN: _move_row(1)
		KEY_TAB: _move_row(-1 if key.shift_pressed else 1)
		KEY_LEFT: _step_value(-1)
		KEY_RIGHT: _step_value(1)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if _elapsed >= GRACE: _confirm()

## Desktop: `point` is the window position. Headset: the pixel on the panel.
func _mouse_at(event: InputEventMouse, point: Vector2) -> void:
	var hit := _hit(point)
	var hover := "" if hit.is_empty() else "%s/%s" % hit
	if hover != _hover or (not hit.is_empty() and hit[0] != _row):
		_hover = hover
		if not hit.is_empty(): _row = hit[0]
		_refresh()
	var button := event as InputEventMouseButton
	if button == null or not button.pressed or button.button_index != MOUSE_BUTTON_LEFT or hit.is_empty(): return
	if hit[0] == "confirm": _confirm()
	else: _set_value(hit[0], hit[1])

func _headset_mouse(event: InputEventMouse) -> void:
	if not is_instance_valid(_panel) or not is_instance_valid(_camera): return
	var pixel: Vector2 = _panel.ray_to_pixel(_camera.project_ray_origin(event.position), _camera.project_ray_normal(event.position))
	_panel.point_at(pixel)
	_pointer.visible = pixel.x >= 0.0
	if _pointer.visible: _pointer.global_position = _panel.pixel_to_world(pixel)
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT: _panel.press(button.pressed)
	if pixel.x >= 0.0: _mouse_at(event, pixel)
	elif not _hover.is_empty():
		_hover = ""; _refresh()

## [row, value] of the visible option or button under `point`, else [].
func _hit(point: Vector2) -> Array:
	for row: String in _visible_rows():
		if row == "confirm":
			if is_instance_valid(_confirm_box) and _confirm_box.get_global_rect().has_point(point): return ["confirm", ""]
			continue
		for option: Array in _options.get(row, []):
			var box: Control = option[1]
			if box.is_visible_in_tree() and box.get_global_rect().has_point(point): return [row, option[0]]
	return []

# ---------------------------------------------------------------- choices
func _visible_rows() -> Array:
	return ROWS.filter(func(row: String) -> bool: return _pony or not row in PONY_ROWS)

func _values(row: String) -> Array:
	match row:
		"kind": return KINDS
		"race": return PLAYER_FORM.RACES
		"eyes": return PLAYER_FORM.EYES.map(func(eye: Array) -> String: return eye[0])
		"opening": return OPENINGS
	return []

func _value(row: String) -> String:
	if row == "kind":
		if not _pony: return "anon"
		for kind: String in KIND_FORMS:
			if KIND_FORMS[kind] == [str(_form.get("sex", "")), str(_form.get("age", ""))]: return kind
		return "anonmare"
	if row == "opening":
		var settings: Node = get_node_or_null("/root/Settings")
		var opening: String = str(settings.get_value(OPENING_KEY)) if settings != null else "play"
		return opening if opening in OPENINGS else "play"
	return str(_form.get(row, ""))

func _set_value(row: String, value: String) -> void:
	if row == "kind":
		_pony = value != "anon"
		if KIND_FORMS.has(value):
			_form["sex"] = KIND_FORMS[value][0]; _form["age"] = KIND_FORMS[value][1]
	elif row == "opening":
		var settings: Node = get_node_or_null("/root/Settings")
		if settings != null: settings.set_value(OPENING_KEY, value)
	else: _form[row] = value
	_row = row
	_refresh()

func _move_row(step: int) -> void:
	var rows := _visible_rows()
	_row = rows[wrapi(maxi(rows.find(_row), 0) + step, 0, rows.size())]
	_hover = ""
	_refresh()

func _step_value(step: int) -> void:
	var values := _values(_row)
	if values.is_empty(): return
	_set_value(_row, values[wrapi(maxi(values.find(_value(_row)), 0) + step, 0, values.size())])

func _result() -> Dictionary:
	return _form.duplicate() if _pony else PLAYER_FORM.human()

## Answered on the next idle frame, outside this input event: the story carries on from there.
func _confirm() -> void:
	if _done: return
	_done = true
	_answer.call_deferred(_result())

func _answer(form: Dictionary) -> void:
	_save_last(form)
	chosen.emit(form)

## Starts the panel on the last saved answer (normalised like a world's saved form), else human.
func _load_last() -> void:
	var file := ConfigFile.new()
	if file.load(LAST_PATH) != OK: return
	var stored: Variant = file.get_value("creator", "form", {})
	var form: Dictionary = PLAYER_FORM.saved({PLAYER_FORM.KEY: stored}) if stored is Dictionary else {}
	if form.is_empty(): return
	_pony = PLAYER_FORM.is_pony(form)
	if _pony: _form = form.duplicate()

static func _save_last(form: Dictionary) -> void:
	if not PLAYER_FORM.valid(form): return
	var file := ConfigFile.new()
	file.set_value("creator", "form", form.duplicate())
	if file.save(LAST_PATH) != OK: push_warning("[creator] could not remember the choice at " + LAST_PATH)

# ---------------------------------------------------------------- frame
func _process(delta: float) -> void:
	if not _open: return
	_elapsed += delta
	# Stay the last child of game, so a node added since cannot hear keys before this one.
	if is_instance_valid(game) and get_parent() == game and get_index() != game.get_child_count() - 1: game.move_child(self, -1)
	if not _headset or not is_instance_valid(_panel): return
	if is_instance_valid(_camera) and _camera.global_transform.is_finite():
		var forward := _flat_forward()
		if _panel_forward == Vector3.ZERO or forward.angle_to(_panel_forward) > deg_to_rad(RECENTRE_DEGREES) \
				or _camera.global_position.distance_to(_panel.global_position) > PANEL_DISTANCE * 2.0:
			_place_panel()
	# Containers lay out after a change; the panel's viewport draws on request only.
	if _redraw > 0:
		_redraw -= 1; _panel.refresh()

func _flat_forward() -> Vector3:
	var basis := _camera.global_basis.orthonormalized()
	var forward := -basis.z; forward.y = 0.0
	# Looking straight down: the top of the view points ahead.
	if forward.length() < 0.1: forward = basis.y; forward.y = 0.0
	return forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD

## World-locked in front of the eyes, level, a little low, facing the camera.
func _place_panel() -> void:
	var forward := _flat_forward()
	var at := _camera.global_position + forward * PANEL_DISTANCE + Vector3.UP * -PANEL_DROP
	_panel.global_transform = Transform3D(Basis(Vector3.UP, atan2(-forward.x, -forward.z)).scaled(Vector3.ONE * PANEL_SCALE), at)
	_panel_forward = forward

# ---------------------------------------------------------------- building
func _build_desktop() -> void:
	_layer = CanvasLayer.new(); _layer.name = "PonyCreatorLayer"; _layer.layer = LAYER
	# Drawn straight to the window, never onto the seated virtual screen.
	_layer.set_meta(&"no_virtual_screen", true)
	add_child(_layer)
	var root := Control.new(); root.set_anchors_preset(Control.PRESET_FULL_RECT); root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(root)
	_build(root)

func _build_headset() -> void:
	_panel = PANEL.new(); _panel.name = "PonyCreatorPanel"; add_child(_panel)
	_panel.display.no_depth_test = true; _panel.display.render_priority = PANEL_PRIORITY
	_build(_panel.content)
	_pointer = MeshInstance3D.new(); _pointer.name = "PonyCreatorPointer"
	var dot := SphereMesh.new(); dot.radius = 0.003; dot.height = 0.006; dot.radial_segments = 12; dot.rings = 6
	var material := StandardMaterial3D.new(); material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = GOLD; material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true; material.render_priority = POINTER_PRIORITY
	_pointer.material_override = material; _pointer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_pointer); _pointer.hide()
	if is_instance_valid(_camera) and _camera.global_transform.is_finite(): _place_panel()
	# The seated mouse dot and reticle (world/ui/headset_cursor.gd) give way to this pointer.
	var cursor: Node = get_tree().get_first_node_in_group("headset_cursor")
	if cursor != null and cursor.has_method("hide_for"): cursor.hide_for(self)

## One Control tree for both displays, centred in `root`.
func _build(root: Control) -> void:
	var box := PanelContainer.new(); box.name = "Creator"; box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.anchor_left = 0.5; box.anchor_top = 0.5; box.anchor_right = 0.5; box.anchor_bottom = 0.5
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH; box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.add_theme_stylebox_override("panel", _style(Color(0.06, 0.08, 0.1, 0.94), Color(GOLD, 0.6), 2, 10, 30.0, 24.0))
	root.add_child(box)
	var column := VBoxContainer.new(); column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.custom_minimum_size.x = WIDTH; column.add_theme_constant_override("separation", 10)
	box.add_child(column)
	column.add_child(_text("Before you wake...", 34, GOLD, true))
	column.add_child(_text("Who are you?", 24, TEXT, true))
	for row: String in ["kind", "race", "eyes", "opening"]: column.add_child(_build_row(row))
	_summary = _text("", 18, MUTED, true)
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; _summary.custom_minimum_size.x = WIDTH
	column.add_child(_summary)
	_pony_notice = _text(PLAYER_FORM.PONY_NOTICE, 20, GOLD, true)
	_pony_notice.name = "PonyNotice"
	_pony_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pony_notice.custom_minimum_size.x = WIDTH
	column.add_child(_pony_notice)
	_confirm_box = PanelContainer.new(); _confirm_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_confirm_box.custom_minimum_size.y = 56
	_confirm_label = _text("Open your eyes", 24, INK, true); _confirm_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_confirm_box.add_child(_confirm_label); column.add_child(_confirm_box)
	column.add_child(_text("Arrow keys or the mouse to choose, Enter to open your eyes", 15, MUTED, true))

func _build_row(row: String) -> Control:
	var back := PanelContainer.new(); back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row_boxes[row] = back
	var line := HBoxContainer.new(); line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_constant_override("separation", 10); back.add_child(line)
	var title := _text(ROW_TITLES[row], 20, MUTED, false)
	title.custom_minimum_size.x = 90; title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_row_titles[row] = title; line.add_child(title)
	var options: Array = []
	if row == "eyes":
		for eye: Array in PLAYER_FORM.EYES:
			var swatch := PanelContainer.new(); swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
			swatch.custom_minimum_size = Vector2(40, 40); swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			line.add_child(swatch); options.append([str(eye[0]), swatch, null])
		_eye_name = _text("", 20, TEXT, false); _eye_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		line.add_child(_eye_name)
	else:
		for value: String in _values(row):
			var option := PanelContainer.new(); option.mouse_filter = Control.MOUSE_FILTER_IGNORE
			option.custom_minimum_size.y = 44
			# Five names fit the 900 px headset panel at 18 px.
			var label := _text(str(LABELS.get(value, value)), 18 if row == "kind" else (16 if row == "opening" else 20), TEXT, true); label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			option.add_child(label); line.add_child(option); options.append([value, option, label])
	_options[row] = options
	return back

## Shows the current choices: the focused row, selected options, the hovered one, the summary.
func _refresh() -> void:
	if not _row in _visible_rows(): _row = "kind"
	for row: String in PONY_ROWS:
		if _row_boxes.has(row): (_row_boxes[row] as Control).visible = _pony
	for row: String in _row_boxes:
		var focused: bool = row == _row
		(_row_boxes[row] as PanelContainer).add_theme_stylebox_override("panel", _row_style(focused))
		(_row_titles[row] as Label).add_theme_color_override("font_color", GOLD if focused else MUTED)
	for row: String in _options:
		var current := _value(row)
		for option: Array in _options[row]:
			var value: String = option[0]
			var selected: bool = value == current
			var lit: bool = _hover == "%s/%s" % [row, value] or (selected and row == _row)
			var box: PanelContainer = option[1]
			var label: Label = option[2]
			if label == null:
				box.add_theme_stylebox_override("panel", _swatch_style(PLAYER_FORM.eye_color(value), selected, lit))
			else:
				box.add_theme_stylebox_override("panel", _option_style(selected, lit))
				label.add_theme_color_override("font_color", INK if selected else TEXT)
	if is_instance_valid(_eye_name): _eye_name.text = PLAYER_FORM.eye_label(str(_form.get("eyes", "")))
	if is_instance_valid(_confirm_box):
		_confirm_box.add_theme_stylebox_override("panel", _option_style(true, _row == "confirm" or _hover == "confirm/"))
	if is_instance_valid(_summary): _summary.text = "You are %s: %s." % [LABELS[_value("kind")], PLAYER_FORM.describe(_result())]
	if is_instance_valid(_pony_notice): _pony_notice.visible = _pony
	_redraw = 2
	if is_instance_valid(_panel): _panel.refresh()

func _text(text: String, size: int, colour: Color, centred: bool) -> Label:
	var label := Label.new(); label.text = text; label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", size); label.add_theme_color_override("font_color", colour)
	if centred: label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return label

## Explicit content margins, so a thicker highlight border never moves the layout.
func _style(fill: Color, border: Color, width: int, radius: int, margin_x: float, margin_y: float) -> StyleBoxFlat:
	var style := StyleBoxFlat.new(); style.bg_color = fill; style.border_color = border
	style.set_border_width_all(width); style.set_corner_radius_all(radius)
	style.content_margin_left = margin_x; style.content_margin_right = margin_x
	style.content_margin_top = margin_y; style.content_margin_bottom = margin_y
	return style

func _row_style(focused: bool) -> StyleBoxFlat:
	var style := _style(Color(1, 1, 1, 0.05) if focused else Color(0, 0, 0, 0), GOLD, 0, 6, 10.0, 4.0)
	if focused: style.border_width_left = 3
	return style

func _option_style(selected: bool, lit: bool) -> StyleBoxFlat:
	var fill: Color = GOLD if selected else Color(0.14, 0.18, 0.25, 0.96)
	if lit and not selected: fill = Color(0.2, 0.25, 0.34, 0.98)
	var border: Color = Color.WHITE if lit else (GOLD.darkened(0.35) if selected else Color(GOLD, 0.3))
	return _style(fill, border, 3 if lit else 1, 8, 12.0, 6.0)

func _swatch_style(colour: Color, selected: bool, lit: bool) -> StyleBoxFlat:
	var border: Color = Color.WHITE if lit else (GOLD if selected else Color(0, 0, 0, 0.45))
	# 19 on its 40-pixel circle: a radius of half its size folds the border into points.
	return _style(colour, border, 4 if lit or selected else 1, 19, 0.0, 0.0)
