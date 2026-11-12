extends Window
## A real desktop window for the first-run AI setup on a flat screen. In a headset the title keeps
## that setup on its panel with the on-panel keyboard (world/ui/title_screen.gd _open_provider).
var page: Control

func _init() -> void:
	visible = false
	force_native = true
	title = "Home: Equestria — AI Settings"
	size = Vector2i(900, 840)
	min_size = Vector2i(760, 500)
	transient = true
	exclusive = true
	initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN

func open(settings_page: Control) -> void:
	page = settings_page
	# The menus' twilight sky (world/ui/menu_card.gd), edge to edge in its own window.
	var background: Control = preload("res://world/ui/menu_card.gd").new(); background.radius = 0.0; background.inset = 0.0; background.glow = 0.0
	add_child(background); background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.reparent(self); page.panel = self
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.setup_mode = true
	# Fit laptop displays while retaining scrolling and readable text.
	if DisplayServer.get_name() != "headless":
		var available := DisplayServer.screen_get_usable_rect(get_tree().root.current_screen).size
		size = Vector2i(mini(900, available.x - 40), mini(840, available.y - 80))
	popup_centered(size)
	page.open()

func refresh() -> void:
	pass # Native windows redraw their controls directly.
