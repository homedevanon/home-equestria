extends CanvasLayer
## Desktop/live editor map. The same atlas can later be hosted by a VR wrist viewport.
## Dressed like the menus (world/ui/menu_style.gd): the twilight card around the map, themed
## toolbar, drop-downs and tooltips (2026-10-27: "tooltips or the save F6 here are a bit ugly").
signal expanded_changed(open: bool)
const MAP_VIEW := preload("res://world/ui/world_map_view.gd")
const STYLE := preload("res://world/ui/menu_style.gd")
const ICON := preload("res://world/ui/menu_icon.gd")
const CARD := preload("res://world/ui/menu_card.gd")
## The card's glow reaches this far outside the panel.
const GLOW := 10.0
var tracked: Node3D
var map: Control
var expanded := false
var preferences_path := "user://world_map.cfg"
var panel: Panel
## Wraps onto more rows when the window is too narrow for one (_toolbar_height()).
var toolbar: HFlowContainer
var title: Label
var status: Label
var ponies: OptionButton
var _pony_menu_ids: Array = []
var _place_menu_rows: Array = []
var places: OptionButton
var keep_zoom: CheckButton
var whole_map: Button
var _root: Control
var _card: Control
var _timer := 0.0
var _pony_marker_clock := 0.0
var _previous_mouse_mode := Input.MOUSE_MODE_VISIBLE
var _selected: Dictionary = {}
## Rollback switch (0.1.0 perf pass, 2026-10-31): the map's ~380 canvas draw calls went out every
## frame although the map redraws a few times a second at most; it now renders into a texture on
## the frames it redraws. false draws it straight onto the HUD layer as before.
const CACHED_MAP := true
var _map_host: SubViewportContainer
var _map_viewport: SubViewport

func _map_redrawn() -> void:
	if _map_viewport != null: _map_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func _ready() -> void:
	layer = 110
	_root = Control.new(); add_child(_root); _root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = STYLE.theme()
	panel = Panel.new(); _root.add_child(panel)
	panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_card = CARD.new(); _card.radius = 16.0; _card.inset = GLOW; _card.glow = 0.3
	panel.add_child(_card)
	title = STYLE.label("", "Heading", 26)
	panel.add_child(title)
	map = MAP_VIEW.new(); map.preferences_path = preferences_path
	if CACHED_MAP:
		# Drawn into its own texture, re-rendered only on the frames the map redraws (its draw
		# signal); otherwise the window shows the last image. Themes do not cross into a
		# SubViewport, so the map carries the menu theme itself.
		_map_host = SubViewportContainer.new(); _map_host.stretch = true; panel.add_child(_map_host)
		_map_viewport = SubViewport.new(); _map_viewport.transparent_bg = true
		_map_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		_map_host.add_child(_map_viewport)
		map.theme = STYLE.theme()
		_map_viewport.add_child(map)
		map.draw.connect(_map_redrawn)
	else:
		panel.add_child(map)
	map.marker_selected.connect(func(marker): _selected = marker; _update_status())
	map.expand_requested.connect(func(): set_expanded(true))
	toolbar = HFlowContainer.new(); panel.add_child(toolbar)
	toolbar.add_theme_constant_override("h_separation", 6); toolbar.add_theme_constant_override("v_separation", 6)
	# Its buttons take clicks; the space around them is the map's (its rect can lag a reflow).
	toolbar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_button("−", func(): map.zoom_at(0.8, map.size * 0.5)).tooltip_text = "Zoom out"
	_button("+", func(): map.zoom_at(1.25, map.size * 0.5)).tooltip_text = "Zoom in"
	whole_map = _button("Whole map", func(): map.frame_world(), "globe")
	_button("Follow me", func(): map.follow(), "pony")
	keep_zoom = CheckButton.new(); keep_zoom.text = "Keep zoom"; keep_zoom.focus_mode = Control.FOCUS_NONE
	keep_zoom.add_theme_font_size_override("font_size", 16)
	keep_zoom.tooltip_text = "Remember this zoom when closing, reopening or restarting. You can still adjust it with the wheel or +/−."
	toolbar.add_child(keep_zoom)
	keep_zoom.toggled.connect(func(value): map.set_zoom_locked(value))
	map.zoom_lock_changed.connect(_update_zoom_lock)
	_update_zoom_lock(map.zoom_locked)
	places = OptionButton.new(); places.custom_minimum_size.x = 190; places.clip_text = true
	places.add_theme_font_size_override("font_size", 16); places.focus_mode = Control.FOCUS_NONE
	toolbar.add_child(places); places.add_item("Find a place…")
	var sorted: Array = map.markers.duplicate(); sorted.sort_custom(func(a,b): return a.name < b.name)
	for marker in sorted:
		places.add_item(marker.name); places.set_item_metadata(places.item_count - 1, marker)
	places.item_selected.connect(func(index):
		if index == 0: return
		var marker: Dictionary = places.get_item_metadata(index)
		map.select_marker(marker.id); map.center = marker.position; map.following = false
		if not map.zoom_locked: map.zoom = maxf(map.zoom, 1.8 if marker.get("local_place", false) else 0.15)
		map.queue_redraw())
	ponies=OptionButton.new(); ponies.custom_minimum_size.x=180; ponies.clip_text=true
	ponies.add_theme_font_size_override("font_size", 16); ponies.focus_mode = Control.FOCUS_NONE
	toolbar.add_child(ponies); ponies.add_item("Find a pony…")
	ponies.item_selected.connect(func(index):
		if index==0: return
		map.select_marker(str(ponies.get_item_metadata(index)))
		var marker: Dictionary=map.selected_marker()
		if marker.is_empty(): return
		map.center=marker.position; map.following=false
		if not map.zoom_locked: map.zoom=maxf(map.zoom,1.8)
		map.queue_redraw())
	_button("Close · M", func(): set_expanded(false), "close")
	status = STYLE.label("", "", 14); status.clip_text = true
	panel.add_child(status)
	_root.resized.connect(_layout); _layout(); _update_status()

func _button(text: String, callback: Callable, icon := "") -> Button:
	var button := Button.new(); button.text = text; button.focus_mode = Control.FOCUS_NONE
	button.theme_type_variation = "Chip"
	if not icon.is_empty(): button.icon = ICON.texture(icon, 16)
	button.pressed.connect(callback); toolbar.add_child(button)
	return button

func _update_zoom_lock(locked: bool) -> void:
	keep_zoom.set_pressed_no_signal(locked)
	whole_map.disabled = locked
	whole_map.tooltip_text = "Turn off Keep zoom to show the whole map." if locked else ""

func bind(target: Node3D) -> void:
	tracked = target; update_location()

func update_location() -> void:
	if not is_instance_valid(tracked) or not tracked.is_inside_tree() or map == null: return
	map.set_location(tracked.global_position, -tracked.global_basis.z)
	if _pony_marker_clock <= 0.0:
		map.update_ponies(tracked)
		_pony_marker_clock = 0.5 if expanded else 2.0
	# The pony finder lives on the toolbar, which only shows when expanded.
	if expanded:
		_update_pony_menu()
		_update_place_menu()
	_update_status()

func _process(delta: float) -> void:
	var profiling := preload("res://tools/crowd_cpu_profile.gd")
	if not profiling.enabled:
		_profiled_process(delta)
		return
	var started := Time.get_ticks_usec()
	_profiled_process(delta)
	profiling.record("world_map_hud", started)


func _profiled_process(delta: float) -> void:
	_pony_marker_clock -= delta
	_timer += delta
	if _timer < 0.1: return
	_timer = 0; update_location()

func set_expanded(open: bool) -> void:
	if open and get_meta("save_menu_open",false):return
	if expanded == open: return
	expanded = open
	_pony_marker_clock = 0.0
	if open:
		_previous_mouse_mode = Input.mouse_mode; Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_update_pony_menu()
	else:
		Input.mouse_mode = _previous_mouse_mode
		map.following = true
		map.save_preferences()
	map.compact = not open; map._dragging = false
	_layout()
	if open: map.frame_player()
	else: map.follow()
	expanded_changed.emit(open)

func contains_screen(point: Vector2) -> bool:
	return panel != null and panel.get_global_rect().has_point(point)

func _layout() -> void:
	var screen := get_viewport().get_visible_rect().size
	panel.size = Vector2(minf(1100, screen.x - 32), minf(760, screen.y - 32)) if expanded else Vector2(310, 248)
	panel.position = (screen - panel.size) * 0.5 if expanded else Vector2(screen.x - panel.size.x - 16, 16)
	_card.position = -Vector2.ONE * GLOW; _card.size = panel.size + Vector2.ONE * GLOW * 2.0
	# No title on the mini map (dev: "remove the LIVE MAP text").
	title.position = Vector2(16, 4); title.text = "Equestria"; title.visible = expanded
	toolbar.position = Vector2(14, 44); toolbar.visible = expanded
	var rows := _toolbar_height(panel.size.x - 28.0)
	toolbar.size = Vector2(panel.size.x - 28.0, rows)
	# The map under the toolbar's rows (one in a wide window, more in a narrow one), above the
	# status, sized now so that framing the world on opening fits it.
	var top := toolbar.position.y + maxf(38.0, rows) + 8.0 if expanded else 8.0
	if _map_host != null:
		_map_host.position = Vector2(8, top)
		_map_host.size = panel.size - Vector2(16, top + 38.0)
		map.position = Vector2.ZERO
	else:
		map.position = Vector2(8, top)
	map.size = panel.size - Vector2(16, top + 38.0)
	if not expanded and not map.zoom_locked: map.zoom = map.size.x / 4400.0
	status.position = Vector2(14, panel.size.y - 30); status.size = Vector2(panel.size.x - 28, 26)
	map.queue_redraw()


## How tall the toolbar's rows are at `width`, wrapped as its flow container wraps them (which
## it only does a frame later).
func _toolbar_height(width: float) -> float:
	var gap := float(toolbar.get_theme_constant("h_separation"))
	var row_gap := float(toolbar.get_theme_constant("v_separation"))
	var height := 0.0
	var row_width := -1.0
	var row_height := 0.0
	for child: Node in toolbar.get_children():
		var control := child as Control
		if control == null or not control.visible: continue
		var need := control.get_combined_minimum_size()
		if row_width >= 0.0 and row_width + gap + need.x <= width:
			row_width += gap + need.x; row_height = maxf(row_height, need.y)
			continue
		if row_width >= 0.0: height += row_height + row_gap
		row_width = need.x; row_height = need.y
	return height + row_height

func _update_status() -> void:
	if status == null: return
	if not map.has_position: status.text = "Waiting for live position…"; return
	var p: Vector2 = map.live_position
	if expanded and not _selected.is_empty():
		_selected=map.selected_marker()
		if _selected.is_empty():
			status.text="Pony is no longer assigned"; return
		var distance: float = p.distance_to(_selected.position)
		var text := "%.2f km" % (distance / 1000) if distance >= 1000 else "%d m" % roundi(distance)
		status.text = "%s · X %.1f  Z %.1f · %s straight-line" % [str(_selected.name)+(" · "+str(_selected.tracking) if _selected.has("tracking") else ""), _selected.position.x, _selected.position.y, text]
	else:
		# Performance overhaul 2026-11-21: the nearest place (a walk over every region's footprint,
		# about 70 us, ten times a second) is looked up again only after a metre of travel; the
		# name can change at most a metre late. Rollback: NEAREST_REUSE = false.
		if not NEAREST_REUSE or _nearest_name.is_empty() or p.distance_squared_to(_nearest_at) > 1.0:
			_nearest_name = str(WorldLayout.nearest(Vector3(p.x, 0, p.y)).get("name", "Equestria"))
			_nearest_at = p
		status.text = "%s · X %.0f  Z %.0f" % [_nearest_name, p.x, p.y]

const NEAREST_REUSE := true
var _nearest_name := ""
var _nearest_at := Vector2.INF

func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed: return
	if get_viewport().gui_get_focus_owner() is LineEdit: return
	if event.physical_keycode == KEY_M:
		set_expanded(not expanded); get_viewport().set_input_as_handled()
	elif expanded and event.physical_keycode == KEY_ESCAPE:
		set_expanded(false); get_viewport().set_input_as_handled()


func _update_pony_menu() -> void:
	if ponies==null: return
	var sorted: Array=map.pony_markers.duplicate()
	sorted.sort_custom(func(a,b): return a.name<b.name)
	var ids: Array=sorted.map(func(row): return row.id)
	if ids==_pony_menu_ids: return
	_pony_menu_ids=ids; ponies.clear(); ponies.add_item("Find a pony…")
	for row: Dictionary in sorted:
		ponies.add_item(row.name); ponies.set_item_metadata(ponies.item_count-1,row.id)


func _update_place_menu() -> void:
	if places == null: return
	var sorted: Array = map.markers.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary): return a.name < b.name)
	var rows: Array = sorted.map(func(row: Dictionary): return [row.id, row.name, row.position])
	if rows == _place_menu_rows: return
	_place_menu_rows = rows
	places.clear(); places.add_item("Find a place…")
	for marker: Dictionary in sorted:
		places.add_item(marker.name)
		places.set_item_metadata(places.item_count - 1, marker)
