extends Node3D
## First-visit spa guide (dev 2026-10-29: "make the spa have popups/pointers the very first time so
## you know whats happening"). While the player is inside the spa, each step shows once: a short
## instruction (desktop banner at the top of the screen, a head-locked panel in a headset, the
## arrival tutorial's look) and the tutorial's gold arrow over what to use. A step ends when the
## player has really done it (spa_customers.gd signals), and finished steps are remembered in
## user://spa_guide.cfg, so they never come back on this install.
const SAVE_PATH := "user://spa_guide.cfg"
const GOLD := Color("edd6a2")
const CHECK_SECONDS := 0.25
## The pay note stays this long, then counts as seen.
const PAID_SECONDS := 7.0
const TITLES := {"welcome": "Ponyville Day Spa", "pick_file": "Hoof filing", "pick_file_case": "Hoof filing",
	"pick_file_room": "Hoof filing", "file": "Hoof filing",
	"rub": "Hoof massage", "wings": "Wing care", "paid": "Paid!"}

var spa: Node
var hands: Node
var game: Node
var step := ""
var _seen := {}
var _check := 0.0
var _paid_left := 0.0
var _arrow: Node3D
var _panel: Node3D
var _panel_title: Label3D
var _panel_text: Label3D
var _layer: CanvasLayer
var _banner: PanelContainer
var _banner_title: Label
var _banner_text: Label


func setup(controller: Node, player_hands: Node, host: Node) -> void:
	spa = controller
	hands = player_hands
	game = host
	name = "SpaGuide"
	var file := ConfigFile.new()
	if file.load(SAVE_PATH) == OK:
		for key: String in file.get_section_keys("seen") if file.has_section("seen") else PackedStringArray():
			_seen[key] = true
	spa.client_arrived.connect(func(_id: String, _name: String): _finish("welcome"))
	spa.service_finished.connect(_service_finished)
	spa.bits_paid.connect(_paid)
	_arrow = _make_arrow(); add_child(_arrow); _arrow.hide()


func _service_finished(_id: String, service: String, _bits: int) -> void:
	if service == "file": _finish("pick_file")
	_finish(service)


func _paid(_id: String, _amount: int, _at: Vector3, _what: String) -> void:
	if not _seen.has("paid") and _paid_left <= 0.0: _paid_left = PAID_SECONDS


func _finish(id: String) -> void:
	if _seen.has(id): return
	_seen[id] = true
	var file := ConfigFile.new()
	file.load(SAVE_PATH)
	file.set_value("seen", id, true)
	file.save(SAVE_PATH)
	if step == id or step.begins_with(id + "_"): _show("")


func _xr() -> bool:
	return is_instance_valid(game) and game.get("xr_active") == true


func _camera() -> Camera3D:
	return game._find_camera(game.player) if is_instance_valid(game) and game.has_method("_find_camera") else null


## The first unseen step whose moment it is, and where its arrow points (INF: none).
func _current() -> Array:
	var camera := _camera()
	var venue: Node3D = spa.get("_venue") as Node3D
	if camera == null or not is_instance_valid(venue) or not venue.is_inside(camera.global_position): return ["", Vector3.INF]
	if _paid_left > 0.0: return ["paid", Vector3.INF]
	# Walk-ins soaking on their own (day plans) are not Anon's clients: the bell is still the start.
	if not _seen.has("welcome") and spa.is_open_now() and spa.anon_clients().is_empty() and hands.bell_node != null:
		return ["welcome", hands._bell_top() + Vector3.UP * 0.12]
	var filing: Array = spa.filing_targets(Vector3.INF)
	if not filing.is_empty():
		var holding: bool = hands.held_file("desktop" if not _xr() else "left") != null or (_xr() and hands.held_file("right") != null)
		if not holding and not _seen.has("pick_file"): return pick_target()
		if holding and not _seen.has("file"): return ["file", Vector3(filing[0].tip) + Vector3.UP * 0.2]
	var rubbing: Array = spa.rub_targets(Vector3.INF)
	if not rubbing.is_empty() and not _seen.has("rub"):
		return ["rub", Vector3(rubbing[0].bottom) + Vector3.UP * 0.25]
	var wings: Array = spa.wing_targets(Vector3.INF)
	if not wings.is_empty() and not _seen.has("wings"):
		var segments: Array = wings[0].wings
		var at: Vector3 = Vector3(segments[0][1]) + Vector3.UP * 0.25 if not segments.is_empty() else Vector3.INF
		return ["wings", at]
	return ["", Vector3.INF]


## The "pick up the file" step for the file the player really has (thread 43694970: the arrow
## pointed at an empty counter while the file was in the briefcase): the arrow over the file lying
## in the spa wherever it is; no arrow and "take it out of your briefcase" when it is stashed; no
## arrow and "make room" when there was no room to lay one. [step, arrow point or INF].
func pick_target() -> Array:
	var file: Dictionary = hands.file_status() if hands.has_method("file_status") else {}
	match str(file.get("where", "")):
		"loose":
			return ["pick_file", Vector3(file.point) + Vector3.UP * 0.15]
		"case":
			return ["pick_file_case", Vector3.INF]
		"full":
			return ["pick_file_room", Vector3.INF]
	return ["", Vector3.INF]


func _text(id: String) -> String:
	var xr := _xr()
	match id:
		"welcome":
			return "Ring the bell on the counter to open (09:00-19:00). Up to three ponies come in for hoof care." \
				+ ("" if xr else " Look at the bell and click.")
		"pick_file":
			return "Pick up the hoof file" + (" with GRIP." if xr else " with E.") \
				+ " Then go to the pony in the footbath: she lifts a front hoof for you."
		"pick_file_case":
			return "The hoof file is in your briefcase: take it out" + (" (turn your hand over, point at it and grip)." if xr else " (its hotbar number, or I for the briefcase).") \
				+ " Then go to the pony in the footbath: she lifts a front hoof for you."
		"pick_file_room":
			return "There is no room for the hoof file: put some of your things back in the briefcase, or free a briefcase slot, and it appears on the counter."
		"file":
			if xr: return "Rub the file back and forth across her raised hoof. Front hooves are filed here; back hooves are filed and massaged on the table."
			return "Aim at her raised hoof, hold the left mouse button and move the mouse left and right. Front hooves are filed here; back hooves are filed and massaged on the table."
		"rub":
			if xr: return "Rub the filed hoof slowly with your hand, from the hoof up her leg; slow and steady is best."
			return "Aim at the filed hoof or her leg, hold the left mouse button and drag slowly along it."
		"wings":
			if xr: return "Stroke her open wings slowly with your hand. Pinch a loose feather with the trigger and pull it out."
			return "Aim at her wing, hold the left mouse button and drag slowly. Click a loose feather and pull to pluck it."
		"paid":
			return "Bits go straight into your wallet. When everypony has left, ring the bell again."
	return ""


func _process(delta: float) -> void:
	if not is_instance_valid(spa) or not is_instance_valid(hands): return
	if _paid_left > 0.0:
		_paid_left -= delta
		if _paid_left <= 0.0: _finish("paid")
	_check -= delta
	var target := Vector3.INF
	if _check <= 0.0:
		_check = CHECK_SECONDS
		var current := _current()
		if current[0] != step: _show(current[0])
		target = current[1]
		_arrow.set_meta("target", target)
	elif _arrow.has_meta("target"):
		target = _arrow.get_meta("target")
	_arrow.visible = not step.is_empty() and target.is_finite()
	if _arrow.visible:
		_arrow.global_position = target + Vector3.UP * sin(Time.get_ticks_msec() * 0.004) * 0.02
		_arrow.rotation.y += delta * 1.6


func _show(id: String) -> void:
	step = id
	if not id.is_empty(): print("[spa guide] ", id)
	if _xr():
		if not is_instance_valid(_panel): _build_panel()
		if is_instance_valid(_panel):
			_panel_title.text = TITLES.get(id, ""); _panel_text.text = _text(id); _panel.visible = not id.is_empty()
	else:
		if not is_instance_valid(_banner): _build_banner()
		_banner_title.text = TITLES.get(id, ""); _banner_text.text = _text(id); _layer.visible = not id.is_empty()
		_layout_banner.call_deferred()


# ---------------------------------------------------------------- look (arrival_tutorial.gd's)

func _make_arrow() -> Node3D:
	var root := Node3D.new(); root.name = "SpaGuideArrow"
	var gold := StandardMaterial3D.new(); gold.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gold.albedo_color = Color("ffd75e"); gold.no_depth_test = true; gold.render_priority = 40
	var tip := MeshInstance3D.new(); var cone := CylinderMesh.new()
	cone.top_radius = 0.04; cone.bottom_radius = 0.0; cone.height = 0.06; cone.radial_segments = 4
	cone.material = gold; tip.mesh = cone; tip.position.y = 0.03; root.add_child(tip)
	var shaft := MeshInstance3D.new(); var stem := CylinderMesh.new()
	stem.top_radius = 0.012; stem.bottom_radius = 0.012; stem.height = 0.07; stem.radial_segments = 4
	stem.material = gold; shaft.mesh = stem; shaft.position.y = 0.095; root.add_child(shaft)
	for part: MeshInstance3D in [tip, shaft]: part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return root


func _build_panel() -> void:
	var camera := _camera()
	if camera == null: return
	_panel = Node3D.new(); _panel.name = "SpaGuidePanel"
	_panel.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.add_child(_panel)
	_panel.position = Vector3(0, .22, -1.15)
	var back := MeshInstance3D.new(); var quad := QuadMesh.new(); quad.size = Vector2(0.94, 0.30)
	var mat := StandardMaterial3D.new(); mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; mat.albedo_color = Color(0.06, 0.08, 0.1, 0.86)
	mat.no_depth_test = true; mat.render_priority = 41; quad.material = mat; back.mesh = quad
	back.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; _panel.add_child(back)
	_panel_title = _label(Vector3(0, 0.10, 0.002), 40, GOLD); _panel.add_child(_panel_title)
	_panel_text = _label(Vector3(0, -0.03, 0.002), 30, Color(0.95, 0.95, 0.92)); _panel.add_child(_panel_text)
	preload("res://world/ui/head_locked_hud.gd").attach(camera, _panel)


func _label(at: Vector3, size: int, colour: Color) -> Label3D:
	var label := Label3D.new(); label.position = at; label.pixel_size = 0.001; label.font_size = size
	label.font = preload("res://world/books/fonts/AtkinsonHyperlegible-Regular.ttf")
	label.outline_size = 2; label.modulate = colour; label.no_depth_test = true; label.render_priority = 42
	label.width = 850.0; label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _build_banner() -> void:
	_layer = CanvasLayer.new(); _layer.layer = 6; add_child(_layer)
	_banner = PanelContainer.new(); _banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.theme = preload("res://world/ui/readable_text_theme.gd").make()
	var style := StyleBoxFlat.new(); style.bg_color = Color(0.06, 0.08, 0.1, 0.84); style.set_corner_radius_all(8)
	style.content_margin_left = 22; style.content_margin_right = 22; style.content_margin_top = 12; style.content_margin_bottom = 14
	style.border_color = Color(GOLD, 0.6); style.set_border_width_all(2)
	_banner.add_theme_stylebox_override("panel", style); _layer.add_child(_banner)
	var column := VBoxContainer.new(); column.mouse_filter = Control.MOUSE_FILTER_IGNORE; _banner.add_child(column)
	_banner_title = Label.new(); _banner_title.add_theme_font_size_override("font_size", 26)
	_banner_title.add_theme_color_override("font_color", GOLD); _banner_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_text = Label.new(); _banner_text.add_theme_font_size_override("font_size", 20)
	_banner_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; _banner_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for label: Label in [_banner_title, _banner_text]: label.mouse_filter = Control.MOUSE_FILTER_IGNORE; column.add_child(label)
	get_viewport().size_changed.connect(_layout_banner)
	_layer.hide()


## Top centre, below the FPS corner (arrival_tutorial.gd keeps the same corner clear).
func _layout_banner() -> void:
	if not is_instance_valid(_banner): return
	var screen := get_viewport().get_visible_rect().size
	var width := maxf(1.0, minf(760.0, screen.x - 32.0))
	_banner.size = Vector2(width, 0.0)
	var top := 26.0
	if Rect2(Vector2((screen.x - width) * .5, top), _banner.size).intersects(Rect2(Vector2.ZERO, Vector2(420.0, 110.0))): top = 122.0
	_banner.position = Vector2((screen.x - width) * .5, top)


func _exit_tree() -> void:
	if is_instance_valid(_panel) and _panel.get_parent() != self: _panel.queue_free()
