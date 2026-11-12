extends Node
## Desktop Escape menu. Escape opens it when nothing else took the key (menus, chat, the
## map and the inspector close themselves on Escape in _input and mark it handled; this
## listens in _unhandled_input). While open the whole world pauses (player bug board #15: ponies,
## AI, physics, sounds and the clock stop); this menu, the saves panel and the save writer run
## on (PROCESS_MODE_ALWAYS). The player cannot move and the mouse is free.
## VR keeps its left-menu-button settings panel, which offers the same quit actions.
##
## Look (dev 2026-10-27 menu redesign, world/ui/menu_style.gd): the world blurs softly behind a
## storybook column on the left (the logo, where and when the player is, the actions); settings,
## the journal (world/ui/journal_page.gd), support and credits open on menu cards in the middle.

const TITLE_SCENE := "res://world/ui/title_screen.tscn"
const LOG_BUNDLE := "res://world/debug/log_bundle.gd"
const VERSION := "res://world/debug/version.gd"
const DESKTOP_OWNER := preload("res://player/desktop_action_owner.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const VIEW := preload("res://world/player_view.gd")
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const STYLE := preload("res://world/ui/menu_style.gd")
const ICON := preload("res://world/ui/menu_icon.gd")
const CARD := preload("res://world/ui/menu_card.gd")
const FX := preload("res://world/ui/menu_fx.gd")
const UPDATER := preload("res://world/update/updater.gd")
const CATALOGUE := preload("res://world/saves/save_catalogue.gd")
const SHELF := preload("res://world/saves/save_shelf.gd")
const LOGO := preload("res://world/ui/title/logo.png")
const SEASON_NAMES := ["Spring", "Summer", "Autumn", "Winter"]   # weather.gd SEASONS order
## The world behind the menu, softly out of focus and dusk-tinted towards the edges.
const BACKDROP := """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float blur = 2.6;
uniform vec4 tint : source_color = vec4(0.13, 0.06, 0.21, 1.0);
void fragment() {
	vec3 c = textureLod(screen_tex, SCREEN_UV, blur).rgb;
	float edge = smoothstep(0.25, 0.95, distance(SCREEN_UV, vec2(0.62, 0.5)));
	float left = 1.0 - smoothstep(0.0, 0.45, SCREEN_UV.x);
	COLOR = vec4(mix(c, tint.rgb, 0.28 + 0.4 * edge + 0.25 * left), 1.0);
}
"""
## The largest cards in layout pixels (menu_style.gd fit_card): a smaller window gets smaller
## ones, and the whole layer scales up with a bigger window.
const SETTINGS_SIZE := Vector2(1280, 840)
const CREDITS_SIZE := Vector2(1000, 840)
## The storybook column's place on the left.
const COLUMN_LEFT := 56.0
const COLUMN_WIDTH := 430.0

var game: Node
var ui: Node                # briefcase inventory (hands, map, inspector)
var save_menu: Node
var settings_menu: Node
var player_body: Node
var opened := false
var canvas: CanvasLayer
var _root: Control
var _pages: Dictionary = {}  # name -> Control
var _credits: Control
var _journal: Control
var _page := ""
var _settings: Control
var _support_status: Label
var _pony_notice: Label
var _world_name: Label
var _when: Label
var _where: Label
var _column: Control
var _logo: TextureRect
var _old_lock := false
var _mouse_mode: int = Input.MOUSE_MODE_VISIBLE
var _input_states: Dictionary = {}
var _in_save_menu := false
## Auto-pause (dev 2026-10-26): ten real minutes without any key, mouse or pad input opens this
## menu, so an unattended world stops instead of running on. Sleeping and talking by voice count as
## being there; real time, so sleep's fast-forward does not shorten it.
const IDLE_PAUSE_SECONDS := 600.0
var _last_input_msec := 0


func setup(host: Node, inventory_ui: Node, saves_panel: Node, settings_panel: Node, body: Node) -> void:
	game = host; ui = inventory_ui; save_menu = saves_panel; settings_menu = settings_panel; player_body = body
	_last_input_msec = Time.get_ticks_msec()
	add_to_group("pause_menu")
	if ui == null or not ui._desktop: return
	canvas = CanvasLayer.new(); canvas.layer = 140; add_child(canvas); canvas.hide()
	var root := Control.new(); _root = root
	root.theme = STYLE.theme(); root.mouse_filter = Control.MOUSE_FILTER_IGNORE; canvas.add_child(root)
	root.size = _screen()
	var shade := ColorRect.new(); shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var blur := ShaderMaterial.new(); blur.shader = Shader.new(); blur.shader.code = BACKDROP
	shade.material = blur; root.add_child(shade)
	_build_main(root)
	var version := Label.new(); version.text = "Home: Equestria " + str((load(VERSION) as Script).call("text")) if ResourceLoader.exists(VERSION) else ""
	version.theme_type_variation = "Faint"; version.add_theme_font_size_override("font_size", 14)
	version.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 14)
	version.grow_horizontal = Control.GROW_DIRECTION_BEGIN; version.grow_vertical = Control.GROW_DIRECTION_BEGIN
	root.add_child(version)
	_build_settings(root)
	_build_support(root)
	_credits = preload("res://world/ui/credits_page.gd").new()
	var credits_size := STYLE.fit_card(_screen(), CREDITS_SIZE)
	_card(root, "credits", credits_size).add_child(_credits)
	_credits.setup(credits_size - Vector2(60, 56), 22)
	_credits.back_requested.connect(_show.bind("main"))
	_journal = preload("res://world/ui/journal_page.gd").new()
	var journal_size := STYLE.fit_card(_screen(), SETTINGS_SIZE)
	_card(root, "journal", journal_size).add_child(_journal)
	_journal.setup(null); _journal.relayout(journal_size - Vector2(60, 56))
	_journal.closed.connect(_show.bind("main"))
	var fx := FX.new(); root.add_child(fx); fx.attach(root)
	# A window resized while the menu shows: it fits the new one at once.
	get_viewport().size_changed.connect(func() -> void: if opened and canvas.visible: _fit())


## A centred menu card of the given size on the pause layer; returns the box inside it.
func _card(root: Control, page_name: String, card_size: Vector2) -> Control:
	var centre := CenterContainer.new(); centre.name = page_name
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); root.add_child(centre); centre.hide()
	var holder := Control.new(); holder.custom_minimum_size = card_size; centre.add_child(holder)
	var card := CARD.new(); card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); holder.add_child(card)
	var inner := MarginContainer.new(); inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right"]: inner.add_theme_constant_override("margin_" + side, 30)
	for side: String in ["top", "bottom"]: inner.add_theme_constant_override("margin_" + side, 28)
	holder.add_child(inner)
	_pages[page_name] = centre
	return inner


## The storybook column: the logo, where and when the player is, then what can be done.
func _build_main(root: Control) -> void:
	var page := Control.new(); page.name = "main"; page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.mouse_filter = Control.MOUSE_FILTER_IGNORE; root.add_child(page); page.hide()
	_pages["main"] = page
	_column = Control.new(); page.add_child(_column)
	_column.anchor_bottom = 1.0; _column.offset_left = COLUMN_LEFT; _column.offset_top = 36; _column.offset_bottom = -36
	_column.offset_right = COLUMN_LEFT + COLUMN_WIDTH
	var card := CARD.new(); card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); _column.add_child(card)
	var box := VBoxContainer.new(); box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 40; box.offset_right = -40; box.offset_top = 30; box.offset_bottom = -30
	box.add_theme_constant_override("separation", 6); _column.add_child(box)
	_logo = TextureRect.new(); _logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED; _logo.custom_minimum_size.y = 160
	# Resized to the pixels it covers: 918 pixels drawn at 160 come out jagged.
	STYLE.sharp_picture(_logo, LOGO)
	box.add_child(_logo)
	var paused := STYLE.label("PAUSED", "Faint", 14); paused.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(paused)
	_world_name = STYLE.label("", "Heading", 30); _world_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_world_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS; box.add_child(_world_name)
	_when = STYLE.label("", "Subheading", 19); _when.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; box.add_child(_when)
	_where = STYLE.label("", "Muted", 16); _where.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_where.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; box.add_child(_where)
	box.add_child(HSeparator.new())
	for entry in [["Continue", close, "play", "Primary"], ["Save game", _open_saves, "save", ""], ["Load game", _open_saves, "folder", ""],
			["Journal", _show.bind("journal"), "book", ""], ["Settings", _show.bind("settings"), "gear", ""], ["AI Settings", _open_provider, "chat", ""],
			["Credits", _show.bind("credits"), "heart", ""], ["Support", _show.bind("support"), "lifebuoy", ""], ["", Callable(), "", ""],
			["Quit to title", quit_to_title, "home", "Ghost"], ["Quit game", quit_game, "moon", "Ghost"]]:
		if str(entry[0]).is_empty():
			var gap := Control.new(); gap.custom_minimum_size.y = 4; gap.size_flags_vertical = Control.SIZE_EXPAND_FILL; box.add_child(gap)
			continue
		var b := Button.new(); b.name = str(entry[0]).replace(" ", "").replace("&", ""); b.text = entry[0]
		b.theme_type_variation = str(entry[3]); b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.icon = ICON.texture(str(entry[2]), 22)
		b.custom_minimum_size = Vector2(0, 50 if str(entry[3]) == "Primary" else 41)
		b.add_theme_font_size_override("font_size", 24 if str(entry[3]) == "Primary" else 20)
		b.pressed.connect(entry[1]); box.add_child(b)
	_pony_notice = STYLE.label(PLAYER_FORM.PONY_NOTICE, "Muted", 15); _pony_notice.name = "PonyNotice"
	_pony_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pony_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pony_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pony_notice.hide(); box.add_child(_pony_notice)
	# Signed in-place updates (dev 2026-10-28): which version this is, and an update button when a
	# newer one is out (world/update/updater.gd, shared with the title and Settings > Updates).
	UPDATER.shared(self).attach(box, quit_game)


## Where and when the player is, for the column's heading.
func _describe_here() -> void:
	var world := str(game.get("context_world_id")) if is_instance_valid(game) else ""
	var saves: Node = save_menu.saves if is_instance_valid(save_menu) else null
	var folder := str(saves.directory).get_base_dir() if saves != null and str(saves.directory) != "" else ""
	var look := SHELF.world_look(world, SHELF.read(folder) if folder != "" else {})
	_world_name.text = str(look.name) if str(look.name) != "" else CATALOGUE.world_name(world)
	_world_name.add_theme_color_override("font_color", (STYLE.SWATCHES[int(look.color) % STYLE.SWATCHES.size()] as Color).lerp(Color.WHITE, 0.2))
	var hours := clampf(float(TimeOfDay.hours), 0.0, 23.99)
	# The one season formula, F1 offset included (world/seasons/season_state.gd, M-SEA-04).
	var seasons: Node = get_tree().get_first_node_in_group("season_state")
	var season_index: int = int(seasons.call("season_index")) if seasons != null else preload("res://world/seasons/season_state.gd").index_for(int(TimeOfDay.day), int(Settings.season_days()))
	var season: String = SEASON_NAMES[season_index % SEASON_NAMES.size()]
	_when.text = "Day %d · %02d:%02d · %s" % [int(TimeOfDay.day) + 1, int(hours), int((hours - int(hours)) * 60.0), season]
	_where.text = str(saves.place_now()) if saves != null and saves.has_method("place_now") else ""
	_where.visible = not _where.text.is_empty()
	# Small windows: a smaller logo keeps every button on screen.
	var tall := _root.size.y
	_logo.custom_minimum_size.y = clampf(tall * 0.125, 70.0, 150.0)
	_logo.visible = tall >= 600.0


func _build_settings(root: Control) -> void:
	var card_size := STYLE.fit_card(_screen(), SETTINGS_SIZE)
	var inner := _card(root, "settings", card_size)
	_settings = preload("res://world/ui/settings_page.gd").new()
	inner.add_child(_settings)
	_settings.setup(card_size - Vector2(60, 56), 20, "Back")
	_settings.back_requested.connect(_show.bind("main"))


## The layer at layout pixels over the whole window, scaled up to fill it, and the cards as big
## as the window allows (on every opening: the window may have changed size).
func _fit() -> void:
	var window := _screen()
	var scale := STYLE.window_scale(window)
	_root.scale = Vector2.ONE * scale; _root.size = (window / scale).ceil()
	STYLE.sharpen(get_viewport(), scale)
	# The logo's pixels follow its size on screen, which this scale changes.
	STYLE.refit_picture(_logo)
	for item: Array in [["settings", SETTINGS_SIZE, _settings], ["credits", CREDITS_SIZE, _credits], ["journal", SETTINGS_SIZE, _journal]]:
		var card_size := STYLE.fit_card(window, item[1])
		var holder: Control = (_pages[item[0]] as Control).get_child(0)
		if holder.custom_minimum_size == card_size: continue
		holder.custom_minimum_size = card_size
		var page: Control = item[2]
		if page.has_method("relayout"): page.relayout(card_size - Vector2(60, 56))
		else: page.custom_minimum_size = card_size - Vector2(60, 56); page.size = page.custom_minimum_size


func _screen() -> Vector2:
	return Vector2(1600, 900) if get_viewport() == null else get_viewport().get_visible_rect().size


func _build_support(root: Control) -> void:
	var inner := _card(root, "support", Vector2(700, 590))
	var box := VBoxContainer.new(); box.add_theme_constant_override("separation", 12); inner.add_child(box)
	var head := HBoxContainer.new(); head.add_theme_constant_override("separation", 10); box.add_child(head)
	var mark := ICON.make("lifebuoy", 34, STYLE.PINK); mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER; head.add_child(mark)
	head.add_child(STYLE.label("Support", "Heading", 36))
	var note := STYLE.label("Stuck in a wall or a tree? Get unstuck takes you to the nearest front door. Something went wrong? Make a logs bundle and attach the zip to your report. It holds the game logs and your settings, never your API key.", "Muted", 18)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; note.custom_minimum_size.x = 620
	box.add_child(note)
	for entry in [["Get unstuck", _unstuck, "home", ""], ["Copy logs bundle", _make_bundle, "archive", ""], ["Open support folder" if OS.has_feature("android") else "Open logs folder", _open_logs, "folder", ""],
			["Debug: Trixie show tomorrow", _book_trixie_show, "sparkle", ""], ["Back", _show.bind("main"), "back", "Ghost"]]:
		var b := Button.new(); b.text = entry[0]; b.custom_minimum_size.y = 48; b.add_theme_font_size_override("font_size", 20)
		b.icon = ICON.texture(str(entry[2]), 22); b.alignment = HORIZONTAL_ALIGNMENT_LEFT; b.theme_type_variation = str(entry[3])
		b.pressed.connect(entry[1]); box.add_child(b)
	_support_status = STYLE.label("", "Muted", 17); _support_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_support_status.custom_minimum_size.x = 620; box.add_child(_support_status)


## Player bug board #37: out of a wall, a tree or a roof, to the nearest front door.
func _unstuck() -> void:
	_support_status.text = preload("res://player/unstuck.gd").run(game)


## Debug: book a Trixie stage show for the next game day at 17:00 (world/events/trixie_show/).
func _book_trixie_show() -> void:
	var runtime: Node = game.get_node_or_null("TrixieShow") if is_instance_valid(game) else null
	_support_status.text = runtime.force_next_day() if runtime != null else "Trixie's shows are not loaded in this world."


## provider_settings.gd calls this on its surface after every change (a SubViewport
## panel needs a redraw; a CanvasLayer does not).
func refresh() -> void:
	pass


# ------------------------------------------------------------------ open / close
func _input(event: InputEvent) -> void:
	if event is InputEventKey or event is InputEventMouse or event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_last_input_msec = Time.get_ticks_msec()

func _check_idle() -> void:
	if canvas == null or opened or _in_save_menu or _other_menu_open(): _last_input_msec = Time.get_ticks_msec(); return
	var sleeper: Node = get_tree().get_first_node_in_group("player_sleep")
	var director: Node = get_tree().get_first_node_in_group("conversation_director")
	var speech: Variant = director.get("speech") if director != null else null
	if (sleeper != null and bool(sleeper.get("sleeping"))) or (speech != null and str(speech.get("state")) == "hearing"):
		_last_input_msec = Time.get_ticks_msec(); return
	# Held keys and mouse motion another node consumed before _input still count.
	if Input.is_anything_pressed() or Input.get_last_mouse_velocity().length_squared() > 1.0: _last_input_msec = Time.get_ticks_msec(); return
	if Time.get_ticks_msec() - _last_input_msec >= int(IDLE_PAUSE_SECONDS * 1000.0): open()

func _unhandled_input(event: InputEvent) -> void:
	if canvas == null or not (event is InputEventKey) or not event.pressed or event.echo: return
	if (event as InputEventKey).physical_keycode != KEY_ESCAPE: return
	if _in_save_menu: return
	if not opened:
		if _other_menu_open(): return
		open()
	elif _page == "main": close()
	elif _page == "settings" and not _settings.capturing.is_empty(): return
	elif _page == "journal": _journal.back()
	else: _show("main")
	get_viewport().set_input_as_handled()


func _other_menu_open() -> bool:
	for menu in [save_menu, settings_menu]:
		if menu != null and menu.opened: return true
	if ui != null and (ui.customizer.opened or ui.case.visible): return true
	return false


func open() -> void:
	if opened or canvas == null: return
	if ui != null and ui._desktop: DESKTOP_OWNER.cancel_current(ui)
	# Before the menu draws: saves made while paused (and the quit save) show this frame.
	var saves := _saves()
	if saves != null: saves.remember_view(self)
	opened = true
	TimeOfDay.hold("pause_menu")
	_pause_world(true)
	_old_lock = player_body.controls_locked; player_body.controls_locked = true
	_mouse_mode = Input.mouse_mode; Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Hotkeys of the other menus stay quiet while paused (F6/F7/I/J/M/T…).
	for node in [ui, ui.inspector if ui != null else null, ui.map_menu if ui != null else null, save_menu, settings_menu,
			game.get("world_map") if game != null else null]:
		if not is_instance_valid(node) or _input_states.has(node): continue
		_input_states[node] = node.is_processing_input(); node.set_process_input(false)
	Settings.message = ""
	_fit()
	canvas.show()
	_show("main")


func close() -> void:
	if not opened: return
	opened = false
	canvas.hide(); _page = ""
	STYLE.sharpen(get_viewport(), 1.0)
	_settings.capturing = ""
	for node in _input_states:
		if is_instance_valid(node): node.set_process_input(_input_states[node])
	_input_states.clear()
	TimeOfDay.release("pause_menu")
	_pause_world(false)
	_menu_sound("prop_ui_back")
	player_body.controls_locked = _old_lock
	Input.mouse_mode = _mouse_mode
	var saves := _saves()
	if saves != null: saves.release_view(self)


## Pauses the SceneTree; the menus and the save writer keep running.
func _pause_world(paused: bool) -> void:
	for node: Variant in [self, save_menu, _saves()]:
		if is_instance_valid(node): (node as Node).process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().paused = paused


## A load or quit replaces the scene; the next world must not start paused.
func _exit_tree() -> void:
	if opened: get_tree().paused = false
	# Loading a save from this menu reloads the scene without close(): let go of the clock here.
	TimeOfDay.release("pause_menu")


func _show(page_name: String) -> void:
	var changed: bool = _page != page_name
	for key in _pages: (_pages[key] as Control).visible = key == page_name
	_page = page_name
	if page_name == "main":
		_describe_here()
		if is_instance_valid(_pony_notice): _pony_notice.visible = PLAYER_FORM.is_pony(PLAYER_FORM.active(get_tree()))
	if page_name == "settings": _settings.refresh()
	# The journal opens on the world being played; it chooses its own focus.
	if page_name == "journal" and changed: _journal.open(str(game.get("context_world_id")) if is_instance_valid(game) else "")
	var first: Control = _settings.first_focus() if page_name == "settings" else _first_button(_pages[page_name])
	if first != null and page_name != "journal": first.grab_focus()
	if changed:
		_menu_sound("prop_ui_confirm")
		_appear(_pages[page_name], page_name == "main")


## Pages drift in: the column from the left, cards up from below.
func _appear(page: Control, from_left: bool) -> void:
	if STYLE.still(): return
	var target: Control = _column if from_left else page
	page.modulate.a = 0.0
	var tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(page, "modulate:a", 1.0, 0.22)
	if from_left:
		target.offset_left = COLUMN_LEFT - 40.0; target.offset_right = COLUMN_LEFT + COLUMN_WIDTH - 40.0
		tween.parallel().tween_property(target, "offset_left", COLUMN_LEFT, 0.3)
		tween.parallel().tween_property(target, "offset_right", COLUMN_LEFT + COLUMN_WIDTH, 0.3)


func _menu_sound(event: String) -> void:
	# The sound mixer pauses with the world; a click queued now would play on resume.
	if get_tree().paused: return
	var camera: Camera3D = VIEW.camera(self)
	if camera != null: SOUNDS.play_at(camera, event, camera.global_position)


func _first_button(node: Node) -> Button:
	for child in node.find_children("*", "Button", true, false):
		if (child as Button).is_visible_in_tree() and not (child as Button).disabled: return child
	return null


func _open_provider() -> void:
	_show("settings")
	_settings.show_tab("AI Settings")


## The saved games panel takes over (its own Escape/Close); the pause menu comes back
## once it closes.
func _open_saves() -> void:
	if save_menu == null: return
	canvas.hide()
	if is_instance_valid(save_menu): save_menu.set_process_input(true)
	save_menu.toggle()
	if not save_menu.opened:
		canvas.show(); return
	_in_save_menu = true


## Perf 0.1.0: the idle-pause check (minutes long) runs four times a second, not every frame.
## Input events still stamp _last_input_msec as they arrive. 0.0 = every frame.
const IDLE_CHECK_SECONDS := 0.25
var _idle_check_left := 0.0

func _process(_delta: float) -> void:
	_idle_check_left -= _delta
	if _idle_check_left <= 0.0:
		_idle_check_left = IDLE_CHECK_SECONDS
		_check_idle()
	if not _in_save_menu: return
	if is_instance_valid(save_menu) and save_menu.opened: return
	_in_save_menu = false
	if not opened: return
	if is_instance_valid(save_menu): save_menu.set_process_input(false)
	# The saves panel restored its own mouse/lock state; the pause menu owns them again.
	player_body.controls_locked = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_fit(); canvas.show(); _show("main")


# ------------------------------------------------------------------ support
func _bundle_script() -> Script:
	return load(LOG_BUNDLE) as Script if ResourceLoader.exists(LOG_BUNDLE) else null


func _make_bundle() -> void:
	var script := _bundle_script()
	if script == null: _support_status.text = "The logs bundle is not available in this build."; return
	var path: String = str(script.call("make_bundle"))
	if path.is_empty(): _support_status.text = "Could not make the logs bundle."; return
	if path.begins_with("user://") or path.begins_with("res://"): path = ProjectSettings.globalize_path(path)
	DisplayServer.clipboard_set(path)
	_support_status.text = "Saved to %s (path copied to the clipboard)." % path


func _open_logs() -> void:
	var script := _bundle_script()
	if script != null: script.call("open_logs_folder")
	else: OS.shell_open(ProjectSettings.globalize_path("user://logs"))


# ------------------------------------------------------------------ quitting
## Back to the home screen, after the same autosave a window close makes (game_saves.gd
## save_before_quit) so Continue on the title resumes here. The world scene is freed by the
## scene change; ZoneManager forgets its zones in game.gd's _exit_tree. Clock/mouse/lock are
## restored first so the title's clock snapshot is the running world's.
## The quit save is written while the menu still holds the frame it covered (its screenshot).
func quit_to_title() -> void:
	_autosave()
	if opened: close()
	TimeOfDay.paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file.call_deferred(TITLE_SCENE)


func quit_game() -> void:
	_autosave()
	get_tree().quit()


func _autosave() -> void:
	var saves: Node = save_menu.saves if save_menu != null else null
	if is_instance_valid(saves) and saves.has_method("save_before_quit"): saves.save_before_quit()


## The world's GameSaves when it offers screenshots (menu fixtures may have none).
func _saves() -> Node:
	var saves: Variant = save_menu.get("saves") if is_instance_valid(save_menu) else null
	return saves if is_instance_valid(saves) and saves is Node and saves.has_method("remember_view") else null
