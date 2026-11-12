extends Node3D
## Lightweight title: baked surroundings and a spatial menu. Gameplay loads on entry.
const PANEL := preload("res://world/ui/spatial_menu_panel.gd")
const CONTROLLER_POINTER := preload("res://world/ui/controller_pointer.gd")
const TITLE_TIME := preload("res://world/ui/title_time.gd")
const BAKED := preload("res://world/ui/baked_vistas.gd")
const GAME := "res://world/main.tscn"
const SAVE_FILE := preload("res://world/save_file.gd")
const SAVES_PATH := "res://world/game_saves.gd"
const PACKS := preload("res://tools/build/packs.gd")
## Save discovery shared with the in-game saved games panel (headers and screenshots only).
const CATALOGUE := preload("res://world/saves/save_catalogue.gd")
const PREVIEW := preload("res://world/saves/save_preview.gd")
const SHELF := preload("res://world/saves/save_shelf.gd")
## Scenario mods (world/modding/scenario.gd): Continue says when the newest save needs another mod
## setup, and why the game came back here (its notice). Light: it preloads only the mod loader.
const SCENARIO := preload("res://world/modding/scenario.gd")
# Header labelling only; selected files are always validated by GameSaves.
# Keep this lightweight menu constant aligned with GameSaves.FORMAT.
const SAVE_HEADER_FORMAT := CATALOGUE.HEADER_FORMAT
## The menu wears the title words' own look (world/ui/title/: bubbly pink-to-lilac letters, a white
## outline, a soft purple shadow) and says no more than it must (dev 2026-10-02: "minimalist and
## pony-themed", not a blue card with gold trim and filler lines).
const PINK := Color("f6a6d9")
const LILAC := Color("c06fdb")
const PLUM := Color("6b3f86")
const MIST := Color("efd2f5")
const WHITE := Color(1, 1, 1)
## Settings and the dialogue setup keep light text: the card turns plum behind them.
const DEEP := Color(0.25, 0.13, 0.31, 0.93)
const FONT := preload("res://world/ui/fonts/CelestiaMediumRedux.ttf")
@export var time_preference_path := TITLE_TIME.PATH
@export var load_scenery := false
@export var game_scene := GAME
var panel: Node3D
var camera: Camera3D
var xr_origin: XROrigin3D
var controllers: Array[XRController3D] = []
var pointer: MeshInstance3D
var _controller_pointers: Dictionary = {}
var xr_active := false
## Seated VR (world/launch_config.gd seated()): the headset view with keyboard and mouse. The
## mouse ray drives the panel; controllers are not built and not needed.
var seated := false
var phase: Dictionary
var status: Label
var _version_box: VBoxContainer   # version line + update button, bottom of the home page
var _hint: Label
var enter_button: Button
var quit_button: Button
var settings_button: Button
var credits_button: Button
var new_game_button: Button
var load_button: Button
var _saves: GDScript
const SEASON_NAMES := ["Spring", "Summer", "Autumn", "Winter"]   # weather.gd SEASONS order
## Load game: the saves browser (world/ui/save_browser.gd), worlds as folders, saves as cards.
var _load_page: Control
var _browser: Control
## The menus' look (dev 2026-10-27 redesign): the twilight card behind every page but home, and
## the flourishes over the whole panel.
const MENU_STYLE := preload("res://world/ui/menu_style.gd")
const UPDATER := preload("res://world/update/updater.gd")
const MENU_CARD := preload("res://world/ui/menu_card.gd")
const MENU_ICON := preload("res://world/ui/menu_icon.gd")
var _fx: Control
## Desktop: the panel glides to the middle and nearer for the pages, back for home. The pages
## widen to the window's shape and come near enough to fill most of its height, drawn finer on a
## big window (dev 2026-10-27: "make some screens take more place to be more visible"); home and
## the headset keep the panel's own 900 x 840.
const HOME_SPOT := Vector3(-0.68, -0.18, -2.25)
const PAGE_FILL := 0.9
const PAGE_WIDEST := 1480
var _forward := false
var _glide: Tween
## What Continue resumes (save_catalogue.gd newest()), shown beside the button.
var _continue_entry: Dictionary = {}
var continue_preview: Control
var continue_line: Label
## New game → choose the opening: the Everfree forest or skip to Golden Oak (dev 2026-10-23).
## Replaced the unused season page; a new game always starts in spring.
var _opening_page: Control
var _opening_buttons: Array[Button] = []
var _opening_back: Button
## Home page and settings page share the panel; one is visible at a time.
var _home_page: Control
var _settings_page: Control
var _credits_page: Control
var _credits_back: Button
## The shared tabbed page (world/ui/settings_page.gd, rows from Settings.TABS).
var _settings_ui: Control
var _provider_page:Control
var _provider_button:Button
var _setup_window: Window
## Room-scale VR: the on-panel keyboard (world/ui/panel_keyboard.gd) under any text field of the
## settings or the first-run AI setup, as on the in-game World Panel (GitHub #1: the title's AI
## Settings took only physical keys). Shown and hidden on focus and page changes, never polled.
const KEYBOARD := preload("res://world/ui/panel_keyboard.gd")
const KEYBOARD_TOP := 500.0
var keyboard: Control
var _keyboard_queued := false
## AI context (world/ui/ai_context_page.gd): what ponies remember, what a request sends, errors.
var _context_page: Control
var _context_button: Button
## Journal (world/ui/journal_page.gd): the talk of any world, as pictures to share.
var journal_button: Button
var _journal_page: Control
var _setup_start := false
var ready_for_entry := false
var entering := false
var scenery: Node3D
var _clock: Dictionary = {}
var _saved_cap := 0
var _request := ""
var _request_kind := ""
var _asset_requests: Array[String] = []
var _focused := 0
var _stick_wait := 0.0
var _recenter_wait := 0.4
var _owner: XRController3D
var _exit_requested := false
## Set by world/ui/title_vista.gd: the menu floats over the live world instead of a backdrop.
var overlay_host: Node = null
## New game / Load game staged a different world: entering reloads the game scene.
var _staged := false
const COVER := preload("res://world/ui/loading_cover.gd")
## The loading screen raised over the menu once a game is chosen, and what it says about the
## world being entered ({title, line, icon, tint}; _trip_of()).
var _cover: Node
var _cover_raised := 0
var _logo_fade: Tween
var _destination := {}
## The loaded world, waiting for the cover to show the hand-off (_hand_off()).
var _packed: PackedScene
var _hand_off_frames := 0
var _cover_wait := 0.0
const GAME_SCRIPT := "res://world/game.gd"
## Card timing, seconds: black, the logo fades in on black, a hold, then the black fades away and
## leaves the menu, whose own logo sits exactly where the faded-in one was (dev 2026-10-02:
## "everything should be black except for the HOME: EQUESTRIA already on the title menu ... fade
## in the text, then fade OUT the black"; the logo image replaced the two words on 2026-10-08).
const CARD_BLACK := 0.8
## Title music (dev 2026-10-23: "black screen, game loads, as it fades in My little POOOONyyyy"):
## the trailer's piano theme starts this far into the launch card, loops on the title, and fades
## out when the game is entered.
const THEME := preload("res://world/ui/music/title_theme.ogg")
const THEME_AT := 1.0
const THEME_FADE := 1.5
var _music: AudioStreamPlayer
const CARD_LOGO := 1.6
const CARD_HOLD := 0.8
const CARD_REVEAL := 1.4
## The home page's logo, in panel pixels: big (dev 2026-10-08: "make it much bigger"), above the
## buttons and reaching past the panel's top edge, so it is a sprite on the panel, not a control.
const LOGO_RECT := Rect2(0, -380, 900, 696)
var _card_active := false
var _logo: Sprite3D
var _card_sphere: MeshInstance3D
var _card_time := 0.0
var _menu_card: Control

static func bypass_title(args: PackedStringArray) -> bool:
	for flag in ["--skip-title", "--capture", "--probe", "--perf", "--perf-stereo", "--profile-runtime"]:
		if flag in args: return true
	return false

## Idle titles only read checkpoint headers. Full validators pull in gameplay, so keep
## their script unloaded until a user chooses a checkpoint or confirms a new game.
func _save_api() -> GDScript:
	if _saves == null: _saves = load(SAVES_PATH) as GDScript
	return _saves

static func _header_number(value: Variant) -> float:
	return float(value) if (value is int or value is float) and is_finite(float(value)) else 0.0

func _catalogue() -> Array[Dictionary]:
	return CATALOGUE.catalogue()

func _ready() -> void:
	if overlay_host != null:
		_ready_overlay()
		return
	# The headset's view first (GitHub #16): whatever fails below, OpenXR then has a viewport to
	# show instead of a silent black void ("No viewport was marked with use_xr").
	_claim_headset()
	# Labs that watch the whole opening (tools/title/) live on the root, across the scene change.
	var args := preload("res://world/dev_tools.gd").user_args()
	var lab_at := args.find("--lab")
	if lab_at >= 0 and lab_at + 1 < args.size() and ResourceLoader.exists(args[lab_at + 1]) and get_tree().root.get_node_or_null("Lab") == null:
		var lab: Node = load(args[lab_at + 1]).new(); lab.name = "Lab"
		get_tree().root.add_child.call_deferred(lab)
	if bypass_title(preload("res://world/dev_tools.gd").user_args()):
		get_tree().change_scene_to_file.call_deferred(game_scene)
		return
	if game_scene == GAME and preload("res://world/launch_config.gd").should_ask():
		if not await _ask_play_mode(): return
	xr_active = _openxr_ready()
	if game_scene == GAME and not xr_active: await _ask_quality()
	seated = xr_active and preload("res://world/launch_config.gd").seated()
	if preload("res://world/launch_config.gd").require_vr() and not xr_active:
		preload("res://world/launch_config.gd").fail_required_vr(get_tree())
		return
	_saved_cap = Engine.max_fps
	if not xr_active: Engine.max_fps = 60
	_clock = {"hours": TimeOfDay.hours, "day": TimeOfDay.day}
	TimeOfDay.hold("title")
	_build_camera()
	scenery = BAKED.new()
	add_child(scenery)
	scenery.setup(camera)
	phase = {"name": scenery.view_name, "hours": TimeOfDay.hours}
	_build_panel()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if game_scene.is_empty():
		_finish_scenery() # Menu-only fixtures skip the animated card.
	else:
		panel.hide()
		_build_card()

## True while an OpenXR session runs (tools/ui/test_title_without_data.gd stands in for one).
func _openxr_ready() -> bool:
	var iface := XRServer.find_interface("OpenXR")
	return iface != null and iface.is_initialized()

## Marks the root viewport for the headset before anything else runs. The desktop-or-VR prompt
## (world/ui/play_mode_prompt.gd) is a flat window: it keeps the window until it is answered.
func _claim_headset() -> void:
	if _openxr_ready() and not preload("res://world/launch_config.gd").should_ask():
		get_viewport().use_xr = true

## The launch card: everything black but the menu's own logo, which fades in where the menu draws
## it; then the black fades away around it. Desktop and headset alike: a black sphere around the
## camera, and the menu's logo sprite drawn over the sphere. The menu is in place (and hidden under the black) from the start.
## Desktop or VR each launch until remembered (world/ui/play_mode_prompt.gd). False when the
## game restarts into VR.
func _ask_play_mode() -> bool:
	var launch := preload("res://world/launch_config.gd")
	var prompt: CanvasLayer = preload("res://world/ui/play_mode_prompt.gd").new()
	add_child(prompt)
	var answer: Array = await prompt.chosen
	prompt.queue_free()
	var mode := str(answer[0])
	if bool(answer[1]):
		launch.write(mode)
		var settings: Node = get_tree().root.get_node_or_null("Settings")
		if settings != null: settings.set_value("vr/start_mode", mode)
	if mode == "off": return true
	launch.restart_in_vr(get_tree())
	return false

## First desktop launch: offer the machine check (world/ui/quality_prompt.gd). Opt-in; asked once.
func _ask_quality() -> void:
	var settings: Node = get_tree().root.get_node_or_null("Settings")
	if settings == null or bool(settings.get_value("setup/quality_asked")) or DisplayServer.get_name() == "headless": return
	var prompt: CanvasLayer = preload("res://world/ui/quality_prompt.gd").new()
	add_child(prompt)
	var pick := str(await prompt.chosen)
	prompt.queue_free()
	if pick != "": settings.set_value("video/quality", pick)
	settings.set_value("setup/quality_asked", true)

func _build_card() -> void:
	_card_active = true
	var mesh := SphereMesh.new(); mesh.radius = 0.6; mesh.height = 1.2; mesh.flip_faces = true
	var mat := StandardMaterial3D.new(); mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color.BLACK; mat.no_depth_test = true; mat.render_priority = 100
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = mat
	_card_sphere = MeshInstance3D.new(); _card_sphere.mesh = mesh
	_card_sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	camera.add_child(_card_sphere)
	_logo.modulate.a = 0.0
	panel.show()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _card_step(delta: float) -> void:
	_card_time += delta
	if _card_time >= THEME_AT: _start_music()
	# The headset pose settles in the first moments: re-centre the menu under the black.
	if xr_active and _recenter_wait > 0:
		_recenter_wait -= delta
		if _recenter_wait <= 0: recenter()
	var logo := smoothstep(CARD_BLACK, CARD_BLACK + CARD_LOGO, _card_time)
	var reveal_from := CARD_BLACK + CARD_LOGO + CARD_HOLD
	var black := 1.0 - smoothstep(reveal_from, reveal_from + CARD_REVEAL, _card_time)
	# The menu's own logo takes over where the home page shows; first launch opens the setup page
	# instead, so there the logo fades away with the black.
	var keep := 1.0 if _home_page != null and _home_page.visible else black
	_logo.modulate.a = logo * keep
	((_card_sphere.mesh as SphereMesh).material as StandardMaterial3D).albedo_color.a = black
	if _card_time >= reveal_from + CARD_REVEAL:
		_card_active = false
		_logo.visible = _home_page.visible
		if is_instance_valid(_card_sphere): _card_sphere.queue_free()
		_card_sphere = null
		_finish_scenery()

## Hosted over the live world by world/ui/title_vista.gd: its camera and controllers, no
## backdrop, no clock changes; Continue hands back to the vista.
func _ready_overlay() -> void:
	var game: Node = overlay_host.game
	xr_active = game.xr_active
	camera = game._find_camera(game.player)
	phase = {"name": str(overlay_host.view_name).capitalize(), "hours": TimeOfDay.hours}
	if xr_active:
		for side: String in ["Left", "Right"]:
			var controller: XRController3D = game.player.find_child("XRController" + side, true, false) as XRController3D
			if controller == null: continue
			controllers.append(controller)
			controller.button_pressed.connect(_controller_pressed.bind(controller))
			controller.button_released.connect(_controller_released.bind(controller))
		_make_pointer()
	elif camera is XRCamera3D:
		# Seated VR: the mouse ray points; this dot shows where, and the seated mouse dot
		# (world/ui/headset_cursor.gd) stays out of the way while the menu is up.
		_make_pointer()
		var cursor: Node = get_tree().get_first_node_in_group("headset_cursor")
		if cursor != null and cursor.has_method("hide_for"): cursor.hide_for(self)
	_build_panel()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_finish_scenery()

func _make_pointer() -> void:
	pointer = MeshInstance3D.new()
	# Seated VR moves it from mouse events, between physics ticks.
	if seated or not xr_active: pointer.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var dot := SphereMesh.new(); dot.radius = 0.006; dot.height = 0.012
	pointer.mesh = dot
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = PINK
	pointer.material_override = material
	pointer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(pointer); pointer.hide()
	for controller in controllers:
		var ray := CONTROLLER_POINTER.new()
		ray.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(ray); ray.set_color(WHITE)
		_controller_pointers[controller] = ray

func _build_camera() -> void:
	if xr_active:
		get_viewport().use_xr = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Quality.set_xr_mode(true)
		xr_origin = XROrigin3D.new()
		add_child(xr_origin)
		camera = XRCamera3D.new()
		xr_origin.add_child(camera)
		for side in ([] if seated else ["left_hand", "right_hand"]):
			var controller := XRController3D.new()
			controller.tracker = StringName(side)
			controller.pose = &"aim"
			xr_origin.add_child(controller)
			controllers.append(controller)
			controller.button_pressed.connect(_controller_pressed.bind(controller))
			controller.button_released.connect(_controller_released.bind(controller))
		_make_pointer()
	else:
		camera = Camera3D.new()
		camera.fov = 50.0
		add_child(camera)
		camera.position = Vector3.ZERO
	camera.near = 0.05
	camera.far = 9000.0
	camera.current = true

func _label(text: String, y: float, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.position = Vector2(66, y)
	label.size.x = 768
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", FONT)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	_page().add_child(label)
	return label


## The status line (loading, problems), the VR pointing hint and the version box share the bottom
## of the home page: a status line hides the other two, an update button hides the hint.
func _bottom_lines() -> void:
	if not is_instance_valid(_version_box) or not is_instance_valid(status): return
	var quiet := status.text.is_empty()
	var button: Control = _version_box.get_node_or_null("Update")
	var hint := quiet and not (button != null and button.visible)
	if _version_box.visible == quiet and (not is_instance_valid(_hint) or _hint.visible == hint): return
	_version_box.visible = quiet
	if is_instance_valid(_hint): _hint.visible = hint
	if panel != null: panel.refresh()


func _update_changed() -> void:
	_bottom_lines()
	if panel != null: panel.refresh()


## Controls are built into whichever page is being assembled (home by default).
var _building: Control
func _page() -> Control:
	return _building if _building != null else panel.content

func _style(color: Color, border: Color, width := 3, radius := 38) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 30
	style.content_margin_right = 30
	style.shadow_color = Color(0.42, 0.22, 0.52, 0.18)
	style.shadow_size = 6
	style.shadow_offset = Vector2(0, 3)
	return style

## No card on the home page (the title words and buttons stand on the world); every other page
## stands on the twilight card (world/ui/menu_card.gd), which the panel redraws a few times a
## second so its stars twinkle. On desktop the panel comes forward for those pages.
func _set_card(_light := true) -> void:
	# Callers switch pages around this call: look once they are done.
	_update_card.call_deferred()


func _update_card() -> void:
	if _menu_card == null: return
	var home := _home_page != null and _home_page.visible
	_menu_card.visible = not home
	panel.tick = 0.0 if home else 1.0 / 20.0
	_lay_out()
	_bring_forward(not home)
	# _lay_out() gives the settings page its full height back; the keyboard takes its share again.
	_queue_keyboard()


func _wide_pages() -> bool:
	return _desktop_pages() and _home_page != null and not _home_page.visible


func _desktop_pages() -> bool:
	return not xr_active and not (camera is XRCamera3D)


## The desktop pages' layout for this window: its shape, as tall as the panel.
func _wide_layout() -> Vector2i:
	var window := Vector2(get_viewport().get_visible_rect().size)
	return Vector2i(clampi(int(0.95 * window.x / maxf(1.0, window.y) * PANEL.PIXELS.y / PAGE_FILL), PANEL.PIXELS.x, PAGE_WIDEST), PANEL.PIXELS.y)


## The panel's shape for what shows: the window's (desktop pages) or its own (home, headset).
func _lay_out() -> void:
	var layout := PANEL.PIXELS
	var sharpness := 1.0
	if _wide_pages():
		layout = _wide_layout()
		sharpness = clampf(ceilf(get_viewport().get_visible_rect().size.y * PAGE_FILL / PANEL.PIXELS.y * 4.0) / 4.0, 1.0, 2.0)
	# The pages follow the layout every time: a page may have been sized for another window while
	# home showed (a square window keeps the panel's own shape, so nothing reshapes).
	if layout != panel.pixels or not is_equal_approx(sharpness, panel.resolution): panel.resize(layout, sharpness)
	var page_size := Vector2(layout)
	_menu_card.size = page_size
	for page: Control in [_load_page, _settings_page, _opening_page]: page.size = page_size
	_browser.relayout(page_size - Vector2(72, 64))
	# While home shows (every page hidden) the settings rows keep their desktop width; an open page,
	# even in a square window whose layout is the panel's own width, follows the layout.
	if not (_desktop_pages() and _home_page.visible): _settings_ui.relayout(page_size - Vector2(80, 50))
	_credits_page.custom_minimum_size = page_size - Vector2(52, 44); _credits_page.size = _credits_page.custom_minimum_size
	_context_page.relayout(page_size)
	_journal_page.relayout(page_size - Vector2(80, 50))


## The window changed size under an open page: reshape and stand it again.
func _window_resized() -> void:
	if panel == null or not _forward: return
	if _glide != null and _glide.is_valid(): _glide.kill()
	_lay_out(); _place_panel()


## Desktop only: the headset keeps the panel where the player looks.
func _bring_forward(forward: bool) -> void:
	if forward == _forward or xr_active or camera is XRCamera3D: return
	_forward = forward
	var target := _panel_spot()
	if _glide != null and _glide.is_valid(): _glide.kill()
	if MENU_STYLE.still() or _card_active:
		panel.global_transform = target; return
	_glide = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_glide.tween_property(panel, "global_transform", target, 0.42)
	_glide.parallel().tween_method(func(_v: float) -> void: panel.refresh(), 0.0, 1.0, 0.42)

func _button(text: String, y: float, primary: bool) -> Button:
	var button := Button.new()
	button.text = text
	button.position = Vector2(170, y)
	button.size = Vector2(560, 100)
	button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.add_theme_font_override("font", FONT)
	button.add_theme_font_size_override("font_size", 36)
	button.add_theme_color_override("font_color", WHITE if primary else PLUM)
	button.add_theme_color_override("font_hover_color", WHITE)
	button.add_theme_color_override("font_focus_color", WHITE)
	button.add_theme_color_override("font_pressed_color", WHITE)
	button.add_theme_color_override("font_disabled_color", Color(PLUM, 0.4))
	button.add_theme_stylebox_override("normal", MENU_STYLE.rounded(_style(LILAC, WHITE, 4) if primary else _style(Color(1, 1, 1, 0.92), MIST)))
	button.add_theme_stylebox_override("hover", MENU_STYLE.rounded(_style(PINK, WHITE, 4)))
	button.add_theme_stylebox_override("pressed", MENU_STYLE.rounded(_style(LILAC.darkened(0.12), WHITE, 4)))
	button.add_theme_stylebox_override("focus", MENU_STYLE.rounded(_style(PINK, WHITE, 4)))
	button.add_theme_stylebox_override("disabled", MENU_STYLE.rounded(_style(Color(1, 1, 1, 0.55), MIST)))
	button.mouse_entered.connect(panel.refresh)
	button.mouse_exited.connect(panel.refresh)
	button.focus_entered.connect(panel.refresh)
	button.focus_exited.connect(panel.refresh)
	_page().add_child(button)
	return button

func _build_panel() -> void:
	panel = PANEL.new()
	panel.name = "HomePanel"
	add_child(panel)
	_menu_card = MENU_CARD.new()
	_menu_card.size = PANEL.PIXELS
	_menu_card.inset = 12.0
	panel.content.add_child(_menu_card)
	_menu_card.hide()
	_home_page = Control.new(); _home_page.name = "Home"; _home_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_home_page.size = PANEL.PIXELS
	panel.content.add_child(_home_page)
	_building = _home_page
	# The game logo (world/ui/title/logo.png, dev 2026-10-08), no tagline (dev 2026-09-30): fitted
	# into LOGO_RECT in the panel's plane, a hair in front, over the launch card's black sphere.
	_logo = Sprite3D.new(); _logo.texture = COVER.LOGO
	var logo_size := Vector2(COVER.LOGO.get_size())
	_logo.pixel_size = PANEL.PIXEL_SIZE * minf(LOGO_RECT.size.x / logo_size.x, LOGO_RECT.size.y / logo_size.y)
	var logo_centre := (LOGO_RECT.get_center() - Vector2(PANEL.PIXELS) * 0.5) * PANEL.PIXEL_SIZE
	_logo.position = Vector3(logo_centre.x, -logo_centre.y, 0.004)
	_logo.no_depth_test = true; _logo.render_priority = 102; _logo.shaded = false
	_logo.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED; _logo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	panel.add_child(_logo)
	# Only the home page shows it; during the launch card the card fades it instead.
	_home_page.visibility_changed.connect(func() -> void: if not _card_active: _logo.visible = _home_page.visible)
	_continue_entry = CATALOGUE.newest(_catalogue())
	var has_checkpoint := not _continue_entry.is_empty()
	enter_button = _button("Continue" if has_checkpoint else "Play", 330, true)
	enter_button.disabled = true
	enter_button.pressed.connect(_enter_pressed)
	enter_button.size.y = 90
	if has_checkpoint: _build_continue_preview()
	new_game_button = _button("New game", 466, false)
	new_game_button.pressed.connect(_new_game)
	load_button = _button("Load game", 542, false)
	load_button.pressed.connect(_open_load)
	load_button.size.x = 270
	journal_button = _button("Journal", 542, false)
	journal_button.pressed.connect(_open_journal)
	journal_button.position.x = 460; journal_button.size.x = 270
	settings_button = _button("Settings", 618, false)
	settings_button.pressed.connect(_open_settings)
	quit_button = _button("Quit", 694, false)
	quit_button.pressed.connect(_quit)
	credits_button = _button("Credits", 694, false)
	credits_button.pressed.connect(_open_credits)
	credits_button.size.x = 270
	quit_button.position.x = 460; quit_button.size.x = 270
	for b in [new_game_button, load_button, journal_button, settings_button, credits_button, quit_button]: b.size.y = 68
	# Only loading and problems are ever written here.
	status = _label("", 770, 26, WHITE)
	status.add_theme_color_override("font_outline_color", PLUM); status.add_theme_constant_override("outline_size", 8)
	if xr_active and not seated:
		_hint = _label("Point and pull the trigger", 770, 22, WHITE)
		_hint.add_theme_color_override("font_outline_color", PLUM); _hint.add_theme_constant_override("outline_size", 8)
	# Which version this is, and an update button while a newer one is out (dev 2026-10-28: "add
	# it to the home page when you boot up the game so you can update from the home page").
	_version_box = VBoxContainer.new(); _version_box.name = "Version"
	_version_box.add_theme_constant_override("separation", 2)
	_home_page.add_child(_version_box)
	# Pinned to the bottom edge and growing upward as the update button comes and goes.
	_version_box.anchor_top = 1.0; _version_box.anchor_bottom = 1.0
	_version_box.offset_left = 170; _version_box.offset_right = 730
	_version_box.offset_top = -6; _version_box.offset_bottom = -6
	_version_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var updater: Node = UPDATER.shared(self)
	updater.attach(_version_box, _quit, 20)
	for node: Node in _version_box.get_children():
		if node is Label:
			node.add_theme_font_override("font", FONT)
			node.add_theme_color_override("font_color", WHITE)
			node.add_theme_color_override("font_outline_color", PLUM); node.add_theme_constant_override("outline_size", 6)
		elif node is Button:
			var button := node as Button
			button.add_theme_font_override("font", FONT); button.alignment = HORIZONTAL_ALIGNMENT_CENTER
			for state_name in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color"]:
				button.add_theme_color_override(state_name, WHITE)
			button.add_theme_stylebox_override("normal", MENU_STYLE.rounded(_style(LILAC, WHITE, 4)))
			button.add_theme_stylebox_override("hover", MENU_STYLE.rounded(_style(PINK, WHITE, 4)))
			button.add_theme_stylebox_override("pressed", MENU_STYLE.rounded(_style(LILAC.darkened(0.12), WHITE, 4)))
			button.add_theme_stylebox_override("focus", MENU_STYLE.rounded(_style(PINK, WHITE, 4)))
			button.add_theme_stylebox_override("disabled", MENU_STYLE.rounded(_style(Color(1, 1, 1, 0.55), MIST)))
			button.mouse_entered.connect(panel.refresh); button.mouse_exited.connect(panel.refresh)
	updater.changed.connect(_update_changed)
	_bottom_lines()
	_building = null
	_set_card(true)
	_build_settings_page()
	_build_credits_page()
	_build_load_page()
	_build_opening_page()
	_setup_start = not has_checkpoint
	_provider_page=preload("res://world/ui/provider_settings.gd").new()
	panel.content.add_child(_provider_page);_provider_page.setup(panel)
	_provider_page.closed.connect(_close_provider)
	_context_page = preload("res://world/ui/ai_context_page.gd").new()
	panel.content.add_child(_context_page); _context_page.setup(panel)
	_context_page.closed.connect(_close_context)
	_journal_page = preload("res://world/ui/journal_page.gd").new()
	panel.content.add_child(_journal_page); _journal_page.setup(panel)
	_journal_page.position = Vector2(40, 28); _journal_page.relayout(Vector2(PANEL.PIXELS) - Vector2(80, 50))
	_journal_page.closed.connect(_close_journal)
	_fx = preload("res://world/ui/menu_fx.gd").new(); _fx.name = "Flourishes"
	panel.content.add_child(_fx); _fx.attach(panel.content, panel.refresh)
	_browser.fx = _fx
	_build_keyboard()
	get_viewport().size_changed.connect(_window_resized)
	_place_panel()
	if not bool(Settings.get_value("setup/completed")) and _installation_problem().is_empty():
		_provider_page.setup_mode = true
		_open_provider()
	panel.refresh()


## Continue follows what Load game changed: the newest save may have been archived or deleted
## (or renamed), so its button, picture and line are made again from the saves as they are now.
func _refresh_continue() -> void:
	_continue_entry = CATALOGUE.newest(_catalogue())
	for node: Control in [continue_preview, continue_line]:
		if is_instance_valid(node): node.queue_free()
	continue_preview = null; continue_line = null
	var has_checkpoint := not _continue_entry.is_empty()
	enter_button.text = "Continue" if has_checkpoint else "Play"
	enter_button.position.x = 170; enter_button.size.x = 560
	if has_checkpoint:
		_building = _home_page; _build_continue_preview(); _building = null
	panel.refresh()


## The screenshot of what Continue resumes and one line about it, beside the Continue button
## (dev 2026-10-15: "its really unclear what save games are what").
func _build_continue_preview() -> void:
	enter_button.position.x = 342; enter_button.size.x = 388
	continue_preview = _thumbnail(_page(), Rect2(170, 330, 160, 90), str(_continue_entry.get("preview", "")))
	continue_line = Label.new()
	continue_line.text = CATALOGUE.line(_continue_entry) if not bool(_continue_entry.newer) else "Made by a newer version of the game · " + str(_continue_entry.world_name)
	var blocked := SCENARIO.entry_block(_continue_entry)
	if not bool(_continue_entry.newer) and not blocked.is_empty(): continue_line.text = blocked + " · " + str(_continue_entry.world_name)
	continue_line.position = Vector2(40, 426); continue_line.size = Vector2(820, 34)
	continue_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	continue_line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	continue_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	continue_line.add_theme_font_override("font", FONT)
	continue_line.add_theme_font_size_override("font_size", 25)
	continue_line.add_theme_color_override("font_color", WHITE)
	continue_line.add_theme_color_override("font_outline_color", PLUM); continue_line.add_theme_constant_override("outline_size", 7)
	_page().add_child(continue_line)


## A framed screenshot (or a soft placeholder when the save has none: old saves, headsets).
func _thumbnail(parent: Control, rect: Rect2, path: String) -> Control:
	var frame := Panel.new()
	frame.position = rect.position; frame.size = rect.size
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := _style(Color(MIST, 0.95), WHITE, 3, 12)
	style.shadow_size = 4
	frame.add_theme_stylebox_override("panel", style)
	parent.add_child(frame)
	var texture := PREVIEW.texture(path)
	if texture != null:
		var picture := TextureRect.new()
		picture.texture = texture
		picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		picture.position = Vector2(3, 3); picture.size = rect.size - Vector2(6, 6)
		picture.clip_contents = true
		picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(picture)
	else:
		var none := Label.new(); none.text = "No picture"
		none.size = rect.size; none.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; none.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		none.add_theme_font_override("font", FONT); none.add_theme_font_size_override("font_size", 18)
		none.add_theme_color_override("font_color", Color(PLUM, 0.7)); none.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(none)
	return frame


## Load page: the saves browser, opened on the world played last; picking a save stages it and
## enters. Names, tags, stars, the archive and deleting work here too (world/saves/save_shelf.gd).
func _build_load_page() -> void:
	_load_page = Control.new(); _load_page.name = "LoadGame"; _load_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_load_page.size = PANEL.PIXELS
	_load_page.visible = false
	panel.content.add_child(_load_page)
	_browser = preload("res://world/ui/save_browser.gd").new()
	_browser.heading = "Load game"; _browser.panel = panel
	_browser.position = Vector2(36, 32)
	_load_page.add_child(_browser)
	_browser.setup(Vector2(828, 776), 20, null, xr_active and not seated)
	_browser.redraw = panel.refresh
	_browser.closed.connect(_close_load)
	_browser.load_requested.connect(_pick_entry)


func _open_load() -> void:
	if not ready_for_entry: return
	_home_page.visible = false
	_load_page.visible = true
	_set_card(true)
	_browser.open()
	var first: Control = _browser.first_focus()
	_focused = maxi(0, _browser.focusables().find(first))
	first.grab_focus()
	panel.refresh()


func _pick_entry(entry: Dictionary) -> void:
	if entering: return
	var saves := _save_api()
	if saves == null or not saves.stage(entry):
		var problem: String = str(saves.get("last_problem")) if saves != null and saves.get("last_problem") is String else ""
		_browser.set_status((problem + ".") if not problem.is_empty() else "That save cannot be loaded (invalid or from another version).")
		return
	_browser.set_status("Loading “%s”…" % CATALOGUE.title_text(entry))
	_staged = true
	_destination = _trip_of(entry)
	enter_game()


## A new game always starts in spring (dev 2026-10-01). New game first asks how it opens
## (dev 2026-10-23: the Everfree skip must be offered on New game, desktop and VR alike).
func _new_game() -> void:
	if entering or not ready_for_entry: return
	_open_opening()


## The Play/Continue button. With no save to continue, Play starts a new game, so it asks how
## it opens first. enter_game() itself stays direct for fixtures and the setup flow; the
## creator panel (world/life/pony_creator.gd) offers the same choice on desktop.
func _enter_pressed() -> void:
	if is_instance_valid(_setup_window) or entering or not ready_for_entry: return
	if bool(Settings.get_value("setup/completed")) and not _staged and game_scene == GAME and CATALOGUE.newest(_catalogue()).is_empty():
		_open_opening(); return
	enter_game()


func _open_opening() -> void:
	_home_page.visible = false
	_opening_page.visible = true
	_set_card(true)
	# Focus starts on the current Settings → World → Opening choice.
	_focused = 1 if str(Settings.get_value(OPENING_KEY)) == "skip" else 0
	_opening_buttons[_focused].grab_focus()
	panel.refresh()


const OPENING_KEY := "world/opening"
## [setting value, title, what it is, painted scene (world/ui/menu_vignette.gd), ribbon].
const OPENINGS := [["play", "The Everfree forest", "Wake among the trees and find your way: the controls, step by step.", "everfree", "Recommended"],
	["skip", "Golden Oak Library", "Skip the opening and wake up in Twilight's library, ready to go.", "golden_oak", ""]]

## Opening page: New game asks whether to play the forest opening or skip it, as two storybook
## cards. The answer is Settings "world/opening" (read by world/life/arrival_story.gd), so it stays
## the default.
func _build_opening_page() -> void:
	_opening_page = Control.new(); _opening_page.name = "NewGameOpening"; _opening_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_opening_page.size = PANEL.PIXELS
	_opening_page.visible = false
	_opening_page.theme = MENU_STYLE.theme()
	panel.content.add_child(_opening_page)
	var box := VBoxContainer.new(); _opening_page.add_child(box)
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 48; box.offset_top = 44; box.offset_right = -48; box.offset_bottom = -44
	box.add_theme_constant_override("separation", 14)
	var title := MENU_STYLE.label("New game", "Heading", 46); title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var question := MENU_STYLE.label("How does your story begin?", "Muted", 24); question.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(question)
	var cards := HBoxContainer.new(); cards.add_theme_constant_override("separation", 24)
	cards.alignment = BoxContainer.ALIGNMENT_CENTER; cards.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(cards)
	for option: Array in OPENINGS:
		var card := Button.new(); card.theme_type_variation = "Card"
		card.custom_minimum_size = Vector2(372, 410); card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		card.pressed.connect(_choose_opening.bind(str(option[0])))
		card.focus_entered.connect(panel.refresh); card.mouse_entered.connect(panel.refresh); card.mouse_exited.connect(panel.refresh)
		cards.add_child(card)
		var scene: Control = preload("res://world/ui/menu_vignette.gd").new()
		scene.scene = str(option[3]); scene.position = Vector2(14, 14); scene.size = Vector2(344, 206); scene.clip_contents = true
		card.add_child(scene)
		if str(option[4]) != "":
			var ribbon := PanelContainer.new(); ribbon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			ribbon.add_theme_stylebox_override("panel", MENU_STYLE.rounded(MENU_STYLE.box(MENU_STYLE.ROSE, Color.WHITE, 2, 99, 14, 3)))
			var word := MENU_STYLE.label(str(option[4]), "", 17); word.add_theme_font_override("font", MENU_STYLE.BOLD)
			word.add_theme_color_override("font_color", Color.WHITE); ribbon.add_child(word)
			ribbon.position = Vector2(26, 26)
			card.add_child(ribbon)
		var words := VBoxContainer.new(); words.mouse_filter = Control.MOUSE_FILTER_IGNORE
		words.position = Vector2(26, 238); words.size = Vector2(320, 210); words.add_theme_constant_override("separation", 10)
		card.add_child(words)
		var name_label := MENU_STYLE.label(str(option[1]), "Subheading", 27); name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.add_theme_font_override("font", MENU_STYLE.HEADING); name_label.add_theme_color_override("font_color", MENU_STYLE.PINK)
		words.add_child(name_label)
		var about := MENU_STYLE.label(str(option[2]), "Muted", 20); about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		about.custom_minimum_size.x = 320; about.mouse_filter = Control.MOUSE_FILTER_IGNORE
		words.add_child(about)
		var go := HBoxContainer.new(); go.mouse_filter = Control.MOUSE_FILTER_IGNORE; go.add_theme_constant_override("separation", 8)
		go.position = Vector2(26, 360); card.add_child(go)
		var arrow := MENU_ICON.make("play", 18, MENU_STYLE.PINK); arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		go.add_child(arrow)
		var start := MENU_STYLE.label("Begin here", "", 19); start.add_theme_font_override("font", MENU_STYLE.BOLD)
		start.add_theme_color_override("font_color", MENU_STYLE.PINK); start.mouse_filter = Control.MOUSE_FILTER_IGNORE
		go.add_child(start)
		_opening_buttons.append(card)
	var back_row := HBoxContainer.new(); back_row.alignment = BoxContainer.ALIGNMENT_CENTER; box.add_child(back_row)
	_opening_back = Button.new(); _opening_back.text = "Back"; _opening_back.theme_type_variation = "Ghost"
	_opening_back.icon = MENU_ICON.texture("back", 22); _opening_back.custom_minimum_size = Vector2(220, 54)
	_opening_back.add_theme_font_size_override("font_size", 22)
	_opening_back.pressed.connect(_close_opening)
	_opening_back.focus_entered.connect(panel.refresh); _opening_back.mouse_entered.connect(panel.refresh); _opening_back.mouse_exited.connect(panel.refresh)
	back_row.add_child(_opening_back)


func _close_opening() -> void:
	_opening_page.visible = false
	_home_page.visible = true
	_set_card(true)
	_focused = 1
	new_game_button.grab_focus()
	panel.refresh()


func _opening_open() -> bool:
	return _opening_page != null and _opening_page.visible


func _choose_opening(opening: String) -> void:
	if entering or not ready_for_entry: return
	Settings.set_value(OPENING_KEY, opening)
	_start_new_game(0)


## New worlds start in late summer (dev decision D-01, 2026-11-08: no season picker, no random),
## so autumn and winter arrive in the first sessions. The day comes from the one season formula
## (world/seasons/season_state.gd, W1-SEAS-A hook): summer, its last third. `_season` is kept for
## older callers and ignored.
func _start_new_game(_season: int) -> void:
	if entering or not ready_for_entry: return
	_setup_start = false
	var start_day := late_summer_day(int(Settings.season_days()))
	var season := 1
	if not _clock.is_empty(): _clock.day = start_day
	else: TimeOfDay.day = start_day
	var saves := _save_api()
	if saves == null:
		_load_failed("game"); return
	var world: String = saves.stage_new_game(start_day)
	_staged = true
	status.text = "New game (%s): %s" % [SEASON_NAMES[season], world]
	# The opening page stays under the loading screen; a failed entry goes back home.
	var opening: Array = OPENINGS[1] if str(Settings.get_value(OPENING_KEY)) == "skip" else OPENINGS[0]
	var look := SHELF.world_look(world, {})
	_destination = {"title": CATALOGUE.world_name(world), "line": "A new world · late %s · %s" % [SEASON_NAMES[season].to_lower(), opening[1]],
		"icon": str(look.icon), "tint": MENU_STYLE.SWATCHES[int(look.color) % MENU_STYLE.SWATCHES.size()]}
	enter_game()


## The first day of a new world: in summer, on the first day of its last third (whatever the
## season length). Loaded on New game only; the idle title never compiles the season core.
static func late_summer_day(season_days: int) -> int:
	var length := maxi(1, season_days)
	var into := mini(length - 1, ceili(2.0 * length / 3.0))
	var formula: Variant = load("res://world/seasons/season_state.gd")
	var day := length + into
	# The calendar formula decides; this only guards a changed season order.
	if formula != null and int(formula.index_for(day, length)) != 1:
		push_warning("[title] late summer day %d is not summer by season_state.gd" % day)
	return day


func _close_load() -> void:
	_load_page.visible = false
	_refresh_continue()
	_home_page.visible = true
	_set_card(true)
	_focused = 2
	load_button.grab_focus()
	panel.refresh()


func _load_open() -> bool:
	return _load_page != null and _load_page.visible


## Settings page: the shared tabbed page, plus the dialogue provider button. Values live
## in the Settings autoload and apply immediately.
func _build_settings_page() -> void:
	_settings_page = Control.new(); _settings_page.name = "Settings"; _settings_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_settings_page.size = PANEL.PIXELS
	_settings_page.visible = false
	panel.content.add_child(_settings_page)
	_settings_ui = preload("res://world/ui/settings_page.gd").new()
	_settings_ui.position = Vector2(40, 28)
	_settings_page.add_child(_settings_ui)
	# Built as wide as its desktop page will be, so its rows lay out for that width.
	var width := float(_wide_layout().x if _desktop_pages() else PANEL.PIXELS.x)
	_settings_ui.setup(Vector2(width - 80.0, 790), 22, "Back", xr_active and not seated)
	_settings_ui.redraw = panel.refresh
	_settings_ui.back_requested.connect(_close_settings)
	_context_button = Button.new(); _context_button.text = "AI context"
	_context_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL; _context_button.add_theme_font_size_override("font_size", 22)
	_context_button.pressed.connect(_open_context)
	_context_button.focus_entered.connect(panel.refresh)
	_settings_ui.footer.add_child(_context_button)


func _open_settings() -> void:
	_set_card(false)
	_home_page.visible = false
	_settings_page.visible = true
	Settings.message = ""
	_settings_ui.refresh()
	var first: Control = _settings_ui.first_focus()
	_focused = maxi(0, _settings_ui.focusables().find(first))
	first.grab_focus()
	panel.refresh()


func _close_settings() -> void:
	_settings_page.visible = false
	_home_page.visible = true
	_set_card(true)
	_focused = 0
	settings_button.grab_focus()
	panel.refresh()


func _settings_open() -> bool:
	return _settings_page != null and _settings_page.visible

func _build_credits_page() -> void:
	_credits_page = preload("res://world/ui/credits_page.gd").new(); _credits_page.name = "Credits"
	panel.content.add_child(_credits_page)
	_credits_page.position = Vector2(26, 22)
	_credits_page.setup(Vector2(PANEL.PIXELS) - Vector2(52, 44))
	_credits_page.redraw = panel.refresh
	_credits_back = _credits_page.back_button
	_credits_page.back_requested.connect(_close_credits)
	_credits_page.hide()

func _credits_open() -> bool:
	return _credits_page != null and _credits_page.visible

func _open_credits() -> void:
	_home_page.hide(); _credits_page.show(); _set_card(true)
	_focused = 0; _credits_back.grab_focus(); panel.refresh()

func _close_credits() -> void:
	_credits_page.hide(); _home_page.show(); _set_card(true)
	_focused = _focus_list().find(credits_button)
	credits_button.grab_focus(); panel.refresh()

func _open_provider()->void:
	# Desktop only: in a headset (room-scale or seated) a desktop window is out of sight, so the
	# first-run setup stays on the panel with its keyboard (GitHub #1).
	if _provider_page.setup_mode and OS.get_name() in ["Windows", "Linux", "macOS"] and _desktop_pages():
		if is_instance_valid(_setup_window): _setup_window.show(); return
		_setup_window = preload("res://world/ui/ai_setup_window.gd").new()
		add_child(_setup_window); _setup_window.close_requested.connect(_quit)
		_setup_window.open(_provider_page)
		status.text = "Complete AI setup in the desktop window."
		panel.press(false); panel.refresh(); return
	if not _provider_page.setup_mode:
		_open_settings(); _settings_ui.show_tab("AI Settings"); return
	_set_card(false)
	_settings_page.hide();_home_page.hide();_provider_page.open();_focused=0;panel.refresh()

func _build_keyboard() -> void:
	if not xr_active or seated: return
	keyboard = KEYBOARD.new(); keyboard.name = "Keyboard"
	keyboard.theme = MENU_STYLE.theme()
	panel.content.add_child(keyboard)
	keyboard.setup(panel, 880, 20); keyboard.position = Vector2(10, KEYBOARD_TOP); keyboard.hide()
	panel.viewport.gui_focus_changed.connect(func(_node: Control) -> void: _queue_keyboard())
	for page: Control in [_settings_page, _provider_page, _settings_ui.provider, _settings_ui.prompts]:
		page.visibility_changed.connect(_queue_keyboard)

## Once per batch of focus and page changes, after they settle (hiding a page drops its focus).
func _queue_keyboard() -> void:
	if keyboard == null or _keyboard_queued: return
	_keyboard_queued = true
	_tend_keyboard.call_deferred()

## A focused text field on the settings or AI setup page: the keyboard comes in under the page,
## which shortens to end above it (its lists scroll); otherwise the page has its whole height.
func _tend_keyboard() -> void:
	_keyboard_queued = false
	if keyboard == null or not is_instance_valid(panel): return
	var focus: Control = panel.viewport.gui_get_focus_owner()
	var typing := (focus is LineEdit or focus is TextEdit) and focus.is_visible_in_tree() \
		and (_settings_open() or _provider_page.visible)
	var settings_height := KEYBOARD_TOP - _settings_ui.position.y - 2.0 if typing else _settings_page.size.y - 50.0
	var setup_height := KEYBOARD_TOP if typing else float(PANEL.PIXELS.y)
	var changed := keyboard.visible != typing
	keyboard.visible = typing
	if not is_equal_approx(_settings_ui.size.y, settings_height):
		_settings_ui.custom_minimum_size.y = settings_height; _settings_ui.size.y = settings_height; changed = true
	if not is_instance_valid(_setup_window) and not is_equal_approx(_provider_page.size.y, setup_height):
		_provider_page.size.y = setup_height; changed = true
	if not changed: return
	if typing:
		# The field stays in sight above the keyboard once the shorter page has laid out.
		var scroll: Node = focus.get_parent()
		while scroll != null and not scroll is ScrollContainer: scroll = scroll.get_parent()
		if scroll != null: (scroll as ScrollContainer).ensure_control_visible.call_deferred(focus)
	_settings_ui.refresh(); panel.refresh()

func _close_provider()->void:
	if _provider_page.setup_mode:
		if not bool(Settings.get_value("setup/completed")): _quit(); return
		if is_instance_valid(_setup_window):
			_provider_page.reparent(panel.content); _provider_page.panel = panel
			_provider_page.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
			_provider_page.size = Vector2(900,840)
			_setup_window.hide(); _setup_window.queue_free(); _setup_window = null
		status.text = ""
		_provider_page.setup_mode = false
		_setup_start = CATALOGUE.newest(_catalogue()).is_empty()
		_provider_page.hide(); _home_page.show(); _set_card(true); enter_button.grab_focus(); panel.refresh()
		return
	_provider_page.hide(); _open_settings(); _settings_ui.show_tab("AI Settings")


func _open_context() -> void:
	_set_card(false)
	_settings_page.hide(); _home_page.hide(); _context_page.open(); _focused = 0; panel.refresh()

func _close_context() -> void:
	_context_page.hide(); _settings_page.show(); _set_card(false); _context_button.grab_focus()
	_focused = maxi(0, _settings_ui.focusables().find(_context_button)); panel.refresh()


func _open_journal() -> void:
	_set_card(false)
	_home_page.hide(); _journal_page.open(); _focused = 0; panel.refresh()

func _close_journal() -> void:
	_journal_page.hide(); _home_page.show(); _set_card(true)
	_focused = _focus_list().find(journal_button)
	journal_button.grab_focus(); panel.refresh()

func _journal_open() -> bool:
	return _journal_page != null and _journal_page.visible


func _focus_list() -> Array:
	if _journal_open(): return _journal_page.controls
	if _context_page != null and _context_page.visible: return _context_page.controls
	if _provider_page!=null and _provider_page.visible:return _provider_page.controls
	if _credits_open(): return _credits_page.focusables()
	if _settings_open(): return _settings_ui.focusables()
	if _opening_open(): return _opening_buttons + [_opening_back]
	if _load_open(): return _browser.focusables()
	return [enter_button, new_game_button, load_button, journal_button, settings_button, credits_button, quit_button]

func _place_panel() -> void:
	panel.global_transform = _panel_spot()


## Where the panel stands: home's spot, or (desktop pages) nearer and in the middle.
func _panel_spot() -> Transform3D:
	if overlay_host != null:
		# Level in front of the eyes, a little left and low so the view stays in sight.
		var facing := Basis(Vector3.UP, camera.global_rotation.y)
		var offset := _page_spot() if _forward else Vector3(-0.95, -0.2, -2.3)
		return Transform3D(facing, camera.global_position + facing * offset)
	return Transform3D(camera.global_transform.basis, camera.global_transform * (_page_spot() if _forward else HOME_SPOT))


## A desktop page straight ahead, near enough to fill PAGE_FILL of the view's height (or most of
## its width, in a narrow window).
func _page_spot() -> Vector3:
	var half_tall := tan(deg_to_rad(camera.fov) * 0.5)
	var window := Vector2(get_viewport().get_visible_rect().size)
	var metres := Vector2(panel.pixels) * PANEL.PIXEL_SIZE
	var away := maxf(metres.y / (2.0 * PAGE_FILL * half_tall), metres.x / (2.0 * 0.95 * half_tall * window.x / maxf(1.0, window.y)))
	return Vector3(0.0, -0.01, -away)

func recenter() -> void:
	if overlay_host != null:
		_place_panel(); return
	if xr_origin == null: return
	# Recenter the spatial menu; the baked world retains its stable heading.
	_place_panel()

func _request_asset(path: String, kind: String) -> void:
	var error := ResourceLoader.load_threaded_request(path, "PackedScene")
	if error != OK:
		_load_failed(kind)
		return
	_request = path
	_request_kind = kind
	if path not in _asset_requests: _asset_requests.append(path)

func _poll_asset() -> void:
	if _request.is_empty(): return
	var progress: Array = []
	var state := ResourceLoader.load_threaded_get_status(_request, progress)
	if state == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		var fraction := float(progress[0]) if not progress.is_empty() else 0.0
		if is_instance_valid(_cover):
			# The loader reports in a few big steps (0%, then about 40% until it is done): a slow
			# creep keeps the bar moving meanwhile. The title's part is the first half.
			var creep := 1.0 - exp(-float(Time.get_ticks_msec() - _cover_raised) / 14000.0)
			_cover.set_progress(0.03 + 0.42 * maxf(fraction, creep), true)
			# Past about 40% the bar barely moves on a slow machine: say it is still working, once.
			if maxf(fraction, creep) > 0.4 and not _slow_note:
				_slow_note = true
				_cover.show_note("Still loading… this can take a minute on slower computers.")
			return
		status.text = "Entering Equestria… %d%%" % int(fraction * 100) if not progress.is_empty() else "Entering Equestria…"
		panel.refresh()
		return
	var path := _request
	var kind := _request_kind
	_request = ""
	if state != ResourceLoader.THREAD_LOAD_LOADED:
		if state == ResourceLoader.THREAD_LOAD_FAILED: ResourceLoader.load_threaded_get(path)
		_asset_requests.erase(path)
		_load_failed(kind)
		return
	var packed := ResourceLoader.load_threaded_get(path) as PackedScene
	_asset_requests.erase(path)
	if packed == null:
		_load_failed(kind)
		return
	_hand_off(packed)

var _download: Node
var _slow_note := false

func _installation_problem() -> String:
	return PACKS.installation_problem(OS.has_feature("android") and OS.has_feature("template"), ResourceLoader.exists)

func _start_music() -> void:
	if _music != null: return
	var stream := THEME.duplicate() as AudioStreamOggVorbis
	stream.loop = true
	_music = AudioStreamPlayer.new(); _music.name = "TitleMusic"; _music.stream = stream
	Settings.route(_music, "Music")
	add_child(_music); _music.play()

func _fade_music() -> void:
	if _music == null or not _music.playing: return
	create_tween().tween_property(_music, "volume_db", -40.0, THEME_FADE)

func _finish_scenery() -> void:
	_start_music()   # a title without the launch card still plays it
	var problem := _installation_problem()
	ready_for_entry = problem.is_empty()
	enter_button.disabled = not ready_for_entry
	new_game_button.disabled = not ready_for_entry
	load_button.disabled = not ready_for_entry
	if not ready_for_entry: _focused = _focus_list().find(settings_button) # Settings stays usable while data is absent.
	_focus_button(0)
	status.text = problem
	# The game refused a world (scenario mods) and came back here: say why, once.
	if problem.is_empty() and not SCENARIO.notice.is_empty():
		status.text = SCENARIO.notice; SCENARIO.notice = ""
	panel.refresh()
	# Quest: fetch this version's data from its GitHub release, then reload the title with it.
	if not ready_for_entry and OS.has_feature("android") and _download == null:
		_download = preload("res://world/ui/quest_data_download.gd").new()
		add_child(_download)
		_download.progress.connect(func(text: String) -> void: status.text = text; panel.refresh())
		_download.finished.connect(func() -> void: get_tree().reload_current_scene.call_deferred())
		_download.start()
	print("TITLE READY phase=%s hours=%.2f spatial_panel=true xr=%s" % [phase.name, phase.hours, xr_active] if ready_for_entry else "TITLE DATA MISSING: gameplay entry disabled")

func _load_failed(kind: String) -> void:
	entering = false
	ready_for_entry = true
	enter_button.disabled = false
	_lower_cover()
	if _opening_open(): _close_opening()
	status.text = "Could not enter. Please try again."
	if _load_open(): _browser.set_status(status.text)
	panel.refresh()
	push_warning("[title] Could not load %s" % kind)

func enter_game() -> void:
	if is_instance_valid(_setup_window): return
	if entering or not ready_for_entry: return
	if not bool(Settings.get_value("setup/completed")):
		_provider_page.setup_mode = true; _open_provider(); return
	_fade_music()
	if not _staged and game_scene == GAME:
		# The same entry the home page previews and every list shows first.
		var newest := CATALOGUE.newest(_catalogue())
		_setup_start = newest.is_empty()
		if not newest.is_empty():
			var saves := _save_api()
			if saves == null or not saves.stage(newest):
				var problem: String = str(saves.get("last_problem")) if saves != null and saves.get("last_problem") is String else ""
				status.text = ("The most recent save cannot load: %s. Use Load game to choose another." % problem) if not problem.is_empty() else "The most recent save could not be loaded. Use Load game to choose another."
				panel.refresh()
				return
			_staged = true
			_destination = _trip_of(newest)
	if _setup_start and ready_for_entry:
		_setup_start = false
		_start_new_game(0)
		return
	if entering or not ready_for_entry: return
	entering = true
	enter_button.disabled = true
	status.text = "Entering Equestria…"
	panel.refresh()
	if overlay_host != null:
		if _staged:
			# A different world (new game, another save): boot it fresh, no title again.
			get_tree().change_scene_to_file.call_deferred(GAME)
		else:
			overlay_host.continue_game()
		return
	_raise_cover()
	# Nothing from the world scene is requested until this explicit action.
	_request_asset(game_scene, "game")


## The loading screen (world/ui/loading_cover.gd) fades in over the menu: the logo, the world
## being entered and a bar, which the game's own cover carries on after the scene change.
func _raise_cover() -> void:
	if is_instance_valid(_cover): return
	COVER.trip = {}
	_cover = COVER.new(); _cover.name = "EntryCover"
	add_child(_cover)
	_cover.setup(camera, xr_active)
	_cover.show_trip(str(_destination.get("title", "")), str(_destination.get("line", "")), str(_destination.get("icon", "")), _destination.get("tint", MENU_STYLE.FAINT))
	_cover.show_text("Entering Equestria…")
	_cover.set_progress(0.03)
	_cover.fade_in(0.0 if MENU_STYLE.still() else 0.45)
	_cover_raised = Time.get_ticks_msec()
	# The menu's logo sprite draws over a headset's cover sphere: it fades with the menu.
	if _logo != null:
		_logo_fade = create_tween()
		_logo_fade.tween_property(_logo, "modulate:a", 0.0, 0.45)


func _lower_cover() -> void:
	if is_instance_valid(_cover): _cover.finish()
	_cover = null
	if _logo_fade != null: _logo_fade.kill()
	if _logo != null: _logo.modulate.a = 1.0


## What the loading screen says about a save: its world, then where and when in it.
func _trip_of(entry: Dictionary) -> Dictionary:
	var bits: Array[String] = []
	if not str(entry.get("place", "")).is_empty(): bits.append(str(entry.place))
	bits.append(CATALOGUE.game_time_text(entry))
	return {"title": str(entry.get("world_name", "")), "line": " · ".join(bits), "icon": str(entry.get("world_icon", "")),
		"tint": MENU_STYLE.SWATCHES[int(entry.get("world_color", 0)) % MENU_STYLE.SWATCHES.size()]}


## The world is loaded. Nothing is drawn from the scene change until the game's own cover is up
## (half a minute on a slow machine), so the cover first shows that step, fully faded in, for a
## couple of frames (_step_hand_off()). Frames are counted in _process: the shutdown waits
## (world/shutdown_waits.gd) stay released after a game returns to the title.
func _hand_off(packed: PackedScene) -> void:
	if not is_instance_valid(_cover):
		set_process(false)
		_finish_entry.call_deferred(packed)
		return
	_packed = packed
	_hand_off_frames = 0
	_cover_wait = 0.0
	_cover.set_progress(0.5, true)
	_cover.show_text("Setting up the world…")
	_cover.show_note("This part can take a little while.")


func _step_hand_off(delta: float) -> void:
	_hand_off_frames += 1 if is_instance_valid(_cover) and _cover.is_settled() else 0
	_cover_wait += delta
	if _hand_off_frames < 3 and _cover_wait < 2.0: return
	var packed := _packed
	_packed = null
	set_process(false)
	_finish_entry.call_deferred(packed)

func _finish_entry(packed: PackedScene) -> void:
	_restore_clock()
	# The world script is first loaded after entry, never while the title idles.
	if game_scene == GAME:
		var game_script := load(GAME_SCRIPT) as GDScript
		if game_script != null: game_script.set("title_mode", false)
	var error := get_tree().change_scene_to_packed(packed)
	if error != OK:
		set_process(true)
		_load_failed("game")

func _process(delta: float) -> void:
	_bottom_lines()
	if _card_active:
		_card_step(delta); return
	if panel == null: return
	if _packed != null:
		_step_hand_off(delta); return
	_poll_asset()
	if is_instance_valid(_setup_window): return
	if not xr_active: return
	if _recenter_wait > 0:
		_recenter_wait -= delta
		if _recenter_wait <= 0: recenter()
	# Seated: no controllers. Pointing them every frame would clear the mouse hover (point_at
	# (-1, -1)), so the mouse path in _input drives the panel instead.
	if seated: return
	_stick_wait = maxf(0, _stick_wait - delta)
	if _owner != null and not _owner.get_has_tracking_data():
		panel.point_at(Vector2(-1, -1))
		panel.press(false)
		_owner = null
	var hit := Vector2(-1, -1)
	for controller in controllers:
		var ray: Node3D = _controller_pointers[controller]
		if not controller.get_has_tracking_data():
			ray.hide()
			continue
		var stick := controller.get_vector2("primary")
		if absf(stick.y) > 0.65 and _stick_wait <= 0:
			_focus_button(1 if stick.y < 0 else -1)
			_stick_wait = 0.3
		var candidate: Vector2 = panel.ray_to_pixel(controller.global_position, -controller.global_basis.z)
		if candidate.x >= 0: ray.aim(controller.global_position, panel.pixel_to_world(candidate))
		else: ray.hide()
		if _owner != null and controller != _owner: continue
		if candidate.x >= 0 and hit.x < 0:
			hit = candidate
	panel.point_at(hit)

func _focus_button(step: int) -> void:
	var buttons: Array = _focus_list()
	if buttons.is_empty(): return
	_focused = wrapi(_focused + step, 0, buttons.size())
	var button: Control = buttons[_focused]
	if button is Button and button.disabled:
		_focused = wrapi(_focused + (1 if step >= 0 else -1), 0, buttons.size())
		button = buttons[_focused]
	button.grab_focus()
	panel.refresh()

func _controller_pressed(action: StringName, controller: XRController3D) -> void:
	if panel == null or _card_active or entering or is_instance_valid(_setup_window): return
	if action == &"primary_click": recenter()
	if action == &"grip_click" and _provider_page.visible:_close_provider();return
	if action == &"grip_click" and _context_page != null and _context_page.visible: _close_context(); return
	if action == &"grip_click" and _journal_open(): _journal_page.back(); return
	if action == &"grip_click" and _settings_open(): _close_settings(); return
	if action == &"grip_click" and _credits_open(): _close_credits(); return
	if action == &"grip_click" and _load_open():
		if not _browser.back(): _close_load()
		return
	if action == &"grip_click" and _opening_open(): _close_opening(); return
	if action != &"trigger_click" or _owner != null: return
	if not controller.get_has_tracking_data(): return
	var pixel: Vector2 = panel.ray_to_pixel(controller.global_position, -controller.global_basis.z)
	if pixel.x >= 0:
		_owner = controller
		panel.point_at(pixel)
		panel.press(true)

func _controller_released(action: StringName, controller: XRController3D) -> void:
	if action == &"trigger_click" and _owner == controller:
		panel.point_at(panel.ray_to_pixel(controller.global_position, -controller.global_basis.z) if controller.get_has_tracking_data() else Vector2(-1, -1))
		panel.press(false)
		_owner = null

func _input(event: InputEvent) -> void:
	if panel == null or _card_active or entering or is_instance_valid(_setup_window): return
	if ((_provider_page!=null and _provider_page.visible) or (_settings_open() and _settings_ui.current_tab() == "AI Settings")) and event is InputEventKey:
		if event.pressed and not event.echo and event.keycode==KEY_ESCAPE:
			if _settings_open(): _close_settings()
			else: _close_provider()
		elif event.pressed and not event.echo and event.keycode==KEY_TAB:_focus_button(-1 if event.shift_pressed else 1)
		else:panel.send_key(event)
		get_viewport().set_input_as_handled();return
	# The journal's picture title takes typed keys, also in a room-scale headset.
	if _journal_open() and _journal_page.typing() and event is InputEventKey:
		if event.pressed and not event.echo and event.keycode == KEY_ESCAPE: _journal_page.back()
		else: panel.send_key(event)
		get_viewport().set_input_as_handled(); return
	if _settings_open() and event is InputEventKey and not _settings_ui.capturing.is_empty():
		panel.send_key(event); get_viewport().set_input_as_handled(); return
	if xr_active and not seated:return
	if event is InputEventMouseMotion or event is InputEventMouseButton:
		var pixel: Vector2 = panel.ray_to_pixel(camera.project_ray_origin(event.position), camera.project_ray_normal(event.position))
		panel.point_at(pixel)
		if pointer != null:
			pointer.visible = pixel.x >= 0
			if pointer.visible: pointer.global_position = panel.pixel_to_world(pixel)
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			panel.press(event.pressed)
		elif event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_RIGHT] and pixel.x >= 0:
			# Lists (settings, saves) scroll with the wheel; a right click opens a save's or a
			# world's menu (world/ui/save_browser.gd).
			var wheel := event.duplicate() as InputEventMouseButton
			wheel.position = pixel; wheel.global_position = pixel
			panel.viewport.push_input(wheel, true); panel.refresh()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		if event.pressed and not event.echo and event.keycode in [KEY_UP, KEY_DOWN, KEY_TAB]:
			_focus_button(1 if event.keycode != KEY_UP else -1)
		elif event.pressed and not event.echo and event.keycode == KEY_HOME and camera is XRCamera3D:
			# Seated VR: Home re-centres the view, then the menu in front of it.
			XRServer.center_on_hmd(XRServer.RESET_BUT_KEEP_TILT, false)
			recenter()
		elif event.pressed and not event.echo and _context_page != null and _context_page.visible and event.keycode == KEY_ESCAPE:
			_close_context()
		elif event.pressed and not event.echo and _journal_open() and event.keycode == KEY_ESCAPE:
			_journal_page.back()
		elif event.pressed and not event.echo and _settings_open() and event.keycode == KEY_ESCAPE:
			_close_settings()
		elif event.pressed and not event.echo and _credits_open() and event.keycode == KEY_ESCAPE:
			_close_credits()
		elif event.pressed and not event.echo and _load_open() and event.keycode == KEY_ESCAPE:
			if not _browser.back(): _close_load()
		elif event.pressed and not event.echo and _opening_open() and event.keycode == KEY_ESCAPE:
			_close_opening()
		else:
			panel.send_key(event)
		get_viewport().set_input_as_handled()

func _quit() -> void:
	if _exit_requested: return
	_exit_requested = true
	get_tree().quit()

func _restore_clock() -> void:
	if _clock.is_empty(): return
	# Child exit notifications precede ours. Disconnect the presentation sky before
	# restoring shared time, including when the window closes during loading.
	var sky := get_node_or_null("WorldEnvironment")
	if sky != null:
		var callback := Callable(sky, "_on_time_changed")
		if TimeOfDay.time_changed.is_connected(callback): TimeOfDay.time_changed.disconnect(callback)
	TimeOfDay.day = _clock.day
	TimeOfDay.hours = _clock.hours
	TimeOfDay.release("title")
	# The player's own FPS cap (Settings), not whatever the menu found at start.
	Engine.max_fps = Settings.fps_cap()
	_clock.clear()

func _exit_tree() -> void:
	_restore_clock()
	# Collect a requested resource even when the window closes mid-load.
	for path in _asset_requests:
		if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED or ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS or ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_FAILED:
			ResourceLoader.load_threaded_get(path)
	_asset_requests.clear(); _request = ""
