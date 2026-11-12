extends RefCounted
## The menus' one look (dev 2026-10-27: "redesign everything in a cool, design, charming and
## whimsical way, without it being forced or too much"): a twilight card (world/ui/menu_card.gd)
## under cream text, the title's pink and lilac on everything that can be pressed, Celestia for
## headings and Atkinson Hyperlegible for everything that is read. Pages set
## `theme = MENU_STYLE.theme()`; type variations name the few special looks:
##   Label: Heading, Subheading, Muted, Faint, Warn
##   Button: Primary, Danger, Ghost, Tab, Chip, Card, Key, Round, Choice, Segment, Drop, Float
## Nothing here moves on its own; world/ui/menu_fx.gd adds the flourishes.
const HEADING := preload("res://world/ui/fonts/CelestiaMediumRedux.ttf")
const REGULAR := preload("res://world/books/fonts/AtkinsonHyperlegible-Regular.ttf")
const BOLD := preload("res://world/books/fonts/AtkinsonHyperlegible-Bold.ttf")
const ITALIC := preload("res://world/books/fonts/AtkinsonHyperlegible-Italic.ttf")
const ROUND_BOX := preload("res://world/ui/round_box.gd")

const INK := Color("1d1230")
const DUSK := Color("33204e")
const CREAM := Color("fff5fb")
const MUTED := Color("cdb9de")
const FAINT := Color("9a86ae")
const PINK := Color("f6a6d9")
const ROSE := Color("ec6fb8")
const LILAC := Color("c06fdb")
const VIOLET := Color("8e5bd6")
const MINT := Color("8fe3c3")
const SKY := Color("8ccbf2")
const BUTTER := Color("ffe08a")
const CORAL := Color("ff8f9a")
const PEACH := Color("ffc28a")
const PERIWINKLE := Color("b3a6ff")
## Colours a world folder or a tag can wear.
const SWATCHES := [PINK, LILAC, SKY, MINT, BUTTER, PEACH, CORAL, PERIWINKLE]

static var _theme: Theme
static var _icons: Dictionary = {}


static func theme() -> Theme:
	if _theme != null: return _theme
	var t := Theme.new()
	t.default_font = REGULAR
	t.default_font_size = 20
	# ---- text
	t.set_color("font_color", "Label", CREAM)
	t.set_constant("outline_size", "Label", 0)
	t.set_constant("shadow_outline_size", "Label", 0)
	t.set_color("font_shadow_color", "Label", Color.TRANSPARENT)
	_variation(t, "Heading", "Label")
	t.set_font("font", "Heading", HEADING)
	t.set_font_size("font_size", "Heading", 34)
	t.set_color("font_color", "Heading", PINK)
	t.set_color("font_shadow_color", "Heading", Color(0.05, 0.0, 0.1, 0.55))
	t.set_constant("shadow_offset_x", "Heading", 0)
	t.set_constant("shadow_offset_y", "Heading", 2)
	_variation(t, "Subheading", "Label")
	t.set_font("font", "Subheading", BOLD)
	t.set_font_size("font_size", "Subheading", 22)
	t.set_color("font_color", "Subheading", Color("f6d8ff"))
	for item: Array in [["Muted", MUTED, 17], ["Faint", FAINT, 16], ["Warn", CORAL, 18]]:
		_variation(t, item[0], "Label")
		t.set_color("font_color", item[0], item[1])
		t.set_font_size("font_size", item[0], item[2])
	t.set_color("default_color", "RichTextLabel", CREAM)
	t.set_font("normal_font", "RichTextLabel", REGULAR)
	t.set_font("bold_font", "RichTextLabel", BOLD)
	t.set_font("italics_font", "RichTextLabel", ITALIC)
	t.set_font("bold_italics_font", "RichTextLabel", BOLD)
	# ---- buttons
	t.set_font("font", "Button", BOLD)
	t.set_font_size("font_size", "Button", 20)
	_button_colors(t, "Button", CREAM, Color.WHITE)
	t.set_constant("h_separation", "Button", 10)
	t.set_constant("icon_max_width", "Button", 0)
	_button_styles(t, "Button", {
		"normal": box(Color(1, 1, 1, 0.07), Color(1, 1, 1, 0.12), 1, 14),
		"hover": box(Color(PINK, 0.2), Color(PINK, 0.85), 2, 14),
		"pressed": box(Color(LILAC, 0.5), Color(PINK, 0.95), 2, 14),
		"hover_pressed": box(Color(LILAC, 0.6), Color.WHITE, 2, 14),
		"disabled": box(Color(1, 1, 1, 0.03), Color(1, 1, 1, 0.06), 1, 14),
		"focus": _focus(14)})
	_variation(t, "Primary", "Button")
	t.set_font("font", "Primary", HEADING)
	t.set_font_size("font_size", "Primary", 24)
	_button_colors(t, "Primary", Color.WHITE, Color.WHITE)
	_button_styles(t, "Primary", {
		"normal": _shadowed(box(ROSE, Color(1, 1, 1, 0.6), 2, 18)),
		"hover": _shadowed(box(PINK.lerp(ROSE, 0.35), Color.WHITE, 3, 18)),
		"pressed": box(LILAC, Color.WHITE, 3, 18),
		"hover_pressed": box(LILAC, Color.WHITE, 3, 18),
		"disabled": box(Color(ROSE, 0.3), Color(1, 1, 1, 0.2), 2, 18),
		"focus": _focus(18)})
	_variation(t, "Danger", "Button")
	_button_colors(t, "Danger", Color("ffd9de"), Color.WHITE)
	_button_styles(t, "Danger", {
		"normal": box(Color(CORAL, 0.12), Color(CORAL, 0.45), 1, 14),
		"hover": box(Color(CORAL, 0.32), CORAL, 2, 14),
		"pressed": box(Color(CORAL, 0.55), Color.WHITE, 2, 14),
		"hover_pressed": box(Color(CORAL, 0.55), Color.WHITE, 2, 14),
		"disabled": box(Color(CORAL, 0.04), Color(CORAL, 0.12), 1, 14),
		"focus": _focus(14)})
	_variation(t, "Ghost", "Button")
	_button_colors(t, "Ghost", MUTED, CREAM)
	_button_styles(t, "Ghost", {
		"normal": box(Color.TRANSPARENT, Color.TRANSPARENT, 0, 12),
		"hover": box(Color(1, 1, 1, 0.08), Color.TRANSPARENT, 0, 12),
		"pressed": box(Color(PINK, 0.18), Color.TRANSPARENT, 0, 12),
		"hover_pressed": box(Color(PINK, 0.24), Color.TRANSPARENT, 0, 12),
		"disabled": box(Color.TRANSPARENT, Color.TRANSPARENT, 0, 12),
		"focus": _focus(12)})
	_variation(t, "Tab", "Button")
	_button_colors(t, "Tab", MUTED, Color.WHITE)
	t.set_color("font_hover_color", "Tab", CREAM)
	t.set_color("icon_normal_color", "Tab", FAINT)
	t.set_color("icon_hover_color", "Tab", PINK)
	t.set_color("icon_pressed_color", "Tab", PINK)
	t.set_color("icon_hover_pressed_color", "Tab", PINK)
	t.set_constant("h_separation", "Tab", 12)
	_button_styles(t, "Tab", {
		"normal": box(Color.TRANSPARENT, Color.TRANSPARENT, 0, 12, 14, 7),
		"hover": box(Color(1, 1, 1, 0.07), Color.TRANSPARENT, 0, 12, 14, 7),
		"pressed": _accent_left(box(Color(PINK, 0.17), Color(PINK, 0.4), 1, 12, 14, 7)),
		"hover_pressed": _accent_left(box(Color(PINK, 0.24), Color(PINK, 0.6), 1, 12, 14, 7)),
		"disabled": box(Color.TRANSPARENT, Color.TRANSPARENT, 0, 12, 14, 7),
		"focus": _focus(12)})
	_variation(t, "Chip", "Button")
	t.set_font_size("font_size", "Chip", 16)
	_button_colors(t, "Chip", MUTED, Color.WHITE)
	t.set_constant("h_separation", "Chip", 6)
	_button_styles(t, "Chip", {
		"normal": box(Color(1, 1, 1, 0.07), Color(1, 1, 1, 0.14), 1, 99, 12, 4),
		"hover": box(Color(1, 1, 1, 0.14), Color(PINK, 0.7), 1, 99, 12, 4),
		"pressed": box(Color(PINK, 0.3), PINK, 1, 99, 12, 4),
		"hover_pressed": box(Color(PINK, 0.4), Color.WHITE, 1, 99, 12, 4),
		"disabled": box(Color(1, 1, 1, 0.03), Color(1, 1, 1, 0.06), 1, 99, 12, 4),
		"focus": _focus(99)})
	_variation(t, "Card", "Button")
	_button_colors(t, "Card", CREAM, Color.WHITE)
	_button_styles(t, "Card", {
		"normal": box(Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.1), 1, 18, 0, 0),
		"hover": box(Color(PINK, 0.12), Color(PINK, 0.85), 2, 18, 0, 0),
		"pressed": box(Color(LILAC, 0.28), Color.WHITE, 2, 18, 0, 0),
		"hover_pressed": box(Color(LILAC, 0.34), Color.WHITE, 2, 18, 0, 0),
		"disabled": box(Color(1, 1, 1, 0.03), Color(1, 1, 1, 0.06), 1, 18, 0, 0),
		"focus": _focus(18)})
	_variation(t, "Key", "Button")
	t.set_font_size("font_size", "Key", 18)
	_button_colors(t, "Key", CREAM, Color.WHITE)
	var key := box(Color(1, 1, 1, 0.1), Color(0.05, 0.0, 0.1, 0.55), 1, 10, 14, 5)
	key.border_width_bottom = 4
	var key_hover := box(Color(PINK, 0.26), Color(PINK, 0.9), 1, 10, 14, 5)
	key_hover.border_width_bottom = 4
	var key_down := box(Color(LILAC, 0.5), Color.WHITE, 1, 10, 14, 5)
	key_down.border_width_bottom = 1; key_down.content_margin_top = 8
	_button_styles(t, "Key", {"normal": key, "hover": key_hover, "pressed": key_down, "hover_pressed": key_down,
		"disabled": box(Color(1, 1, 1, 0.04), Color(1, 1, 1, 0.08), 1, 10, 14, 5), "focus": _focus(10)})
	_variation(t, "Round", "Button")
	t.set_font_size("font_size", "Round", 20)
	_button_colors(t, "Round", CREAM, Color.WHITE)
	_button_styles(t, "Round", {
		"normal": box(Color(1, 1, 1, 0.08), Color(1, 1, 1, 0.12), 1, 99, 4, 4),
		"hover": box(Color(PINK, 0.32), PINK, 2, 99, 4, 4),
		"pressed": box(LILAC, Color.WHITE, 2, 99, 4, 4),
		"hover_pressed": box(LILAC, Color.WHITE, 2, 99, 4, 4),
		"disabled": box(Color(1, 1, 1, 0.02), Color(1, 1, 1, 0.05), 1, 99, 4, 4),
		"focus": _focus(99)})
	# A row that is pressed to step through choices (AI settings): caption left, value right.
	_variation(t, "Choice", "Button")
	_button_colors(t, "Choice", CREAM, Color.WHITE)
	_button_styles(t, "Choice", {
		"normal": box(Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.09), 1, 14, 16, 8),
		"hover": box(Color(PINK, 0.14), Color(PINK, 0.8), 2, 14, 16, 8),
		"pressed": box(Color(LILAC, 0.36), Color.WHITE, 2, 14, 16, 8),
		"hover_pressed": box(Color(LILAC, 0.36), Color.WHITE, 2, 14, 16, 8),
		"disabled": box(Color(1, 1, 1, 0.02), Color(1, 1, 1, 0.05), 1, 14, 16, 8),
		"focus": _focus(14)})
	# A choice among a few (settings rows): every value side by side in a track, the chosen one lit.
	_variation(t, "Segment", "Button")
	t.set_font_size("font_size", "Segment", 17)
	_button_colors(t, "Segment", MUTED, Color.WHITE)
	_button_styles(t, "Segment", {
		"normal": box(Color.TRANSPARENT, Color.TRANSPARENT, 0, 99, 14, 5),
		"hover": box(Color(1, 1, 1, 0.1), Color(PINK, 0.5), 1, 99, 14, 5),
		"pressed": _shadowed(box(ROSE, Color(1, 1, 1, 0.55), 1, 99, 14, 5)),
		"hover_pressed": _shadowed(box(ROSE.lightened(0.08), Color.WHITE, 1, 99, 14, 5)),
		"disabled": box(Color.TRANSPARENT, Color.TRANSPARENT, 0, 99, 14, 5),
		"focus": _focus(99)})
	# A dropdown's face: the chosen value and a chevron; its list unfolds under the row.
	_variation(t, "Drop", "Button")
	t.set_font_size("font_size", "Drop", 18)
	_button_colors(t, "Drop", CREAM, Color.WHITE)
	_button_styles(t, "Drop", {
		"normal": box(Color(0.05, 0.02, 0.09, 0.35), Color(1, 1, 1, 0.16), 1, 12, 14, 6),
		"hover": box(Color(PINK, 0.16), Color(PINK, 0.85), 1, 12, 14, 6),
		"pressed": box(Color(LILAC, 0.3), PINK, 1, 12, 14, 6),
		"hover_pressed": box(Color(LILAC, 0.36), Color.WHITE, 1, 12, 14, 6),
		"disabled": box(Color(1, 1, 1, 0.02), Color(1, 1, 1, 0.05), 1, 12, 14, 6),
		"focus": _focus(12)})
	# A chip standing on the world itself (the map's "Saved games" button), not on a card: solid
	# dusk, so it reads over bright scenery. Its radius is just under half its height (about 29
	# pixels): a larger one is clamped by Godot, and a bright rim then doubles into a dot at each
	# end.
	_variation(t, "Float", "Button")
	t.set_font_size("font_size", "Float", 15)
	_button_colors(t, "Float", CREAM, Color.WHITE)
	t.set_constant("h_separation", "Float", 7)
	_button_styles(t, "Float", {
		"normal": box(Color(DUSK, 0.92), Color(LILAC, 0.6), 1, 13, 12, 5),
		"hover": box(Color(DUSK.lerp(ROSE, 0.35), 0.95), PINK, 1, 13, 12, 5),
		"pressed": box(LILAC, Color.WHITE, 1, 13, 12, 5),
		"hover_pressed": box(LILAC, Color.WHITE, 1, 13, 12, 5),
		"disabled": box(Color(DUSK, 0.6), Color(1, 1, 1, 0.1), 1, 13, 12, 5),
		"focus": _focus(13)})
	# ---- toggles
	for type_name: String in ["CheckBox", "CheckButton"]:
		_button_colors(t, type_name, CREAM, Color.WHITE)
		t.set_constant("h_separation", type_name, 12)
		_button_styles(t, type_name, {
			"normal": box(Color.TRANSPARENT, Color.TRANSPARENT, 0, 12, 8, 6),
			"hover": box(Color(1, 1, 1, 0.06), Color.TRANSPARENT, 0, 12, 8, 6),
			"pressed": box(Color.TRANSPARENT, Color.TRANSPARENT, 0, 12, 8, 6),
			"hover_pressed": box(Color(1, 1, 1, 0.06), Color.TRANSPARENT, 0, 12, 8, 6),
			"disabled": box(Color.TRANSPARENT, Color.TRANSPARENT, 0, 12, 8, 6),
			"focus": _focus(12)})
	t.set_icon("checked", "CheckBox", icon("check_on"))
	t.set_icon("unchecked", "CheckBox", icon("check_off"))
	t.set_icon("checked_disabled", "CheckBox", icon("check_on"))
	t.set_icon("unchecked_disabled", "CheckBox", icon("check_off"))
	t.set_icon("radio_checked", "CheckBox", icon("radio_on"))
	t.set_icon("radio_unchecked", "CheckBox", icon("radio_off"))
	for state: String in ["checked", "checked_disabled", "checked_mirrored", "checked_disabled_mirrored"]:
		t.set_icon(state, "CheckButton", icon("switch_on"))
	for state: String in ["unchecked", "unchecked_disabled", "unchecked_mirrored", "unchecked_disabled_mirrored"]:
		t.set_icon(state, "CheckButton", icon("switch_off"))
	# ---- picking from lists
	_button_colors(t, "OptionButton", CREAM, Color.WHITE)
	_button_styles(t, "OptionButton", {
		"normal": box(Color(1, 1, 1, 0.07), Color(1, 1, 1, 0.14), 1, 14),
		"hover": box(Color(PINK, 0.2), Color(PINK, 0.85), 2, 14),
		"pressed": box(Color(LILAC, 0.5), PINK, 2, 14),
		"disabled": box(Color(1, 1, 1, 0.03), Color(1, 1, 1, 0.06), 1, 14),
		"focus": _focus(14)})
	t.set_icon("arrow", "OptionButton", icon("chevron_down"))
	t.set_constant("arrow_margin", "OptionButton", 14)
	var popup := box(DUSK, Color(PINK, 0.5), 2, 14, 8, 8)
	t.set_stylebox("panel", "PopupMenu", rounded(popup))
	t.set_stylebox("hover", "PopupMenu", rounded(box(Color(PINK, 0.26), Color.TRANSPARENT, 0, 10)))
	t.set_color("font_color", "PopupMenu", CREAM)
	t.set_color("font_hover_color", "PopupMenu", Color.WHITE)
	t.set_font("font", "PopupMenu", REGULAR)
	t.set_constant("v_separation", "PopupMenu", 10)
	t.set_stylebox("panel", "TooltipPanel", rounded(box(DUSK, Color(PINK, 0.6), 2, 10, 12, 8)))
	t.set_color("font_color", "TooltipLabel", CREAM)
	t.set_font_size("font_size", "TooltipLabel", 17)
	var well := box(Color(0.05, 0.02, 0.09, 0.5), Color(1, 1, 1, 0.1), 1, 14, 8, 8)
	t.set_stylebox("panel", "ItemList", rounded(well))
	t.set_stylebox("focus", "ItemList", rounded(box(Color.TRANSPARENT, Color(PINK, 0.65), 2, 14)))
	t.set_stylebox("selected", "ItemList", rounded(box(Color(PINK, 0.26), Color.TRANSPARENT, 0, 10)))
	t.set_stylebox("selected_focus", "ItemList", rounded(box(Color(PINK, 0.32), Color.TRANSPARENT, 0, 10)))
	t.set_stylebox("hovered", "ItemList", rounded(box(Color(1, 1, 1, 0.07), Color.TRANSPARENT, 0, 10)))
	t.set_stylebox("hovered_selected", "ItemList", rounded(box(Color(PINK, 0.36), Color.TRANSPARENT, 0, 10)))
	t.set_stylebox("cursor", "ItemList", rounded(StyleBoxEmpty.new()))
	t.set_stylebox("cursor_unfocused", "ItemList", rounded(StyleBoxEmpty.new()))
	t.set_color("font_color", "ItemList", CREAM)
	t.set_color("font_selected_color", "ItemList", Color.WHITE)
	t.set_color("font_hovered_color", "ItemList", Color.WHITE)
	t.set_color("guide_color", "ItemList", Color.TRANSPARENT)
	t.set_constant("v_separation", "ItemList", 8)
	t.set_constant("h_separation", "ItemList", 10)
	# ---- typing
	for type_name: String in ["LineEdit", "TextEdit"]:
		t.set_stylebox("normal", type_name, rounded(box(Color(0.05, 0.02, 0.09, 0.55), Color(1, 1, 1, 0.16), 1, 12, 14, 8)))
		t.set_stylebox("focus", type_name, rounded(box(Color.TRANSPARENT, PINK, 2, 12)))
		t.set_stylebox("read_only", type_name, rounded(box(Color(0.05, 0.02, 0.09, 0.35), Color(1, 1, 1, 0.08), 1, 12, 14, 8)))
		t.set_color("font_color", type_name, CREAM)
		t.set_color("font_readonly_color", type_name, MUTED)
		t.set_color("font_selected_color", type_name, Color.WHITE)
		t.set_color("selection_color", type_name, Color(LILAC, 0.55))
		t.set_color("caret_color", type_name, PINK)
		t.set_color("font_placeholder_color", type_name, Color(MUTED, 0.5))
	t.set_color("clear_button_color", "LineEdit", MUTED)
	t.set_color("background_color", "TextEdit", Color.TRANSPARENT)
	t.set_icon("updown", "SpinBox", icon("updown"))
	# ---- containers
	t.set_stylebox("panel", "ScrollContainer", rounded(StyleBoxEmpty.new()))
	t.set_stylebox("panel", "PanelContainer", rounded(box(Color(1, 1, 1, 0.04), Color(1, 1, 1, 0.08), 1, 16, 14, 12)))
	t.set_stylebox("panel", "Panel", rounded(box(Color(1, 1, 1, 0.04), Color(1, 1, 1, 0.08), 1, 16)))
	var line := StyleBoxLine.new(); line.color = Color(1, 1, 1, 0.12); line.thickness = 1
	t.set_stylebox("separator", "HSeparator", rounded(line))
	t.set_constant("separation", "HSeparator", 14)
	for bar: String in ["VScrollBar", "HScrollBar"]:
		var track := box(Color(1, 1, 1, 0.05), Color.TRANSPARENT, 0, 6, 5, 5)
		t.set_stylebox("scroll", bar, rounded(track))
		t.set_stylebox("scroll_focus", bar, rounded(track))
		t.set_stylebox("grabber", bar, rounded(box(Color(LILAC, 0.75), Color.TRANSPARENT, 0, 6, 5, 5)))
		t.set_stylebox("grabber_highlight", bar, rounded(box(PINK, Color.TRANSPARENT, 0, 6, 5, 5)))
		t.set_stylebox("grabber_pressed", bar, rounded(box(ROSE, Color.TRANSPARENT, 0, 6, 5, 5)))
	t.set_stylebox("background", "ProgressBar", rounded(box(Color(1, 1, 1, 0.08), Color.TRANSPARENT, 0, 99, 0, 3)))
	t.set_stylebox("fill", "ProgressBar", rounded(box(PINK, Color.TRANSPARENT, 0, 99, 0, 3)))
	t.set_stylebox("slider", "HSlider", rounded(box(Color(1, 1, 1, 0.12), Color.TRANSPARENT, 0, 99, 0, 3)))
	t.set_stylebox("grabber_area", "HSlider", rounded(box(PINK, Color.TRANSPARENT, 0, 99, 0, 3)))
	t.set_stylebox("grabber_area_highlight", "HSlider", rounded(box(PINK, Color.TRANSPARENT, 0, 99, 0, 3)))
	t.set_icon("grabber", "HSlider", icon("knob"))
	t.set_icon("grabber_highlight", "HSlider", icon("knob"))
	_theme = t
	return t


static func _variation(t: Theme, name: String, base: String) -> void:
	t.set_type_variation(name, base)


static func _button_colors(t: Theme, type_name: String, normal: Color, bright: Color) -> void:
	t.set_color("font_color", type_name, normal)
	t.set_color("font_focus_color", type_name, normal)
	for state: String in ["font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		t.set_color(state, type_name, bright)
	t.set_color("font_disabled_color", type_name, Color(normal, 0.38))
	t.set_color("icon_normal_color", type_name, normal)
	t.set_color("icon_focus_color", type_name, normal)
	for state: String in ["icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color"]:
		t.set_color(state, type_name, bright)
	t.set_color("icon_disabled_color", type_name, Color(normal, 0.38))


static func _button_styles(t: Theme, type_name: String, styles: Dictionary) -> void:
	for state: String in styles: t.set_stylebox(state, type_name, rounded(styles[state]))


## `style` drawn with its corners capped at half its size less a pixel (world/ui/round_box.gd), so
## pills and circles (radius 99) do not show bright points where Godot clamps them. Every style
## of the theme goes through it; round overrides elsewhere use it too.
static func rounded(style: StyleBox) -> StyleBox:
	return ROUND_BOX.new(style) if style is StyleBoxFlat else style


## A rounded box: fill, border and its width, corner radius, then inner margins.
static func box(bg: Color, border := Color.TRANSPARENT, width := 0, radius := 14, margin_x := 16, margin_y := 8) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(radius)
	style.corner_detail = 10
	style.anti_aliasing_size = 0.8
	style.content_margin_left = margin_x; style.content_margin_right = margin_x
	style.content_margin_top = margin_y; style.content_margin_bottom = margin_y
	return style


static func _focus(radius: int) -> StyleBoxFlat:
	var style := box(Color.TRANSPARENT, Color(PINK, 0.8), 2, radius + 2)
	style.set_expand_margin_all(2)
	return style


static func _shadowed(style: StyleBoxFlat) -> StyleBoxFlat:
	style.shadow_color = Color(ROSE, 0.35); style.shadow_size = 10; style.shadow_offset = Vector2(0, 2)
	return style


static func _accent_left(style: StyleBoxFlat) -> StyleBoxFlat:
	style.border_width_left = 4; style.border_color = PINK
	return style


## Whether flourishes stay still (Settings → Accessibility → Reduced motion).
static func still() -> bool:
	var loop := Engine.get_main_loop() as SceneTree
	var settings: Node = loop.root.get_node_or_null("Settings") if loop != null else null
	return settings != null and bool(settings.get_value("access/reduced_motion"))


## Desktop menus are laid out for the game's 1600 x 900 window and grow with a bigger one (dev
## 2026-10-27: "make some screens take more place to be more visible"): window pixels per layout
## pixel, so a card keeps its share of the window and its words their size on screen.
const LAYOUT_WINDOW := Vector2(1600, 900)
static func window_scale(window: Vector2) -> float:
	return clampf(minf(window.x / LAYOUT_WINDOW.x, window.y / LAYOUT_WINDOW.y), 0.75, 3.0)


## A card as big as `most` (layout pixels) where the window has room, `margin` clear around it.
static func fit_card(window: Vector2, most: Vector2, margin := Vector2(40, 30)) -> Vector2:
	var room := window / window_scale(window) - margin * 2.0
	return Vector2(minf(most.x, room.x), minf(most.y, room.y)).floor()


## Fonts on `viewport` rasterize `scale` times finer, so a menu scaled up on it keeps sharp words;
## 1 puts them back.
static func sharpen(viewport: Viewport, scale: float) -> void:
	if viewport != null: viewport.oversampling_override = 0.0 if is_equal_approx(scale, 1.0) else scale


## Shows `source` in `rect` resized once with Lanczos to the screen pixels it covers (kept to
## its aspect), and again whenever `rect` changes size: a big picture shown small (the 918-pixel
## logo at 160 in the pause menu) is jagged with plain filtering and soft from mipmaps. A host
## that scales an ancestor (the pause menu with the window) calls refit_picture() after.
static func sharp_picture(rect: TextureRect, source: Texture2D) -> void:
	rect.texture = source
	var refit := func() -> void:
		if not rect.is_inside_tree(): return
		var scale := rect.get_global_transform_with_canvas().get_scale() * rect.get_viewport().get_final_transform().get_scale()
		var room := rect.size * scale.abs()
		var source_size := Vector2(source.get_size())
		var fit := minf(room.x / source_size.x, room.y / source_size.y)
		if fit <= 0.0 or fit >= 1.0:
			rect.texture = source; rect.remove_meta(&"sharp_pixels"); return
		var pixels := Vector2i((source_size * fit).round())
		if pixels.x < 2 or pixels.y < 2 or rect.get_meta(&"sharp_pixels", Vector2i.ZERO) == pixels: return
		rect.set_meta(&"sharp_pixels", pixels)
		var image := source.get_image()
		if image == null: return
		if image.is_compressed(): image.decompress()
		image.resize(pixels.x, pixels.y, Image.INTERPOLATE_LANCZOS)
		rect.texture = ImageTexture.create_from_image(image)
	rect.set_meta(&"sharp_refit", refit)
	rect.resized.connect(refit)
	# Deferred through the rect itself: a deferred call on a freed object is dropped silently,
	# whereas the lambda errored "Lambda capture at index 0 was freed" when the picture was freed
	# in the same frame (W1-TEST-BASELINES).
	Callable(rect, &"emit_signal").bind(&"resized").call_deferred()


## Fits a sharp_picture() again, once the layout has settled: after its scale on screen changed
## without its own size changing.
static func refit_picture(rect: TextureRect) -> void:
	if rect != null and rect.has_meta(&"sharp_refit"): (rect.get_meta(&"sharp_refit") as Callable).call_deferred()


## A deterministic swatch for a word (tags without a chosen colour).
static func swatch_for(word: String) -> Color:
	return SWATCHES[absi(word.to_lower().hash()) % SWATCHES.size()]


static func label(text: String, variation := "", size := 0) -> Label:
	var node := Label.new()
	node.text = text
	node.theme_type_variation = variation
	if size > 0: node.add_theme_font_size_override("font_size", size)
	return node


# ------------------------------------------------------------------ small drawn textures
## Theme pictures drawn once from distance fields: toggles, ticks, chevrons, the slider knob.
static func icon(kind: String) -> Texture2D:
	if _icons.has(kind): return _icons[kind]
	var image: Image
	match kind:
		"switch_on", "switch_off":
			var on := kind == "switch_on"
			image = _draw_image(Vector2i(50, 28), func(p: Vector2) -> Array:
				return [[_sd_box(p, Vector2(25, 14), Vector2(24, 13), 13), ROSE if on else Color(1, 1, 1, 0.16)],
					[(p - Vector2(36 if on else 14, 14)).length() - 9.5, Color.WHITE if on else Color(MUTED, 0.9)]])
		"check_on", "check_off":
			var on := kind == "check_on"
			image = _draw_image(Vector2i(28, 28), func(p: Vector2) -> Array:
				var square := _sd_box(p, Vector2(14, 14), Vector2(12, 12), 7)
				if not on: return [[absf(square + 1.0) - 1.0, Color(MUTED, 0.75)]]
				return [[square, ROSE], [_sd_segment(p, Vector2(8, 14.5), Vector2(12.2, 18.5)) - 1.6, Color.WHITE],
					[_sd_segment(p, Vector2(12.2, 18.5), Vector2(20, 9.5)) - 1.6, Color.WHITE]])
		"radio_on", "radio_off":
			var on := kind == "radio_on"
			image = _draw_image(Vector2i(28, 28), func(p: Vector2) -> Array:
				var ring := (p - Vector2(14, 14)).length() - 12.0
				if not on: return [[absf(ring + 1.0) - 1.0, Color(MUTED, 0.75)]]
				return [[ring, ROSE], [(p - Vector2(14, 14)).length() - 5.0, Color.WHITE]])
		"chevron_down":
			image = _draw_image(Vector2i(20, 20), func(p: Vector2) -> Array:
				return [[minf(_sd_segment(p, Vector2(5, 8), Vector2(10, 13)), _sd_segment(p, Vector2(10, 13), Vector2(15, 8))) - 1.4, MUTED]])
		"updown":
			image = _draw_image(Vector2i(20, 30), func(p: Vector2) -> Array:
				var up := minf(_sd_segment(p, Vector2(5, 11), Vector2(10, 6)), _sd_segment(p, Vector2(10, 6), Vector2(15, 11)))
				var down := minf(_sd_segment(p, Vector2(5, 19), Vector2(10, 24)), _sd_segment(p, Vector2(10, 24), Vector2(15, 19)))
				return [[minf(up, down) - 1.4, MUTED]])
		"knob":
			image = _draw_image(Vector2i(26, 26), func(p: Vector2) -> Array:
				return [[(p - Vector2(13, 13)).length() - 11.0, PINK], [(p - Vector2(13, 13)).length() - 7.5, Color.WHITE]])
	var texture := ImageTexture.create_from_image(image)
	_icons[kind] = texture
	return texture


## Layers of [signed distance in pixels, colour], painted over one another, antialiased.
static func _draw_image(size: Vector2i, layers_at: Callable) -> Image:
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	for y in size.y:
		for x in size.x:
			var out := Color(0, 0, 0, 0)
			for layer: Array in layers_at.call(Vector2(x + 0.5, y + 0.5)):
				var cover := clampf(0.5 - float(layer[0]), 0.0, 1.0)
				var color: Color = layer[1]
				var a := color.a * cover
				if a <= 0.0: continue
				var total := a + out.a * (1.0 - a)
				out = Color((color.r * a + out.r * out.a * (1.0 - a)) / total, (color.g * a + out.g * out.a * (1.0 - a)) / total,
					(color.b * a + out.b * out.a * (1.0 - a)) / total, total)
			image.set_pixel(x, y, out)
	return image


static func _sd_box(p: Vector2, centre: Vector2, half: Vector2, radius: float) -> float:
	var q := (p - centre).abs() - half + Vector2(radius, radius)
	return Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - radius


static func _sd_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var pa := p - a
	var ba := b - a
	var h := clampf(pa.dot(ba) / ba.dot(ba), 0.0, 1.0)
	return (pa - ba * h).length()
