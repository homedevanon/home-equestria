extends Node3D
## The opening is the tutorial (dev 2026-10-01): each thing Anon can do around him is shown once,
## with a floating arrow at what to use and a short instruction. Steps end when he has really
## done it: walk to the stump, put an apple in his briefcase, open the briefcase, take an apple
## out and eat it, try the wardrobe; once Twilight is there, see how a pony feels about him.
## Desktop shows the instruction as a banner at the top of the screen; a headset shows a panel
## fixed to the tracked camera, with physics interpolation disabled on the display.
signal step_done(id: String)
signal receipts_changed
const FOOD_SPAWN := preload("res://world/food/food_spawn.gd")
const IDENTITY := preload("res://world/inventory/item_identity.gd")
const RECOVERY_SECONDS := 8.0
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const APPLE := "apple"
const STEPS := ["walk", "stash", "briefcase", "eat", "clothes"]
const TITLES := {"walk": "Find your feet", "stash": "Pick something up", "briefcase": "Your briefcase",
	"eat": "Eat something", "clothes": "Change your clothes", "inspect": "How ponies feel about you",
	"talk": "Talk to her"}
const GOLD := Color("edd6a2")
var game: Node
var pocket: Node3D
var step := ""
var twilight: Node3D
var _seen_open := false
var _seen_at := 0.0
var receipts: Dictionary = {}
var _recovery_wait := 0.0
var _case_seen := false
var _clothes_seen := false
var _elapsed := 0.0
var _arrow: Node3D
var _panel: Node3D
var _panel_title: Label3D
var _panel_text: Label3D
var _layer: CanvasLayer
var _banner_title: Label
var _banner_text: Label
var _banner: PanelContainer
var _banner_map: Node
var _banner_layout_queued := false

func setup(host: Node, the_pocket: Node3D, saved_receipts: Dictionary = {}) -> void:
	game = host; pocket = the_pocket
	receipts = saved_receipts.duplicate(true)
	game.inventory.food_consumed.connect(_food_consumed)
	game.inventory.inventory.changed.connect(_inventory_changed)
	game.inventory.case.changed.connect(_observe_controls)
	game.inventory.case.dismissed.connect(_observe_controls)
	game.inventory.customizer.dismissed.connect(_observe_controls)
	game.inventory.customizer.visibility_changed.connect(_observe_controls)
	_inventory_changed()
	_observe_controls()
	name = "ArrivalTutorial"
	_arrow = _make_arrow(); add_child(_arrow); _arrow.hide()
	if game.xr_active: _build_panel()
	else: _build_banner()

var _last_feet := Vector3.INF
var _walked := 0.0
func start(id: String) -> void:
	step = id; _seen_open = false; _seen_at = 0.0; _elapsed = 0.0; _last_feet = _feet(); _walked = 0.0
	_refresh_text()
	print("[tutorial] ", id)

func stop() -> void:
	step = ""
	_arrow.hide()
	if is_instance_valid(_panel): _panel.hide()
	if is_instance_valid(_layer): _layer.hide()

# ---------------------------------------------------------------- what to do
func _text(id: String) -> String:
	var xr: bool = game.xr_active
	if id == "eat" and _holding_apple():
		return "Hold the apple up to your mouth to eat it." if xr else "Hold the left mouse button to eat the apple you are holding."
	if id == "eat" and xr and _apple_slot() >= 5:
		return "Flip up your LEFT hand and touch the briefcase button. Select the apple in the briefcase to equip it, then hold it to your mouth."
	if id == "eat" and not _has_carried_apple():
		if xr: return "Pick up an apple from the stump with GRIP, then hold it to your mouth to eat."
		return "Look at an apple on the stump and press E to put it in your briefcase. Then take it out and hold the left mouse button to eat."
	if xr:
		match id:
			"walk": return "Left stick to walk, right stick to turn. Walk over to the stump."
			"stash": return "Squeeze GRIP to pick up an apple. Turn a palm up, then release the apple over the briefcase icon or a RIGHT-hand slot to store it."
			"briefcase": return "Flip up your LEFT hand and touch the briefcase button with your right finger. Point at Close lid and pull TRIGGER when done."
			"eat": return "Flip up your RIGHT hand: five quick slots appear above it. Point at the apple and pull TRIGGER or squeeze GRIP, then hold it to your mouth to eat. Lower your hand to dismiss the slots."
			"clothes": return "Flip up your LEFT hand and touch the shirt button. Touch the wardrobe controls, then Save outfit or Cancel."
			"inspect": return "Flip up your LEFT hand and touch the eye button. Point at Twilight and pull TRIGGER to see how she feels about you."
			"talk": return "Answer her out loud: hold B or Y on a controller while you speak."
	# Desktop AnonPony trots and has a quick menu, not a wrist.
	var pony: bool = PLAYER_FORM.is_pony(PLAYER_FORM.active(get_tree())) if is_inside_tree() else false
	match id:
		"walk":
			if pony: return "W A S D to trot, Shift to gallop, Ctrl to walk slowly, the mouse to look around. Walk over to the stump."
			return "W A S D to walk, the mouse to look around. Walk over to the stump."
		"stash": return "Look at an apple and press E. It goes straight into your briefcase."
		"briefcase":
			if pony: return "Press I to open your briefcase and see what you carry (Tab brings up your quick menu, too). Press I again to close it."
			return "Press I to open your briefcase and see what you carry (Tab brings up your wrist menu, too). Press I again to close it."
		"eat":
			var slot := _apple_slot()
			if slot >= 0 and slot < 5: return "Press %d to take an apple out, then hold the left mouse button to eat it." % (slot + 1)
			return "Press I, click an apple in your briefcase and press Equip. Then hold the left mouse button to eat it."
		"clothes": return "Press U to open your wardrobe. Take your jacket off or change a colour, then Save outfit or Cancel."
		"inspect": return "Press J, then click Twilight to see how she feels about you. Press J again to close it."
		# M-ARR-05: after J the opening waits for him to answer her; nothing said what to do.
		"talk": return "Answer her: hold T while you speak, or press Enter, type, and press Enter again."
	return ""

func _refresh_text() -> void:
	var title: String = TITLES.get(step, "")
	if step == "walk" and is_inside_tree() and PLAYER_FORM.is_pony(PLAYER_FORM.active(get_tree())): title = "Find your hooves"
	var body := _text(step)
	if is_instance_valid(_panel_title): _panel_title.text = title; _panel_text.text = body; _panel.visible = not step.is_empty()
	if is_instance_valid(_banner_title): _banner_title.text = title; _banner_text.text = body; _layer.visible = not step.is_empty()
	if is_instance_valid(_banner): _queue_banner_layout()

# ---------------------------------------------------------------- has he done it?
func _physics_process(delta: float) -> void:
	if not is_instance_valid(game) or not is_instance_valid(game.inventory): return
	_observe_controls()
	_recovery_wait = maxf(0.0, _recovery_wait - delta)
	if step.is_empty(): return
	_elapsed += delta
	var inventory: Node = game.inventory
	var done := false
	match step:
		"walk":
			# He has to actually walk: a pony's eye can start within reach of the stump. Jumps
			# (a teleport, a reload) do not count as walking.
			var feet := _feet()
			var moved := _flat(feet, _last_feet) if _last_feet != Vector3.INF else 0.0
			if moved < 0.5: _walked += moved
			_last_feet = feet
			done = is_instance_valid(pocket) and _flat(feet, pocket.stump_top) < 1.7 and _walked > 0.6
		"stash":
			done = bool(receipts.get("stash", false))
		"briefcase":
			done = bool(receipts.get("briefcase", false))
		"eat":
			done = bool(receipts.get("eat", false))
			if int(_elapsed * 2.0) % 2 == 0: _refresh_text()   # the slot can change as he moves things
		"clothes":
			done = bool(receipts.get("clothes", false))
		"inspect":
			var inspector: Node = inventory.get("inspector")
			if inspector != null and inspector.get("selected") == twilight and twilight != null:
				if not _seen_open: _seen_at = _elapsed
				_seen_open = true
			done = _seen_open and inspector != null and (not bool(inspector.get("active")) or _elapsed - _seen_at > 12.0)
	if not done and step in ["stash", "eat"]: _recover_apple()
	if done:
		var finished := step
		step = ""
		_arrow.hide()
		_tick_sound()
		step_done.emit(finished)

func _tick_sound() -> void:
	preload("res://world/audio/interaction_sounds.gd").play_at(self, "select", _feet())

## Receipts are monotonic and recorded even before their instruction appears.
func _record(key: String) -> void:
	if bool(receipts.get(key, false)): return
	receipts[key] = true
	receipts_changed.emit()

func _food_consumed(id: String) -> void:
	if IDENTITY.canonical(id) == APPLE: _record("eat")

func _inventory_changed() -> void:
	if _apple_slot() >= 0: _record("stash")

func _observe_controls() -> void:
	if not is_instance_valid(game) or not is_instance_valid(game.inventory): return
	if game.inventory.case.visible and game.inventory.case.opened: _case_seen = true
	elif not game.inventory.case.visible and _case_seen: _record("briefcase")
	if game.inventory.customizer.opened: _clothes_seen = true
	elif _clothes_seen: _record("clothes")

## Only usable apples count. A saved dropped loan may be underneath the world or outside
## the pocket; it must not suppress the one replacement on the physical stump.
func _holding_apple() -> bool:
	for item: Node in game.inventory.held.values():
		if is_instance_valid(item) and IDENTITY.canonical(str(item.get_meta("item_id", ""))) == APPLE: return true
	return false

func _has_carried_apple() -> bool:
	return _apple_slot() >= 0 or _holding_apple()

func _apple_available() -> bool:
	if _has_carried_apple(): return true
	var candidates: Array[Node] = get_tree().get_nodes_in_group("world_food")
	for item: Node in game.inventory.loose.values():
		if is_instance_valid(item) and not candidates.has(item): candidates.append(item)
	for item: Node in candidates:
		if not item is Node3D or item.is_queued_for_deletion(): continue
		if IDENTITY.canonical(str(item.get_meta("item_id", ""))) != APPLE: continue
		if item.has_meta("food_for_sale") and bool(item.get_meta("food_for_sale")): continue
		var at: Vector3 = item.global_position
		if not at.is_finite() or _flat(at, pocket.stump_top) > 4.2: continue
		var floor_y: float = pocket.stump_top.y - 0.5
		if is_instance_valid(WorldTerrain.instance):
			var terrain_y: float = WorldTerrain.instance.height_at(at)
			if is_finite(terrain_y): floor_y = terrain_y
		if at.y >= floor_y - 0.08 and at.y <= pocket.stump_top.y + 1.5: return true
	return false

func _recover_apple() -> void:
	if not step in ["stash", "eat"] or bool(receipts.get(step, false)): return
	if _recovery_wait > 0.0 or not is_instance_valid(pocket) or not pocket.stump_top.is_finite(): return
	_recovery_wait = RECOVERY_SECONDS
	if _apple_available(): return
	var apple: RigidBody3D = FOOD_SPAWN.spawn(game, APPLE, Transform3D(Basis.IDENTITY, pocket.stump_top), false)
	if apple != null: apple.add_to_group("arrival_apples")

func _apple_slot() -> int:
	var store: RefCounted = game.inventory.inventory
	for i in store.slots.size():
		if IDENTITY.canonical(str(store.slots[i].get("id", ""))) == APPLE and int(store.slots[i].get("count", 0)) > 0: return i
	return -1

func _feet() -> Vector3:
	var camera: Camera3D = game._find_camera(game.player) if is_instance_valid(game) and is_instance_valid(game.player) else null
	return camera.global_position if camera != null and camera.is_inside_tree() else Vector3.ZERO

static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

# ---------------------------------------------------------------- arrow and instructions
func _process(delta: float) -> void:
	if step.is_empty() or not is_instance_valid(game): return
	var camera: Camera3D = game._find_camera(game.player)
	if camera == null: return
	var target := _arrow_target()
	_arrow.visible = target.is_finite()
	if _arrow.visible:
		var bob := sin(Time.get_ticks_msec() * 0.004) * 0.06
		var small := not ["walk", "stash", "inspect", "talk"].has(step)
		_arrow.scale = Vector3.ONE * (0.35 if small else 1.0)
		_arrow.global_position = target + Vector3.UP * (bob * (0.35 if small else 1.0))
		_arrow.rotation.y += delta * 1.6

## World tasks retain world arrows; head HUD controls are already named in the view.
func _arrow_target() -> Vector3:
	if step == "eat" and _holding_apple(): return Vector3.INF
	if step == "eat" and not _has_carried_apple():
		return pocket.stump_top + Vector3.UP * 0.55 if is_instance_valid(pocket) else Vector3.INF
	match step:
		"walk", "stash":
			return pocket.stump_top + Vector3.UP * 0.55 if is_instance_valid(pocket) else Vector3.INF
		"inspect", "talk":
			return twilight.global_position + Vector3.UP * 2.0 if is_instance_valid(twilight) else Vector3.INF
	if not game.xr_active: return Vector3.INF
	if step == "eat" and _apple_slot() < 5:
		var hotbar: Node3D = game.inventory.get("hotbar")
		if is_instance_valid(hotbar) and hotbar.is_visible_in_tree() and hotbar.global_position.is_finite():
			return hotbar.global_position + Vector3.UP * 0.18
		if not game.inventory.has_method("hand_sample"): return Vector3.INF
		var sample: Dictionary = game.inventory.hand_sample("right")
		if not bool(sample.get("active", false)) or not sample.get("pose") is Transform3D: return Vector3.INF
		var pose: Transform3D = sample.pose
		return pose.origin + Vector3.UP * 0.18 if pose.is_finite() else Vector3.INF
	if game.inventory.has_method("_head_hud") and game.inventory._head_hud(): return Vector3.INF
	var avatar: Node = game.inventory.get("avatar")
	if avatar == null or not avatar.has_method("interaction_forearm"): return Vector3.INF
	var arm: Dictionary = avatar.interaction_forearm("left")
	if not arm.has("forearm"): return Vector3.INF
	var frame: Transform3D = arm.forearm
	return frame.origin + Vector3.UP * 0.16

func _make_arrow() -> Node3D:
	var root := Node3D.new(); root.name = "TutorialArrow"
	var gold := StandardMaterial3D.new(); gold.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gold.albedo_color = Color("ffd75e"); gold.no_depth_test = true; gold.render_priority = 40
	var tip := MeshInstance3D.new(); var cone := CylinderMesh.new()
	cone.top_radius = 0.11; cone.bottom_radius = 0.0; cone.height = 0.16; cone.radial_segments = 4
	cone.material = gold; tip.mesh = cone; tip.position.y = 0.08; root.add_child(tip)
	var shaft := MeshInstance3D.new(); var stem := CylinderMesh.new()
	stem.top_radius = 0.035; stem.bottom_radius = 0.035; stem.height = 0.18; stem.radial_segments = 4
	stem.material = gold; shaft.mesh = stem; shaft.position.y = 0.25; root.add_child(shaft)
	for part: MeshInstance3D in [tip, shaft]: part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return root

func _build_panel() -> void:
	_panel = Node3D.new(); _panel.name = "TutorialPanel"
	_panel.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var camera: Camera3D = game._find_camera(game.player)
	if camera == null: add_child(_panel)
	else: camera.add_child(_panel)
	_panel.position = Vector3(0, -.08, -1.15)
	var back := MeshInstance3D.new(); var quad := QuadMesh.new(); quad.size = Vector2(0.94, 0.36)
	var mat := StandardMaterial3D.new(); mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; mat.albedo_color = Color(0.06, 0.08, 0.1, 0.86)
	mat.no_depth_test = true; mat.render_priority = 41; quad.material = mat; back.mesh = quad
	back.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; _panel.add_child(back)
	_panel_title = _label(Vector3(0, 0.125, 0.002), 44, GOLD); _panel.add_child(_panel_title)
	_panel_text = _label(Vector3(0, -0.035, 0.002), 32, Color(0.95, 0.95, 0.92)); _panel.add_child(_panel_text)
	if camera != null: preload("res://world/ui/head_locked_hud.gd").attach(camera,_panel)

func _label(at: Vector3, size: int, colour: Color) -> Label3D:
	var label := Label3D.new(); label.position = at; label.pixel_size = 0.001; label.font_size = size
	label.font = preload("res://world/books/fonts/AtkinsonHyperlegible-Regular.ttf")
	label.outline_size = 2; label.modulate = colour; label.no_depth_test = true; label.render_priority = 42
	label.width = 850.0; label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

func _build_banner() -> void:
	_layer = CanvasLayer.new(); _layer.layer = 6; add_child(_layer)
	var box := PanelContainer.new(); box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner = box
	box.theme = preload("res://world/ui/readable_text_theme.gd").make()
	var style := StyleBoxFlat.new(); style.bg_color = Color(0.06, 0.08, 0.1, 0.84); style.set_corner_radius_all(8)
	style.content_margin_left = 22; style.content_margin_right = 22; style.content_margin_top = 12; style.content_margin_bottom = 14
	style.border_color = Color(GOLD, 0.6); style.set_border_width_all(2)
	box.add_theme_stylebox_override("panel", style); _layer.add_child(box)
	var column := VBoxContainer.new(); column.mouse_filter = Control.MOUSE_FILTER_IGNORE; box.add_child(column)
	_banner_title = Label.new(); _banner_title.add_theme_font_size_override("font_size", 28)
	_banner_title.add_theme_color_override("font_color", GOLD); _banner_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_banner_text = Label.new(); _banner_text.add_theme_font_size_override("font_size", 21)
	_banner_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; _banner_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for label: Label in [_banner_title, _banner_text]: label.mouse_filter = Control.MOUSE_FILTER_IGNORE; column.add_child(label)
	get_viewport().size_changed.connect(_queue_banner_layout)
	box.minimum_size_changed.connect(_queue_banner_layout)
	box.resized.connect(_queue_banner_layout)
	# Capture the already-created desktop map once. Signals handle resize, toggles and
	# showing/hiding it; no world scans or layout polling in the tutorial frame loop.
	_banner_map = game.get("world_map")
	if is_instance_valid(_banner_map):
		if _banner_map.has_signal("expanded_changed"): _banner_map.expanded_changed.connect(_banner_map_expanded)
		if _banner_map.has_signal("visibility_changed"): _banner_map.visibility_changed.connect(_queue_banner_layout)
		var map_panel: Control = _banner_map.get("panel")
		if is_instance_valid(map_panel):
			map_panel.item_rect_changed.connect(_queue_banner_layout)
			map_panel.visibility_changed.connect(_queue_banner_layout)
	_queue_banner_layout()
	_layer.hide()

func _banner_map_expanded(_open: bool) -> void:
	_queue_banner_layout()

func _queue_banner_layout() -> void:
	if _banner_layout_queued or not is_instance_valid(_banner): return
	_banner_layout_queued = true
	_layout_banner.call_deferred()

func _layout_banner() -> void:
	_banner_layout_queued = false
	# M-ARR-02: a deferred layout can run after the tutorial left the tree (quit or teleport):
	# there is no viewport then.
	if not is_instance_valid(_banner) or not is_inside_tree(): return
	var viewport := get_viewport()
	if viewport == null: return
	var screen := viewport.get_visible_rect().size
	var width := maxf(1.0, minf(860.0, screen.x - 32.0))
	# Reset height after narrower text has wrapped; Container minimums supply the
	# complete title/body height instead of clipping to the former fixed banner.
	_banner.size = Vector2(width, 0.0)
	var rect := Rect2(Vector2((screen.x - width) * .5, 26.0), _banner.size)
	# FPS occupies the top-left three-line HUD. Keep its corner clear even while its
	# enabled state changes; reserving it needs no diagnostic-node dependency/search.
	var fps_corner := Rect2(Vector2.ZERO, Vector2(420.0, 110.0))
	if rect.intersects(fps_corner): rect.position.y = fps_corner.end.y + 12.0
	if is_instance_valid(_banner_map) and _banner_map.get("visible") == true and _banner_map.get("expanded") != true:
		var map_panel: Control = _banner_map.get("panel")
		if is_instance_valid(map_panel) and map_panel.is_visible_in_tree():
			var map_rect := map_panel.get_global_rect()
			if rect.intersects(map_rect): rect.position.y = map_rect.end.y + 12.0
	_banner.position = rect.position

func _exit_tree() -> void:
	if is_instance_valid(_panel) and _panel.get_parent() != self: _panel.queue_free()
