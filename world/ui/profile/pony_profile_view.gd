extends "res://world/ui/spatial_menu_panel.gd"
## Relationship status and meters, using the home menu's pink, lilac and plum.
## Relationship rules stay in PlayerBonds; this view presents current facts.
signal closed
signal back
## Pay row (dev 2026-10-28): bits move only through these buttons (world/ai/bit_payments.gd).
signal pay(amount: int)
signal hire_show
const PAY_AMOUNTS := [5, 20, 50, 100]
const PLUM := Color("6b3f86")
const LILAC := Color("c06fdb")
const PINK := Color("f6a6d9")
const MIST := Color("efd2f5")
const ON_TOP_PRIORITY := 127
const STAGES := {"acquaintance":"Acquaintances", "friend":"Friends", "close_friend":"Close friends", "dating":"Dating", "engaged":"Engaged", "married":"Married"}
var heading: Label
var subline: Label
var summary: RichTextLabel
var _last_text := ""
var meters: Dictionary = {}
var purse: Label
var pay_buttons: Dictionary = {}
var hire_button: Button

func _ready() -> void:
	super._ready()
	content.theme = preload("res://world/ui/readable_text_theme.gd").make()
	display.no_depth_test = true
	display.render_priority = ON_TOP_PRIORITY
	display.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
	var bg := PanelContainer.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(bg)
	var style := _style(Color("fff7ff"), Color.WHITE)
	style.content_margin_left = 42; style.content_margin_right = 42
	style.content_margin_top = 30; style.content_margin_bottom = 28
	bg.add_theme_stylebox_override("panel", style)
	var col := VBoxContainer.new(); col.add_theme_constant_override("separation", 18); bg.add_child(col)
	heading = Label.new(); heading.add_theme_font_override("font", preload("res://world/ui/fonts/CelestiaMediumRedux.ttf"))
	heading.add_theme_font_size_override("font_size", 48); heading.add_theme_color_override("font_color", PLUM)
	heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; col.add_child(heading)
	subline = Label.new(); subline.add_theme_font_size_override("font_size", 28)
	subline.add_theme_color_override("font_color", PLUM); col.add_child(subline)
	_add_meter(col, "love", "Love", preload("res://world/ui/profile/icons/heart.svg"), Color("b73c79"))
	_add_meter(col, "friendship", "Friendship", preload("res://world/ui/profile/icons/messages-square.svg"), PLUM)
	summary = RichTextLabel.new(); summary.bbcode_enabled = true
	summary.size_flags_vertical = Control.SIZE_EXPAND_FILL
	summary.add_theme_color_override("default_color", Color("51365f"))
	for key: String in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size"]:
		summary.add_theme_font_size_override(key, 28)
	summary.add_theme_constant_override("line_separation", 5)
	col.add_child(summary)
	summary.get_v_scroll_bar().value_changed.connect(func(_value: float): refresh())
	purse = Label.new(); purse.add_theme_font_size_override("font_size", 27)
	purse.add_theme_color_override("font_color", PLUM); col.add_child(purse)
	var pay_row := HBoxContainer.new(); pay_row.add_theme_constant_override("separation", 12); col.add_child(pay_row)
	for amount: int in PAY_AMOUNTS:
		var button := _button("Pay %d" % amount, pay_row)
		button.pressed.connect(func(): pay.emit(amount))
		pay_buttons[amount] = button
	hire_button = _button("Hire a show", pay_row)
	hire_button.pressed.connect(func(): hire_show.emit())
	var buttons := HBoxContainer.new(); buttons.add_theme_constant_override("separation", 16); col.add_child(buttons)
	for caption: String in ["Another pony", "Close"]:
		var button := _button(caption, buttons)
		if caption == "Close": button.pressed.connect(func(): closed.emit())
		else: button.pressed.connect(func(): back.emit())
	hide()

func _button(caption: String, row: HBoxContainer) -> Button:
	var button := Button.new(); button.text = caption; button.custom_minimum_size.y = 64
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 30)
	button.add_theme_color_override("font_color", PLUM)
	for state: String in ["hover", "pressed", "focus"]: button.add_theme_color_override("font_" + state + "_color", PLUM)
	button.add_theme_color_override("font_disabled_color", Color(PLUM, 0.35))
	button.add_theme_stylebox_override("normal", _style(MIST, Color.WHITE))
	button.add_theme_stylebox_override("hover", _style(PINK, Color.WHITE))
	button.add_theme_stylebox_override("pressed", _style(PINK.darkened(.06), Color.WHITE))
	button.add_theme_stylebox_override("disabled", _style(Color("f3eef5"), Color.WHITE))
	button.add_theme_stylebox_override("focus", _style(Color.TRANSPARENT, LILAC))
	button.mouse_entered.connect(refresh); button.mouse_exited.connect(refresh)
	button.focus_entered.connect(refresh); button.focus_exited.connect(refresh)
	row.add_child(button)
	return button

func _add_meter(parent: VBoxContainer, key: String, caption: String, icon: Texture2D, color: Color) -> void:
	var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 16); parent.add_child(row)
	var symbol := TextureRect.new(); symbol.texture = icon; symbol.self_modulate = color
	symbol.custom_minimum_size = Vector2(44, 44); symbol.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	symbol.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED; row.add_child(symbol)
	var column := VBoxContainer.new(); column.size_flags_horizontal = Control.SIZE_EXPAND_FILL; row.add_child(column)
	var label := Label.new(); label.add_theme_font_size_override("font_size", 27)
	label.add_theme_color_override("font_color", PLUM); column.add_child(label)
	var bar := ProgressBar.new(); bar.custom_minimum_size.y = 18; bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var track := _style(Color("e8deed"), Color.TRANSPARENT); track.set_border_width_all(0)
	var fill := _style(color, Color.TRANSPARENT); fill.set_border_width_all(0)
	# Radius 28 on an 18-pixel bar: capped under half its size (world/ui/round_box.gd), or the ends fold.
	var style := preload("res://world/ui/menu_style.gd")
	bar.add_theme_stylebox_override("background", style.rounded(track)); bar.add_theme_stylebox_override("fill", style.rounded(fill))
	column.add_child(bar)
	# Level rows: how far to the next level by name, and the whole path as dots.
	var detail := Label.new(); detail.add_theme_font_size_override("font_size", 23)
	detail.add_theme_color_override("font_color", Color(PLUM, 0.8)); detail.visible = false; column.add_child(detail)
	meters[key] = {"row":row, "label":label, "bar":bar, "caption":caption, "detail":detail}

func _set_meter(key: String, value: int, description: String, enabled := true) -> void:
	var meter: Dictionary = meters[key]
	meter.row.visible = enabled
	meter.bar.value = clampi(value, 0, 100)
	meter.label.text = "%s  %d / 100 · %s" % [meter.caption, clampi(value, 0, 100), description]
	meter.detail.visible = false

## One bond_ladder.gd row: the level's name is the headline, the bar fills toward the next level
## and starts over after each level-up, and the dots show the whole path.
func _set_level(key: String, row: Dictionary, enabled := true) -> void:
	var meter: Dictionary = meters[key]
	meter.row.visible = enabled and not row.is_empty()
	if row.is_empty(): return
	var names: Array = row.names
	var level := int(row.level)
	meter.bar.value = roundf(float(row.fill) * 100.0)
	if level < 0: meter.label.text = "%s  ·  %s" % [meter.caption, str(row.name)]
	else: meter.label.text = "%s  ·  %s  ·  level %d of %d" % [meter.caption, str(row.name), level + 1, names.size()]
	var dots := PackedStringArray()
	for i in names.size(): dots.append("●" if i <= level else "○")
	var waiting := str(row.waiting)
	var unit := (" " + str(row.unit)) if row.has("unit") else ""
	var line := "%d / %d%s to %s" % [int(row.have), int(row.need), unit, str(row.next)]
	if bool(row.max): line = "Highest level"
	elif not waiting.is_empty() and (float(row.fill) >= 1.0 or int(row.need) <= 1):
		line = waiting if waiting.contains(str(row.next)) else "%s → %s" % [waiting, str(row.next)]
	elif not waiting.is_empty(): line += " · " + waiting
	meter.detail.text = line + "      " + " ".join(dots)
	meter.detail.visible = true

static func _style(fill: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new(); style.bg_color = fill; style.border_color = border
	style.set_border_width_all(3); style.set_corner_radius_all(28)
	return style

static func _plain(value: Variant) -> String:
	return str(value).replace("[", "[lb]")

func show_profile(id: String, identity: Resource, info: Dictionary) -> void:
	var title: String = identity.display_name if identity else id.replace("_", " ").capitalize()
	var bond: Dictionary = info.bond
	var impression: Dictionary = info.impression
	var stage: String = STAGES.get(str(bond.stage), "Unknown")
	var love := clampi(int(impression.get("love", 0)), 0, 100)
	var friendship := clampi(int(impression.get("friendship", 0)), 0, 100)
	var romance_visible: bool = bool(info.get("romance_available", identity != null and not identity.filly))
	var love_label := str(impression.get("love_label", "Neutral"))
	# Keep the score tier, but avoid implying a partnership from attraction alone.
	love_label = {"Soulmate":"In love", "Strong Romantic Interest":"Strong interest"}.get(love_label, love_label)
	var standing := str(impression.get("standing", "Neutral"))
	var lines := PackedStringArray()
	var thought := str(info.get("thought", "")).strip_edges()
	lines.append("[b]Trust[/b]  %d / 100    [b]Familiarity[/b]  %d / 100" % [roundi(float(bond.get("trust", 0))), roundi(float(bond.get("familiarity", 0)))])
	if romance_visible and str(bond.stage) in ["acquaintance", "friend", "close_friend"]:
		lines.append("Love measures romantic interest. You are not dating.")
	if not thought.is_empty(): lines.append("[b]Last impression[/b]  " + _plain(thought))
	var mood := str(impression.get("mood", "neutral"))
	if mood != "neutral": lines.append("[b]Mood[/b]  " + _plain(mood.capitalize()))
	# M-AI-15: Hostility is her forgiving grudge (pony_impressions.gd grudge) or her negative
	# friendship, whichever is higher (a mare hostile in an older save has no grudge row yet).
	var hostility := maxi(int(impression.get("hostility", 0)), int(impression.get("enemy", 0)))
	if hostility > 0:
		lines.append("[b]Hostility[/b]  %d / 100 · %s" % [hostility, _plain(standing)])
	if not str(impression.get("heard", "")).is_empty():
		lines.append("[b]Heard about you[/b]  " + _plain(str(impression.heard)))
	if bool(info.get("space", false)):
		lines.append("[b]Boundary[/b]  " + _plain(title) + " has asked for space.")
	elif not str(info.get("welcome", "")).is_empty():
		lines.append("[b]Comfortable with[/b]  " + _plain(info.welcome))
	for spec: Array in [["invitation", "Pending invitation"], ["plan", "Plan"]]:
		var text := str(info.get(spec[0], ""))
		if not text.is_empty(): lines.append("[b]" + spec[1] + "[/b]\n" + _plain(text))
	if not str(bond.get("shared_home_id", "")).is_empty(): lines.append("[b]Living arrangement[/b]  Shared home")
	var memories: Array = info.get("memories", [])
	if not memories.is_empty():
		lines.append("[b]Recent activities[/b]")
		for memory: String in memories:
			var text := memory.replace("You and Anon completed conversation together.", "You talked together.")
			if text.begins_with("You and Anon "): text = "You and " + title + text.trim_prefix("You and Anon")
			elif text == "You asked Anon for space; physical affection is currently unwelcome.":
				text = title + " asked for space; physical affection is currently unwelcome."
			elif text == "Your romantic relationship with Anon ended. Do not assume continued romantic permission.":
				text = "Your romantic relationship with " + title + " ended."
			lines.append("• " + _plain(text))
	var body := "\n\n".join(lines)
	var purse_bits := int(info.get("purse", 0)); var player_bits := int(info.get("player_bits", 0))
	var show_price := int(info.get("show_price", 0)); var show_ready := bool(info.get("show_ready", false))
	var next_text := JSON.stringify([id, title, stage, body, love, friendship, love_label, standing, romance_visible, purse_bits, player_bits, show_price, show_ready, info.get("ladder", {})])
	if next_text == _last_text: return
	_last_text = next_text
	var changed_pony := heading.text != title
	heading.text = title; subline.text = "Relationship: " + stage; summary.text = body
	var ladder: Dictionary = info.get("ladder", {})
	if ladder.is_empty():
		_set_meter("love", love, love_label, romance_visible)
		_set_meter("friendship", friendship, standing)
	else:
		_set_level("love", ladder.get("love", {}), romance_visible)
		_set_level("friendship", ladder.get("friendship", {}))
	purse.text = "%s's purse: %d bits    Yours: %d bits" % [title, purse_bits, player_bits]
	for amount: int in pay_buttons: (pay_buttons[amount] as Button).disabled = player_bits < amount
	hire_button.visible = show_price > 0
	hire_button.text = "Hire a show · %d" % show_price
	hire_button.disabled = not show_ready or player_bits < show_price
	if changed_pony: summary.scroll_to_line(0)
	refresh()

func scroll_key(code: Key) -> bool:
	var bar := summary.get_v_scroll_bar()
	match code:
		KEY_PAGEUP: bar.value -= bar.page
		KEY_PAGEDOWN: bar.value += bar.page
		KEY_HOME: bar.value = bar.min_value
		KEY_END: bar.value = bar.max_value
		_: return false
	return true

func scroll_wheel(event: InputEventMouseButton, pixel: Vector2) -> void:
	if not summary.get_global_rect().has_point(pixel): return
	var forwarded := event.duplicate() as InputEventMouseButton
	forwarded.position = pixel
	forwarded.global_position = pixel
	viewport.push_input(forwarded, true)
	refresh()
