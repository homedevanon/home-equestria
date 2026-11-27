extends CanvasLayer
## Desktop control card: the stack of controls in the bottom right corner. First made for the bridal
## carry (the row under the crosshair sat where her subtitles go); since 2026-11-20 every desktop
## control hint uses it (interaction_hints.gd, desktop_interactions.gd).
## One card per game, found with shared(). Each user owns a named section: an optional small title
## and rows [keys, "tap" | "hold" | "release" | "", action]. keys is one key name ("G"), several
## (["Shift", "Q"]) or "" for a line of plain words.

const CURRENCY := preload("res://world/ui/currency.gd")
const PATH := "res://world/ui/control_card.gd"
const GROUP := "control_card"
const INK := Color("f4f1ff")
const SHADE := Color("1a1624")
const MUTED := Color(0.957, 0.945, 1.0, 0.6)
const MARGIN := 28.0
const FADE_SECONDS := .15

class Section:
	var box: VBoxContainer
	var title: Label
	var grid: GridContainer
	var shown: Array = []

var _stack: VBoxContainer
var _sections: Dictionary = {}


## The game's one card; made under `from` when there is none yet.
static func shared(from: Node) -> CanvasLayer:
	var found: Node = from.get_tree().get_first_node_in_group(GROUP)
	if found is CanvasLayer and not found.is_queued_for_deletion(): return found as CanvasLayer
	var card: CanvasLayer = (load(PATH) as GDScript).new()
	from.add_child(card)
	return card


func _ready() -> void:
	layer = 5
	add_to_group(GROUP)
	var card := PanelContainer.new()
	# No backing: outlined words over the world, like the prompt row.
	card.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(card)
	# Pinned to the corner, growing left and up as rows come and go.
	card.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	card.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	card.grow_vertical = Control.GROW_DIRECTION_BEGIN
	card.offset_left = -MARGIN; card.offset_right = -MARGIN
	card.offset_top = -MARGIN; card.offset_bottom = -MARGIN
	_stack = VBoxContainer.new()
	_stack.add_theme_constant_override("separation", 18)
	_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(_stack)


## Call every tick while the section may show: fades it in or out and rebuilds only on a change.
func section(key: String, on: bool, title: String, rows: Array, delta: float) -> void:
	var part: Section = _sections.get(key) as Section
	if part == null:
		if not on: return
		part = _make(key)
	if on:
		if part.title.text != title:
			part.title.text = title; part.title.visible = not title.is_empty()
		if rows != part.shown: _build(part, rows)
	part.box.modulate.a = move_toward(part.box.modulate.a, 1.0 if on else 0.0, delta / FADE_SECONDS)
	part.box.visible = part.box.modulate.a > 0.0


func _make(key: String) -> Section:
	var part := Section.new()
	part.box = VBoxContainer.new()
	part.box.name = key.capitalize().replace(" ", "")
	part.box.add_theme_constant_override("separation", 8)
	part.box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	part.box.modulate.a = 0.0
	part.box.visible = false
	_stack.add_child(part.box)
	part.title = _label("", 14, MUTED, 5)
	part.title.visible = false
	part.box.add_child(part.title)
	part.grid = GridContainer.new()
	part.grid.add_theme_constant_override("h_separation", 10)
	part.grid.add_theme_constant_override("v_separation", 7)
	part.grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	part.box.add_child(part.grid)
	_sections[key] = part
	return part


func _build(part: Section, rows: Array) -> void:
	part.shown = rows.duplicate(true)
	for child: Node in part.grid.get_children():
		part.grid.remove_child(child); child.queue_free()
	# The tap/hold column exists only when a row uses it, so plain rows keep key and words together.
	var modes := false
	for row: Array in rows:
		if not str(row[1]).is_empty(): modes = true
	part.grid.columns = 3 if modes else 2
	for row: Array in rows:
		var keys := HBoxContainer.new()
		keys.add_theme_constant_override("separation", 4)
		keys.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var names: Array = row[0] if row[0] is Array else ([] if str(row[0]).is_empty() else [str(row[0])])
		for key: Variant in names: keys.add_child(_keycap(str(key)))
		part.grid.add_child(keys)
		if modes:
			var mode := _label(str(row[1]), 15, MUTED, 5)
			mode.custom_minimum_size.x = 38.0
			mode.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			mode.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			part.grid.add_child(mode)
		var action := _label(str(row[2]), 21, INK, 6)
		CURRENCY.apply(action)
		action.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		action.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		part.grid.add_child(action)


## A light keycap with the key in dark ink, like the prompt icons.
func _keycap(key: String) -> Control:
	var cap := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = INK
	style.border_color = SHADE
	style.set_border_width_all(2)
	style.border_width_bottom = 4
	style.set_corner_radius_all(7)
	style.content_margin_left = 9.0; style.content_margin_right = 9.0
	style.content_margin_top = 2.0; style.content_margin_bottom = 2.0
	cap.add_theme_stylebox_override("panel", style)
	cap.custom_minimum_size = Vector2(36, 34)
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var text := _label(key, 19, SHADE, 0)
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cap.add_child(text)
	return cap


func _label(text: String, size: int, colour: Color, outline: int) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	if outline > 0:
		label.add_theme_color_override("font_outline_color", SHADE)
		label.add_theme_constant_override("outline_size", outline)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
