extends Button
## One pony's big selection box in "Who lives where" (world/ui/population/population_window.gd):
## her picture, a small round photo of her in-game model when one was baked, her name and a
## coloured tag with where she lives (grey "Not spawned"). Pressing it selects her; the window
## does the moving. A plain Button, so the mouse, the focus keys, a gamepad and a VR ray on a
## spatial panel all reach it. Pictures come from world/ui/population/pictures.gd.

const STYLE := preload("res://world/ui/menu_style.gd")
const ICON := preload("res://world/ui/menu_icon.gd")
const SIZE := Vector2(176, 244)
const NOT_SPAWNED_TINT := Color(0.62, 0.6, 0.66)
const LOCK_GOLD := Color("ffe08a")

var pony_id := ""
var locked := false
var selected := false
var _picture: Texture2D
var _photo: Texture2D
var _name: Label
var _tag: PanelContainer
var _tag_text: Label


func setup(pony: Dictionary, picture: Texture2D, photo: Texture2D) -> void:
	pony_id = str(pony.get("id", ""))
	locked = bool(pony.get("locked", false))
	_picture = picture; _photo = photo
	theme_type_variation = "Card"
	custom_minimum_size = SIZE
	clip_contents = true
	tooltip_text = str(pony.get("name", pony_id))
	_name = Label.new(); _name.name = "Name"
	_name.add_theme_font_override("font", STYLE.BOLD)
	_name.add_theme_font_size_override("font_size", 17)
	_name.add_theme_constant_override("line_spacing", -3)
	_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; _name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; _name.max_lines_visible = 2
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS; _name.clip_text = true
	_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name.position = Vector2(8, 156); _name.size = Vector2(160, 44)
	_name.text = str(pony.get("name", pony_id))
	add_child(_name)
	_tag = PanelContainer.new(); _tag.name = "Tag"; _tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_tag)
	_tag_text = Label.new(); _tag_text.add_theme_font_override("font", STYLE.BOLD)
	_tag_text.add_theme_font_size_override("font_size", 14)
	_tag_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tag_text.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS; _tag_text.clip_text = true
	_tag_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tag.add_child(_tag_text)
	show_place(pony)


## The tag under her name: her region's name in its colour, or grey "Not spawned".
func show_place(pony: Dictionary, region_name := "") -> void:
	var region := str(pony.get("region", ""))
	var off := bool(pony.get("not_spawned", false)) or region.is_empty()
	var tint := NOT_SPAWNED_TINT if off else STYLE.swatch_for(region)
	var text := "Not spawned" if off else (region_name if not region_name.is_empty() else region.replace("_", " ").capitalize())
	_tag_text.text = text
	_tag_text.add_theme_color_override("font_color", tint.lerp(Color.WHITE, 0.55))
	_tag.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(tint, 0.26), Color(tint, 0.85), 1, 99, 10, 2)))
	var font: Font = STYLE.BOLD
	var width := minf(font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x + 24.0, 160.0)
	_tag.custom_minimum_size = Vector2(width, 24)
	_tag.size = _tag.custom_minimum_size
	_tag.position = Vector2((SIZE.x - width) * 0.5, 208)


func set_selected(value: bool) -> void:
	if value == selected: return
	selected = value
	if selected:
		for state: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
			var lit := STYLE.box(Color(STYLE.PINK, 0.2 if state == "normal" else 0.28), Color.WHITE if state.begins_with("hover") else STYLE.PINK, 4, 18, 0, 0)
			if state == "focus": lit = STYLE.box(Color.TRANSPARENT, Color.WHITE, 2, 20, 0, 0)
			add_theme_stylebox_override(state, STYLE.rounded(lit))
	else:
		for state: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]: remove_theme_stylebox_override(state)
	queue_redraw()


func _draw() -> void:
	var area := Rect2(Vector2(12, 12), Vector2(152, 140))
	if _picture != null:
		var fit := _picture.get_size()
		if fit.x > 0.0 and fit.y > 0.0:
			var k := minf(area.size.x / fit.x, area.size.y / fit.y)
			var shown := fit * k
			# Drawn with rounded corners: a baked photo is a square with its own pale background.
			var box := Rect2(area.position + (area.size - shown) * 0.5, shown)
			var round := 18.0
			var points := PackedVector2Array(); var uvs := PackedVector2Array()
			for corner in 4:
				var mid := Vector2(box.end.x - round if corner in [0, 1] else box.position.x + round, box.end.y - round if corner in [1, 2] else box.position.y + round)
				for step in 7:
					var angle := (corner - 1) * PI * 0.5 + step * PI / 12.0
					var point := mid + Vector2(cos(angle), sin(angle)) * round
					points.append(point); uvs.append((point - box.position) / box.size)
			draw_colored_polygon(points, Color.WHITE, uvs, _picture)
	if _photo != null:
		var centre := Vector2(SIZE.x - 34, 126)
		var radius := 28.0
		draw_circle(centre, radius + 3.0, STYLE.INK)
		var points := PackedVector2Array(); var uvs := PackedVector2Array()
		for i in 40:
			var angle := TAU * i / 40.0
			var along := Vector2(cos(angle), sin(angle))
			points.append(centre + along * radius); uvs.append(Vector2(0.5, 0.5) + along * 0.5)
		draw_colored_polygon(points, Color.WHITE, uvs, _photo)
		draw_arc(centre, radius + 1.5, 0.0, TAU, 40, Color(STYLE.CREAM, 0.85), 2.0, true)
	if selected:
		var spot := Vector2(30, 30)
		draw_circle(spot, 15.0, STYLE.ROSE)
		draw_arc(spot, 15.0, 0.0, TAU, 32, Color.WHITE, 2.0, true)
		ICON.paint(get_canvas_item(), Rect2(spot - Vector2(9, 9), Vector2(18, 18)), "check", Color.WHITE, 2.5)
	if locked:
		# A small padlock: she stays where she is in this version.
		var at := Vector2(SIZE.x - 32, 16)
		draw_circle(at + Vector2(10, 12), 16.0, Color(STYLE.INK, 0.85))
		draw_arc(at + Vector2(10, 9), 5.5, PI, TAU, 16, LOCK_GOLD, 2.5, true)
		draw_rect(Rect2(at + Vector2(3, 9), Vector2(14, 11)), LOCK_GOLD)
		draw_circle(at + Vector2(10, 14), 1.8, STYLE.INK)
